import 'dart:convert';
import 'dart:io';

import 'memory_context_builder.dart';

class MemoryScopeData {
  const MemoryScopeData({
    required this.userId,
    this.workspaceId,
    this.repoId,
    this.agentId,
    this.sessionId,
  });

  final String userId;
  final String? workspaceId;
  final String? repoId;
  final String? agentId;
  final String? sessionId;

  Map<String, Object?> toJson() => <String, Object?>{
    'userId': userId,
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (repoId != null) 'repoId': repoId,
    if (agentId != null) 'agentId': agentId,
    if (sessionId != null) 'sessionId': sessionId,
  };
}

class MemorySearchRequest {
  const MemorySearchRequest({
    required this.query,
    required this.scope,
    this.limit = 12,
  });

  final String query;
  final MemoryScopeData scope;
  final int limit;

  Map<String, Object?> toJson() => <String, Object?>{
    'query': query,
    'scope': scope.toJson(),
    'limit': limit,
  };
}

class MemorySearchItem {
  const MemorySearchItem({
    required this.id,
    required this.kind,
    required this.scope,
    required this.text,
    required this.score,
  });

  final String id;
  final String kind;
  final String scope;
  final String text;
  final double score;

  factory MemorySearchItem.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Memory search item must be an object.');
    }
    return MemorySearchItem(
      id: raw['id'] as String? ?? '',
      kind: raw['kind'] as String? ?? '',
      scope: raw['scope'] as String? ?? '',
      text: raw['text'] as String? ?? '',
      score: (raw['score'] as num? ?? 0).toDouble(),
    );
  }
}

class MemoryApiClient {
  MemoryApiClient({
    required this.baseUrl,
    required this.token,
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient();

  final Uri baseUrl;
  final String token;
  final HttpClient _httpClient;

  Future<List<MemorySearchItem>> search(MemorySearchRequest request) async {
    final response = await _postJson('/v1/memory/search', request.toJson());
    final items = response['items'];
    if (items is! List) return const <MemorySearchItem>[];
    return items.map(MemorySearchItem.fromJson).toList(growable: false);
  }

  Future<String?> searchContext(MemorySearchRequest request) async {
    final items = await search(request);
    if (items.isEmpty) return null;
    return MemoryContextBuilder.build(
      items
          .map((item) => MemoryContextItem(kind: item.kind, text: item.text))
          .toList(growable: false),
    );
  }

  void close({bool force = false}) => _httpClient.close(force: force);

  Future<Map<String, Object?>> _postJson(
    String path,
    Map<String, Object?> body,
  ) async {
    final uri = baseUrl.resolve(path);
    final request = await _httpClient.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.write(jsonEncode(body));
    final response = await request.close();
    final responseBody = await utf8.decodeStream(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Memory daemon returned HTTP ${response.statusCode}: $responseBody',
        uri: uri,
      );
    }
    final decoded = jsonDecode(responseBody);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Memory daemon response must be an object.');
    }
    return decoded;
  }
}
