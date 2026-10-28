import 'package:ianvs_design/ianvs_design.dart';
import 'package:ianvs_agent_core/models/chat_message.dart';
import '../../chat_theme.dart';

/// Presentation only: the host owns identity, ordering, scrolling and lifecycle.
class ChatMessageFrame extends StatelessWidget {
  const ChatMessageFrame({
    super.key,
    required this.role,
    required this.child,
    this.roleLabel,
    this.leading,
    this.actions = const [],
    this.footer,
    this.showRole = true,
  });

  final ChatMessageRole role;
  final Widget child;
  final String? roleLabel;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? footer;
  final bool showRole;

  @override
  Widget build(BuildContext context) {
    final theme = ChatTheme.of(context);
    final user = role == ChatMessageRole.user;
    final label =
        roleLabel ??
        switch (role) {
          ChatMessageRole.user => 'User',
          ChatMessageRole.assistant => 'Assistant',
          ChatMessageRole.tool => 'Tool',
          ChatMessageRole.error => 'Error',
          ChatMessageRole.status => 'Status',
        };
    final background = switch (role) {
      ChatMessageRole.user => theme.userMessageSurface,
      ChatMessageRole.assistant => Colors.transparent,
      ChatMessageRole.tool => theme.warning.withValues(alpha: .08),
      ChatMessageRole.error => theme.danger.withValues(alpha: .08),
      ChatMessageRole.status => theme.surfaceRaised,
    };
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: theme.contentMaxWidth),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(context.ianvs.panelRadius),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final header = Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ?leading,
                  if (showRole)
                    Text(
                      label,
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              );
              final content = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: user && !showRole
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.stretch,
                children: [
                  child,
                  if (footer != null) ...[const SizedBox(height: 8), footer!],
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: actions),
                  ],
                ],
              );
              if (!showRole && leading == null) return content;
              if (constraints.maxWidth < 600) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [header, const SizedBox(height: 8), content],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 96, child: header),
                  const SizedBox(width: 12),
                  Expanded(child: content),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
