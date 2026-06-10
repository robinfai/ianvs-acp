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
            },
            {
                "name": "memory.update",
                "description": "Create a pending memory update request.",
                "inputSchema": { "type": "object" }
            },
            {
                "name": "memory.forget",
                "description": "Create a pending memory delete request.",
                "inputSchema": { "type": "object" }
            }
        ]
    })
}
