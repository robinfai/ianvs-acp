use std::collections::BTreeMap;
use std::fs;

use ianvs_acp_core::{
    BudgetPolicy, DurableWorkflow, DurableWorkflowError, PlanVersion, ProgressLedgerKind,
    ResultSchema, SemanticCapabilityProfile, StepDefinition, StepKind, StepRunStatus,
    StructuredResultStatus, TaskLedgerStatus, WORKFLOW_IR_SCHEMA_VERSION, WorkflowDefinition,
    WorkflowIrError, WorkflowRun, WorkflowRunStatus, evaluate_agent_result, extract_json_value,
};
use serde_json::json;

#[test]
fn extracts_one_json_value_and_validates_a_bounded_schema_subset() {
    let schema = result_schema();
    let extracted =
        extract_json_value("Result follows:\n```json\n{\"summary\":\"ready\",\"score\":3}\n```")
            .unwrap();
    assert_eq!(extracted["summary"], "ready");
    let result = evaluate_agent_result(
        &schema,
        "Result follows: {\"summary\":\"ready\",\"score\":3}",
        Vec::new(),
        "2026-07-21T13:00:00.000Z",
    )
    .unwrap();
    assert_eq!(result.status, StructuredResultStatus::Valid);
    assert_eq!(result.value.unwrap()["score"], 3);
    assert!(extract_json_value("{\"summary\":\"one\"} {\"summary\":\"two\"}").is_err());
}

#[test]
fn correction_is_bounded_and_exhaustion_is_explicit() {
    let schema = result_schema();
    let first =
        evaluate_agent_result(&schema, "not json", Vec::new(), "2026-07-21T13:00:00.000Z").unwrap();
    assert_eq!(first.status, StructuredResultStatus::CorrectionRequired);
    assert!(first.correction_prompt.is_some());
    let second = evaluate_agent_result(
        &schema,
        "{\"summary\": 7}",
        first.attempts,
        "2026-07-21T13:00:01.000Z",
    )
    .unwrap();
    assert_eq!(second.status, StructuredResultStatus::CorrectionRequired);
    let third = evaluate_agent_result(
        &schema,
        "{\"score\": 200}",
        second.attempts,
        "2026-07-21T13:00:02.000Z",
    )
    .unwrap();
    assert_eq!(third.status, StructuredResultStatus::Exhausted);
    assert!(third.correction_prompt.is_none());
    assert_eq!(third.attempts.len(), 3);
}

