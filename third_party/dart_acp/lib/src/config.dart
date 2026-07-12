import 'package:logging/logging.dart';
import 'capabilities.dart';
import 'providers/fs_provider.dart';
import 'providers/permission_provider.dart';
import 'providers/terminal_provider.dart';
import 'schema_version.dart';

/// Callback for an evolving ACP request surface.
typedef AcpRequestHandler = Future<dynamic> Function(Map<String, dynamic>);

/// Collection of timeout knobs for ACP requests.
class AcpTimeouts {
  /// Create timeouts; all optional.
  const AcpTimeouts({
    this.initialize = const Duration(seconds: 15),
    this.prompt,
    this.permission,
  });

  /// Initialize call timeout.
  final Duration initialize;

  /// Optional prompt turn timeout (no hard timeout by default).
  final Duration? prompt;

  /// Optional permission prompt timeout.
  final Duration? permission;
}

/// Client configuration describing transport, providers, and capabilities.
class AcpConfig {
  /// Construct a configuration; call sites provide agent command/args/env.
  AcpConfig({
    this.agentCommand,
    this.agentArgs = const [],
    this.envOverrides = const {},
    this.capabilities = const AcpCapabilities(),
    this.clientInfo = const AcpImplementation(
      name: 'dart_acp',
      version: dartAcpImplementationVersion,
    ),
    this.initializeMeta,
    this.mcpServers = const [],
    this.allowReadOutsideWorkspace = false,
    this.timeouts = const AcpTimeouts(),
    Logger? logger,
    this.fsProvider,
    PermissionProvider? permissionProvider,
    this.terminalProvider,
    this.elicitationProvider,
    this.mcpConnectProvider,
    this.mcpMessageProvider,
    this.mcpDisconnectProvider,
    this.onProtocolOut,
    this.onProtocolIn,
  }) : logger = logger ?? Logger('dart_acp'),
       permissionProvider =
           permissionProvider ?? const DefaultPermissionProvider();

  /// Manually maintained minimum protocol version required by this client.
  /// Bump this constant only when you add support for a future breaking spec.
  static const int minimumProtocolVersion = 1;

  /// Agent executable name/path (for stdio transport).
  final String? agentCommand;

  /// Arguments passed to the agent executable.
  final List<String> agentArgs;

  /// Environment variable overlay for the agent process.
  final Map<String, String> envOverrides;

  /// Client capability advertisement.
  final AcpCapabilities capabilities;

  /// Client implementation metadata sent during initialization.
  final AcpImplementation? clientInfo;

  /// Optional ACP `_meta` data sent with the initialize request.
  final Map<String, dynamic>? initializeMeta;

  /// Global MCP servers forwarded to session/new and session/load.
  final List<Map<String, dynamic>> mcpServers;

  /// Whether reads may escape the workspace root (yolo mode).
  final bool allowReadOutsideWorkspace;

  /// Request timeout configuration.
  final AcpTimeouts timeouts;

  /// Logger used by the client and transport.
  final Logger logger;

  /// Optional tap for raw outbound JSON-RPC frames (unprefixed JSONL).
  final void Function(String line)? onProtocolOut;

  /// Optional tap for raw inbound JSON-RPC frames (unprefixed JSONL).
  final void Function(String line)? onProtocolIn;

  /// File system provider used to fulfill fs/* requests.
  final FsProvider? fsProvider;

  /// Permission provider used to answer session/request_permission.
  final PermissionProvider permissionProvider;

  /// Optional terminal provider to allow terminal lifecycle methods.
  final TerminalProvider? terminalProvider;

  /// Optional handler for unstable `elicitation/create` requests.
  final AcpRequestHandler? elicitationProvider;

  /// Optional handler for unstable `mcp/connect` requests.
  final AcpRequestHandler? mcpConnectProvider;

  /// Optional handler for unstable `mcp/message` requests/notifications.
  final AcpRequestHandler? mcpMessageProvider;

  /// Optional handler for unstable `mcp/disconnect` requests.
  final AcpRequestHandler? mcpDisconnectProvider;
}
