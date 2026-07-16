import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:stream_channel/stream_channel.dart';

import 'acp_endpoint_validator.dart';

class StreamableHttpAcpTransport implements acp.AcpTransport {
  StreamableHttpAcpTransport({
    required this.endpoint,
    this.headers = const <String, String>{},
    this.onProtocolOut,
    this.onProtocolIn,
    Duration requestTimeout = const Duration(seconds: 30),
    Duration firstByteTimeout = const Duration(seconds: 15),
    Duration sseIdleTimeout = const Duration(minutes: 5),
    this.byteBudget = const acp.TransportByteBudget(),
    int maxCookieCount = 128,
    int maxCookieBytes = 64 * 1024,
    int maxProtocolObserverErrors = 128,
    DateTime Function()? clock,
  }) : requestTimeout = _positiveDuration(requestTimeout, 'requestTimeout'),
       firstByteTimeout = _positiveDuration(
         firstByteTimeout,
         'firstByteTimeout',
       ),
       sseIdleTimeout = _positiveDuration(sseIdleTimeout, 'sseIdleTimeout'),
       maxCookieCount = _positiveLimit(maxCookieCount, 'maxCookieCount'),
       maxCookieBytes = _positiveLimit(maxCookieBytes, 'maxCookieBytes'),
       maxProtocolObserverErrors = _positiveLimit(
         maxProtocolObserverErrors,
         'maxProtocolObserverErrors',
       ),
       _clock = clock ?? DateTime.now {
    byteBudget.validate();
    validateAcpEndpoint(
      endpoint,
      allowedSchemes: const <String>{'http', 'https'},
    );
  }

  final Uri endpoint;
  final Map<String, String> headers;
  final void Function(String line)? onProtocolOut;
  final void Function(String line)? onProtocolIn;
  final Duration requestTimeout;
  final Duration firstByteTimeout;
  final Duration sseIdleTimeout;
  final acp.TransportByteBudget byteBudget;
  final int maxCookieCount;
  final int maxCookieBytes;
  final int maxProtocolObserverErrors;
  final DateTime Function() _clock;

  final Map<String, String> _pendingMethodsById = <String, String>{};
  final Map<String, String> _serverRequestSessionsById = <String, String>{};
  final Map<String, Future<void>> _streamStartsByKey = <String, Future<void>>{};
  final Map<String, _StoredCookie> _cookiesByName = <String, _StoredCookie>{};
  final List<StreamSubscription<String>> _streamSubscriptions =
      <StreamSubscription<String>>[];
  final Set<acp.TransportBodyReadOperation<Object?>> _pendingBodyReads =
      <acp.TransportBodyReadOperation<Object?>>{};

  static const Duration _teardownTimeout = Duration(seconds: 2);
  static const String _protocolVersionHeader = 'Acp-Protocol-Version';

  HttpClient? _client;
  StreamChannelController<String>? _controller;
  StreamSubscription<String>? _outboundSubscription;
  Future<void>? _stopFuture;
  String? _connectionId;
  bool _stopping = false;
  int _nextGeneration = 0;
  int? _activeGeneration;
  int _protocolObserverFailuresRecorded = 0;

  @override
  StreamChannel<String> get channel {
    final controller = _controller;
    if (controller == null) {
      throw StateError('Transport not started');
    }
    return controller.foreign;
  }

  /// Number of one-shot response bodies currently being read.
  int get activeBodyReadCount => _pendingBodyReads.length;

