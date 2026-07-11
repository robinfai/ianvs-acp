import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as mcp;

import '../config/acp_client_config.dart';
import 'acp_agent_client.dart';
import 'acp_endpoint_validator.dart';
import 'acp_permission_request.dart';
import 'agent_event.dart';
import 'agent_session.dart';
import 'no_redirect_mcp_http_transport.dart';

abstract class AcpPermissionReviewer {
  bool get canAutoApprove => false;

  Future<AcpPermissionReviewResult?> review(
    AcpPermissionRequest request, {
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
    String? model,
  });

  Future<void> dispose() async {}
}

typedef AcpAgentClientFactory = AcpAgentClient Function();

class AcpAgentPermissionReviewer extends AcpPermissionReviewer {
  AcpAgentPermissionReviewer({
    required this.agentName,
    required this.clientFactory,
    this.modelOverride,
    this.timeout = const Duration(seconds: 10),
  });

  final String agentName;
  final AcpAgentClientFactory clientFactory;
  final String? modelOverride;
  final Duration timeout;

  AcpAgentClient? _client;
  AgentSession? _session;
  String? _sessionWorkspaceRoot;
  List<String> _sessionAdditionalDirectories = const <String>[];

  @override
  Future<AcpPermissionReviewResult?> review(
    AcpPermissionRequest request, {
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
    String? model,
  }) async {
    final effectiveModel = modelOverride ?? model;
    final directories = _normalizedDirectories(additionalDirectories);
    final payload = acpPermissionReviewPayload(
      request,
      workspaceRoot: workspaceRoot,
      additionalDirectories: directories,
      model: effectiveModel,
    );

    try {
      return await (() async {
        final client = await _ensureClient();
        final session = await _ensureSession(
          client,
          workspaceRoot,
          directories,
        );
        await _syncModel(client, session.id, effectiveModel);
        final response = await _reviewWithAgent(client, session.id, payload);
        final data = _reviewDataFromText(response);
        return AcpPermissionReviewResult(
          decision: _reviewDecisionFromData(data),
          risk:
              _reviewStringField(data, const [
                'risk',
                'riskLevel',
                'severity',
              ]) ??
              'unknown',
          rationale:
              _reviewStringField(data, const [
                'rationale',
                'reason',
                'summary',
              ]) ??
              response.trim(),
          reviewer:
              _reviewStringField(data, const ['reviewer', 'reviewAgent']) ??
              agentName,
          model: _reviewStringField(data, const ['model']) ?? effectiveModel,
          details: <String, Object?>{
            if (data.isNotEmpty) 'raw': data,
            'localAnalysis': payload['analysis'],
          },
        );
      }()).timeout(timeout);
    } catch (error) {
      await _resetClient();
      return AcpPermissionReviewResult(
        risk: 'unknown',
        rationale: 'Review agent failed: $error',
        reviewer: agentName,
        model: effectiveModel,
        details: <String, Object?>{
          'error': error.toString(),
          'localAnalysis': payload['analysis'],
        },
      );
    }
  }

  Future<AcpAgentClient> _ensureClient() async {
    final existing = _client;
    if (existing != null) return existing;

    final client = clientFactory();
    await client.connect();
    _client = client;
    return client;
  }

  Future<AgentSession> _ensureSession(
    AcpAgentClient client,
    String workspaceRoot,
    List<String> additionalDirectories,
  ) async {
    final existing = _session;
    if (existing != null &&
        _sessionWorkspaceRoot == workspaceRoot &&
        _sameStringList(_sessionAdditionalDirectories, additionalDirectories)) {
      return existing;
    }

    if (existing != null) {
      try {
        await client.closeSession(sessionId: existing.id);
      } on Object {
        // The sidecar session is best-effort and can be replaced safely.
      }
    }
    final session = await client.createSession(
      cwd: workspaceRoot,
      additionalDirectories: additionalDirectories,
    );
    _session = session;
    _sessionWorkspaceRoot = workspaceRoot;
    _sessionAdditionalDirectories = additionalDirectories;
    return session;
  }

