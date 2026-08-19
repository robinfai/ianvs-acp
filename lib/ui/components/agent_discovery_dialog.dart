import 'package:flutter/material.dart';

import '../../config/acp_client_config.dart';
import '../theme/app_design_tokens.dart';

class AgentDiscoveryDialog extends StatefulWidget {
  const AgentDiscoveryDialog({super.key, required this.agentServers});

  final List<AgentServerConfig> agentServers;

  @override
  State<AgentDiscoveryDialog> createState() => _AgentDiscoveryDialogState();
}

class _AgentDiscoveryDialogState extends State<AgentDiscoveryDialog> {
  late final Set<String> _selectedNames = widget.agentServers
      .map((server) => server.name)
      .toSet();

  @override
  Widget build(BuildContext context) {
    final selectedServers = widget.agentServers
        .where((server) => _selectedNames.contains(server.name))
        .toList(growable: false);
    return AlertDialog(
      title: const Text('Discovered ACP Agents'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select the local ACP agents to add to settings.json.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 12),
            for (final server in widget.agentServers) ...[
              _DiscoveredAgentTile(
                server: server,
                selected: _selectedNames.contains(server.name),
                onChanged: (selected) => setState(() {
                  if (selected) {
                    _selectedNames.add(server.name);
                  } else {
                    _selectedNames.remove(server.name);
                  }
                }),
              ),
              if (server != widget.agentServers.last) const SizedBox(height: 8),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(<AgentServerConfig>[]),
          child: const Text('Skip'),
        ),
        FilledButton(
          onPressed: selectedServers.isEmpty
              ? null
              : () => Navigator.of(context).pop(selectedServers),
          child: const Text('Add Agents'),
        ),
      ],
    );
  }
}

class _DiscoveredAgentTile extends StatelessWidget {
  const _DiscoveredAgentTile({
    required this.server,
    required this.selected,
    required this.onChanged,
  });

  final AgentServerConfig server;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => onChanged(!selected),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected ? AppColors.primaryMist : AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected
                  ? AppColors.primary.withValues(alpha: 0.22)
                  : AppColors.border,
            ),
          ),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: (value) => onChanged(value ?? false),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.hub_outlined,
                size: 20,
                color: selected
                    ? AppColors.primaryDark
                    : AppColors.textTertiary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      server.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _serverTarget(server),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _serverTarget(AgentServerConfig server) {
  return server.safeDisplayTarget;
}
