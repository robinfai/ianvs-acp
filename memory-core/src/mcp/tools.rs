use super::daemon_client::DaemonClient;

pub fn tools_list() -> serde_json::Value {
    serde_json::json!({
        "tools": [
            {
                "name": "memory.search",
                "description": "Search approved long-term memory.",
                "inputSchema": search_schema()
            },
            {
                "name": "memory.remember",
                "description": "Propose memory; auto-approve when confidence meets policy, otherwise skip below-threshold proposals.",
                "inputSchema": remember_schema()
            },
            {
                "name": "memory.list",
                "description": "List approved memory.",
                "inputSchema": list_schema()
            },
            {
                "name": "memory.update",
                "description": "Update memory; auto-apply high-confidence requests when policy is supplied, otherwise create a pending request.",
                "inputSchema": update_schema()
            },
            {
                "name": "memory.forget",
                "description": "Forget memory; high-confidence deletes stay pending for review and low-confidence requests can be skipped by policy.",
                "inputSchema": forget_schema()
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
        "memory.remember" => {
            client
                .post_json(
                    "/v1/memory/extract-candidates",
                    remember_arguments(arguments),
                )
                .await
        }
        "memory.update" => call_change_request_tool(client, arguments, "update").await,
        "memory.forget" => call_change_request_tool(client, arguments, "delete").await,
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

fn search_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "Natural language query for relevant approved memory."
            },
            "scope": scope_schema(),
            "limit": {
                "type": "integer",
                "minimum": 1,
                "maximum": 50,
                "description": "Maximum memories to return."
            }
        },
        "required": ["query", "scope"],
        "additionalProperties": false
    })
}

fn remember_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "object",
        "properties": {
            "scope": scope_schema(),
            "kind": memory_kind_schema(),
            "memoryScope": memory_scope_schema(),
            "text": {
                "type": "string",
                "description": "Durable memory text to propose."
            },
            "reason": {
                "type": "string",
                "description": "Why this memory should be retained."
            },
            "confidence": confidence_schema(),
            "autoApproveThreshold": confidence_schema()
        },
        "required": ["scope", "kind", "memoryScope", "text"],
        "additionalProperties": false
    })
}

fn list_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "object",
        "properties": {
            "scope": scope_schema(),
            "userId": {
                "type": "string",
                "description": "Legacy user id whose memory should be listed."
            },
            "repoId": {
                "type": "string",
                "description": "Legacy repository scope to list."
            },
            "status": {
                "type": "string",
                "enum": ["active", "disabled", "deleted"],
                "description": "Memory status filter."
            }
        },
        "additionalProperties": false
    })
}

fn update_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "object",
        "properties": {
            "scope": scope_schema(),
            "targetMemoryId": {
                "type": "string",
                "description": "Approved memory id to update after review."
            },
            "proposedKind": memory_kind_schema(),
            "proposedScope": memory_scope_schema(),
            "proposedText": {
                "type": "string",
                "description": "Replacement memory text to review."
            },
            "reason": {
                "type": "string",
                "description": "Why this update is useful."
            },
            "confidence": confidence_schema(),
            "autoApproveThreshold": confidence_schema()
        },
        "required": ["scope", "targetMemoryId", "proposedText"],
        "additionalProperties": false
    })
}

fn forget_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "object",
        "properties": {
            "scope": scope_schema(),
            "targetMemoryId": {
                "type": "string",
                "description": "Approved memory id to delete after review."
            },
            "reason": {
                "type": "string",
                "description": "Why this memory should be forgotten."
            },
            "confidence": confidence_schema(),
            "autoApproveThreshold": confidence_schema()
        },
        "required": ["scope", "targetMemoryId"],
        "additionalProperties": false
    })
}

fn scope_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "object",
        "properties": {
            "userId": {
                "type": "string",
                "description": "Stable local user id."
            },
            "workspaceId": {
                "type": "string",
                "description": "Workspace path or id."
            },
            "repoId": {
                "type": "string",
                "description": "Repository path or id."
            },
            "agentId": {
                "type": "string",
                "description": "Agent id for agent-scoped session memory."
            },
            "sessionId": {
                "type": "string",
                "description": "ACP session id for session-scoped memory."
            }
        },
        "required": ["userId"],
        "additionalProperties": false
    })
}

fn memory_kind_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "string",
        "enum": [
            "user_preference",
            "project_rule",
            "architecture_decision",
            "session_summary"
        ]
    })
}

fn memory_scope_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "string",
        "enum": ["global", "workspace", "repo", "session"]
    })
}

fn confidence_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "number",
        "minimum": 0,
        "maximum": 1
    })
}

fn remember_arguments(arguments: serde_json::Value) -> serde_json::Value {
    let Some(input) = arguments.as_object() else {
        return arguments;
    };
    if input.contains_key("preExtractedCandidates") {
        return arguments;
    }

    let mut candidate = serde_json::Map::new();
    copy_json_field(input, &mut candidate, "kind", "kind");
    copy_json_field(input, &mut candidate, "memoryScope", "scope");
    copy_json_field(input, &mut candidate, "text", "text");
    copy_json_field(input, &mut candidate, "confidence", "confidence");
    copy_json_field(input, &mut candidate, "reason", "reason");

    let mut body = serde_json::Map::new();
    copy_json_field(input, &mut body, "scope", "scope");
    if input.contains_key("autoApproveThreshold") {
        copy_json_field(
            input,
            &mut body,
            "autoApproveThreshold",
            "autoApproveThreshold",
        );
    } else if let Some(threshold) = default_auto_approve_threshold() {
        body.insert("autoApproveThreshold".to_string(), threshold);
    }
    body.insert(
        "preExtractedCandidates".to_string(),
        serde_json::Value::Array(vec![serde_json::Value::Object(candidate)]),
    );
    serde_json::Value::Object(body)
}