  Future<void> _syncModel(
    AcpAgentClient client,
    String sessionId,
    String? model,
  ) async {
    final trimmed = model?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    try {
      final settings = await client
          .sessionSettings(sessionId)
          .timeout(const Duration(seconds: 5));
      final option = settings.modelOption;
      if (option == null || option.currentValue == trimmed) return;
      await client
          .setConfigOption(
            sessionId: sessionId,
            configId: option.id,
            value: trimmed,
          )
          .timeout(const Duration(seconds: 5));
    } on Object {
      // Some agents do not expose model settings on sidecar sessions. The
      // requested model is still included in the review prompt.
    }
  }

  Future<String> _reviewWithAgent(
    AcpAgentClient client,
    String sessionId,
    Map<String, dynamic> payload,
  ) async {
    final buffer = StringBuffer();
    await for (final event in client.sendPrompt(
      sessionId: sessionId,
      prompt: _agentReviewPrompt(payload),
    )) {
      switch (event.type) {
        case AgentEventType.agentTextDelta:
          buffer.write(event.text);
        case AgentEventType.agentTextDone:
          return buffer.toString();
        case AgentEventType.error:
          throw StateError(event.text);
        case AgentEventType.userMessage ||
            AgentEventType.toolCall ||
            AgentEventType.status:
          break;
      }
    }
    return buffer.toString();
  }

  String _agentReviewPrompt(Map<String, dynamic> payload) {
    const encoder = JsonEncoder.withIndent('  ');
    return '''
You are a sidecar permission approval reviewer. Review only the command execution context in the JSON payload.

Return only a JSON object with:
- "decision": "allow", "deny", or "manual"
- "risk": "low", "medium", or "high"
- "rationale": one concise sentence

Allow only clearly low-risk read-only commands whose cwd is inside one of the workspace roots. Deny destructive, privileged, network-install, or outside-workspace commands. Use manual for ambiguity. Do not run tools.

Payload:
```json
${encoder.convert(payload)}
```
''';
  }

  Map<String, Object?> _reviewDataFromText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const <String, Object?>{};
    for (final candidate in <String>[
      trimmed,
      _stripJsonFence(trimmed),
      _firstJsonObject(trimmed),
    ]) {
      if (candidate.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(candidate);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      } on FormatException {
        continue;
      }
    }
    return <String, Object?>{'summary': trimmed};
  }

  String _stripJsonFence(String text) {
    final match = RegExp(
      r'^```(?:json)?\s*([\s\S]*?)\s*```$',
      caseSensitive: false,
    ).firstMatch(text);
    return match?.group(1)?.trim() ?? text;
  }

  String _firstJsonObject(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start == -1 || end <= start) return '';
    return text.substring(start, end + 1);
  }

  @override
  Future<void> dispose() async {
    await _resetClient();
  }

  Future<void> _resetClient() async {
    final client = _client;
    final session = _session;
    _client = null;
    _session = null;
    _sessionWorkspaceRoot = null;
    _sessionAdditionalDirectories = const <String>[];
    try {
      if (client != null && session != null) {
        await client.closeSession(sessionId: session.id);
      }
    } on Object {
      // Best-effort cleanup for a sidecar session.
    }
    try {
      await client?.dispose();
    } on Object {
      // Best-effort cleanup; review failures fall back to manual review.
    }
  }
}

class McpPermissionReviewAgent extends AcpPermissionReviewer {
  McpPermissionReviewAgent({required this.config, required this.mcpServer}) {
    if (mcpServer.type == 'http' || mcpServer.type == 'sse') {
      parseAndValidateAcpEndpoint(
        mcpServer.url,
        allowedSchemes: const <String>{'http', 'https'},
      );
    }
  }

  final AcpPermissionReviewAgentConfig config;
  final McpServerConfig mcpServer;

  mcp.McpClient? _client;
  mcp.Transport? _transport;
  Future<mcp.McpClient>? _connectingClient;
  mcp.Transport? _connectingTransport;
  Future<void>? _resetting;
  int _connectionGeneration = 0;
  bool _disposed = false;

  @override
  bool get canAutoApprove => true;

