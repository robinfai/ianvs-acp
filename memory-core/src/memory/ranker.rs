pub fn kind_priority(kind: &str) -> i64 {
    match kind {
        "project_rule" => 0,
        "architecture_decision" => 1,
        "user_preference" => 2,
        "task_episode" => 3,
        "session_summary" => 4,
        _ => 9,
    }
}

pub fn final_score(vector_score: f32, scope_score: f32, recency_score: f32) -> f32 {
    vector_score * 0.70 + scope_score * 0.20 + recency_score * 0.10
}
