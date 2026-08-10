import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ianvs_terminal_core/ianvs_terminal_core.dart';
import 'package:path/path.dart' as path;

import '../acp/agent_session.dart';
import '../ui/theme/app_design_tokens.dart';

typedef AcpTerminalRuntimeFactory = TerminalRuntimeController Function();

typedef AcpSessionTerminalRegionBuilder =
    Widget Function(
      BuildContext context,
      Widget terminalToggle,
      Widget terminalPanel,
    );

TerminalRuntimeController createAcpTerminalRuntime() {
  return TerminalRuntimeController.native(
    copyToClipboard: (text) => Clipboard.setData(ClipboardData(text: text)),
    readClipboard: () async {
      return (await Clipboard.getData('text/plain'))?.text ?? '';
    },
  );
}

/// Adds a lazily-created terminal panel to one active ACP session.
///
/// The native runtime is not loaded until the user opens the panel. Changing
/// or closing the ACP session disposes every terminal tab before the next
/// session is rendered.
class AcpSessionTerminalRegion extends StatefulWidget {
  const AcpSessionTerminalRegion({
    super.key,
    required this.session,
    required this.builder,
    this.runtimeFactory = createAcpTerminalRuntime,
  });

  final AgentSession? session;
  final AcpSessionTerminalRegionBuilder builder;
  final AcpTerminalRuntimeFactory runtimeFactory;

  @override
  State<AcpSessionTerminalRegion> createState() =>
      _AcpSessionTerminalRegionState();
}

class _AcpSessionTerminalRegionState extends State<AcpSessionTerminalRegion> {
  TerminalPanelController? _panelController;

  String? get _sessionIdentity {
    final session = widget.session;
    if (session == null) {
      return null;
    }
    return '${session.agentName ?? ''}\u0000${session.id}\u0000${session.cwd}';
  }

  @override
  void didUpdateWidget(covariant AcpSessionTerminalRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_identityFor(oldWidget.session) != _sessionIdentity ||
        !identical(oldWidget.runtimeFactory, widget.runtimeFactory)) {
      _disposePanel();
    }
  }

  String? _identityFor(AgentSession? session) {
    if (session == null) {
      return null;
    }
    return '${session.agentName ?? ''}\u0000${session.id}\u0000${session.cwd}';
  }

  void _togglePanel() {
    final existing = _panelController;
    if (existing != null) {
      existing.toggle();
      return;
    }
    final session = widget.session;
    if (session == null) {
      return;
    }
    TerminalPanelController? controller;
    try {
      final runtime = widget.runtimeFactory();
      controller = TerminalPanelController(
        runtime: runtime,
        disposeRuntime: true,
        defaultTabFactory: (index) => _terminalTabFor(session, index),
      );
      controller.setOpen(true);
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _panelController = controller;
      });
    } on Object catch (error) {
      controller?.dispose();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open terminal: $error')),
      );
    }
  }

  TerminalPanelTabDefinition _terminalTabFor(AgentSession session, int index) {
    final local = defaultLocalTerminalPanelTab(index);
    final workspaceName = path.basename(path.normalize(session.cwd)).trim();
    final baseTitle = workspaceName.isEmpty || workspaceName == '.'
        ? 'Terminal'
        : workspaceName;
    return TerminalPanelTabDefinition(
      id: '${session.id}-terminal-$index',
      title: index == 1 ? baseTitle : '$baseTitle $index',
      followTerminalTitle: false,
      options: local.options,
      sessionConfig: local.sessionConfig.copyWith(
        launch: local.sessionConfig.launch.copyWith(cwd: session.cwd),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final terminalTheme =
            theme.extension<AppTerminalTheme>() ??
            AppTerminalTheme.conversationCanvas;
        final desiredHeight = constraints.maxHeight * 0.36;
        final availableHeight = math.max<double>(
          140.0,
          constraints.maxHeight - 190,
        );
        final panelHeight = desiredHeight
            .clamp(140.0, math.min<double>(340.0, availableHeight))
            .toDouble();
        final controller = _panelController;
        final terminalPanel = controller == null
            ? const SizedBox.shrink()
            : TerminalBottomPanel(
                key: const Key('acp-terminal-panel'),
                controller: controller,
                style: TerminalBottomPanelStyle(
                  height: panelHeight,
                  headerHeight: 38,
                  backgroundColor: terminalTheme.background,
                  headerColor: colorScheme.surfaceContainerLow,
                  borderColor: colorScheme.outlineVariant,
                  activeTabColor: colorScheme.surfaceContainerLowest,
                  activeTabForegroundColor: colorScheme.onSurface,
                  inactiveTabForegroundColor: colorScheme.onSurfaceVariant,
                  viewportColors: TerminalViewportColors(
                    canvasBackground: terminalTheme.background,
                    foreground: terminalTheme.foreground,
                    cursor: terminalTheme.cursor,
                    selection: terminalTheme.selection,
                    scrollbarTrack: terminalTheme.scrollbarTrack,
                    scrollbarThumb: terminalTheme.scrollbarThumb,
                    minimumContrastRatio: 4.5,
                    smartCursorColor: true,
                  ),
                  viewportPadding: const EdgeInsets.only(
                    left: 12,
                    top: 8,
                    right: 12,
                    bottom: 10,
                  ),
                  useFrameDefaultColors: false,
                ),
              );
        final content = widget.builder(
          context,
          _AcpTerminalToggleAction(
            controller: controller,
            enabled: widget.session != null,
            onPressed: _togglePanel,
          ),
          terminalPanel,
        );
        return CallbackShortcuts(
          bindings: widget.session == null
              ? const <ShortcutActivator, VoidCallback>{}
              : <ShortcutActivator, VoidCallback>{
                  const SingleActivator(
                    LogicalKeyboardKey.backquote,
                    control: true,
                  ): _togglePanel,
                },
          child: content,
        );
      },
    );
  }

  void _disposePanel() {
    _panelController?.dispose();
    _panelController = null;
  }

  @override
  void dispose() {
    _disposePanel();
    super.dispose();
  }
}

class _AcpTerminalToggleAction extends StatelessWidget {
  const _AcpTerminalToggleAction({
    required this.controller,
    required this.enabled,
    required this.onPressed,
  });

  final TerminalPanelController? controller;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (controller == null) {
      return _button(context, open: false);
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _button(context, open: controller.isOpen),
    );
  }

  Widget _button(BuildContext context, {required bool open}) {
    final colorScheme = Theme.of(context).colorScheme;
    final tooltip = !enabled
        ? 'Start a session to use the terminal'
        : open
        ? 'Hide terminal panel (⌃`)'
        : 'Show terminal panel (⌃`)';
    return Semantics(
      button: true,
      selected: open,
      enabled: enabled,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: IconButton(
          key: const Key('acp-terminal-panel-toggle'),
          onPressed: enabled ? onPressed : null,
          style: IconButton.styleFrom(
            minimumSize: const Size.square(32),
            maximumSize: const Size.square(32),
            padding: EdgeInsets.zero,
            foregroundColor: open
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSurfaceVariant,
            backgroundColor: open
                ? colorScheme.primaryContainer
                : Colors.transparent,
            disabledForegroundColor: colorScheme.onSurfaceVariant.withValues(
              alpha: 0.45,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
          ),
          iconSize: 18,
          icon: const Icon(Icons.terminal_rounded),
        ),
      ),
    );
  }
}
