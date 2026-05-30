import 'package:flutter/material.dart';

import '../../config/acp_client_config.dart';
import '../theme/app_design_tokens.dart';

class NewSessionAgentDialog extends StatelessWidget {
  const NewSessionAgentDialog({
    super.key,
    required this.agentServers,
    required this.currentAgentName,
  });

  final List<AgentServerConfig> agentServers;
  final String currentAgentName;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Session'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final server in agentServers) ...[
              _AgentChoiceTile(
                server: server,
                selected: server.name == currentAgentName,
                onTap: () => Navigator.of(context).pop(server),
              ),
              if (server != agentServers.last) const SizedBox(height: 8),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _AgentChoiceTile extends StatelessWidget {
  const _AgentChoiceTile({
    required this.server,
    required this.selected,
    required this.onTap,
  });

  final AgentServerConfig server;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
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
              Icon(
                selected ? Icons.check_circle_rounded : Icons.hub_outlined,
                size: 20,
                color: selected ? AppColors.success : AppColors.primaryDark,
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
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      server.command,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
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
