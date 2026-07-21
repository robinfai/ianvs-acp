import 'package:flutter/material.dart';

import '../../startup/deep_link_request.dart';

class DeepLinkConfirmationDialog extends StatelessWidget {
  const DeepLinkConfirmationDialog({required this.request, super.key});

  final DeepLinkRequest request;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Open external session?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Another application requested access to an ACP session. '
                'Review every value before continuing.',
              ),
              const SizedBox(height: 16),
              _RequestValue(
                label: 'Agent',
                value: request.agentName ?? 'Default',
              ),
              _RequestValue(
                label: 'Session',
                value: request.sessionId ?? 'Missing',
              ),
              _RequestValue(
                label: 'Workspace',
                value: request.cwd ?? 'Missing',
              ),
              if (request.validationErrors.isNotEmpty) ...[
                const SizedBox(height: 12),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final error in request.validationErrors)
                          Text(
                            error,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: request.canConfirm
              ? () => Navigator.of(context).pop(true)
              : null,
          child: const Text('Open Session'),
        ),
      ],
    );
  }
}

class _RequestValue extends StatelessWidget {
  const _RequestValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 2),
          SelectableText(value),
        ],
      ),
    );
  }
}
