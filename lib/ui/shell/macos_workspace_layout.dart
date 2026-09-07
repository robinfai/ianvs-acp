import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_design_tokens.dart';

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
  VoidCallback? onSidebarMenu;
  VoidCallback? onInspectorMenu;

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS) {
      _menuChannel.setMethodCallHandler((call) async {
        if (!mounted) return;
        switch (call.method) {
          case 'toggleSidebar':
            onSidebarMenu?.call();
          case 'toggleInspector':
            onInspectorMenu?.call();
        }
      });
    }
  }

  @override
  void dispose() {
    if (Platform.isMacOS) _menuChannel.setMethodCallHandler(null);
    super.dispose();
  }

  bool sidebarVisible = true;
  bool inspectorVisible = true;
  double sidebarWidth = 260;

  void toggleSidebar() => setState(() => sidebarVisible = !sidebarVisible);
  void toggleInspector() =>
      setState(() => inspectorVisible = !inspectorVisible);

  void _resize(double delta) => setState(() {
    sidebarWidth = (sidebarWidth + delta).clamp(220.0, 320.0);
  });

  Widget get sidebarDivider => Semantics(
    container: true,
    label: 'Sidebar width',
    value: '${sidebarWidth.round()} points',
    increasedValue: '${(sidebarWidth + 20).clamp(220, 320).round()} points',
    decreasedValue: '${(sidebarWidth - 20).clamp(220, 320).round()} points',
    onIncrease: () => _resize(20),
    onDecrease: () => _resize(-20),
    child: MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        key: const Key('sidebar-resize-handle'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => _resize(details.delta.dx),
        onDoubleTap: () => setState(() => sidebarWidth = 260),
        child: const SizedBox(
          width: 5,
          child: Center(
            child: VerticalDivider(width: 1, color: AppColors.border),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => CallbackShortcuts(
      bindings: {
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
