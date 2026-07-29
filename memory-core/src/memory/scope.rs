use super::types::{MemoryKind, MemoryScope};

pub fn default_scope_for(kind: MemoryKind, scope: &MemoryScope) -> &'static str {
    match kind {
        MemoryKind::UserPreference => "global",
        MemoryKind::ProjectRule => "repo",
        MemoryKind::ArchitectureDecision => {
            if scope.repo_id.is_some() {
                "repo"
            } else {
                "workspace"
            }
        }
        MemoryKind::SessionSummary => "session",
        MemoryKind::TaskEpisode => {
            if scope.repo_id.is_some() {
                "repo"
            } else {
                "workspace"
            }
        }
    }
}
