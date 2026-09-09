enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  sessionReady,
  streaming,
  error,
  reconnecting,
}

enum NewSessionStage {
  connecting,
  creating,
  configuring,
  applyingTemplate;

  String get label => switch (this) {
    connecting => '正在连接 Agent 并完成握手…',
    creating => '正在创建会话…',
    configuring => '正在加载会话命令与配置…',
    applyingTemplate => '正在应用会话模板…',
  };
}

extension ConnectionStatusLabel on ConnectionStatus {
  String get label => switch (this) {
    ConnectionStatus.disconnected => 'disconnected',
    ConnectionStatus.connecting => 'connecting',
    ConnectionStatus.connected => 'connected',
    ConnectionStatus.sessionReady => 'session ready',
    ConnectionStatus.streaming => 'streaming',
    ConnectionStatus.error => 'error',
    ConnectionStatus.reconnecting => 'reconnecting',
  };
}
