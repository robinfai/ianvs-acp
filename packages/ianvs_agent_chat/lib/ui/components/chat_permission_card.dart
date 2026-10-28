import 'chat_decision_card.dart';
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
  Widget build(BuildContext context) => ChatDecisionCard(
    title: Text(request.title, style: Theme.of(context).textTheme.titleSmall),
    description: request.rationale.isEmpty ? null : Text(request.rationale),
    actions: [
      for (final choice in request.choices)
        OutlinedButton(
          onPressed: onSelectOption == null
              ? null
              : () => onSelectOption!(choice.optionId),
          child: Text(choice.name),
        ),
    ],
  );
}
