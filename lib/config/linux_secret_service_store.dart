import 'dart:convert';
import 'dart:io';

import 'secret_store.dart';

final class LinuxSecretToolResult {
  const LinuxSecretToolResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

typedef LinuxSecretToolRunner =
    Future<LinuxSecretToolResult> Function(
      List<String> arguments, {
      String? input,
    });

/// Stores ACP configuration secrets in the desktop Secret Service collection.
///
/// `secret-tool` receives secret material only over stdin. Values are wrapped
/// in a versioned base64 envelope so trailing newlines survive its text CLI.
final class LinuxSecretServiceStore implements SecretStore {
  LinuxSecretServiceStore({LinuxSecretToolRunner? processRunner})
    : _processRunner = processRunner ?? _runSecretTool;

  static final RegExp _referencePattern = RegExp(
    r'^secret-service://ianvs-acp/([0-9a-f]{64})$',
  );
  static const String _valueEnvelope = 'ianvs-acp:v1:';

  final LinuxSecretToolRunner _processRunner;

  @override
  Future<String> put({
    required String namespace,
    required String key,
    required String value,
  }) async {
    final account = secretAccountFor(namespace: namespace, key: key);
    final result = await _processRunner(<String>[
      'store',
      '--label=ianvs ACP',
      'application',
      'ianvs-acp',
      'account',
      account,
    ], input: '$_valueEnvelope${base64Encode(utf8.encode(value))}');
    _requireSuccess(result, 'store');
    return _referenceForAccount(account);
  }

  @override
  Future<String?> get(String reference) async {
    final account = _accountFromReference(reference);
    final result = await _processRunner(<String>[
      'lookup',
      'application',
      'ianvs-acp',
      'account',
      account,
    ]);
    if (result.exitCode == 1) return null;
    _requireSuccess(result, 'lookup');
    final encoded = _trimCommandNewline(result.stdout);
    if (!encoded.startsWith(_valueEnvelope)) {
      throw StateError('Secret Service returned an invalid value envelope.');
    }
    try {
      return utf8.decode(
        base64Decode(encoded.substring(_valueEnvelope.length)),
      );
    } on FormatException {
      throw StateError('Secret Service returned an invalid encoded value.');
    }
  }

  @override
  Future<void> delete(String reference) async {
    final account = _accountFromReference(reference);
    final result = await _processRunner(<String>[
      'clear',
      'application',
      'ianvs-acp',
      'account',
      account,
    ]);
    if (result.exitCode != 1) _requireSuccess(result, 'clear');
  }

  @override
  String referenceFor({required String namespace, required String key}) =>
      _referenceForAccount(secretAccountFor(namespace: namespace, key: key));

  @override
  bool referenceMatches(
    String reference, {
    required String namespace,
    required String key,
  }) => reference == referenceFor(namespace: namespace, key: key);

  static String _referenceForAccount(String account) =>
      'secret-service://ianvs-acp/$account';

  static String _accountFromReference(String reference) {
    final match = _referencePattern.firstMatch(reference);
    if (match == null) {
      throw FormatException(
        'Invalid Secret Service secret reference.',
        reference,
      );
    }
    return match.group(1)!;
  }

  static void _requireSuccess(LinuxSecretToolResult result, String operation) {
    if (result.exitCode == 0) return;
    final detail = result.stderr.trim();
    throw StateError(
      detail.isEmpty
          ? 'secret-tool $operation failed with exit ${result.exitCode}.'
          : 'secret-tool $operation failed: $detail',
    );
  }

  static String _trimCommandNewline(String value) {
    if (value.endsWith('\r\n')) {
      return value.substring(0, value.length - 2);
    }
    if (value.endsWith('\n')) {
      return value.substring(0, value.length - 1);
    }
    return value;
  }

  static Future<LinuxSecretToolResult> _runSecretTool(
    List<String> arguments, {
    String? input,
  }) async {
    final process = await Process.start(
      'secret-tool',
      arguments,
      mode: ProcessStartMode.normal,
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    if (input != null) process.stdin.write(input);
    await process.stdin.close();
    final values = await Future.wait<Object>(<Future<Object>>[
      process.exitCode,
      stdout,
      stderr,
    ]);
    return LinuxSecretToolResult(
      exitCode: values[0]! as int,
      stdout: values[1]! as String,
      stderr: values[2]! as String,
    );
  }
}
