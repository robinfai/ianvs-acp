import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_agent_capabilities.dart';

void main() {
  test('capability objects advertise support while null and false do not', () {
    final capabilities = AcpAgentCapabilities.fromInitialize(
      protocolVersion: 1,
      agentCapabilities: <String, dynamic>{
        'auth': <String, dynamic>{'logout': null},
        'sessionCapabilities': <String, dynamic>{
          'list': <String, dynamic>{},
          'resume': null,
          'fork': false,
          'configOptions': true,
          'close': <String, dynamic>{'_meta': <String, dynamic>{}},
        },
      },
      authMethods: const <Map<String, dynamic>>[],
      clientCapabilities: const <String, dynamic>{},
      hasFsProvider: false,
      hasTerminalProvider: false,
      allowReadOutsideWorkspace: false,
    );

    expect(capabilities.auth.logout, isFalse);
    expect(capabilities.session.list, isTrue);
    expect(capabilities.session.resume, isFalse);
    expect(capabilities.session.fork, isFalse);
    expect(capabilities.session.configOptions, isTrue);
    expect(capabilities.session.close, isTrue);
  });

  test('legacy boolean true capabilities remain supported', () {
    final capabilities = AcpAgentCapabilities.fromInitialize(
      protocolVersion: 1,
      agentCapabilities: <String, dynamic>{
        'auth': <String, dynamic>{'logout': true},
        'sessionCapabilities': <String, dynamic>{
          'list': true,
          'resume': true,
          'fork': true,
          'configOptions': true,
          'close': true,
        },
      },
      authMethods: const <Map<String, dynamic>>[],
      clientCapabilities: const <String, dynamic>{},
      hasFsProvider: false,
      hasTerminalProvider: false,
      allowReadOutsideWorkspace: false,
    );

    expect(capabilities.auth.logout, isTrue);
    expect(capabilities.session.list, isTrue);
    expect(capabilities.session.resume, isTrue);
    expect(capabilities.session.fork, isTrue);
    expect(capabilities.session.configOptions, isTrue);
    expect(capabilities.session.close, isTrue);
  });
}
