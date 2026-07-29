use super::daemon_client::DaemonClient;

pub fn tools_list() -> serde_json::Value {
    serde_json::json!({
        "tools": [
            {
                "name": "memory.search",
                "description": "Search approved long-term memory.",
                "inputSchema": { "type": "object" }
            },
            {
                "name": "memory.remember",
                "description": "Create memory candidates and auto-approve them when review policy allows.",
                "inputSchema": { "type": "object" }
            },
            {
                "name": "memory.list",
                "description": "List approved memory.",
                "inputSchema": { "type": "object" }
            },
            {
                "name": "memory.update",
                "description": "Create a memory update change request and auto-approve it when review policy allows.",
                "inputSchema": { "type": "object" }
            },
            {
                "name": "memory.forget",
                "description": "Create a pending memory delete change request.",
                "inputSchema": { "type": "object" }
            }
        ]
    })
}

pub async fn call_tool(
    client: &DaemonClient,
    name: &str,
    arguments: serde_json::Value,
) -> serde_json::Value {
    let result = match name {
        "memory.search" => client.post_json("/v1/memory/search", arguments).await,
        "memory.list" => client.get_json("/v1/memory", list_query(arguments)).await,
        "memory.remember" => remember_with_review_policy(client, arguments).await,
        "memory.update" => change_request_with_review_policy(client, arguments, "update").await,
        "memory.forget" => {
            client
                .post_json(
                    "/v1/memory/change-requests",
                    change_request_arguments(arguments, "delete"),
                )
                .await
        }
        _ => {
            return tool_response(
                serde_json::json!({ "error": format!("unsupported tool: {name}") }),
                true,
            );
        }
    };
    match result {
        Ok(value) => tool_response(value, false),
        Err(error) => tool_response(serde_json::json!({ "error": error.to_string() }), true),
    }
}

async fn remember_with_review_policy(
    client: &DaemonClient,
    arguments: serde_json::Value,
) -> anyhow::Result<serde_json::Value> {
    let remember_body = remember_arguments(arguments);
    let mut result = client
        .post_json("/v1/memory/extract-candidates", remember_body.clone())
        .await?;
    let approved_memories = approve_candidates_from_policy(client, &result).await;
    let auto_applied_change_requests = result
        .get("autoAppliedChangeRequests")
        .and_then(|value| value.as_i64())
        .unwrap_or(0);
    let should_run_maintenance = !approved_memories.is_empty() || auto_applied_change_requests > 0;
    if !approved_memories.is_empty() {
        if let Some(object) = result.as_object_mut() {
            object.insert(
                "approvedMemories".to_string(),
                serde_json::Value::Array(approved_memories),
            );
        }
    }
    if should_run_maintenance {
        if let Some(maintenance) = run_maintenance_after_mcp_write(client, &remember_body).await {
            if let Some(object) = result.as_object_mut() {
                object.insert("maintenanceResult".to_string(), maintenance);
            }
        }
    }
    Ok(result)
}

fn remember_arguments(arguments: serde_json::Value) -> serde_json::Value {
    let mut body = arguments
        .as_object()
        .cloned()
        .unwrap_or_else(serde_json::Map::new);
    body.insert(
        "source".to_string(),
        serde_json::Value::String("mcp".to_string()),
    );
    serde_json::Value::Object(body)
}

async fn change_request_with_review_policy(
    client: &DaemonClient,
    arguments: serde_json::Value,
    action: &str,
) -> anyhow::Result<serde_json::Value> {
    let request_body = change_request_arguments(arguments, action);
    let mut result = client
        .post_json("/v1/memory/change-requests", request_body.clone())
        .await?;
    let mut approved_change_request = false;
    if should_auto_approve_change_request(action, &result) {
        if let Some(id) = result.get("id").and_then(|value| value.as_str()) {
            if let Ok(approved) = client
                .post_json(
                    &format!("/v1/memory/change-requests/{id}/approve"),
                    serde_json::json!({"actor": "mcp"}),
                )
                .await
            {
                if let Some(object) = result.as_object_mut() {
                    object.insert("approvedChangeRequest".to_string(), approved);
                }
                approved_change_request = true;
            }
        }
    }
    if approved_change_request {
        if let Some(maintenance) = run_maintenance_after_mcp_write(client, &request_body).await {
            if let Some(object) = result.as_object_mut() {
                object.insert("maintenanceResult".to_string(), maintenance);
            }
        }
    }
    Ok(result)
}

