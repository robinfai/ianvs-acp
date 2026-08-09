import 'dart:collection';

import 'package:ianvs_acp/acp/acp_input_budget.dart' as acp;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_agent_capabilities.dart';

void main() {
  test('capability objects advertise support while null and false do not', () {
    final capabilities = AcpAgentCapabilities.fromInitialize(
      protocolVersion: 1,
      agentCapabilities: <String, dynamic>{
        'loadSession': <String, dynamic>{},
        'auth': <String, dynamic>{'logout': null},
        'sessionCapabilities': <String, dynamic>{
          'list': <String, dynamic>{},
          'resume': null,
          'fork': false,
          'configOptions': true,
          'additionalDirectories': <String, dynamic>{},
          'close': <String, dynamic>{'_meta': <String, dynamic>{}},
        },
      },
      authMethods: const <Map<String, dynamic>>[],
      clientCapabilities: const <String, dynamic>{},
      hasFsProvider: false,
      hasTerminalProvider: false,
      allowReadOutsideWorkspace: false,
    );

    expect(capabilities.loadSession, isTrue);
    expect(capabilities.auth.logout, isFalse);
    expect(capabilities.session.list, isTrue);
    expect(capabilities.session.resume, isFalse);
    expect(capabilities.session.fork, isFalse);
    expect(capabilities.session.configOptions, isTrue);
    expect(capabilities.session.additionalDirectories, isTrue);
    expect(capabilities.session.close, isTrue);
  });

  test('boolean shorthand capabilities remain supported', () {
    final capabilities = AcpAgentCapabilities.fromInitialize(
      protocolVersion: 1,
      agentCapabilities: <String, dynamic>{
        'loadSession': true,
        'auth': <String, dynamic>{'logout': true},
        'sessionCapabilities': <String, dynamic>{
          'list': true,
          'resume': true,
          'fork': true,
          'configOptions': true,
          'additionalDirectories': true,
          'close': true,
        },
      },
      authMethods: const <Map<String, dynamic>>[],
      clientCapabilities: const <String, dynamic>{},
      hasFsProvider: false,
      hasTerminalProvider: false,
      allowReadOutsideWorkspace: false,
    );

    expect(capabilities.loadSession, isTrue);
    expect(capabilities.auth.logout, isTrue);
    expect(capabilities.session.list, isTrue);
    expect(capabilities.session.resume, isTrue);
    expect(capabilities.session.fork, isTrue);
    expect(capabilities.session.configOptions, isTrue);
    expect(capabilities.session.additionalDirectories, isTrue);
    expect(capabilities.session.close, isTrue);
  });

  test('session capabilities accept snake case additional directories', () {
    final capabilities = AcpAgentCapabilities.fromInitialize(
      protocolVersion: 1,
      agentCapabilities: <String, dynamic>{
        'sessionCapabilities': <String, dynamic>{
          'additional_directories': <String, dynamic>{},
        },
      },
      authMethods: const <Map<String, dynamic>>[],
      clientCapabilities: const <String, dynamic>{},
      hasFsProvider: false,
      hasTerminalProvider: false,
      allowReadOutsideWorkspace: false,
    );

    expect(capabilities.session.additionalDirectories, isTrue);
  });

  test('initialization metadata is preserved', () {
    final capabilities = AcpAgentCapabilities.fromInitialize(
      protocolVersion: 1,
      agentCapabilities: const <String, dynamic>{},
      authMethods: const <Map<String, dynamic>>[],
      clientCapabilities: const <String, dynamic>{},
      hasFsProvider: false,
      hasTerminalProvider: false,
      allowReadOutsideWorkspace: false,
      agentInfo: const <String, dynamic>{
        'name': 'Example Agent',
        'version': '2.0.0',
      },
      clientInfo: const <String, dynamic>{
        'name': 'ACP Client',
        'version': '1.0.0',
      },
    );

    expect(capabilities.agentInfo['name'], 'Example Agent');
    expect(capabilities.agentInfo['version'], '2.0.0');
    expect(capabilities.clientInfo['name'], 'ACP Client');
    expect(capabilities.clientInfo['version'], '1.0.0');
  });

  test('ACP input budget exposes stable defensive defaults', () {
    const budget = acp.AcpInputBudget();

    expect(budget.maxJsonDepth, 32);
    expect(budget.maxCapabilityDepth, 16);
    expect(budget.maxCapabilityNodes, 4096);
    expect(budget.maxCapabilityBytes, 256 * 1024);
    expect(budget.maxAuthMethods, 32);
    expect(budget.maxMetadataDepth, 16);
    expect(budget.maxMetadataNodes, 8192);
    expect(budget.maxMetadataEntries, 1024);
    expect(budget.maxMetadataBytes, 512 * 1024);
    expect(budget.maxCollectionItems, 1024);
    expect(budget.maxStructuredUpdateNodes, 8192);
    expect(budget.maxStructuredUpdateBytes, 16 * 1024 * 1024);
    expect(budget.maxStructuredStringBytes, 4 * 1024 * 1024);
    expect(budget.maxMessageTextBytes, 2 * 1024 * 1024);
    expect(budget.maxMessageTextLines, 10000);
    expect(budget.maxMarkdownSyntaxTokens, 4096);
    expect(budget.maxMarkdownFallbackBytes, 64 * 1024);
    expect(budget.maxThoughtTextBytes, 512 * 1024);
    expect(budget.maxEmbeddedMediaBytes, 16 * 1024 * 1024);
    expect(budget.maxImageDimension, 8192);
    expect(budget.maxImagePixels, 16777216);
    expect(budget.maxImagePreviewPixels, 2097152);
    expect(budget.maxConcurrentImageDecodes, 2);
    expect(budget.maxImagePreviewPixelsGlobal, 4194304);
    expect(budget.maxImageDecodeBytesGlobal, 32 * 1024 * 1024);
    expect(budget.maxTurnItems, 512);
    expect(budget.maxTurnRetainedBytes, 32 * 1024 * 1024);
    expect(budget.maxTimelineItems, 2000);
    expect(budget.maxTimelineBytes, 32 * 1024 * 1024);
    expect(budget.maxUiStateBytes, 128 * 1024 * 1024);
    expect(budget.maxMetadataPreviewBytes, 16 * 1024);
    expect(budget.maxMetadataPreviewChars, 4096);
  });

  test('capability depth accepts the exact boundary', () {
    final capabilities = _parseCapabilities(<String, Object?>{
      'nested': <String, Object?>{'leaf': true},
    }, budget: const acp.AcpInputBudget(maxCapabilityDepth: 2));

    expect(capabilities.rawAgentCapabilities['nested'], isA<Map>());
  });

  test('capability depth rejects the first container beyond the boundary', () {
    final secret = 'depth-secret';

    expect(
      () => _parseCapabilities(<String, Object?>{
        'nested': <String, Object?>{
          'tooDeep': <String, Object?>{'value': secret},
        },
      }, budget: const acp.AcpInputBudget(maxCapabilityDepth: 2)),
      throwsA(
        isA<acp.AcpInputLimitExceeded>()
            .having((error) => error.limit, 'limit', 2)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 3)
            .having(
              (error) => error.toString(),
              'payload-free',
              isNot(contains(secret)),
            ),
      ),
    );
  });

  test('capability nodes accept the exact aggregate boundary', () {
    final capabilities = _parseCapabilities(<String, Object?>{
      'one': true,
    }, budget: const acp.AcpInputBudget(maxCapabilityNodes: 3));

    expect(capabilities.loadSession, isFalse);
  });

  test('capability nodes reject the first node beyond the boundary', () {
    expect(
      () => _parseCapabilities(<String, Object?>{
        'one': true,
        'two': false,
      }, budget: const acp.AcpInputBudget(maxCapabilityNodes: 3)),
      throwsA(
        isA<acp.AcpInputLimitExceeded>()
            .having((error) => error.limit, 'limit', 3)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 4),
      ),
    );
  });

  test('capability UTF-8 bytes accept the exact aggregate boundary', () {
    final capabilities = _parseCapabilities(<String, Object?>{
      'token': '秘密',
    }, budget: const acp.AcpInputBudget(maxCapabilityBytes: 11));

    expect(capabilities.rawAgentCapabilities['token'], '秘密');
  });

  test('capability UTF-8 bytes reject the first byte beyond the boundary', () {
    final secret = '秘密';

    expect(
      () => _parseCapabilities(<String, Object?>{
        'token': secret,
      }, budget: const acp.AcpInputBudget(maxCapabilityBytes: 10)),
      throwsA(
        isA<acp.AcpInputLimitExceeded>()
            .having((error) => error.limit, 'limit', 10)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 11)
            .having(
              (error) => error.toString(),
              'payload-free',
              isNot(contains(secret)),
            ),
      ),
    );
  });

  test('auth methods accept the exact count and reject the next entry', () {
    final atBoundary = _parseCapabilities(
      const <String, Object?>{},
      authMethods: const <Object?>[
        <String, Object?>{'id': 'one'},
        <String, Object?>{'id': 'two'},
      ],
      budget: const acp.AcpInputBudget(maxAuthMethods: 2),
    );
    expect(atBoundary.authMethods, hasLength(2));

    expect(
      () => _parseCapabilities(
        const <String, Object?>{},
        authMethods: const <Object?>[
          <String, Object?>{'id': 'one'},
          <String, Object?>{'id': 'two'},
          <String, Object?>{'id': 'auth-secret'},
        ],
        budget: const acp.AcpInputBudget(maxAuthMethods: 2),
      ),
      throwsA(
        isA<acp.AcpInputLimitExceeded>()
            .having((error) => error.limit, 'limit', 2)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 3)
            .having(
              (error) => error.toString(),
              'payload-free',
              isNot(contains('auth-secret')),
            ),
      ),
    );
  });

  test('auth methods reject wrong container types without stringifying', () {
    const secret = 'auth-container-secret';
    final hostile = _HostileJsonValue(secret);

    expect(
      () => acp.copyBoundedInitializeInput(
        agentCapabilities: const <String, Object?>{},
        authMethods: hostile,
      ),
      throwsA(
        isA<FormatException>()
            .having(
              (error) => error.message,
              'message',
              'ACP initialize auth methods must be a JSON array.',
            )
            .having(
              (error) => error.toString(),
              'payload-free',
              isNot(contains(secret)),
            ),
      ),
    );
    expect(hostile.toStringCalls, 0);
  });

  test('auth methods reject every non-object entry without stringifying', () {
    const secret = 'auth-entry-secret';
    final hostile = _HostileJsonValue(secret);

    expect(
      () => acp.copyBoundedInitializeInput(
        agentCapabilities: const <String, Object?>{},
        authMethods: <Object?>[
          const <String, Object?>{'id': 'valid'},
          hostile,
        ],
      ),
      throwsA(
        isA<FormatException>()
            .having(
              (error) => error.message,
              'message',
              'ACP initialize auth methods must contain only JSON objects.',
            )
            .having(
              (error) => error.toString(),
              'payload-free',
              isNot(contains(secret)),
            ),
      ),
    );
    expect(hostile.toStringCalls, 0);
  });

  test('null auth methods remain an empty optional value', () {
    final copied = acp.copyBoundedInitializeInput(
      agentCapabilities: const <String, Object?>{},
      authMethods: null,
    );

    expect(copied.authMethods, isEmpty);
  });

  test('capability parsing returns a defensive deep copy', () {
    final nested = <String, Object?>{'enabled': true};
    final raw = <String, Object?>{'extension': nested};

    final capabilities = _parseCapabilities(raw);
    nested['enabled'] = false;
    raw['late'] = 'mutation';

    expect(capabilities.rawAgentCapabilities['extension'], <String, Object?>{
      'enabled': true,
    });
    expect(capabilities.rawAgentCapabilities, isNot(contains('late')));
  });

  test('bounded initialize input defensively copies nested agent info', () {
    final nested = <String, Object?>{'version': '1.0.0'};
    final agentInfo = <String, Object?>{'details': nested};

    final copied = acp.copyBoundedInitializeInput(
      agentCapabilities: const <String, Object?>{},
      authMethods: const <Object?>[],
      agentInfo: agentInfo,
    );
    nested['version'] = 'mutated';
    agentInfo['late'] = 'mutation';

    expect(copied.agentInfo['details'], <String, Object?>{'version': '1.0.0'});
    expect(copied.agentInfo, isNot(contains('late')));
  });

  test('JSON input guard counts UTF-8 from UTF-16 code units exactly', () {
    final cases = <({String value, int bytes})>[
      (value: 'Aé€😀', bytes: 10),
      (value: String.fromCharCodes(<int>[0xd83d, 0xde00]), bytes: 4),
      (value: String.fromCharCode(0xd800), bytes: 3),
      (value: String.fromCharCode(0xdc00), bytes: 3),
      (value: String.fromCharCodes(<int>[0xd800, 0x61, 0xdc00]), bytes: 7),
    ];

    for (final testCase in cases) {
      final exact = acp.AcpJsonInputGuard(
        resource: 'ACP test input',
        maxDepth: 4,
        maxNodes: 8,
        maxBytes: testCase.bytes + 1,
      );
      expect(
        exact.copyMap(<String, Object?>{'k': testCase.value})['k'],
        testCase.value,
      );

      final over = acp.AcpJsonInputGuard(
        resource: 'ACP test input',
        maxDepth: 4,
        maxNodes: 8,
        maxBytes: testCase.bytes,
      );
      expect(
        () => over.copyMap(<String, Object?>{'k': testCase.value}),
        throwsA(
          isA<acp.AcpInputLimitExceeded>()
              .having((error) => error.limit, 'limit', testCase.bytes)
              .having(
                (error) => error.observedAtLeast,
                'observedAtLeast',
                testCase.bytes + 1,
              ),
        ),
      );
    }
  });

  test('JSON input guard stops UTF-8 counting at the first overflow', () {
    final guard = acp.AcpJsonInputGuard(
      resource: 'ACP test input',
      maxDepth: 4,
      maxNodes: 8,
      maxBytes: 2,
    );

    expect(
      () => guard.copyMap(<String, Object?>{'k': 'Aé€😀'}),
      throwsA(
        isA<acp.AcpInputLimitExceeded>()
            .having((error) => error.limit, 'limit', 2)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 4),
      ),
    );
  });

  test('JSON input guard rejects non-string keys without calling toString', () {
    const secret = 'map-key-secret';
    final hostileKey = _HostileMapKey(secret);
    final guard = acp.AcpJsonInputGuard(
      resource: 'ACP test input',
      maxDepth: 4,
      maxNodes: 8,
      maxBytes: 64,
    );

    expect(
      () => guard.copyMap(<Object?, Object?>{hostileKey: 'value'}),
      throwsA(
        isA<FormatException>()
            .having(
              (error) => error.message,
              'message',
              'ACP test input contains a JSON object with a non-string key.',
            )
            .having(
              (error) => error.toString(),
              'payload-free',
              isNot(contains(secret)),
            ),
      ),
    );
    expect(hostileKey.toStringCalls, 0);
  });

  test('JSON input guard rejects numeric and string key collisions', () {
    final guard = acp.AcpJsonInputGuard(
      resource: 'ACP test input',
      maxDepth: 4,
      maxNodes: 8,
      maxBytes: 64,
    );

    expect(
      () => guard.copyMap(<Object?, Object?>{1: 'numeric', '1': 'string'}),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'ACP test input contains a JSON object with a non-string key.',
        ),
      ),
    );
  });

  test('JSON input guard rejects non-finite numbers with a fixed error', () {
    for (final value in <double>[
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      final guard = acp.AcpJsonInputGuard(
        resource: 'ACP test input',
        maxDepth: 4,
        maxNodes: 8,
        maxBytes: 64,
      );

      expect(
        () => guard.copyMap(<String, Object?>{'value': value}),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'ACP test input contains a non-finite JSON number.',
          ),
        ),
      );
    }
  });

  test('ACP input budget rejects every dynamic non-positive limit at use', () {
    final invalidBudgets = <acp.AcpInputBudget Function()>[
      () => acp.AcpInputBudget(maxJsonDepth: 0),
      () => acp.AcpInputBudget(maxCapabilityDepth: 0),
      () => acp.AcpInputBudget(maxCapabilityNodes: 0),
      () => acp.AcpInputBudget(maxCapabilityBytes: 0),
      () => acp.AcpInputBudget(maxAuthMethods: 0),
      () => acp.AcpInputBudget(maxMetadataDepth: 0),
      () => acp.AcpInputBudget(maxMetadataNodes: 0),
      () => acp.AcpInputBudget(maxMetadataEntries: 0),
      () => acp.AcpInputBudget(maxMetadataBytes: 0),
    ];

    for (final createBudget in invalidBudgets) {
      expect(
        () => acp.copyBoundedInitializeInput(
          agentCapabilities: const <String, Object?>{},
          authMethods: const <Object?>[],
          budget: createBudget(),
        ),
        throwsA(isA<ArgumentError>()),
      );
    }
  });

  test('JSON input guard runtime-validates direct construction', () {
    expect(
      () => acp.AcpJsonInputGuard(
        resource: 'ACP test input',
        maxDepth: 0,
        maxNodes: 1,
        maxBytes: 1,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => acp.AcpJsonInputGuard(
        resource: 'ACP test input',
        maxDepth: 1,
        maxNodes: 0,
        maxBytes: 1,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => acp.AcpJsonInputGuard(
        resource: 'ACP test input',
        maxDepth: 1,
        maxNodes: 1,
        maxBytes: 0,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('remaining node precheck avoids traversing an oversized nested map', () {
    final exactMap = _CountingMap(<String, Object?>{'one': true, 'two': false});
    final exactGuard = acp.AcpJsonInputGuard(
      resource: 'ACP test input',
      maxDepth: 4,
      maxNodes: 4,
      maxBytes: 64,
    );
    expect(
      exactGuard.copyMap(<String, Object?>{'nested': exactMap}),
      contains('nested'),
    );
    expect(exactMap.entriesVisited, 2);

    final overMap = _CountingMap(<String, Object?>{
      'one': true,
      'two': false,
      'three': null,
    });
    final overGuard = acp.AcpJsonInputGuard(
      resource: 'ACP test input',
      maxDepth: 4,
      maxNodes: 4,
      maxBytes: 64,
    );
    expect(
      () => overGuard.copyMap(<String, Object?>{'nested': overMap}),
      throwsA(
        isA<acp.AcpInputLimitExceeded>()
            .having((error) => error.limit, 'limit', 4)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 5),
      ),
    );
    expect(overMap.entriesVisited, 0);
  });

  test('remaining node precheck spans roots before reading a list', () {
    final exactList = _CountingList(<Object?>[true]);
    final exactGuard = acp.AcpJsonInputGuard(
      resource: 'ACP test input',
      maxDepth: 4,
      maxNodes: 4,
      maxBytes: 64,
    );
    exactGuard.copyMap(<String, Object?>{'one': true});
    expect(exactGuard.copyList(exactList), <Object?>[true]);
    expect(exactList.itemsRead, 1);

    final overList = _CountingList(<Object?>[true, false]);
    final overGuard = acp.AcpJsonInputGuard(
      resource: 'ACP test input',
      maxDepth: 4,
      maxNodes: 4,
      maxBytes: 64,
    );
    overGuard.copyMap(<String, Object?>{'one': true});
    expect(
      () => overGuard.copyList(overList),
      throwsA(
        isA<acp.AcpInputLimitExceeded>()
            .having((error) => error.limit, 'limit', 4)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 5),
      ),
    );
    expect(overList.itemsRead, 0);
  });

  test('lying map iteration stops at the first remaining-node overflow', () {
    final source = _LyingMap(
      reportedLength: 1,
      backingValues: <String, Object?>{
        'one': true,
        'two': false,
        'three': null,
        'four': 4,
        'five': 5,
      },
    );
    final guard = acp.AcpJsonInputGuard(
      resource: 'ACP test input',
      maxDepth: 4,
      maxNodes: 4,
      maxBytes: 64,
    );

    expect(
      () => guard.copyMap(source),
      throwsA(
        isA<acp.AcpInputLimitExceeded>()
            .having((error) => error.limit, 'limit', 4)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 5),
      ),
    );
    expect(source.entriesVisited, 4);
  });

  test('list guard uses one bounded length snapshot', () {
    final source = _ChangingLengthList(
      firstLength: 1,
      laterLength: 1000,
      values: <Object?>[true],
    );
    final guard = acp.AcpJsonInputGuard(
      resource: 'ACP test input',
      maxDepth: 4,
      maxNodes: 4,
      maxBytes: 64,
    );

    expect(guard.copyList(source), <Object?>[true]);
    expect(source.lengthReads, 1);
    expect(source.itemsRead, 1);
  });

  test('auth methods use one bounded length snapshot', () {
    final hidden = _HostileJsonValue('hidden-auth-secret');
    final source = _ChangingLengthList(
      firstLength: 1,
      laterLength: 2,
      values: <Object?>[
        <String, Object?>{'id': 'visible'},
        hidden,
      ],
    );

    final copied = acp.copyBoundedInitializeInput(
      agentCapabilities: const <String, Object?>{},
      authMethods: source,
    );

    expect(copied.authMethods, <Map<String, Object?>>[
      <String, Object?>{'id': 'visible'},
    ]);
    expect(source.lengthReads, 1);
    expect(source.itemsRead, 1);
    expect(hidden.toStringCalls, 0);
  });
}

AcpAgentCapabilities _parseCapabilities(
  Object? agentCapabilities, {
  Object? authMethods = const <Object?>[],
  acp.AcpInputBudget budget = const acp.AcpInputBudget(),
}) {
  return AcpAgentCapabilities.fromInitialize(
    protocolVersion: 1,
    agentCapabilities: agentCapabilities,
    authMethods: authMethods,
    clientCapabilities: const <String, dynamic>{},
    hasFsProvider: false,
    hasTerminalProvider: false,
    allowReadOutsideWorkspace: false,
    inputBudget: budget,
  );
}

class _HostileMapKey {
  _HostileMapKey(this.secret);

  final String secret;
  var toStringCalls = 0;

  @override
  String toString() {
    toStringCalls += 1;
    throw StateError(secret);
  }
}

class _HostileJsonValue {
  _HostileJsonValue(this.secret);

  final String secret;
  var toStringCalls = 0;

  @override
  String toString() {
    toStringCalls += 1;
    throw StateError(secret);
  }
}

class _CountingMap extends MapBase<String, Object?> {
  _CountingMap(this._values);

  final Map<String, Object?> _values;
  var entriesVisited = 0;

  @override
  Iterable<MapEntry<String, Object?>> get entries sync* {
    for (final entry in _values.entries) {
      entriesVisited += 1;
      yield entry;
    }
  }

  @override
  Iterable<String> get keys => _values.keys;

  @override
  int get length => _values.length;

  @override
  Object? operator [](Object? key) => _values[key];

  @override
  void operator []=(String key, Object? value) => _values[key] = value;

  @override
  void clear() => _values.clear();

  @override
  Object? remove(Object? key) => _values.remove(key);
}

class _CountingList extends ListBase<Object?> {
  _CountingList(this._values);

  final List<Object?> _values;
  var itemsRead = 0;

  @override
  int get length => _values.length;

  @override
  set length(int value) => throw UnsupportedError('fixed test list');

  @override
  Object? operator [](int index) {
    itemsRead += 1;
    return _values[index];
  }

  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('fixed test list');
}

class _LyingMap extends MapBase<String, Object?> {
  _LyingMap({required this.reportedLength, required this.backingValues});

  final int reportedLength;
  final Map<String, Object?> backingValues;
  var entriesVisited = 0;

  @override
  Iterable<MapEntry<String, Object?>> get entries sync* {
    for (final entry in backingValues.entries) {
      entriesVisited += 1;
      yield entry;
    }
  }

  @override
  Iterable<String> get keys => backingValues.keys;

  @override
  int get length => reportedLength;

  @override
  Object? operator [](Object? key) => backingValues[key];

  @override
  void operator []=(String key, Object? value) => backingValues[key] = value;

  @override
  void clear() => backingValues.clear();

  @override
  Object? remove(Object? key) => backingValues.remove(key);
}

class _ChangingLengthList extends ListBase<Object?> {
  _ChangingLengthList({
    required this.firstLength,
    required this.laterLength,
    required this.values,
  });

  final int firstLength;
  final int laterLength;
  final List<Object?> values;
  var lengthReads = 0;
  var itemsRead = 0;

  @override
  int get length {
    lengthReads += 1;
    return lengthReads == 1 ? firstLength : laterLength;
  }

  @override
  set length(int value) => throw UnsupportedError('fixed test list');

  @override
  Object? operator [](int index) {
    itemsRead += 1;
    return values[index];
  }

  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('fixed test list');
}
