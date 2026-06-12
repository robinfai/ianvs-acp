use super::redactor;

pub fn accepts_candidate(text: &str, confidence: Option<f32>) -> bool {
    let trimmed = text.trim();
    if trimmed.len() < 8 {
        return false;
    }
    if !accepts_memory_text(trimmed) {
        return false;
    }
    if confidence.unwrap_or(1.0) < 0.65 {
        return false;
    }
    true
}

pub fn accepts_memory_text(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return false;
    }
    if trimmed.chars().count() > 1000 {
        return false;
    }
    if redactor::contains_secret(trimmed) {
        return false;
    }
    if looks_like_agent_operating_constraint(trimmed) {
        return false;
    }
    true
}

fn looks_like_agent_operating_constraint(text: &str) -> bool {
    let lower = text.to_lowercase();
    let mentions_agents = lower.contains("agents.md")
        || lower.contains("agent operating")
        || lower.contains("agent instruction");
    let mentions_constraint = lower.contains("constraint")
        || lower.contains("instruction")
        || lower.contains("tool-use")
        || lower.contains("tool use")
        || lower.contains("rule")
        || text.contains("约束")
        || text.contains("指令")
        || text.contains("工具规则")
        || text.contains("工具使用规则");
    if mentions_agents && mentions_constraint {
        return true;
    }

    let mentions_netcat = lower.contains("netcat") || contains_ascii_word(&lower, "nc");
    let prohibits = lower.contains("do not use")
        || lower.contains("never use")
        || lower.contains("must not use")
        || text.contains("严禁使用")
        || text.contains("禁止使用")
        || text.contains("不要使用")
        || text.contains("禁用");
    mentions_netcat && prohibits
}

fn contains_ascii_word(text: &str, word: &str) -> bool {
    text.split(|character: char| !character.is_ascii_alphanumeric())
        .any(|part| part == word)
}
