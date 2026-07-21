import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/tasks/permission_context.dart';

void main() {
  group('permission display context', () {
    test('shows normalized root operation fields in a fixed order', () {
      final context = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: const <String, Object?>{
            'command': 'git',
            'args': <String>['push', 'origin', 'main'],
            'cwd': '/workspace',
            'path': '/workspace/report.txt',
            'target': 'origin',
          },
        ),
      );

      expect(context.isComplete, isTrue);
      expect(context.warning, isNull);
      expect(
        context.entries
            .map((entry) => (entry.label, entry.value))
            .toList(growable: false),
        const <(String, String)>[
          ('Command', '["git","push","origin","main"]'),
          ('Working directory', '/workspace'),
          ('Path', '/workspace/report.txt'),
          ('Target', 'origin'),
        ],
      );
      expect(
        () => context.entries.add(
          const PermissionDisplayEntry(label: 'Other', value: 'value'),
        ),
        throwsUnsupportedError,
      );
    });

    test('reads operation fields from nested toolCall input', () {
      final context = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: const <String, Object?>{
            'toolCall': <String, Object?>{
              'input': <String, Object?>{
                'command': 'flutter',
                'args': <String>['test', 'test/widget_test.dart'],
                'cwd': '/workspace/app',
                'path': 'test/widget_test.dart',
                'target': 'local',
              },
            },
          },
        ),
      );

      expect(context.isComplete, isTrue);
      expect(
        context.entries
            .map((entry) => (entry.label, entry.value))
            .toList(growable: false),
        const <(String, String)>[
          ('Command', '["flutter","test","test/widget_test.dart"]'),
          ('Working directory', '/workspace/app'),
          ('Path', 'test/widget_test.dart'),
          ('Target', 'local'),
        ],
      );
    });

    test('deduplicates equal fields across structured containers', () {
      final context = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: const <String, Object?>{
            'command': 'git status',
            'cwd': '/workspace',
            'toolCall': <String, Object?>{
              'command': 'git status',
              'cwd': '/workspace',
            },
          },
        ),
      );

      expect(context.isComplete, isTrue);
      expect(context.entries.map((entry) => entry.label), <String>[
        'Command',
        'Working directory',
      ]);
    });

    test('preserves field whitespace identity atomically', () {
      final conflict = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: const <String, Object?>{
            'path': '/a',
            'input': <String, Object?>{'path': '/a '},
          },
        ),
      );
      final single = permissionDisplayContextForRequest(
        _permissionRequest(metadata: const <String, Object?>{'path': '/a '}),
      );

      expect(conflict.isComplete, isFalse);
      expect(conflict.entries, isEmpty);
      expect(single.isComplete, isTrue);
      expect(single.entries.single.value, r'/a\u{0020}');
    });

    test('preserves command and argument boundary whitespace', () {
      final context = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: const <String, Object?>{
            'command': ' git ',
            'args': <String>['', ' x ', 'plain'],
          },
        ),
      );

      expect(context.isComplete, isTrue);
      expect(context.entries.single.label, 'Command');
      expect(context.entries.single.value, '[" git ",""," x ","plain"]');
    });

    test('escapes unsafe command characters without losing boundaries', () {
      final bidi = String.fromCharCodes(const <int>[
        0x061c,
        0x200e,
        0x200f,
        0x2028,
        0x2029,
        0x202a,
        0x202b,
        0x202c,
        0x202d,
        0x202e,
        0x2066,
        0x2067,
        0x2068,
        0x2069,
      ]);
      final malformedSurrogate = String.fromCharCode(0xd800);
      final context = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: <String, Object?>{
            'command': 'g"it\\',
            'args': <String>[
              '',
              ' edge ',
              'tab\tcr\rline\n',
              'controls\x00\x1f\x7f\x80\x9f',
              '$bidi$malformedSurrogate',
              'é',
            ],
          },
        ),
      );

      expect(context.isComplete, isTrue);
      final value = context.entries.single.value;
      expect(value, startsWith(r'["g\"it\\",""," edge ",'));
      for (final escape in const <String>[
        r'\u{0000}',
        r'\u{001F}',
        r'\u{007F}',
        r'\u{0080}',
        r'\u{009F}',
        r'\u{0009}',
        r'\u{000D}',
        r'\u{000A}',
        r'\u{061C}',
        r'\u{200E}',
        r'\u{200F}',
        r'\u{2028}',
        r'\u{2029}',
        r'\u{202A}',
        r'\u{202B}',
        r'\u{202C}',
        r'\u{202D}',
        r'\u{202E}',
        r'\u{2066}',
        r'\u{2067}',
        r'\u{2068}',
        r'\u{2069}',
        r'\u{D800}',
      ]) {
        expect(value, contains(escape), reason: escape);
      }
      expect(value, endsWith(',"é"]'));
      expect(_containsUnsafePermissionDisplayCodeUnit(value), isFalse);
    });

    test('escapes field boundary spaces, quotes, and backslashes', () {
      final context = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: const <String, Object?>{'path': '  /a b"c\\d  '},
        ),
      );

      expect(context.isComplete, isTrue);
      expect(
        context.entries.single.value,
        r'\u{0020}\u{0020}/a b\"c\\d\u{0020}\u{0020}',
      );
    });

    test('enforces escaped output budget atomically at exact and plus one', () {
      final limits = PermissionDisplayContextLimits(maxUtf8Bytes: 9);
      final exact = permissionDisplayContextForRequest(
        _permissionRequest(metadata: const <String, Object?>{'path': 'a\x00'}),
        limits: limits,
      );
      final overflow = permissionDisplayContextForRequest(
        _permissionRequest(metadata: const <String, Object?>{'path': 'a\x00b'}),
        limits: limits,
      );

      expect(exact.isComplete, isTrue);
      expect(exact.entries.single.value, r'a\u{0000}');
      expect(overflow.isComplete, isFalse);
      expect(overflow.entries, isEmpty);
      expect(overflow.warning, PermissionDisplayContext.incompleteWarning);
    });

    test('returns no partial entries for conflicts or malformed fields', () {
      for (final metadata in <Map<String, Object?>>[
        const <String, Object?>{
          'command': 'git status',
          'toolCall': <String, Object?>{'command': 'flutter test'},
          'cwd': '/workspace',
        },
        const <String, Object?>{
          'command': 'git status',
          'path': <String>['not', 'a', 'string'],
        },
        const <String, Object?>{
          'command': 'git',
          'args': <Object?>['status', 1],
        },
      ]) {
        final context = permissionDisplayContextForRequest(
          _permissionRequest(metadata: metadata),
        );

        expect(context.isComplete, isFalse);
        expect(context.entries, isEmpty);
        expect(context.warning, PermissionDisplayContext.incompleteWarning);
      }
    });

    test('rejects deep Map and raw JSON conflicts without partial entries', () {
      for (final metadata in <Map<String, Object?>>[
        const <String, Object?>{
          'command': 'git status',
          'input': <String, Object?>{
            'input': <String, Object?>{'command': 'flutter test'},
          },
        },
        const <String, Object?>{
          'command': 'git status',
          'rawInput': '{"input":{"command":"flutter test"}}',
        },
        const <String, Object?>{
          'path': '/workspace/a',
          'input': <String, Object?>{
            'input': <String, Object?>{'path': '/workspace/b'},
          },
        },
        const <String, Object?>{
          'target': 'origin',
          'rawInput': '{"input":{"target":"upstream"}}',
        },
      ]) {
        final context = permissionDisplayContextForRequest(
          _permissionRequest(metadata: metadata),
        );

        expect(context.isComplete, isFalse);
        expect(context.entries, isEmpty);
        expect(context.warning, PermissionDisplayContext.incompleteWarning);
      }
    });

    test(
      'accepts exactly 16 KiB of multibyte text and rejects one byte more',
      () {
        final exact = List<String>.filled(8192, 'é').join();
        final complete = permissionDisplayContextForRequest(
          _permissionRequest(metadata: <String, Object?>{'path': exact}),
        );
        final incomplete = permissionDisplayContextForRequest(
          _permissionRequest(metadata: <String, Object?>{'path': '$exact!'}),
        );

        expect(complete.isComplete, isTrue);
        expect(complete.entries.single.value, exact);
        expect(incomplete.isComplete, isFalse);
        expect(incomplete.entries, isEmpty);
      },
    );

    test('preflights raw JSON before invoking the decoder', () {
      final payload = '${List<String>.filled(8186, 'é').join()}a';
      final exact = '{"path":"$payload"}';
      var decoded = 0;
      Object? decode(String source) {
        decoded += 1;
        return jsonDecode(source);
      }

      final complete = permissionDisplayContextForRequest(
        _permissionRequest(metadata: <String, Object?>{'rawInput': exact}),
        decodeRawJsonForTesting: decode,
      );
      expect(decoded, 1);
      final incomplete = permissionDisplayContextForRequest(
        _permissionRequest(metadata: <String, Object?>{'rawInput': '$exact '}),
        decodeRawJsonForTesting: decode,
      );
      expect(decoded, 1);
      final codeUnitOverflow = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: <String, Object?>{'rawInput': '123456789'},
        ),
        limits: PermissionDisplayContextLimits(maxUtf8Bytes: 8),
        decodeRawJsonForTesting: decode,
      );
      final utf8Overflow = permissionDisplayContextForRequest(
        _permissionRequest(metadata: <String, Object?>{'rawInput': 'ééééa'}),
        limits: PermissionDisplayContextLimits(maxUtf8Bytes: 8),
        decodeRawJsonForTesting: decode,
      );

      expect(complete.isComplete, isTrue);
      expect(complete.entries.single.value, payload);
      expect(incomplete.isComplete, isFalse);
      expect(incomplete.entries, isEmpty);
      expect(codeUnitOverflow.isComplete, isFalse);
      expect(utf8Overflow.isComplete, isFalse);
      expect(decoded, 1);
    });

    test(
      'ignores unrelated metadata without traversing or stringifying it',
      () {
        final context = permissionDisplayContextForRequest(
          _permissionRequest(
            metadata: <String, Object?>{
              'command': 'git status',
              'irrelevantObject': _ThrowingToString('irrelevant-object'),
              'irrelevantList': List<Object?>.filled(
                1024,
                _ThrowingToString('irrelevant-list'),
              ),
              'irrelevantMap': <String, Object?>{
                for (var index = 0; index < 1024; index += 1)
                  'unknown$index': _ThrowingToString('irrelevant-map'),
              },
            },
          ),
        );

        expect(context.isComplete, isTrue);
        expect(context.entries.single.value, '["git status"]');
      },
    );

    test('does not enumerate metadata to discover recognized fields', () {
      final context = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: _DirectLookupOnlyMap(<String, Object?>{
            'command': 'git status',
          }),
        ),
      );

      expect(context.isComplete, isTrue);
      expect(context.entries.single.value, '["git status"]');
    });

    test('fails closed when root containsKey throws', () {
      _expectPermissionMapGetterFailure(
        _ThrowingPermissionMap(
          getter: _ThrowingMapGetter.containsKey,
          canary: 'root-contains-canary',
        ),
        'root-contains-canary',
      );
    });

    test('fails closed when root index getter throws', () {
      _expectPermissionMapGetterFailure(
        _ThrowingPermissionMap(
          getter: _ThrowingMapGetter.valueAt,
          canary: 'root-index-canary',
        ),
        'root-index-canary',
      );
    });

    test('fails closed when nested containsKey throws', () {
      _expectPermissionMapGetterFailure(<String, Object?>{
        'input': _ThrowingPermissionMap(
          getter: _ThrowingMapGetter.containsKey,
          canary: 'nested-contains-canary',
        ),
      }, 'nested-contains-canary');
    });

    test('fails closed when nested index getter throws', () {
      _expectPermissionMapGetterFailure(<String, Object?>{
        'input': _ThrowingPermissionMap(
          getter: _ThrowingMapGetter.valueAt,
          canary: 'nested-index-canary',
        ),
      }, 'nested-index-canary');
    });

    test('stops after 16 entries before reading the next recognized value', () {
      final overflow = permissionDisplayContextForRequest(
        _permissionRequest(metadata: _DefaultEntryLimitSentinelMap()),
      );

      expect(overflow.isComplete, isFalse);
      expect(overflow.entries, isEmpty);
    });

    test('enforces structured depth boundary at four', () {
      Map<String, Object?> nested(int depth) {
        Map<String, Object?> value = const <String, Object?>{
          'path': '/workspace/file',
        };
        for (var index = 0; index < depth; index += 1) {
          value = <String, Object?>{'input': value};
        }
        return value;
      }

      final exact = permissionDisplayContextForRequest(
        _permissionRequest(metadata: nested(4)),
      );
      final overflow = permissionDisplayContextForRequest(
        _permissionRequest(metadata: nested(5)),
      );

      expect(exact.isComplete, isTrue);
      expect(overflow.isComplete, isFalse);
      expect(overflow.entries, isEmpty);
    });

    test('checks depth before reading an over-depth container value', () {
      Map<String, Object?> metadata = _DepthSentinelMap();
      for (var index = 0; index < 4; index += 1) {
        metadata = <String, Object?>{'input': metadata};
      }

      final context = permissionDisplayContextForRequest(
        _permissionRequest(metadata: metadata),
      );

      expect(context.isComplete, isFalse);
      expect(context.entries, isEmpty);
    });

    test('stops after 128 nodes before reading the next list item', () {
      final overflow = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: <String, Object?>{
            'command': 'git',
            'args': _DefaultNodeLimitSentinelList(),
          },
        ),
      );

      expect(overflow.isComplete, isFalse);
      expect(overflow.entries, isEmpty);
    });

    test('accepts args that exactly consume the remaining node budget', () {
      final args = _ExactNodeBudgetList();

      final context = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: <String, Object?>{'command': 'git', 'args': args},
        ),
      );

      expect(context.isComplete, isTrue);
      expect(context.entries, hasLength(1));
      expect(context.entries.single.label, 'Command');
      expect(context.entries.single.value, startsWith('["git","arg0",'));
      expect(context.entries.single.value, endsWith(',"arg124"]'));
      expect(','.allMatches(context.entries.single.value), hasLength(125));
      expect(args.lengthReads, 1);
      expect(args.itemReads, 125);
    });

    test('reads list length once before rejecting node overflow', () {
      const canary = 'permission-list-length-canary';
      final args = _LengthReadSentinelList(canary);

      final context = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: <String, Object?>{'command': 'git', 'args': args},
        ),
      );

      expect(context.isComplete, isFalse);
      expect(context.entries, isEmpty);
      expect(context.warning, PermissionDisplayContext.incompleteWarning);
      expect(context.warning, isNot(contains(canary)));
      expect(args.lengthReads, 1);
      expect(args.itemReads, 0);
    });

    test('fails closed when the list length getter throws', () {
      const canary = 'permission-list-getter-canary';

      final context = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: <String, Object?>{
            'command': 'git',
            'args': _ThrowingLengthList(canary),
          },
        ),
      );

      expect(context.isComplete, isFalse);
      expect(context.entries, isEmpty);
      expect(context.warning, PermissionDisplayContext.incompleteWarning);
      expect(context.warning, isNot(contains(canary)));
    });

    test('uses a payload-free warning without invoking remote toString', () {
      const canary = 'permission-display-secret-canary';
      final context = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: <String, Object?>{
            'command': _ThrowingToString(canary),
            'cwd': '/workspace',
          },
        ),
      );

      expect(context.isComplete, isFalse);
      expect(context.entries, isEmpty);
      expect(context.warning, isNot(contains(canary)));
      expect(context.warning, PermissionDisplayContext.incompleteWarning);
    });

    test('keeps legacy requests without structured context complete', () {
      final context = permissionDisplayContextForRequest(
        _permissionRequest(
          metadata: <String, Object?>{
            'legacy': _ThrowingToString('legacy-canary'),
          },
        ),
      );

      expect(context.isComplete, isTrue);
      expect(context.entries, isEmpty);
      expect(context.warning, isNull);
    });

    test('validates injected limits at runtime', () {
      expect(
        () => PermissionDisplayContextLimits(maxUtf8Bytes: 0),
        throwsArgumentError,
      );
      expect(
        () => PermissionDisplayContextLimits(maxEntries: 0),
        throwsArgumentError,
      );
      expect(
        () => PermissionDisplayContextLimits(maxDepth: 0),
        throwsArgumentError,
      );
      expect(
        () => PermissionDisplayContextLimits(maxNodes: 0),
        throwsArgumentError,
      );
    });
  });
}

