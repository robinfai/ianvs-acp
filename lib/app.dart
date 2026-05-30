import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'acp/agent_session.dart';
import 'acp/dart_acp_agent_client.dart';
import 'config/acp_client_config.dart';
import 'state/chat_controller.dart';
import 'ui/components/new_session_agent_dialog.dart';
import 'ui/shell/app_shell.dart';
import 'ui/theme/app_design_tokens.dart';

class AcpClientApp extends StatefulWidget {
  const AcpClientApp({
    super.key,
    this.controller,
    this.config = const AcpClientConfig(),
    this.startupError,
  });

  final ChatController? controller;
  final AcpClientConfig config;
  final String? startupError;

  @override
  State<AcpClientApp> createState() => _AcpClientAppState();
}

class _AcpClientAppState extends State<AcpClientApp> {
  static const String _initialResumeSessionId = String.fromEnvironment(
    'ACP_RESUME_SESSION_ID',
  );

  late AcpClientConfig _config;
  late ChatController _controller;
  late final String _cwd;
  final Map<String, ChatController> _controllersByAgent =
      <String, ChatController>{};
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    _config = widget.config;
    _cwd = AcpClientConfig.resolveWorkspaceCwd(
      currentDirectory: Directory.current.path,
    );
    if (widget.controller == null) {
      _controller = _controllerFor(_config);
      _controllersByAgent[_config.agentName] = _controller;
    } else {
      _controller = widget.controller!;
    }
    if (_initialResumeSessionId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_controller.resumeSession(_initialResumeSessionId));
      });
    }
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      for (final controller in _controllersByAgent.values) {
        controller.dispose();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ACP Client',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messengerKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: AppColors.bg,
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        fontFamily: 'SF Pro Display',
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          titleTextStyle: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
        ),
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: AppColors.primary,
          selectionColor: AppColors.primary.withValues(alpha: 0.18),
        ),
      ),
      home: AppShell(
        controller: _controller,
        agentName: _config.agentName,
        agentServers: _config.selectableAgentServers,
        configPath: _config.configPath,
        defaultAgentName: _config.defaultAgentServerName,
        startupError: widget.startupError,
        canSwitchAgent: widget.controller == null,
        sessionControllers: _sessionControllers,
        onNewSession: (context) => unawaited(_startNewSession(context)),
        onSelectSession: (session) => unawaited(_selectSession(session)),
        onSelectAgent: widget.controller == null
            ? (agentName) => unawaited(_selectAgent(agentName))
            : null,
      ),
    );
  }

  ChatController _controllerFor(AcpClientConfig config) {
    return ChatController(
      client: _agentClient(config.activeAgentServer),
      cwd: _cwd,
      agentName: config.agentName,
    );
  }

  Future<void> _selectAgent(String agentName) async {
    if (agentName == _config.agentName) return;

    late final AcpClientConfig nextConfig;
    try {
      nextConfig = _config.withActiveAgentServer(agentName);
    } catch (error) {
      _showSnackBar('Could not select agent: $error');
      return;
    }

    _activateAgent(nextConfig);
  }

  Future<void> _startNewSession(BuildContext dialogContext) async {
    if (_controller.isStreaming || _controller.isSessionOperationRunning) {
      return;
    }
    if (widget.controller != null) {
      await _controller.newSession();
      return;
    }

    final agentServers = _config.selectableAgentServers;
    if (agentServers.isEmpty) {
      await _controller.newSession();
      if (mounted) setState(() {});
      return;
    }

    final selected = agentServers.length == 1
        ? agentServers.single
        : await showDialog<AgentServerConfig>(
            context: dialogContext,
            builder: (context) => NewSessionAgentDialog(
              agentServers: agentServers,
              currentAgentName: _config.agentName,
            ),
          );
    if (selected == null) return;

    late final AcpClientConfig nextConfig;
    try {
      nextConfig = _config.withActiveAgentServer(selected.name);
    } catch (error) {
      _showSnackBar('Could not select agent: $error');
      return;
    }

    final controller = _activateAgent(nextConfig);
    await controller.newSession();
    if (mounted) setState(() {});
  }

  Future<void> _selectSession(AgentSession session) async {
    if (_controller.isStreaming || _controller.isSessionOperationRunning) {
      return;
    }

    var controller = _controller;
    if (widget.controller == null) {
      final sessionAgentName = session.agentName?.trim();
      if (sessionAgentName != null &&
          sessionAgentName.isNotEmpty &&
          sessionAgentName != _config.agentName) {
        try {
          controller = _activateAgent(
            _config.withActiveAgentServer(sessionAgentName),
          );
        } catch (error) {
          _showSnackBar('Could not select agent: $error');
          return;
        }
      }
    }

    if (controller.currentSession?.id == session.id) return;
    await controller.resumeSession(
      session.id,
      cwd: session.cwd,
      title: session.title,
      updatedAt: session.updatedAt,
    );
    if (mounted) setState(() {});
  }

  ChatController _activateAgent(AcpClientConfig nextConfig) {
    final controller = _controllersByAgent.putIfAbsent(
      nextConfig.agentName,
      () => _controllerFor(nextConfig),
    );
    setState(() {
      _config = nextConfig;
      _controller = controller;
    });
    return controller;
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    _messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  DartAcpAgentClient _agentClient(AgentServerConfig? server) {
    if (server == null) {
      return DartAcpAgentClient();
    }
    return DartAcpAgentClient(
      agentCommand: server.command,
      agentArgs: server.args,
      envOverrides: server.env,
    );
  }

  List<ChatController> get _sessionControllers {
    if (widget.controller != null) return <ChatController>[_controller];
    return _controllersByAgent.values.toList();
  }
}
