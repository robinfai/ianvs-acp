use std::collections::{BTreeMap, BTreeSet};
use std::fs;

use ianvs_acp_core::{
    BudgetPolicy, CapabilityRegistry, CapabilityRequirement, CoordinatorError, DurableWorkflow,
    PlanProposal, PlanProposalStatus, PlanVersion, SemanticCapabilityProfile, StepDefinition,
    StepKind, StepRunStatus, WORKFLOW_IR_SCHEMA_VERSION, WorkflowDefinition, WorkflowRun,
};
use serde_json::json;

#[test]
fn capability_matching_is_semantic_and_vendor_independent() {
    let profiles = profiles();
    let registry = CapabilityRegistry::from_profiles(&profiles).unwrap();
    let requirement = CapabilityRequirement {
        all_of: ["code".to_string()].into_iter().collect(),
        any_of: ["review".to_string(), "test".to_string()]
            .into_iter()
            .collect(),
        none_of: ["network".to_string()].into_iter().collect(),
    };
    let matched = registry.matching_profiles(&requirement);
    assert_eq!(matched.len(), 1);
    assert_eq!(matched[0].profile_id, "reviewer");
}

#[test]
fn policy_rejects_rewriting_started_steps_and_stale_proposals() {
    let definition = definition();
    let mut run = WorkflowRun::new(
        "run-policy".to_string(),
        &definition,
        "2026-07-21T14:00:00.000Z".to_string(),
    )
    .unwrap();
    run.start_step("root", json!({}), "2026-07-21T14:00:01.000Z", &definition)
        .unwrap();
    let mut rewritten = root_step();
    rewritten.kind = StepKind::Agent {
        capability_profile: "general".to_string(),
        prompt_template: "Changed after start".to_string(),
    };
    let rewrite_proposal = proposal("rewrite", 1, vec![rewritten]);
    assert_eq!(
        run.propose_plan(&definition, rewrite_proposal),
        Err(CoordinatorError::StartedStepMutation)
    );

    let stale = PlanProposal {
        base_plan_version: 0,
        ..proposal("stale", 1, vec![root_step()])
    };
    assert_eq!(
        run.propose_plan(&definition, stale),
        Err(CoordinatorError::StalePlanProposal)
    );

    let review = StepDefinition {
        step_id: "review-after-running".to_string(),
        kind: StepKind::Agent {
            capability_profile: "reviewer".to_string(),
            prompt_template: "Review after the started Step completes.".to_string(),
        },
        depends_on: vec!["root".to_string()],
        inputs: BTreeMap::new(),
        result_schema_id: None,
        retry_limit: 0,
        permission_profile: None,
    };
    run.propose_plan(
        &definition,
        proposal("running-replan", 1, vec![root_step(), review]),
    )
    .unwrap();
    run.activate_plan(&definition, "running-replan", "2026-07-21T14:00:02.750Z")
        .unwrap();
    assert_eq!(run.step_runs[0].plan_version, 1);
    run.complete_step(
        &definition,
        "root",
        json!({"ok": true}),
        Vec::new(),
        "2026-07-21T14:00:03.000Z",
    )
    .unwrap();
    assert_eq!(
        run.task_ledger[0].status,
        ianvs_acp_core::TaskLedgerStatus::Succeeded
    );
    assert_eq!(
        run.task_ledger[1].status,
        ianvs_acp_core::TaskLedgerStatus::Ready
    );
}

#[test]
fn validated_replan_ledgers_and_usage_survive_restart() {
    let directory = unique_temp_dir("coordinator");
    let database = directory.join("workflow.sqlite3");
    let definition = definition();
    let mut authority = DurableWorkflow::open(&database).unwrap();
    authority.register_workflow_definition(&definition).unwrap();
    let run = WorkflowRun::new(
        "run-coordinator".to_string(),
        &definition,
        "2026-07-21T14:00:00.000Z".to_string(),
    )
    .unwrap();
    authority.create_workflow_run(&run).unwrap();
    authority
        .start_workflow_step(&run.run_id, "root", json!({}), "2026-07-21T14:00:01.000Z")
        .unwrap();
    authority
        .complete_workflow_step(
            &run.run_id,
            "root",
            json!({"ok": true}),
            Vec::new(),
            "2026-07-21T14:00:02.000Z",
        )
        .unwrap();
    let review = StepDefinition {
        step_id: "review".to_string(),
        kind: StepKind::Agent {
            capability_profile: "reviewer".to_string(),
            prompt_template: "Review the root output.".to_string(),
        },
        depends_on: vec!["root".to_string()],
        inputs: BTreeMap::new(),
        result_schema_id: None,
        retry_limit: 0,
        permission_profile: None,
    };
    let proposed = authority
        .propose_workflow_plan(
            &run.run_id,
            proposal("proposal-1", 1, vec![root_step(), review]),
        )
        .unwrap();
    assert_eq!(proposed.plan_proposals.len(), 1);
    assert_eq!(proposed.progress_ledger.last().unwrap().sequence, 3);
    let activated = authority
        .activate_workflow_plan(&run.run_id, "proposal-1", "2026-07-21T14:00:03.000Z")
        .unwrap();
    assert_eq!(activated.active_plan_version, 2);
    assert_eq!(activated.step_runs[0].plan_version, 1);
    assert_eq!(activated.step_runs[1].plan_version, 2);
    assert_eq!(activated.step_runs[1].status, StepRunStatus::Ready);
    assert_eq!(
        activated.plan_proposals[0].status,
        PlanProposalStatus::Activated
    );
    let metered = authority
        .record_workflow_usage(&run.run_id, 100, 25, 500, "2026-07-21T14:00:04.000Z")
        .unwrap();
    assert_eq!(metered.usage.input_tokens, 100);
    assert_eq!(metered.task_ledger.len(), 2);
    assert!(
        authority
            .record_workflow_usage(&run.run_id, u64::MAX, 0, 0, "2026-07-21T14:00:05.000Z",)
            .is_err()
    );
    assert_eq!(
        authority.workflow_run(&run.run_id).unwrap().unwrap(),
        metered
    );
    drop(authority);

    let reopened = DurableWorkflow::open(&database).unwrap();
    let restored = reopened.workflow_run(&run.run_id).unwrap().unwrap();
    assert_eq!(restored, metered);
    fs::remove_dir_all(directory).unwrap();
}

