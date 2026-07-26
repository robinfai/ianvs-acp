use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use ianvs_acp_core::{
    AgentLaunchConfig, BudgetPolicy, ExecutorLeaseState, InboxApprovalStatus, InboxArtifactKind,
    InboxTaskStatus, InputBinding, PermissionDecision, PlanProposal, PlanVersion,
    SemanticCapabilityProfile, StepDefinition, StepKind, TaskInboxCommand, TaskInboxSnapshot,
    WORKFLOW_IR_SCHEMA_VERSION, WorkflowDefinition, WorkflowRun, WorkflowRunStatus,
};
use ianvs_acpd::protocol::{
    DAEMON_PROTOCOL_VERSION, DaemonCommand, DaemonRequest, DaemonResponse, DaemonResult,
};
use ianvs_acpd::{DaemonError, DaemonHost};

#[test]
#[allow(clippy::too_many_lines)]
fn daemon_remains_the_single_execution_host_across_flutter_disconnect() {
    let directory = unique_temp_dir("daemon-e2e");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let permission_workspace = directory.join("permission-workspace");
    fs::create_dir(&permission_workspace).unwrap();
    let database = directory.join("workflow.sqlite3");
    let socket = directory.join("ianvs-acpd.sock");
    let host = DaemonHost::bind(&database, &socket, true).unwrap();
    let server = thread::spawn(move || host.serve().unwrap());
    wait_for_socket(&socket);
    assert!(matches!(
        DaemonHost::bind(&database, &socket, true),
        Err(DaemonError::AlreadyRunning)
    ));
    let alternate_socket = socket.with_extension("alternate.sock");
    assert!(matches!(
        DaemonHost::bind(&database, &alternate_socket, true),
        Err(DaemonError::AlreadyRunning)
    ));

    let source: TaskInboxSnapshot = serde_json::from_value(serde_json::json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-21T10:00:00.000Z",
        "tasks": [{
            "id": "task-1",
            "title": "Headless task",
            "description": "complete while Flutter is disconnected",
            "workspace_path": workspace,
            "agent_name": "fixture",
            "status": "queued",
            "priority": "normal",
            "created_at": "2026-07-21T09:00:00.000Z",
            "updated_at": "2026-07-21T10:00:00.000Z",
            "metadata": {}
        }],
        "runs": [],
        "events": [],
        "artifacts": [],
        "approvals": [],
        "resources": []
    }))
    .unwrap();
    let mut client = Client::connect(&socket);
    assert!(matches!(
        client.call(DaemonCommand::StageTaskInbox {
            source,
            source_checksum: "sha256:daemon-e2e".to_string(),
        }),
        DaemonResult::TaskInboxStage { .. }
    ));
    assert!(matches!(
        client.call(DaemonCommand::MaterializeTaskInbox),
        DaemonResult::TaskInboxProjection { .. }
    ));
    assert!(matches!(
        client.call(DaemonCommand::ActivateTaskInbox),
        DaemonResult::TaskInboxProjection { .. }
    ));
    let fixture = env!("CARGO_BIN_EXE_ianvs-acpd-fixture-agent");
    assert!(matches!(
        client.call(DaemonCommand::ConfigureAgents {
            agents: vec![fixture_agent(fixture, true)],
        }),
        DaemonResult::AgentsConfigured { .. }
    ));
    drop(client);

    // No client is connected while the daemon admits and executes the Task.
    thread::sleep(Duration::from_millis(400));
    let mut reconnected = Client::connect(&socket);
    let deadline = Instant::now() + Duration::from_secs(15);
    let snapshot = loop {
        let DaemonResult::TaskInboxSnapshot {
            snapshot: Some(snapshot),
        } = reconnected.call(DaemonCommand::CurrentTaskInbox)
        else {
            panic!("daemon returned an unexpected TaskInbox result")
        };
        if snapshot.tasks[0].status == InboxTaskStatus::NeedsHumanReview {
            break snapshot;
        }
        assert!(
            Instant::now() < deadline,
            "headless execution timed out: status={:?}, events={:?}",
            snapshot.tasks[0].status,
            snapshot
                .events
                .iter()
                .map(|event| (&event.kind, &event.text))
                .collect::<Vec<_>>()
        );
        thread::sleep(Duration::from_millis(100));
    };
    assert_eq!(snapshot.runs.len(), 1);
    assert!(
        snapshot
            .events
            .iter()
            .any(|event| event.kind == ianvs_acp_core::InboxEventKind::Assistant)
    );
    let run_id = snapshot.runs[0].id.clone();
    let DaemonResult::RuntimeEvents { page } = reconnected.call(DaemonCommand::RuntimeEvents {
        run_id,
        after_sequence: 0,
        limit: 100,
    }) else {
        panic!("daemon returned an unexpected runtime event result")
    };
    assert!(!page.events.is_empty());
    assert!(
        page.events
            .windows(2)
            .all(|pair| pair[0].sequence < pair[1].sequence)
    );

    assert!(matches!(
        reconnected.call(DaemonCommand::ConfigureAgents {
            agents: vec![fixture_agent(fixture, false)],
        }),
        DaemonResult::AgentsConfigured { .. }
    ));
    let permission_task = serde_json::from_value(serde_json::json!({
        "id": "task-permission",
        "title": "Permission review",
        "description": "remain durable when a headless permission is requested",
        "workspace_path": permission_workspace,
        "agent_name": "fixture",
        "status": "inbox",
        "priority": "normal",
        "created_at": "2026-07-21T10:01:00.000Z",
        "updated_at": "2026-07-21T10:01:00.000Z",
        "metadata": {}
    }))
    .unwrap();
    assert!(matches!(
        reconnected.call(DaemonCommand::ApplyTaskInbox {
            command: TaskInboxCommand::CreateTask {
                task: permission_task,
            },
        }),
        DaemonResult::TaskInboxProjection { .. }
    ));
    assert!(matches!(
        reconnected.call(DaemonCommand::ApplyTaskInbox {
            command: TaskInboxCommand::QueueTask {
                task_id: "task-permission".to_string(),
                updated_at: "2026-07-21T10:01:01.000Z".to_string(),
            },
        }),
        DaemonResult::TaskInboxProjection { .. }
    ));
    let deadline = Instant::now() + Duration::from_secs(15);
    let (permission_run_id, permission_request_id) = loop {
        let DaemonResult::TaskInboxSnapshot {
            snapshot: Some(snapshot),
        } = reconnected.call(DaemonCommand::CurrentTaskInbox)
        else {
            panic!("daemon returned an unexpected permission TaskInbox result")
        };
        let task = snapshot
            .tasks
            .iter()
            .find(|task| task.id == "task-permission")
            .unwrap();
        assert_ne!(task.status, InboxTaskStatus::Failed);
        if task.status == InboxTaskStatus::BlockedOnPermission {
            assert!(snapshot.events.iter().any(|event| {
                event.task_id == task.id && event.kind == ianvs_acp_core::InboxEventKind::Permission
            }));
            let approval = snapshot
                .approvals
                .iter()
                .find(|approval| approval.task_id == task.id)
                .unwrap();
            assert_eq!(approval.status, InboxApprovalStatus::Pending);
            let request_id = approval.metadata["permission_request_id"]
                .as_str()
                .unwrap()
                .to_string();
            break (task.current_run_id.clone().unwrap(), request_id);
        }
        assert!(Instant::now() < deadline, "permission wait timed out");
        thread::sleep(Duration::from_millis(100));
    };
    assert!(matches!(
        reconnected.call(DaemonCommand::RespondTaskPermission {
            run_id: permission_run_id.clone(),
            permission_request_id,
            decision: PermissionDecision::Selected {
                option_id: "allow-once".to_string(),
            },
            now: "2026-07-21T10:01:02.000Z".to_string(),
        }),
        DaemonResult::Ack
    ));
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let DaemonResult::TaskInboxSnapshot {
            snapshot: Some(snapshot),
        } = reconnected.call(DaemonCommand::CurrentTaskInbox)
        else {
            panic!("daemon returned an unexpected resumed TaskInbox result")
        };
        let task = snapshot
            .tasks
            .iter()
            .find(|task| task.id == "task-permission")
            .unwrap();
        assert_ne!(task.status, InboxTaskStatus::Failed);
        if task.status == InboxTaskStatus::NeedsHumanReview {
            assert!(snapshot.events.iter().any(|event| {
                event.task_id == task.id
                    && event.kind == ianvs_acp_core::InboxEventKind::Assistant
                    && event.text.contains("permission:allow-once")
            }));
            let approval = snapshot
                .approvals
                .iter()
                .find(|approval| approval.task_id == task.id)
                .unwrap();
            assert_eq!(approval.status, InboxApprovalStatus::Approved);
            break;
        }
        assert!(Instant::now() < deadline, "permission resume timed out");
        thread::sleep(Duration::from_millis(100));
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let DaemonResult::ExecutorLease { lease: Some(lease) } =
            reconnected.call(DaemonCommand::ExecutorLeaseForRun {
                run_id: permission_run_id.clone(),
            })
        else {
            panic!("daemon returned an unexpected permission executor lease")
        };
        if lease.state == ExecutorLeaseState::Released {
            break;
        }
        assert!(Instant::now() < deadline, "executor lease was not released");
        thread::sleep(Duration::from_millis(25));
    }
    assert!(matches!(
        reconnected.call(DaemonCommand::Shutdown),
        DaemonResult::Ack
    ));
    drop(reconnected);
    server.join().unwrap();
    assert!(!socket.exists());
    fs::remove_dir_all(directory).unwrap();
}

