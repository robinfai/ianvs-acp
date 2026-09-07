import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// A cancellation lifetime belongs to one prompt, including its tool rounds.
class ChatCancellation {
  final Completer<void> _done = Completer<void>();
  bool get isCancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!isCancelled) _done.complete();
  }

  void check() {
    if (isCancelled) throw const ChatCancelled();
  }

  Future<T> bind<T>(Future<T> operation) => Future.any([
    operation,
    whenCancelled.then<T>((_) => throw const ChatCancelled()),
  ]);
}

class ChatCancelled implements Exception {
  const ChatCancelled();
  @override
  String toString() => 'Request cancelled.';
}

class ChatApiException implements Exception {
  const ChatApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP $statusCode)';
}

/// One Chat Completions stream. The client is closed on success, failure,
/// subscription cancellation, timeout, and explicit stop; no shared connection
/// lifetime can accidentally cancel another conversation.
class OpenAiChatClient {
  OpenAiChatClient({
    required this.endpoint,
    required this.model,
    this.apiKey,
    this.headers = const {},
    this.extraBody = const {},
    this.requestTimeout = const Duration(minutes: 2),
    this.maxEventBytes = 1024 * 1024,
    this.maxResponseBytes = 16 * 1024 * 1024,
    http.Client Function()? clientFactory,
  }) : clientFactory = clientFactory ?? http.Client.new {
    if (!endpoint.hasAuthority ||
        !['https', 'http'].contains(endpoint.scheme) ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasFragment) {
      throw ArgumentError(
        'Use an absolute HTTP(S) completion endpoint without embedded credentials or a fragment.',
      );
    }
    if (model.trim().isEmpty ||
        requestTimeout <= Duration.zero ||
        maxEventBytes <= 0 ||
        maxResponseBytes < maxEventBytes) {
      throw ArgumentError('Invalid model, timeout, or response budget.');
    }
    if (extraBody.keys.any(
      (key) =>
          const {'model', 'messages', 'stream', 'tools', 'n'}.contains(key),
    )) {
      throw ArgumentError('extraBody cannot override managed request fields.');
    }
    if (headers.keys.any(
      (key) => [
        'authorization',
        'content-type',
        'accept',
      ].contains(key.toLowerCase()),
    )) {
      throw ArgumentError(
        'Use apiKey for authorization; content type and streaming headers are managed by the client.',
      );
    }
  }

  /// Full URL, e.g. https://your-provider.example/v1/chat/completions.
  final Uri endpoint;
  final String model;
  final String? apiKey;
  final Map<String, String> headers;

  /// Provider extensions, e.g. DeepSeek thinking mode or max_tokens.
  /// Routing, messages, streaming and tools remain managed by this client.
  final Map<String, Object?> extraBody;
  final Duration requestTimeout;
  final int maxEventBytes;
  final int maxResponseBytes;
  final http.Client Function() clientFactory;

  Stream<Map<String, Object?>> stream({
    required List<Map<String, Object?>> messages,
    required ChatCancellation cancellation,
    List<Map<String, Object?>> tools = const [],
  }) async* {
    cancellation.check();
    final client = clientFactory();
    var closed = false;
    void close() {
      if (!closed) {
        closed = true;
        client.close();
      }
    }

    unawaited(cancellation.whenCancelled.then((_) => close()));
    final timeout = Timer(requestTimeout, close);
    try {
      final request = http.Request('POST', endpoint)
        ..followRedirects = false
        ..headers.addAll({
          ...headers,
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
          if (apiKey?.isNotEmpty == true) 'Authorization': 'Bearer $apiKey',
        })
        ..body = jsonEncode({
          ...extraBody,
          'model': model,
          'messages': messages,
          'stream': true,
          if (tools.isNotEmpty) 'tools': tools,
        });
      final response = await cancellation.bind(
        client.send(request).timeout(requestTimeout),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Never put credentials or provider echo bodies into UI diagnostics.
        throw ChatApiException(
          'The model request failed',
          statusCode: response.statusCode,
        );
      }
      final events = decodeServerSentEvents(
        response.stream,
        maxEventBytes: maxEventBytes,
        maxResponseBytes: maxResponseBytes,
      );
      final iterator = StreamIterator(events);
      var done = false;
      try {
        while (await cancellation.bind(
          iterator.moveNext().timeout(requestTimeout),
        )) {
          cancellation.check();
          final data = iterator.current;
          if (data.trim() == '[DONE]') {
            done = true;
            break;
          }
          final dynamic value;
          try {
            value = jsonDecode(data);
          } on FormatException {
            throw const ChatApiException(
              'The model returned malformed stream data.',
            );
          }
          if (value is! Map<String, dynamic>) {
            throw const ChatApiException(
              'The model returned an invalid stream event.',
            );
          }
          if (value.containsKey('error')) {
            throw const ChatApiException(
              'The model reported a streaming error.',
            );
          }
          yield Map<String, Object?>.from(value);
        }
      } finally {
        await iterator.cancel();
      }
      cancellation.check();
      if (!done) {
        throw const ChatApiException(
          'The response ended before the completion marker.',
        );
      }
    } on ChatCancelled {
      rethrow;
    } on ChatApiException {
      rethrow;
    } catch (_) {
      cancellation.check();
      throw const ChatApiException(
        'Could not complete the model connection. Check the endpoint and try again.',
      );
    } finally {
      timeout.cancel();
      close();
    }
  }
}

/// Parses UTF-8 SSE independently of network chunk boundaries. Bounds are
/// enforced before assembling an unbounded line or event, including comments.
Stream<String> decodeServerSentEvents(
  Stream<List<int>> bytes, {
  int maxEventBytes = 1024 * 1024,
  int maxResponseBytes = 16 * 1024 * 1024,
}) async* {
  final line = <int>[];
  final data = <String>[];
  var eventBytes = 0;
  var totalBytes = 0;
  var previousCr = false;
  var firstLine = true;
  String? finishLine() {
    var text = utf8.decode(line);
    line.clear();
    if (firstLine) {
      text = text.replaceFirst(RegExp('^\uFEFF'), '');
      firstLine = false;
    }
    if (text.isEmpty) {
      eventBytes = 0;
      if (data.isEmpty) return null;
      final event = data.join('\n');
      data.clear();
      return event;
    }
    if (text.startsWith('data:')) {
      var value = text.substring(5);
      if (value.startsWith(' ')) value = value.substring(1);
      data.add(value);
    }
    return null;
  }

  await for (final chunk in bytes) {
    totalBytes += chunk.length;
    if (totalBytes > maxResponseBytes) {
      throw const ChatApiException(
        'The model response exceeded its size limit.',
      );
    }
    for (final byte in chunk) {
      if (previousCr && byte == 10) {
        previousCr = false;
        continue;
      }
      previousCr = byte == 13;
      eventBytes++;
      if (eventBytes > maxEventBytes) {
        throw const ChatApiException('A stream event exceeded its size limit.');
      }
      if (byte == 10 || byte == 13) {
        final event = finishLine();
        if (event != null) yield event;
      } else {
        line.add(byte);
      }
    }
  }
  if (line.isNotEmpty) {
    final event = finishLine();
    if (event != null) yield event;
  }
  if (data.isNotEmpty) yield data.join('\n');
}
