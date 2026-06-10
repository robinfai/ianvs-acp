import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/acp_memory_middleware.dart';

void main() {
  test(
    'search failure returns original prompt and records nonfatal error',
    () async {
      final middleware = AcpMemoryMiddleware(
        search: (_) async => throw StateError('down'),
      );
      final result = await middleware.preparePrompt('hello');
      expect(result.prompt, 'hello');
      expect(result.memoryContext, isNull);
      expect(result.error, contains('down'));
    },
  );
}