AcpPermissionRequest _permissionRequest({
  Map<String, Object?> metadata = const <String, Object?>{},
}) {
  return AcpPermissionRequest(
    id: 'permission-display',
    title: 'Permission requested',
    rationale: 'Requested by agent.',
    sessionId: 'session-1',
    toolName: 'terminal',
    toolKind: 'execute',
    options: const <String>['allow', 'deny'],
    requestedAt: DateTime(2026, 7, 11, 12),
    metadata: metadata,
  );
}

class _ThrowingToString {
  const _ThrowingToString(this.canary);

  final String canary;

  @override
  String toString() => throw StateError(canary);
}

void _expectPermissionMapGetterFailure(
  Map<String, Object?> metadata,
  String canary,
) {
  final context = permissionDisplayContextForRequest(
    _permissionRequest(metadata: metadata),
  );

  expect(context.isComplete, isFalse);
  expect(context.entries, isEmpty);
  expect(context.warning, PermissionDisplayContext.incompleteWarning);
  expect(context.warning, isNot(contains(canary)));
}

enum _ThrowingMapGetter { containsKey, valueAt }

class _ThrowingPermissionMap extends MapBase<String, Object?> {
  _ThrowingPermissionMap({required this.getter, required this.canary});

  final _ThrowingMapGetter getter;
  final String canary;

