class MemoryContextItem {
  const MemoryContextItem({required this.kind, required this.text});

  final String kind;
  final String text;
}

class MemoryContextBuilder {
  static String build(List<MemoryContextItem> items) {
    if (items.isEmpty) return '';

    final buffer = StringBuffer()
      ..writeln('<agent_memory_context>')
      ..writeln('The following are relevant long-term memories.')
      ..writeln('Use them as background context only.')
      ..writeln(
        "If they conflict with the user's current instruction, the current instruction wins.",
      );

    for (var index = 0; index < items.length; index += 1) {
      final item = items[index];
      buffer.writeln('${index + 1}. [${item.kind}] ${item.text}');
    }

    buffer.write('</agent_memory_context>');
    return buffer.toString();
  }
}
