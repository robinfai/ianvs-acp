enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  sessionReady,
  streaming,
  error,
  reconnecting,
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