  @override
  Object? operator [](Object? key) {
    if (getter == _ThrowingMapGetter.valueAt && key == 'command') {
      throw StateError(canary);
    }
    return key == 'command' ? 'git status' : null;
  }

  @override
  void operator []=(String key, Object? value) => throw UnsupportedError('');

  @override
  void clear() => throw UnsupportedError('');

  @override
  bool containsKey(Object? key) {
    if (getter == _ThrowingMapGetter.containsKey) throw StateError(canary);
    return key == 'command';
  }

  @override
  Iterable<String> get keys => const <String>['command'];

  @override
  Object? remove(Object? key) => throw UnsupportedError('');
}

class _DirectLookupOnlyMap extends MapBase<String, Object?> {
  _DirectLookupOnlyMap(this._values);

  final Map<String, Object?> _values;

  @override
  Object? operator [](Object? key) => _values[key];

  @override
  void operator []=(String key, Object? value) => throw UnsupportedError('');

  @override
  void clear() => throw UnsupportedError('');

  @override
  bool containsKey(Object? key) => _values.containsKey(key);

  @override
  Iterable<String> get keys => throw StateError('metadata was enumerated');

  @override
  Object? remove(Object? key) => throw UnsupportedError('');
}

class _DefaultEntryLimitSentinelMap extends MapBase<String, Object?> {
  static final Map<String, Object?> _values = <String, Object?>{
    'command': 'git',
    'cmd': 'git',
    'commandLine': 'git',
    'command_line': 'git',
    'shellCommand': 'git',
    'shell_command': 'git',
    'script': 'git',
    'args': const <String>['status'],
    'argv': const <String>['status'],
    'arguments': const <String>['status'],
    'cwd': '/workspace',
    'path': '/workspace/file',
    'target': 'local',
    'toolCall': const <String, Object?>{},
    'rawInput': const <String, Object?>{},
    'raw_input': const <String, Object?>{},
  };

