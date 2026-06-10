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
                "description": "Create a pending memory candidate.",
                "inputSchema": { "type": "object" }
            },
            {
                "name": "memory.list",
                "description": "List approved memory.",
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
        "memory.remember" => {
            client
                .post_json("/v1/memory/extract-candidates", arguments)
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

fn list_query(arguments: serde_json::Value) -> Vec<(&'static str, String)> {
    let Some(arguments) = arguments.as_object() else {
        return Vec::new();
    };
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
