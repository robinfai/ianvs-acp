use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryKind {
    UserPreference,
    ProjectRule,
    ArchitectureDecision,
    SessionSummary,
    TaskEpisode,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskEpisodeData {
    pub goal: String,
    #[serde(default)]
    pub constraints: Vec<String>,
    #[serde(default)]
    pub tools_used: Vec<String>,
    pub mistake: Option<String>,
    pub successful_pattern: String,
}

impl TaskEpisodeData {
    pub fn is_valid(&self) -> bool {
        !self.goal.trim().is_empty() && !self.successful_pattern.trim().is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryScope {
    pub user_id: String,
    pub workspace_id: Option<String>,
    pub repo_id: Option<String>,
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryItem {
    pub id: String,
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub user_id: String,
    pub workspace_id: Option<String>,
    pub repo_id: Option<String>,
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
    pub source: String,
    pub source_session_id: Option<String>,
    pub source_turn_id: Option<String>,
    pub confidence: Option<f32>,
    pub status: String,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryCandidate {
    pub id: String,
    pub kind: MemoryKind,
    pub scope: String,
    pub text: String,
    pub reason: Option<String>,
    pub confidence: Option<f32>,
    pub user_id: String,
    pub workspace_id: Option<String>,
    pub repo_id: Option<String>,
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
    pub transcript_hash: Option<String>,
    pub status: String,
    pub created_at: i64,
    pub reviewed_at: Option<i64>,
}