  @override
  Future<AcpPermissionReviewResult?> review(
    AcpPermissionRequest request, {
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
    String? model,
  }) async {
    if (!config.enabled) return null;
    final effectiveModel = config.model ?? model;
    final payload = acpPermissionReviewPayload(
      request,
      workspaceRoot: workspaceRoot,
      additionalDirectories: additionalDirectories,
      model: effectiveModel,
    );

    try {
      return await (() async {
        final client = await _ensureClient();
        final result = await client.callTool(
          mcp.CallToolRequest(name: config.toolName, arguments: payload),
        );
        return _resultFromToolCall(result, model: effectiveModel);
      }()).timeout(config.timeout);
    } catch (error) {
      await _resetClient();
      return AcpPermissionReviewResult(
        risk: 'unknown',
        rationale: 'Review agent failed: $error',
        reviewer: mcpServer.name,
        model: effectiveModel,
        details: <String, Object?>{
          'error': error.toString(),
          'localAnalysis': payload['analysis'],
        },
      );
    }
  }

  Future<mcp.McpClient> _ensureClient() async {
    if (_disposed) {
      throw StateError('MCP permission reviewer is disposed.');
    }
    final resetting = _resetting;
    if (resetting != null) await resetting;
    if (_disposed) {
      throw StateError('MCP permission reviewer is disposed.');
    }
    final existing = _client;
    if (existing != null) return existing;
    final connecting = _connectingClient;
    if (connecting != null) return connecting;

    final generation = _connectionGeneration;
    late final Future<mcp.McpClient> connectingClient;
    connectingClient = _connectClient(generation).whenComplete(() {
      if (identical(_connectingClient, connectingClient)) {
        _connectingClient = null;
      }
    });
    _connectingClient = connectingClient;
    return connectingClient;
  }

  Future<mcp.McpClient> _connectClient(int generation) async {
    final transport = _transportForServer(mcpServer);
    _connectingTransport = transport;
    final client = mcp.McpClient(
      const mcp.Implementation(
        name: 'ianvs-acp-permission-review',
        version: '1.0.0',
      ),
    );
    try {
      await client.connect(transport);
      if (_disposed ||
          generation != _connectionGeneration ||
          !identical(_connectingTransport, transport)) {
        await transport.close();
        throw StateError('MCP permission reviewer connection was cancelled.');
      }
      _connectingTransport = null;
      _client = client;
      _transport = transport;
      return client;
    } catch (_) {
      if (identical(_connectingTransport, transport)) {
        _connectingTransport = null;
      }
      try {
        await transport.close();
      } on Object {
        // The original connection failure remains the useful error.
      }
      rethrow;
    }
  }

  mcp.Transport _transportForServer(McpServerConfig server) {
    final runtime = server.toRuntimeJson();
    if (server.type == 'http' || server.type == 'sse') {
      final endpoint = parseAndValidateAcpEndpoint(
        server.url,
        allowedSchemes: const <String>{'http', 'https'},
      );
      return NoRedirectMcpHttpTransport(
        endpoint: endpoint,
        headers: <String, String>{
          for (final key in server.headerKeys)
            key: _headerValue(runtime['headers'], key) ?? '',
        },
      );
    }
    if (server.type == 'acp') {
      throw UnsupportedError(
        'ACP transport MCP servers cannot be used as sidecar review agents.',
      );
    }
    return mcp.StdioClientTransport(
      mcp.StdioServerParameters(
        command: server.command,
        args: runtime['args'] is List
            ? (runtime['args'] as List).whereType<String>().toList()
            : const <String>[],
        environment: _envMap(runtime['env']),
        stderrMode: ProcessStartMode.normal,
      ),
    );
  }

  String? _headerValue(Object? headers, String key) {
    if (headers is Map) {
      final value = headers[key];
      return value is String ? value : null;
    }
    if (headers is List) {
      for (final header in headers) {
        if (header is! Map) continue;
        if (header['name'] == key && header['value'] is String) {
          return header['value'] as String;
        }
      }
    }
    return null;
  }

  Map<String, String>? _envMap(Object? env) {
    if (env is! List || env.isEmpty) return null;
    final result = <String, String>{};
    for (final entry in env) {
      if (entry is! Map) continue;
      final name = entry['name'];
      final value = entry['value'];
      if (name is String && value is String) result[name] = value;
    }
    return result.isEmpty ? null : result;
  }