  @override
  Future<void> start() async {
    for (;;) {
      final stopping = _stopFuture;
      if (stopping == null) break;
      await stopping;
    }
    if (_controller != null) return;
    _stopping = false;
    _client ??= HttpClient();
    final client = _client!;
    final controller = StreamChannelController<String>();
    final generation = ++_nextGeneration;
    _controller = controller;
    _activeGeneration = generation;
    _protocolObserverFailuresRecorded = 0;
    _outboundSubscription = controller.local.stream.listen(
      (line) {
        unawaited(_sendLine(generation, client, controller, line));
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_ownsGeneration(generation, client, controller)) {
          controller.local.sink.addError(error, stackTrace);
        }
      },
    );
  }

  bool _ownsGeneration(
    int generation,
    HttpClient client,
    StreamChannelController<String> controller,
  ) {
    return !_stopping &&
        _activeGeneration == generation &&
        identical(_client, client) &&
        identical(_controller, controller);
  }

  Future<void> _sendLine(
    int generation,
    HttpClient client,
    StreamChannelController<String> controller,
    String line,
  ) async {
    if (!_ownsGeneration(generation, client, controller)) return;
    _notifyProtocolOut(generation, client, controller, line);
    if (!_ownsGeneration(generation, client, controller)) return;
    String? pendingMethodIdKey;
    try {
      final message = jsonDecode(line);
      if (message is! Map<String, dynamic>) {
        throw const FormatException(
          'ACP HTTP transport requires JSON objects.',
        );
      }
      final idKey = _idKey(message['id']);
      final method = message['method'];
      if (idKey != null && method is String) {
        _pendingMethodsById[idKey] = method;
        pendingMethodIdKey = idKey;
      }

      final sessionId = _sessionIdForOutbound(message, idKey);
      final isInitialize = method == 'initialize';
      if (!isInitialize) {
        await _ensureInboundStream(generation, client, controller, null);
        if (!_ownsGeneration(generation, client, controller)) return;
      }
      if (sessionId != null) {
        await _ensureInboundStream(generation, client, controller, sessionId);
        if (!_ownsGeneration(generation, client, controller)) return;
      }

      final cookieHeader = _prepareCookieHeader();
      final request = await client.postUrl(endpoint).timeout(requestTimeout);
      if (!_ownsGeneration(generation, client, controller)) {
        request.abort();
        return;
      }
      request.followRedirects = false;
      _applyRequestHeaders(
        request,
        cookieHeader: cookieHeader,
        contentType: ContentType.json,
        sessionId: sessionId,
      );
      request.write(line);
      final response = await request.close().timeout(firstByteTimeout);
      if (!_ownsGeneration(generation, client, controller)) {
        await _cancelResponse(response);
        return;
      }
      await _storeResponseCookies(response);
      if (!_ownsGeneration(generation, client, controller)) {
        await _cancelResponse(response);
        return;
      }

      final body = await _readResponseBody(
        response,
        resource: 'ACP HTTP POST response body',
        timeout: requestTimeout,
      );
      if (!_ownsGeneration(generation, client, controller)) return;
      if (isInitialize) {
        _handleInitializeResponse(
          generation,
          client,
          controller,
          response,
          body,
        );
        return;
      }
      if (response.statusCode == HttpStatus.accepted && body.trim().isEmpty) {
        return;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _addInboundLine(
          generation,
          client,
          controller,
          body,
          resource: 'ACP HTTP POST JSON',
        );
        return;
      }
      throw HttpException(
        'ACP HTTP POST failed with ${response.statusCode}: ${response.reasonPhrase}',
        uri: endpoint,
      );
    } catch (error, stackTrace) {
      if (!_ownsGeneration(generation, client, controller)) return;
      if (pendingMethodIdKey != null) {
        _pendingMethodsById.remove(pendingMethodIdKey);
      }
      controller.local.sink.addError(error, stackTrace);
    }
  }

  String? _sessionIdForOutbound(Map<String, dynamic> message, String? idKey) {
    final method = message['method'];
    if (method is String) {
      final params = message['params'];
      if (params is Map) {
        final sessionId = _sessionIdFromMap(params);
        if (sessionId != null) return sessionId;
      }
      return null;
    }
    if (idKey == null) return null;
    return _serverRequestSessionsById.remove(idKey);
  }

  void _handleInitializeResponse(
    int generation,
    HttpClient client,
    StreamChannelController<String> controller,
    HttpClientResponse response,
    String body,
  ) {
    if (!_ownsGeneration(generation, client, controller)) return;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'ACP HTTP initialize failed with ${response.statusCode}: ${response.reasonPhrase}',
        uri: endpoint,
      );
    }
    final decoded = _decodeRemoteJsonObject(
      body,
      resource: 'ACP HTTP initialize JSON',
    );
    final connectionId =
        response.headers.value('Acp-Connection-Id') ??
        _stringFromPath(decoded, const ['result', 'connectionId']) ??
        _stringFromPath(decoded, const ['result', 'connection_id']);
    if (connectionId == null || connectionId.trim().isEmpty) {
      throw const FormatException(
        'ACP HTTP initialize response did not include Acp-Connection-Id.',
      );
    }
    _connectionId = connectionId.trim();
    _startInboundStream(generation, client, controller, null);
    _addInboundLine(
      generation,
      client,
      controller,
      body,
      resource: 'ACP HTTP initialize JSON',
      decoded: decoded,
    );
  }

  void _startInboundStream(
    int generation,
    HttpClient client,
    StreamChannelController<String> controller,
    String? sessionId,
  ) {
    unawaited(
      _ensureInboundStream(
        generation,
        client,
        controller,
        sessionId,
      ).catchError((Object error, StackTrace stackTrace) {
        // _ensureInboundStream has already forwarded this failure to the
        // transport channel.
      }),
    );
  }

  Future<void> _ensureInboundStream(
    int generation,
    HttpClient client,
    StreamChannelController<String> controller,
    String? sessionId,
  ) {
    if (!_ownsGeneration(generation, client, controller)) {
      return Future<void>.value();
    }
    final connectionId = _connectionId;
    if (connectionId == null || connectionId.isEmpty) {
      throw StateError('ACP HTTP transport is not initialized.');
    }
    final key = sessionId ?? '';
    final existing = _streamStartsByKey[key];
    if (existing != null) return existing;
    late final Future<void> operation;
    operation = () async {
      try {
        final cookieHeader = _prepareCookieHeader();
        final request = await client.getUrl(endpoint).timeout(requestTimeout);
        if (!_ownsGeneration(generation, client, controller)) {
          request.abort();
          return;
        }
        request.followRedirects = false;
        _applyRequestHeaders(
          request,
          cookieHeader: cookieHeader,
          accept: 'text/event-stream',
        );
        request.headers.set('Acp-Connection-Id', connectionId);
        if (sessionId != null) {
          request.headers.set('Acp-Session-Id', sessionId);
        }
        final response = await request.close().timeout(firstByteTimeout);
        if (!_ownsGeneration(generation, client, controller)) {
          await _cancelResponse(response);
          return;
        }
        await _storeResponseCookies(response);
        if (!_ownsGeneration(generation, client, controller)) {
          await _cancelResponse(response);
          return;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await _drainResponse(
            response,
            resource: 'ACP HTTP SSE error response body',
            timeout: requestTimeout,
          );
          if (!_ownsGeneration(generation, client, controller)) return;
          throw HttpException(
            'ACP HTTP SSE stream failed with ${response.statusCode}: ${response.reasonPhrase}',
            uri: endpoint,
          );
        }
        var streamFailed = false;
        late final StreamSubscription<String> subscription;
        subscription =
            _sseEvents(
              _withSseIdleTimeout(response),
              resource: 'ACP HTTP SSE',
            ).listen(
              (event) => _handleSseEvent(generation, client, controller, event),
              onError: (Object error, StackTrace stackTrace) {
                if (!_ownsGeneration(generation, client, controller)) return;
                streamFailed = true;
                controller.local.sink.addError(error, stackTrace);
              },
              onDone: () {
                if (identical(_streamStartsByKey[key], operation)) {
                  _streamStartsByKey.remove(key);
                }
                _streamSubscriptions.remove(subscription);
                if (_ownsGeneration(generation, client, controller) &&
                    !streamFailed) {
                  controller.local.sink.addError(
                    StateError(
                      sessionId == null
                          ? 'ACP connection SSE stream closed'
                          : 'ACP session SSE stream closed: $sessionId',
                    ),
                    StackTrace.current,
                  );
                }
              },
            );
        if (!_ownsGeneration(generation, client, controller)) {
          await subscription.cancel();
          return;
        }
        _streamSubscriptions.add(subscription);
      } catch (error, stackTrace) {
        if (identical(_streamStartsByKey[key], operation)) {
          _streamStartsByKey.remove(key);
        }
        if (!_ownsGeneration(generation, client, controller)) return;
        controller.local.sink.addError(error, stackTrace);
        rethrow;
      }
    }();
    _streamStartsByKey[key] = operation;
    return operation;
  }

  Stream<List<int>> _withSseIdleTimeout(Stream<List<int>> response) {
    return response.timeout(
      sseIdleTimeout,
      onTimeout: (sink) {
        sink.addError(
          TimeoutException(
            'ACP SSE stream was idle for $sseIdleTimeout',
            sseIdleTimeout,
          ),
          StackTrace.current,
        );
        sink.close();
      },
    );
  }

  Stream<String> _sseEvents(
    Stream<List<int>> response, {
    required String resource,
  }) async* {
    await for (final event in acp.decodeBoundedSse(
      response,
      budget: byteBudget,
      resource: resource,
    )) {
      yield event.data;
    }
  }

  Future<String> _readResponseBody(
    HttpClientResponse response, {
    required String resource,
    required Duration timeout,
  }) async {
    await _enforceResponseContentLength(response, resource: resource);
    return _runBodyRead(
      acp.startBoundedUtf8BodyRead(
        response,
        limit: byteBudget.maxBodyBytes,
        resource: resource,
        timeout: timeout,
      ),
    );
  }

  Future<void> _drainResponse(
    HttpClientResponse response, {
    required String resource,
    required Duration timeout,
  }) async {
    await _enforceResponseContentLength(response, resource: resource);
    await _runBodyRead(
      acp.startBoundedByteDrain(
        response,
        limit: byteBudget.maxBodyBytes,
        resource: resource,
        timeout: timeout,
      ),
    );
  }

  Future<T> _runBodyRead<T>(acp.TransportBodyReadOperation<T> operation) async {
    _pendingBodyReads.add(operation);
    try {
      return await operation.future;
    } finally {
      _pendingBodyReads.remove(operation);
    }
  }

  Future<void> _cancelPendingBodyReads() async {
    final pending = List<acp.TransportBodyReadOperation<Object?>>.of(
      _pendingBodyReads,
    );
    await Future.wait<void>([
      for (final operation in pending)
        operation.cancel().catchError((Object _) {}),
    ]);
  }

  Future<void> _enforceResponseContentLength(
    HttpClientResponse response, {
    required String resource,
  }) async {
    try {
      acp.enforceTransportContentLength(
        contentLength: response.contentLength,
        limit: byteBudget.maxBodyBytes,
        resource: resource,
      );
    } on acp.TransportByteLimitExceeded {
      final subscription = response.listen((_) {});
      await subscription.cancel();
      rethrow;
    }
  }

  void _handleSseEvent(
    int generation,
    HttpClient client,
    StreamChannelController<String> controller,
    String event,
  ) {
    if (!_ownsGeneration(generation, client, controller)) return;
    if (event.trim().isEmpty) return;
    try {
      _addInboundLine(
        generation,
        client,
        controller,
        event,
        resource: 'ACP HTTP SSE JSON',
      );
    } catch (error, stackTrace) {
      if (_ownsGeneration(generation, client, controller)) {
        controller.local.sink.addError(error, stackTrace);
      }
    }
  }

  void _addInboundLine(
    int generation,
    HttpClient client,
    StreamChannelController<String> controller,
    String line, {
    required String resource,
    Map<String, dynamic>? decoded,
  }) {
    if (!_ownsGeneration(generation, client, controller)) return;
    if (line.trim().isEmpty) return;
    final message =
        decoded ?? _decodeRemoteJsonObject(line, resource: resource);
    if (!_ownsGeneration(generation, client, controller)) return;
    _captureInboundMetadata(generation, client, controller, message);
    _notifyProtocolIn(generation, client, controller, line);
    if (_ownsGeneration(generation, client, controller)) {
      controller.local.sink.add(line);
    }
  }

  Map<String, dynamic> _decodeRemoteJsonObject(
    String source, {
    required String resource,
  }) {
    final decoded = acp.decodeTransportJson(source, resource: resource);
    if (decoded is! Map) {
      throw acp.TransportProtocolDecodeError(resource: resource);
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  void _notifyProtocolOut(
    int generation,
    HttpClient client,
    StreamChannelController<String> controller,
    String line,
  ) {
    try {
      onProtocolOut?.call(line);
    } on Object {
      _recordProtocolObserverFailure(generation, client, controller);
    }
  }

  void _recordProtocolObserverFailure(
    int generation,
    HttpClient client,
    StreamChannelController<String> controller,
  ) {
    if (!_ownsGeneration(generation, client, controller) ||
        _protocolObserverFailuresRecorded >= maxProtocolObserverErrors) {
      return;
    }
    _protocolObserverFailuresRecorded += 1;
  }

  void _notifyProtocolIn(
    int generation,
    HttpClient client,
    StreamChannelController<String> controller,
    String line,
  ) {
    try {
      onProtocolIn?.call(line);
    } on Object {
      _recordProtocolObserverFailure(generation, client, controller);
    }
  }

  void _captureInboundMetadata(
    int generation,
    HttpClient client,
    StreamChannelController<String> controller,
    Map<String, dynamic> decoded,
  ) {
    if (!_ownsGeneration(generation, client, controller)) return;
    final idKey = _idKey(decoded['id']);
    final isResponse =
        decoded.containsKey('result') || decoded.containsKey('error');
    if (idKey != null && isResponse) {
      final method = _pendingMethodsById.remove(idKey);
      if (decoded.containsKey('result') &&
          (method == 'session/new' ||
              method == 'session/load' ||
              method == 'session/resume' ||
              method == 'session/fork')) {
        final sessionId = _sessionIdFromResult(decoded);
        if (sessionId != null) {
          _startInboundStream(generation, client, controller, sessionId);
        }
      }
    }
    final method = decoded['method'];
    if (idKey != null && method is String) {
      final params = decoded['params'];
      final sessionId = params is Map ? _sessionIdFromMap(params) : null;
      if (sessionId != null) {
        _serverRequestSessionsById[idKey] = sessionId;
      }
    }
  }

  void _applyRequestHeaders(
    HttpClientRequest request, {
    required String? cookieHeader,
    ContentType? contentType,
    String? accept,
    String? sessionId,
  }) {
    for (final entry in headers.entries) {
      if (_isCookieHeader(entry.key)) continue;
      request.headers.set(entry.key, entry.value);
    }
    if (contentType != null) {
      request.headers.contentType = contentType;
    }
    if (accept != null) {
      request.headers.set(HttpHeaders.acceptHeader, accept);
    }
    final connectionId = _connectionId;
    if (connectionId != null && connectionId.isNotEmpty) {
      request.headers.set('Acp-Connection-Id', connectionId);
      request.headers.set(_protocolVersionHeader, '1');
    }
    if (sessionId != null && sessionId.isNotEmpty) {
      request.headers.set('Acp-Session-Id', sessionId);
    }
    if (cookieHeader != null) {
      request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
    }
  }

  void _storeCookies(List<Cookie> cookies) {
    if (cookies.isEmpty) return;
    final staged = Map<String, _StoredCookie>.of(_cookiesByName);
    final now = _clock();
    _pruneExpiredCookies(staged, now);
    for (final cookie in cookies) {
      final maxAge = cookie.maxAge;
      final DateTime? expiresAt;
      if (maxAge != null) {
        if (maxAge <= 0) {
          staged.remove(cookie.name);
          continue;
        }
        expiresAt = _maxAgeExpiration(now, maxAge);
      } else {
        expiresAt = cookie.expires;
      }
      if (expiresAt != null && !expiresAt.isAfter(now)) {
        staged.remove(cookie.name);
      } else {
        staged[cookie.name] = _StoredCookie(cookie, expiresAt: expiresAt);
      }
    }
    _prepareCookieHeader(cookies: staged);
    _cookiesByName
      ..clear()
      ..addAll(staged);
  }

  String? _prepareCookieHeader({Map<String, _StoredCookie>? cookies}) {
    final configuredValues = <String>[
      for (final entry in headers.entries)
        if (_isCookieHeader(entry.key) && entry.value.isNotEmpty) entry.value,
    ];
    final jar = cookies ?? _cookiesByName;
    _pruneExpiredCookies(jar, _clock());
    final configuredCount = configuredValues.fold<int>(
      0,
      (count, value) =>
          count +
          value.split(';').where((part) => part.trim().isNotEmpty).length,
    );
    final observedCount = configuredCount + jar.length;
    if (observedCount > maxCookieCount) {
      throw acp.TransportByteLimitExceeded(
        resource: 'ACP HTTP cookies',
        limit: maxCookieCount,
        observedAtLeast: observedCount,
      );
    }
    final segments = <String>[
      ...configuredValues,
      ...jar.values.map((stored) => _requestCookiePair(stored.cookie)),
    ];
    if (segments.isEmpty) return null;
    final header = segments.join('; ');
    final headerBytes = utf8.encode(header).length;
    if (headerBytes > maxCookieBytes) {
      throw acp.TransportByteLimitExceeded(
        resource: 'ACP HTTP cookie header bytes',
        limit: maxCookieBytes,
        observedAtLeast: headerBytes,
      );
    }
    return header;
  }

  Future<void> _storeResponseCookies(HttpClientResponse response) async {
    final List<Cookie> cookies;
    try {
      cookies = response.cookies;
    } on Object {
      await _cancelResponse(response);
      throw acp.TransportProtocolDecodeError(
        resource: 'ACP HTTP response cookies',
      );
    }
    try {
      _storeCookies(cookies);
    } on Object {
      await _cancelResponse(response);
      rethrow;
    }
  }

  Future<void> _cancelResponse(HttpClientResponse response) async {
    try {
      final subscription = response.listen((_) {});
      await subscription.cancel();
    } on Object {
      // Preserve the payload-free protocol or budget failure.
    }
  }

  String? _idKey(Object? id) {
    if (id == null) return null;
    return jsonEncode(id);
  }

  String? _stringFromPath(Map<String, dynamic> json, List<String> path) {
    Object? current = json;
    for (final key in path) {
      if (current is! Map) return null;
      current = current[key];
    }
    return current is String && current.trim().isNotEmpty
        ? current.trim()
        : null;
  }

  String? _sessionIdFromResult(Map<String, dynamic> json) {
    final result = json['result'];
    if (result is! Map) return null;
    return _sessionIdFromMap(result) ?? _nonEmptyString(result['id']);
  }

  String? _sessionIdFromMap(Map map) {
    return _nonEmptyString(map['sessionId']) ??
        _nonEmptyString(map['session_id']);
  }

  String? _nonEmptyString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<void> stop() {
    final existing = _stopFuture;
    if (existing != null) return existing;
    final future = _stop();
    _stopFuture = future;
    unawaited(
      future
          .whenComplete(() {
            if (identical(_stopFuture, future)) _stopFuture = null;
          })
          .catchError((Object _) {}),
    );
    return future;
  }

  Future<void> _stop() async {
    _activeGeneration = null;
    _stopping = true;
    final sseCancellations = _cancelSseSubscriptions();
    await _outboundSubscription?.cancel();
    _outboundSubscription = null;
    await _cancelPendingBodyReads();
    await _terminateConnection();
    await _cancelPendingBodyReads();
    _client?.close(force: true);
    _client = null;
    await Future.wait<void>(sseCancellations);
    await Future.wait<void>(_cancelSseSubscriptions());
    await _controller?.local.sink.close();
    _controller = null;
    _connectionId = null;
    _pendingMethodsById.clear();
    _serverRequestSessionsById.clear();
    _streamStartsByKey.clear();
    _cookiesByName.clear();
  }

  List<Future<void>> _cancelSseSubscriptions() {
    final subscriptions = List<StreamSubscription<String>>.of(
      _streamSubscriptions,
    );
    _streamSubscriptions.clear();
    return <Future<void>>[
      for (final subscription in subscriptions)
        subscription.cancel().catchError((Object _) {}),
    ];
  }

  Future<void> _terminateConnection() async {
    final connectionId = _connectionId;
    if (connectionId == null || connectionId.isEmpty) return;
    final client = _client;
    if (client == null) return;
    try {
      final cookieHeader = _prepareCookieHeader();
      final request = await client
          .deleteUrl(endpoint)
          .timeout(_teardownTimeout);
      request.followRedirects = false;
      _applyRequestHeaders(request, cookieHeader: cookieHeader);
      request.headers.set('Acp-Connection-Id', connectionId);
      final response = await request.close().timeout(_teardownTimeout);
      await _storeResponseCookies(response);
      await _drainResponse(
        response,
        resource: 'ACP HTTP DELETE response body',
        timeout: _teardownTimeout,
      );
    } on acp.TransportByteLimitExceeded catch (error, stackTrace) {
      _controller?.local.sink.addError(error, stackTrace);
    } on acp.TransportProtocolDecodeError catch (error, stackTrace) {
      _controller?.local.sink.addError(error, stackTrace);
    } on Object {
      // Remote teardown is best effort; local disposal must always finish.
    }
  }
}

String _requestCookiePair(Cookie cookie) => '${cookie.name}=${cookie.value}';

class _StoredCookie {
  const _StoredCookie(this.cookie, {required this.expiresAt});

  final Cookie cookie;
  final DateTime? expiresAt;
}

void _pruneExpiredCookies(Map<String, _StoredCookie> cookies, DateTime now) {
  cookies.removeWhere((_, stored) {
    final expiresAt = stored.expiresAt;
    return expiresAt != null && !expiresAt.isAfter(now);
  });
}

DateTime _maxAgeExpiration(DateTime receivedAt, int seconds) {
  final receivedUtc = receivedAt.toUtc();
  final safeMaximum = DateTime.utc(9999, 12, 31, 23, 59, 59, 999, 999);
  if (!receivedUtc.isBefore(safeMaximum)) return safeMaximum;
  final remainingMicroseconds =
      safeMaximum.microsecondsSinceEpoch - receivedUtc.microsecondsSinceEpoch;
  final remainingWholeSeconds =
      remainingMicroseconds ~/ Duration.microsecondsPerSecond;
  if (seconds > remainingWholeSeconds) return safeMaximum;
  return receivedUtc.add(Duration(seconds: seconds));
}

bool _isCookieHeader(String name) =>
    name.toLowerCase() == HttpHeaders.cookieHeader;

int _positiveLimit(int value, String name) {
  if (value <= 0) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
  return value;
}

Duration _positiveDuration(Duration value, String name) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
  return value;
}
