import 'package:logging/logging.dart';
import 'capabilities.dart';
import 'providers/fs_provider.dart';
import 'providers/permission_provider.dart';
import 'providers/terminal_provider.dart';

/// Collection of timeout knobs for ACP requests.
class AcpTimeouts {
  /// Create bounded logical timeouts for ACP operations.
  const AcpTimeouts({
    this.initialize = const Duration(seconds: 15),
    this.request = const Duration(seconds: 60),
    this.prompt = const Duration(minutes: 30),
    this.permission = const Duration(minutes: 5),
    this.promptCancelGrace = const Duration(seconds: 2),
  });

  /// Initialize call timeout.
  final Duration initialize;

  /// Ordinary request timeout.
  final Duration request;

  /// Prompt turn timeout.
  final Duration prompt;

  /// Permission prompt timeout.
  final Duration permission;

  /// Grace period for reaping a cancelled prompt.
  final Duration promptCancelGrace;

  /// Validate that every logical timeout is positive.
  void validate() {
    if (initialize <= Duration.zero ||
        request <= Duration.zero ||
        prompt <= Duration.zero ||
        permission <= Duration.zero ||
        promptCancelGrace <= Duration.zero) {
      throw ArgumentError('ACP timeouts must be positive.');
    }
  }
}

/// Fixed error for an ordinary ACP request deadline.
final class AcpRequestTimeoutException implements Exception {
  /// Create the fixed timeout error.
  const AcpRequestTimeoutException();

  @override
  String toString() => 'ACP request timed out.';
}

/// Fixed error for an ACP prompt deadline.
final class AcpPromptTimeoutException implements Exception {
  /// Create the fixed timeout error.
  const AcpPromptTimeoutException();

  @override
  String toString() => 'ACP prompt timed out.';
}

/// Fixed error for an unavailable ACP connection.
final class AcpConnectionClosedException implements Exception {
  /// Create the fixed connection error.
  const AcpConnectionClosedException();

  @override
  String toString() => 'ACP connection closed.';
}

/// Client configuration describing transport, providers, and capabilities.
class AcpConfig {
  /// Construct a configuration; call sites provide agent command/args/env.
  AcpConfig({
    this.agentCommand,
    this.agentArgs = const [],
    this.envOverrides = const {},
    this.capabilities = const AcpCapabilities(),
    this.mcpServers = const [],
    this.allowReadOutsideWorkspace = false,
    AcpTimeouts timeouts = const AcpTimeouts(),
    Logger? logger,
    this.fsProvider,
    PermissionProvider? permissionProvider,
    this.terminalProvider,
    this.onProtocolOut,
    this.onProtocolIn,
  }) : timeouts = _validatedAcpTimeouts(timeouts),
       logger = logger ?? Logger('dart_acp'),
       permissionProvider =
           permissionProvider ?? const DefaultPermissionProvider();

  static AcpTimeouts _validatedAcpTimeouts(AcpTimeouts value) {
    value.validate();
    return value;
  }

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
}
