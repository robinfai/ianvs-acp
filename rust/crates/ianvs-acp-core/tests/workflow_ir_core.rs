use std::collections::BTreeMap;
use std::fs;

use ianvs_acp_core::{
    BudgetPolicy, ConditionPredicate, DurableWorkflow, InputBinding, PlanVersion, ResultSchema,
    SemanticCapabilityProfile, StepDefinition, StepKind, StepRunStatus, WORKFLOW_IR_SCHEMA_VERSION,
    WorkflowDefinition, WorkflowIrError, WorkflowRun,
};
use serde_json::json;

#[test]
fn validates_all_initial_node_types_and_rejects_cycles() {
    let definition = definition_with_steps(all_step_kinds());
    definition.validate().unwrap();

    let mut cyclic = definition.clone();
    cyclic.initial_plan.steps[0].depends_on = vec!["checkpoint".to_string()];
    assert_eq!(cyclic.validate(), Err(WorkflowIrError::DependencyCycle));

    let mut undeclared_input = definition.clone();
    undeclared_input.initial_plan.steps[3].kind = StepKind::Reduce {
        collection_input: InputBinding::StepOutput {
            step_id: "agent".to_string(),
            pointer: "/items".to_string(),
        },
    };
    assert_eq!(
        undeclared_input.validate(),
        Err(WorkflowIrError::InputDependency {
            step_id: "reduce".to_string(),
            dependency_id: "agent".to_string(),
        })
    );
}

#[test]
fn enforces_static_node_depth_and_fan_out_budgets() {
    let mut definition = definition_with_steps(vec![
        agent_step("root", vec![]),
        agent_step("left", vec!["root"]),
        agent_step("right", vec!["root"]),
    ]);
    definition.budget_policy.max_fan_out = 1;
    assert_eq!(definition.validate(), Err(WorkflowIrError::FanOutLimit));

    definition.budget_policy.max_fan_out = 2;
    definition.budget_policy.max_depth = 1;
    assert_eq!(definition.validate(), Err(WorkflowIrError::DepthLimit));

    let mut parallel = definition_with_steps(vec![
        StepDefinition {
            step_id: "parallel-root".to_string(),
            kind: StepKind::Parallel { max_fan_out: 1 },
            depends_on: Vec::new(),
            inputs: BTreeMap::new(),
            result_schema_id: None,
            retry_limit: 0,
            permission_profile: None,
        },
        agent_step("left", vec!["parallel-root"]),
        agent_step("right", vec!["parallel-root"]),
    ]);
    parallel.budget_policy.max_fan_out = 2;
    assert_eq!(parallel.validate(), Err(WorkflowIrError::FanOutLimit));
}

#[test]
fn workflow_definition_and_step_runs_survive_reopen_with_cas_revisions() {
    let directory = unique_temp_dir("workflow-ir");
    let database = directory.join("workflow.sqlite3");
    let definition = definition_with_steps(vec![
        agent_step("research", vec![]),
        agent_step("write", vec!["research"]),
    ]);
    let mut authority = DurableWorkflow::open(&database).unwrap();
    authority.register_workflow_definition(&definition).unwrap();
    let run = WorkflowRun::new(
        "workflow-run-1".to_string(),
        &definition,
        "2026-07-21T12:00:00.000Z".to_string(),
    )
    .unwrap();
    authority.create_workflow_run(&run).unwrap();
    let mut forged = run.clone();
    forged.status = ianvs_acp_core::WorkflowRunStatus::Succeeded;
    forged.run_id = "forged-workflow-run".to_string();
    assert!(authority.create_workflow_run(&forged).is_err());
    let running = authority
        .start_workflow_step(
            &run.run_id,
            "research",
            json!({"topic": "durability"}),
            "2026-07-21T12:00:01.000Z",
        )
        .unwrap();
    assert_eq!(running.revision, 1);
    assert_eq!(running.step_runs[0].status, StepRunStatus::Running);
    drop(authority);

    let mut reopened = DurableWorkflow::open(&database).unwrap();
    let restored = reopened.workflow_run(&run.run_id).unwrap().unwrap();
    assert_eq!(restored, running);
    let completed = reopened
        .submit_workflow_step_result(
            &run.run_id,
            "research",
            "{\"summary\":\"durable\"}",
            Vec::new(),
            "2026-07-21T12:00:02.000Z",
        )
        .unwrap();
    assert_eq!(completed.revision, 2);
    assert_eq!(completed.step_runs[1].status, StepRunStatus::Ready);
    fs::remove_dir_all(directory).unwrap();
}

