import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../config/acp_client_config.dart';
import '../../state/chat_controller.dart';
import 'permission_history_view.dart';
import 'runtime_inventory_view.dart';
import 'session_activity_view.dart';

enum DiagnosticsTab { events, permissions, runtime }

/// One navigation surface over the existing session and runtime projections.
/// It never owns the controller, changes policy, or persists audit data.
class ActivityDiagnosticsDialog extends StatelessWidget {
  const ActivityDiagnosticsDialog({
    super.key,
    required this.controller,
    required this.runtimeConfig,
    this.initialTab = DiagnosticsTab.events,
    this.permissionExporter,
  });

  final ChatController controller;
  final AcpClientConfig runtimeConfig;
  final DiagnosticsTab initialTab;
  final PermissionHistoryExporter? permissionExporter;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: math.min(840, size.width - 32),
        height: math.min(740, size.height - 32),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: DefaultTabController(
            length: DiagnosticsTab.values.length,
            initialIndex: initialTab.index,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Activity & Diagnostics',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      autofocus: true,
                      tooltip: 'Close diagnostics',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => Text(
                    '${controller.agentName} · ${controller.currentSession?.displayTitle ?? 'No active session'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const TabBar(
                  tabs: [
                    Tab(text: 'Events'),
                    Tab(text: 'Permissions'),
                    Tab(text: 'Runtime'),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) => TabBarView(
                      children: [
                        SessionActivityView(controller: controller),
                        PermissionHistoryView(
                          key: ValueKey((
                            controller,
                            controller.currentSession?.id,
                          )),
                          entries: controller.permissionHistory,
                          exporter: permissionExporter,
                        ),
                        RuntimeInventoryView(
                          controller: controller,
                          runtimeConfig: runtimeConfig,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