async fn run_maintenance_after_mcp_write(
    client: &DaemonClient,
    arguments: &serde_json::Value,
) -> Option<serde_json::Value> {
    if !env_bool("MEMORY_MAINTENANCE_ENABLED", true)
        || !env_bool("MEMORY_MAINTENANCE_RUN_AFTER_EXTRACTION", true)
    {
        return None;
    }
    let scope = arguments.get("scope")?.clone();
    if !scope.is_object() {
        return None;
    }
    let mut body = serde_json::Map::new();
    body.insert("scope".to_string(), scope);
    body.insert("enabled".to_string(), serde_json::Value::Bool(true));
    body.insert(
        "mode".to_string(),
        serde_json::Value::String(env_string(
            "MEMORY_MAINTENANCE_MODE",
            "high_confidence_auto",
        )),
    );
    body.insert(
        "costMode".to_string(),
        serde_json::Value::String(env_string("MEMORY_MAINTENANCE_COST_MODE", "low_cost")),
    );
    body.insert(
        "highConfidenceThreshold".to_string(),
        serde_json::json!(env_f64(
            "MEMORY_MAINTENANCE_HIGH_CONFIDENCE_THRESHOLD",
            0.90
        )),
    );
    body.insert(
        "reviewThreshold".to_string(),
        serde_json::json!(env_f64("MEMORY_MAINTENANCE_REVIEW_THRESHOLD", 0.75)),
    );
    body.insert(
        "maxItemsPerBatch".to_string(),
        serde_json::json!(env_i64("MEMORY_MAINTENANCE_MAX_ITEMS_PER_BATCH", 12)),
    );
    body.insert(
        "manualOnlyActions".to_string(),
        serde_json::Value::Array(
            env_list("MEMORY_MAINTENANCE_MANUAL_ONLY_ACTIONS", &["delete"])
                .into_iter()
                .map(serde_json::Value::String)
                .collect(),
        ),
    );
    client
        .post_json(
            "/v1/memory/maintenance/run",
            serde_json::Value::Object(body),
        )
        .await
        .ok()
}

fn should_auto_approve_change_request(action: &str, request: &serde_json::Value) -> bool {
    if matches!(action, "delete" | "forget") {
        return false;
    }
    let mode = review_approval_mode();
    if mode == "auto_approve" {
        return true;
    }
    if mode != "auto_high_confidence" {
        return false;
    }
    let threshold = std::env::var("MEMORY_REVIEW_HIGH_CONFIDENCE_THRESHOLD")
        .ok()
        .and_then(|value| value.trim().parse::<f64>().ok())
        .unwrap_or(0.85);
    request
        .get("confidence")
        .and_then(|value| value.as_f64())
        .unwrap_or(0.0)
        >= threshold
}

async fn approve_candidates_from_policy(
    client: &DaemonClient,
    result: &serde_json::Value,
) -> Vec<serde_json::Value> {
    let mode = review_approval_mode();
    let threshold = std::env::var("MEMORY_REVIEW_HIGH_CONFIDENCE_THRESHOLD")
        .ok()
        .and_then(|value| value.trim().parse::<f64>().ok())
        .unwrap_or(0.85);
    let session_threshold = std::env::var("MEMORY_MAINTENANCE_REVIEW_THRESHOLD")
        .ok()
        .and_then(|value| value.trim().parse::<f64>().ok())
        .unwrap_or(0.75);
    if !matches!(mode.as_str(), "auto_high_confidence" | "auto_approve") {
        return Vec::new();
    }

    let Some(candidates) = result.get("candidates").and_then(|value| value.as_array()) else {
        return Vec::new();
    };
    let mut approved = Vec::new();
    for candidate in candidates {
        if mode == "auto_high_confidence"
            && candidate
                .get("kind")
                .and_then(|value| value.as_str())
                .is_some_and(|kind| kind.trim().eq_ignore_ascii_case("task_episode"))
        {
            continue;
        }
        let confidence = candidate
            .get("confidence")
            .and_then(|value| value.as_f64())
            .unwrap_or(0.0);
        if mode == "auto_high_confidence"
            && confidence < threshold
            && !is_review_band_auto_candidate(candidate, session_threshold)
        {
            continue;
        }
        let Some(id) = candidate.get("id").and_then(|value| value.as_str()) else {
            continue;
        };
        let body = serde_json::json!({
            "kind": candidate.get("kind").cloned().unwrap_or(serde_json::Value::Null),
            "scope": candidate.get("scope").cloned().unwrap_or(serde_json::Value::Null),
            "text": candidate.get("text").cloned().unwrap_or(serde_json::Value::Null),
            "actor": "mcp",
        });
        if let Ok(memory) = client
            .post_json(&format!("/v1/memory/candidates/{id}/approve"), body)
            .await
        {
            approved.push(memory);
        }
    }
    approved
}

