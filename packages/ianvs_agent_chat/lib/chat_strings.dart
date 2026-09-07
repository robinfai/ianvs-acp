import 'package:flutter/widgets.dart';

/// Override the primary composer labels without replacing a backend.
class ChatStrings extends InheritedWidget {
  const ChatStrings({
    super.key,
    required super.child,
    this.send = 'Send',
    this.stop = 'Stop',
    this.promptHint = _defaultHint,
  });
  final String send;
  final String stop;
  final String Function(String agentName) promptHint;
  static String _defaultHint(String name) => '发送消息给 $name';
  static ChatStrings? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatStrings>();
  @override
  bool updateShouldNotify(ChatStrings oldWidget) =>
      send != oldWidget.send ||
      stop != oldWidget.stop ||
      promptHint != oldWidget.promptHint;
}