#[test]
fn concurrent_agent_and_capability_parallelism_are_hard_limits() {
    let mut definition = definition();
    definition.budget_policy.max_concurrent_agents = 1;
    definition.initial_plan.steps.push(StepDefinition {
        step_id: "second".to_string(),
        kind: StepKind::Agent {
            capability_profile: "general".to_string(),
            prompt_template: "Run concurrently".to_string(),
        },
        depends_on: Vec::new(),
        inputs: BTreeMap::new(),
        result_schema_id: None,
        retry_limit: 0,
        permission_profile: None,
    });
    let mut run = WorkflowRun::new(
        "run-concurrency".to_string(),
        &definition,
        "2026-07-21T14:00:00.000Z".to_string(),
    )
    .unwrap();
    run.start_step("root", json!({}), "2026-07-21T14:00:01.000Z", &definition)
        .unwrap();
    assert_eq!(
        run.start_step("second", json!({}), "2026-07-21T14:00:02.000Z", &definition,),
        Err(ianvs_acp_core::WorkflowIrError::ConcurrentAgentBudgetExhausted)
    );

    definition.budget_policy.max_concurrent_agents = 2;
    definition.capability_profiles[0].max_parallelism = 1;
    let mut run = WorkflowRun::new(
        "run-profile-concurrency".to_string(),
        &definition,
        "2026-07-21T14:00:00.000Z".to_string(),
    )
    .unwrap();
    run.start_step("root", json!({}), "2026-07-21T14:00:01.000Z", &definition)
        .unwrap();
    assert!(matches!(
        run.start_step(
            "second",
            json!({}),
            "2026-07-21T14:00:02.000Z",
            &definition,
        ),
        Err(ianvs_acp_core::WorkflowIrError::CapabilityParallelismExhausted(profile))
            if profile == "general"
    ));
}

fn definition() -> WorkflowDefinition {
    WorkflowDefinition {
        schema_version: WORKFLOW_IR_SCHEMA_VERSION,
        definition_id: "coordinator-definition".to_string(),
        version: 1,
        name: "Bounded coordinator".to_string(),
        created_at: "2026-07-21T14:00:00.000Z".to_string(),
        provenance: "static baseline".to_string(),
        budget_policy: BudgetPolicy {
            max_plan_nodes: 8,
            max_fan_out: 2,
            max_depth: 4,
            max_replans: 1,
            max_invocations: 4,
            max_concurrent_agents: 2,
            token_budget: 1_000,
            cost_budget_micros: 10_000,
        },
        capability_profiles: profiles(),
        result_schemas: Vec::new(),
        initial_plan: PlanVersion {
            version: 1,
            reason: "initial static plan".to_string(),
            provenance: "test".to_string(),
            created_at: "2026-07-21T14:00:00.000Z".to_string(),
            steps: vec![root_step()],
        },
    }
}

fn profiles() -> Vec<SemanticCapabilityProfile> {
    vec![
        SemanticCapabilityProfile {
            profile_id: "general".to_string(),
            summary: "General coding worker".to_string(),
            capabilities: BTreeSet::from(["code".to_string(), "analysis".to_string()]),
            max_parallelism: 2,
        },
        SemanticCapabilityProfile {
            profile_id: "reviewer".to_string(),
            summary: "Independent code reviewer".to_string(),
            capabilities: BTreeSet::from(["code".to_string(), "review".to_string()]),
            max_parallelism: 1,
        },
    ]
}

fn root_step() -> StepDefinition {
    StepDefinition {
        step_id: "root".to_string(),
        kind: StepKind::Agent {
            capability_profile: "general".to_string(),
            prompt_template: "Implement the bounded task.".to_string(),
        },
        depends_on: Vec::new(),
        inputs: BTreeMap::new(),
        result_schema_id: None,
        retry_limit: 0,
        permission_profile: None,
    }
}

fn proposal(proposal_id: &str, base_plan_version: u32, steps: Vec<StepDefinition>) -> PlanProposal {
    PlanProposal {
        proposal_id: proposal_id.to_string(),
        base_plan_version,
        proposed_plan_version: base_plan_version + 1,
        reason: "bounded replan".to_string(),
        provenance: "coordinator:test".to_string(),
        created_at: "2026-07-21T14:00:02.500Z".to_string(),
        steps,
        status: PlanProposalStatus::Proposed,
        rejection_reason: None,
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
