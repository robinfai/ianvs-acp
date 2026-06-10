use super::redactor;

pub fn accepts_candidate(text: &str, confidence: Option<f32>) -> bool {
    let trimmed = text.trim();
    if trimmed.len() < 8 {
        return false;
    }
    if trimmed.chars().count() > 1000 {
        return false;
    }
    if redactor::contains_secret(trimmed) {
        return false;
    }
    if confidence.unwrap_or(1.0) < 0.65 {
        return false;
    }
    true
}
