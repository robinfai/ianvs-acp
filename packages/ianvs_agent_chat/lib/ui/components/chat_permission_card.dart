import 'package:flutter/material.dart';
import 'package:ianvs_agent_core/ianvs_agent_core.dart';

/// Presentation only. Hosts validate the request lifecycle before accepting a choice.
class ChatPermissionCard extends StatelessWidget {
  const ChatPermissionCard({
    super.key,
    required this.request,
    required this.onSelectOption,
  });
  final ChatPermissionRequest request;
  final ValueChanged<String>? onSelectOption;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(request.title, style: Theme.of(context).textTheme.titleSmall),
          if (request.rationale.isNotEmpty) Text(request.rationale),
          Wrap(
            spacing: 8,
            children: [
              for (final choice in request.choices)
                OutlinedButton(
                  onPressed: onSelectOption == null
                      ? null
                      : () => onSelectOption!(choice.optionId),
                  child: Text(choice.name),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
