use agent_client_protocol::schema::v1::{
    AgentAuthCapabilities, AgentCapabilities, AuthMethod, AuthMethodAgent, AuthenticateRequest,
    AuthenticateResponse, AvailableCommand, AvailableCommandInput, AvailableCommandsUpdate,
    CancelNotification, CloseSessionRequest, CloseSessionResponse, ConfigOptionUpdate,
    ContentBlock, ContentChunk, CreateTerminalRequest, DeleteSessionRequest, DeleteSessionResponse,
    Implementation, InitializeRequest, InitializeResponse, KillTerminalRequest,
    ListSessionsRequest, ListSessionsResponse, LoadSessionRequest, LoadSessionResponse,
    LogoutCapabilities, LogoutRequest, LogoutResponse, McpCapabilities, McpServer,
    NewSessionRequest, NewSessionResponse, PermissionOption, PermissionOptionKind,
    PromptCapabilities, PromptRequest, PromptResponse, ReadTextFileRequest, ReleaseTerminalRequest,
    RequestPermissionOutcome, RequestPermissionRequest, ResumeSessionRequest,
    ResumeSessionResponse, SessionAdditionalDirectoriesCapabilities, SessionCapabilities,
    SessionCloseCapabilities, SessionConfigOption, SessionConfigOptionCategory,
    SessionConfigSelectOption, SessionDeleteCapabilities, SessionInfo, SessionListCapabilities,
    SessionMode, SessionModeState, SessionNotification, SessionResumeCapabilities, SessionUpdate,
    SetSessionConfigOptionRequest, SetSessionConfigOptionResponse, SetSessionModeRequest,
    SetSessionModeResponse, StopReason, TerminalOutputRequest, TextContent, ToolCallUpdate,
    ToolCallUpdateFields, ToolKind, UnstructuredCommandInput, WaitForTerminalExitRequest,
    WriteTextFileRequest,
};
use agent_client_protocol::{Agent, Client, ConnectionTo, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

#[derive(Clone)]
struct FixtureSessionConfig {
    model: String,
    reasoning_effort: String,
    fast_mode: String,
}

impl Default for FixtureSessionConfig {
    fn default() -> Self {
        Self {
            model: "fast".to_string(),
            reasoning_effort: "medium".to_string(),
            fast_mode: "off".to_string(),
        }
    }
}

static FIXTURE_SESSION_CONFIG: OnceLock<Mutex<FixtureSessionConfig>> = OnceLock::new();
static FIXTURE_PROMPT_CANCELLED: AtomicBool = AtomicBool::new(false);
static FIXTURE_SESSION_COUNTER: AtomicU64 = AtomicU64::new(0);

fn fixture_modes() -> SessionModeState {
    if std::env::var("IANVS_FIXTURE_OVERSIZED_MODES").as_deref() == Ok("1") {
        SessionModeState::new(
            "mode-0",
            (0..40)
                .map(|index| {
                    SessionMode::new(
                        format!("mode-{index}"),
                        format!("{index}-{}", "x".repeat(8 * 1024 - 8)),
                    )
                })
                .collect(),
        )
    } else {
        SessionModeState::new(
            "default",
            vec![
                SessionMode::new("default", "Default"),
                SessionMode::new("plan", "Plan"),
            ],
        )
    }
}

#[allow(clippy::too_many_lines)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    fail_once_if_requested();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async {
        Agent
            .builder()
            .name("ianvs-fixture-agent")
            .on_receive_notification(
                async move |_notification: CancelNotification, _connection| {
                    FIXTURE_PROMPT_CANCELLED.store(true, Ordering::Release);
                    Ok(())
                },
                agent_client_protocol::on_receive_notification!(),
            )
            .on_receive_request(
                async move |request: InitializeRequest,
                            responder,
                            connection: ConnectionTo<Client>| {
                    let prompt_attachments =
                        std::env::var("IANVS_FIXTURE_PROMPT_ATTACHMENTS").as_deref() == Ok("1");
                    if std::env::var("IANVS_FIXTURE_USE_TERMINAL").as_deref() == Ok("1")
                        && !request.client_capabilities.terminal
                    {
                        return responder.respond_with_internal_error(
                            "fixture requires the client terminal capability",
                        );
                    }
                    if std::env::var("IANVS_FIXTURE_USE_FILESYSTEM").as_deref() == Ok("1")
                        && (!request.client_capabilities.fs.read_text_file
                            || !request.client_capabilities.fs.write_text_file)
                    {
                        return responder.respond_with_internal_error(
                            "fixture requires both client filesystem capabilities",
                        );
                    }
                    let auth_methods = if std::env::var("IANVS_FIXTURE_OVERSIZED_AUTH_METHODS")
                        .as_deref()
                        == Ok("1")
                    {
                        (0..33)
                            .map(|index| {
                                AuthMethod::Agent(AuthMethodAgent::new(
                                    format!("fixture-auth-{index}"),
                                    "Fixture authentication",
                                ))
                            })
                            .collect()
                    } else {
                        vec![AuthMethod::Agent(
                            AuthMethodAgent::new("fixture-auth", "Fixture authentication")
                                .description("Authenticate through the fixture agent"),
                        )]
                    };
                    let agent_name = if std::env::var("IANVS_FIXTURE_OVERSIZED_AGENT_INFO")
                        .as_deref()
                        == Ok("1")
                    {
                        "x".repeat(20 * 1024)
                    } else {
                        "ianvs-fixture-agent".to_string()
                    };
                    let result = responder.respond(
                        InitializeResponse::new(request.protocol_version)
                            .agent_capabilities(
                                AgentCapabilities::new()
                                    .load_session(true)
                                    .prompt_capabilities(
                                        PromptCapabilities::new()
                                            .image(prompt_attachments)
                                            .audio(prompt_attachments)
                                            .embedded_context(prompt_attachments),
                                    )
                                    .mcp_capabilities(
                                        if std::env::var("IANVS_FIXTURE_MCP").as_deref() == Ok("1")
                                        {
                                            McpCapabilities::new().http(true).sse(true)
                                        } else {
                                            McpCapabilities::new()
                                        },
                                    )
                                    .session_capabilities(
                                        SessionCapabilities::new()
                                            .list(SessionListCapabilities::new())
                                            .resume(SessionResumeCapabilities::new())
                                            .close(SessionCloseCapabilities::new())
                                            .delete(SessionDeleteCapabilities::new())
                                            .additional_directories(
                                                SessionAdditionalDirectoriesCapabilities::new(),
                                            ),
                                    )
                                    .auth(
                                        AgentAuthCapabilities::new()
                                            .logout(LogoutCapabilities::new()),
                                    ),
                            )
                            .auth_methods(auth_methods)
                            .agent_info(Implementation::new(agent_name, "1.0.0")),
                    );
                    if result.is_ok()
                        && std::env::var("IANVS_FIXTURE_BOGUS_CONFIG_NOTIFICATION").as_deref()
                            == Ok("1")
                    {
                        connection.send_notification(SessionNotification::new(
                            "bogus-session",
                            SessionUpdate::ConfigOptionUpdate(ConfigOptionUpdate::new(
                                fixture_config_options(),
                            )),
                        ))?;
                    }
                    result
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: NewSessionRequest,
                            responder,
                            connection: ConnectionTo<Client>| {
                    if std::env::var("IANVS_FIXTURE_MCP").as_deref() == Ok("1") {
                        let transports = request
                            .mcp_servers
                            .iter()
                            .map(|server| match server {
                                McpServer::Stdio(server) => {
                                    format!("stdio:{}:{}", server.name, server.command.display())
                                }
                                McpServer::Http(server) => {
                                    format!("http:{}:{}", server.name, server.url)
                                }
                                McpServer::Sse(server) => {
                                    format!("sse:{}:{}", server.name, server.url)
                                }
                                _ => "unstable".to_string(),
                            })
                            .collect::<Vec<_>>();
                        if transports
                            != [
                                "stdio:local-mcp:mcp-command",
                                "http:http-mcp:https://example.test/mcp",
                                "sse:sse-mcp:https://example.test/sse",
                            ]
                        {
                            return responder.respond_with_internal_error(format!(
                                "unexpected MCP projection: {transports:?}"
                            ));
                        }
                    }
                    if std::env::var("IANVS_FIXTURE_CONFIG_UPDATE_AFTER_NEW").as_deref() == Ok("1")
                    {
                        update_fixture_config("model", "quality");
                        connection.send_notification(SessionNotification::new(
                            "fixture-session",
                            SessionUpdate::ConfigOptionUpdate(ConfigOptionUpdate::new(
                                fixture_config_options(),
                            )),
                        ))?;
                    }
                    let fixture_session_index =
                        FIXTURE_SESSION_COUNTER.fetch_add(1, Ordering::Relaxed) + 1;
                    let fixture_session_id = if std::env::var("IANVS_FIXTURE_DUPLICATE_SESSION_ID")
                        .as_deref()
                        == Ok("1")
                        || fixture_session_index == 1
                    {
                        "fixture-session".to_string()
                    } else {
                        format!("fixture-session-{fixture_session_index}")
                    };
                    if std::env::var("IANVS_FIXTURE_COMMANDS_AFTER_NEW").as_deref() == Ok("1") {
                        connection.send_notification(SessionNotification::new(
                            fixture_session_id.clone(),
                            SessionUpdate::AvailableCommandsUpdate(AvailableCommandsUpdate::new(
                                vec![
                                    AvailableCommand::new("review", "Review the current change.")
                                        .input(AvailableCommandInput::Unstructured(
                                            UnstructuredCommandInput::new("[focus]"),
                                        )),
                                ],
                            )),
                        ))?;
                    }
                    let result = responder.respond(
                        NewSessionResponse::new(fixture_session_id)
                            .modes(fixture_modes())
                            .config_options(fixture_config_options()),
                    );
                    if std::env::var("IANVS_FIXTURE_EXIT_AFTER_NEW_SESSION").as_deref() == Ok("1") {
                        std::thread::spawn(|| {
                            std::thread::sleep(std::time::Duration::from_millis(50));
                            std::process::exit(43);
                        });
                    }
                    result
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: LoadSessionRequest,
                            responder,
                            connection: ConnectionTo<Client>| {
                    if std::env::var("IANVS_FIXTURE_FAIL_LOAD_SESSION").as_deref()
                        == Ok(request.session_id.to_string().as_str())
                    {
                        return responder
                            .respond_with_internal_error("fixture rejected persisted session");
                    }
                    connection.send_notification(SessionNotification::new(
                        request.session_id,
                        SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                            TextContent::new("loaded fixture history"),
                        ))),
                    ))?;
                    responder.respond(
                        LoadSessionResponse::new()
                            .modes(fixture_modes())
                            .config_options(fixture_config_options()),
                    )
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: ResumeSessionRequest, responder, _connection| {
                    responder.respond(
                        ResumeSessionResponse::new()
                            .modes(fixture_modes())
                            .config_options(fixture_config_options()),
                    )
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: ListSessionsRequest, responder, _connection| {
                    if std::env::var("IANVS_FIXTURE_OVERSIZED_CATALOG").as_deref() == Ok("1") {
                        return responder.respond(ListSessionsResponse::new(vec![
                            SessionInfo::new(
                                "fixture-session",
                                std::path::PathBuf::from("x".repeat(40 * 1024)),
                            ),
                        ]));
                    }
                    responder.respond(ListSessionsResponse::new(vec![
                        SessionInfo::new("fixture-session", std::env::temp_dir())
                            .title("Fixture session")
                            .updated_at("2026-07-17T10:00:00Z"),
                    ]))
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: CloseSessionRequest, responder, _connection| {
                    responder.respond(CloseSessionResponse::new())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: DeleteSessionRequest, responder, _connection| {
                    responder.respond(DeleteSessionResponse::new())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: AuthenticateRequest, responder, _connection| {
                    responder.respond(AuthenticateResponse::new())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: LogoutRequest, responder, _connection| {
                    responder.respond(LogoutResponse::new())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: PromptRequest, responder, connection: ConnectionTo<Client>| {
                    FIXTURE_PROMPT_CANCELLED.store(false, Ordering::Release);
                    let session_id = request.session_id.clone();
                    if std::env::var("IANVS_FIXTURE_PROMPT_ATTACHMENTS").as_deref() == Ok("1") {
                        let kinds = request
                            .prompt
                            .iter()
                            .map(|block| match block {
                                ContentBlock::Text(_) => "text",
                                ContentBlock::Image(_) => "image",
                                ContentBlock::Audio(_) => "audio",
                                ContentBlock::Resource(_) => "resource",
                                ContentBlock::ResourceLink(_) => "resource_link",
                                _ => "unknown",
                            })
                            .collect::<Vec<_>>()
                            .join(",");
                        connection.send_notification(SessionNotification::new(
                            session_id,
                            SessionUpdate::AgentMessageChunk(ContentChunk::new(
                                ContentBlock::Text(TextContent::new(format!("content:{kinds}"))),
                            )),
                        ))?;
                        connection.spawn(async move {
                            let stop_reason = if fixture_response_delay().await {
                                StopReason::Cancelled
                            } else {
                                StopReason::EndTurn
                            };
                            responder.respond(PromptResponse::new(stop_reason))
                        })?;
                        return Ok(());
                    }
                    if std::env::var("IANVS_FIXTURE_USE_FILESYSTEM").as_deref() == Ok("1") {
                        connection.spawn({
                            let connection = connection.clone();
                            async move {
                                let read = connection
                                    .send_request(
                                        ReadTextFileRequest::new(session_id.clone(), "input.txt")
                                            .line(2)
                                            .limit(1),
                                    )
                                    .block_task()
                                    .await?;
                                connection
                                    .send_request(WriteTextFileRequest::new(
                                        session_id.clone(),
                                        "output.txt",
                                        format!("copy:{}", read.content),
                                    ))
                                    .block_task()
                                    .await?;
                                connection.send_notification(SessionNotification::new(
                                    session_id,
                                    SessionUpdate::AgentMessageChunk(ContentChunk::new(
                                        ContentBlock::Text(TextContent::new(format!(
                                            "filesystem:{}",
                                            read.content.trim()
                                        ))),
                                    )),
                                ))?;
                                responder.respond(PromptResponse::new(StopReason::EndTurn))
                            }
                        })?;
                        return Ok(());
                    }
                    if std::env::var("IANVS_FIXTURE_USE_TERMINAL").as_deref() == Ok("1") {
                        connection.spawn({
                            let connection = connection.clone();
                            async move {
                                let created = connection
                                    .send_request(
                                        CreateTerminalRequest::new(session_id.clone(), "/bin/echo")
                                            .args(vec!["fixture-terminal".to_string()])
                                            .output_byte_limit(64),
                                    )
                                    .block_task()
                                    .await?;
                                let terminal_id = created.terminal_id;
                                let exit = connection
                                    .send_request(WaitForTerminalExitRequest::new(
                                        session_id.clone(),
                                        terminal_id.clone(),
                                    ))
                                    .block_task()
                                    .await?;
                                let output = connection
                                    .send_request(TerminalOutputRequest::new(
                                        session_id.clone(),
                                        terminal_id.clone(),
                                    ))
                                    .block_task()
                                    .await?;
                                connection
                                    .send_request(KillTerminalRequest::new(
                                        session_id.clone(),
                                        terminal_id.clone(),
                                    ))
                                    .block_task()
                                    .await?;
                                connection
                                    .send_request(ReleaseTerminalRequest::new(
                                        session_id.clone(),
                                        terminal_id,
                                    ))
                                    .block_task()
                                    .await?;
                                connection.send_notification(SessionNotification::new(
                                    session_id,
                                    SessionUpdate::AgentMessageChunk(ContentChunk::new(
                                        ContentBlock::Text(TextContent::new(format!(
                                            "terminal:{}:{}:{}",
                                            output.output.trim(),
                                            exit.exit_status.exit_code.unwrap_or(u32::MAX),
                                            output.truncated,
                                        ))),
                                    )),
                                ))?;
                                responder.respond(PromptResponse::new(StopReason::EndTurn))
                            }
                        })?;
                        return Ok(());
                    }
                    if let Some(permission_count) = std::env::var("IANVS_FIXTURE_PERMISSION_FLOOD")
                        .ok()
                        .and_then(|value| value.parse::<usize>().ok())
                    {
                        connection.spawn({
                            let connection = connection.clone();
                            async move {
                                let mut requests = Vec::with_capacity(permission_count);
                                for index in 0..permission_count {
                                    requests.push(
                                        connection
                                            .send_request(RequestPermissionRequest::new(
                                                session_id.clone(),
                                                ToolCallUpdate::new(
                                                    format!("fixture-flood-{index}"),
                                                    ToolCallUpdateFields::new()
                                                        .title(format!("Flood permission {index}"))
                                                        .kind(ToolKind::Other),
                                                ),
                                                vec![PermissionOption::new(
                                                    "allow-once",
                                                    "Allow once",
                                                    PermissionOptionKind::AllowOnce,
                                                )],
                                            ))
                                            .block_task(),
                                    );
                                }
                                let results = futures::future::join_all(requests).await;
                                let accepted =
                                    results.iter().filter(|result| result.is_ok()).count();
                                let rejected = results.len().saturating_sub(accepted);
                                connection.send_notification(SessionNotification::new(
                                    session_id,
                                    SessionUpdate::AgentMessageChunk(ContentChunk::new(
                                        ContentBlock::Text(TextContent::new(format!(
                                            "permission-flood:{accepted}:{rejected}"
                                        ))),
                                    )),
                                ))?;
                                responder.respond(PromptResponse::new(StopReason::EndTurn))
                            }
                        })?;
                        return Ok(());
                    }
                    connection.spawn({
                        let connection = connection.clone();
                        async move {
                            if std::env::var("IANVS_FIXTURE_SKIP_PERMISSION").as_deref() == Ok("1")
                            {
                                connection.send_notification(SessionNotification::new(
                                    session_id,
                                    SessionUpdate::AgentMessageChunk(ContentChunk::new(
                                        ContentBlock::Text(TextContent::new(
                                            "headless fixture complete".to_string(),
                                        )),
                                    )),
                                ))?;
                                return responder.respond(PromptResponse::new(StopReason::EndTurn));
                            }
                            let tool_call = ToolCallUpdate::new(
                                "fixture-tool",
                                ToolCallUpdateFields::new()
                                    .title("Write fixture output")
                                    .kind(ToolKind::Edit)
                                    .raw_input(serde_json::json!({"path": "fixture.txt"})),
                            );
                            let permission = connection
                                .send_request(RequestPermissionRequest::new(
                                    session_id.clone(),
                                    tool_call,
                                    vec![
                                        PermissionOption::new(
                                            "allow-once",
                                            "Allow once",
                                            PermissionOptionKind::AllowOnce,
                                        ),
                                        PermissionOption::new(
                                            "reject-once",
                                            "Reject",
                                            PermissionOptionKind::RejectOnce,
                                        ),
                                    ],
                                ))
                                .block_task()
                                .await?;
                            let text = match permission.outcome {
                                RequestPermissionOutcome::Selected(selected) => {
                                    format!("permission:{}", selected.option_id)
                                }
                                RequestPermissionOutcome::Cancelled => {
                                    "permission:cancelled".to_string()
                                }
                                _ => "permission:unknown".to_string(),
                            };
                            connection.send_notification(SessionNotification::new(
                                session_id,
                                SessionUpdate::AgentMessageChunk(ContentChunk::new(
                                    ContentBlock::Text(TextContent::new(text)),
                                )),
                            ))?;
                            responder.respond(PromptResponse::new(StopReason::EndTurn))
                        }
                    })?;
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: SetSessionModeRequest, responder, _connection| {
                    responder.respond(SetSessionModeResponse::new())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |request: SetSessionConfigOptionRequest, responder, _connection| {
                    let value = request
                        .value
                        .as_value_id()
                        .map_or_else(|| "fast".to_string(), ToString::to_string);
                    update_fixture_config(&request.config_id.to_string(), &value);
                    responder.respond(SetSessionConfigOptionResponse::new(fixture_config_options()))
                },
                agent_client_protocol::on_receive_request!(),
            )
            .connect_to(Stdio::new())
            .await
    })?;
    Ok(())
}

fn fixture_config_options() -> Vec<SessionConfigOption> {
    let config = fixture_session_config();
    vec![
        SessionConfigOption::select(
            "model",
            "Model",
            config.model,
            vec![
                SessionConfigSelectOption::new("fast", "Fast"),
                SessionConfigSelectOption::new("quality", "Quality"),
                SessionConfigSelectOption::new("vision", "Vision"),
            ],
        )
        .category(SessionConfigOptionCategory::Model),
        SessionConfigOption::select(
            "reasoning_effort",
            "Reasoning effort",
            config.reasoning_effort,
            vec![
                SessionConfigSelectOption::new("low", "Low"),
                SessionConfigSelectOption::new("medium", "Medium"),
                SessionConfigSelectOption::new("high", "High"),
                SessionConfigSelectOption::new("xhigh", "Extra high"),
            ],
        )
        .category(SessionConfigOptionCategory::ThoughtLevel),
        SessionConfigOption::select(
            "fast_mode",
            "Speed",
            config.fast_mode,
            vec![
                SessionConfigSelectOption::new("off", "Standard")
                    .description("Default speed, normal usage"),
                SessionConfigSelectOption::new("on", "Fast")
                    .description("1.5x speed, increased usage"),
            ],
        )
        .category(SessionConfigOptionCategory::ModelConfig),
        SessionConfigOption::boolean("auto_approve", "Auto approve", false),
    ]
}

fn fixture_session_config() -> FixtureSessionConfig {
    FIXTURE_SESSION_CONFIG
        .get_or_init(|| Mutex::new(FixtureSessionConfig::default()))
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone()
}

fn update_fixture_config(config_id: &str, value: &str) {
    let mut config = FIXTURE_SESSION_CONFIG
        .get_or_init(|| Mutex::new(FixtureSessionConfig::default()))
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    match config_id {
        "model" => config.model = value.to_string(),
        "reasoning_effort" => config.reasoning_effort = value.to_string(),
        "fast_mode" => config.fast_mode = value.to_string(),
        _ => {}
    }
}

fn fail_once_if_requested() {
    let Ok(path) = std::env::var("IANVS_FIXTURE_FAIL_ONCE_FILE") else {
        return;
    };
    if path.trim().is_empty() {
        return;
    }
    if std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .is_ok()
    {
        eprintln!("fixture intentionally exiting before initialize");
        std::process::exit(42);
    }
}

async fn fixture_response_delay() -> bool {
    let milliseconds = std::env::var("IANVS_FIXTURE_RESPONSE_DELAY_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or_default();
    let mut remaining = milliseconds;
    while remaining > 0 {
        if FIXTURE_PROMPT_CANCELLED.load(Ordering::Acquire) {
            return true;
        }
        let slice = remaining.min(25);
        tokio::time::sleep(std::time::Duration::from_millis(slice)).await;
        remaining -= slice;
    }
    FIXTURE_PROMPT_CANCELLED.load(Ordering::Acquire)
}
