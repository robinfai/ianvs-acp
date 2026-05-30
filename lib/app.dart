import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'acp/dart_acp_agent_client.dart';
import 'config/acp_client_config.dart';
import 'state/chat_controller.dart';
import 'ui/shell/app_shell.dart';
import 'ui/theme/app_design_tokens.dart';

class AcpClientApp extends StatefulWidget {
  const AcpClientApp({
    super.key,
    this.controller,
    this.config = const AcpClientConfig(),
  });

  final ChatController? controller;
  final AcpClientConfig config;

  @override
  State<AcpClientApp> createState() => _AcpClientAppState();
}

class _AcpClientAppState extends State<AcpClientApp> {
  static const String _initialResumeSessionId = String.fromEnvironment(
    'ACP_RESUME_SESSION_ID',
  );
  static const String _workspaceCwd = String.fromEnvironment(
    'ACP_WORKSPACE_CWD',
  );

  late final ChatController _controller =
      widget.controller ??
      ChatController(
        client: _agentClient(widget.config.activeAgentServer),
        cwd: _workspaceCwd.isEmpty ? Directory.current.path : _workspaceCwd,
      );

  @override
  void initState() {
    super.initState();
    if (_initialResumeSessionId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_controller.resumeSession(_initialResumeSessionId));
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ACP Client',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: AppColors.bg,
        useMaterial3: true,
        fontFamily: 'SF Pro Display',
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: AppColors.primary,
          selectionColor: AppColors.primary.withValues(alpha: 0.18),
        ),
      ),
      home: AppShell(
        controller: _controller,
        agentName: widget.config.agentName,
      ),
    );
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
}