fn is_review_band_auto_candidate(candidate: &serde_json::Value, threshold: f64) -> bool {
    if candidate
        .get("confidence")
        .and_then(|value| value.as_f64())
        .unwrap_or(0.0)
        < threshold
    {
        return false;
    }
    let kind = candidate
        .get("kind")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    let scope = candidate
        .get("scope")
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    matches!(
        (kind.as_str(), scope.as_str()),
        ("session_summary", "session")
            | ("user_preference", "global")
            | ("project_rule", "workspace")
            | ("project_rule", "repo")
            | ("architecture_decision", "workspace")
            | ("architecture_decision", "repo")
    )
}

fn review_approval_mode() -> String {
    std::env::var("MEMORY_REVIEW_APPROVAL_MODE")
        .map(|value| normalize_mode(&value))
        .unwrap_or_else(|_| "auto_high_confidence".to_string())
}

fn normalize_mode(value: &str) -> String {
    value
        .trim()
        .to_ascii_lowercase()
        .chars()
        .map(|character| match character {
            '-' => '_',
            character if character.is_ascii_whitespace() => '_',
            character => character,
        })
        .collect()
}

fn env_bool(name: &str, default: bool) -> bool {
    match std::env::var(name)
        .ok()
        .map(|value| normalize_mode(&value))
        .as_deref()
    {
        Some("1" | "true" | "yes" | "on" | "enabled") => true,
        Some("0" | "false" | "no" | "off" | "disabled") => false,
        _ => default,
    }
}

fn env_string(name: &str, default: &str) -> String {
    std::env::var(name)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| default.to_string())
}

fn env_f64(name: &str, default: f64) -> f64 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.trim().parse::<f64>().ok())
        .unwrap_or(default)
}

fn env_i64(name: &str, default: i64) -> i64 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.trim().parse::<i64>().ok())
        .unwrap_or(default)
}

fn env_list(name: &str, default: &[&str]) -> Vec<String> {
    std::env::var(name)
        .ok()
        .map(|value| {
            value
                .split(',')
                .map(normalize_mode)
                .filter(|value| !value.is_empty())
                .collect::<Vec<_>>()
        })
        .filter(|values| !values.is_empty())
        .unwrap_or_else(|| default.iter().map(|value| value.to_string()).collect())
}

fn change_request_arguments(arguments: serde_json::Value, action: &str) -> serde_json::Value {
    let mut body = arguments
        .as_object()
        .cloned()
        .unwrap_or_else(serde_json::Map::new);
    body.insert(
        "action".to_string(),
        serde_json::Value::String(action.to_string()),
    );
    body.insert(
        "source".to_string(),
        serde_json::Value::String("mcp".to_string()),
    );
    if !body.contains_key("targetMemoryIds") {
        let target = body
            .remove("targetMemoryId")
            .or_else(|| body.remove("memoryId"))
            .and_then(|value| value.as_str().map(ToOwned::to_owned));
        if let Some(target) = target {
            body.insert(
                "targetMemoryIds".to_string(),
                serde_json::Value::Array(vec![serde_json::Value::String(target)]),
            );
        }
    }
    serde_json::Value::Object(body)
}

fn list_query(arguments: serde_json::Value) -> Vec<(&'static str, String)> {
    let Some(arguments) = arguments.as_object() else {
        return Vec::new();
    };
    [
        "userId",
        "workspaceId",
        "repoId",
        "agentId",
        "sessionId",
        "kind",
        "status",
        "limit",
        "offset",
    ]
    .into_iter()
    .filter_map(|key| {
        arguments.get(key).and_then(|value| {
            value
                .as_str()
                .map(ToOwned::to_owned)
                .or_else(|| value.as_i64().map(|number| number.to_string()))
                .map(|value| (key, value))
        })
    })
    .collect()
}

fn tool_response(value: serde_json::Value, is_error: bool) -> serde_json::Value {
    serde_json::json!({
        "content": [
            {
                "type": "text",
                "text": serde_json::to_string_pretty(&value).unwrap_or_else(|_| value.to_string())
            }
        ],
        "isError": is_error
    })
}
