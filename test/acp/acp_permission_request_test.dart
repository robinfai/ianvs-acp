import 'dart:convert';
import 'dart:collection';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';

void main() {
  AcpPermissionRequest request(List<String> options) {
    return AcpPermissionRequest(
      id: 'permission-1',
      title: 'Review action',
      rationale: 'Requested by agent',
      sessionId: 'session-1',
      toolName: 'tool',
      options: options,
      requestedAt: DateTime(2026, 5, 31, 12),
    );
  }

  test('permission labels match action keywords as words', () {
    final item = request(const ['Disallow', 'Allow']);

    expect(item.allowActionLabel, 'Allow Once');
    expect(item.denyActionLabel, 'Disallow');
  });

  test('permission labels keep specific agent action labels', () {
    final item = request(const ['Approve Plan', 'Reject Plan']);

    expect(item.allowActionLabel, 'Approve Plan');
    expect(item.denyActionLabel, 'Reject Plan');
  });

  test('permission labels treat negated allow phrases as deny actions', () {
    final item = request(const ['Do not allow', 'Allow']);

    expect(item.allowActionLabel, 'Allow Once');
    expect(item.denyActionLabel, 'Do not allow');
  });

  test('permission requests preserve structured agent choices', () {
    final item = AcpPermissionRequest(
      id: 'permission-1',
      title: 'Review action',
      rationale: 'Requested by agent',
      sessionId: 'session-1',
      toolName: 'tool',
      options: const ['Allow this time', 'Reject this time'],
      choices: const [
        AcpPermissionChoice(
          optionId: 'allow-once',
          name: 'Allow this time',
          kind: 'allow_once',
        ),
        AcpPermissionChoice(
          optionId: 'reject-once',
          name: 'Reject this time',
          kind: 'reject_once',
        ),
      ],
      requestedAt: DateTime(2026, 5, 31, 12),
    );

    expect(item.choices.first.optionId, 'allow-once');
    expect(item.choices.last.kind, 'reject_once');
    expect(item.toJson()['choices'], [
      {
        'optionId': 'allow-once',
        'name': 'Allow this time',
        'kind': 'allow_once',
      },
      {
        'optionId': 'reject-once',
        'name': 'Reject this time',
        'kind': 'reject_once',
      },
    ]);
  });

  test('permission fingerprints sort maps but preserve metadata strings', () {
    final first = AcpPermissionRequest(
      id: 'permission-a',
      title: ' Run command ',
      rationale: ' Requested by agent ',
      sessionId: ' session-1 ',
      toolName: ' terminal ',
      toolKind: ' execute ',
      options: const [' Allow ', ' Deny '],
      requestedAt: DateTime(2026, 5, 31, 12),
      metadata: const {
        'z': 'value',
        'nested': {'b': 2, 'a': 'one'},
      },
    );
    final second = AcpPermissionRequest(
      id: 'permission-b',
      title: 'Run command',
      rationale: 'Requested by agent',
      sessionId: 'session-1',
      toolName: 'terminal',
      toolKind: 'execute',
      options: const ['Allow', 'Deny'],
      requestedAt: DateTime(2026, 6, 1, 12),
      metadata: const {
        'nested': {'a': 'one', 'b': 2},
        'z': 'value',
      },
    );

    expect(first.contentFingerprint, second.contentFingerprint);
    final trailingPath = AcpPermissionRequest(
      id: first.id,
      title: first.title,
      rationale: first.rationale,
      sessionId: first.sessionId,
      toolName: first.toolName,
      toolKind: first.toolKind,
      options: first.options,
      requestedAt: first.requestedAt,
      metadata: const {'path': '/workspace/report '},
    );
    final exactPath = AcpPermissionRequest(
      id: first.id,
      title: first.title,
      rationale: first.rationale,
      sessionId: first.sessionId,
      toolName: first.toolName,
      toolKind: first.toolKind,
      options: first.options,
      requestedAt: first.requestedAt,
      metadata: const {'path': '/workspace/report'},
    );
    final leadingValue = AcpPermissionRequest(
      id: first.id,
      title: first.title,
      rationale: first.rationale,
      sessionId: first.sessionId,
      toolName: first.toolName,
      toolKind: first.toolKind,
      options: first.options,
      requestedAt: first.requestedAt,
      metadata: const {'key': ' value'},
    );
    final exactValue = AcpPermissionRequest(
      id: first.id,
      title: first.title,
      rationale: first.rationale,
      sessionId: first.sessionId,
      toolName: first.toolName,
      toolKind: first.toolKind,
      options: first.options,
      requestedAt: first.requestedAt,
      metadata: const {'key': 'value'},
    );

    expect(
      trailingPath.contentFingerprint,
      isNot(exactPath.contentFingerprint),
    );
    expect(
      leadingValue.contentFingerprint,
      isNot(exactValue.contentFingerprint),
    );
    expect(
      first.withGeneration(1).bindingKey,
      isNot(first.withGeneration(2).bindingKey),
    );
  });

  test('legacy persistent choices are not treated as single use', () {
    const choice = AcpPermissionChoice(
      optionId: 'allow-always',
      name: 'Always allow',
    );

    expect(choice.decision, AcpPermissionDecision.allow);
    expect(choice.isSingleUse, isFalse);
  });

  test('permission lifecycle identity survives copies without leaking', () {
    final request = AcpPermissionRequest(
      id: 'permission-1',
      lifecycleId: 'lifecycle-1',
      title: 'Read',
      rationale: 'Requested',
      sessionId: 'session-1',
      toolName: 'read_text_file',
      options: const <String>['Allow', 'Deny'],
      requestedAt: DateTime.utc(2026, 7, 14),
    );
    final generated = request.withGeneration(2);
    final audit = generated.forAudit();
    expect(generated.lifecycleId, 'lifecycle-1');
    expect(audit.lifecycleId, 'lifecycle-1');
    expect(
      generated.bindingKey,
      'permission-1:lifecycle-1:${request.contentFingerprint}:2',
    );
    expect(generated.contentFingerprint, request.contentFingerprint);

    final legacy = AcpPermissionRequest(
      id: 'legacy',
      title: '',
      rationale: '',
      sessionId: 'session-1',
      toolName: '',
      options: const <String>[],
      requestedAt: DateTime.utc(2026),
    );
    expect(legacy.lifecycleId, isEmpty);
    expect(
      legacy.bindingKey,
      'legacy:${legacy.contentFingerprint}:0',
      reason: 'empty lifecycleId must preserve the pre-migration key format',
    );
    expect(legacy.withGeneration(3).lifecycleId, isEmpty);
    expect(legacy.forAudit().lifecycleId, isEmpty);
  });

  test('explicit permission decisions use kind without name fallback', () {
    const explicitAllow = AcpPermissionChoice(
      optionId: 'allow-once',
      name: 'Custom approval',
      kind: 'allow_once',
    );
    const explicitDeny = AcpPermissionChoice(
      optionId: 'reject-once',
      name: 'Custom rejection',
      kind: 'reject_once',
    );
    const nameOnly = AcpPermissionChoice(
      optionId: 'legacy-reject',
      name: 'Reject',
    );
    const nameOnlyAllow = AcpPermissionChoice(
      optionId: 'legacy-allow',
      name: 'Allow',
    );
    const unknownKind = AcpPermissionChoice(
      optionId: 'unknown',
      name: 'Allow',
      kind: 'ask_later',
    );

    expect(explicitAllow.explicitDecision, AcpPermissionDecision.allow);
    expect(explicitDeny.explicitDecision, AcpPermissionDecision.deny);
    expect(nameOnly.explicitDecision, isNull);
    expect(nameOnly.decision, AcpPermissionDecision.deny);
    expect(nameOnlyAllow.explicitDecision, isNull);
    expect(nameOnlyAllow.decision, AcpPermissionDecision.allow);
    expect(unknownKind.explicitDecision, isNull);
  });

  test('transient policy context affects binding but is never serialized', () {
    AcpPermissionRequest item(String secret) => AcpPermissionRequest(
      id: 'permission-env',
      title: 'Create terminal',
      rationale: 'Requested by agent',
      sessionId: 'session-1',
      toolName: 'terminal',
      options: const ['Allow', 'Deny'],
      requestedAt: DateTime(2026, 7, 11),
      metadata: const <String, Object?>{
        'command': 'curl',
        'envKeys': ['EXFIL_URL'],
      },
      transientPolicyContext: <String, Object?>{
        'environment': <String, String>{'EXFIL_URL': secret},
      },
    );

    final first = item('https://one.example/private');
    final second = item('https://two.example/private');

    expect(first.contentFingerprint, isNot(second.contentFingerprint));
    expect(
      first.withGeneration(2).transientPolicyContext,
      same(first.transientPolicyContext),
    );
    expect(first.toJson().toString(), isNot(contains('one.example')));
    expect(first.toJson(), isNot(contains('transientPolicyContext')));
  });

  test('permission review encoded budget accepts exact and omits plus one', () {
    final result = AcpPermissionReviewResult(
      decision: AcpPermissionDecision.allow,
      risk: 'low',
      rationale: List<String>.filled(512, 'r').join(),
      reviewer: 'reviewer',
      details: const <String, Object?>{
        'evidence': <String, Object?>{'kind': 'read'},
      },
    );
    final encodedBytes = utf8.encode(jsonEncode(result.toJson())).length;

    final exact = sanitizeAcpPermissionReviewResult(
      result,
      inputBudget: const acp.AcpInputBudget(),
      maxEncodedBytes: encodedBytes,
    );
    final plusOne = sanitizeAcpPermissionReviewResult(
      result,
      inputBudget: const acp.AcpInputBudget(),
      maxEncodedBytes: encodedBytes - 1,
    );

    expect(exact.toJson(), result.toJson());
    expect(plusOne.decision, isNull);
    expect(
      plusOne.rationale,
      'Permission review result omitted because it exceeded safety limits.',
    );
    expect(plusOne.details, const <String, Object?>{'omission': 'size_limit'});
    expect(
      utf8.encode(jsonEncode(plusOne.toJson())).length,
      lessThanOrEqualTo(encodedBytes - 1),
    );
  });

  test(
    'permission review minimum encoded budget accepts exact and rejects minus one',
    () {
      final oversized = AcpPermissionReviewResult(
        rationale: List<String>.filled(1024, 'x').join(),
        details: <String, Object?>{
          'raw': List<String>.filled(1024, 'y').join(),
        },
      );

      final omitted = sanitizeAcpPermissionReviewResult(
        oversized,
        maxEncodedBytes: minimumPermissionReviewResultEncodedByteLimit,
      );

      expect(omitted.details, const <String, Object?>{
        'omission': 'size_limit',
      });
      expect(
        utf8.encode(jsonEncode(omitted.toJson())).length,
        lessThanOrEqualTo(minimumPermissionReviewResultEncodedByteLimit),
      );
      expect(
        () => sanitizeAcpPermissionReviewResult(
          oversized,
          maxEncodedBytes: minimumPermissionReviewResultEncodedByteLimit - 1,
        ),
        throwsArgumentError,
      );
    },
  );

  test('permission review structure and string limits omit raw values', () {
    const canary = 'token-canary-/private/reviewer/path';
    const result = AcpPermissionReviewResult(
      decision: AcpPermissionDecision.allow,
      risk: 'low',
      rationale: canary,
      reviewer: 'reviewer',
      details: <String, Object?>{
        'raw': <String, Object?>{
          'nested': <String, Object?>{'secret': canary},
        },
      },
    );

    final bounded = sanitizeAcpPermissionReviewResult(
      result,
      inputBudget: const acp.AcpInputBudget(maxStructuredStringBytes: 8),
      maxEncodedBytes: 1024,
    );
    final encoded = jsonEncode(bounded.toJson());

    expect(bounded.decision, isNull);
    expect(encoded, isNot(contains(canary)));
    expect(bounded.details, const <String, Object?>{'omission': 'size_limit'});
  });

  test(
    'permission history export bounds oversized request fields before encoding',
    () {
      const canary = 'audit-request-canary-should-not-survive';
      final huge = '$canary${List<String>.filled(2 * 1024 * 1024, 'x').join()}';
      final largeMetadata = <String, Object?>{
        for (var index = 0; index < 2048; index += 1) '$canary-$index': canary,
      };

      AcpPermissionAuditEntry entry({
        required String id,
        String title = 'Read file',
        List<String> options = const <String>['Allow', 'Deny'],
        Map<String, Object?> metadata = const <String, Object?>{},
        Map<String, Object?> transientPolicyContext = const <String, Object?>{},
      }) {
        return AcpPermissionAuditEntry(
          request: AcpPermissionRequest(
            id: id,
            title: title,
            rationale: 'Requested by agent',
            sessionId: 'session-1',
            toolName: 'read_text_file',
            options: options,
            metadata: metadata,
            transientPolicyContext: transientPolicyContext,
            generation: 1,
            requestedAt: DateTime.utc(2026, 7, 15),
          ),
          status: AcpPermissionAuditStatus.pending,
          recordedAt: DateTime.utc(2026, 7, 15),
        );
      }

      final oversized = <AcpPermissionAuditEntry>[
        entry(
          id: 'huge-title',
          title: huge,
          transientPolicyContext: _ThrowingPermissionMap(),
        ),
        entry(
          id: 'huge-options',
          options: List<String>.filled(2048, canary),
          transientPolicyContext: _ThrowingPermissionMap(),
        ),
        entry(
          id: 'huge-metadata',
          metadata: largeMetadata,
          transientPolicyContext: _ThrowingPermissionMap(),
        ),
      ];
      final compatible = entry(id: 'compatible');
      for (final candidate in oversized) {
        final emptyExport = acpPermissionAuditEntriesToJson(
          <AcpPermissionAuditEntry>[candidate],
          maxEncodedBytes: 4096,
        );
        final prefixedExport = acpPermissionAuditEntriesToJson(
          <AcpPermissionAuditEntry>[compatible, candidate, compatible],
          maxEncodedBytes: 4096,
        );
        final emptyEntries =
            (jsonDecode(emptyExport) as Map<String, dynamic>)['entries']
                as List<dynamic>;
        final prefixedEntries =
            (jsonDecode(prefixedExport) as Map<String, dynamic>)['entries']
                as List<dynamic>;

        expect(utf8.encode(emptyExport).length, lessThanOrEqualTo(4096));
        expect(utf8.encode(prefixedExport).length, lessThanOrEqualTo(4096));
        expect(emptyExport, isNot(contains(canary)));
        expect(prefixedExport, isNot(contains(canary)));
        expect(emptyEntries, isEmpty);
        expect(prefixedEntries, hasLength(1));
        expect(
          (prefixedEntries.single as Map<String, dynamic>)['request'],
          containsPair('id', 'compatible'),
        );
      }
    },
  );

  test(
    'permission history v1 export preserves bounded generated fingerprint',
    () {
      final request = AcpPermissionRequest(
        id: 'permission-fingerprint',
        title: 'Read report',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'read_text_file',
        toolKind: 'read',
        options: const <String>['Allow', 'Deny'],
        choices: const <AcpPermissionChoice>[
          AcpPermissionChoice(
            optionId: 'allow-once',
            name: 'Allow',
            kind: 'allow_once',
          ),
        ],
        metadata: const <String, Object?>{
          'nested': <String, Object?>{'b': 2, 'a': 'one'},
        },
        transientPolicyContext: const <String, Object?>{
          'environment': <String, String>{'TOKEN': 'transient-secret'},
        },
        generation: 1,
        requestedAt: DateTime.utc(2026, 7, 15),
      );
      final expectedFingerprint = request.toJson()['contentFingerprint'];
      final exported =
          acpPermissionAuditEntriesToJson(<AcpPermissionAuditEntry>[
            AcpPermissionAuditEntry(
              request: request,
              status: AcpPermissionAuditStatus.pending,
              recordedAt: DateTime.utc(2026, 7, 15),
            ),
          ]);
      final decoded = jsonDecode(exported) as Map<String, dynamic>;
      final entry =
          (decoded['entries'] as List<dynamic>).single as Map<String, dynamic>;
      final exportedRequest = entry['request'] as Map<String, dynamic>;

      expect(exportedRequest['contentFingerprint'], expectedFingerprint);
      expect(exported, isNot(contains('transient-secret')));
      expect(exportedRequest, isNot(contains('transientPolicyContext')));
    },
  );
}

final class _ThrowingPermissionMap extends MapBase<String, Object?> {
  Never _unexpected() => throw StateError(
    'permission history export must not calculate a content fingerprint',
  );

  @override
  Object? operator [](Object? key) => _unexpected();

  @override
  void operator []=(String key, Object? value) => _unexpected();

  @override
  void clear() => _unexpected();

  @override
  Iterable<String> get keys => _unexpected();

  @override
  Object? remove(Object? key) => _unexpected();
}
