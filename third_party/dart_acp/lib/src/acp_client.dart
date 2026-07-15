import 'dart:async';

import 'package:meta/meta.dart';

import 'capabilities.dart';
import 'config.dart';
import 'content/content_builder.dart';
import 'extensions.dart';
import 'input_budget.dart';
import 'models/bounded_observation.dart';
import 'models/session_types.dart';
import 'models/terminal_events.dart';
import 'models/updates.dart';
import 'providers/terminal_provider.dart';
import 'rpc/inbound_gate.dart';
import 'rpc/peer.dart';
import 'session/session_manager.dart';
import 'transport/stdio_transport.dart';
import 'transport/transport.dart';

/// High-level ACP client that manages transport, session lifecycle,
/// and streams updates from the agent.
class AcpClient implements AcpBoundedObservationSource {
  /// Private constructor - use [AcpClient.start] to create instances.
  AcpClient._({required this.config, required AcpTransport transport})
    : _transport = transport;

  /// Create and start a client with the given configuration.
  /// If no transport is provided, creates a StdioTransport that spawns
  /// the agent.
  static Future<AcpClient> start({
    required AcpConfig config,
    AcpTransport? transport,
    int maxReplayItems = 2048,
    int maxReplayBytes = 16 * 1024 * 1024,
    int maxToolCallItems = 512,
    int maxToolCallBytes = 8 * 1024 * 1024,
    int maxPendingItems = 128,
    int maxPendingBytes = 32 * 1024 * 1024,
    int maxConcurrentHandlers = 16,
    int maxOrdinaryConcurrentHandlers = 14,
    int maxTerminalHandles = defaultMaxTerminalHandles,
    int maxTerminalHandlesPerSession = defaultMaxTerminalHandlesPerSession,
    AcpInputBudget inputBudget = const AcpInputBudget(),
    @visibleForTesting
    void Function(JsonRpcPeer peer)? beforeSessionManagerForTesting,
    @visibleForTesting
    void Function(JsonRpcPeer peer, SessionManager manager)?
    afterSessionManagerForTesting,
  }) async {
    config.timeouts.validate();
    inputBudget.validate();
    validateTerminalHandleLimits(
      maxTerminalHandles: maxTerminalHandles,
      maxTerminalHandlesPerSession: maxTerminalHandlesPerSession,
    );
    InboundGate.validateLimits(
      maxPendingItems: maxPendingItems,
      maxPendingBytes: maxPendingBytes,
      maxConcurrentHandlers: maxConcurrentHandlers,
      maxOrdinaryConcurrentHandlers: maxOrdinaryConcurrentHandlers,
    );
    if (maxReplayItems <= 0 ||
        maxReplayBytes < minimumSessionReplayBytes ||
        maxToolCallItems <= 0 ||
        maxToolCallBytes <= 0) {
      throw ArgumentError(
        'Session state budgets are invalid; maxReplayBytes must be at least '
        '$minimumSessionReplayBytes.',
      );
    }
    final actualTransport =
        transport ??
        StdioTransport(
          command: config.agentCommand,
          args: config.agentArgs,
          envOverrides: config.envOverrides,
          logger: config.logger,
          onProtocolOut: config.onProtocolOut,
          onProtocolIn: config.onProtocolIn,
        );

    await actualTransport.start();

    final client = AcpClient._(config: config, transport: actualTransport);
    client._peer = JsonRpcPeer(
      actualTransport.channel,
      timeouts: config.timeouts,
      maxPendingItems: maxPendingItems,
      maxPendingBytes: maxPendingBytes,
      maxConcurrentHandlers: maxConcurrentHandlers,
      maxOrdinaryConcurrentHandlers: maxOrdinaryConcurrentHandlers,
    );
    beforeSessionManagerForTesting?.call(client._peer);
    client._sessionManager = SessionManager(
      config: config,
      peer: client._peer,
      maxReplayItems: maxReplayItems,
      maxReplayBytes: maxReplayBytes,
      maxToolCallItems: maxToolCallItems,
      maxToolCallBytes: maxToolCallBytes,
      maxTerminalHandles: maxTerminalHandles,
      maxTerminalHandlesPerSession: maxTerminalHandlesPerSession,
      inputBudget: inputBudget,
    );
    afterSessionManagerForTesting?.call(client._peer, client._sessionManager);

    return client;
  }

  /// Client configuration.
  final AcpConfig config;
  final AcpTransport _transport;
  late final JsonRpcPeer _peer;
  late final SessionManager _sessionManager;
  Future<void>? _disposeFuture;

  /// Read-only peer projection for integration tests.
  @visibleForTesting
  JsonRpcPeer get peerForTesting => _peer;

