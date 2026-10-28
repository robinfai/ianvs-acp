import 'package:ianvs_design/ianvs_design.dart';
import '../../chat_theme.dart';

/// A shared approval surface. It never interprets or authorizes an action.
/// Host-provided widgets retain their keys, focus nodes and lifecycle guards.
class ChatDecisionCard extends StatelessWidget {
  const ChatDecisionCard({
    super.key,
    this.title,
    this.description,
    this.body,
    this.actions = const [],
  });
  final Widget? title;
  final Widget? description;
  final Widget? body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = ChatTheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.warning.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
        border: Border.all(color: theme.warning.withValues(alpha: .30)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?title,
          if (description != null) ...[const SizedBox(height: 6), description!],
          if (body != null) ...[
            if (title != null || description != null) const SizedBox(height: 8),
            body!,
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }
}
