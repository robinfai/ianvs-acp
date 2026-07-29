const SECRET_KEYS: &[&str] = &[
    "api_key",
    "access_token",
    "refresh_token",
    "password",
    "passwd",
    "secret",
    "private_key",
];

const SECRET_PREFIXES: &[&str] = &["-----begin", "sk-", "ghp_", "xoxb-", "akia"];

pub fn contains_secret(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    SECRET_KEYS.iter().any(|pattern| lower.contains(pattern))
        || SECRET_PREFIXES
            .iter()
            .any(|pattern| lower.contains(pattern))
}

pub fn redact(text: &str) -> String {
    text.split_whitespace()
        .map(redact_token)
        .collect::<Vec<_>>()
        .join(" ")
}

fn redact_token(token: &str) -> String {
    let lower = token.to_ascii_lowercase();
    if let Some((key, _value)) = token.split_once('=') {
        let key_lower = key.to_ascii_lowercase();
        if SECRET_KEYS
            .iter()
            .any(|pattern| key_lower.contains(pattern))
        {
            return format!("{key}=[REDACTED]");
        }
    }

    if SECRET_PREFIXES
        .iter()
        .any(|pattern| lower.contains(pattern))
    {
        return "[REDACTED]".to_string();
    }

    token.to_string()
}