  AcpPermissionReviewResult _resultFromToolCall(
    mcp.CallToolResult result, {
    String? model,
  }) {
    final data = _structuredResult(result);
    if (result.isError) {
      return AcpPermissionReviewResult(
        risk:
            _stringField(data, const ['risk', 'riskLevel', 'severity']) ??
            'unknown',
        rationale:
            _stringField(data, const ['rationale', 'reason', 'summary']) ??
            _textResult(result) ??
            'Review agent returned an MCP tool error.',
        reviewer: mcpServer.name,
        model: model,
        details: <String, Object?>{'raw': data},
      );
    }
    return AcpPermissionReviewResult(
      decision: _decisionFromReview(data),
      risk:
          _stringField(data, const ['risk', 'riskLevel', 'severity']) ??
          'unknown',
      rationale:
          _stringField(data, const ['rationale', 'reason', 'summary']) ??
          _textResult(result) ??
          '',
      reviewer:
          _stringField(data, const ['reviewer', 'reviewAgent']) ??
          mcpServer.name,
      model: _stringField(data, const ['model']) ?? model,
      details: data.isEmpty ? const <String, Object?>{} : data,
    );
  }

  Map<String, Object?> _structuredResult(mcp.CallToolResult result) {
    final structured = result.structuredContent;
    if (structured != null) {
      return structured.map((key, value) => MapEntry(key, value as Object?));
    }
    final extra = result.extra;
    if (extra != null && extra.isNotEmpty) {
      return extra.map((key, value) => MapEntry(key, value as Object?));
    }
    final text = _textResult(result);
    if (text == null) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } on FormatException {
      return <String, Object?>{'summary': text};
    }
    return <String, Object?>{'summary': text};
  }

  String? _textResult(mcp.CallToolResult result) {
    for (final content in result.content) {
      if (content is mcp.TextContent && content.text.trim().isNotEmpty) {
        return content.text.trim();
      }
    }
    return null;
  }

  String? _stringField(Map<String, Object?> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  AcpPermissionDecision? _decisionFromReview(Map<String, Object?> data) {
    final value = _stringField(data, const [
      'decision',
      'outcome',
      'approval',
      'result',
    ])?.toLowerCase();
    return switch (value) {
      'allow' ||
      'allowed' ||
      'approve' ||
      'approved' ||
      'yes' => AcpPermissionDecision.allow,
      'deny' ||
      'denied' ||
      'reject' ||
      'rejected' ||
      'block' ||
      'blocked' ||
      'no' => AcpPermissionDecision.deny,
      'cancel' || 'cancelled' || 'canceled' => AcpPermissionDecision.cancel,
      _ => null,
    };
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _resetClient();
  }

  Future<void> _resetClient() {
    final existing = _resetting;
    if (existing != null) return existing;
    late final Future<void> resetting;
    resetting = _performReset().whenComplete(() {
      if (identical(_resetting, resetting)) {
        _resetting = null;
      }
    });
    _resetting = resetting;
    return resetting;
  }

  Future<void> _performReset() async {
    _connectionGeneration += 1;
    final client = _client;
    final transport = _transport;
    final connectingTransport = _connectingTransport;
    _client = null;
    _transport = null;
    _connectingClient = null;
    _connectingTransport = null;
    try {
      await client?.close();
    } on Object {
      // Best-effort cleanup; review failures should fall back to manual review.
    }
    try {
      await transport?.close();
    } on Object {
      // Best-effort cleanup; the MCP client normally closes its transport.
    }
    if (!identical(connectingTransport, transport)) {
      try {
        await connectingTransport?.close();
      } on Object {
        // An in-flight initialization must not survive reset or disposal.
      }
    }
  }
}

AcpPermissionDecision? _reviewDecisionFromData(Map<String, Object?> data) {
  final value = _reviewStringField(data, const [
    'decision',
    'outcome',
    'approval',
    'result',
  ])?.toLowerCase();
  return switch (value) {
    'allow' ||
    'allowed' ||
    'approve' ||
    'approved' ||
    'yes' => AcpPermissionDecision.allow,
    'deny' ||
    'denied' ||
    'reject' ||
    'rejected' ||
    'block' ||
    'blocked' ||
    'no' => AcpPermissionDecision.deny,
    'cancel' || 'cancelled' || 'canceled' => AcpPermissionDecision.cancel,
    _ => null,
  };
}