  @override
  Object? operator [](Object? key) {
    if (key == 'input') throw StateError('17th entry value was read');
    return _values[key];
  }

  @override
  void operator []=(String key, Object? value) => throw UnsupportedError('');

  @override
  void clear() => throw UnsupportedError('');

  @override
  bool containsKey(Object? key) => key == 'input' || _values.containsKey(key);

  @override
  Iterable<String> get keys => <String>[..._values.keys, 'input'];

  @override
  Object? remove(Object? key) => throw UnsupportedError('');
}

class _DefaultNodeLimitSentinelList extends ListBase<String> {
  @override
  int get length => 126;

  @override
  set length(int value) => throw UnsupportedError('');

  @override
  String operator [](int index) {
    if (index < 125) return 'arg$index';
    throw StateError('129th node value was read');
  }

  @override
  void operator []=(int index, String value) => throw UnsupportedError('');
}

class _ExactNodeBudgetList extends ListBase<String> {
  int lengthReads = 0;
  int itemReads = 0;

  @override
  int get length {
    lengthReads += 1;
    return 125;
  }

  @override
  set length(int value) => throw UnsupportedError('');

  @override
  String operator [](int index) {
    itemReads += 1;
    return 'arg$index';
  }

  @override
  void operator []=(int index, String value) => throw UnsupportedError('');
}