  /// Read-only session-manager projection for integration tests.
  @visibleForTesting
  SessionManager get sessionManagerForTesting => _sessionManager;

  /// The exact timeout configuration owned by the peer.
  @visibleForTesting
  AcpTimeouts get peerTimeoutsForTesting => _peer.timeouts;

  /// The exact configuration instance owned by the session manager.
  @visibleForTesting
  AcpConfig get sessionManagerConfigForTesting => _sessionManager.config;

  /// Replaces the opaque permission cancellation-token factory for tests.
  @visibleForTesting
  void replacePermissionCancellationTokenFactoryForTesting(
    Object Function() factory,
  ) {
    // ignore: invalid_use_of_visible_for_testing_member
    _sessionManager.replacePermissionCancellationTokenFactoryForTesting(
      factory,
    );
  }

  /// Whether the underlying ACP peer remains available.
  bool get isAvailable => _peer.isAvailable;

  /// Adds a listener for the peer's first unavailable state.
  void addPeerUnavailableListener(AcpPeerUnavailableListener listener) =>
      _peer.addUnavailableListener(listener);

  /// Removes a peer unavailable listener.
  void removePeerUnavailableListener(AcpPeerUnavailableListener listener) =>
      _peer.removeUnavailableListener(listener);

  @override
  void addBoundedObservationListener(AcpBoundedObservationListener listener) =>
      _sessionManager.addBoundedObservationListener(listener);

  @override
  void removeBoundedObservationListener(
    AcpBoundedObservationListener listener,
  ) => _sessionManager.removeBoundedObservationListener(listener);