fn fixture_agent(command: &str, skip_permission: bool) -> AgentLaunchConfig {
    AgentLaunchConfig {
        agent_name: "fixture".to_string(),
        command: command.to_string(),
        args: Vec::new(),
        environment: if skip_permission {
            std::collections::BTreeMap::from([(
                "IANVS_FIXTURE_SKIP_PERMISSION".to_string(),
                "1".to_string(),
            )])
        } else {
            std::collections::BTreeMap::new()
        },
        process_cwd: None,
        permission_timeout_ms: None,
        max_restart_attempts: None,
        restart_base_delay_ms: None,
        session_store_path: None,
        additional_directories: Vec::new(),
        mcp_servers: Vec::new(),
        enable_terminal_provider: false,
        enable_filesystem_read_text_file: false,
        enable_filesystem_write_text_file: false,
        max_terminal_handles: None,
        max_terminal_handles_per_session: None,
        terminal_default_output_byte_limit: None,
        terminal_max_output_byte_limit: None,
    }
}

#[test]
#[allow(clippy::too_many_lines)]
fn daemon_exposes_typed_workflow_ir_results_and_bounded_replanning() {
    let directory = unique_temp_dir("daemon-workflow-ir");
    let database = directory.join("workflow.sqlite3");
    let socket = directory.join("ianvs-acpd-ir.sock");
    let host = DaemonHost::bind(&database, &socket, true).unwrap();
    let server = thread::spawn(move || host.serve().unwrap());
    wait_for_socket(&socket);
    let mut client = Client::connect(&socket);
    let definition: WorkflowDefinition = serde_json::from_value(serde_json::json!({
        "schemaVersion": 1,
        "definitionId": "daemon-definition",
        "version": 1,
        "name": "Daemon workflow",
        "createdAt": "2026-07-21T15:00:00.000Z",
        "provenance": "daemon E2E",
        "budgetPolicy": {
            "maxPlanNodes": 8,
            "maxFanOut": 2,
            "maxDepth": 4,
            "maxReplans": 1,
            "maxInvocations": 4,
            "maxConcurrentAgents": 2,
            "tokenBudget": 1000,
            "costBudgetMicros": 10000
        },
        "capabilityProfiles": [{
            "profileId": "writer",
            "summary": "Structured writer",
            "capabilities": ["structured-output"],
            "maxParallelism": 1
        }],
        "resultSchemas": [{
            "schemaId": "result",
            "schema": {
                "type": "object",
                "properties": {"summary": {"type": "string"}},
                "required": ["summary"],
                "additionalProperties": false
            }
        }],
        "initialPlan": {
            "version": 1,
            "reason": "initial",
            "provenance": "daemon E2E",
            "createdAt": "2026-07-21T15:00:00.000Z",
            "steps": [{
                "stepId": "write",
                "kind": {
                    "type": "agent",
                    "capabilityProfile": "writer",
                    "promptTemplate": "Return JSON"
                },
                "dependsOn": [],
                "inputs": {},
                "resultSchemaId": "result",
                "retryLimit": 0,
                "permissionProfile": null
            }]
        }
    }))
    .unwrap();
    assert!(matches!(
        client.call(DaemonCommand::RegisterWorkflowDefinition {
            definition: definition.clone(),
        }),
        DaemonResult::Ack
    ));
    let run = WorkflowRun::new(
        "daemon-workflow-run".to_string(),
        &definition,
        "2026-07-21T15:00:00.000Z".to_string(),
    )
    .unwrap();
    assert!(matches!(
        client.call(DaemonCommand::CreateWorkflowRun { run: run.clone() }),
        DaemonResult::WorkflowRun { run: Some(_) }
    ));
    assert!(matches!(
        client.call(DaemonCommand::StartWorkflowStep {
            run_id: run.run_id.clone(),
            step_id: "write".to_string(),
            input: serde_json::json!({}),
            now: "2026-07-21T15:00:01.000Z".to_string(),
        }),
        DaemonResult::WorkflowRun { run: Some(_) }
    ));
    let DaemonResult::WorkflowRun {
        run: Some(completed),
    } = client.call(DaemonCommand::SubmitWorkflowStepResult {
        run_id: run.run_id.clone(),
        step_id: "write".to_string(),
        raw: "{\"summary\":\"done\"}".to_string(),
        artifacts: Vec::new(),
        now: "2026-07-21T15:00:02.000Z".to_string(),
    })
    else {
        panic!("daemon returned an unexpected structured result")
    };
    assert_eq!(
        completed.step_runs[0].output,
        Some(serde_json::json!({"summary": "done"}))
    );
    let proposal: PlanProposal = serde_json::from_value(serde_json::json!({
        "proposalId": "checkpoint-proposal",
        "basePlanVersion": 1,
        "proposedPlanVersion": 2,
        "reason": "persist completion checkpoint",
        "provenance": "coordinator:daemon-e2e",
        "createdAt": "2026-07-21T15:00:03.000Z",
        "steps": [
            definition.initial_plan.steps[0].clone(),
            {
                "stepId": "checkpoint",
                "kind": {"type": "checkpoint"},
                "dependsOn": ["write"],
                "inputs": {},
                "resultSchemaId": null,
                "retryLimit": 0,
                "permissionProfile": null
            }
        ],
        "status": "proposed",
        "rejectionReason": null
    }))
    .unwrap();
    assert!(matches!(
        client.call(DaemonCommand::ProposeWorkflowPlan {
            run_id: run.run_id.clone(),
            proposal,
        }),
        DaemonResult::WorkflowRun { run: Some(_) }
    ));
    let DaemonResult::WorkflowRun {
        run: Some(activated),
    } = client.call(DaemonCommand::ActivateWorkflowPlan {
        run_id: run.run_id.clone(),
        proposal_id: "checkpoint-proposal".to_string(),
        now: "2026-07-21T15:00:04.000Z".to_string(),
    })
    else {
        panic!("daemon returned an unexpected activated plan")
    };
    assert_eq!(activated.active_plan_version, 2);
    assert_eq!(activated.task_ledger.len(), 2);
    assert!(matches!(
        client.call(DaemonCommand::RecordWorkflowUsage {
            run_id: run.run_id,
            input_tokens: 100,
            output_tokens: 25,
            cost_micros: 500,
            now: "2026-07-21T15:00:05.000Z".to_string(),
        }),
        DaemonResult::WorkflowRun { run: Some(_) }
    ));
    assert!(matches!(
        client.call(DaemonCommand::Shutdown),
        DaemonResult::Ack
    ));
    drop(client);
    server.join().unwrap();
    fs::remove_dir_all(directory).unwrap();
}

