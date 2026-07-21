use agent_client_protocol::schema::v1::{
    AgentAuthCapabilities, AgentCapabilities, AuthMethod, AuthMethodAgent, AuthenticateRequest,
    AuthenticateResponse, CloseSessionRequest, CloseSessionResponse, ConfigOptionUpdate,
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
    ToolCallUpdateFields, ToolKind, WaitForTerminalExitRequest, WriteTextFileRequest,
};
use agent_client_protocol::{Agent, Client, ConnectionTo, Stdio};

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
            .on_receive_request(
                async move |request: InitializeRequest, responder, _connection| {
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
                    responder.respond(
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
                            .auth_methods(vec![AuthMethod::Agent(
                                AuthMethodAgent::new("fixture-auth", "Fixture authentication")
                                    .description("Authenticate through the fixture agent"),
                            )])
                            .agent_info(Implementation::new("ianvs-fixture-agent", "1.0.0")),
                    )
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
                        connection.send_notification(SessionNotification::new(
                            "fixture-session",
                            SessionUpdate::ConfigOptionUpdate(ConfigOptionUpdate::new(
                                fixture_config_options("quality"),
                            )),
                        ))?;
                    }
                    let result = responder.respond(
                        NewSessionResponse::new("fixture-session")
                            .modes(SessionModeState::new(
                                "default",
                                vec![
                                    SessionMode::new("default", "Default"),
                                    SessionMode::new("plan", "Plan"),
                                ],
                            ))
                            .config_options(fixture_config_options("fast")),
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
                    connection.send_notification(SessionNotification::new(
                        request.session_id,
                        SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                            TextContent::new("loaded fixture history"),
                        ))),
                    ))?;
                    responder.respond(
                        LoadSessionResponse::new()
                            .modes(SessionModeState::new(
                                "default",
                                vec![SessionMode::new("default", "Default")],
                            ))
                            .config_options(fixture_config_options("fast")),
                    )
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: ResumeSessionRequest, responder, _connection| {
                    responder.respond(
                        ResumeSessionResponse::new()
                            .modes(SessionModeState::new(
                                "default",
                                vec![SessionMode::new("default", "Default")],
                            ))
                            .config_options(fixture_config_options("fast")),
                    )
                },
                agent_client_protocol::on_receive_request!(),
            )
            .on_receive_request(
                async move |_request: ListSessionsRequest, responder, _connection| {
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
                        return responder.respond(PromptResponse::new(StopReason::EndTurn));
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
                    connection.spawn({
                        let connection = connection.clone();
                        async move {
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
                    let current = request
                        .value
                        .as_value_id()
                        .map_or_else(|| "fast".to_string(), ToString::to_string);
                    responder.respond(SetSessionConfigOptionResponse::new(fixture_config_options(
                        &current,
                    )))
                },
                agent_client_protocol::on_receive_request!(),
            )
            .connect_to(Stdio::new())
            .await
    })?;
    Ok(())
}

fn fixture_config_options(model: &str) -> Vec<SessionConfigOption> {
    vec![
        SessionConfigOption::select(
            "model",
            "Model",
            model.to_string(),
            vec![
                SessionConfigSelectOption::new("fast", "Fast"),
                SessionConfigSelectOption::new("quality", "Quality"),
            ],
        )
        .category(SessionConfigOptionCategory::Model),
        SessionConfigOption::boolean("auto_approve", "Auto approve", false),
    ]
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
