import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'memory_extraction.dart';
import 'memory_maintenance_extraction.dart';

class OpenAiCompatibleMemoryExtractor {
  OpenAiCompatibleMemoryExtractor({
    required this.baseUrl,
    required this.model,
    this.apiKey,
    this.timeout = const Duration(seconds: 20),
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient();

  final String baseUrl;
  final String model;
  final String? apiKey;
  final Duration timeout;
  final HttpClient _httpClient;

  Future<List<ExtractedMemoryCandidate>> extract({
    required String userPrompt,
    required String assistantAnswer,
  }) async {
    return (() async {
      final uri = Uri.parse(
        '${baseUrl.replaceFirst(RegExp(r'/*$'), '')}/chat/completions',
      );
      final request = await _httpClient.postUrl(uri);
      request.headers.contentType = ContentType.json;
      final trimmedApiKey = apiKey?.trim();
      if (trimmedApiKey != null && trimmedApiKey.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $trimmedApiKey',
        );
      }
      request.write(
        jsonEncode(<String, Object?>{
          'model': model,
          'temperature': 0,
          'messages': [
            {
              'role': 'user',
              'content': buildMemoryExtractionPrompt(
                userPrompt: userPrompt,
                assistantAnswer: assistantAnswer,
              ),
            },
          ],
        }),
      );
      final response = await request.close();
      final responseBody = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Memory extractor returned HTTP ${response.statusCode}: $responseBody',
          uri: uri,
        );
      }
      final decoded = jsonDecode(responseBody);
      if (decoded is! Map) {
        throw const FormatException('Extractor response must be an object.');
      }
      final content = _contentFromResponse(decoded);
      return parseExtractedMemoryCandidates(content);
    })().timeout(timeout);
  }

  Future<List<MaintenanceChangeRequestSuggestion>> extractMaintenance({
    required List<MemoryMaintenanceItem> memories,
  }) async {
    return (() async {
      final uri = Uri.parse(
        '${baseUrl.replaceFirst(RegExp(r'/*$'), '')}/chat/completions',
      );
      final request = await _httpClient.postUrl(uri);
      request.headers.contentType = ContentType.json;
      final trimmedApiKey = apiKey?.trim();
      if (trimmedApiKey != null && trimmedApiKey.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $trimmedApiKey',
        );
      }
      request.write(
        jsonEncode(<String, Object?>{
          'model': model,
          'temperature': 0,
          'messages': [
            {
              'role': 'user',
              'content': buildMemoryMaintenancePrompt(memories: memories),
            },
          ],
        }),
      );
      final response = await request.close();
      final responseBody = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Memory maintenance extractor returned HTTP ${response.statusCode}: $responseBody',
          uri: uri,
        );
      }
      final decoded = jsonDecode(responseBody);
      if (decoded is! Map) {
        throw const FormatException('Extractor response must be an object.');
      }
      final content = _contentFromResponse(decoded);
      return parseMaintenanceChangeRequests(content);
    })().timeout(timeout);
  }

  void close({bool force = false}) => _httpClient.close(force: force);

  String _contentFromResponse(Map<dynamic, dynamic> decoded) {
    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map) {
        final message = first['message'];
        if (message is Map && message['content'] is String) {
          return message['content'] as String;
        }
        if (first['text'] is String) {
          return first['text'] as String;
        }
      }
    }
    throw const FormatException('Extractor response missing completion text.');
  }
}
