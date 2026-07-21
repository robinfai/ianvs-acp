use serde::{Deserialize, Serialize};

use crate::InboxEventRecord;

pub const MAX_RUNTIME_EVENT_QUERY_LIMIT: usize = 500;
pub const MAX_RUNTIME_EVENT_APPEND_BATCH: usize = 500;
pub const MAX_RUNTIME_EVENT_REPLAY: usize = 2_000;
pub const RUNTIME_EVENT_CHECKPOINT_INTERVAL: u64 = 1_000;
pub const WORKFLOW_SNAPSHOT_RETENTION: usize = 8;
pub const MAX_RUNTIME_EVENTS_PER_RUN: usize = 100_000;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StoredRuntimeEvent {
    pub sequence: u64,
    pub event: InboxEventRecord,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub executor_lease_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub executor_generation: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeEventPage {
    pub run_id: String,
    pub after_sequence: u64,
    pub events: Vec<StoredRuntimeEvent>,
    pub next_sequence: u64,
    pub has_more: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeEventAppendReceipt {
    pub revision: u64,
    pub first_sequence: u64,
    pub last_sequence: u64,
    pub event_ids: Vec<String>,
}
