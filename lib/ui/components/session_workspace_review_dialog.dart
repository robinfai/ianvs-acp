import 'package:flutter/material.dart';

import '../../acp/agent_session.dart';
import '../theme/app_design_tokens.dart';

Future<bool> showSessionWorkspaceReviewDialog(
  BuildContext context,
  AgentSession session,
) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => SessionWorkspaceReviewDialog(session: session),
      ) ??
      false;
}

class SessionWorkspaceReviewDialog extends StatelessWidget {
  const SessionWorkspaceReviewDialog({super.key, required this.session});

  final AgentSession session;

  @override
  Widget build(BuildContext context) {
    final additionalDirectories = _visibleAdditionalDirectories(session);
    final agentName = session.agentName?.trim();
    return AlertDialog(
      clipBehavior: Clip.antiAlias,
      surfaceTintColor: Colors.transparent,
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      actionsAlignment: MainAxisAlignment.end,
      title: const Text(
        'Review Session Workspace',
        style: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.displayTitle,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (agentName != null && agentName.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  agentName,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'Confirm the folders this session can use for local files and terminal commands.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 14),
              _WorkspacePath(label: 'Main workspace', path: session.cwd.trim()),
              for (final directory in additionalDirectories) ...[
                const SizedBox(height: 10),
                _WorkspacePath(label: 'Additional directory', path: directory),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.textSecondary,
            minimumSize: const Size(88, 40),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            minimumSize: const Size(148, 40),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: const Text('Resume Session'),
        ),
      ],
    );
  }
}

List<String> _visibleAdditionalDirectories(AgentSession session) {
  final mainWorkspace = session.cwd.trim();
  final seen = <String>{if (mainWorkspace.isNotEmpty) mainWorkspace};
  final directories = <String>[];
  for (final rawDirectory in session.additionalDirectories) {
    final directory = rawDirectory.trim();
    if (directory.isEmpty || !seen.add(directory)) continue;
    directories.add(directory);
  }
  return directories;
}

class _WorkspacePath extends StatelessWidget {
  const _WorkspacePath({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            path,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: AppTypography.monoFamily,
              fontFamilyFallback: AppTypography.monoFallback,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}
