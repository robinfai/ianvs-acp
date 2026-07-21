use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::ExecutionError;

pub const MAX_IDEMPOTENCY_PAYLOAD_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_IDEMPOTENCY_RESULT_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdempotencyKey {
    pub command_id: String,
    pub command_type: String,
    pub payload_hash: String,
    pub created_at: String,
}

impl IdempotencyKey {
    pub fn for_payload<T: Serialize>(
        command_id: &str,
        command_type: &str,
        created_at: &str,
        payload: &T,
    ) -> Result<Self, ExecutionError> {
        validate_text(command_id, "commandId")?;
        validate_text(command_type, "commandType")?;
        validate_text(created_at, "createdAt")?;
        let encoded =
            serde_json::to_vec(payload).map_err(|_| ExecutionError::IdempotencyEncoding)?;
        if encoded.len() > MAX_IDEMPOTENCY_PAYLOAD_BYTES {
            return Err(ExecutionError::IdempotencyPayloadTooLarge);
        }
        let digest = Sha256::digest(encoded);
        Ok(Self {
            command_id: command_id.to_string(),
            command_type: command_type.to_string(),
            payload_hash: format!("sha256:{digest:x}"),
            created_at: created_at.to_string(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct IdempotencyRecord {
    pub command_id: String,
    pub command_type: String,
    pub payload_hash: String,
    pub result_revision: u64,
    pub result_projection: String,
    pub created_at: String,
}

fn validate_text(value: &str, field: &'static str) -> Result<(), ExecutionError> {
    if value.is_empty() || value.trim() != value {
        Err(ExecutionError::InvalidText(field))
    } else {
        Ok(())
    }
}