#[test]
#[allow(clippy::too_many_lines)]
fn daemon_automatically_flows_workflow_agent_tasks_into_local_successors() {
    let directory = unique_temp_dir("daemon-workflow-dispatch");
    let workspace = directory.join("workspace");
    fs::create_dir(&workspace).unwrap();
    let database = directory.join("workflow.sqlite3");
    let socket = directory.join("ianvs-acpd-workflow-dispatch.sock");
    let host = DaemonHost::bind(&database, &socket, true).unwrap();
    let server = thread::spawn(move || host.serve().unwrap());
    wait_for_socket(&socket);
    let mut client = Client::connect(&socket);
    let source: TaskInboxSnapshot = serde_json::from_value(serde_json::json!({
        "schema": "ianvs-acp.task-inbox.v1",
        "updated_at": "2026-07-26T08:00:00.000Z",
        "tasks": [],
        "runs": [],
        "events": [],
        "artifacts": [],
        "approvals": [],
        "resources": []
    }))
    .unwrap();
    assert!(matches!(
        client.call(DaemonCommand::StageTaskInbox {
            source,
            source_checksum: "sha256:daemon-workflow-dispatch".to_string(),
        }),
        DaemonResult::TaskInboxStage { .. }
    ));
    assert!(matches!(
        client.call(DaemonCommand::MaterializeTaskInbox),
        DaemonResult::TaskInboxProjection { .. }
    ));
    assert!(matches!(
        client.call(DaemonCommand::ActivateTaskInbox),
        DaemonResult::TaskInboxProjection { .. }
    ));
    let fixture = env!("CARGO_BIN_EXE_ianvs-acpd-fixture-agent");
    assert!(matches!(
        client.call(DaemonCommand::ConfigureAgents {
            agents: vec![fixture_agent(fixture, true)],
        }),
        DaemonResult::AgentsConfigured { .. }
    ));
    let definition = WorkflowDefinition {
        schema_version: WORKFLOW_IR_SCHEMA_VERSION,
        definition_id: "automatic-flow".to_string(),
        version: 1,
        name: "Automatic flow".to_string(),
        created_at: "2026-07-26T08:00:00.000Z".to_string(),
        provenance: "daemon E2E".to_string(),
        budget_policy: BudgetPolicy {
            max_plan_nodes: 8,
            max_fan_out: 2,
            max_depth: 4,
            max_replans: 1,
            max_invocations: 4,
            max_concurrent_agents: 1,
            token_budget: 10_000,
            cost_budget_micros: 100_000,
        },
        capability_profiles: vec![SemanticCapabilityProfile {
            profile_id: "fixture".to_string(),
            summary: "Fixture ACP agent".to_string(),
            capabilities: BTreeSet::from(["write".to_string()]),
            max_parallelism: 1,
        }],
        result_schemas: Vec::new(),
        initial_plan: PlanVersion {
            version: 1,
            reason: "initial".to_string(),
            provenance: "daemon E2E".to_string(),
            created_at: "2026-07-26T08:00:00.000Z".to_string(),
            steps: vec![
                StepDefinition {
                    step_id: "prepare".to_string(),
                    kind: StepKind::Checkpoint,
                    depends_on: Vec::new(),
                    inputs: BTreeMap::new(),
                    result_schema_id: None,
                    retry_limit: 0,
                    permission_profile: None,
                },
                StepDefinition {
                    step_id: "write".to_string(),
                    kind: StepKind::Agent {
                        capability_profile: "fixture".to_string(),
                        prompt_template: "Complete this workflow Step.".to_string(),
                    },
                    depends_on: vec!["prepare".to_string()],
                    inputs: BTreeMap::from([(
                        "workspacePath".to_string(),
                        InputBinding::Literal {
                            value: serde_json::json!(workspace),
                        },
                    )]),
                    result_schema_id: None,
                    retry_limit: 0,
                    permission_profile: None,
                },
                StepDefinition {
                    step_id: "approve".to_string(),
                    kind: StepKind::Approval {
                        approval_profile: "human".to_string(),
                    },
                    depends_on: vec!["write".to_string()],
                    inputs: BTreeMap::new(),
                    result_schema_id: None,
                    retry_limit: 0,
                    permission_profile: None,
                },
                StepDefinition {
                    step_id: "finish".to_string(),
                    kind: StepKind::Checkpoint,
                    depends_on: vec!["approve".to_string()],
                    inputs: BTreeMap::new(),
                    result_schema_id: None,
                    retry_limit: 0,
                    permission_profile: None,
                },
            ],
        },
    };
    assert!(matches!(
        client.call(DaemonCommand::RegisterWorkflowDefinition {
            definition: definition.clone(),
        }),
        DaemonResult::Ack
    ));
    let run = WorkflowRun::new(
        "automatic-flow-run".to_string(),
        &definition,
        "2026-07-26T08:00:00.000Z".to_string(),
    )
    .unwrap();
    assert!(matches!(
        client.call(DaemonCommand::CreateWorkflowRun { run }),
        DaemonResult::WorkflowRun { run: Some(_) }
    ));

    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let DaemonResult::WorkflowRun { run: Some(run) } =
            client.call(DaemonCommand::WorkflowRun {
                run_id: "automatic-flow-run".to_string(),
            })
        else {
            panic!("daemon returned an unexpected automatic Workflow Run")
        };
        if run.status == WorkflowRunStatus::NeedsHumanReview {
            assert_eq!(
                run.step_runs
                    .iter()
                    .find(|step| step.step_id == "write")
                    .unwrap()
                    .status,
                ianvs_acp_core::StepRunStatus::Succeeded
            );
            break;
        }
        assert!(
            Instant::now() < deadline,
            "automatic workflow did not reach approval: {:?}",
            run.status
        );
        thread::sleep(Duration::from_millis(100));
    }
    let DaemonResult::TaskInboxSnapshot {
        snapshot: Some(snapshot),
    } = client.call(DaemonCommand::CurrentTaskInbox)
    else {
        panic!("daemon returned an unexpected automatic TaskInbox")
    };
    assert_eq!(snapshot.tasks.len(), 1);
    assert_eq!(snapshot.tasks[0].status, InboxTaskStatus::Done);
    assert!(snapshot.artifacts.iter().any(|artifact| {
        artifact.kind == InboxArtifactKind::AgentSummary
            && artifact
                .content_preview
                .as_deref()
                .is_some_and(|value| value.contains("headless fixture complete"))
    }));
    let DaemonResult::WorkflowStepTaskBindings { bindings } =
        client.call(DaemonCommand::WorkflowStepTaskBindings {
            run_id: "automatic-flow-run".to_string(),
        })
    else {
        panic!("daemon returned unexpected Workflow Step bindings")
    };
    assert_eq!(bindings.len(), 1);
    assert_eq!(bindings[0].step_id, "write");
    assert!(bindings[0].task_run_id.is_some());

    assert!(matches!(
        client.call(DaemonCommand::ResolveWorkflowApprovalStep {
            run_id: "automatic-flow-run".to_string(),
            step_id: "approve".to_string(),
            approved: true,
            now: "2026-07-26T08:01:00.000Z".to_string(),
        }),
        DaemonResult::WorkflowRun { run: Some(_) }
    ));
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let DaemonResult::WorkflowRun { run: Some(run) } =
            client.call(DaemonCommand::WorkflowRun {
                run_id: "automatic-flow-run".to_string(),
            })
        else {
            panic!("daemon returned an unexpected resolved Workflow Run")
        };
        if run.status == WorkflowRunStatus::Succeeded {
            assert!(
                run.step_runs
                    .iter()
                    .all(|step| step.status == ianvs_acp_core::StepRunStatus::Succeeded)
            );
            break;
        }
        assert!(Instant::now() < deadline, "local successor did not finish");
        thread::sleep(Duration::from_millis(100));
    }
    assert!(matches!(
        client.call(DaemonCommand::Shutdown),
        DaemonResult::Ack
    ));
    drop(client);
    server.join().unwrap();
    fs::remove_dir_all(directory).unwrap();
}