#[test]
fn typed_agent_result_is_durable_and_only_valid_output_completes_step() {
    let directory = unique_temp_dir("structured-result");
    let database = directory.join("workflow.sqlite3");
    let definition = workflow_definition();
    let mut authority = DurableWorkflow::open(&database).unwrap();
    authority.register_workflow_definition(&definition).unwrap();
    let run = WorkflowRun::new(
        "structured-run".to_string(),
        &definition,
        "2026-07-21T13:00:00.000Z".to_string(),
    )
    .unwrap();
    authority.create_workflow_run(&run).unwrap();
    authority
        .start_workflow_step(&run.run_id, "agent", json!({}), "2026-07-21T13:00:01.000Z")
        .unwrap();
    assert!(matches!(
        authority.complete_workflow_step(
            &run.run_id,
            "agent",
            json!({"summary": "bypass", "score": 1}),
            Vec::new(),
            "2026-07-21T13:00:01.500Z",
        ),
        Err(DurableWorkflowError::WorkflowIr(
            WorkflowIrError::StructuredResultRequired(step_id)
        )) if step_id == "agent"
    ));
    let correcting = authority
        .submit_workflow_step_result(
            &run.run_id,
            "agent",
            "{\"summary\": 9}",
            Vec::new(),
            "2026-07-21T13:00:02.000Z",
        )
        .unwrap();
    assert_eq!(correcting.step_runs[0].status, StepRunStatus::Running);
    assert_eq!(
        correcting.step_runs[0]
            .structured_result
            .as_ref()
            .unwrap()
            .status,
        StructuredResultStatus::CorrectionRequired
    );
    drop(authority);

    let mut reopened = DurableWorkflow::open(&database).unwrap();
    let complete = reopened
        .submit_workflow_step_result(
            &run.run_id,
            "agent",
            "```json\n{\"summary\":\"done\",\"score\":99}\n```",
            Vec::new(),
            "2026-07-21T13:00:03.000Z",
        )
        .unwrap();
    assert_eq!(complete.step_runs[0].status, StepRunStatus::Succeeded);
    assert_eq!(
        complete.step_runs[0].output.as_ref().unwrap()["summary"],
        "done"
    );
    assert_eq!(
        complete.step_runs[0]
            .structured_result
            .as_ref()
            .unwrap()
            .attempts
            .len(),
        2
    );
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn exhausted_corrections_enter_durable_human_review() {
    let definition = workflow_definition();
    let mut authority = DurableWorkflow::open_in_memory().unwrap();
    authority.register_workflow_definition(&definition).unwrap();
    let run = WorkflowRun::new(
        "exhausted-run".to_string(),
        &definition,
        "2026-07-21T13:10:00.000Z".to_string(),
    )
    .unwrap();
    authority.create_workflow_run(&run).unwrap();
    authority
        .start_workflow_step(&run.run_id, "agent", json!({}), "2026-07-21T13:10:01.000Z")
        .unwrap();
    for (index, raw) in ["not json", "{\"summary\":7}", "{\"score\":200}"]
        .into_iter()
        .enumerate()
    {
        authority
            .submit_workflow_step_result(
                &run.run_id,
                "agent",
                raw,
                Vec::new(),
                &format!("2026-07-21T13:10:0{}.000Z", index + 2),
            )
            .unwrap();
    }
    let exhausted = authority.workflow_run(&run.run_id).unwrap().unwrap();
    assert_eq!(exhausted.status, WorkflowRunStatus::NeedsHumanReview);
    assert_eq!(
        exhausted.step_runs[0].status,
        StepRunStatus::NeedsHumanReview
    );
    assert_eq!(exhausted.task_ledger[0].status, TaskLedgerStatus::Waiting);
    assert_eq!(
        exhausted.progress_ledger.last().unwrap().kind,
        ProgressLedgerKind::HumanReview
    );
}

fn workflow_definition() -> WorkflowDefinition {
    WorkflowDefinition {
        schema_version: WORKFLOW_IR_SCHEMA_VERSION,
        definition_id: "structured-definition".to_string(),
        version: 1,
        name: "Structured output".to_string(),
        created_at: "2026-07-21T13:00:00.000Z".to_string(),
        provenance: "test".to_string(),
        budget_policy: BudgetPolicy {
            max_plan_nodes: 4,
            max_fan_out: 2,
            max_depth: 4,
            max_replans: 1,
            max_invocations: 4,
            max_concurrent_agents: 1,
            token_budget: 10_000,
            cost_budget_micros: 100_000,
        },
        capability_profiles: vec![SemanticCapabilityProfile {
            profile_id: "writer".to_string(),
            summary: "Structured result writer".to_string(),
            capabilities: ["structured-output".to_string()].into_iter().collect(),
            max_parallelism: 1,
        }],
        result_schemas: vec![result_schema()],
        initial_plan: PlanVersion {
            version: 1,
            reason: "initial".to_string(),
            provenance: "test".to_string(),
            created_at: "2026-07-21T13:00:00.000Z".to_string(),
            steps: vec![StepDefinition {
                step_id: "agent".to_string(),
                kind: StepKind::Agent {
                    capability_profile: "writer".to_string(),
                    prompt_template: "Return JSON".to_string(),
                },
                depends_on: Vec::new(),
                inputs: BTreeMap::new(),
                result_schema_id: Some("agent-result".to_string()),
                retry_limit: 0,
                permission_profile: None,
            }],
        },
    }
}

fn result_schema() -> ResultSchema {
    ResultSchema {
        schema_id: "agent-result".to_string(),
        schema: json!({
            "type": "object",
            "properties": {
                "summary": {"type": "string", "minLength": 1, "maxLength": 100},
                "score": {"type": "integer", "minimum": 0, "maximum": 100}
            },
            "required": ["summary", "score"],
            "additionalProperties": false
        }),
    }
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