fn definition_with_steps(steps: Vec<StepDefinition>) -> WorkflowDefinition {
    WorkflowDefinition {
        schema_version: WORKFLOW_IR_SCHEMA_VERSION,
        definition_id: "definition-1".to_string(),
        version: 1,
        name: "Typed workflow".to_string(),
        created_at: "2026-07-21T12:00:00.000Z".to_string(),
        provenance: "test fixture".to_string(),
        budget_policy: BudgetPolicy {
            max_plan_nodes: 32,
            max_fan_out: 8,
            max_depth: 16,
            max_replans: 2,
            max_invocations: 32,
            max_concurrent_agents: 4,
            token_budget: 100_000,
            cost_budget_micros: 1_000_000,
        },
        capability_profiles: vec![SemanticCapabilityProfile {
            profile_id: "general".to_string(),
            summary: "General ACP worker".to_string(),
            capabilities: ["analysis".to_string()].into_iter().collect(),
            max_parallelism: 4,
        }],
        result_schemas: vec![ResultSchema {
            schema_id: "object-result".to_string(),
            schema: json!({
                "type": "object",
                "properties": {"summary": {"type": "string"}},
                "required": ["summary"],
                "additionalProperties": false
            }),
        }],
        initial_plan: PlanVersion {
            version: 1,
            reason: "initial static plan".to_string(),
            provenance: "test fixture".to_string(),
            created_at: "2026-07-21T12:00:00.000Z".to_string(),
            steps,
        },
    }
}

fn agent_step(id: &str, dependencies: Vec<&str>) -> StepDefinition {
    StepDefinition {
        step_id: id.to_string(),
        kind: StepKind::Agent {
            capability_profile: "general".to_string(),
            prompt_template: "Return a structured result.".to_string(),
        },
        depends_on: dependencies.into_iter().map(str::to_string).collect(),
        inputs: BTreeMap::new(),
        result_schema_id: Some("object-result".to_string()),
        retry_limit: 1,
        permission_profile: Some("workspace-read".to_string()),
    }
}

fn all_step_kinds() -> Vec<StepDefinition> {
    let definitions = vec![
        (
            "agent",
            StepKind::Agent {
                capability_profile: "general".to_string(),
                prompt_template: "Work".to_string(),
            },
        ),
        ("parallel", StepKind::Parallel { max_fan_out: 2 }),
        (
            "map",
            StepKind::Map {
                collection_input: InputBinding::Literal {
                    value: json!([1, 2]),
                },
                max_fan_out: 2,
            },
        ),
        (
            "reduce",
            StepKind::Reduce {
                collection_input: InputBinding::StepOutput {
                    step_id: "map".to_string(),
                    pointer: "/items".to_string(),
                },
            },
        ),
        (
            "condition",
            StepKind::Condition {
                predicate: ConditionPredicate::Exists {
                    input: InputBinding::StepOutput {
                        step_id: "reduce".to_string(),
                        pointer: "/summary".to_string(),
                    },
                },
            },
        ),
        (
            "approval",
            StepKind::Approval {
                approval_profile: "human".to_string(),
            },
        ),
        (
            "wait",
            StepKind::Wait {
                timeout_seconds: 60,
                signal_name: Some("continue".to_string()),
            },
        ),
        ("checkpoint", StepKind::Checkpoint),
    ];
    definitions
        .into_iter()
        .enumerate()
        .map(|(index, (id, kind))| StepDefinition {
            step_id: id.to_string(),
            kind,
            depends_on: if index > 0 {
                vec![all_step_kind_id(index - 1).to_string()]
            } else {
                Vec::new()
            },
            inputs: BTreeMap::new(),
            result_schema_id: None,
            retry_limit: 0,
            permission_profile: None,
        })
        .collect()
}

fn all_step_kind_id(index: usize) -> &'static str {
    [
        "agent",
        "parallel",
        "map",
        "reduce",
        "condition",
        "approval",
        "wait",
        "checkpoint",
    ][index]
}

fn unique_temp_dir(label: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "ianvs-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir(&path).unwrap();
    path
}
