use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::ResultSchema;

pub const MAX_AGENT_RESULT_BYTES: usize = 1024 * 1024;
pub const MAX_RESULT_VALIDATION_ISSUES: usize = 32;
pub const MAX_RESULT_SCHEMA_DEPTH: usize = 64;
pub const MAX_RESULT_CORRECTION_ATTEMPTS: u32 = 2;
const ALLOWED_SCHEMA_KEYWORDS: &[&str] = &[
    "type",
    "properties",
    "required",
    "additionalProperties",
    "items",
    "enum",
    "const",
    "minLength",
    "maxLength",
    "minimum",
    "maximum",
    "minItems",
    "maxItems",
    "description",
    "title",
];

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum StructuredResultError {
    #[error("Agent result exceeds its bounded size")]
    OutputTooLarge,
    #[error("Agent result does not contain one JSON value")]
    JsonNotFound,
    #[error("result schema contains an unsupported or invalid keyword")]
    InvalidSchema,
    #[error("result schema exceeds its bounded depth")]
    SchemaDepth,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResultValidationIssue {
    pub instance_pointer: String,
    pub schema_pointer: String,
    pub keyword: String,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StructuredResultStatus {
    Valid,
    CorrectionRequired,
    Exhausted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StructuredResultAttempt {
    pub attempt: u32,
    pub raw_sha256: String,
    pub extracted: Option<Value>,
    pub issues: Vec<ResultValidationIssue>,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StructuredResultRecord {
    pub schema_id: String,
    pub status: StructuredResultStatus,
    pub attempts: Vec<StructuredResultAttempt>,
    pub value: Option<Value>,
    pub correction_prompt: Option<String>,
}

pub fn validate_result_schema(schema: &ResultSchema) -> Result<(), StructuredResultError> {
    validate_schema_node(&schema.schema, 0, "")
}

pub fn evaluate_agent_result(
    schema: &ResultSchema,
    raw: &str,
    mut previous_attempts: Vec<StructuredResultAttempt>,
    now: &str,
) -> Result<StructuredResultRecord, StructuredResultError> {
    validate_result_schema(schema)?;
    if raw.len() > MAX_AGENT_RESULT_BYTES {
        return Err(StructuredResultError::OutputTooLarge);
    }
    let attempt_number = u32::try_from(previous_attempts.len())
        .unwrap_or(u32::MAX)
        .saturating_add(1);
    let digest = Sha256::digest(raw.as_bytes());
    let extracted = extract_json_value(raw).ok();
    let mut issues = match &extracted {
        Some(value) => validate_instance(&schema.schema, value),
        None => vec![ResultValidationIssue {
            instance_pointer: String::new(),
            schema_pointer: String::new(),
            keyword: "json".to_string(),
            message: "Output did not contain one parseable JSON value.".to_string(),
        }],
    };
    issues.truncate(MAX_RESULT_VALIDATION_ISSUES);
    previous_attempts.push(StructuredResultAttempt {
        attempt: attempt_number,
        raw_sha256: format!("sha256:{digest:x}"),
        extracted: extracted.clone(),
        issues: issues.clone(),
        created_at: now.to_string(),
    });
    if issues.is_empty() {
        return Ok(StructuredResultRecord {
            schema_id: schema.schema_id.clone(),
            status: StructuredResultStatus::Valid,
            attempts: previous_attempts,
            value: extracted,
            correction_prompt: None,
        });
    }
    let corrections_used = attempt_number.saturating_sub(1);
    let exhausted = corrections_used >= MAX_RESULT_CORRECTION_ATTEMPTS;
    Ok(StructuredResultRecord {
        schema_id: schema.schema_id.clone(),
        status: if exhausted {
            StructuredResultStatus::Exhausted
        } else {
            StructuredResultStatus::CorrectionRequired
        },
        attempts: previous_attempts,
        value: None,
        correction_prompt: (!exhausted).then(|| correction_prompt(&issues)),
    })
}

pub fn extract_json_value(raw: &str) -> Result<Value, StructuredResultError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(StructuredResultError::JsonNotFound);
    }
    if let Ok(value) = serde_json::from_str::<Value>(trimmed) {
        return Ok(value);
    }
    if let Some(fenced) = strip_single_json_fence(trimmed)
        && let Ok(value) = serde_json::from_str::<Value>(fenced.trim())
    {
        return Ok(value);
    }
    for (offset, character) in trimmed.char_indices() {
        if character != '{' && character != '[' {
            continue;
        }
        let mut stream =
            serde_json::Deserializer::from_str(&trimmed[offset..]).into_iter::<Value>();
        if let Some(Ok(value)) = stream.next() {
            let remainder = &trimmed[offset + stream.byte_offset()..];
            if contains_json_value(remainder) {
                return Err(StructuredResultError::JsonNotFound);
            }
            return Ok(value);
        }
    }
    Err(StructuredResultError::JsonNotFound)
}

fn contains_json_value(value: &str) -> bool {
    value.char_indices().any(|(offset, character)| {
        matches!(character, '{' | '[')
            && serde_json::Deserializer::from_str(&value[offset..])
                .into_iter::<Value>()
                .next()
                .is_some_and(|result| result.is_ok())
    })
}

fn strip_single_json_fence(value: &str) -> Option<&str> {
    let body = value
        .strip_prefix("```json")
        .or_else(|| value.strip_prefix("```JSON"))?;
    body.strip_suffix("```")
}

fn validate_schema_node(
    schema: &Value,
    depth: usize,
    pointer: &str,
) -> Result<(), StructuredResultError> {
    if depth > MAX_RESULT_SCHEMA_DEPTH {
        return Err(StructuredResultError::SchemaDepth);
    }
    let object = schema
        .as_object()
        .ok_or(StructuredResultError::InvalidSchema)?;
    if object
        .keys()
        .any(|key| !ALLOWED_SCHEMA_KEYWORDS.contains(&key.as_str()))
    {
        return Err(StructuredResultError::InvalidSchema);
    }
    let schema_type = object
        .get("type")
        .and_then(Value::as_str)
        .ok_or(StructuredResultError::InvalidSchema)?;
    if !matches!(
        schema_type,
        "object" | "array" | "string" | "number" | "integer" | "boolean" | "null"
    ) {
        return Err(StructuredResultError::InvalidSchema);
    }
    if let Some(values) = object.get("enum") {
        let values = values
            .as_array()
            .ok_or(StructuredResultError::InvalidSchema)?;
        if values.is_empty() || values.len() > 256 {
            return Err(StructuredResultError::InvalidSchema);
        }
    }
    match schema_type {
        "object" => {
            let properties = object
                .get("properties")
                .and_then(Value::as_object)
                .ok_or(StructuredResultError::InvalidSchema)?;
            if properties.len() > 1024 {
                return Err(StructuredResultError::InvalidSchema);
            }
            for (name, child) in properties {
                if name.is_empty() || name.len() > 4096 {
                    return Err(StructuredResultError::InvalidSchema);
                }
                validate_schema_node(
                    child,
                    depth + 1,
                    &format!("{pointer}/properties/{}", escape_pointer(name)),
                )?;
            }
            if let Some(required) = object.get("required") {
                let required = required
                    .as_array()
                    .ok_or(StructuredResultError::InvalidSchema)?;
                let mut names = BTreeSet::new();
                for value in required {
                    let name = value.as_str().ok_or(StructuredResultError::InvalidSchema)?;
                    if !properties.contains_key(name) || !names.insert(name) {
                        return Err(StructuredResultError::InvalidSchema);
                    }
                }
            }
            if let Some(additional) = object.get("additionalProperties")
                && !additional.is_boolean()
            {
                return Err(StructuredResultError::InvalidSchema);
            }
        }
        "array" => {
            let items = object
                .get("items")
                .ok_or(StructuredResultError::InvalidSchema)?;
            validate_schema_node(items, depth + 1, &format!("{pointer}/items"))?;
            validate_unsigned_bounds(object, "minItems", "maxItems")?;
        }
        "string" => validate_unsigned_bounds(object, "minLength", "maxLength")?,
        "number" | "integer" => validate_number_bounds(object)?,
        _ => {}
    }
    Ok(())
}

fn validate_unsigned_bounds(
    object: &Map<String, Value>,
    minimum: &str,
    maximum: &str,
) -> Result<(), StructuredResultError> {
    let minimum = object.get(minimum).map(Value::as_u64).transpose_option()?;
    let maximum = object.get(maximum).map(Value::as_u64).transpose_option()?;
    if minimum.zip(maximum).is_some_and(|(min, max)| min > max) {
        return Err(StructuredResultError::InvalidSchema);
    }
    Ok(())
}

fn validate_number_bounds(object: &Map<String, Value>) -> Result<(), StructuredResultError> {
    let minimum = object
        .get("minimum")
        .map(Value::as_f64)
        .transpose_option()?;
    let maximum = object
        .get("maximum")
        .map(Value::as_f64)
        .transpose_option()?;
    if minimum.zip(maximum).is_some_and(|(min, max)| min > max) {
        return Err(StructuredResultError::InvalidSchema);
    }
    Ok(())
}

fn validate_instance(schema: &Value, instance: &Value) -> Vec<ResultValidationIssue> {
    let mut issues = Vec::new();
    validate_instance_node(schema, instance, "", "", 0, &mut issues);
    issues
}

fn validate_instance_node(
    schema: &Value,
    instance: &Value,
    instance_pointer: &str,
    schema_pointer: &str,
    depth: usize,
    issues: &mut Vec<ResultValidationIssue>,
) {
    if issues.len() >= MAX_RESULT_VALIDATION_ISSUES || depth > MAX_RESULT_SCHEMA_DEPTH {
        return;
    }
    let object = schema.as_object().expect("validated result schema");
    let expected = object["type"].as_str().expect("validated result type");
    let type_matches = match expected {
        "object" => instance.is_object(),
        "array" => instance.is_array(),
        "string" => instance.is_string(),
        "number" => instance.is_number(),
        "integer" => instance.as_i64().is_some() || instance.as_u64().is_some(),
        "boolean" => instance.is_boolean(),
        "null" => instance.is_null(),
        _ => false,
    };
    if !type_matches {
        push_issue(
            issues,
            instance_pointer,
            &format!("{schema_pointer}/type"),
            "type",
            &format!("Expected {expected}."),
        );
        return;
    }
    if let Some(values) = object.get("enum").and_then(Value::as_array)
        && !values.contains(instance)
    {
        push_issue(
            issues,
            instance_pointer,
            schema_pointer,
            "enum",
            "Value is not allowed.",
        );
    }
    if let Some(constant) = object.get("const")
        && constant != instance
    {
        push_issue(
            issues,
            instance_pointer,
            schema_pointer,
            "const",
            "Value does not match const.",
        );
    }
    match expected {
        "object" => validate_object_instance(
            object,
            instance.as_object().expect("type checked"),
            instance_pointer,
            schema_pointer,
            depth,
            issues,
        ),
        "array" => validate_array_instance(
            object,
            instance.as_array().expect("type checked"),
            instance_pointer,
            schema_pointer,
            depth,
            issues,
        ),
        "string" => validate_string_instance(
            object,
            instance.as_str().expect("type checked"),
            instance_pointer,
            schema_pointer,
            issues,
        ),
        "number" | "integer" => validate_number_instance(
            object,
            instance.as_f64().expect("number checked"),
            instance_pointer,
            schema_pointer,
            issues,
        ),
        _ => {}
    }
}

fn validate_object_instance(
    schema: &Map<String, Value>,
    instance: &Map<String, Value>,
    instance_pointer: &str,
    schema_pointer: &str,
    depth: usize,
    issues: &mut Vec<ResultValidationIssue>,
) {
    let properties = schema["properties"]
        .as_object()
        .expect("validated properties");
    if let Some(required) = schema.get("required").and_then(Value::as_array) {
        for name in required.iter().filter_map(Value::as_str) {
            if !instance.contains_key(name) {
                push_issue(
                    issues,
                    instance_pointer,
                    &format!("{schema_pointer}/required"),
                    "required",
                    &format!("Missing required property {name}."),
                );
            }
        }
    }
    for (name, value) in instance {
        if let Some(child_schema) = properties.get(name) {
            validate_instance_node(
                child_schema,
                value,
                &format!("{instance_pointer}/{}", escape_pointer(name)),
                &format!("{schema_pointer}/properties/{}", escape_pointer(name)),
                depth + 1,
                issues,
            );
        } else if schema.get("additionalProperties").and_then(Value::as_bool) == Some(false) {
            push_issue(
                issues,
                &format!("{instance_pointer}/{}", escape_pointer(name)),
                &format!("{schema_pointer}/additionalProperties"),
                "additionalProperties",
                "Additional property is not allowed.",
            );
        }
    }
}

fn validate_array_instance(
    schema: &Map<String, Value>,
    instance: &[Value],
    instance_pointer: &str,
    schema_pointer: &str,
    depth: usize,
    issues: &mut Vec<ResultValidationIssue>,
) {
    validate_length(
        schema,
        u64::try_from(instance.len()).unwrap_or(u64::MAX),
        "minItems",
        "maxItems",
        instance_pointer,
        schema_pointer,
        issues,
    );
    for (index, value) in instance.iter().enumerate() {
        validate_instance_node(
            &schema["items"],
            value,
            &format!("{instance_pointer}/{index}"),
            &format!("{schema_pointer}/items"),
            depth + 1,
            issues,
        );
    }
}

fn validate_string_instance(
    schema: &Map<String, Value>,
    instance: &str,
    instance_pointer: &str,
    schema_pointer: &str,
    issues: &mut Vec<ResultValidationIssue>,
) {
    validate_length(
        schema,
        u64::try_from(instance.chars().count()).unwrap_or(u64::MAX),
        "minLength",
        "maxLength",
        instance_pointer,
        schema_pointer,
        issues,
    );
}

#[allow(clippy::too_many_arguments)]
fn validate_length(
    schema: &Map<String, Value>,
    length: u64,
    minimum: &str,
    maximum: &str,
    instance_pointer: &str,
    schema_pointer: &str,
    issues: &mut Vec<ResultValidationIssue>,
) {
    if schema
        .get(minimum)
        .and_then(Value::as_u64)
        .is_some_and(|value| length < value)
    {
        push_issue(
            issues,
            instance_pointer,
            schema_pointer,
            minimum,
            "Value is too short.",
        );
    }
    if schema
        .get(maximum)
        .and_then(Value::as_u64)
        .is_some_and(|value| length > value)
    {
        push_issue(
            issues,
            instance_pointer,
            schema_pointer,
            maximum,
            "Value is too long.",
        );
    }
}

fn validate_number_instance(
    schema: &Map<String, Value>,
    value: f64,
    instance_pointer: &str,
    schema_pointer: &str,
    issues: &mut Vec<ResultValidationIssue>,
) {
    if schema
        .get("minimum")
        .and_then(Value::as_f64)
        .is_some_and(|minimum| value < minimum)
    {
        push_issue(
            issues,
            instance_pointer,
            schema_pointer,
            "minimum",
            "Number is too small.",
        );
    }
    if schema
        .get("maximum")
        .and_then(Value::as_f64)
        .is_some_and(|maximum| value > maximum)
    {
        push_issue(
            issues,
            instance_pointer,
            schema_pointer,
            "maximum",
            "Number is too large.",
        );
    }
}

fn correction_prompt(issues: &[ResultValidationIssue]) -> String {
    let mut prompt = String::from(
        "Return exactly one JSON value matching the required schema. Correct these validation errors:\n",
    );
    for issue in issues.iter().take(MAX_RESULT_VALIDATION_ISSUES) {
        prompt.push_str("- ");
        prompt.push_str(if issue.instance_pointer.is_empty() {
            "/"
        } else {
            &issue.instance_pointer
        });
        prompt.push_str(": ");
        prompt.push_str(&issue.message);
        prompt.push('\n');
    }
    prompt
}

fn push_issue(
    issues: &mut Vec<ResultValidationIssue>,
    instance_pointer: &str,
    schema_pointer: &str,
    keyword: &str,
    message: &str,
) {
    if issues.len() < MAX_RESULT_VALIDATION_ISSUES {
        issues.push(ResultValidationIssue {
            instance_pointer: instance_pointer.to_string(),
            schema_pointer: schema_pointer.to_string(),
            keyword: keyword.to_string(),
            message: message.to_string(),
        });
    }
}

fn escape_pointer(value: &str) -> String {
    value.replace('~', "~0").replace('/', "~1")
}

trait TransposeOption<T> {
    fn transpose_option(self) -> Result<Option<T>, StructuredResultError>;
}

impl<T> TransposeOption<T> for Option<Option<T>> {
    fn transpose_option(self) -> Result<Option<T>, StructuredResultError> {
        match self {
            Some(Some(value)) => Ok(Some(value)),
            Some(None) => Err(StructuredResultError::InvalidSchema),
            None => Ok(None),
        }
    }
}