String? _reviewStringField(Map<String, Object?> data, List<String> keys) {
  for (final key in keys) {
    final value = data[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

Map<String, dynamic> acpPermissionReviewPayload(
  AcpPermissionRequest request, {
  required String workspaceRoot,
  List<String> additionalDirectories = const <String>[],
  String? model,
}) {
  final metadataWorkspace = _metadataString(request.metadata, 'workspaceRoot');
  final effectiveWorkspace =
      metadataWorkspace == null || metadataWorkspace.isEmpty
      ? workspaceRoot
      : metadataWorkspace;
  final effectiveAdditionalDirectories = _normalizedDirectories([
    ...additionalDirectories,
    ..._metadataStringList(request.metadata, const [
      'additionalDirectories',
      'additional_directories',
    ]),
  ]);
  final commandContext = _commandContextFromPermission(request);
  final command = commandContext.command;
  final args = commandContext.args;
  final cwd = commandContext.cwd ?? effectiveWorkspace;
  final commandLine = _commandLine(command, args);
  final analysis = _localPermissionAnalysis(
    request,
    workspaceRoot: effectiveWorkspace,
    additionalDirectories: effectiveAdditionalDirectories,
    commandLine: commandLine,
    cwd: cwd,
  );
  return <String, dynamic>{
    'schema': 'ianvs-acp.permission-review.v1',
    if (model?.trim().isNotEmpty == true) 'model': model!.trim(),
    'request': _jsonMap(request.toJson()),
    'workspace': <String, Object?>{
      'root': effectiveWorkspace,
      if (effectiveAdditionalDirectories.isNotEmpty)
        'additionalDirectories': effectiveAdditionalDirectories,
    },
    if (commandLine.isNotEmpty)
      'command': <String, Object?>{
        'line': commandLine,
        if (command?.trim().isNotEmpty == true) 'command': command!.trim(),
        if (args.isNotEmpty) 'args': args,
        'cwd': cwd,
      },
    'analysis': analysis,
  };
}

Map<String, Object?> _localPermissionAnalysis(
  AcpPermissionRequest request, {
  required String workspaceRoot,
  required List<String> additionalDirectories,
  required String commandLine,
  required String cwd,
}) {
  final signals = <String>[];
  final workspaceRoots = _workspaceRoots(workspaceRoot, additionalDirectories);
  final cwdWithinWorkspace = _isWithinAnyWorkspace(cwd, workspaceRoots);
  if (!cwdWithinWorkspace) signals.add('cwd_outside_workspace');

  final lowerCommand = commandLine.toLowerCase();
  if (lowerCommand.isNotEmpty) {
    if (_matchesAny(lowerCommand, _highRiskCommandPatterns)) {
      signals.add('high_risk_command_pattern');
    } else if (_matchesAny(lowerCommand, _mediumRiskCommandPatterns)) {
      signals.add('medium_risk_command_pattern');
    } else if (_matchesAny(lowerCommand, _lowRiskCommandPatterns)) {
      signals.add('low_risk_command_pattern');
    }
  }

  final toolKind = request.toolKind?.toLowerCase();
  if (toolKind == 'execute' && commandLine.isEmpty) {
    signals.add('missing_command_context');
  }

  final risk =
      signals.contains('cwd_outside_workspace') ||
          signals.contains('high_risk_command_pattern')
      ? 'high'
      : signals.contains('medium_risk_command_pattern') ||
            signals.contains('missing_command_context')
      ? 'medium'
      : 'low';
  final suggestedDecision = switch (risk) {
    'high' => 'deny',
    'low' => 'allow',
    _ => 'manual',
  };

  return <String, Object?>{
    'scope': 'command_execution_context',
    'risk': risk,
    'suggestedDecision': suggestedDecision,
    'cwdWithinWorkspace': cwdWithinWorkspace,
    if (workspaceRoots.length > 1) 'workspaceRoots': workspaceRoots,
    if (signals.isNotEmpty) 'signals': signals,
  };
}

String? _metadataString(Map<String, Object?> metadata, String key) {
  final value = metadata[key];
  return value is String && value.trim().isNotEmpty ? value.trim() : null;
}

class _PermissionCommandContext {
  const _PermissionCommandContext({
    required this.command,
    required this.args,
    required this.cwd,
  });

  final String? command;
  final List<String> args;
  final String? cwd;
}

_PermissionCommandContext _commandContextFromPermission(
  AcpPermissionRequest request,
) {
  final metadata = request.metadata;
  final rawInput = _firstValue(metadata, const [
    'rawInput',
    'raw_input',
    'input',
    'args',
    'arguments',
  ]);
  final nestedToolCall = metadata['toolCall'];
  final nestedRawInput = nestedToolCall is Map
      ? _firstValue(nestedToolCall, const [
          'rawInput',
          'raw_input',
          'input',
          'args',
          'arguments',
        ])
      : null;
  final commandSource =
      _decodedJsonObject(rawInput) ??
      _decodedJsonObject(nestedRawInput) ??
      metadata;
  final toolCallSource = nestedToolCall is Map ? nestedToolCall : null;

  final command =
      _firstString(commandSource, const [
        'command',
        'cmd',
        'commandLine',
        'command_line',
        'shellCommand',
        'shell_command',
        'script',
      ]) ??
      _firstString(toolCallSource, const [
        'command',
        'cmd',
        'commandLine',
        'command_line',
        'shellCommand',
        'shell_command',
      ]) ??
      _commandLineFromPermissionText(request.title) ??
      _commandLineFromPermissionText(request.rationale);
  final args = _firstStringList(commandSource, const [
    'args',
    'argv',
    'arguments',
  ]);
  final cwd =
      _firstString(commandSource, const [
        'cwd',
        'workdir',
        'workingDirectory',
        'working_directory',
      ]) ??
      _firstString(toolCallSource, const [
        'cwd',
        'workdir',
        'workingDirectory',
        'working_directory',
      ]) ??
      _metadataString(metadata, 'cwd');
  return _PermissionCommandContext(command: command, args: args, cwd: cwd);
}

String? _commandLineFromPermissionText(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  for (final pattern in <RegExp>[
    RegExp(r'^running:\s*(.+)$', caseSensitive: false),
    RegExp(r'^run:\s*(.+)$', caseSensitive: false),
    RegExp(r'^command:\s*(.+)$', caseSensitive: false),
    RegExp(r'^executing:\s*(.+)$', caseSensitive: false),
  ]) {
    final match = pattern.firstMatch(trimmed);
    final value = match?.group(1)?.trim();
    if (value != null && value.isNotEmpty) return _stripInlineCode(value);
  }
  final inline = RegExp(r'`([^`]+)`').firstMatch(trimmed)?.group(1)?.trim();
  return inline == null || inline.isEmpty ? null : inline;
}

String _stripInlineCode(String value) {
  var result = value.trim();
  while (result.startsWith('`') && result.endsWith('`') && result.length > 1) {
    result = result.substring(1, result.length - 1).trim();
  }
  return result;
}

Object? _firstValue(Map? map, List<String> keys) {
  if (map == null) return null;
  for (final key in keys) {
    if (map.containsKey(key)) return map[key];
  }
  return null;
}

Map<String, Object?>? _decodedJsonObject(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  if (value is! String || value.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(value);
    if (decoded is Map) {
      return decoded.map((key, item) => MapEntry(key.toString(), item));
    }
  } on FormatException {
    return null;
  }
  return null;
}

String? _firstString(Map? map, List<String> keys) {
  if (map == null) return null;
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

List<String> _firstStringList(Map? map, List<String> keys) {
  if (map == null) return const <String>[];
  for (final key in keys) {
    final values = _stringList(map[key]);
    if (values.isNotEmpty) return values;
  }
  return const <String>[];
}

List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return value.whereType<String>().toList(growable: false);
}

List<String> _metadataStringList(
  Map<String, Object?> metadata,
  List<String> keys,
) {
  for (final key in keys) {
    final values = _stringList(metadata[key]);
    if (values.isNotEmpty) return values;
  }
  return const <String>[];
}

List<String> _normalizedDirectories(Iterable<String> directories) {
  final result = <String>[];
  final seen = <String>{};
  for (final directory in directories) {
    final trimmed = directory.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) continue;
    result.add(trimmed);
  }
  return List.unmodifiable(result);
}

bool _sameStringList(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _commandLine(String? command, List<String> args) {
  final trimmedCommand = command?.trim();
  if (trimmedCommand == null || trimmedCommand.isEmpty) return '';
  if (args.isEmpty) return trimmedCommand;
  return [trimmedCommand, ...args.map(_shellDisplayArg)].join(' ');
}

String _shellDisplayArg(String arg) {
  if (!arg.contains(RegExp(r'\s'))) return arg;
  return "'${arg.replaceAll("'", r"'\''")}'";
}

bool _isWithinWorkspace(String path, String workspaceRoot) {
  final root = _normalizedAbsolutePath(workspaceRoot, workspaceRoot);
  final target = _normalizedAbsolutePath(path, root);
  return target == root || target.startsWith('$root/');
}

bool _isWithinAnyWorkspace(String path, List<String> workspaceRoots) {
  for (final root in workspaceRoots) {
    if (_isWithinWorkspace(path, root)) return true;
  }
  return false;
}

List<String> _workspaceRoots(
  String workspaceRoot,
  List<String> additionalDirectories,
) {
  final roots = <String>[];
  final seen = <String>{};
  for (final root in [workspaceRoot, ...additionalDirectories]) {
    final normalized = _normalizedAbsolutePath(root, workspaceRoot);
    if (seen.add(normalized)) roots.add(normalized);
  }
  return List.unmodifiable(roots);
}

String _normalizedAbsolutePath(String path, String base) {
  final trimmed = path.trim().replaceAll('\\', '/');
  final raw = trimmed.startsWith('/') ? trimmed : '${base.trim()}/$trimmed';
  final parts = <String>[];
  for (final part in raw.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(part);
  }
  return '/${parts.join('/')}';
}

bool _matchesAny(String value, List<RegExp> patterns) {
  return patterns.any((pattern) => pattern.hasMatch(value));
}

Map<String, dynamic> _jsonMap(Map<String, Object?> raw) {
  return raw.map((key, value) => MapEntry(key, _jsonValue(value)));
}

Object? _jsonValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Map<String, Object?>) return _jsonMap(value);
  if (value is Map) {
    return value.map<String, dynamic>(
      (key, item) => MapEntry(key.toString(), _jsonValue(item)),
    );
  }
  if (value is List) return value.map(_jsonValue).toList(growable: false);
  return value.toString();
}

final List<RegExp> _highRiskCommandPatterns = <RegExp>[
  RegExp(r'\brm\s+(-[a-z]*r[a-z]*f|-rf|-fr)\b'),
  RegExp(r'\bsudo\b'),
  RegExp(r'\b(chmod|chown)\s+-r\b'),
  RegExp(r'\bchmod\s+777\b'),
  RegExp(r'\b(dd|mkfs|diskutil\s+erase)\b'),
  RegExp(r'\b(git\s+reset\s+--hard|git\s+clean\s+-[a-z]*f)\b'),
  RegExp(r'\b(curl|wget)\b.+\|\s*(sh|bash|zsh)\b'),
  RegExp(r'>\s*/dev/(disk|rdisk|sda|nvme)'),
];

final List<RegExp> _mediumRiskCommandPatterns = <RegExp>[
  RegExp(r'\b(npm|pnpm|yarn|bun)\s+(install|add|remove|update)\b'),
  RegExp(r'\b(dart|flutter)\s+pub\s+(add|get|upgrade)\b'),
  RegExp(r'\b(git\s+(commit|push|merge|rebase|checkout|switch))\b'),
  RegExp(r'\b(curl|wget|ssh|scp|rsync)\b'),
  RegExp(r'\bpython[0-9.]*\s+-m\s+pip\s+install\b'),
];

final List<RegExp> _lowRiskCommandPatterns = <RegExp>[
  RegExp(r'^\s*(pwd|ls|cat|head|tail)\b'),
  RegExp(r'^\s*(rg|grep|sed|awk|find)\b'),
  RegExp(r'^\s*git\s+(status|diff|show|log)\b'),
  RegExp(r'^\s*(dart|flutter)\s+(test|analyze)\b'),
];
