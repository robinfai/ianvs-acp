final class AcpAvailableCommandsUpdate {
  AcpAvailableCommandsUpdate({
    required this.sessionId,
    required List<Map<String, Object?>> commands,
  }) : commands = List<Map<String, Object?>>.unmodifiable(
         commands.map((command) {
           final copied = Map<String, Object?>.from(command);
           final input = copied['input'];
           if (input is Map) {
             copied['input'] = Map<String, Object?>.unmodifiable(
               input.map((key, value) => MapEntry(key.toString(), value)),
             );
           }
           return Map<String, Object?>.unmodifiable(copied);
         }),
       );

  final String sessionId;
  final List<Map<String, Object?>> commands;
}