fn default_auto_approve_threshold() -> Option<serde_json::Value> {
    let threshold = default_auto_approve_threshold_number()?;
    serde_json::Number::from_f64(threshold).map(serde_json::Value::Number)
}

fn default_auto_approve_threshold_number() -> Option<f64> {
    let value = std::env::var("MEMORY_AUTO_APPROVE_THRESHOLD").ok()?;
    valid_confidence(value.trim().parse::<f64>().ok()?)
}

fn default_change_request_auto_approve_threshold_number() -> Option<f64> {
    std::env::var("MEMORY_CHANGE_REQUEST_AUTO_APPROVE_THRESHOLD")
        .ok()
        .and_then(|value| valid_confidence(value.trim().parse::<f64>().ok()?))
        .or_else(default_auto_approve_threshold_number)
}

async fn call_change_request_tool(
    client: &DaemonClient,
    arguments: serde_json::Value,
    action: &str,
) -> anyhow::Result<serde_json::Value> {
    if let Some(threshold) = change_request_auto_threshold(&arguments) {
        return client
            .post_json(
                "/v1/memory/maintenance/run",
                maintenance_change_request_arguments(arguments, action, threshold),
            )
            .await;
    }

    client
        .post_json(
            "/v1/memory/change-requests",
            change_request_arguments(arguments, action),
        )
        .await
}

fn change_request_auto_threshold(arguments: &serde_json::Value) -> Option<f64> {
    let input = arguments.as_object()?;
    input
        .get("autoApproveThreshold")
        .and_then(|value| value.as_f64())
        .and_then(valid_confidence)
        .or_else(default_change_request_auto_approve_threshold_number)
}

fn valid_confidence(value: f64) -> Option<f64> {
    if (0.0..=1.0).contains(&value) {
        Some(value)
    } else {
        None
    }
}

fn maintenance_change_request_arguments(
    arguments: serde_json::Value,
    action: &str,
    threshold: f64,
) -> serde_json::Value {
    let input = arguments
        .as_object()
        .cloned()
        .unwrap_or_else(serde_json::Map::new);
    let threshold = serde_json::Number::from_f64(threshold)
        .map(serde_json::Value::Number)
        .unwrap_or_else(|| serde_json::json!(0.9));

    let mut suggestion = serde_json::Map::new();
    suggestion.insert(
        "action".to_string(),
        serde_json::Value::String(action.to_string()),
    );
    suggestion.insert(
        "source".to_string(),
        serde_json::Value::String("mcp".to_string()),
    );
    if let Some(target_ids) = input.get("targetMemoryIds") {
        suggestion.insert("targetMemoryIds".to_string(), target_ids.clone());
    } else if let Some(target_id) = input.get("targetMemoryId") {
        suggestion.insert(
            "targetMemoryIds".to_string(),
            serde_json::Value::Array(vec![target_id.clone()]),
        );
    }
    copy_json_field(&input, &mut suggestion, "proposedKind", "proposedKind");
    copy_json_field(&input, &mut suggestion, "proposedScope", "proposedScope");
    copy_json_field(&input, &mut suggestion, "proposedText", "proposedText");
    copy_json_field(&input, &mut suggestion, "confidence", "confidence");
    copy_json_field(&input, &mut suggestion, "reason", "reason");

    let mut body = serde_json::Map::new();
    copy_json_field(&input, &mut body, "scope", "scope");
    body.insert("enabled".to_string(), serde_json::Value::Bool(true));
    body.insert(
        "mode".to_string(),
        serde_json::Value::String("high_confidence_auto".to_string()),
    );
    body.insert(
        "costMode".to_string(),
        serde_json::Value::String("low_cost".to_string()),
    );
    body.insert("highConfidenceThreshold".to_string(), threshold.clone());
    body.insert("reviewThreshold".to_string(), threshold);
    body.insert(
        "manualOnlyActions".to_string(),
        serde_json::Value::Array(
            ["delete", "disable", "expire"]
                .into_iter()
                .map(|action| serde_json::Value::String(action.to_string()))
                .collect(),
        ),
    );
    body.insert(
        "preExtractedChangeRequests".to_string(),
        serde_json::Value::Array(vec![serde_json::Value::Object(suggestion)]),
    );
    serde_json::Value::Object(body)
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
    body.entry("source".to_string())
        .or_insert_with(|| serde_json::Value::String("mcp".to_string()));
    serde_json::Value::Object(body)
}

fn copy_json_field(
    source: &serde_json::Map<String, serde_json::Value>,
    destination: &mut serde_json::Map<String, serde_json::Value>,
    from: &str,
    to: &str,
) {
    if let Some(value) = source.get(from) {
        destination.insert(to.to_string(), value.clone());
    }
}

fn list_query(arguments: serde_json::Value) -> Vec<(&'static str, String)> {
    let Some(arguments) = arguments.as_object() else {
        return Vec::new();
    };
    if let Some(scope) = arguments.get("scope").and_then(|value| value.as_object()) {
        let mut query = vec![("visible", "true".to_string())];
        for key in ["userId", "workspaceId", "repoId", "agentId", "sessionId"] {
            if let Some(value) = scope.get(key).and_then(|value| value.as_str()) {
                query.push((key, value.to_string()));
            }
        }
        if let Some(status) = arguments.get("status").and_then(|value| value.as_str()) {
            query.push(("status", status.to_string()));
        }
        return query;
    }
    ["userId", "repoId", "status"]
        .into_iter()
        .filter_map(|key| {
            arguments
                .get(key)
                .and_then(|value| value.as_str())
                .map(|value| (key, value.to_string()))
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
