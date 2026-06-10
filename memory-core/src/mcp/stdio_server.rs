use tokio::io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader};

use super::daemon_client::DaemonClient;

pub async fn run(client: DaemonClient) -> anyhow::Result<()> {
    let stdin = BufReader::new(io::stdin());
    let mut lines = stdin.lines();
    let mut stdout = io::stdout();
    while let Some(line) = lines.next_line().await? {
        let request: serde_json::Value = serde_json::from_str(&line)?;
        let id = request
            .get("id")
            .cloned()
            .unwrap_or(serde_json::Value::Null);
        let method = request
            .get("method")
            .and_then(|value| value.as_str())
            .unwrap_or("");
        let result = match method {
            "tools/list" => crate::mcp::tools::tools_list(),
            "tools/call" => {
                let params = request
                    .get("params")
                    .cloned()
                    .unwrap_or_else(|| serde_json::json!({}));
                let name = params
                    .get("name")
                    .and_then(|value| value.as_str())
                    .unwrap_or("");
                let arguments = params
                    .get("arguments")
                    .cloned()
                    .unwrap_or_else(|| serde_json::json!({}));
                crate::mcp::tools::call_tool(&client, name, arguments).await
            }
            _ => serde_json::json!({"error": "unsupported method"}),
        };
        let response = serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        });
        stdout.write_all(response.to_string().as_bytes()).await?;
        stdout.write_all(b"\n").await?;
        stdout.flush().await?;
    }
    drop(client);
    Ok(())
}
