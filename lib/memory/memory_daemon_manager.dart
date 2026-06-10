import 'dart:convert';

class MemoryDaemonReady {
  const MemoryDaemonReady({required this.port});

  final int port;

  String get baseUrl => 'http://127.0.0.1:$port';

  factory MemoryDaemonReady.fromStdoutLine(String line) {
    final decoded = jsonDecode(line);
    if (decoded is! Map || decoded['type'] != 'ready') {
      throw const FormatException('Expected memory daemon ready JSON.');
    }
    final port = decoded['port'];
    if (port is! int || port <= 0) {
      throw const FormatException('Memory daemon ready JSON missing port.');
    }
    return MemoryDaemonReady(port: port);
  }
}

class MemoryDaemonLaunch {
  const MemoryDaemonLaunch({
    required this.executable,
    required this.dataDir,
    required this.token,
  });

  final String executable;
  final String dataDir;
  final String token;

  List<String> get args => <String>[
    '--mode',
    'daemon',
    '--host',
    '127.0.0.1',
    '--port',
    '0',
    '--data-dir',
    dataDir,
  ];

  Map<String, String> get env => <String, String>{'MEMORY_DAEMON_TOKEN': token};
}
