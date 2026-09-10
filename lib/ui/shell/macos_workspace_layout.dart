import 'dart:async';
import 'dart:io';

import 'package:ianvs_design/ianvs_design.dart';
import 'package:flutter/services.dart';

/// Owns window layout preferences independently of streaming session updates.
class MacosWorkspaceLayout extends StatefulWidget {
  const MacosWorkspaceLayout({super.key, required this.builder});

  final Widget Function(
    BuildContext context,
    BoxConstraints constraints,
    MacosWorkspaceLayoutState layout,
  )
  builder;

  @override
  State<MacosWorkspaceLayout> createState() => MacosWorkspaceLayoutState();
}

class MacosWorkspaceLayoutState extends State<MacosWorkspaceLayout> {
  static const _menuChannel = MethodChannel('com.ianvs.acp/workspace-layout');
  static MacosWorkspaceLayoutState? _menuHandlerOwner;
  VoidCallback? onSidebarMenu;
  VoidCallback? onInspectorMenu;
  Future<void> Function()? onSettingsMenu;
  bool _settingsRouteOpen = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS) {
      _menuHandlerOwner = this;
      _menuChannel.setMethodCallHandler((call) async {
        if (!mounted) return;
        switch (call.method) {
          case 'toggleSidebar':
            onSidebarMenu?.call();
          case 'toggleInspector':
            onInspectorMenu?.call();
          case 'openSettings':
            unawaited(openSettings());
        }
      });
    }
  }

  @override
  void dispose() {
    if (Platform.isMacOS && identical(_menuHandlerOwner, this)) {
      _menuHandlerOwner = null;
      _menuChannel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  bool sidebarVisible = true;
  bool inspectorVisible = true;
  double sidebarWidth = 260;

  void toggleSidebar() => setState(() => sidebarVisible = !sidebarVisible);
  void toggleInspector() =>
      setState(() => inspectorVisible = !inspectorVisible);

  Future<void> openSettings() async {
    final callback = onSettingsMenu;
    if (_settingsRouteOpen || callback == null) return;
    _settingsRouteOpen = true;
    try {
      await callback();
    } finally {
      _settingsRouteOpen = false;
    }
  }

  Widget get sidebarDivider => IanvsResizeHandle(
    key: const Key('sidebar-resize-handle'),
    value: sidebarWidth,
    min: 220,
    max: 320,
    resetValue: 260,
    semanticLabel: 'Sidebar width',
    semanticValueFormatter: (value) => '${value.round()} points',
    onChanged: (value) => setState(() => sidebarWidth = value),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
            unawaited(openSettings()),
        if (constraints.maxWidth >= 780)
          const SingleActivator(
            LogicalKeyboardKey.keyS,
            meta: true,
            control: true,
          ): toggleSidebar,
        if (constraints.maxWidth >= 1280)
          const SingleActivator(LogicalKeyboardKey.keyI, meta: true, alt: true):
              toggleInspector,
      },
      child: widget.builder(context, constraints, this),
    ),
  );
}