struct Client {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
    next_id: u64,
}

impl Client {
    fn connect(path: &Path) -> Self {
        let stream = UnixStream::connect(path).unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        Self {
            stream,
            reader,
            next_id: 0,
        }
    }

    fn call(&mut self, command: DaemonCommand) -> DaemonResult {
        self.next_id += 1;
        let request_id = format!("request-{}", self.next_id);
        let request = DaemonRequest {
            schema_version: DAEMON_PROTOCOL_VERSION,
            request_id: request_id.clone(),
            command,
        };
        serde_json::to_writer(&mut self.stream, &request).unwrap();
        self.stream.write_all(b"\n").unwrap();
        self.stream.flush().unwrap();
        let mut encoded = String::new();
        self.reader.read_line(&mut encoded).unwrap();
        let response: DaemonResponse = serde_json::from_str(&encoded).unwrap();
        assert_eq!(response.request_id, request_id);
        if let DaemonResult::Error { code, message } = response.result {
            panic!("daemon request failed ({code}): {message}");
        }
        response.result
    }
}

fn wait_for_socket(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !path.exists() {
        assert!(Instant::now() < deadline, "daemon socket did not appear");
        thread::sleep(Duration::from_millis(10));
    }
}

fn unique_temp_dir(label: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "ianvs-acp-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}
