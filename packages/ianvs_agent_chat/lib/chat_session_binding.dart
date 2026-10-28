import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:ianvs_agent_core/ianvs_agent_core.dart';

class ChatSessionBinding extends StatefulWidget {
  const ChatSessionBinding({
    super.key,
    required this.session,
    required this.builder,
  });
  final ChatSession session;
  final Widget Function(BuildContext, ChatSessionState) builder;
  @override
  State<ChatSessionBinding> createState() => _ChatSessionBindingState();
}

class _ChatSessionBindingState extends State<ChatSessionBinding> {
  StreamSubscription<ChatSessionState>? _subscription;
  late ChatSessionState _state;
  void _bind() {
    final session = widget.session;
    _subscription = session.changes.listen((state) {
      if (mounted && identical(session, widget.session)) {
        setState(() => _state = state);
      }
    });
    _state = session.state;
  }

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(ChatSessionBinding oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      unawaited(_subscription?.cancel());
      _bind();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _state);
}