class _LengthReadSentinelList extends ListBase<String> {
  _LengthReadSentinelList(this.canary);

  final String canary;
  int lengthReads = 0;
  int itemReads = 0;

  @override
  int get length {
    lengthReads += 1;
    if (lengthReads > 1) throw StateError(canary);
    return 126;
  }

  @override
  set length(int value) => throw UnsupportedError('');

  @override
  String operator [](int index) {
    itemReads += 1;
    return 'arg$index';
  }

  @override
  void operator []=(int index, String value) => throw UnsupportedError('');
}

class _ThrowingLengthList extends ListBase<String> {
  _ThrowingLengthList(this.canary);

  final String canary;

  @override
  int get length => throw StateError(canary);

  @override
  set length(int value) => throw UnsupportedError('');

  @override
  String operator [](int index) => throw StateError(canary);

  @override
  void operator []=(int index, String value) => throw UnsupportedError('');
}

class _DepthSentinelMap extends MapBase<String, Object?> {
  @override
  Object? operator [](Object? key) {
    if (key == 'input') throw StateError('over-depth value was read');
    return null;
  }

  @override
  void operator []=(String key, Object? value) => throw UnsupportedError('');

  @override
  void clear() => throw UnsupportedError('');

  @override
  bool containsKey(Object? key) => key == 'input';

  @override
  Iterable<String> get keys => const <String>['input'];

  @override
  Object? remove(Object? key) => throw UnsupportedError('');
}

bool _containsUnsafePermissionDisplayCodeUnit(String value) {
  for (final codeUnit in value.codeUnits) {
    if (codeUnit <= 0x1f ||
        (codeUnit >= 0x7f && codeUnit <= 0x9f) ||
        (codeUnit >= 0xd800 && codeUnit <= 0xdfff) ||
        codeUnit == 0x061c ||
        codeUnit == 0x200e ||
        codeUnit == 0x200f ||
        (codeUnit >= 0x2028 && codeUnit <= 0x202e) ||
        (codeUnit >= 0x2066 && codeUnit <= 0x2069)) {
      return true;
    }
  }
  return false;
}