  /// Dispose the transport and release resources.
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    final owner = Completer<void>.sync();
    final disposing = owner.future;
    _disposeFuture = disposing;
    unawaited(_dispose(owner));
    return disposing;
  }

  Future<void> _dispose(Completer<void> owner) async {
    try {
      // Close JSON-RPC peer first to stop inbound traffic cleanly,
      // then dispose session resources and finally stop the transport.
      try {
        try {
          try {
            await _peer.dispose();
          } on Object {
            // Ignore close errors during shutdown.
          }
        } finally {
          await _sessionManager.dispose();
        }
      } finally {
        await _transport.stop();
      }
      if (!owner.isCompleted) owner.complete();
    } on Object catch (error, stackTrace) {
      if (!owner.isCompleted) owner.completeError(error, stackTrace);
    }
  }

  /// Send `initialize` to negotiate protocol and capabilities.
  Future<InitializeResult> initialize({
    AcpCapabilities? capabilitiesOverride,
  }) async =>
      _sessionManager.initialize(capabilitiesOverride: capabilitiesOverride);

  /// Create a new ACP session; returns the session id.
  Future<String> newSession(
    String workspaceRoot, {
    List<String> additionalDirectories = const <String>[],
  }) async => _sessionManager.newSession(
    workspaceRoot: workspaceRoot,
    additionalDirectories: additionalDirectories,
  );

  /// Load an existing session (if the agent supports it).
  Future<void> loadSession({
    required String sessionId,
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
  }) async => _sessionManager.loadSession(
    sessionId: sessionId,
    workspaceRoot: workspaceRoot,
    additionalDirectories: additionalDirectories,
  );

  /// Send a prompt to the agent and stream `AcpUpdate`s.
  ///
  /// The [content] string can include @-mentions for files and URLs:
  /// - `@file.txt` or `@"path with spaces/file.txt"` for local files
  /// - `@https://example.com/resource` for URLs
  /// - `@~/Documents/file.txt` for home directory paths
  Stream<AcpUpdate> prompt({
    required String sessionId,
    required String content,
  }) {
    final workspaceRoot = _sessionManager.getWorkspaceRoot(sessionId);
    final contentBlocks = ContentBuilder.buildFromPrompt(
      content,
      workspaceRoot: workspaceRoot,
    );
    return _sessionManager.prompt(sessionId: sessionId, content: contentBlocks);
  }

  /// Subscribe to the persistent session updates stream (includes replay).
  Stream<AcpUpdate> sessionUpdates(String sessionId) =>
      _sessionManager.sessionUpdates(sessionId);

  /// Subscribe only to updates published after this subscription.
  Stream<AcpUpdate> liveSessionUpdates(String sessionId) =>
      _sessionManager.liveSessionUpdates(sessionId);

  /// Mark a raw `session/prompt` request as active.
  AcpSessionInputBudgetOwner beginPromptTurn(String sessionId) =>
      _sessionManager.beginPromptTurn(sessionId);

  /// Sends one prompt request bound to the exact active [owner].
  Future<Map<String, dynamic>> sendPromptRequest({
    required AcpSessionInputBudgetOwner owner,
    required List<Map<String, dynamic>> content,
  }) => _sessionManager.sendPromptRequest(owner: owner, content: content);

  /// Clear turn-local state after a raw `session/prompt` request completes.
  void endPromptTurn(AcpSessionInputBudgetOwner owner) =>
      _sessionManager.endPromptTurn(owner);

  /// Cancel the current turn only while [owner] still owns it.
  Future<void> cancelPromptTurn(AcpSessionInputBudgetOwner owner) =>
      _sessionManager.cancelPromptTurn(owner);

  /// Whether [owner] currently has one pending terminal-delivery right.
  bool hasPromptDeliveryRight(AcpSessionInputBudgetOwner owner) =>
      _sessionManager.hasPromptDeliveryRight(owner);

  /// Whether [owner] currently has one active terminal-delivery claim.
  bool hasActivePromptDeliveryClaim(AcpSessionInputBudgetOwner owner) =>
      _sessionManager.hasActivePromptDeliveryClaim(owner);

  Future<bool> waitForPromptDeliveryBarrier(AcpSessionInputBudgetOwner owner) =>
      _sessionManager.waitForPromptDeliveryBarrier(owner);

  AcpPromptDeliveryClaim? tryClaimPromptDeliveryRight(
    AcpSessionInputBudgetOwner owner,
  ) => _sessionManager.tryClaimPromptDeliveryRight(owner);

  void releasePromptDeliveryRight(AcpPromptDeliveryClaim claim) =>
      _sessionManager.releasePromptDeliveryRight(claim);

  @visibleForTesting
  Future<void> promptWinnerRecordedForTesting(
    AcpSessionInputBudgetOwner owner,
  ) =>
      // ignore: invalid_use_of_visible_for_testing_member
      _sessionManager.promptWinnerRecordedForTesting(owner);

  @visibleForTesting
  Future<void> promptRightRecordedForTesting(
    AcpSessionInputBudgetOwner owner,
  ) =>
      // ignore: invalid_use_of_visible_for_testing_member
      _sessionManager.promptRightRecordedForTesting(owner);

  @visibleForTesting
  Future<void> promptBarrierReleasedForTesting(
    AcpSessionInputBudgetOwner owner,
  ) =>
      // ignore: invalid_use_of_visible_for_testing_member
      _sessionManager.promptBarrierReleasedForTesting(owner);

  @visibleForTesting
  Future<void> promptClaimSeenForTesting(AcpSessionInputBudgetOwner owner) =>
      // ignore: invalid_use_of_visible_for_testing_member
      _sessionManager.promptClaimSeenForTesting(owner);

  @visibleForTesting
  Future<void> promptGraceStartedForTesting(AcpSessionInputBudgetOwner owner) =>
      // ignore: invalid_use_of_visible_for_testing_member
      _sessionManager.promptGraceStartedForTesting(owner);

  @visibleForTesting
  Future<void> admissionResponseGraceStartedForTesting(
    AcpSessionInputBudgetOwner owner,
  ) =>
      // ignore: invalid_use_of_visible_for_testing_member
      _sessionManager.admissionResponseGraceStartedForTesting(owner);

  @visibleForTesting
  void expireOwnerAdmissionResponseGraceForTesting(
    AcpSessionInputBudgetOwner owner,
  ) =>
      // ignore: invalid_use_of_visible_for_testing_member
      _sessionManager.expireOwnerAdmissionResponseGraceForTesting(owner);

  @visibleForTesting
  Future<void> closePeerExplicitlyForTesting() => _peer.close();

  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  AcpPromptAdmissionProbeForTesting armNextPromptAdmissionForTesting() =>
      // ignore: invalid_use_of_visible_for_testing_member
      _sessionManager.armNextPromptAdmissionForTesting();

  /// Terminal events stream for UI.
  Stream<TerminalEvent> get terminalEvents => _sessionManager.terminalEvents;

  /// Read current buffered output for a managed terminal.
  Future<String> terminalOutput(String terminalId) async =>
      _sessionManager.readTerminalOutput(terminalId);

  /// Kill a managed terminal process.
  Future<void> terminalKill(String terminalId) async {
    await _sessionManager.killTerminal(terminalId);
  }

  /// Wait for a managed terminal process to exit.
  Future<int?> terminalWaitForExit(String terminalId) async =>
      _sessionManager.waitTerminal(terminalId);

  /// Release resources for a managed terminal.
  Future<void> terminalRelease(String terminalId) async {
    await _sessionManager.releaseTerminal(terminalId);
  }

  // ===== Modes (extension) =====

  /// Get current/available modes for a session, if provided by the agent.
  ({String? currentModeId, List<({String id, String name})> availableModes})?
  sessionModes(String sessionId) => _sessionManager.sessionModes(sessionId);

  /// Set the session mode (extension). Returns true on success.
  Future<bool> setMode({
    required String sessionId,
    required String modeId,
  }) async =>
      _sessionManager.setSessionMode(sessionId: sessionId, modeId: modeId);

  // ===== Session Extensions =====

  /// List existing sessions (requires agent support for session/list).
  ///
  /// Filter by [cwd] to show sessions for a specific directory.
  /// Use [cursor] for pagination (from previous
  /// [SessionListResult.nextCursor]).
  ///
  /// Check [InitializeResult.supportsListSessions] before calling.
  Future<SessionListResult> listSessions({String? cwd, String? cursor}) async =>
      _sessionManager.listSessions(cwd: cwd, cursor: cursor);

  /// Close a session and release all local resources owned by it.
  Future<void> closeSession({required String sessionId}) =>
      _sessionManager.closeSession(sessionId: sessionId);

  /// Resume a session without loading history (simpler than [loadSession]).
  ///
  /// Requires agent support for session/resume capability.
  /// Check [InitializeResult.supportsResumeSession] before calling.
  Future<SessionResult> resumeSession({
    required String sessionId,
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
  }) async => _sessionManager.resumeSession(
    sessionId: sessionId,
    workspaceRoot: workspaceRoot,
    additionalDirectories: additionalDirectories,
  );

  /// Fork an existing session to create a new independent session.
  ///
  /// Useful for generating summaries or PR descriptions without
  /// polluting the original session history.
  /// Check [InitializeResult.supportsForkSession] before calling.
  Future<SessionResult> forkSession({
    required String sessionId,
    String? workspaceRoot,
    List<String> additionalDirectories = const <String>[],
  }) async => _sessionManager.forkSession(
    sessionId: sessionId,
    workspaceRoot: workspaceRoot,
    additionalDirectories: additionalDirectories,
  );

  /// Set a configuration option for a session.
  ///
  /// Returns the updated list of all config options for the session.
  Future<List<ConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required String value,
  }) async => _sessionManager.setConfigOption(
    sessionId: sessionId,
    configId: configId,
    value: value,
  );

  /// Send an arbitrary JSON-RPC request (advanced; for compliance harness).
  Future<Map<String, dynamic>> sendRaw(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (method == 'session/prompt') {
      throw StateError('session/prompt must use owner-bound API.');
    }
    return _peer.sendRaw(method, params);
  }

  /// Send a JSON-RPC notification (no response expected).
  Future<void> sendNotificationRaw(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (method == 'session/prompt') {
      throw StateError('session/prompt must use owner-bound API.');
    }
    await _peer.sendNotificationRaw(method, params);
  }

  // ===== Extension Methods =====

  /// Send an extension request to the agent.
  ///
  /// Extension methods MUST start with underscore (`_`). Use
  /// [extensionMethodName] to create properly namespaced method names.
  ///
  /// Example:
  /// ```dart
  /// final method = extensionMethodName('zed.dev', 'workspace/buffers');
  /// final response = await client.sendExtensionRequest(
  ///   method,
  ///   ExtensionParams({'language': 'rust'}),
  /// );
  /// ```
  ///
  /// Throws [ArgumentError] if [method] doesn't start with underscore.
  /// May throw JSON-RPC errors if the agent doesn't support the method.
  Future<ExtensionResponse> sendExtensionRequest(
    String method,
    ExtensionParams params,
  ) async {
    if (!isValidExtensionMethod(method)) {
      throw ArgumentError.value(
        method,
        'method',
        'Extension methods must start with underscore (_)',
      );
    }
    final result = await _peer.sendRaw(method, params.toJson());
    return ExtensionResponse(result);
  }

  /// Send an extension notification to the agent (no response expected).
  ///
  /// Extension notifications MUST start with underscore (`_`). Use
  /// [extensionMethodName] to create properly namespaced method names.
  ///
  /// Example:
  /// ```dart
  /// final method = extensionMethodName('zed.dev', 'file_opened');
  /// await client.sendExtensionNotification(
  ///   method,
  ///   ExtensionParams({'path': '/home/user/file.rs'}),
  /// );
  /// ```
  ///
  /// Throws [ArgumentError] if [method] doesn't start with underscore.
  Future<void> sendExtensionNotification(
    String method,
    ExtensionParams params,
  ) async {
    if (!isValidExtensionMethod(method)) {
      throw ArgumentError.value(
        method,
        'method',
        'Extension methods must start with underscore (_)',
      );
    }
    await _peer.sendNotificationRaw(method, params.toJson());
  }
}
