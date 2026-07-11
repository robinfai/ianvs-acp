import 'package:dart_acp/dart_acp.dart' as acp;
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

  test('legacy boolean true capabilities remain supported', () {
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
