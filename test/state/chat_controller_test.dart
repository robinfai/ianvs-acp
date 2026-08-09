import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:ianvs_acp/acp/acp_input_budget.dart' as acp;
import 'package:ianvs_acp/acp/acp_agent_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_permission_reviewer.dart';
import 'package:ianvs_acp/acp/acp_session_catalog.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/acp_session_usage.dart';
import 'package:ianvs_acp/acp/assistant_agent_enhancer.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/config/assistant_agent_config.dart';
import 'package:ianvs_acp/storage/session_transcript_cache.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/state/connection_state.dart' as app_state;

void main() {
  group('ChatMessage text buffer', () {
    test(
      'getter setter append revision and materialization stay compatible',
      () {
        final message = ChatMessage(
          role: ChatMessageRole.assistant,
          text: 'seed',
        );

        expect(message.text, 'seed');
        expect(message.revision, 0);
        expect(message.materializationCount, 0);

        message.appendAcceptedText(' one', acceptedUtf8Bytes: 4);
        expect(message.revision, 1);
        expect(message.materializationCount, 0);
        expect(message.text, 'seed one');
        expect(message.materializationCount, 1);
        expect(message.acceptedUtf8Bytes, 8);
        expect(message.text, 'seed one');
        expect(message.materializationCount, 1);

        message.appendAcceptedText('', acceptedUtf8Bytes: 0);
        expect(message.revision, 1);
        expect(
          () => message.appendAcceptedText('x', acceptedUtf8Bytes: 0),
          throwsArgumentError,
        );
        expect(message.text, 'seed one');
        expect(message.revision, 1);

        message.text = 'reset';
        expect(message.text, 'reset');
        expect(message.acceptedUtf8Bytes, 5);
        expect(message.revision, 2);
        message.appendAcceptedText('!', acceptedUtf8Bytes: 1);
        expect(message.text, 'reset!');
        expect(message.revision, 3);
        expect(message.materializationCount, 2);
      },
    );

    test('one hundred thousand micro chunks retain order in linear time', () {
      final message = ChatMessage(role: ChatMessageRole.assistant, text: '');
      final stopwatch = Stopwatch()..start();

      for (var index = 0; index < 100000; index += 1) {
        message.appendAcceptedText(
          String.fromCharCode(97 + index % 26),
          acceptedUtf8Bytes: 1,
        );
      }
      final text = message.text;
      stopwatch.stop();

      expect(text, hasLength(100000));
      expect(
        text.substring(0, 52),
        'abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz',
      );
      expect(text.substring(99974), 'efghijklmnopqrstuvwxyzabcd');
      expect(message.revision, 100000);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('freeze and thaw preserve value without sharing mutable state', () {
      final omission = acp.AcpInputOmission(
        reason: acp.AcpInputOmissionReason.inputLimit,
        resource: 'message text',
        truncated: true,
        limit: 4,
        observedAtLeast: 5,
      );
      final active = ChatMessage(
        role: ChatMessageRole.assistant,
        text: 'seed',
        timestamp: DateTime(2026, 7, 12, 10),
        metadata: const <String, Object?>{
          'nested': <String, Object?>{
            'items': <Object?>['safe'],
          },
        },
        omissions: <acp.AcpInputOmission>[omission],
      );
      active.appendAcceptedText('!', acceptedUtf8Bytes: 1);
      final retainedBeforeFreeze = active.retainedBytes;

      final frozen = active.freeze();
      final firstThaw = frozen.thaw();
      final secondThaw = frozen.thaw();

      expect(frozen, isNot(same(active)));
      expect(firstThaw, isNot(same(secondThaw)));
      expect(firstThaw.metadata, isNot(same(secondThaw.metadata)));
      expect(firstThaw.omissions, isNot(same(secondThaw.omissions)));
      expect(firstThaw.text, 'seed!');
      expect(firstThaw.role, active.role);
      expect(firstThaw.timestamp, active.timestamp);
      expect(firstThaw.revision, active.revision);
      expect(firstThaw.acceptedUtf8Bytes, active.acceptedUtf8Bytes);
      expect(firstThaw.retainedBytes, retainedBeforeFreeze);
      expect(frozen.retainedBytes, retainedBeforeFreeze);

      expect(() => frozen.text = 'changed', throwsStateError);
      expect(
        () => frozen.appendAcceptedText('x', acceptedUtf8Bytes: 1),
        throwsStateError,
      );
      expect(() => frozen.addOmission(omission), throwsStateError);
      expect(frozen.text, 'seed!');
      expect(frozen.revision, active.revision);

      firstThaw.appendAcceptedText(' first', acceptedUtf8Bytes: 6);
      secondThaw.text = 'second';
      expect(firstThaw.text, 'seed! first');
      expect(secondThaw.text, 'second');
      expect(frozen.text, 'seed!');
    });

    test('retained bytes are stable until an active mutation', () {
      final message = ChatMessage(
        role: ChatMessageRole.tool,
        text: 'abc',
        metadata: const <String, Object?>{
          'items': <Object?>[1, true, null],
        },
      );

      final initial = message.retainedBytes;
      expect(message.retainedBytes, initial);

      message.appendAcceptedText('d', acceptedUtf8Bytes: 1);
      final appended = message.retainedBytes;
      expect(appended, greaterThan(initial));
      expect(message.retainedBytes, appended);

      final frozen = message.freeze();
      final thawed = frozen.thaw();
      expect(frozen.retainedBytes, appended);
      expect(thawed.retainedBytes, appended);
    });

    test(
      'media retained bytes survive freeze thaw and archive restore exactly',
      () {
        const budget = acp.AcpInputBudget(
          maxEmbeddedMediaBytes: 1,
          maxStructuredStringBytes: 1,
        );
        ChatMessage image(String data) => ChatMessage(
          role: ChatMessageRole.assistant,
          text: '',
          metadata: <String, Object?>{
            'contentBlocks': <Object?>[
              <String, Object?>{'type': 'image', 'data': data},
            ],
          },
          inputBudget: budget,
        );

        final empty = image('');
        final active = image('YQ==');
        expect(active.retainedBytes, empty.retainedBytes + 4);
        final frozen = active.freeze();
        final thawed = frozen.thaw();
        expect(frozen.retainedBytes, active.retainedBytes);
        expect(thawed.retainedBytes, active.retainedBytes);
        expect(thawed.metadata.toString(), contains('YQ=='));

        final snapshot = ArchivedSessionSnapshot(
          session: AgentSession(
            id: 's',
            cwd: 'w',
            createdAt: DateTime(2026, 7, 13),
          ),
          wasCurrent: true,
          messages: <ChatMessage>[active],
          availableCommands: const <Map<String, Object?>>[],
          lastLatency: null,
          lastError: null,
          sessionSettings: const AcpSessionSettings(),
          sessionUsage: null,
          sessionSettingsLoading: false,
          status: app_state.ConnectionStatus.sessionReady,
          activeSessionSettingsLoadId: null,
          inputBudget: budget,
        );
        final controller = ChatController(
          client: FakeAgentClient(),
          cwd: 'w',
          inputBudget: budget,
        );
        addTearDown(controller.dispose);
        controller.restoreArchivedSessionLocally(snapshot);

        expect(
          controller.messages.single.metadata.toString(),
          contains('YQ=='),
        );
        expect(controller.messages.single.retainedBytes, active.retainedBytes);
      },
    );

    test('owned media omission provenance survives internal copies only', () {
      const canary = 'SECRET_OWNED_MEDIA_OMISSION';
      const budget = acp.AcpInputBudget(maxStructuredStringBytes: 1);
      final owned = ChatMessage(
        role: ChatMessageRole.assistant,
        text: '',
        metadata: const <String, Object?>{
          'contentBlocks': <Object?>[
            <String, Object?>{'type': 'image', 'data': canary},
            <String, Object?>{'type': 'audio', 'data': canary},
            <String, Object?>{
              'type': 'resource',
              'resource': <String, Object?>{'blob': canary},
            },
          ],
        },
      );
      final forged = ChatMessage(
        role: ChatMessageRole.assistant,
        text: '',
        metadata: const <String, Object?>{
          'contentBlocks': <Object?>[
            <String, Object?>{
              'type': 'omitted',
              'reason': 'invalid_encoding',
              'resource': 'image_data',
              'truncated': false,
            },
          ],
        },
      );

      List<Object?> resources(ChatMessage message) =>
          (message.metadata['contentBlocks']! as List)
              .map((block) => (block as Map)['resource'])
              .toList(growable: false);

      expect(resources(owned), <Object?>[
        'image_data',
        'audio_data',
        'resource_blob',
      ]);
      expect(owned.omissions.map((omission) => omission.resource), <String>[
        'image_data',
        'audio_data',
        'resource_blob',
      ]);
      final retained = owned.retainedBytes;
      final frozen = owned.freeze();
      final thawed = frozen.thaw();
      expect(resources(frozen), <Object?>[
        'image_data',
        'audio_data',
        'resource_blob',
      ]);
      expect(resources(thawed), resources(owned));
      expect(
        frozen.omissions.map((item) => item.resource),
        owned.omissions.map((item) => item.resource),
      );
      expect(frozen.retainedBytes, retained);
      expect(thawed.retainedBytes, retained);

      expect(resources(forged), <Object?>['external_omitted']);
      expect(forged.omissions, isEmpty);
      expect(resources(forged.freeze()), <Object?>['external_omitted']);
      expect(resources(forged.freeze().thaw()), <Object?>['external_omitted']);
      expect(forged.freeze().omissions, isEmpty);

      final snapshot = ArchivedSessionSnapshot(
        session: AgentSession(
          id: 's',
          cwd: 'w',
          createdAt: DateTime(2026, 7, 13),
        ),
        wasCurrent: true,
        messages: <ChatMessage>[owned, forged],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: const AcpSessionSettings(),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
      );
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: 'w',
        inputBudget: budget,
      );
      addTearDown(controller.dispose);
      controller.restoreArchivedSessionLocally(snapshot);

      expect(resources(controller.messages[0]), resources(owned));
      expect(
        controller.messages[0].omissions.map((item) => item.resource),
        owned.omissions.map((item) => item.resource),
      );
      expect(controller.messages[0].retainedBytes, retained);
      expect(resources(controller.messages[1]), <Object?>['external_omitted']);
      expect(controller.messages[1].omissions, isEmpty);
    });
  });

  group('ChatMessage guarded metadata and omissions', () {
    test(
      'content block retained bytes count every dynamic key and kind',
      () async {
        ChatMessage message(Map<String, Object?> metadata) => ChatMessage(
          role: ChatMessageRole.assistant,
          text: '',
          metadata: metadata,
        );

        final pairs = <(ChatMessage, ChatMessage)>[
          (
            message(<String, Object?>{'contentBlocks': <Object?>[], 'a': 'v'}),
            message(<String, Object?>{
              'contentBlocks': <Object?>[],
              'aaaa': 'v',
            }),
          ),
          (
            message(<String, Object?>{
              'contentBlocks': <Object?>[],
              'kind': 'x',
            }),
            message(<String, Object?>{
              'contentBlocks': <Object?>[],
              'kind': 'xxxx',
            }),
          ),
          (
            message(const <String, Object?>{
              'contentBlocks': <Object?>[
                <String, Object?>{'type': 'x', 'a': 'v'},
              ],
            }),
            message(const <String, Object?>{
              'contentBlocks': <Object?>[
                <String, Object?>{'type': 'xxxx', 'a': 'v'},
              ],
            }),
          ),
          (
            message(const <String, Object?>{
              'contentBlocks': <Object?>[
                <String, Object?>{
                  'type': 'resource',
                  'resource': <String, Object?>{'a': 'v'},
                },
              ],
            }),
            message(const <String, Object?>{
              'contentBlocks': <Object?>[
                <String, Object?>{
                  'type': 'resource',
                  'resource': <String, Object?>{'aaaa': 'v'},
                },
              ],
            }),
          ),
        ];
        for (final pair in pairs) {
          expect(pair.$2.retainedBytes - pair.$1.retainedBytes, 3);
          expect(pair.$1.freeze().retainedBytes, pair.$1.retainedBytes);
          expect(pair.$2.freeze().thaw().retainedBytes, pair.$2.retainedBytes);
        }

        final userRetained = ChatMessage(
          role: ChatMessageRole.user,
          text: 'u',
        ).retainedBytes;
        final small = pairs.first.$1;
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: acp.AcpInputBudget(
            maxTurnRetainedBytes: userRetained + small.retainedBytes + 1024,
          ),
        );
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        fake.emit(
          const AgentEvent(
            type: AgentEventType.agentTextDelta,
            text: '',
            metadata: <String, Object?>{
              'contentBlocks': <Object?>[],
              'aaaa': 'v',
            },
          ),
        );

        expect(
          controller.messages.where(
            (item) => item.metadata.containsKey('aaaa'),
          ),
          isEmpty,
        );
        final dynamic debug = controller;
        expect(debug.debugTurnOverflowed, isTrue);
      },
    );

    test('content block hostile kind never invokes equality', () {
      final hostileKind = _ThrowingEqualityValue();

      final message = ChatMessage(
        role: ChatMessageRole.assistant,
        text: '',
        metadata: <String, Object?>{
          'contentBlocks': <Object?>[],
          'kind': hostileKind,
        },
      );

      expect(hostileKind.equalityCalls, 0);
      expect(message.metadata, isEmpty);
      expect(
        message.omissions.single.reason,
        acp.AcpInputOmissionReason.invalidStructure,
      );
    });

    test('content block hostile type never invokes equality', () {
      const canary = 'SECRET_HOSTILE_CONTENT_BLOCK_TYPE';
      for (final dynamic hostileType in <Object>[
        _ThrowingEqualityValue(),
        _TrueEqualityValue(),
      ]) {
        late final ChatMessage message;
        expect(
          () => message = ChatMessage(
            role: ChatMessageRole.assistant,
            text: '',
            metadata: <String, Object?>{
              'contentBlocks': <Object?>[
                <String, Object?>{
                  'type': hostileType,
                  'data': 'AAAA',
                  'secret': canary,
                },
              ],
            },
          ),
          returnsNormally,
        );

        expect(hostileType.equalityCalls, 0);
        expect(message.metadata, isEmpty);
        expect(message.metadata.toString(), isNot(contains(canary)));
        expect(
          message.omissions.single.reason,
          acp.AcpInputOmissionReason.invalidStructure,
        );
      }
    });

    test('typed config hostile kind never invokes equality', () {
      for (final dynamic hostileKind in <Object>[
        _ThrowingEqualityValue(),
        _TrueEqualityValue(),
      ]) {
        final message = ChatMessage(
          role: ChatMessageRole.status,
          text: '',
          metadata: <String, Object?>{
            'kind': hostileKind,
            'configOptions': <AcpConfigOption>[],
          },
        );

        expect(hostileKind.equalityCalls, 0);
        expect(message.metadata, isEmpty);
        expect(
          message.omissions.single.reason,
          acp.AcpInputOmissionReason.invalidStructure,
        );
      }
    });

    test('resource blocks snapshot nested entries and guard dynamic keys', () {
      ChatMessage resource(
        Map<String, Object?> nested,
        acp.AcpInputBudget budget,
      ) => ChatMessage(
        role: ChatMessageRole.assistant,
        text: '',
        metadata: <String, Object?>{
          'contentBlocks': <Object?>[
            <String, Object?>{'type': 'resource', 'resource': nested},
          ],
        },
        inputBudget: budget,
      );

      const entryBudget = acp.AcpInputBudget(
        maxCollectionItems: 2,
        maxMetadataEntries: 2,
      );
      final exact = resource(<String, Object?>{
        'uri': 'u',
        'title': 't',
      }, entryBudget);
      expect(exact.metadata['contentBlocks'], isNotEmpty);
      expect(exact.omissions, isEmpty);

      const canary = 'SECRET_RESOURCE_KEY_CANARY';
      final plusOne = resource(<String, Object?>{
        'uri': 'u',
        'title': 't',
        'x': canary,
      }, entryBudget);
      expect(plusOne.metadata, isEmpty);
      expect(plusOne.metadata.toString(), isNot(contains(canary)));
      expect(plusOne.omissions, hasLength(1));

      final longKey = resource(<String, Object?>{
        canary: 'v',
      }, const acp.AcpInputBudget(maxStructuredStringBytes: 4));
      expect(longKey.metadata, isEmpty);
      expect(longKey.metadata.toString(), isNot(contains(canary)));

      final stateful = resource(
        _ReportedLengthResourceMap(canary),
        const acp.AcpInputBudget(),
      );
      expect(stateful.metadata, isEmpty);
      expect(stateful.metadata.toString(), isNot(contains(canary)));

      final throwing = resource(
        _ThrowingMetadataMap(canary),
        const acp.AcpInputBudget(),
      );
      expect(throwing.metadata, isEmpty);
      expect(throwing.metadata.toString(), isNot(contains(canary)));
    });

    test('metadata is defensively copied and deeply immutable', () {
      final nested = <String, Object?>{'value': 'original'};
      final items = <Object?>[nested];
      final source = <String, Object?>{'items': items};

      final message = ChatMessage(
        role: ChatMessageRole.tool,
        text: 'safe',
        metadata: source,
      );
      nested['value'] = 'changed';
      items.add('changed');
      source['late'] = 'changed';

      final copiedItems = message.metadata['items']! as List<Object?>;
      expect(copiedItems, hasLength(1));
      expect(
        (copiedItems.single! as Map<String, Object?>)['value'],
        'original',
      );
      expect(message.metadata, isNot(contains('late')));
      expect(() => message.metadata['new'] = 1, throwsUnsupportedError);
      expect(() => copiedItems.add(2), throwsUnsupportedError);
      expect(
        () => (copiedItems.single! as Map<String, Object?>)['value'] = 'x',
        throwsUnsupportedError,
      );
    });

    test('hostile metadata fails safe without leaking payload', () {
      const canary = 'CHAT_METADATA_CANARY_MUST_NOT_APPEAR';
      final message = ChatMessage(
        role: ChatMessageRole.tool,
        text: 'safe',
        metadata: <String, Object?>{
          'omissions': <Object?>[
            <String, Object?>{
              'resource': 'forged',
              'reason': 'inputLimit',
              'payload': canary,
            },
          ],
          'bad': StringBuffer(canary),
        },
      );

      expect(message.metadata, isEmpty);
      expect(message.text, 'safe');
      expect(message.omissions, hasLength(1));
      expect(
        message.omissions.single.reason,
        acp.AcpInputOmissionReason.invalidStructure,
      );
      expect(message.omissions.single.resource, 'chat message metadata');
      expect(message.omissions.single.toString(), isNot(contains(canary)));
    });

    test('metadata over its guard budget records a payload-free omission', () {
      const canary = 'CHAT_METADATA_LIMIT_CANARY_MUST_NOT_APPEAR';
      final message = ChatMessage(
        role: ChatMessageRole.tool,
        text: 'safe',
        metadata: const <String, Object?>{'first': 'safe', 'second': canary},
        inputBudget: const acp.AcpInputBudget(maxMetadataNodes: 2),
      );

      expect(message.metadata, isEmpty);
      expect(
        message.omissions.single.reason,
        acp.AcpInputOmissionReason.inputLimit,
      );
      expect(message.omissions.single.limit, 2);
      expect(message.omissions.single.toString(), isNot(contains(canary)));
    });

    test('structured metadata guard enforces depth and entry limits', () {
      final depthLimited = ChatMessage(
        role: ChatMessageRole.tool,
        text: 'safe',
        metadata: const <String, Object?>{
          'nested': <String, Object?>{'value': 'safe'},
        },
        inputBudget: const acp.AcpInputBudget(maxJsonDepth: 1),
      );
      final entryLimited = ChatMessage(
        role: ChatMessageRole.tool,
        text: 'safe',
        metadata: const <String, Object?>{'a': 1, 'b': 2},
        inputBudget: const acp.AcpInputBudget(maxMetadataEntries: 1),
      );

      expect(depthLimited.metadata, isEmpty);
      expect(
        depthLimited.omissions.single.reason,
        acp.AcpInputOmissionReason.inputLimit,
      );
      expect(entryLimited.metadata, isEmpty);
      expect(entryLimited.omissions.single.limit, 1);
    });

    test('structured metadata nodes bytes and strings honor exact limits', () {
      ChatMessage message(acp.AcpInputBudget budget, String value) {
        return ChatMessage(
          role: ChatMessageRole.tool,
          text: 'safe',
          metadata: <String, Object?>{'a': value},
          inputBudget: budget,
        );
      }

      expect(
        message(
          const acp.AcpInputBudget(maxStructuredUpdateNodes: 2),
          'b',
        ).metadata,
        {'a': 'b'},
      );
      expect(
        message(
          const acp.AcpInputBudget(maxStructuredUpdateNodes: 1),
          'b',
        ).metadata,
        isEmpty,
      );
      expect(
        message(
          const acp.AcpInputBudget(maxStructuredUpdateBytes: 2),
          'b',
        ).metadata,
        {'a': 'b'},
      );
      expect(
        message(
          const acp.AcpInputBudget(maxStructuredUpdateBytes: 1),
          'b',
        ).metadata,
        isEmpty,
      );
      expect(
        message(
          const acp.AcpInputBudget(maxStructuredStringBytes: 1),
          'b',
        ).metadata,
        {'a': 'b'},
      );
      expect(
        message(
          const acp.AcpInputBudget(maxStructuredStringBytes: 1),
          'bb',
        ).metadata,
        isEmpty,
      );
    });

    test(
      'deep allowed metadata is copied iteratively and remains immutable',
      () {
        Map<String, Object?> metadata = <String, Object?>{'leaf': 'safe'};
        for (var depth = 0; depth < 256; depth += 1) {
          metadata = <String, Object?>{'next': metadata};
        }
        final message = ChatMessage(
          role: ChatMessageRole.tool,
          text: 'safe',
          metadata: metadata,
          inputBudget: const acp.AcpInputBudget(
            maxJsonDepth: 300,
            maxMetadataDepth: 300,
            maxMetadataNodes: 600,
            maxStructuredUpdateNodes: 600,
          ),
        );

        expect(message.metadata, isNotEmpty);
        Map<String, Object?> cursor = message.metadata;
        for (var depth = 0; depth < 256; depth += 1) {
          cursor = cursor['next']! as Map<String, Object?>;
        }
        expect(cursor['leaf'], 'safe');
        expect(() => cursor['late'] = 'no', throwsUnsupportedError);
      },
    );

    test('typed omissions are copied deduplicated immutable and bounded', () {
      acp.AcpInputOmission omission(String resource, int limit) {
        return acp.AcpInputOmission(
          reason: acp.AcpInputOmissionReason.inputLimit,
          resource: resource,
          truncated: true,
          limit: limit,
          observedAtLeast: limit + 1,
        );
      }

      final source = <acp.AcpInputOmission>[
        omission('message text', 4),
        omission('message text', 8),
        omission('thought text', 4),
        omission('ignored third resource', 4),
      ];
      final message = ChatMessage(
        role: ChatMessageRole.assistant,
        text: '',
        omissions: source,
        inputBudget: const acp.AcpInputBudget(maxCollectionItems: 2),
        metadata: const <String, Object?>{
          'omissions': <Object?>[
            <String, Object?>{'resource': 'forged', 'reason': 'inputLimit'},
          ],
        },
      );
      source.clear();

      expect(message.omissions.map((item) => item.resource), [
        'message text',
        'thought text',
      ]);
      expect(message.omissions, hasLength(2));
      expect(
        () => message.omissions.add(omission('another', 4)),
        throwsUnsupportedError,
      );
      expect(message.addOmission(omission('message text', 16)), isFalse);
      expect(message.addOmission(omission('over limit', 4)), isFalse);
      expect(message.revision, 0);

      final growing = ChatMessage(role: ChatMessageRole.assistant, text: '');
      expect(growing.addOmission(omission('new resource', 4)), isTrue);
      expect(growing.revision, 1);
    });

    test('trusted omissions take capacity before local metadata failures', () {
      final trusted = acp.AcpInputOmission(
        reason: acp.AcpInputOmissionReason.inputLimit,
        resource: 'trusted event resource',
        truncated: true,
        limit: 1,
        observedAtLeast: 2,
      );
      final message = ChatMessage(
        role: ChatMessageRole.tool,
        text: 'safe',
        metadata: <String, Object?>{'bad': StringBuffer('payload')},
        omissions: <acp.AcpInputOmission>[trusted],
        inputBudget: const acp.AcpInputBudget(maxCollectionItems: 1),
      );

      expect(message.metadata, isEmpty);
      expect(message.omissions, hasLength(1));
      expect(message.omissions.single.resource, 'trusted event resource');
      expect(() => message.omissions.add(trusted), throwsUnsupportedError);
    });
  });

  group('ChatController turn text budgets', () {
    test('input budget is validated during controller construction', () {
      expect(
        () => ChatController(
          client: FakeAgentClient(),
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(maxMessageTextBytes: 4),
        ),
        throwsA(isA<acp.AcpInputLimitExceeded>()),
      );
    });

    test('split surrogate pairs survive tool and status boundaries', () async {
      final high = String.fromCharCode(0xd83d);
      final low = String.fromCharCode(0xde00);
      final controller = ChatController(
        client: FakeAgentClient(
          promptEvents: [
            AgentEvent(type: AgentEventType.agentTextDelta, text: high),
            const AgentEvent(
              type: AgentEventType.toolCall,
              text: 'tool boundary',
            ),
            AgentEvent(type: AgentEventType.agentTextDelta, text: low),
            AgentEvent(
              type: AgentEventType.status,
              text: high,
              metadata: const <String, Object?>{'kind': 'thought'},
            ),
            const AgentEvent(
              type: AgentEventType.status,
              text: 'ordinary status boundary',
            ),
            AgentEvent(
              type: AgentEventType.status,
              text: low,
              metadata: const <String, Object?>{'kind': 'thought'},
            ),
            const AgentEvent(type: AgentEventType.agentTextDone, text: ''),
          ],
        ),
        cwd: '/workspace',
        inputBudget: const acp.AcpInputBudget(
          maxMessageTextBytes: 4,
          maxThoughtTextBytes: 4,
          maxMarkdownFallbackBytes: 4,
        ),
      );
      addTearDown(controller.dispose);

      await controller.sendPrompt('go');
      await pumpEventQueue();

      final textMessages = controller.messages
          .where((message) => message.role == ChatMessageRole.assistant)
          .toList();
      final thoughtMessages = controller.messages
          .where((message) => message.metadata['kind'] == 'thought')
          .toList();
      expect(textMessages.map((message) => message.text), ['$high$low', '']);
      expect(thoughtMessages.map((message) => message.text), ['$high$low', '']);
      expect(textMessages.map((message) => message.acceptedUtf8Bytes), [4, 0]);
      expect(thoughtMessages.map((message) => message.acceptedUtf8Bytes), [
        4,
        0,
      ]);
      final toolIndex = controller.messages.indexWhere(
        (message) => message.role == ChatMessageRole.tool,
      );
      final ordinaryStatusIndex = controller.messages.indexWhere(
        (message) =>
            message.role == ChatMessageRole.status &&
            message.metadata['kind'] != 'thought',
      );
      expect(
        controller.messages.indexOf(textMessages.first),
        lessThan(toolIndex),
      );
      expect(
        controller.messages.indexOf(textMessages.last),
        greaterThan(toolIndex),
      );
      expect(
        controller.messages.indexOf(thoughtMessages.first),
        lessThan(ordinaryStatusIndex),
      );
      expect(
        controller.messages.indexOf(thoughtMessages.last),
        greaterThan(ordinaryStatusIndex),
      );
      expect(
        controller.messages
            .expand((message) => message.omissions)
            .where((omission) => omission.resource == 'display text'),
        hasLength(2),
      );
    });

    test(
      'pending high surrogate and following non-low keep source order',
      () async {
        final high = String.fromCharCode(0xd83d);
        final controller = ChatController(
          client: FakeAgentClient(
            promptEvents: [
              AgentEvent(type: AgentEventType.agentTextDelta, text: high),
              const AgentEvent(type: AgentEventType.toolCall, text: 'tool'),
              const AgentEvent(type: AgentEventType.agentTextDelta, text: 'a'),
              AgentEvent(
                type: AgentEventType.status,
                text: high,
                metadata: const <String, Object?>{'kind': 'thought'},
              ),
              const AgentEvent(type: AgentEventType.status, text: 'status'),
              const AgentEvent(
                type: AgentEventType.status,
                text: 'b',
                metadata: <String, Object?>{'kind': 'thought'},
              ),
              const AgentEvent(type: AgentEventType.agentTextDone, text: ''),
            ],
          ),
          cwd: '/workspace',
        );
        addTearDown(controller.dispose);

        await controller.sendPrompt('go');
        await pumpEventQueue();

        expect(
          controller.messages
              .where((message) => message.role == ChatMessageRole.assistant)
              .map((message) => message.text),
          [high, 'a'],
        );
        expect(
          controller.messages
              .where((message) => message.role == ChatMessageRole.assistant)
              .map((message) => message.acceptedUtf8Bytes),
          [3, 1],
        );
        expect(
          controller.messages
              .where((message) => message.metadata['kind'] == 'thought')
              .map((message) => message.text),
          [high, 'b'],
        );
        expect(
          controller.messages
              .where((message) => message.metadata['kind'] == 'thought')
              .map((message) => message.acceptedUtf8Bytes),
          [3, 1],
        );
      },
    );

    test(
      'consecutive pending high surrogates retain each source target',
      () async {
        final high = String.fromCharCode(0xd83d);
        final low = String.fromCharCode(0xde00);
        final controller = ChatController(
          client: FakeAgentClient(
            promptEvents: [
              AgentEvent(type: AgentEventType.agentTextDelta, text: high),
              const AgentEvent(type: AgentEventType.toolCall, text: 'tool-1'),
              AgentEvent(type: AgentEventType.agentTextDelta, text: high),
              const AgentEvent(type: AgentEventType.status, text: 'status-1'),
              AgentEvent(type: AgentEventType.agentTextDelta, text: low),
              AgentEvent(
                type: AgentEventType.status,
                text: high,
                metadata: const <String, Object?>{'kind': 'thought'},
              ),
              const AgentEvent(type: AgentEventType.status, text: 'status-2'),
              AgentEvent(
                type: AgentEventType.status,
                text: high,
                metadata: const <String, Object?>{'kind': 'thought'},
              ),
              const AgentEvent(type: AgentEventType.toolCall, text: 'tool-2'),
              AgentEvent(
                type: AgentEventType.status,
                text: low,
                metadata: const <String, Object?>{'kind': 'thought'},
              ),
              const AgentEvent(type: AgentEventType.agentTextDone, text: ''),
            ],
          ),
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(
            maxMessageTextBytes: 7,
            maxThoughtTextBytes: 7,
            maxMarkdownFallbackBytes: 7,
          ),
        );
        addTearDown(controller.dispose);

        await controller.sendPrompt('go');
        await pumpEventQueue();

        expect(
          controller.messages
              .where((message) => message.role == ChatMessageRole.assistant)
              .map((message) => message.text),
          [high, '$high$low', ''],
        );
        expect(
          controller.messages
              .where((message) => message.role == ChatMessageRole.assistant)
              .map((message) => message.acceptedUtf8Bytes),
          [3, 4, 0],
        );
        expect(
          controller.messages
              .where((message) => message.metadata['kind'] == 'thought')
              .map((message) => message.text),
          [high, '$high$low', ''],
        );
        expect(
          controller.messages
              .where((message) => message.metadata['kind'] == 'thought')
              .map((message) => message.acceptedUtf8Bytes),
          [3, 4, 0],
        );
      },
    );

    test(
      'pending surrogate limit omission belongs to its source target',
      () async {
        final high = String.fromCharCode(0xd83d);
        final low = String.fromCharCode(0xde00);
        final controller = ChatController(
          client: FakeAgentClient(
            promptEvents: [
              AgentEvent(type: AgentEventType.agentTextDelta, text: high),
              const AgentEvent(type: AgentEventType.toolCall, text: 'tool'),
              AgentEvent(type: AgentEventType.agentTextDelta, text: low),
              AgentEvent(
                type: AgentEventType.status,
                text: high,
                metadata: const <String, Object?>{'kind': 'thought'},
              ),
              const AgentEvent(type: AgentEventType.status, text: 'status'),
              AgentEvent(
                type: AgentEventType.status,
                text: low,
                metadata: const <String, Object?>{'kind': 'thought'},
              ),
              const AgentEvent(type: AgentEventType.agentTextDone, text: ''),
            ],
          ),
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(
            maxMessageTextBytes: 3,
            maxThoughtTextBytes: 3,
            maxMarkdownFallbackBytes: 3,
          ),
        );
        addTearDown(controller.dispose);

        await controller.sendPrompt('go');
        await pumpEventQueue();

        final textMessages = controller.messages
            .where((message) => message.role == ChatMessageRole.assistant)
            .toList();
        final thoughtMessages = controller.messages
            .where((message) => message.metadata['kind'] == 'thought')
            .toList();
        expect(textMessages.map((message) => message.text), ['', '']);
        expect(thoughtMessages.map((message) => message.text), ['', '']);
        expect(textMessages.map((message) => message.acceptedUtf8Bytes), [
          0,
          0,
        ]);
        expect(thoughtMessages.map((message) => message.acceptedUtf8Bytes), [
          0,
          0,
        ]);
        expect(textMessages.first.omissions.single.resource, 'message text');
        expect(textMessages.last.omissions, isEmpty);
        expect(thoughtMessages.first.omissions.single.resource, 'thought text');
        expect(thoughtMessages.last.omissions, isEmpty);
      },
    );

    test(
      'finish without a low surrogate writes to the source target',
      () async {
        final high = String.fromCharCode(0xd83d);
        final controller = ChatController(
          client: FakeAgentClient(
            promptEvents: [
              AgentEvent(type: AgentEventType.agentTextDelta, text: high),
              const AgentEvent(type: AgentEventType.toolCall, text: 'tool'),
              AgentEvent(
                type: AgentEventType.status,
                text: high,
                metadata: const <String, Object?>{'kind': 'thought'},
              ),
              const AgentEvent(type: AgentEventType.status, text: 'status'),
              const AgentEvent(type: AgentEventType.agentTextDone, text: ''),
            ],
          ),
          cwd: '/workspace',
        );
        addTearDown(controller.dispose);

        await controller.sendPrompt('go');
        await pumpEventQueue();

        expect(
          controller.messages
              .where((message) => message.role == ChatMessageRole.assistant)
              .single
              .text,
          high,
        );
        expect(
          controller.messages
              .where((message) => message.metadata['kind'] == 'thought')
              .single
              .text,
          high,
        );
      },
    );

    test(
      'done and error flush pending text without borrowing its projection',
      () async {
        const canary = 'DONE_EVENT_TEXT_CANARY_MUST_NOT_APPEAR';
        final high = String.fromCharCode(0xd83d);

        Future<void> verify({required bool error}) async {
          final fake = _ControlledPromptAgentClient();
          final controller = ChatController(client: fake, cwd: '/workspace');
          await controller.newSession();
          await controller.sendPrompt('u');
          final observed = <AgentEvent>[];
          controller.addAgentEventObserver((_, event) => observed.add(event));

          fake.emit(
            AgentEvent(type: AgentEventType.agentTextDelta, text: high),
          );
          fake.emit(
            error
                ? const AgentEvent(type: AgentEventType.error, text: 'boom')
                : const AgentEvent(
                    type: AgentEventType.agentTextDone,
                    text: canary,
                  ),
          );

          final assistant = controller.messages.singleWhere(
            (message) => message.role == ChatMessageRole.assistant,
          );
          expect(assistant.text, high);
          expect(assistant.acceptedUtf8Bytes, 3);
          expect(observed, hasLength(2));
          expect(observed.last.text, error ? 'boom' : '');
          expect(observed.last.metadata, isEmpty);
          expect(observed.last.text, isNot(contains(high)));
          expect(observed.last.toString(), isNot(contains(canary)));
          controller.dispose();
          await controller.disposalComplete;
        }

        await verify(error: false);
        await verify(error: true);
      },
    );

    test(
      'turn finish omissions never borrow the terminal projection',
      () async {
        final high = String.fromCharCode(0xd83d);

        final omissionFake = _ControlledPromptAgentClient();
        final omissionController = ChatController(
          client: omissionFake,
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(
            maxMessageTextBytes: 2,
            maxMarkdownFallbackBytes: 2,
          ),
        );
        await omissionController.newSession();
        await omissionController.sendPrompt('u');
        final omissionObserved = <AgentEvent>[];
        omissionController.addAgentEventObserver(
          (_, event) => omissionObserved.add(event),
        );
        omissionFake.emit(
          AgentEvent(type: AgentEventType.agentTextDelta, text: high),
        );
        omissionFake.emit(
          const AgentEvent(type: AgentEventType.agentTextDone, text: ''),
        );

        final omittedAssistant = omissionController.messages.singleWhere(
          (message) => message.role == ChatMessageRole.assistant,
        );
        expect(
          omittedAssistant.omissions.where(
            (omission) => omission.resource == 'message text',
          ),
          hasLength(1),
        );
        expect(
          omissionObserved.last.omissions.where(
            (omission) => omission.resource == 'message text',
          ),
          isEmpty,
        );
        omissionController.dispose();
        await omissionController.disposalComplete;

        final measuringFake = _ControlledPromptAgentClient();
        final measuring = ChatController(
          client: measuringFake,
          cwd: '/workspace',
        );
        await measuring.newSession();
        await measuring.sendPrompt('u');
        measuringFake.emit(
          AgentEvent(type: AgentEventType.agentTextDelta, text: high),
        );
        final dynamic measuringDebug = measuring;
        final pendingRetained =
            measuringDebug.debugCurrentTurnRetainedBytes as int;
        measuring.dispose();
        await measuring.disposalComplete;
        final errorRetained = ChatMessage(
          role: ChatMessageRole.error,
          text: 'boom',
        ).retainedBytes;

        Future<void> verifyRetainedOverflow({required bool error}) async {
          final fake = _ControlledPromptAgentClient();
          final controller = ChatController(
            client: fake,
            cwd: '/workspace',
            inputBudget: acp.AcpInputBudget(
              maxTurnRetainedBytes:
                  pendingRetained + (error ? errorRetained : 0) + 1024,
            ),
          );
          await controller.newSession();
          await controller.sendPrompt('u');
          final observed = <AgentEvent>[];
          controller.addAgentEventObserver((_, event) => observed.add(event));
          fake.emit(
            AgentEvent(type: AgentEventType.agentTextDelta, text: high),
          );
          fake.emit(
            error
                ? const AgentEvent(type: AgentEventType.error, text: 'boom')
                : const AgentEvent(
                    type: AgentEventType.agentTextDone,
                    text: '',
                  ),
          );

          expect(
            controller.messages
                .expand((message) => message.omissions)
                .where(
                  (omission) => omission.resource == 'turn retained bytes',
                ),
            hasLength(1),
          );
          expect(
            observed.last.omissions.where(
              (omission) => omission.resource == 'turn retained bytes',
            ),
            isEmpty,
          );
          expect(observed.last.text, error ? 'boom' : '');
          controller.dispose();
          await controller.disposalComplete;
        }

        await verifyRetainedOverflow(error: false);
        await verifyRetainedOverflow(error: true);
      },
    );

    test(
      'unknown stop reason is a bounded projection with exact root accounting',
      () async {
        const canary = 'SECRET_UNKNOWN_STOP_REASON_CANARY_MUST_NOT_APPEAR';
        const stopReason = '$canary-suffix';
        const baseBudget = acp.AcpInputBudget(
          maxStructuredStringBytes: 256,
          maxMessageTextBytes: 16,
          maxMarkdownFallbackBytes: 16,
        );

        Future<({ChatController controller, List<AgentEvent> observed})> run(
          acp.AcpInputBudget budget,
        ) async {
          final controller = ChatController(
            client: FakeAgentClient(
              resumeEvents: const <AgentEvent>[
                AgentEvent(
                  type: AgentEventType.agentTextDone,
                  text: canary,
                  metadata: <String, Object?>{
                    'kind': 'turn',
                    'stopReason': stopReason,
                  },
                ),
              ],
            ),
            cwd: '/workspace',
            inputBudget: budget,
          );
          final observed = <AgentEvent>[];
          controller.addAgentEventObserver((_, event) => observed.add(event));
          await controller.resumeSession('resume');
          return (controller: controller, observed: observed);
        }

        final baseline = await run(baseBudget);
        final retained = baseline.controller.messages.single.retainedBytes;
        expect(baseline.controller.messages.single.text.length, lessThan(30));
        baseline.controller.dispose();
        await baseline.controller.disposalComplete;

        for (final delta in const <int>[0, -1]) {
          final result = await run(
            acp.AcpInputBudget(
              maxStructuredStringBytes: 256,
              maxMessageTextBytes: 16,
              maxMarkdownFallbackBytes: 16,
              maxTurnRetainedBytes: retained + 1024 + delta,
            ),
          );
          final accepted = delta == 0;
          expect(result.controller.messages, hasLength(1));
          expect(
            result.controller.messages.single.metadata,
            accepted
                ? const <String, Object?>{
                    'kind': 'turn',
                    'stopReason': 'unknown',
                  }
                : isEmpty,
          );
          expect(result.observed, hasLength(1));
          expect(result.observed.single.text, accepted ? isNotEmpty : isEmpty);
          expect(
            result.observed.single.metadata,
            accepted
                ? const <String, Object?>{
                    'kind': 'turn',
                    'stopReason': 'unknown',
                  }
                : isEmpty,
          );
          expect(
            <Object?>[
              ...result.controller.messages.map(
                (message) => <Object?>[message.text, message.metadata],
              ),
              result.observed.single,
            ].toString(),
            isNot(contains(canary)),
          );
          expect(
            result.observed.single.omissions.where(
              (omission) =>
                  omission.resource ==
                  (accepted ? 'display text' : 'turn retained bytes'),
            ),
            hasLength(1),
          );
          result.controller.dispose();
          await result.controller.disposalComplete;
        }
      },
    );

    test(
      'CRLF and limits aggregate across text tool and status messages',
      () async {
        const textCanary = 'TEXT_BUDGET_CANARY_MUST_NOT_APPEAR';
        const thoughtCanary = 'THOUGHT_BUDGET_CANARY_MUST_NOT_APPEAR';
        final controller = ChatController(
          client: FakeAgentClient(
            promptEvents: const [
              AgentEvent(type: AgentEventType.agentTextDelta, text: 'a\r'),
              AgentEvent(type: AgentEventType.toolCall, text: 'tool boundary'),
              AgentEvent(type: AgentEventType.agentTextDelta, text: '\nb'),
              AgentEvent(
                type: AgentEventType.status,
                text: 'ordinary text status boundary',
              ),
              AgentEvent(
                type: AgentEventType.agentTextDelta,
                text: '\n$textCanary',
              ),
              AgentEvent(
                type: AgentEventType.status,
                text: 'x\r',
                metadata: <String, Object?>{'kind': 'thought'},
              ),
              AgentEvent(
                type: AgentEventType.status,
                text: 'ordinary status boundary',
              ),
              AgentEvent(
                type: AgentEventType.status,
                text: '\ny',
                metadata: <String, Object?>{'kind': 'thought'},
              ),
              AgentEvent(
                type: AgentEventType.status,
                text: '\n$thoughtCanary',
                metadata: <String, Object?>{'kind': 'thought'},
              ),
              AgentEvent(type: AgentEventType.agentTextDone, text: ''),
            ],
          ),
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(
            maxMessageTextBytes: 128,
            maxMessageTextLines: 2,
            maxThoughtTextBytes: 128,
            maxMarkdownFallbackBytes: 64,
          ),
        );
        addTearDown(controller.dispose);

        await controller.sendPrompt('go');
        await pumpEventQueue();

        final assistantMessages = controller.messages.where(
          (message) => message.role == ChatMessageRole.assistant,
        );
        final thoughtMessages = controller.messages.where(
          (message) => message.metadata['kind'] == 'thought',
        );
        expect(
          assistantMessages.map((message) => message.text).join(),
          'a\r\nb',
        );
        expect(thoughtMessages.map((message) => message.text).join(), 'x\r\ny');
        final output = controller.messages
            .map((message) => message.text)
            .join();
        expect(output, isNot(contains(textCanary)));
        expect(output, isNot(contains(thoughtCanary)));
        expect(
          assistantMessages
              .expand((message) => message.omissions)
              .map((item) => item.resource),
          contains('message text'),
        );
        expect(
          thoughtMessages
              .expand((message) => message.omissions)
              .map((item) => item.resource),
          contains('thought text'),
        );
      },
    );

    test(
      'thought metadata failures preserve the thought counter and drain',
      () async {
        const canary = 'SECRET_THOUGHT_METADATA_CANARY';

        Future<void> verify({
          required acp.AcpInputBudget budget,
          required Map<String, Object?> metadata,
          required acp.AcpInputOmissionReason metadataReason,
        }) async {
          final fake = _ControlledPromptAgentClient();
          final controller = ChatController(
            client: fake,
            cwd: '/workspace',
            inputBudget: budget,
          );
          await controller.newSession();
          await controller.sendPrompt('u');
          final observed = <AgentEvent>[];
          controller.addAgentEventObserver((_, event) => observed.add(event));

          fake.emit(
            AgentEvent(
              type: AgentEventType.status,
              text: 'a$canary',
              metadata: metadata,
            ),
          );
          fake.emit(
            const AgentEvent(
              type: AgentEventType.status,
              text: canary,
              metadata: <String, Object?>{'kind': 'thought'},
            ),
          );

          final thoughtMessages = controller.messages.where(
            (message) => message.metadata['kind'] == 'thought',
          );
          expect(
            thoughtMessages,
            isNotEmpty,
            reason:
                '${controller.messages.map((message) => <Object?>[message.text, message.metadata, message.omissions])} error=${controller.lastError}',
          );
          final thought = thoughtMessages.single;
          expect(thought.text, 'a');
          expect(
            thought.omissions.where(
              (omission) =>
                  omission.resource == 'chat message metadata' &&
                  omission.reason == metadataReason,
            ),
            hasLength(1),
          );
          expect(
            thought.omissions.where(
              (omission) => omission.resource == 'thought text',
            ),
            hasLength(1),
          );
          expect(observed.first.metadata['kind'], 'thought');
          expect(observed.first.text, 'a');
          expect(
            observed.map((event) => event.text).join(),
            isNot(contains(canary)),
          );
          expect(
            controller.messages
                .expand((message) => message.omissions)
                .where((omission) => omission.resource == 'thought text'),
            hasLength(1),
          );
          controller.dispose();
          await controller.disposalComplete;
        }

        await verify(
          budget: const acp.AcpInputBudget(
            maxMessageTextBytes: 100,
            maxThoughtTextBytes: 1,
            maxMarkdownFallbackBytes: 100,
          ),
          metadata: <String, Object?>{
            'kind': 'thought',
            'bad': _CanaryPayload(),
          },
          metadataReason: acp.AcpInputOmissionReason.invalidStructure,
        );
        await verify(
          budget: const acp.AcpInputBudget(
            maxMessageTextBytes: 100,
            maxThoughtTextBytes: 1,
            maxMarkdownFallbackBytes: 100,
            maxStructuredStringBytes: 16,
          ),
          metadata: const <String, Object?>{'kind': 'thought', 'bad': canary},
          metadataReason: acp.AcpInputOmissionReason.inputLimit,
        );
      },
    );

    List<AgentEvent> twoTurnEvents() => const <AgentEvent>[
      AgentEvent(type: AgentEventType.userMessage, text: 'user one'),
      AgentEvent(type: AgentEventType.agentTextDelta, text: 'a'),
      AgentEvent(
        type: AgentEventType.status,
        text: 'x',
        metadata: <String, Object?>{'kind': 'thought'},
      ),
      AgentEvent(type: AgentEventType.userMessage, text: 'user two'),
      AgentEvent(type: AgentEventType.agentTextDelta, text: 'b'),
      AgentEvent(
        type: AgentEventType.status,
        text: 'y',
        metadata: <String, Object?>{'kind': 'thought'},
      ),
    ];

    void expectTwoTurns(
      ChatController controller, {
      required int expectedDisplayOmissions,
    }) {
      expect(
        controller.messages
            .where((message) => message.role == ChatMessageRole.assistant)
            .map((message) => message.text),
        ['a', 'b'],
      );
      expect(
        controller.messages
            .where((message) => message.metadata['kind'] == 'thought')
            .map((message) => message.text),
        ['x', 'y'],
      );
      expect(
        controller.messages
            .expand((message) => message.omissions)
            .where((omission) => omission.resource == 'display text'),
        hasLength(expectedDisplayOmissions),
      );
    }

    const twoTurnBudget = acp.AcpInputBudget(
      maxMessageTextBytes: 1,
      maxThoughtTextBytes: 1,
      maxMarkdownFallbackBytes: 1,
    );

    test(
      'replay user messages begin new text and thought turn budgets',
      () async {
        final controller = ChatController(
          client: FakeAgentClient(resumeEvents: twoTurnEvents()),
          cwd: '/workspace',
          inputBudget: twoTurnBudget,
        );
        addTearDown(controller.dispose);

        await controller.resumeSession('two-turn-replay');

        expectTwoTurns(controller, expectedDisplayOmissions: 2);
      },
    );

    test('new session initial user messages begin new turn budgets', () async {
      final controller = ChatController(
        client: FakeAgentClient(createSessionEvents: twoTurnEvents()),
        cwd: '/workspace',
        inputBudget: twoTurnBudget,
      );
      addTearDown(controller.dispose);

      await controller.newSession();

      expectTwoTurns(controller, expectedDisplayOmissions: 2);
    });

    test('fork initial user messages begin new turn budgets', () async {
      final controller = ChatController(
        client: FakeAgentClient(forkSessionEvents: twoTurnEvents()),
        cwd: '/workspace',
        inputBudget: twoTurnBudget,
      );
      addTearDown(controller.dispose);
      await controller.newSession();

      await controller.forkCurrentSession();

      expectTwoTurns(controller, expectedDisplayOmissions: 2);
    });

    test(
      'live echoed user message finishes old turn before observation',
      () async {
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: twoTurnBudget,
        );
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('go');
        final observedAssistantText = <String>[];
        controller.addAgentEventObserver((_, event) {
          if (event.type == AgentEventType.userMessage) {
            observedAssistantText.add(
              controller.messages
                  .where((message) => message.role == ChatMessageRole.assistant)
                  .last
                  .text,
            );
          }
        });
        var notifications = 0;
        controller.addListener(() => notifications += 1);

        fake.emit(
          const AgentEvent(type: AgentEventType.agentTextDelta, text: 'a'),
        );
        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: 'x',
            metadata: <String, Object?>{'kind': 'thought'},
          ),
        );
        fake.emit(
          const AgentEvent(type: AgentEventType.userMessage, text: 'echo'),
        );
        fake.emit(
          const AgentEvent(type: AgentEventType.agentTextDelta, text: 'b'),
        );
        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: 'y',
            metadata: <String, Object?>{'kind': 'thought'},
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(observedAssistantText, ['a']);
        expect(notifications, 3);
        expectTwoTurns(controller, expectedDisplayOmissions: 1);
      },
    );
  });

  group('ChatController streaming notifications', () {
    Future<
      ({
        ChatController controller,
        _ControlledPromptAgentClient fake,
        List<AgentEvent> observed,
      })
    >
    configController({
      acp.AcpInputBudget budget = const acp.AcpInputBudget(),
    }) async {
      final fake = _ControlledPromptAgentClient();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        inputBudget: budget,
      );
      await controller.newSession();
      await controller.sendPrompt('update config');
      final observed = <AgentEvent>[];
      controller.addAgentEventObserver((_, event) => observed.add(event));
      return (controller: controller, fake: fake, observed: observed);
    }

    AgentEvent typedConfigEvent(
      List<Object?> options, {
      List<acp.AcpInputOmission> omissions = const <acp.AcpInputOmission>[],
    }) {
      return AgentEvent(
        type: AgentEventType.status,
        text: 'config updated',
        metadata: <String, Object?>{
          'kind': 'config_option_update',
          'configOptions': options,
        },
        omissions: omissions,
      );
    }

    test(
      'recognized typed config limit clears old cache without payload',
      () async {
        const canary = 'TYPED_CONFIG_LIMIT_CANARY_MUST_NOT_APPEAR';
        final state = await configController(
          budget: const acp.AcpInputBudget(maxStructuredStringBytes: 16),
        );
        addTearDown(state.controller.dispose);
        expect(state.controller.sessionSettings.configOptions, isNotEmpty);

        state.fake.emit(
          typedConfigEvent(<Object?>[
            const AcpConfigOption(
              id: canary,
              name: 'name',
              type: 'type',
              currentValue: 'value',
              options: <AcpConfigOptionChoice>[],
            ),
          ]),
        );

        expect(state.controller.sessionSettings.configOptions, isEmpty);
        expect(state.observed.single.metadata['kind'], 'config_option_update');
        expect(state.observed.single.metadata['configOptions'], isEmpty);
        expect(
          state.observed.single.omissions.single.reason,
          acp.AcpInputOmissionReason.inputLimit,
        );
        expect(
          <Object?>[
            state.controller.lastError,
            ...state.controller.messages.map((message) => message.text),
            ...state.observed.single.omissions.map((item) => item.toString()),
          ].join(' '),
          isNot(contains(canary)),
        );
      },
    );

    test(
      'recognized typed config invalid item clears without partial prefix',
      () async {
        final state = await configController();
        addTearDown(state.controller.dispose);
        expect(state.controller.sessionSettings.configOptions, isNotEmpty);

        state.fake.emit(
          typedConfigEvent(<Object?>[
            const AcpConfigOption(
              id: 'valid',
              name: 'Valid',
              type: 'select',
              currentValue: 'on',
              options: <AcpConfigOptionChoice>[],
            ),
            42,
          ]),
        );

        expect(state.controller.sessionSettings.configOptions, isEmpty);
        expect(state.observed.single.metadata['kind'], 'config_option_update');
        expect(state.observed.single.metadata['configOptions'], isEmpty);
        expect(
          state.observed.single.omissions.single.reason,
          acp.AcpInputOmissionReason.invalidStructure,
        );
      },
    );

    test(
      'trusted omission may fill cap while empty config carrier still clears',
      () async {
        final trusted = acp.AcpInputOmission(
          reason: acp.AcpInputOmissionReason.inputLimit,
          resource: 'trusted config omission',
          truncated: false,
          limit: 1,
          observedAtLeast: 2,
        );
        final state = await configController(
          budget: const acp.AcpInputBudget(maxCollectionItems: 1),
        );
        addTearDown(state.controller.dispose);
        expect(state.controller.sessionSettings.configOptions, isNotEmpty);

        state.fake.emit(
          typedConfigEvent(
            <Object?>[42],
            omissions: <acp.AcpInputOmission>[trusted],
          ),
        );

        expect(state.controller.sessionSettings.configOptions, isEmpty);
        expect(state.observed.single.metadata['kind'], 'config_option_update');
        expect(state.observed.single.metadata['configOptions'], isEmpty);
        expect(state.observed.single.omissions, hasLength(1));
        expect(
          state.observed.single.omissions.single.resource,
          'trusted config omission',
        );
      },
    );

    test(
      'stateful typed metadata is read once and cannot evade fail-close',
      () async {
        const canary = 'STATEFUL_TYPED_MAP_CANARY_MUST_NOT_APPEAR';
        final state = await configController(
          budget: const acp.AcpInputBudget(maxStructuredStringBytes: 16),
        );
        addTearDown(state.controller.dispose);
        final metadata = _StatefulTypedConfigMetadataMap(canary);

        state.fake.emit(
          AgentEvent(
            type: AgentEventType.status,
            text: 'config updated',
            metadata: metadata,
          ),
        );

        expect(metadata.entriesReads, 1);
        expect(state.controller.sessionSettings.configOptions, isEmpty);
        expect(state.observed.single.metadata['kind'], 'config_option_update');
        expect(state.observed.single.metadata['configOptions'], isEmpty);
        expect(
          <Object?>[
            ...state.observed.single.omissions.map((item) => item.toString()),
            state.controller.lastError,
          ].join(' '),
          isNot(contains(canary)),
        );
      },
    );

    test(
      'recognized stateful options fail closed without partial config',
      () async {
        final state = await configController();
        addTearDown(state.controller.dispose);
        final options = _StatefulConfigOptionsList();

        state.fake.emit(typedConfigEvent(options));

        expect(state.controller.sessionSettings.configOptions, isEmpty);
        expect(state.observed.single.metadata['kind'], 'config_option_update');
        expect(state.observed.single.metadata['configOptions'], isEmpty);
        expect(
          state.observed.single.omissions.single.reason,
          acp.AcpInputOmissionReason.invalidStructure,
        );
        expect(options.lengthReads, greaterThan(0));
        expect(options.indexReads, greaterThan(0));
      },
    );

    test('disposed controller does not access late hostile metadata', () async {
      final fake = _LateEventAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      await controller.newSession();
      await controller.sendPrompt('go');
      var observed = 0;
      controller.addAgentEventObserver((_, _) => observed += 1);
      final metadata = _CountingThrowingMetadataMap();

      controller.dispose();
      fake.emit(
        AgentEvent(
          type: AgentEventType.status,
          text: 'late',
          metadata: metadata,
        ),
      );
      await controller.disposalComplete;

      expect(metadata.accesses, 0);
      expect(observed, 0);
      expect(
        controller.messages.where((message) => message.text == 'late'),
        isEmpty,
      );
    });

    test(
      'raw hostile metadata is guarded before kind reads or observers',
      () async {
        const canary = 'RAW_EVENT_METADATA_CANARY_MUST_NOT_APPEAR';
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('go');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        expect(
          () => fake.emit(
            AgentEvent(
              type: AgentEventType.status,
              text: 'safe status',
              metadata: _ThrowingMetadataMap(canary),
            ),
          ),
          returnsNormally,
        );

        expect(observed, hasLength(1));
        expect(observed.single.metadata, isEmpty);
        expect(observed.single.omissions, hasLength(1));
        expect(
          observed.single.omissions.single.reason,
          acp.AcpInputOmissionReason.invalidStructure,
        );
        final visible = <Object?>[
          controller.lastError,
          ...controller.messages.map((message) => message.text),
          ...observed.single.omissions.map((item) => item.toString()),
        ].join(' ');
        expect(visible, isNot(contains(canary)));
      },
    );

    test(
      'text and thought chunks coalesce until a synchronous boundary',
      () async {
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('go');

        var notifications = 0;
        final snapshots = <List<String>>[];
        controller.addListener(() {
          notifications += 1;
          snapshots.add(
            controller.messages
                .map((message) => '${message.role.name}:${message.text}')
                .toList(),
          );
        });

        fake.emit(
          const AgentEvent(type: AgentEventType.agentTextDelta, text: 'a'),
        );
        fake.emit(
          const AgentEvent(type: AgentEventType.agentTextDelta, text: 'b'),
        );
        expect(notifications, 0);
        final assistant = controller.messages.last;

        fake.emit(
          const AgentEvent(
            type: AgentEventType.toolCall,
            text: 'tool boundary',
          ),
        );
        expect(notifications, 2);
        expect(snapshots.first.last, 'assistant:ab');
        expect(snapshots.last.last, 'tool:tool boundary');
        expect(assistant.materializationCount, 1);

        notifications = 0;
        snapshots.clear();
        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: 'x',
            metadata: <String, Object?>{'kind': 'thought'},
          ),
        );
        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: 'y',
            metadata: <String, Object?>{'kind': 'thought'},
          ),
        );
        expect(notifications, 0);

        await Future<void>.delayed(Duration.zero);

        expect(notifications, 1);
        expect(snapshots.single.last, 'status:xy');

        notifications = 0;
        snapshots.clear();
        fake.emit(
          const AgentEvent(type: AgentEventType.agentTextDelta, text: 'tail'),
        );
        fake.emit(
          const AgentEvent(type: AgentEventType.agentTextDone, text: ''),
        );
        expect(notifications, 2);
      },
    );

    test(
      'dispose suppresses an already scheduled streaming notification',
      () async {
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        await controller.newSession();
        await controller.sendPrompt('go');
        var notifications = 0;
        controller.addListener(() => notifications += 1);

        fake.emit(
          const AgentEvent(type: AgentEventType.agentTextDelta, text: 'a'),
        );
        expect(notifications, 0);
        controller.dispose();
        await Future<void>.delayed(Duration.zero);

        expect(notifications, 0);
      },
    );

    test(
      'tool boundary materializes pending text without a listener',
      () async {
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('go');

        fake.emit(
          const AgentEvent(type: AgentEventType.agentTextDelta, text: 'a'),
        );
        final target = controller.messages.last;
        expect(target.materializationCount, 0);

        fake.emit(
          const AgentEvent(
            type: AgentEventType.toolCall,
            text: 'tool boundary',
          ),
        );

        expect(target.materializationCount, 1);
      },
    );

    test('stream onDone consumes a pending delta notification once', () async {
      final fake = _ControlledPromptAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      await controller.newSession();
      await controller.sendPrompt('go');
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      fake.emit(
        const AgentEvent(type: AgentEventType.agentTextDelta, text: 'tail'),
      );
      expect(notifications, 0);
      await fake.finishPrompt();
      expect(notifications, 1);

      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);
      expect(controller.messages.last.text, 'tail');
    });

    test('drained empty chunks do not schedule notifications', () async {
      final fake = _ControlledPromptAgentClient();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        inputBudget: const acp.AcpInputBudget(
          maxMessageTextBytes: 1,
          maxMarkdownFallbackBytes: 1,
        ),
      );
      addTearDown(controller.dispose);
      await controller.newSession();
      await controller.sendPrompt('go');
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      fake.emit(
        const AgentEvent(type: AgentEventType.agentTextDelta, text: 'a'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);

      fake.emit(
        const AgentEvent(type: AgentEventType.agentTextDelta, text: 'b'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 2);

      fake.emit(
        const AgentEvent(type: AgentEventType.agentTextDelta, text: 'c'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 2);
    });

    test(
      'disposing during boundary flush stops observer and boundary mutation',
      () async {
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        await controller.newSession();
        await controller.sendPrompt('go');
        var observedTools = 0;
        controller.addAgentEventObserver((_, event) {
          if (event.type == AgentEventType.toolCall) observedTools += 1;
        });
        controller.addListener(controller.dispose);

        fake.emit(
          const AgentEvent(type: AgentEventType.agentTextDelta, text: 'tail'),
        );
        final messageCountBeforeBoundary = controller.messages.length;
        fake.emit(
          const AgentEvent(type: AgentEventType.toolCall, text: 'must not add'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(observedTools, 0);
        expect(controller.messages, hasLength(messageCountBeforeBoundary));
        expect(
          controller.messages.where(
            (message) => message.role == ChatMessageRole.tool,
          ),
          isEmpty,
        );
        await controller.disposalComplete;
      },
    );
  });

  group('ChatController turn root ledger', () {
    test('ordinary events cannot consume the reserved overflow item', () async {
      const canary = 'SECRET_TURN_ITEM_CANARY';
      final fake = _ControlledPromptAgentClient();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        inputBudget: const acp.AcpInputBudget(maxTurnItems: 2),
      );
      addTearDown(controller.dispose);
      await controller.newSession();
      await controller.sendPrompt('u');
      final dynamic debug = controller;

      expect(debug.debugCurrentTurnItems, 1);

      fake.emit(
        const AgentEvent(type: AgentEventType.agentTextDelta, text: canary),
      );
      await Future<void>.delayed(Duration.zero);

      expect(debug.debugCurrentTurnItems, 1);
      expect(debug.debugTurnOverflowed, isTrue);
      expect(debug.debugTurnTextCounterTouched, isFalse);
      expect(
        controller.messages.map((message) => message.text).join(),
        isNot(contains(canary)),
      );
      final overflowOmissions = controller.messages
          .expand((message) => message.omissions)
          .where((omission) => omission.resource == 'turn items');
      expect(overflowOmissions, hasLength(1));

      await fake.finishPrompt();
      expect(debug.debugCurrentTurnItems, 0);
      expect(debug.debugCurrentTurnRetainedBytes, 0);
      expect(debug.debugTurnOverflowed, isFalse);
    });

    test('ordinary item capacity admits exact and rejects plus one', () async {
      const canary = 'SECRET_ORDINARY_ITEM_PLUS_ONE';
      final fake = _ControlledPromptAgentClient();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        inputBudget: const acp.AcpInputBudget(maxTurnItems: 3),
      );
      addTearDown(controller.dispose);
      await controller.newSession();
      await controller.sendPrompt('u');
      final dynamic debug = controller;

      fake.emit(const AgentEvent(type: AgentEventType.toolCall, text: 'exact'));
      expect(debug.debugCurrentTurnItems, 2);
      fake.emit(const AgentEvent(type: AgentEventType.status, text: canary));

      expect(debug.debugCurrentTurnItems, 2);
      expect(debug.debugCurrentTurnItems, lessThanOrEqualTo(3));
      expect(
        controller.messages.map((message) => message.text).join(),
        isNot(contains(canary)),
      );
      expect(
        controller.messages
            .expand((message) => message.omissions)
            .where((omission) => omission.resource == 'turn items'),
        hasLength(1),
      );
    });

    test(
      'agent observers receive only the root-admitted text projection',
      () async {
        const canary = 'SECRET_REJECTED_OBSERVER_CANARY';
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(maxTurnItems: 2),
        );
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          const AgentEvent(
            type: AgentEventType.agentTextDelta,
            text: canary,
            metadata: <String, Object?>{'safe': 'metadata'},
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(observed, hasLength(1));
        expect(observed.single.text, isEmpty);
        expect(observed.single.metadata, isEmpty);
        expect(observed.single.toString(), isNot(contains(canary)));
        expect(
          observed.single.omissions.where(
            (omission) => omission.resource == 'turn items',
          ),
          hasLength(1),
        );
      },
    );

    test('agent observers receive only the accepted text prefix', () async {
      const canary = 'SECRET_TEXT_SUFFIX_CANARY';
      final fake = _ControlledPromptAgentClient();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        inputBudget: const acp.AcpInputBudget(
          maxMessageTextBytes: 3,
          maxMarkdownFallbackBytes: 3,
        ),
      );
      addTearDown(controller.dispose);
      await controller.newSession();
      await controller.sendPrompt('u');
      final observed = <AgentEvent>[];
      controller.addAgentEventObserver((_, event) => observed.add(event));

      fake.emit(
        const AgentEvent(
          type: AgentEventType.agentTextDelta,
          text: 'abc$canary',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(observed.single.text, 'abc');
      expect(observed.single.text, isNot(contains(canary)));
      expect(
        observed.single.omissions.where(
          (omission) => omission.resource == 'message text',
        ),
        hasLength(1),
      );
    });

    test(
      'error text budget bounds message lastError and observer together',
      () async {
        const canary = 'SECRET_ERROR_SUFFIX_CANARY';
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(
            maxMessageTextBytes: 4,
            maxMarkdownFallbackBytes: 4,
          ),
        );
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          const AgentEvent(type: AgentEventType.error, text: 'safe$canary'),
        );

        final error = controller.messages.singleWhere(
          (message) => message.role == ChatMessageRole.error,
        );
        expect(error.text, 'safe');
        expect(controller.lastError, 'safe');
        expect(observed.single.text, 'safe');
        expect(
          <Object?>[
            error.text,
            controller.lastError,
            observed.single.text,
          ].join(),
          isNot(contains(canary)),
        );
        expect(
          error.omissions.where(
            (omission) => omission.resource == 'error text',
          ),
          hasLength(1),
        );
      },
    );

    test('live user media starts a fresh aggregate before scanning', () async {
      final fake = _ControlledPromptAgentClient();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        inputBudget: const acp.AcpInputBudget(maxEmbeddedMediaBytes: 1),
      );
      addTearDown(controller.dispose);
      await controller.newSession();
      await controller.sendPrompt('u');

      AgentEvent mediaUser(String data) => AgentEvent(
        type: AgentEventType.userMessage,
        text: 'replay',
        metadata: <String, Object?>{
          'contentBlocks': <Object?>[
            <String, Object?>{'type': 'image', 'data': data},
          ],
        },
      );

      fake.emit(mediaUser('YQ=='));
      fake.emit(mediaUser('Yg=='));

      final retained = controller.messages
          .map((message) => message.metadata)
          .toList(growable: false)
          .toString();
      expect(retained, contains('YQ=='));
      expect(retained, contains('Yg=='));
      expect(
        controller.messages
            .expand((message) => message.omissions)
            .where((omission) => omission.resource == 'turn_media'),
        isEmpty,
      );
    });

    test(
      'streaming text uses normal retained bytes but not the reserve',
      () async {
        const canary = 'SECRET_TURN_RETAINED_CANARY';
        final userRetained = ChatMessage(
          role: ChatMessageRole.user,
          text: 'u',
        ).retainedBytes;
        final emptyAssistantRetained = ChatMessage(
          role: ChatMessageRole.assistant,
          text: '',
        ).retainedBytes;
        final maxTurnRetainedBytes =
            userRetained + emptyAssistantRetained + 4 + 1024;
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: acp.AcpInputBudget(
            maxTurnRetainedBytes: maxTurnRetainedBytes,
          ),
        );
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');

        fake.emit(
          const AgentEvent(type: AgentEventType.agentTextDelta, text: 'abcd'),
        );
        final normalExact = userRetained + emptyAssistantRetained + 4;
        final dynamic debug = controller;
        expect(debug.debugCurrentTurnRetainedBytes, normalExact);
        fake.emit(
          const AgentEvent(type: AgentEventType.agentTextDelta, text: 'e'),
        );
        final afterOverflow = debug.debugCurrentTurnRetainedBytes as int;
        expect(afterOverflow, greaterThan(normalExact));
        expect(
          afterOverflow,
          controller.messages.fold<int>(
            0,
            (total, message) => total + message.retainedBytes,
          ),
        );
        expect(afterOverflow, lessThanOrEqualTo(maxTurnRetainedBytes));
        fake.emit(
          const AgentEvent(type: AgentEventType.agentTextDelta, text: canary),
        );
        await Future<void>.delayed(Duration.zero);

        final assistant = controller.messages.singleWhere(
          (message) => message.role == ChatMessageRole.assistant,
        );
        expect(assistant.text, 'abcd');
        expect(
          controller.messages.map((message) => message.text).join(),
          isNot(contains(canary)),
        );
        expect(
          controller.messages
              .expand((message) => message.omissions)
              .where((omission) => omission.resource == 'turn retained bytes'),
          hasLength(1),
        );
        expect(debug.debugCurrentTurnRetainedBytes, afterOverflow);
        expect(debug.debugTurnOverflowed, isTrue);
      },
    );

    test(
      'same tool id replacement updates bytes without consuming an item',
      () async {
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        final dynamic debug = controller;

        fake.emit(
          const AgentEvent(
            type: AgentEventType.toolCall,
            text: 'a',
            metadata: <String, Object?>{'toolCallId': 'same-tool'},
          ),
        );
        final firstBytes = debug.debugCurrentTurnRetainedBytes as int;
        expect(debug.debugCurrentTurnItems, 2);

        fake.emit(
          const AgentEvent(
            type: AgentEventType.toolCall,
            text: 'a longer safe value',
            metadata: <String, Object?>{'toolCallId': 'same-tool'},
          ),
        );

        expect(debug.debugCurrentTurnItems, 2);
        expect(debug.debugCurrentTurnRetainedBytes, greaterThan(firstBytes));
        expect(
          controller.messages.where(
            (message) => message.role == ChatMessageRole.tool,
          ),
          hasLength(1),
        );
        expect(
          controller.messages
              .singleWhere((message) => message.role == ChatMessageRole.tool)
              .text,
          'a longer safe value',
        );
      },
    );

    test(
      'rejected tool replacement keeps old safe state and observer projection',
      () async {
        const canary = 'SECRET_REJECTED_TOOL_UPDATE_CANARY';
        const metadata = <String, Object?>{'toolCallId': 'bounded-tool'};
        final userRetained = ChatMessage(
          role: ChatMessageRole.user,
          text: 'u',
        ).retainedBytes;
        final toolRetained = ChatMessage(
          role: ChatMessageRole.tool,
          text: 'safe',
          metadata: metadata,
        ).retainedBytes;
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: acp.AcpInputBudget(
            maxTurnRetainedBytes: userRetained + toolRetained + 1024,
          ),
        );
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          const AgentEvent(
            type: AgentEventType.toolCall,
            text: 'safe',
            metadata: metadata,
          ),
        );
        fake.emit(
          const AgentEvent(
            type: AgentEventType.toolCall,
            text: 'safe$canary',
            metadata: metadata,
          ),
        );

        final tool = controller.messages.singleWhere(
          (message) => message.role == ChatMessageRole.tool,
        );
        expect(tool.text, 'safe');
        expect(observed, hasLength(2));
        expect(observed.first.text, 'safe');
        expect(observed.last.text, isEmpty);
        expect(observed.last.metadata, isEmpty);
        expect(observed.last.text, isNot(contains(canary)));
        expect(
          observed.last.omissions.where(
            (omission) => omission.resource == 'turn retained bytes',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'rejected status replacement keeps old safe state and observer projection',
      () async {
        const canary = 'SECRET_REJECTED_STATUS_UPDATE_CANARY';
        const metadata = <String, Object?>{
          'kind': 'plan',
          'id': 'bounded-plan',
        };
        final userRetained = ChatMessage(
          role: ChatMessageRole.user,
          text: 'u',
        ).retainedBytes;
        final statusRetained = ChatMessage(
          role: ChatMessageRole.status,
          text: 'safe',
          metadata: metadata,
        ).retainedBytes;
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: acp.AcpInputBudget(
            maxTurnRetainedBytes: userRetained + statusRetained + 1024,
          ),
        );
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: 'safe',
            metadata: metadata,
          ),
        );
        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: 'safe$canary',
            metadata: metadata,
          ),
        );

        final plan = controller.messages.singleWhere(
          (message) => message.metadata['kind'] == 'plan',
        );
        expect(plan.text, 'safe');
        expect(observed, hasLength(2));
        expect(observed.first.text, 'safe');
        expect(observed.last.text, isEmpty);
        expect(observed.last.metadata, isEmpty);
        expect(observed.last.text, isNot(contains(canary)));
      },
    );

    test(
      'non-streaming display events retain and observe only their safe prefix',
      () async {
        const canary = 'SECRET_NON_STREAMING_DISPLAY_CANARY';
        final cases = <({AgentEvent event, String expected})>[
          (
            event: const AgentEvent(
              type: AgentEventType.userMessage,
              text: 'safe$canary',
            ),
            expected: 'safe',
          ),
          (
            event: const AgentEvent(
              type: AgentEventType.toolCall,
              text: 'safe$canary',
            ),
            expected: 'safe',
          ),
          (
            event: const AgentEvent(
              type: AgentEventType.status,
              text: '你a$canary',
            ),
            expected: '你a',
          ),
          (
            event: const AgentEvent(
              type: AgentEventType.status,
              text: 'safe$canary',
              metadata: <String, Object?>{
                'kind': 'terminal',
                'terminalId': 'bounded',
              },
            ),
            expected: 'safe',
          ),
          (
            event: const AgentEvent(
              type: AgentEventType.status,
              text: 'safe$canary',
              metadata: <String, Object?>{'kind': 'plan'},
            ),
            expected: 'safe',
          ),
          (
            event: const AgentEvent(
              type: AgentEventType.status,
              text: 'safe$canary',
              metadata: <String, Object?>{'kind': 'diff'},
            ),
            expected: 'safe',
          ),
        ];

        for (final testCase in cases) {
          final fake = _ControlledPromptAgentClient();
          final controller = ChatController(
            client: fake,
            cwd: '/workspace',
            inputBudget: const acp.AcpInputBudget(
              maxMessageTextBytes: 4,
              maxMarkdownFallbackBytes: 4,
            ),
          );
          await controller.newSession();
          await controller.sendPrompt('u');
          final observed = <AgentEvent>[];
          controller.addAgentEventObserver((_, event) => observed.add(event));

          fake.emit(testCase.event);

          final retained = controller.messages.last;
          expect(retained.text, testCase.expected);
          expect(observed.single.text, testCase.expected);
          expect(retained.text, isNot(contains(canary)));
          expect(observed.single.text, isNot(contains(canary)));
          expect(
            retained.omissions.where(
              (omission) => omission.resource == 'display text',
            ),
            hasLength(1),
          );
          final dynamic debug = controller;
          expect(
            debug.debugCurrentTurnRetainedBytes,
            testCase.event.type == AgentEventType.userMessage
                ? retained.retainedBytes
                : controller.messages.fold<int>(
                    0,
                    (total, message) => total + message.retainedBytes,
                  ),
          );
          controller.dispose();
          await controller.disposalComplete;
        }
      },
    );

    test('non-streaming display text counts CR LF and CRLF exactly', () async {
      const canary = 'SECRET_DISPLAY_LINE_CANARY';
      for (final separator in const <String>['\r', '\n', '\r\n']) {
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(
            maxMessageTextBytes: 128,
            maxMessageTextLines: 2,
            maxMarkdownFallbackBytes: 128,
          ),
        );
        await controller.newSession();
        await controller.sendPrompt('u');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          AgentEvent(
            type: AgentEventType.status,
            text: 'a${separator}b$separator$canary',
          ),
        );

        expect(controller.messages.last.text, 'a${separator}b');
        expect(observed.single.text, 'a${separator}b');
        expect(observed.single.text, isNot(contains(canary)));
        controller.dispose();
        await controller.disposalComplete;
      }
    });

    test('plan diff commands and settings consume turn items', () async {
      final fake = _ControlledPromptAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      await controller.newSession();
      await controller.sendPrompt('u');
      final dynamic debug = controller;

      fake.emit(
        const AgentEvent(
          type: AgentEventType.status,
          text: 'plan',
          metadata: <String, Object?>{'kind': 'plan', 'title': 'plan'},
        ),
      );
      expect(debug.debugCurrentTurnItems, 2);
      final planBytes = debug.debugCurrentTurnRetainedBytes as int;

      fake.emit(
        const AgentEvent(
          type: AgentEventType.status,
          text: 'diff',
          metadata: <String, Object?>{'kind': 'diff', 'id': 'd'},
        ),
      );
      expect(debug.debugCurrentTurnItems, 3);
      expect(debug.debugCurrentTurnRetainedBytes, greaterThan(planBytes));

      fake.emit(
        const AgentEvent(
          type: AgentEventType.status,
          text: 'commands',
          metadata: <String, Object?>{
            'kind': 'commands',
            'commands': <Object?>[
              <String, Object?>{'name': 'review'},
            ],
          },
        ),
      );
      expect(debug.debugCurrentTurnItems, 5);
      expect(controller.availableCommands.single['name'], 'review');

      fake.emit(
        const AgentEvent(
          type: AgentEventType.status,
          text: 'settings',
          metadata: <String, Object?>{
            'kind': 'config_option_update',
            'configOptions': <AcpConfigOption>[
              AcpConfigOption(
                id: 'mode',
                name: 'Mode',
                type: 'select',
                currentValue: 'safe',
                options: <AcpConfigOptionChoice>[],
              ),
            ],
          },
        ),
      );
      expect(debug.debugCurrentTurnItems, 7);
      expect(controller.sessionSettings.configOptions.single.id, 'mode');
    });

    test(
      'usage and session info updates replace their root state item',
      () async {
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        final dynamic debug = controller;

        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: '',
            metadata: <String, Object?>{
              'kind': 'usage_update',
              'used': 1,
              'size': 10,
            },
          ),
        );
        expect(debug.debugCurrentTurnItems, 2);
        final firstUsageBytes = debug.debugCurrentTurnRetainedBytes as int;
        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: '',
            metadata: <String, Object?>{
              'kind': 'usage_update',
              'used': 2,
              'size': 10,
            },
          ),
        );
        expect(debug.debugCurrentTurnItems, 2);
        expect(debug.debugCurrentTurnRetainedBytes, firstUsageBytes);
        expect(controller.sessionUsage?.used, 2);

        fake.emit(
          AgentEvent(
            type: AgentEventType.status,
            text: '',
            metadata: <String, Object?>{
              'kind': 'session_info_update',
              'sessionId': controller.currentSession!.id,
              'title': 'one',
            },
          ),
        );
        expect(debug.debugCurrentTurnItems, 3);
        fake.emit(
          AgentEvent(
            type: AgentEventType.status,
            text: '',
            metadata: <String, Object?>{
              'kind': 'session_info_update',
              'sessionId': controller.currentSession!.id,
              'title': 'two',
            },
          ),
        );
        expect(debug.debugCurrentTurnItems, 3);
        expect(controller.currentSession?.title, 'two');
      },
    );

    test(
      'usage retained overflow preserves old safe state and observer projection',
      () async {
        const canary = 'SECRET_USAGE_COST_CANARY';
        AgentEvent usage({String? currency}) => AgentEvent(
          type: AgentEventType.status,
          text: 'usage',
          metadata: <String, Object?>{
            'kind': 'usage_update',
            'used': 1,
            'size': 10,
            if (currency != null)
              'cost': <String, Object?>{'amount': 1, 'currency': currency},
          },
        );

        final measuringFake = _ControlledPromptAgentClient();
        final measuring = ChatController(
          client: measuringFake,
          cwd: '/workspace',
        );
        await measuring.newSession();
        await measuring.sendPrompt('u');
        measuringFake.emit(usage());
        final dynamic measuringDebug = measuring;
        final exactRetained =
            measuringDebug.debugCurrentTurnRetainedBytes as int;
        measuring.dispose();
        await measuring.disposalComplete;

        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: acp.AcpInputBudget(
            maxTurnRetainedBytes: exactRetained + 1024,
          ),
        );
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(usage());
        fake.emit(usage(currency: canary));

        expect(controller.sessionUsage?.cost, isNull);
        expect(observed, hasLength(2));
        expect(observed.last.text, isEmpty);
        expect(observed.last.metadata, isEmpty);
        expect(observed.last.toString(), isNot(contains(canary)));
        expect(
          observed.last.omissions.where(
            (omission) => omission.resource == 'turn retained bytes',
          ),
          hasLength(1),
        );
      },
    );

    test('invalid usage cost is atomic finite and payload-free', () async {
      const canary = 'SECRET_INVALID_USAGE_COST';
      final invalidCosts = <Object?>[
        <String, Object?>{
          'amount': 1,
          'currency': <String, Object?>{'secret': canary},
        },
        <String, Object?>{
          'amount': 1,
          'currency': <Object?>[canary],
        },
        const <String, Object?>{'amount': 'NaN', 'currency': 'USD'},
        const <String, Object?>{'amount': 'Infinity', 'currency': 'USD'},
        const <String, Object?>{'amount': double.nan, 'currency': 'USD'},
        const <String, Object?>{'amount': double.infinity, 'currency': 'USD'},
      ];

      Future<void> verify(Object? cost, {required bool markerFits}) async {
        final amount = cost is Map<String, Object?> ? cost['amount'] : null;
        final metadataGuardRejects = amount is num && !amount.isFinite;
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: acp.AcpInputBudget(maxTurnItems: markerFits ? 512 : 2),
        );
        await controller.newSession();
        await controller.sendPrompt('u');
        controller.sessionUsage = const AcpSessionUsage(used: 2, size: 10);
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        expect(
          () => fake.emit(
            AgentEvent(
              type: AgentEventType.status,
              text: canary,
              metadata: <String, Object?>{
                'kind': 'usage_update',
                'used': 3,
                'size': 10,
                'cost': cost,
              },
            ),
          ),
          returnsNormally,
        );

        expect(controller.sessionUsage?.used, 2);
        expect(controller.sessionUsage?.cost, isNull);
        expect(
          controller.messages
              .map((message) => <Object?>[message.text, message.metadata])
              .toString(),
          isNot(contains(canary)),
        );
        expect(observed.single.text, isEmpty, reason: 'cost: $cost');
        expect(
          observed.single.metadata,
          metadataGuardRejects && markerFits
              ? const <String, Object?>{'kind': 'usage_update'}
              : isEmpty,
          reason: 'cost: $cost',
        );
        expect(observed.single.toString(), isNot(contains(canary)));
        expect(
          observed.single.omissions.where(
            (omission) =>
                omission.resource ==
                (markerFits
                    ? metadataGuardRejects
                          ? 'chat message metadata'
                          : 'usage cost'
                    : 'turn items'),
          ),
          hasLength(1),
        );
        controller.dispose();
        await controller.disposalComplete;
      }

      for (final cost in invalidCosts) {
        await verify(cost, markerFits: true);
      }
      await verify(invalidCosts.first, markerFits: false);
    });

    test(
      'usage cost guard owns nested carriers before strict inspection',
      () async {
        const canary = 'SECRET_THROWING_USAGE_COST_INDEX';
        final cost = _ThrowingIndexUsageCostMap(canary);
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        controller.sessionUsage = const AcpSessionUsage(used: 2, size: 10);
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        expect(
          () => fake.emit(
            AgentEvent(
              type: AgentEventType.status,
              text: canary,
              metadata: <String, Object?>{
                'kind': 'usage_update',
                'used': 3,
                'size': 10,
                'cost': cost,
              },
            ),
          ),
          returnsNormally,
        );

        expect(cost.indexReads, 0);
        expect(controller.sessionUsage?.used, 2);
        expect(controller.sessionUsage?.cost, isNull);
        expect(observed.single.text, isEmpty);
        expect(observed.single.metadata, isEmpty);
        expect(observed.single.toString(), isNot(contains(canary)));
        expect(
          observed.single.omissions.where(
            (omission) => omission.resource == 'usage cost',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'invalid usage values use a distinct payload-free diagnosis',
      () async {
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        controller.sessionUsage = const AcpSessionUsage(used: 2, size: 10);
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: 'invalid usage',
            metadata: <String, Object?>{
              'kind': 'usage_update',
              'used': 'invalid',
              'size': 10,
            },
          ),
        );

        expect(controller.sessionUsage?.used, 2);
        expect(observed.single.text, isEmpty);
        expect(observed.single.metadata, isEmpty);
        expect(
          observed.single.omissions.where(
            (omission) => omission.resource == 'usage values',
          ),
          hasLength(1),
        );
        expect(
          observed.single.omissions.where(
            (omission) => omission.resource == 'usage cost',
          ),
          isEmpty,
        );
      },
    );

    test(
      'usage and session info metadata guard failures stay specialized and payload-free',
      () async {
        const canary = 'SECRET_STATE_METADATA_GUARD_CANARY';

        Future<void> verify({
          required String kind,
          required acp.AcpInputBudget budget,
          required Map<String, Object?> metadata,
          required acp.AcpInputOmissionReason reason,
        }) async {
          final fake = _ControlledPromptAgentClient();
          final controller = ChatController(
            client: fake,
            cwd: '/workspace',
            inputBudget: budget,
          );
          await controller.newSession();
          await controller.sendPrompt('u');
          controller.sessionUsage = const AcpSessionUsage(used: 2, size: 10);
          controller.currentSession = controller.currentSession!.copyWith(
            title: 'old',
          );
          final observed = <AgentEvent>[];
          controller.addAgentEventObserver((_, event) => observed.add(event));

          expect(
            () => fake.emit(
              AgentEvent(
                type: AgentEventType.status,
                text: canary,
                metadata: metadata,
              ),
            ),
            returnsNormally,
          );

          expect(controller.sessionUsage?.used, 2);
          expect(controller.currentSession?.title, 'old');
          expect(
            controller.messages.map((message) => message.text).join(),
            isNot(contains(canary)),
          );
          expect(observed.single.text, isEmpty);
          expect(observed.single.metadata['kind'], kind);
          expect(observed.single.metadata.toString(), isNot(contains(canary)));
          expect(
            observed.single.omissions.where(
              (omission) => omission.reason == reason,
            ),
            hasLength(1),
          );
          controller.dispose();
          await controller.disposalComplete;
        }

        for (final kind in const <String>[
          'usage_update',
          'session_info_update',
        ]) {
          await verify(
            kind: kind,
            budget: const acp.AcpInputBudget(maxStructuredStringBytes: 16),
            metadata: <String, Object?>{'kind': kind, 'value': canary},
            reason: acp.AcpInputOmissionReason.inputLimit,
          );
          await verify(
            kind: kind,
            budget: const acp.AcpInputBudget(),
            metadata: <String, Object?>{
              'kind': kind,
              'value': _CanaryPayload(),
            },
            reason: acp.AcpInputOmissionReason.invalidStructure,
          );
        }
      },
    );

    test(
      'replacing a prior-turn status admits it into the current ledger',
      () async {
        final first = _ControlledPromptAgentClient();
        final controller = ChatController(client: first, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('first');
        first.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: 'old plan',
            metadata: <String, Object?>{'kind': 'plan'},
          ),
        );
        await first.finishPrompt();

        final second = _ControlledPromptAgentClient();
        final replacement = ChatController(client: second, cwd: '/workspace');
        addTearDown(replacement.dispose);
        replacement.currentSession = controller.currentSession;
        replacement.sessions.addAll(controller.sessions);
        for (final message in controller.messages) {
          replacement.addMessageForTesting(
            ChatMessage(
              role: message.role,
              text: message.text,
              timestamp: message.timestamp,
              metadata: message.metadata,
              omissions: message.omissions,
            ),
            startsNewTurn: message.role == ChatMessageRole.user,
          );
        }
        await replacement.sendPrompt('second');
        second.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: 'new plan',
            metadata: <String, Object?>{'kind': 'plan'},
          ),
        );

        expect(
          replacement.messages
              .singleWhere((message) => message.metadata['kind'] == 'plan')
              .text,
          'new plan',
        );
        final dynamic debug = replacement;
        expect(debug.debugCurrentTurnItems, 2);
      },
    );

    test(
      'hostile commands clear old state without retaining payload',
      () async {
        const smallCommands = AgentEvent(
          type: AgentEventType.status,
          text: 'commands',
          metadata: <String, Object?>{
            'kind': 'commands',
            'commands': <Object?>[
              <String, Object?>{'name': 'safe'},
            ],
          },
        );
        const canary = 'SECRET_COMMAND_ROOT_CANARY';
        final payload = _CanaryPayload();
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        fake.emit(smallCommands);
        expect(controller.availableCommands.single['name'], 'safe');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          AgentEvent(
            type: AgentEventType.status,
            text: canary,
            metadata: <String, Object?>{
              'kind': 'commands',
              'commands': <Object?>[
                <String, Object?>{'name': 'unsafe', 'payload': payload},
              ],
            },
          ),
        );

        expect(controller.availableCommands, isEmpty);
        expect(
          controller.messages
              .expand((message) => message.omissions)
              .where(
                (omission) =>
                    omission.resource == 'chat message metadata' &&
                    omission.reason ==
                        acp.AcpInputOmissionReason.invalidStructure,
              ),
          hasLength(1),
        );
        expect(
          controller.messages.map((message) => message.text).join(),
          isNot(contains(canary)),
        );
        expect(
          controller.messages.map((message) => message.metadata).toString(),
          isNot(contains(canary)),
        );
        expect(payload.toStringCalls, 0);
        expect(observed.single.text, isNot(contains(canary)));
        expect(observed.single.metadata.toString(), isNot(contains(canary)));
      },
    );

    test(
      'structurally invalid commands fail closed with a typed marker',
      () async {
        const canary = 'SECRET_INVALID_COMMAND_STRUCTURE';
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: canary,
            metadata: <String, Object?>{
              'kind': 'commands',
              'commands': <Object?>[
                <Object?>[canary],
              ],
            },
          ),
        );

        expect(controller.availableCommands, isEmpty);
        expect(observed.single.text, isEmpty);
        expect(observed.single.metadata, isEmpty);
        expect(observed.single.toString(), isNot(contains(canary)));
        expect(
          observed.single.omissions.where(
            (omission) => omission.resource == 'commands',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'invalid command and mode clears are never accepted as event payload',
      () async {
        const canary = 'SECRET_INVALID_CLEAR_PAYLOAD';

        Future<void> verify({
          required bool commands,
          required bool ledgerTracked,
        }) async {
          final fake = _ControlledPromptAgentClient();
          final controller = ChatController(
            client: fake,
            cwd: '/workspace',
            inputBudget: acp.AcpInputBudget(
              maxTurnItems: ledgerTracked ? 512 : 2,
            ),
          );
          await controller.newSession();
          await controller.sendPrompt('u');

          if (ledgerTracked) {
            fake.emit(
              commands
                  ? const AgentEvent(
                      type: AgentEventType.status,
                      text: 'old commands',
                      metadata: <String, Object?>{
                        'kind': 'commands',
                        'commands': <Object?>[
                          <String, Object?>{'name': 'old'},
                        ],
                      },
                    )
                  : const AgentEvent(
                      type: AgentEventType.status,
                      text: 'old mode',
                      metadata: <String, Object?>{
                        'kind': 'mode',
                        'mode': 'old',
                      },
                    ),
            );
          } else if (commands) {
            controller.availableCommands = const <Map<String, Object?>>[
              <String, Object?>{'name': 'old'},
            ];
          } else {
            controller.sessionSettings = const AcpSessionSettings(
              modes: AcpSessionModeInfo(currentModeId: 'old'),
            );
          }
          expect(
            commands
                ? controller.availableCommands
                : controller.sessionSettings.modes.currentModeId,
            isNot(isEmpty),
          );

          final observed = <AgentEvent>[];
          controller.addAgentEventObserver((_, event) => observed.add(event));
          fake.emit(
            commands
                ? const AgentEvent(
                    type: AgentEventType.status,
                    text: canary,
                    metadata: <String, Object?>{
                      'kind': 'commands',
                      'commands': <Object?>[
                        <Object?>[canary],
                      ],
                    },
                  )
                : const AgentEvent(
                    type: AgentEventType.status,
                    text: canary,
                    metadata: <String, Object?>{'kind': 'mode', 'mode': ''},
                  ),
          );

          expect(controller.availableCommands, isEmpty);
          expect(controller.sessionSettings.modes.currentModeId, isNull);
          expect(observed.single.text, isEmpty);
          expect(observed.single.metadata, isEmpty);
          expect(observed.single.toString(), isNot(contains(canary)));
          expect(
            observed.single.omissions.where(
              (omission) =>
                  omission.resource ==
                  (ledgerTracked
                      ? commands
                            ? 'commands'
                            : 'session mode'
                      : 'turn items'),
            ),
            hasLength(1),
          );
          controller.dispose();
          await controller.disposalComplete;
        }

        for (final commands in const <bool>[true, false]) {
          await verify(commands: commands, ledgerTracked: true);
          await verify(commands: commands, ledgerTracked: false);
        }
      },
    );

    test('invalid config clears are never accepted as event payload', () async {
      const canary = 'SECRET_INVALID_CONFIG_CLEAR_PAYLOAD';

      Future<void> verify(bool ledgerTracked) async {
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: acp.AcpInputBudget(
            maxTurnItems: ledgerTracked ? 512 : 2,
          ),
        );
        await controller.newSession();
        await controller.sendPrompt('u');
        const oldOption = AcpConfigOption(
          id: 'old',
          name: 'Old',
          type: 'select',
          currentValue: 'on',
          options: <AcpConfigOptionChoice>[],
        );
        if (ledgerTracked) {
          fake.emit(
            const AgentEvent(
              type: AgentEventType.status,
              text: 'old config',
              metadata: <String, Object?>{
                'kind': 'config_option_update',
                'configOptions': <AcpConfigOption>[oldOption],
              },
            ),
          );
        } else {
          controller.sessionSettings = const AcpSessionSettings(
            configOptions: <AcpConfigOption>[oldOption],
          );
        }
        expect(controller.sessionSettings.configOptions, isNotEmpty);

        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));
        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: canary,
            metadata: <String, Object?>{
              'kind': 'config_option_update',
              'configOptions': canary,
            },
          ),
        );

        expect(controller.sessionSettings.configOptions, isEmpty);
        expect(observed.single.text, isEmpty);
        expect(observed.single.metadata, isEmpty);
        expect(observed.single.toString(), isNot(contains(canary)));
        expect(
          observed.single.omissions.where(
            (omission) =>
                omission.resource ==
                (ledgerTracked ? 'config options' : 'turn items'),
          ),
          hasLength(1),
        );
        controller.dispose();
        await controller.disposalComplete;
      }

      await verify(true);
      await verify(false);
    });

    test(
      'commands rollback is payload-free whether the failure marker fits or not',
      () async {
        const canary = 'SECRET_COMMAND_ROLLBACK_CANARY';

        Future<void> verify(int maxTurnItems) async {
          final fake = _ControlledPromptAgentClient();
          final controller = ChatController(
            client: fake,
            cwd: '/workspace',
            inputBudget: acp.AcpInputBudget(maxTurnItems: maxTurnItems),
          );
          await controller.newSession();
          await controller.sendPrompt('u');
          final observed = <AgentEvent>[];
          controller.addAgentEventObserver((_, event) => observed.add(event));

          fake.emit(
            const AgentEvent(
              type: AgentEventType.status,
              text: canary,
              metadata: <String, Object?>{
                'kind': 'commands',
                'commands': <Object?>[
                  <String, Object?>{'name': canary},
                ],
              },
            ),
          );

          expect(controller.availableCommands, isEmpty);
          expect(observed.single.text, isEmpty);
          expect(observed.single.metadata, isEmpty);
          expect(observed.single.toString(), isNot(contains(canary)));
          expect(
            observed.single.omissions.where(
              (omission) => omission.resource == 'turn items',
            ),
            hasLength(1),
          );
          controller.dispose();
          await controller.disposalComplete;
        }

        await verify(3);
        await verify(2);
      },
    );

    test(
      'settings rollback is payload-free whether the failure marker fits or not',
      () async {
        const canary = 'SECRET_SETTINGS_ROLLBACK_CANARY';

        Future<void> verify(int maxTurnItems) async {
          final fake = _ControlledPromptAgentClient();
          final controller = ChatController(
            client: fake,
            cwd: '/workspace',
            inputBudget: acp.AcpInputBudget(maxTurnItems: maxTurnItems),
          );
          await controller.newSession();
          await controller.sendPrompt('u');
          final observed = <AgentEvent>[];
          controller.addAgentEventObserver((_, event) => observed.add(event));

          fake.emit(
            const AgentEvent(
              type: AgentEventType.status,
              text: canary,
              metadata: <String, Object?>{
                'kind': 'config_option_update',
                'configOptions': <AcpConfigOption>[
                  AcpConfigOption(
                    id: 'mode',
                    name: canary,
                    type: 'select',
                    currentValue: 'safe',
                    options: <AcpConfigOptionChoice>[],
                  ),
                ],
              },
            ),
          );

          expect(controller.sessionSettings.configOptions, isEmpty);
          expect(observed.single.text, isEmpty);
          expect(observed.single.metadata, isEmpty);
          expect(observed.single.toString(), isNot(contains(canary)));
          expect(
            observed.single.omissions.where(
              (omission) => omission.resource == 'turn items',
            ),
            hasLength(1),
          );
          controller.dispose();
          await controller.disposalComplete;
        }

        await verify(3);
        await verify(2);
      },
    );

    test(
      'unknown hostile behavior clears commands and settings without observation payload',
      () async {
        const canary = 'SECRET_UNKNOWN_BEHAVIOR_CANARY';
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        controller.availableCommands = const <Map<String, Object?>>[
          <String, Object?>{'name': 'old'},
        ];
        controller.sessionSettings = const AcpSessionSettings(
          configOptions: <AcpConfigOption>[
            AcpConfigOption(
              id: 'old',
              name: 'Old',
              type: 'select',
              currentValue: 'on',
              options: <AcpConfigOptionChoice>[],
            ),
          ],
        );
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          AgentEvent(
            type: AgentEventType.status,
            text: canary,
            metadata: _ThrowingMetadataMap(canary),
          ),
        );

        expect(controller.availableCommands, isEmpty);
        expect(controller.sessionSettings.configOptions, isEmpty);
        expect(observed.single.text, isEmpty);
        expect(observed.single.metadata, isEmpty);
        expect(observed.single.toString(), isNot(contains(canary)));
      },
    );

    test('hostile non-string kind never invokes equality', () async {
      const canary = 'SECRET_HOSTILE_KIND_EQUALITY';
      final hostileKind = _ThrowingEqualityValue();
      final fake = _ControlledPromptAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      await controller.newSession();
      await controller.sendPrompt('u');
      controller.availableCommands = const <Map<String, Object?>>[
        <String, Object?>{'name': 'old'},
      ];
      controller.sessionSettings = const AcpSessionSettings(
        configOptions: <AcpConfigOption>[
          AcpConfigOption(
            id: 'old',
            name: 'Old',
            type: 'select',
            currentValue: 'on',
            options: <AcpConfigOptionChoice>[],
          ),
        ],
      );
      final observed = <AgentEvent>[];
      controller.addAgentEventObserver((_, event) => observed.add(event));

      expect(
        () => fake.emit(
          AgentEvent(
            type: AgentEventType.status,
            text: canary,
            metadata: <String, Object?>{'kind': hostileKind, 'payload': canary},
          ),
        ),
        returnsNormally,
      );

      expect(hostileKind.equalityCalls, 0);
      expect(controller.availableCommands, isEmpty);
      expect(controller.sessionSettings.configOptions, isEmpty);
      expect(observed.single.text, isEmpty);
      expect(observed.single.metadata, isEmpty);
      expect(observed.single.toString(), isNot(contains(canary)));
      expect(
        observed.single.omissions.where(
          (omission) =>
              omission.reason == acp.AcpInputOmissionReason.invalidStructure,
        ),
        hasLength(1),
      );
    });

    test(
      'host fixed overflow resources survive a small string budget',
      () async {
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(
            maxTurnItems: 2,
            maxStructuredStringBytes: 16,
          ),
        );
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');

        expect(
          () => fake.emit(
            const AgentEvent(
              type: AgentEventType.agentTextDelta,
              text: 'SECRET_FIXED_RESOURCE_CANARY',
            ),
          ),
          returnsNormally,
        );

        expect(
          controller.messages
              .expand((message) => message.omissions)
              .where((omission) => omission.resource == 'turn items'),
          hasLength(1),
        );
        expect(
          controller.messages.map((message) => message.text).join(),
          isNot(contains('SECRET_FIXED_RESOURCE_CANARY')),
        );
      },
    );

    test(
      'injected media enforces aggregate exact plus one and drains',
      () async {
        const canary = 'SECRET_MEDIA_DRAIN_CANARY';
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(maxEmbeddedMediaBytes: 1),
        );
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');

        AgentEvent image(String data) => AgentEvent(
          type: AgentEventType.agentTextDelta,
          text: 'image',
          metadata: <String, Object?>{
            'contentBlocks': <Object?>[
              <String, Object?>{
                'type': 'image',
                'mimeType': 'image/png',
                'data': data,
              },
            ],
          },
        );

        fake.emit(image('YQ=='));
        fake.emit(image('YQ=='));
        fake.emit(image(canary));

        final metadataText = controller.messages
            .map((message) => message.metadata)
            .toString();
        expect('YQ=='.allMatches(metadataText), hasLength(1));
        expect(metadataText, isNot(contains(canary)));
        expect(
          controller.messages
              .expand((message) => message.omissions)
              .where((omission) => omission.resource == 'turn_media'),
          hasLength(1),
        );
      },
    );

    test(
      'audio and resource blobs share media bytes and invalid input is hidden',
      () async {
        const canary = 'SECRET_INVALID_MEDIA_CANARY';
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(maxEmbeddedMediaBytes: 2),
        );
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        AgentEvent media(Map<String, Object?> block) => AgentEvent(
          type: AgentEventType.agentTextDelta,
          text: 'media',
          metadata: <String, Object?>{
            'contentBlocks': <Object?>[block],
          },
        );

        fake.emit(
          media(const <String, Object?>{
            'type': 'image',
            'mimeType': 'image/png',
            'data': canary,
          }),
        );
        fake.emit(
          media(const <String, Object?>{
            'type': 'audio',
            'mimeType': 'audio/wav',
            'data': 'YQ==',
          }),
        );
        fake.emit(
          media(const <String, Object?>{
            'type': 'resource',
            'resource': <String, Object?>{
              'uri': 'file:///safe',
              'blob': 'Yg==',
            },
          }),
        );
        fake.emit(
          media(const <String, Object?>{
            'type': 'image',
            'mimeType': 'image/png',
            'data': 'Yw==',
          }),
        );
        fake.emit(
          media(const <String, Object?>{
            'type': 'audio',
            'mimeType': 'audio/wav',
            'data': canary,
          }),
        );

        final retainedMetadata = controller.messages
            .map((message) => message.metadata)
            .toList(growable: false)
            .toString();
        expect(retainedMetadata, contains('YQ=='));
        expect(retainedMetadata, contains('Yg=='));
        expect(retainedMetadata, isNot(contains(canary)));
        expect(
          controller.messages
              .expand((message) => message.omissions)
              .where(
                (omission) =>
                    omission.resource == 'image_data' &&
                    omission.reason ==
                        acp.AcpInputOmissionReason.invalidEncoding,
              ),
          hasLength(1),
        );
        expect(
          controller.messages
              .expand((message) => message.omissions)
              .where((omission) => omission.resource == 'turn_media'),
          hasLength(1),
        );
        expect(
          observed.map((event) => event.metadata).toString(),
          isNot(contains(canary)),
        );
      },
    );

    test(
      'media payload is independent from the structured string budget',
      () async {
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(
            maxEmbeddedMediaBytes: 1,
            maxStructuredStringBytes: 16,
          ),
        );
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');

        fake.emit(
          const AgentEvent(
            type: AgentEventType.agentTextDelta,
            text: 'i',
            metadata: <String, Object?>{
              'contentBlocks': <Object?>[
                <String, Object?>{
                  'type': 'image',
                  'mimeType': 'i',
                  'data': 'YQ==',
                },
              ],
            },
          ),
        );

        final image = controller.messages.singleWhere(
          (message) => message.metadata['contentBlocks'] != null,
        );
        expect(image.metadata.toString(), contains('YQ=='));
        expect(image.omissions, isEmpty);
      },
    );

    test(
      'forged media omission drops extra payload and bad blocks keep their own resource',
      () async {
        const canary = 'SECRET_FORGED_OMISSION_CANARY';
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');

        fake.emit(
          const AgentEvent(
            type: AgentEventType.agentTextDelta,
            text: 'media',
            metadata: <String, Object?>{
              'contentBlocks': <Object?>[
                <String, Object?>{
                  'type': 'omitted',
                  'reason': 'invalid_encoding',
                  'resource': 'image_data',
                  'truncated': false,
                  'extra': canary,
                },
                <String, Object?>{'type': 'image', 'data': canary},
                <String, Object?>{'type': 'audio', 'data': canary},
              ],
            },
          ),
        );

        final message = controller.messages.last;
        final blocks = message.metadata['contentBlocks']! as List;
        expect(message.metadata.toString(), isNot(contains(canary)));
        expect(blocks[0], isNot(contains('extra')));
        expect((blocks[1] as Map)['resource'], 'image_data');
        expect((blocks[2] as Map)['resource'], 'audio_data');
        expect(
          message.omissions.map((omission) => omission.resource),
          containsAll(<String>['image_data', 'audio_data']),
        );
      },
    );

    test(
      'forged omitted blocks never create trusted typed omissions',
      () async {
        const canary = 'SECRET_FORGED_TYPED_OMISSION';
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          const AgentEvent(
            type: AgentEventType.agentTextDelta,
            text: 'forged',
            metadata: <String, Object?>{
              'contentBlocks': <Object?>[
                <String, Object?>{
                  'type': 'omitted',
                  'reason': 'invalid_encoding',
                  'resource': 'image_data',
                  'truncated': false,
                  'extra': canary,
                },
              ],
            },
          ),
        );

        final message = controller.messages.last;
        expect(message.metadata.toString(), isNot(contains(canary)));
        expect(message.omissions, isEmpty);
        expect(observed.single.omissions, isEmpty);
      },
    );

    test('malformed forged omitted capacity fields never throw', () async {
      final fake = _ControlledPromptAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      await controller.newSession();
      await controller.sendPrompt('u');

      expect(
        () => fake.emit(
          const AgentEvent(
            type: AgentEventType.agentTextDelta,
            text: 'forged',
            metadata: <String, Object?>{
              'contentBlocks': <Object?>[
                <String, Object?>{
                  'type': 'omitted',
                  'reason': 'input_limit',
                  'resource': 'image_data',
                  'truncated': false,
                },
                <String, Object?>{
                  'type': 'omitted',
                  'reason': 'invalid_encoding',
                  'resource': 'audio_data',
                  'truncated': false,
                  'limit': 1,
                  'observedAtLeast': 2,
                },
                <String, Object?>{
                  'type': 'omitted',
                  'reason': 42,
                  'resource': <Object?>[],
                  'truncated': 'no',
                },
              ],
            },
          ),
        ),
        returnsNormally,
      );
      expect(controller.messages.last.omissions, isEmpty);
    });
  });

  group('ChatController turn budget terminal lifecycle', () {
    Future<
      ({
        ChatController controller,
        _ControlledPromptAgentClient fake,
        ChatMessage target,
        String high,
      })
    >
    pendingHighSurrogate() async {
      final high = String.fromCharCode(0xd83d);
      final fake = _ControlledPromptAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      await controller.newSession();
      await controller.sendPrompt('go');
      fake.emit(AgentEvent(type: AgentEventType.agentTextDelta, text: high));
      return (
        controller: controller,
        fake: fake,
        target: controller.messages.last,
        high: high,
      );
    }

    test('stop finishes pending text exactly once', () async {
      final state = await pendingHighSurrogate();
      addTearDown(state.controller.dispose);

      await state.controller.stop();
      expect(state.target.materializationCount, 1);
      expect(state.target.text, state.high);
      expect(state.target.revision, 1);
      state.controller.dispose();
      expect(state.target.revision, 1);
    });

    test(
      'terminal overflow omission attaches to an owned turn target',
      () async {
        const canary = 'SECRET_TERMINAL_OVERFLOW_CANARY';
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(maxTurnItems: 2),
        );
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: canary,
            metadata: <String, Object?>{
              'kind': 'terminal',
              'terminalId': 't',
              'status': 'completed',
            },
          ),
        );

        expect(
          controller.messages.where(
            (message) => message.metadata['kind'] == 'terminal',
          ),
          isEmpty,
        );
        expect(observed.single.text, isEmpty);
        expect(observed.single.metadata, isEmpty);
        expect(observed.single.toString(), isNot(contains(canary)));
        expect(
          controller.messages
              .expand((message) => message.omissions)
              .where((omission) => omission.resource == 'turn items'),
          hasLength(1),
        );
      },
    );

    test('no-target terminal uses one payload-free reserved marker', () async {
      const canary = 'SECRET_NO_TARGET_TERMINAL_CANARY';
      final controller = ChatController(
        client: FakeAgentClient(
          createSessionEvents: const <AgentEvent>[
            AgentEvent(
              type: AgentEventType.status,
              text: canary,
              metadata: <String, Object?>{
                'kind': 'terminal',
                'terminalId': 'initial',
                'status': 'completed',
              },
            ),
          ],
        ),
        cwd: '/workspace',
        inputBudget: const acp.AcpInputBudget(maxTurnItems: 1),
      );
      addTearDown(controller.dispose);
      final dynamic debug = controller;
      late AgentEvent observed;
      var itemsDuringObservation = -1;
      var retainedDuringObservation = -1;
      controller.addAgentEventObserver((_, event) {
        observed = event;
        itemsDuringObservation = debug.debugCurrentTurnItems as int;
        retainedDuringObservation = debug.debugCurrentTurnRetainedBytes as int;
      });

      await controller.newSession();

      expect(itemsDuringObservation, 1);
      expect(retainedDuringObservation, greaterThan(0));
      expect(
        retainedDuringObservation,
        lessThanOrEqualTo(const acp.AcpInputBudget().maxTurnRetainedBytes),
      );
      expect(controller.messages, hasLength(1));
      final marker = controller.messages.single;
      expect(marker.role, ChatMessageRole.status);
      expect(marker.text, isEmpty);
      expect(marker.metadata, isEmpty);
      expect(marker.omissions, hasLength(1));
      expect(marker.omissions.single.resource, 'turn items');
      expect(observed.text, isEmpty);
      expect(observed.metadata, isEmpty);
      expect(observed.toString(), isNot(contains(canary)));
    });

    test(
      'same terminal id lifecycle replaces in place and recomputes delta',
      () async {
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        await controller.newSession();
        await controller.sendPrompt('u');
        final dynamic debug = controller;

        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: 'a',
            metadata: <String, Object?>{
              'kind': 'terminal',
              'terminalId': 'same',
              'status': 'running',
            },
          ),
        );
        expect(debug.debugCurrentTurnItems, 2);
        final firstBytes = debug.debugCurrentTurnRetainedBytes as int;

        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: 'completed safely',
            metadata: <String, Object?>{
              'kind': 'terminal',
              'terminalId': 'same',
              'status': 'completed',
            },
          ),
        );
        expect(debug.debugCurrentTurnItems, 2);
        expect(debug.debugCurrentTurnRetainedBytes, greaterThan(firstBytes));
        final completedBytes = debug.debugCurrentTurnRetainedBytes as int;

        fake.emit(
          const AgentEvent(
            type: AgentEventType.status,
            text: 'Terminal released.',
            metadata: <String, Object?>{
              'kind': 'terminal',
              'terminalId': 'same',
              'status': 'released',
            },
          ),
        );

        expect(debug.debugCurrentTurnItems, 2);
        expect(debug.debugCurrentTurnRetainedBytes, completedBytes);
        final terminal = controller.messages.singleWhere(
          (message) => message.metadata['kind'] == 'terminal',
        );
        expect(terminal.text, 'completed safely');
        expect(terminal.metadata['status'], 'completed');
      },
    );

    test('terminal overflow stays typed-only when no marker can fit', () async {
      const canary = 'SECRET_TERMINAL_TYPED_ONLY_CANARY';
      final fake = _ControlledPromptAgentClient();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        inputBudget: const acp.AcpInputBudget(maxTurnRetainedBytes: 1),
      );
      addTearDown(controller.dispose);
      await controller.newSession();
      await controller.sendPrompt('u');
      final observed = <AgentEvent>[];
      controller.addAgentEventObserver((_, event) => observed.add(event));

      fake.emit(
        const AgentEvent(
          type: AgentEventType.status,
          text: canary,
          metadata: <String, Object?>{
            'kind': 'terminal',
            'terminalId': 't',
            'status': 'completed',
          },
        ),
      );

      final dynamic debug = controller;
      expect(debug.debugTurnOverflowed, isTrue);
      expect(debug.debugCurrentTurnRetainedBytes, 0);
      expect(controller.messages, isEmpty);
      expect(observed.single.text, isEmpty);
      expect(observed.single.metadata, isEmpty);
      expect(observed.single.toString(), isNot(contains(canary)));
      expect(
        observed.single.omissions.where(
          (omission) => omission.resource == 'turn retained bytes',
        ),
        hasLength(1),
      );
    });

    test('reconnect finishes pending text before releasing the turn', () async {
      final state = await pendingHighSurrogate();
      addTearDown(state.controller.dispose);

      await state.controller.reconnect();
      expect(state.target.text, state.high);
      expect(state.target.revision, 1);
      state.controller.dispose();
      expect(state.target.revision, 1);
    });

    test('session close and switch finish the old pending target', () async {
      final closing = await pendingHighSurrogate();
      addTearDown(closing.controller.dispose);
      closing.controller.isStreaming = false;

      await closing.controller.closeCurrentSession();
      expect(closing.target.text, closing.high);
      expect(closing.target.revision, 1);

      final switching = await pendingHighSurrogate();
      addTearDown(switching.controller.dispose);
      switching.controller.isStreaming = false;
      await switching.controller.newSession();

      expect(switching.target.text, switching.high);
      expect(switching.target.revision, 1);
    });

    test(
      'archive finishes pending text before freezing the snapshot',
      () async {
        final state = await pendingHighSurrogate();
        addTearDown(state.controller.dispose);
        state.controller.isStreaming = false;

        final snapshot = state.controller.archiveSessionLocally(
          state.controller.currentSession!.id,
        );

        expect(snapshot, isNotNull);
        expect(snapshot!.messages.last.text, state.high);
        expect(snapshot.messages.last.revision, 1);
        expect(snapshot.messages.last.acceptedUtf8Bytes, 3);
        expect(() => snapshot.messages.last.text = 'no', throwsStateError);
      },
    );

    test(
      'dispose finishes pending text and suppresses double finish',
      () async {
        final state = await pendingHighSurrogate();

        state.controller.dispose();
        state.controller.dispose();

        expect(state.target.text, state.high);
        expect(state.target.revision, 1);
        await state.controller.disposalComplete;
      },
    );
  });

  group('ChatController timeline budgets', () {
    test(
      'message and command collections expose immutable revisioned views',
      () {
        final controller = ChatController(
          client: FakeAgentClient(),
          cwd: '/workspace',
        );
        addTearDown(controller.dispose);

        expect(controller.messagesRevision, 0);
        expect(
          () => controller.messages.add(
            ChatMessage(role: ChatMessageRole.user, text: 'bypass'),
          ),
          throwsUnsupportedError,
        );
        controller.addMessageForTesting(
          ChatMessage(role: ChatMessageRole.user, text: 'guarded'),
          startsNewTurn: true,
        );
        expect(controller.messagesRevision, 1);

        final nested = <Object?>['safe'];
        final commands = <Map<String, Object?>>[
          <String, Object?>{'name': 'review', 'payload': nested},
        ];
        expect(controller.availableCommandsRevision, 0);
        controller.availableCommands = commands;
        expect(controller.availableCommandsRevision, 1);
        nested.add('mutated');
        expect(controller.availableCommands.single['payload'], <Object?>[
          'safe',
        ]);
        commands.single['name'] = 'updated';
        controller.availableCommands = commands;
        expect(controller.availableCommandsRevision, 2);
        expect(controller.availableCommands.single['name'], 'updated');
        commands.clear();
        expect(
          () => controller.availableCommands.clear(),
          throwsUnsupportedError,
        );
        controller.availableCommands = const <Map<String, Object?>>[];
        expect(controller.availableCommandsRevision, 3);
        expect(controller.availableCommands, isEmpty);
      },
    );

    test('controller owns independent immutable message instances', () {
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      final source = ChatMessage(role: ChatMessageRole.user, text: 'safe');

      controller.addMessageForTesting(source, startsNewTurn: true);
      final firstOwned = controller.messages.single;
      expect(firstOwned, isNot(same(source)));
      source.text = 'source changed';
      expect(firstOwned.text, 'safe');
      expect(() => firstOwned.text = 'bypass', throwsStateError);
      expect(
        () => firstOwned.appendAcceptedText('!', acceptedUtf8Bytes: 1),
        throwsStateError,
      );
      expect(
        () => firstOwned.addOmission(
          acp.AcpInputOmission(
            reason: acp.AcpInputOmissionReason.invalidStructure,
            resource: 'bypass',
            truncated: false,
          ),
        ),
        throwsStateError,
      );

      final repeated = ChatMessage(role: ChatMessageRole.user, text: 'repeat');
      controller.addMessageForTesting(repeated, startsNewTurn: true);
      controller.addMessageForTesting(repeated, startsNewTurn: true);
      expect(controller.messages[1], isNot(same(controller.messages[2])));
      expect(
        controller.messages[1].turnId,
        isNot(controller.messages[2].turnId),
      );
      expect(controller.debugCurrentTurnItems, 1);
      expect(
        () => controller.addMessageForTesting(firstOwned, startsNewTurn: true),
        throwsStateError,
      );
    });

    test(
      'item overflow evicts the oldest complete turn and keeps one marker',
      () {
        final controller = ChatController(
          client: FakeAgentClient(),
          cwd: '/workspace',
          inputBudget: const acp.AcpInputBudget(maxTimelineItems: 3),
        );
        addTearDown(controller.dispose);

        controller.addMessageForTesting(
          ChatMessage(role: ChatMessageRole.user, text: 'turn one user'),
          startsNewTurn: true,
        );
        controller.addMessageForTesting(
          ChatMessage(
            role: ChatMessageRole.assistant,
            text: 'turn one assistant',
          ),
        );
        final firstTurnId = controller.messages.first.turnId;

        controller.addMessageForTesting(
          ChatMessage(role: ChatMessageRole.user, text: 'turn two user'),
          startsNewTurn: true,
        );
        controller.addMessageForTesting(
          ChatMessage(
            role: ChatMessageRole.assistant,
            text: 'turn two assistant',
          ),
        );

        expect(controller.messages.map((message) => message.text), <String>[
          '',
          'turn two user',
          'turn two assistant',
        ]);
        expect(
          controller.messages.where(
            (message) => message.omissions.any(
              (omission) => omission.resource == 'timeline history',
            ),
          ),
          hasLength(1),
        );
        final currentTurn = controller.messages.skip(1).toList();
        expect(
          currentTurn.map((message) => message.turnId).toSet(),
          hasLength(1),
        );
        expect(currentTurn.first.turnId, isNot(firstTurnId));

        controller.addMessageForTesting(
          ChatMessage(role: ChatMessageRole.user, text: 'turn three user'),
          startsNewTurn: true,
        );
        expect(
          controller.messages.where(
            (message) => message.omissions.any(
              (omission) => omission.resource == 'timeline history',
            ),
          ),
          hasLength(1),
        );
        expect(controller.messages.last.text, 'turn three user');
      },
    );

    test('byte exact keeps history and plus one evicts a complete turn', () {
      final userText = List<String>.filled(1500, 'u').join();
      final assistantText = List<String>.filled(1500, 'a').join();
      final turnBytes =
          ChatMessage(
            role: ChatMessageRole.user,
            text: userText,
          ).retainedBytes +
          ChatMessage(
            role: ChatMessageRole.assistant,
            text: assistantText,
          ).retainedBytes;
      final timelineBytes = 64 + 32 * 4 + turnBytes * 2;
      final budget = acp.AcpInputBudget(
        maxTurnRetainedBytes: turnBytes + 1025,
        maxTimelineBytes: timelineBytes,
        maxUiStateBytes: timelineBytes + 16384,
      );

      ChatController build({required bool overflow}) {
        final controller = ChatController(
          client: FakeAgentClient(),
          cwd: '/workspace',
          inputBudget: budget,
        );
        addTearDown(controller.dispose);
        controller.addMessageForTesting(
          ChatMessage(role: ChatMessageRole.user, text: userText),
          startsNewTurn: true,
        );
        controller.addMessageForTesting(
          ChatMessage(role: ChatMessageRole.assistant, text: assistantText),
        );
        controller.addMessageForTesting(
          ChatMessage(role: ChatMessageRole.user, text: userText),
          startsNewTurn: true,
        );
        controller.addMessageForTesting(
          ChatMessage(
            role: ChatMessageRole.assistant,
            text: overflow ? '$assistantText!' : assistantText,
          ),
        );
        return controller;
      }

      final exact = build(overflow: false);
      expect(exact.messages, hasLength(4));
      expect(
        exact.messages.where(
          (message) => message.omissions.any(
            (omission) => omission.resource == 'timeline history',
          ),
        ),
        isEmpty,
      );

      final overflow = build(overflow: true);
      expect(overflow.messages, hasLength(3));
      expect(overflow.messages.first.text, isEmpty);
      expect(overflow.messages[1].role, ChatMessageRole.user);
      expect(overflow.messages[2].text, '$assistantText!');
      expect(overflow.messages[1].turnId, overflow.messages[2].turnId);
    });

    test('timeline bytes include one list host and every list entry', () {
      final texts = <String>['first', 'second', 'third', 'fourth'];
      final samples = <ChatMessage>[
        for (final text in texts)
          ChatMessage(role: ChatMessageRole.user, text: text),
      ];
      final exactBytes =
          64 +
          32 * samples.length +
          samples.fold<int>(0, (sum, message) => sum + message.retainedBytes);
      final turnBytes =
          samples
              .map((message) => message.retainedBytes)
              .reduce((left, right) => left > right ? left : right) +
          1025;
      final exact = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        inputBudget: acp.AcpInputBudget(
          maxTurnRetainedBytes: turnBytes,
          maxTimelineBytes: exactBytes,
          maxUiStateBytes: exactBytes + 4096,
        ),
      );
      addTearDown(exact.dispose);
      for (final message in samples) {
        exact.addMessageForTesting(message, startsNewTurn: true);
      }

      expect(exact.debugActiveTimelineRetainedBytes, exactBytes);
      expect(exact.messages, hasLength(4));

      final plusOne = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        inputBudget: acp.AcpInputBudget(
          maxTurnRetainedBytes: turnBytes,
          maxTimelineBytes: exactBytes - 1,
          maxUiStateBytes: exactBytes + 4096,
        ),
      );
      addTearDown(plusOne.dispose);
      plusOne.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.user, text: 'old'),
        startsNewTurn: true,
      );
      for (final text in texts) {
        plusOne.addMessageForTesting(
          ChatMessage(role: ChatMessageRole.user, text: text),
          startsNewTurn: true,
        );
      }

      expect(
        plusOne.messages.where((message) => message.text == 'old'),
        isEmpty,
      );
      expect(
        plusOne.debugActiveTimelineRetainedBytes,
        lessThanOrEqualTo(exactBytes - 1),
      );
    });

    test(
      'inactive snapshots use LRU and reconnect clears the whole ledger',
      () async {
        ArchivedSessionSnapshot snapshot(
          String id, {
          acp.AcpInputBudget budget = const acp.AcpInputBudget(),
        }) {
          return ArchivedSessionSnapshot(
            session: AgentSession(
              id: id,
              cwd: '/workspace',
              createdAt: DateTime(2026, 7, 13),
            ),
            wasCurrent: false,
            messages: const <ChatMessage>[],
            availableCommands: const <Map<String, Object?>>[],
            lastLatency: null,
            lastError: null,
            sessionSettings: const AcpSessionSettings(),
            sessionUsage: null,
            sessionSettingsLoading: false,
            status: app_state.ConnectionStatus.sessionReady,
            activeSessionSettingsLoadId: null,
            inputBudget: budget,
          );
        }

        final oneSnapshotBytes = snapshot('s1').retainedBytes;
        final budget = acp.AcpInputBudget(
          maxTurnRetainedBytes: 2048,
          maxTimelineBytes: 2048,
          maxUiStateBytes: oneSnapshotBytes * 2,
        );
        final controller = ChatController(
          client: FakeAgentClient(),
          cwd: '/workspace',
          inputBudget: budget,
        );
        addTearDown(controller.dispose);

        controller.restoreArchivedSessionLocally(
          snapshot('s1', budget: budget),
        );
        controller.restoreArchivedSessionLocally(
          snapshot('s2', budget: budget),
        );
        expect(controller.debugInactiveSnapshotIds, <String>['s1', 's2']);
        expect(controller.debugUiStateRetainedBytes, oneSnapshotBytes * 2);

        controller.touchInactiveSnapshotForTesting('s1');
        expect(controller.debugInactiveSnapshotIds, <String>['s2', 's1']);
        controller.restoreArchivedSessionLocally(
          snapshot('s3', budget: budget),
        );

        expect(controller.debugInactiveSnapshotIds, <String>['s1', 's3']);
        expect(
          controller.debugUiStateRetainedBytes,
          lessThanOrEqualTo(budget.maxUiStateBytes),
        );

        controller.addMessageForTesting(
          ChatMessage(role: ChatMessageRole.user, text: 'active'),
          startsNewTurn: true,
        );
        expect(controller.messages.single.text, 'active');
        expect(
          controller.debugUiStateRetainedBytes,
          lessThanOrEqualTo(budget.maxUiStateBytes),
        );

        await controller.reconnect();
        expect(controller.messages, isEmpty);
        expect(controller.debugInactiveSnapshotIds, isEmpty);
        expect(controller.debugUiStateRetainedBytes, 0);
      },
    );

    test(
      'active commands settings and usage share snapshot retained accounting',
      () async {
        final session = AgentSession(
          id: 'active-ledger',
          cwd: '/workspace',
          createdAt: DateTime(2026, 7, 13, 10),
          title: 'Active ledger',
        );
        final inactiveSession = AgentSession(
          id: 'inactive-ledgr',
          cwd: '/workspace',
          createdAt: DateTime(2026, 7, 13, 11),
          title: 'Inactive cache',
        );
        const commands = <Map<String, Object?>>[
          <String, Object?>{
            'name': 'review',
            'description': 'Review active state',
          },
        ];
        const settings = AcpSessionSettings(
          modes: AcpSessionModeInfo(
            currentModeId: 'ask',
            availableModes: <AcpSessionMode>[
              AcpSessionMode(id: 'ask', name: 'Ask'),
            ],
          ),
        );
        const usage = AcpSessionUsage(
          used: 7,
          size: 100,
          cost: AcpSessionUsageCost(amount: 1.5, currency: 'USD'),
        );

        ArchivedSessionSnapshot view({
          required AgentSession session,
          List<Map<String, Object?>> availableCommands =
              const <Map<String, Object?>>[],
          AcpSessionSettings sessionSettings = const AcpSessionSettings(),
          AcpSessionUsage? sessionUsage,
          bool wasCurrent = false,
          acp.AcpInputBudget budget = const acp.AcpInputBudget(),
        }) {
          return ArchivedSessionSnapshot(
            session: session,
            wasCurrent: wasCurrent,
            messages: const <ChatMessage>[],
            availableCommands: availableCommands,
            lastLatency: const Duration(milliseconds: 12),
            lastError: 'bounded error',
            sessionSettings: sessionSettings,
            sessionUsage: sessionUsage,
            sessionSettingsLoading: false,
            status: app_state.ConnectionStatus.sessionReady,
            activeSessionSettingsLoadId: 3,
            inputBudget: budget,
          );
        }

        final inactive = view(session: inactiveSession);
        final cases =
            <
              ({
                String name,
                ArchivedSessionSnapshot desired,
                void Function(ChatController) apply,
              })
            >[
              (
                name: 'commands',
                desired: view(session: session, availableCommands: commands),
                apply: (controller) => controller.availableCommands = commands,
              ),
              (
                name: 'settings',
                desired: view(session: session, sessionSettings: settings),
                apply: (controller) => controller.sessionSettings = settings,
              ),
              (
                name: 'usage',
                desired: view(session: session, sessionUsage: usage),
                apply: (controller) => controller.sessionUsage = usage,
              ),
            ];

        ChatController build(int maxUiStateBytes) {
          final budget = acp.AcpInputBudget(
            maxTurnRetainedBytes: 2048,
            maxTimelineBytes: 2048,
            maxUiStateBytes: maxUiStateBytes,
          );
          final controller = ChatController(
            client: FakeAgentClient(),
            cwd: '/workspace',
            inputBudget: budget,
          );
          addTearDown(controller.dispose);
          controller.restoreArchivedSessionLocally(
            view(session: session, wasCurrent: true, budget: budget),
          );
          controller.restoreArchivedSessionLocally(
            view(session: inactiveSession, budget: budget),
          );
          return controller;
        }

        for (final stateCase in cases) {
          final exactTotal =
              stateCase.desired.retainedBytes + inactive.retainedBytes;

          final exact = build(exactTotal);
          stateCase.apply(exact);
          expect(
            exact.debugActiveUiStateRetainedBytes,
            stateCase.desired.retainedBytes,
            reason: stateCase.name,
          );
          expect(exact.debugInactiveSnapshotIds, <String>[
            inactiveSession.id,
          ], reason: stateCase.name);
          expect(exact.debugUiStateRetainedBytes, exactTotal);

          final plusOne = build(exactTotal - 1);
          stateCase.apply(plusOne);
          expect(
            plusOne.debugActiveUiStateRetainedBytes,
            stateCase.desired.retainedBytes,
            reason: stateCase.name,
          );
          expect(plusOne.debugInactiveSnapshotIds, isEmpty);
          expect(
            plusOne.debugUiStateRetainedBytes,
            lessThanOrEqualTo(exactTotal - 1),
          );
        }

        final reconnect = build(
          cases.first.desired.retainedBytes + inactive.retainedBytes,
        );
        reconnect.availableCommands = commands;
        reconnect.sessionSettings = settings;
        reconnect.sessionUsage = usage;
        await reconnect.reconnect();
        expect(reconnect.currentSession, isNull);
        expect(reconnect.messages, isEmpty);
        expect(reconnect.availableCommands, isEmpty);
        expect(reconnect.sessionSettings, const AcpSessionSettings());
        expect(reconnect.sessionUsage, isNull);
        expect(reconnect.lastLatency, isNull);
        expect(reconnect.lastError, isNull);
        expect(reconnect.debugInactiveSnapshotIds, isEmpty);
        expect(reconnect.debugActiveUiStateRetainedBytes, 0);
        expect(reconnect.debugUiStateRetainedBytes, 0);
      },
    );

    test(
      'new session transfers active ownership without transient eviction',
      () async {
        final oldSession = AgentSession(
          id: 'old-session',
          cwd: '/workspace/old',
          createdAt: DateTime(2026, 7, 13, 12),
        );
        final newSession = AgentSession(
          id: 'fake-session-1',
          cwd: '/workspace/new',
          createdAt: DateTime(2026, 5, 28, 12),
          agentName: 'Codex',
        );
        final oldMessage = ChatMessage(
          role: ChatMessageRole.assistant,
          text: List<String>.filled(3000, 'o').join(),
        );

        ArchivedSessionSnapshot snapshot(
          AgentSession session, {
          List<ChatMessage> messages = const <ChatMessage>[],
          bool wasCurrent = false,
          acp.AcpInputBudget budget = const acp.AcpInputBudget(),
        }) => ArchivedSessionSnapshot(
          session: session,
          wasCurrent: wasCurrent,
          messages: messages,
          availableCommands: const <Map<String, Object?>>[],
          lastLatency: null,
          lastError: null,
          sessionSettings: const AcpSessionSettings(),
          sessionUsage: null,
          sessionSettingsLoading: false,
          status: app_state.ConnectionStatus.sessionReady,
          activeSessionSettingsLoadId: null,
          inputBudget: budget,
        );

        final oldRetained = snapshot(
          oldSession,
          messages: <ChatMessage>[oldMessage],
        ).retainedBytes;
        final newRetained = snapshot(newSession).retainedBytes;
        final exact = oldRetained + newRetained;
        final budget = acp.AcpInputBudget(
          maxTurnRetainedBytes: 4096,
          maxTimelineBytes: 4096,
          maxUiStateBytes: exact,
        );
        final controller = ChatController(
          client: FakeAgentClient(sessionSettings: const AcpSessionSettings()),
          cwd: '/workspace',
          inputBudget: budget,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        controller.restoreArchivedSessionLocally(
          snapshot(
            oldSession,
            messages: <ChatMessage>[oldMessage],
            wasCurrent: true,
            budget: budget,
          ),
        );

        final created = await controller.newSession(cwd: '/workspace/new');
        expect(
          created,
          isTrue,
          reason:
              '${controller.lastError} ${controller.debugUiStateRetainedBytes}/$exact ${controller.debugInactiveSnapshotIds}',
        );
        expect(controller.currentSession?.id, newSession.id);
        expect(controller.debugInactiveSnapshotIds, <String>[oldSession.id]);
        expect(controller.debugUiStateRetainedBytes, exact);
      },
    );

    test(
      'local resume transfers exact active and snapshot ownership',
      () async {
        final firstSession = AgentSession(
          id: 'local-first',
          cwd: '/workspace/first',
          createdAt: DateTime(2026, 7, 13, 12),
        );
        final secondSession = AgentSession(
          id: 'local-second',
          cwd: '/workspace/second',
          createdAt: DateTime(2026, 7, 13, 13),
        );

        ArchivedSessionSnapshot snapshot(
          AgentSession session,
          String text, {
          required bool wasCurrent,
          acp.AcpInputBudget budget = const acp.AcpInputBudget(),
        }) => ArchivedSessionSnapshot(
          session: session,
          wasCurrent: wasCurrent,
          messages: <ChatMessage>[
            ChatMessage(role: ChatMessageRole.assistant, text: text),
          ],
          availableCommands: const <Map<String, Object?>>[],
          lastLatency: null,
          lastError: null,
          sessionSettings: const AcpSessionSettings(),
          sessionUsage: null,
          sessionSettingsLoading: false,
          status: app_state.ConnectionStatus.sessionReady,
          activeSessionSettingsLoadId: null,
          inputBudget: budget,
        );

        final firstText = List<String>.filled(900, 'a').join();
        final secondText = List<String>.filled(700, 'b').join();
        final exact =
            snapshot(firstSession, firstText, wasCurrent: true).retainedBytes +
            snapshot(
              secondSession,
              secondText,
              wasCurrent: false,
            ).retainedBytes;
        final budget = acp.AcpInputBudget(
          maxTurnRetainedBytes: 4096,
          maxTimelineBytes: 4096,
          maxUiStateBytes: exact,
        );
        final controller = ChatController(
          client: FakeAgentClient(),
          cwd: '/workspace',
          inputBudget: budget,
        );
        addTearDown(controller.dispose);
        controller.restoreArchivedSessionLocally(
          snapshot(firstSession, firstText, wasCurrent: true, budget: budget),
        );
        controller.restoreArchivedSessionLocally(
          snapshot(
            secondSession,
            secondText,
            wasCurrent: false,
            budget: budget,
          ),
        );
        expect(controller.debugUiStateRetainedBytes, exact);

        await controller.resumeSession(secondSession.id);
        expect(controller.currentSession?.id, secondSession.id);
        expect(controller.messages.single.text, secondText);
        expect(controller.debugInactiveSnapshotIds, <String>[firstSession.id]);
        expect(controller.debugUiStateRetainedBytes, exact);

        await controller.resumeSession(firstSession.id);
        expect(controller.currentSession?.id, firstSession.id);
        expect(controller.messages.single.text, firstText);
        expect(controller.debugInactiveSnapshotIds, <String>[secondSession.id]);
        expect(controller.debugUiStateRetainedBytes, exact);
      },
    );

    test('failed remote resume restores inactive LRU atomically', () async {
      final activeSession = AgentSession(
        id: 'rollback-active',
        cwd: '/workspace/active',
        createdAt: DateTime(2026, 7, 13, 15),
      );
      final cachedSession = AgentSession(
        id: 'rollback-cached',
        cwd: '/workspace/cached',
        createdAt: DateTime(2026, 7, 13, 16),
      );

      ArchivedSessionSnapshot snapshot(
        AgentSession session,
        String text, {
        required bool wasCurrent,
        String? lastError,
        acp.AcpInputBudget budget = const acp.AcpInputBudget(),
      }) => ArchivedSessionSnapshot(
        session: session,
        wasCurrent: wasCurrent,
        messages: <ChatMessage>[
          ChatMessage(role: ChatMessageRole.assistant, text: text),
        ],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: lastError,
        sessionSettings: const AcpSessionSettings(),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
        inputBudget: budget,
      );

      final activeText = List<String>.filled(300, 'a').join();
      final cachedText = List<String>.filled(200, 'c').join();
      const failedError = 'Bad state: resume failed';
      final exactAfterRollback =
          snapshot(
            activeSession,
            activeText,
            wasCurrent: true,
            lastError: failedError,
          ).retainedBytes +
          snapshot(cachedSession, cachedText, wasCurrent: false).retainedBytes;
      final budget = acp.AcpInputBudget(
        maxTurnRetainedBytes: 4096,
        maxTimelineBytes: 4096,
        maxUiStateBytes: exactAfterRollback,
      );
      final controller = ChatController(
        client: _FailingResumeAgentClient(),
        cwd: '/workspace',
        inputBudget: budget,
      );
      addTearDown(controller.dispose);
      controller.restoreArchivedSessionLocally(
        snapshot(activeSession, activeText, wasCurrent: true, budget: budget),
      );
      controller.restoreArchivedSessionLocally(
        snapshot(cachedSession, cachedText, wasCurrent: false, budget: budget),
      );
      expect(controller.debugInactiveSnapshotIds, <String>[cachedSession.id]);

      await controller.resumeSession('rollback-target', cwd: '/workspace/b');

      expect(controller.currentSession?.id, activeSession.id);
      expect(controller.messages.single.text, activeText);
      expect(controller.lastError, failedError);
      expect(controller.debugInactiveSnapshotIds, <String>[cachedSession.id]);
      expect(controller.debugUiStateRetainedBytes, exactAfterRollback);
    });

    test(
      'hostile remote session is rejected before ownership commit',
      () async {
        final previous = AgentSession(
          id: 'safe-current',
          cwd: '/workspace/safe',
          createdAt: DateTime(2026, 7, 13, 19),
        );
        final controller = ChatController(
          client: _HostileCreateSessionAgentClient(),
          cwd: '/workspace',
        );
        addTearDown(controller.dispose);
        controller.restoreArchivedSessionLocally(
          ArchivedSessionSnapshot(
            session: previous,
            wasCurrent: true,
            messages: <ChatMessage>[
              ChatMessage(role: ChatMessageRole.assistant, text: 'safe'),
            ],
            availableCommands: const <Map<String, Object?>>[],
            lastLatency: null,
            lastError: null,
            sessionSettings: const AcpSessionSettings(),
            sessionUsage: null,
            sessionSettingsLoading: false,
            status: app_state.ConnectionStatus.sessionReady,
            activeSessionSettingsLoadId: null,
          ),
        );
        expect(await controller.newSession(), isFalse);

        expect(controller.currentSession?.id, previous.id);
        expect(controller.messages.single.text, 'safe');
        expect(controller.sessions.map((session) => session.id), [previous.id]);
        expect(controller.debugInactiveSnapshotIds, isEmpty);
        expect(
          controller.debugUiStateRetainedBytes,
          lessThanOrEqualTo(controller.inputBudget.maxUiStateBytes),
        );
      },
    );

    test(
      'new session publishes committed state before settings await',
      () async {
        final fake = _DelayedInitialSettingsAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);
        final committedNotifications = <String>[];
        controller.addListener(() {
          final sessionId = controller.currentSession?.id;
          if (sessionId != null) {
            committedNotifications.add(sessionId);
            expect(
              controller.debugUiStateRetainedBytes,
              lessThanOrEqualTo(controller.inputBudget.maxUiStateBytes),
            );
          }
        });

        final creating = controller.newSession();
        await fake.settingsStarted.future;

        expect(controller.currentSession?.id, 'fake-session-1');
        expect(committedNotifications, contains('fake-session-1'));

        fake.allowSettings.complete();
        expect(await creating, isTrue);
      },
    );

    test('initial events are copied as one atomic bounded batch', () async {
      final previous = AgentSession(
        id: 'events-safe',
        cwd: '/workspace/safe',
        createdAt: DateTime(2026, 7, 13, 20),
      );
      final controller = ChatController(
        client: _GrowingInitialEventsAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      controller.restoreArchivedSessionLocally(
        ArchivedSessionSnapshot(
          session: previous,
          wasCurrent: true,
          messages: <ChatMessage>[
            ChatMessage(role: ChatMessageRole.assistant, text: 'safe'),
          ],
          availableCommands: const <Map<String, Object?>>[],
          lastLatency: null,
          lastError: null,
          sessionSettings: const AcpSessionSettings(),
          sessionUsage: null,
          sessionSettingsLoading: false,
          status: app_state.ConnectionStatus.sessionReady,
          activeSessionSettingsLoadId: null,
        ),
      );

      expect(await controller.newSession(), isFalse);
      expect(controller.currentSession?.id, previous.id);
      expect(controller.messages.single.text, 'safe');
      expect(controller.sessions.map((session) => session.id), [previous.id]);
      expect(controller.debugInactiveSnapshotIds, isEmpty);
    });

    test(
      'remote session collections are stable after source mutation',
      () async {
        final fake = _MutableCreateSessionAgentClient();
        final controller = ChatController(client: fake, cwd: '/workspace');
        addTearDown(controller.dispose);

        expect(await controller.newSession(), isTrue);
        fake.directories.add('/mutated');
        fake.events.add(
          const AgentEvent(
            type: AgentEventType.agentTextDelta,
            text: 'mutated',
          ),
        );

        expect(controller.currentSession?.additionalDirectories, ['/safe']);
        expect(controller.currentSession?.initialEvents, isEmpty);
        expect(controller.messages.map((message) => message.text), ['initial']);
      },
    );

    test('disposed controller drops delayed session result', () async {
      final fake = _DelayedCreateSessionAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');

      final creating = controller.newSession();
      await fake.createStarted.future;
      controller.dispose();
      fake.allowCreate.complete();
      await creating;

      expect(controller.currentSession, isNull);
      expect(controller.sessions, isEmpty);
      expect(controller.messages, isEmpty);
      expect(controller.debugInactiveSnapshotIds, isEmpty);
      await controller.disposalComplete;
    });

    test(
      'active-only overflow evicts old turns and rejects auxiliary plus one',
      () {
        final session = AgentSession(
          id: 'active-only',
          cwd: '/workspace',
          createdAt: DateTime(2026, 7, 13, 13),
        );
        ChatMessage oldMessage() => ChatMessage(
          role: ChatMessageRole.assistant,
          text: List<String>.filled(1000, 'o').join(),
        );
        ChatMessage currentMessage() =>
            ChatMessage(role: ChatMessageRole.assistant, text: '');

        ArchivedSessionSnapshot snapshot({
          List<ChatMessage> messages = const <ChatMessage>[],
          List<Map<String, Object?>> commands = const <Map<String, Object?>>[],
          AcpSessionSettings settings = const AcpSessionSettings(),
          AcpSessionUsage? usage,
          acp.AcpInputBudget budget = const acp.AcpInputBudget(),
        }) => ArchivedSessionSnapshot(
          session: session,
          wasCurrent: true,
          messages: messages,
          availableCommands: commands,
          lastLatency: null,
          lastError: null,
          sessionSettings: settings,
          sessionUsage: usage,
          sessionSettingsLoading: false,
          status: app_state.ConnectionStatus.sessionReady,
          activeSessionSettingsLoadId: null,
          inputBudget: budget,
        );

        final measuring = ChatController(
          client: FakeAgentClient(),
          cwd: '/workspace',
        );
        addTearDown(measuring.dispose);
        measuring.restoreArchivedSessionLocally(
          snapshot(messages: <ChatMessage>[oldMessage()]),
        );
        measuring.addMessageForTesting(currentMessage(), startsNewTurn: true);
        final messageExact = measuring.debugUiStateRetainedBytes;
        final messageBudget = acp.AcpInputBudget(
          maxTurnRetainedBytes: 4096,
          maxTimelineBytes: 4096,
          maxUiStateBytes: messageExact,
        );
        final messageController = ChatController(
          client: FakeAgentClient(),
          cwd: '/workspace',
          inputBudget: messageBudget,
        );
        addTearDown(messageController.dispose);
        messageController.restoreArchivedSessionLocally(
          snapshot(
            messages: <ChatMessage>[oldMessage()],
            budget: messageBudget,
          ),
        );
        messageController.addMessageForTesting(
          currentMessage(),
          startsNewTurn: true,
        );
        expect(
          messageController.debugUiStateRetainedBytes,
          messageExact,
          reason: messageController.messages
              .map((message) => '${message.text.length}:${message.turnId}')
              .toString(),
        );
        messageController.appendTextForTesting('x\n');
        expect(
          messageController.messages.where(
            (message) => message.text.startsWith('o'),
          ),
          isEmpty,
        );
        expect(
          messageController.messages.where(
            (message) => message.omissions.any(
              (omission) => omission.resource == 'timeline history',
            ),
          ),
          hasLength(1),
        );
        expect(
          messageController.debugUiStateRetainedBytes,
          lessThanOrEqualTo(messageBudget.maxUiStateBytes),
        );

        const commands = <Map<String, Object?>>[
          <String, Object?>{'name': 'review'},
        ];
        const settings = AcpSessionSettings(
          modes: AcpSessionModeInfo(
            currentModeId: 'ask',
            availableModes: <AcpSessionMode>[
              AcpSessionMode(id: 'ask', name: 'Ask'),
            ],
          ),
        );
        const usage = AcpSessionUsage(used: 1, size: 10);
        final desired =
            <
              ({
                int retained,
                bool checksCommandRevision,
                void Function(ChatController) apply,
                void Function(ChatController) verifyRejected,
              })
            >[
              (
                retained: snapshot(commands: commands).retainedBytes,
                checksCommandRevision: true,
                apply: (controller) => controller.availableCommands = commands,
                verifyRejected: (controller) =>
                    expect(controller.availableCommands, isEmpty),
              ),
              (
                retained: snapshot(settings: settings).retainedBytes,
                checksCommandRevision: false,
                apply: (controller) => controller.sessionSettings = settings,
                verifyRejected: (controller) {
                  expect(
                    controller.sessionSettings.modes.currentModeId,
                    isNull,
                  );
                  expect(
                    controller.sessionSettings.modes.availableModes,
                    isEmpty,
                  );
                  expect(controller.sessionSettings.configOptions, isEmpty);
                },
              ),
              (
                retained: snapshot(usage: usage).retainedBytes,
                checksCommandRevision: false,
                apply: (controller) => controller.sessionUsage = usage,
                verifyRejected: (controller) =>
                    expect(controller.sessionUsage, isNull),
              ),
            ];
        for (final stateCase in desired) {
          final budget = acp.AcpInputBudget(
            maxTurnRetainedBytes: 2048,
            maxTimelineBytes: 2048,
            maxUiStateBytes: stateCase.retained - 1,
          );
          final controller = ChatController(
            client: FakeAgentClient(),
            cwd: '/workspace',
            inputBudget: budget,
          );
          addTearDown(controller.dispose);
          controller.restoreArchivedSessionLocally(snapshot(budget: budget));
          final commandRevisionBefore = controller.availableCommandsRevision;
          stateCase.apply(controller);
          stateCase.verifyRejected(controller);
          if (stateCase.checksCommandRevision) {
            expect(controller.availableCommandsRevision, commandRevisionBefore);
          }
          expect(controller.currentSession?.id, session.id);
          expect(
            controller.debugUiStateRetainedBytes,
            lessThanOrEqualTo(budget.maxUiStateBytes),
          );
        }
      },
    );

    test('internal command UI overflow is atomic and payload-free', () async {
      const commands = <Map<String, Object?>>[
        <String, Object?>{
          'name': 'review',
          'description': 'Review current changes',
        },
      ];
      final session = AgentSession(
        id: 'fake-session-1',
        cwd: '/workspace',
        createdAt: DateTime(2026, 5, 28, 12),
        agentName: 'Codex',
      );
      final desired = ArchivedSessionSnapshot(
        session: session,
        wasCurrent: true,
        messages: const <ChatMessage>[],
        availableCommands: commands,
        lastLatency: null,
        lastError: null,
        sessionSettings: const AcpSessionSettings(),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
      );
      final budget = acp.AcpInputBudget(
        maxTurnRetainedBytes: 2048,
        maxTimelineBytes: 2048,
        maxUiStateBytes: desired.retainedBytes - 1,
      );
      final controller = ChatController(
        client: FakeAgentClient(
          sessionSettings: const AcpSessionSettings(),
          createSessionEvents: const <AgentEvent>[
            AgentEvent(
              type: AgentEventType.status,
              text: 'commands',
              metadata: <String, Object?>{
                'kind': 'commands',
                'commands': commands,
              },
            ),
          ],
        ),
        cwd: '/workspace',
        inputBudget: budget,
      );
      addTearDown(controller.dispose);
      final observed = <AgentEvent>[];
      controller.addAgentEventObserver((_, event) => observed.add(event));

      expect(await controller.newSession(), isTrue);
      expect(controller.availableCommands, isEmpty);
      expect(
        controller.debugUiStateRetainedBytes,
        lessThanOrEqualTo(budget.maxUiStateBytes),
      );
      final commandEvent = observed.single;
      expect(commandEvent.text, isEmpty);
      expect(commandEvent.metadata, isEmpty);
      expect(
        commandEvent.omissions.where(
          (omission) => omission.resource == 'UI state retained bytes',
        ),
        hasLength(1),
        reason:
            'text=${commandEvent.text} metadata=${commandEvent.metadata} omissions=${commandEvent.omissions} error=${controller.lastError} retained=${controller.debugUiStateRetainedBytes}/${budget.maxUiStateBytes}',
      );
    });

    test(
      'auxiliary preflight rejects usage beyond all evictable turns',
      () async {
        final fake = _ControlledPromptAgentClient();
        final session = AgentSession(
          id: 'auxiliary-exact',
          cwd: '/workspace',
          createdAt: DateTime(2026, 7, 13, 17),
        );
        final largeDescription = List<String>.filled(1000, 's').join();
        final currency = List<String>.filled(1000, 'u').join();
        final settings = AcpSessionSettings(
          configOptions: <AcpConfigOption>[
            AcpConfigOption(
              id: 'large',
              name: 'Large',
              type: 'text',
              currentValue: 'safe',
              options: const <AcpConfigOptionChoice>[],
              description: largeDescription,
            ),
          ],
        );
        final proposedUsage = AcpSessionUsage(
          used: 1,
          size: 10,
          cost: AcpSessionUsageCost(amount: 1, currency: currency),
        );

        ArchivedSessionSnapshot view({
          required List<ChatMessage> messages,
          AcpSessionUsage? usage,
          acp.AcpInputBudget budget = const acp.AcpInputBudget(),
        }) => ArchivedSessionSnapshot(
          session: session,
          wasCurrent: true,
          messages: messages,
          availableCommands: const <Map<String, Object?>>[],
          lastLatency: null,
          lastError: null,
          sessionSettings: settings,
          sessionUsage: usage,
          sessionSettingsLoading: false,
          status: app_state.ConnectionStatus.sessionReady,
          activeSessionSettingsLoadId: null,
          inputBudget: budget,
        );

        final currentMessage = ChatMessage(
          role: ChatMessageRole.user,
          text: 'u',
        );
        final proposedWithoutOld = view(
          messages: <ChatMessage>[currentMessage],
          usage: proposedUsage,
        ).retainedBytes;
        final budget = acp.AcpInputBudget(
          maxTurnRetainedBytes: 4096,
          maxTimelineBytes: 4096,
          maxUiStateBytes: proposedWithoutOld - 1,
        );
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: budget,
        );
        addTearDown(controller.dispose);
        controller.restoreArchivedSessionLocally(
          view(
            messages: <ChatMessage>[
              ChatMessage(role: ChatMessageRole.assistant, text: 'old'),
            ],
            budget: budget,
          ),
        );
        await controller.sendPrompt('u');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          AgentEvent(
            type: AgentEventType.status,
            text: currency,
            metadata: <String, Object?>{
              'kind': 'usage_update',
              'used': 1,
              'size': 10,
              'cost': <String, Object?>{'amount': 1, 'currency': currency},
            },
          ),
        );

        expect(controller.sessionUsage, isNull);
        expect(controller.sessionSettings.configOptions.single.id, 'large');
        expect(controller.messages.map((message) => message.text), [
          'old',
          'u',
        ]);
        expect(
          controller.debugUiStateRetainedBytes,
          lessThanOrEqualTo(budget.maxUiStateBytes),
        );
        expect(observed.single.text, isEmpty);
        expect(observed.single.metadata, isEmpty);
        expect(observed.single.toString(), isNot(contains(currency)));
        expect(
          observed.single.omissions.where(
            (omission) => omission.resource == 'UI state retained bytes',
          ),
          hasLength(1),
        );
      },
    );

    test('commands and settings share exact auxiliary rejection', () async {
      final session = AgentSession(
        id: 'auxiliary-peer-cases',
        cwd: '/workspace',
        createdAt: DateTime(2026, 7, 13, 18),
      );
      final canary = List<String>.filled(700, 'z').join();
      final commands = <Map<String, Object?>>[
        <String, Object?>{'name': 'large', 'description': canary},
      ];
      final settings = AcpSessionSettings(
        configOptions: <AcpConfigOption>[
          AcpConfigOption(
            id: 'large',
            name: 'Large',
            type: 'text',
            currentValue: 'safe',
            options: const <AcpConfigOptionChoice>[],
            description: canary,
          ),
        ],
      );

      ArchivedSessionSnapshot view({
        required List<ChatMessage> messages,
        List<Map<String, Object?>> availableCommands =
            const <Map<String, Object?>>[],
        AcpSessionSettings sessionSettings = const AcpSessionSettings(),
        acp.AcpInputBudget budget = const acp.AcpInputBudget(),
      }) => ArchivedSessionSnapshot(
        session: session,
        wasCurrent: true,
        messages: messages,
        availableCommands: availableCommands,
        lastLatency: null,
        lastError: null,
        sessionSettings: sessionSettings,
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
        inputBudget: budget,
      );

      Future<void> verify({required bool commandsCase}) async {
        final desired = view(
          messages: <ChatMessage>[
            ChatMessage(role: ChatMessageRole.user, text: 'u'),
          ],
          availableCommands: commandsCase ? commands : const [],
          sessionSettings: commandsCase ? const AcpSessionSettings() : settings,
        );
        final budget = acp.AcpInputBudget(
          maxTurnRetainedBytes: 2048,
          maxTimelineBytes: 2048,
          maxUiStateBytes: desired.retainedBytes - 1,
        );
        final fake = _ControlledPromptAgentClient();
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: budget,
        );
        addTearDown(controller.dispose);
        controller.restoreArchivedSessionLocally(
          view(
            messages: <ChatMessage>[
              ChatMessage(role: ChatMessageRole.assistant, text: 'old'),
            ],
            budget: budget,
          ),
        );
        await controller.sendPrompt('u');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          AgentEvent(
            type: AgentEventType.status,
            text: canary,
            metadata: commandsCase
                ? <String, Object?>{'kind': 'commands', 'commands': commands}
                : <String, Object?>{
                    'kind': 'config_option_update',
                    'configOptions': settings.configOptions,
                  },
          ),
        );

        expect(controller.availableCommands, isEmpty);
        expect(controller.sessionSettings.configOptions, isEmpty);
        expect(controller.messages.map((message) => message.text), [
          'old',
          'u',
        ]);
        expect(observed.single.text, isEmpty);
        expect(observed.single.metadata, isEmpty);
        expect(observed.single.toString(), isNot(contains(canary)));
        expect(
          observed.single.omissions.where(
            (omission) => omission.resource == 'UI state retained bytes',
          ),
          hasLength(1),
        );
      }

      await verify(commandsCase: true);
      await verify(commandsCase: false);
    });

    test(
      'prior-turn replacement rejects without deleting its target',
      () async {
        final fake = _ControlledPromptAgentClient();
        final session = AgentSession(
          id: 'prior-replacement',
          cwd: '/workspace',
          createdAt: DateTime(2026, 7, 13, 18),
        );
        final largeSetting = List<String>.filled(1000, 's').join();
        final settings = AcpSessionSettings(
          configOptions: <AcpConfigOption>[
            AcpConfigOption(
              id: 'large',
              name: 'Large',
              type: 'text',
              currentValue: largeSetting,
              options: const <AcpConfigOptionChoice>[],
            ),
          ],
        );
        final oldText = List<String>.filled(900, 'p').join();
        final replacementText = '${oldText}x';
        const planMetadata = <String, Object?>{'kind': 'plan', 'title': 'plan'};
        ChatMessage plan(String text) => ChatMessage(
          role: ChatMessageRole.status,
          text: text,
          metadata: planMetadata,
        );

        ArchivedSessionSnapshot view(
          List<ChatMessage> messages, {
          acp.AcpInputBudget budget = const acp.AcpInputBudget(),
        }) => ArchivedSessionSnapshot(
          session: session,
          wasCurrent: true,
          messages: messages,
          availableCommands: const <Map<String, Object?>>[],
          lastLatency: null,
          lastError: null,
          sessionSettings: settings,
          sessionUsage: null,
          sessionSettingsLoading: false,
          status: app_state.ConnectionStatus.sessionReady,
          activeSessionSettingsLoadId: null,
          inputBudget: budget,
        );

        final desired = view(<ChatMessage>[
          plan(replacementText),
          ChatMessage(role: ChatMessageRole.user, text: 'u'),
        ]);
        final budget = acp.AcpInputBudget(
          maxTurnRetainedBytes: 4096,
          maxTimelineBytes: 4096,
          maxUiStateBytes: desired.retainedBytes - 1,
        );
        final controller = ChatController(
          client: fake,
          cwd: '/workspace',
          inputBudget: budget,
        );
        addTearDown(controller.dispose);
        controller.restoreArchivedSessionLocally(
          view(<ChatMessage>[plan(oldText)], budget: budget),
        );
        await controller.sendPrompt('u');
        final observed = <AgentEvent>[];
        controller.addAgentEventObserver((_, event) => observed.add(event));

        fake.emit(
          AgentEvent(
            type: AgentEventType.status,
            text: replacementText,
            metadata: planMetadata,
          ),
        );

        expect(controller.messages.map((message) => message.text), [
          oldText,
          'u',
        ]);
        expect(
          controller.messages.where(
            (message) => message.omissions.any(
              (omission) => omission.resource == 'timeline history',
            ),
          ),
          isEmpty,
        );
        expect(
          controller.debugUiStateRetainedBytes,
          lessThanOrEqualTo(budget.maxUiStateBytes),
        );
        expect(observed.single.text, isEmpty);
        expect(observed.single.metadata, isEmpty);
        expect(observed.single.toString(), isNot(contains(replacementText)));
        expect(
          observed.single.omissions.where(
            (omission) => omission.resource == 'UI state retained bytes',
          ),
          hasLength(1),
        );
      },
    );

    test('current-only append and replace reject retained-byte plus one', () {
      final session = AgentSession(
        id: 'current-only-mutations',
        cwd: '/workspace',
        createdAt: DateTime(2026, 7, 13, 14),
      );

      ArchivedSessionSnapshot snapshot(acp.AcpInputBudget budget) =>
          ArchivedSessionSnapshot(
            session: session,
            wasCurrent: true,
            messages: const <ChatMessage>[],
            availableCommands: const <Map<String, Object?>>[],
            lastLatency: null,
            lastError: null,
            sessionSettings: const AcpSessionSettings(),
            sessionUsage: null,
            sessionSettingsLoading: false,
            status: app_state.ConnectionStatus.sessionReady,
            activeSessionSettingsLoadId: null,
            inputBudget: budget,
          );

      ChatController build(acp.AcpInputBudget budget) {
        final controller = ChatController(
          client: FakeAgentClient(),
          cwd: '/workspace',
          inputBudget: budget,
        );
        addTearDown(controller.dispose);
        controller.restoreArchivedSessionLocally(snapshot(budget));
        return controller;
      }

      const measuringBudget = acp.AcpInputBudget(
        maxTurnRetainedBytes: 2048,
        maxTimelineBytes: 2048,
      );
      final appendMeasuring = build(measuringBudget);
      appendMeasuring.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.assistant, text: ''),
        startsNewTurn: true,
      );
      appendMeasuring.appendTextForTesting('a\n');
      final appendExact = appendMeasuring.debugUiStateRetainedBytes;

      final appendBudget = acp.AcpInputBudget(
        maxTurnRetainedBytes: 2048,
        maxTimelineBytes: 2048,
        maxUiStateBytes: appendExact,
      );
      final appendController = build(appendBudget);
      appendController.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.assistant, text: ''),
        startsNewTurn: true,
      );
      appendController.appendTextForTesting('a\n');
      appendController.appendTextForTesting('b\n');
      expect(appendController.messages.single.text, 'a\n');
      expect(
        appendController.debugUiStateRetainedBytes,
        lessThanOrEqualTo(appendBudget.maxUiStateBytes),
      );

      final replaceMeasuring = build(measuringBudget);
      replaceMeasuring.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.status, text: 'a'),
        startsNewTurn: true,
      );
      expect(
        replaceMeasuring.replaceLastMessageForTesting(
          ChatMessage(role: ChatMessageRole.status, text: 'ab'),
        ),
        isTrue,
      );
      final replaceExact = replaceMeasuring.debugUiStateRetainedBytes;
      final replaceBudget = acp.AcpInputBudget(
        maxTurnRetainedBytes: 2048,
        maxTimelineBytes: 2048,
        maxUiStateBytes: replaceExact - 1,
      );
      final replaceController = build(replaceBudget);
      replaceController.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.status, text: 'a'),
        startsNewTurn: true,
      );
      expect(
        replaceController.replaceLastMessageForTesting(
          ChatMessage(role: ChatMessageRole.status, text: 'ab'),
        ),
        isFalse,
      );
      expect(replaceController.messages.single.text, 'a');
      expect(
        replaceController.debugUiStateRetainedBytes,
        lessThanOrEqualTo(replaceBudget.maxUiStateBytes),
      );
    });

    test('streaming append refreshes active bytes before timeline eviction', () {
      final oldText = List<String>.filled(4000, 'o').join();
      final oldRetained = ChatMessage(
        role: ChatMessageRole.user,
        text: oldText,
      ).retainedBytes;
      final turnBytes = oldRetained + 1025;
      final timelineBytes = turnBytes;
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        inputBudget: acp.AcpInputBudget(
          maxMessageTextBytes: 700,
          maxMarkdownFallbackBytes: 700,
          maxTurnRetainedBytes: turnBytes,
          maxTimelineBytes: timelineBytes,
          maxUiStateBytes: timelineBytes + 4096,
        ),
      );
      addTearDown(controller.dispose);
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.user, text: oldText),
        startsNewTurn: true,
      );
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.assistant, text: ''),
        startsNewTurn: true,
      );

      controller.appendTextForTesting('123456789\n');
      expect(
        controller.messages,
        hasLength(2),
        reason: controller.messages
            .map(
              (message) =>
                  '${message.text.length}:${message.omissions.map((o) => o.resource)}',
            )
            .toString(),
      );
      expect(
        controller.debugActiveTimelineRetainedBytes,
        controller.messages.fold<int>(
          64 + 32 * controller.messages.length,
          (retained, message) => retained + message.retainedBytes,
        ),
      );

      controller.addOmissionForTesting(
        acp.AcpInputOmission(
          reason: acp.AcpInputOmissionReason.invalidStructure,
          resource: 'streaming text',
          truncated: false,
        ),
      );
      expect(
        controller.debugActiveTimelineRetainedBytes,
        controller.messages.fold<int>(
          64 + 32 * controller.messages.length,
          (retained, message) => retained + message.retainedBytes,
        ),
      );
      final overflowChunk = '${List<String>.filled(599, 'x').join()}\n';
      controller.appendTextForTesting(overflowChunk);
      expect(
        controller.messages.where((message) => message.text == oldText),
        isEmpty,
      );
      final current = controller.messages.singleWhere(
        (message) => message.role == ChatMessageRole.assistant,
      );
      expect(current.text, '123456789\n$overflowChunk');
      expect(current.omissions, isNotEmpty);
      expect(
        controller.debugActiveTimelineRetainedBytes,
        controller.messages.fold<int>(
          64 + 32 * controller.messages.length,
          (retained, message) => retained + message.retainedBytes,
        ),
      );
    });

    test('marker reserve evicts another old turn and stays a singleton', () {
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        inputBudget: const acp.AcpInputBudget(maxTimelineItems: 4),
      );
      addTearDown(controller.dispose);
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.user, text: 'oldest'),
        startsNewTurn: true,
      );
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.user, text: 'second oldest'),
        startsNewTurn: true,
      );
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.user, text: 'current one'),
        startsNewTurn: true,
      );
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.assistant, text: 'current two'),
      );
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.status, text: 'current three'),
      );

      expect(controller.messages.map((message) => message.text), <String>[
        '',
        'current one',
        'current two',
        'current three',
      ]);
      expect(
        controller.messages.where(
          (message) => message.omissions.any(
            (omission) => omission.resource == 'timeline history',
          ),
        ),
        hasLength(1),
      );
    });
  });

  test('connect success sets connected status', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.status, app_state.ConnectionStatus.connected);
    expect(controller.lastError, isNull);
  });

  test('connect failure sets error status', () async {
    final controller = ChatController(
      client: FakeAgentClient(connectError: Exception('codex missing')),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('codex missing'));
  });

  test('connect failure survives an error whose toString throws', () async {
    const canary = 'CONNECT_ERROR_SECRET';
    final error = _ThrowingErrorString(canary);
    final controller = ChatController(
      client: FakeAgentClient(connectError: error),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);
    final notifications =
        <({app_state.ConnectionStatus status, String? error})>[];
    controller.addListener(() {
      notifications.add((
        status: controller.status,
        error: controller.lastError,
      ));
    });

    await controller.connect();

    expect(error.toStringCalls, 1);
    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, 'An unexpected error occurred.');
    expect(controller.lastError, isNot(contains(canary)));
    expect(
      notifications,
      contains((
        status: app_state.ConnectionStatus.error,
        error: 'An unexpected error occurred.',
      )),
    );
  });

  test(
    'auth detection protects map keys and values and deduplicates cycles',
    () async {
      const canary = 'MAP_VALUE_SECRET';
      final throwingKey = _ThrowingStringValue('MAP_KEY_SECRET');
      final throwingValue = _ThrowingStringValue(canary);
      final authValue = _StringValue('AUTH_REQUIRED');
      final data = <Object?, Object?>{};
      data[throwingKey] = throwingValue;
      data['self'] = data;
      data['auth'] = authValue;
      final controller = ChatController(
        client: FakeAgentClient(
          createSessionError: _StructuredError(text: 'opaque', data: data),
          authMethods: const [
            {'id': 'browser', 'name': 'Browser sign-in'},
          ],
        ),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      await controller.newSession();

      expect(throwingKey.toStringCalls, 1);
      expect(throwingValue.toStringCalls, 1);
      expect(authValue.toStringCalls, 1);
      expect(controller.status, app_state.ConnectionStatus.error);
      expect(controller.lastError, contains('Authentication required'));
      expect(controller.lastError, contains('Authenticate'));
      expect(controller.lastError, isNot(contains(canary)));
    },
  );

  test('auth detection checks cause before wide data', () async {
    final unrelatedData = _CountingErrorIterable(10000);
    final wrappedAuth = _StructuredError(
      text: 'wrapped',
      data: unrelatedData,
      cause: const _AuthRequiredError(),
    );
    final authController = ChatController(
      client: FakeAgentClient(
        connectError: wrappedAuth,
        authMethods: const [
          {'id': 'browser', 'name': 'Browser sign-in'},
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(authController.dispose);

    await authController.connect();

    expect(authController.lastError, contains('Authentication required'));
    expect(unrelatedData.yielded, lessThan(1000));
  });

  test('auth detection does not loop on a recursive self cause', () async {
    final recursive = _RecursiveSelfCauseError();
    final recursiveController = ChatController(
      client: FakeAgentClient(connectError: recursive),
      cwd: '/workspace',
    );
    addTearDown(recursiveController.dispose);

    await recursiveController.connect();

    expect(recursive.toStringCalls, 2);
    expect(recursiveController.status, app_state.ConnectionStatus.error);
    expect(recursiveController.lastError, 'An unexpected error occurred.');
  });

  test('auth detection checks data fairly beside a wide cause', () async {
    final unrelatedCause = _CountingErrorIterable(10000);
    final controller = ChatController(
      client: FakeAgentClient(
        createSessionError: _StructuredError(
          text: 'opaque',
          cause: unrelatedCause,
          data: const <String, Object?>{'code': 'auth_required'},
        ),
        authMethods: const [
          {'id': 'browser', 'name': 'Browser sign-in'},
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('Authentication required'));
    expect(controller.lastError, contains('Authenticate'));
    expect(unrelatedCause.yielded, lessThan(1000));
  });

  test('one wide cause string cannot consume the data scan budget', () async {
    final wideCause = List<String>.filled(100000, 'x').join();
    final controller = ChatController(
      client: FakeAgentClient(
        createSessionError: _StructuredError(
          text: 'opaque',
          cause: wideCause,
          data: const <String, Object?>{'code': 'auth_required'},
        ),
        authMethods: const [
          {'id': 'browser', 'name': 'Browser sign-in'},
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('Authentication required'));
    expect(controller.lastError, contains('Authenticate'));
  });

  test('auth detection bounds scanning of a single oversized string', () async {
    final oversized = '${List<String>.filled(100000, 'x').join()}auth_required';
    final controller = ChatController(
      client: FakeAgentClient(
        connectError: _StructuredError(
          text: 'oversized error',
          data: oversized,
        ),
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, 'oversized error');
  });

  test('auth detection counts pre-rendered error text only once', () async {
    final errorText = List<String>.filled(40000, 'x').join();
    final controller = ChatController(
      client: FakeAgentClient(
        createSessionError: _StructuredError(
          text: errorText,
          data: 'auth_required',
        ),
        authMethods: const [
          {'id': 'browser', 'name': 'Browser sign-in'},
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('Authentication required'));
    expect(controller.lastError, contains('Authenticate'));
  });

  test('auth detection applies depth and node traversal limits', () async {
    Object? deep = 'auth_required';
    for (var index = 0; index < 64; index += 1) {
      deep = <Object?>[deep];
    }
    final deepController = ChatController(
      client: FakeAgentClient(
        connectError: _StructuredError(text: 'deep error', data: deep),
      ),
      cwd: '/workspace',
    );
    addTearDown(deepController.dispose);

    await deepController.connect();

    expect(deepController.lastError, 'deep error');

    final iterable = _CountingErrorIterable(10000);
    final wideController = ChatController(
      client: FakeAgentClient(
        connectError: _StructuredError(text: 'wide error', data: iterable),
      ),
      cwd: '/workspace',
    );
    addTearDown(wideController.dispose);

    await wideController.connect();

    expect(wideController.lastError, 'wide error');
    expect(iterable.yielded, lessThan(1000));
  });

  test('reconnect failure clears stale capabilities', () async {
    final fake = _FailingReconnectAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.capabilities, isNotNull);
    expect(controller.canLogout, isTrue);

    await controller.reconnect();

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.capabilities, isNull);
    expect(controller.canLogout, isFalse);
    expect(controller.lastError, contains('connection dropped'));
  });

  test('reconnect accepts reused session setup permissions', () async {
    final fake = _ReusedSessionSetupPermissionAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    expect(controller.currentSession?.id, 'reused-session');

    await controller.closeCurrentSession();
    expect(controller.currentSession, isNull);

    await controller.reconnect();
    await controller.newSession();
    await pumpEventQueue();

    expect(controller.currentSession?.id, 'reused-session');
    expect(controller.pendingPermissionRequest?.id, 'permission-reused-2');
    expect(fake.lastPermissionRequestId, isNull);
  });

  test('create session success sets current session', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.currentSession?.id, 'fake-session-1');
    expect(controller.currentSession?.agentName, 'Codex');
    expect(controller.sessions, hasLength(1));
    expect(controller.sessionSettings.configOptions.single.id, 'approval');
    expect(controller.sessionSettings.modes.currentModeId, isNull);
  });

  test('create session accepts cwd override', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession(cwd: '/other/project');

    expect(controller.currentSession?.cwd, '/other/project');
    expect(controller.sessions.single.cwd, '/other/project');
  });

  test('usage updates set session usage without timeline messages', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        createSessionEvents: const [
          AgentEvent(
            type: AgentEventType.status,
            text: 'Context 26%',
            metadata: <String, Object?>{
              'kind': 'usage_update',
              'used': 53000,
              'size': 200000,
              'cost': <String, Object?>{'amount': 0.045, 'currency': 'USD'},
            },
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    expect(controller.messages, isEmpty);
    expect(controller.sessionUsage?.used, 53000);
    expect(controller.sessionUsage?.size, 200000);
    expect(controller.sessionUsage?.percentage, closeTo(0.265, 0.0001));
    expect(controller.sessionUsage?.cost?.amount, 0.045);
    expect(controller.sessionUsage?.cost?.currency, 'USD');
  });

  test('new session preserves initial error events', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        createSessionEvents: const [
          AgentEvent(type: AgentEventType.error, text: 'session setup failed'),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    final created = await controller.newSession();

    expect(created, isFalse);
    expect(controller.currentSession?.id, 'fake-session-1');
    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('session setup failed'));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.error,
    ]);
  });

  test(
    'send prompt stops when automatic session setup emits an error',
    () async {
      final fake = FakeAgentClient(
        createSessionEvents: const [
          AgentEvent(type: AgentEventType.error, text: 'session setup failed'),
        ],
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.sendPrompt('Hi');

      expect(fake.lastPrompt, isNull);
      expect(controller.currentSession?.id, 'fake-session-1');
      expect(controller.status, app_state.ConnectionStatus.error);
      expect(controller.lastError, contains('session setup failed'));
      expect(controller.messages.map((message) => message.role), [
        ChatMessageRole.error,
      ]);
    },
  );

  test('created sessions keep selected agent name', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
      agentName: 'Kimi Code Dev',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    expect(controller.currentSession?.agentName, 'Kimi Code Dev');
    expect(controller.sessions.single.agentName, 'Kimi Code Dev');
  });

  test('new sessions append to sidebar history', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.newSession();

    expect(controller.currentSession?.id, 'fake-session-2');
    expect(controller.sessions.map((session) => session.id), [
      'fake-session-2',
      'fake-session-1',
    ]);
  });

  test(
    'concurrent new session requests are ignored while one is running',
    () async {
      final fake = FakeAgentClient(
        createSessionDelay: const Duration(milliseconds: 20),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      final first = controller.newSession();
      final second = controller.newSession();
      final results = await Future.wait([first, second]);

      expect(fake.sessionCount, 1);
      expect(controller.sessions, hasLength(1));
      expect(controller.isSessionOperationRunning, isFalse);
      expect(results, containsAll(<bool>[true, false]));
    },
  );

  test('dispose during pending connect ignores late notifications', () async {
    final controller = ChatController(
      client: FakeAgentClient(connectDelay: const Duration(milliseconds: 20)),
      cwd: '/workspace',
    );

    final pendingConnect = controller.connect();
    await pumpEventQueue();
    expect(controller.isSessionOperationRunning, isTrue);

    controller.dispose();
    await pendingConnect;
  });

  test('dispose ignores asynchronous cleanup errors', () async {
    final errors = <Object>[];

    final zoneDone = runZonedGuarded<Future<void>>(
      () async {
        final controller = ChatController(
          client: _FailingDisposeAgentClient(),
          cwd: '/workspace',
        );

        await controller.connect();
        controller.dispose();
        await controller.disposalComplete;
      },
      (error, stackTrace) {
        errors.add(error);
      },
    );
    if (zoneDone != null) {
      await zoneDone;
    }

    expect(errors, isEmpty);
  });

  test('list sessions keeps session operation lock while loading', () async {
    final fake = FakeAgentClient(
      listSessionsDelay: const Duration(milliseconds: 20),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();
    final loading = controller.listSessions();
    await pumpEventQueue();

    expect(controller.isSessionOperationRunning, isTrue);

    final projects = await loading;

    expect(projects.single.cwd, '/workspace/project-a');
    expect(controller.isSessionOperationRunning, isFalse);
  });

  test('load session catalog stores listed sessions locally', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);

    await controller.connect();
    final projects = await controller.loadSessionCatalog();

    expect(projects.single.cwd, '/workspace/project-a');
    expect(controller.sessions, hasLength(1));
    expect(controller.sessions.single.id, 'session-a');
    expect(controller.sessions.single.cwd, '/workspace/project-a');
    expect(
      controller.sessions.single.displayTitle,
      'Resume this project conversation',
    );
    expect(controller.sessions.single.agentName, isNull);
    expect(controller.isSessionOperationRunning, isFalse);
  });

  test('load session catalog preserves explicit agent metadata', () async {
    final controller = ChatController(
      client: _AgentNamedCatalogClient(),
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);

    await controller.connect();
    await controller.loadSessionCatalog();

    expect(controller.sessions.single.id, 'session-fast');
    expect(controller.sessions.single.agentName, 'codex-fast');
  });

  test(
    'session catalog preserves active workspace identity while refreshing remote metadata',
    () async {
      final fake = _MutableBindingCatalogClient(
        projects: <AcpProjectSessions>[
          AcpProjectSessions(
            cwd: '/workspace/catalog',
            sessions: <AcpSessionEntry>[
              AcpSessionEntry(
                id: 'bound-session',
                cwd: '/workspace/catalog',
                title: 'Catalog title',
                additionalDirectories: <String>['/workspace/catalog-extra'],
                updatedAt: DateTime(2026, 7, 15, 10),
                meta: <String, Object?>{'agentName': 'Other Agent'},
              ),
            ],
          ),
        ],
      );
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        agentName: 'Codex',
      );
      addTearDown(controller.dispose);

      await controller.resumeSession(
        'bound-session',
        cwd: '/workspace/current',
        additionalDirectories: const ['/workspace/current-extra'],
      );
      await controller.loadSessionCatalog();

      final indexed = controller.sessions.singleWhere(
        (session) => session.id == 'bound-session',
      );
      expect(controller.currentSession?.title, 'Catalog title');
      expect(controller.currentSession?.updatedAt, DateTime(2026, 7, 15, 10));
      expect(indexed.title, 'Catalog title');
      expect(indexed.updatedAt, DateTime(2026, 7, 15, 10));
      expect(
        <String, Object?>{
          'currentCwd': controller.currentSession?.cwd,
          'currentDirectories':
              controller.currentSession?.additionalDirectories,
          'currentAgent': controller.currentSession?.agentName,
          'indexedCwd': indexed.cwd,
          'indexedDirectories': indexed.additionalDirectories,
          'indexedAgent': indexed.agentName,
        },
        <String, Object?>{
          'currentCwd': '/workspace/current',
          'currentDirectories': const ['/workspace/current-extra'],
          'currentAgent': 'Codex',
          'indexedCwd': '/workspace/current',
          'indexedDirectories': const ['/workspace/current-extra'],
          'indexedAgent': 'Codex',
        },
      );
      expect(fake.resumeCalls, 1);
    },
  );

  test(
    'session catalog preserves an empty bound additional directory list',
    () async {
      final fake = _MutableBindingCatalogClient(
        projects: <AcpProjectSessions>[
          AcpProjectSessions(
            cwd: '/workspace/catalog',
            sessions: const <AcpSessionEntry>[
              AcpSessionEntry(
                id: 'empty-directories',
                cwd: '/workspace/catalog',
                title: 'Catalog empty directories',
                additionalDirectories: <String>['/workspace/catalog-extra'],
                meta: <String, Object?>{'agentName': 'Catalog Agent'},
              ),
            ],
          ),
        ],
      );
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        agentName: '',
      );
      addTearDown(controller.dispose);

      await controller.resumeSession(
        'empty-directories',
        cwd: '/workspace/bound',
        additionalDirectories: const <String>[],
      );
      await controller.loadSessionCatalog();

      expect(controller.currentSession?.cwd, '/workspace/bound');
      expect(controller.currentSession?.additionalDirectories, isEmpty);
      expect(controller.currentSession?.agentName, 'Catalog Agent');
      expect(
        controller.sessions
            .singleWhere((session) => session.id == 'empty-directories')
            .additionalDirectories,
        isEmpty,
      );
    },
  );

  test(
    'catalog and resume preserve an inactive snapshot workspace binding',
    () async {
      final originalUpdatedAt = DateTime(2026, 7, 15, 9);
      final fake = _MutableBindingCatalogClient(
        projects: <AcpProjectSessions>[
          AcpProjectSessions(
            cwd: '/workspace/catalog-a',
            sessions: const <AcpSessionEntry>[
              AcpSessionEntry(
                id: 'snapshot-a',
                cwd: '/workspace/catalog-a',
                title: 'Refreshed snapshot title',
                additionalDirectories: <String>['/workspace/catalog-extra'],
                meta: <String, Object?>{'agentName': 'Other Agent'},
              ),
            ],
          ),
        ],
      );
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        agentName: 'Codex',
      );
      addTearDown(controller.dispose);

      await controller.resumeSession(
        'snapshot-a',
        cwd: '/workspace/bound-a',
        additionalDirectories: const <String>['/workspace/bound-extra'],
        updatedAt: originalUpdatedAt,
      );
      await controller.resumeSession('active-b', cwd: '/workspace/b');
      expect(controller.debugInactiveSnapshotIds, contains('snapshot-a'));
      expect(fake.resumeCalls, 2);

      await controller.loadSessionCatalog();

      final indexed = controller.sessions.singleWhere(
        (session) => session.id == 'snapshot-a',
      );
      expect(indexed.cwd, '/workspace/bound-a');
      expect(indexed.additionalDirectories, ['/workspace/bound-extra']);
      expect(indexed.agentName, 'Codex');
      expect(indexed.title, 'Refreshed snapshot title');
      expect(indexed.updatedAt, originalUpdatedAt);

      controller.addMessageForTesting(
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: 'Active B state must survive a rejected resume.',
        ),
        startsNewTurn: true,
      );
      controller.availableCommands = const <Map<String, Object?>>[
        <String, Object?>{'name': 'review-snapshot-conflict'},
      ];
      controller.sessionSettings = _settingsWithMode('edit');
      final statusBeforeConflict = controller.status;
      final messagesBeforeConflict = controller.messages
          .map((message) => message.text)
          .toList(growable: false);
      final turnItemsBeforeConflict = controller.debugCurrentTurnItems;
      final turnBytesBeforeConflict = controller.debugCurrentTurnRetainedBytes;
      final commandsBeforeConflict = controller.availableCommands;
      final settingsBeforeConflict = controller.sessionSettings;
      final snapshotsBeforeConflict = controller.debugInactiveSnapshotIds;

      await controller.resumeSession(
        'snapshot-a',
        cwd: '/workspace/catalog-a',
        additionalDirectories: const <String>['/workspace/catalog-extra'],
      );

      expect(controller.currentSession?.id, 'active-b');
      expect(controller.status, statusBeforeConflict);
      expect(controller.isStreaming, isFalse);
      expect(
        controller.messages.map((message) => message.text),
        messagesBeforeConflict,
      );
      expect(controller.debugCurrentTurnItems, turnItemsBeforeConflict);
      expect(controller.debugCurrentTurnRetainedBytes, turnBytesBeforeConflict);
      expect(controller.availableCommands, commandsBeforeConflict);
      expect(controller.sessionSettings, same(settingsBeforeConflict));
      expect(controller.debugInactiveSnapshotIds, snapshotsBeforeConflict);
      expect(controller.lastError, contains('different workspace'));
      expect(fake.resumeCalls, 2);

      await controller.resumeSession(
        'snapshot-a',
        cwd: '/workspace/bound-a',
        additionalDirectories: const <String>['/workspace/bound-extra'],
      );

      expect(controller.currentSession?.id, 'snapshot-a');
      expect(controller.currentSession?.cwd, '/workspace/bound-a');
      expect(
        controller.debugInactiveSnapshotIds,
        isNot(contains('snapshot-a')),
      );
      expect(fake.resumeCalls, 2);
    },
  );

  test(
    'catalog and resume preserve an archived local unstarted workspace binding',
    () async {
      final fake = _MutableBindingCatalogClient(
        projects: const <AcpProjectSessions>[],
      );
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        agentName: 'Codex',
      );
      addTearDown(controller.dispose);

      await controller.newSession(cwd: '/workspace/local');
      final localSession = controller.currentSession!;
      final archived = controller.archiveSessionLocally(localSession.id)!;
      addTearDown(archived.discard);
      expect(controller.currentSession, isNull);
      expect(controller.debugInactiveSnapshotIds, isEmpty);

      fake.projects = <AcpProjectSessions>[
        AcpProjectSessions(
          cwd: '/workspace/catalog-local',
          sessions: <AcpSessionEntry>[
            AcpSessionEntry(
              id: localSession.id,
              cwd: '/workspace/catalog-local',
              title: 'Refreshed local title',
              additionalDirectories: const <String>['/workspace/catalog-extra'],
              meta: const <String, Object?>{'agentName': 'Other Agent'},
            ),
          ],
        ),
      ];
      await controller.loadSessionCatalog();

      final indexed = controller.sessions.singleWhere(
        (session) => session.id == localSession.id,
      );
      expect(indexed.cwd, '/workspace/local');
      expect(indexed.additionalDirectories, isEmpty);
      expect(indexed.agentName, 'Codex');
      expect(indexed.title, 'Refreshed local title');
      final statusBeforeConflict = controller.status;
      final retainedBytesBeforeConflict = controller.debugUiStateRetainedBytes;
      final sessionsBeforeConflict = controller.sessions
          .map((session) => (session.id, session.cwd, session.archived))
          .toList(growable: false);

      await controller.resumeSession(
        localSession.id,
        cwd: '/workspace/catalog-local',
        additionalDirectories: const <String>['/workspace/catalog-extra'],
      );

      expect(controller.currentSession, isNull);
      expect(controller.status, statusBeforeConflict);
      expect(controller.isStreaming, isFalse);
      expect(controller.messages, isEmpty);
      expect(controller.debugInactiveSnapshotIds, isEmpty);
      expect(controller.debugUiStateRetainedBytes, retainedBytesBeforeConflict);
      expect(
        controller.sessions.map(
          (session) => (session.id, session.cwd, session.archived),
        ),
        sessionsBeforeConflict,
      );
      expect(controller.lastError, contains('different workspace'));
      expect(fake.resumeCalls, 0);

      await controller.resumeSession(
        localSession.id,
        cwd: '/workspace/local',
        additionalDirectories: const <String>[],
      );

      expect(controller.currentSession?.id, localSession.id);
      expect(controller.currentSession?.cwd, '/workspace/local');
      expect(controller.currentSession?.additionalDirectories, isEmpty);
      expect(fake.resumeCalls, 0);
    },
  );

  test(
    'trimmed resume restores a snapshot created with a raw session id',
    () async {
      final fake = _WhitespaceCreatedSessionCatalogClient(
        projects: const <AcpProjectSessions>[],
      );
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        agentName: 'Codex',
      );
      addTearDown(controller.dispose);

      await controller.newSession(cwd: '/workspace/raw-snapshot');
      controller.addMessageForTesting(
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: 'Raw snapshot history',
        ),
        startsNewTurn: true,
      );
      await controller.resumeSession('active-b', cwd: '/workspace/b');
      expect(
        controller.debugInactiveSnapshotIds.map((id) => id.trim()),
        contains('raw-session'),
      );
      expect(fake.resumeCalls, 1);

      await controller.resumeSession('raw-session');

      expect(fake.resumeCalls, 1);
      expect(controller.currentSession?.id.trim(), 'raw-session');
      expect(controller.currentSession?.cwd, '/workspace/raw-snapshot');
      expect(
        controller.debugInactiveSnapshotIds.map((id) => id.trim()),
        contains('active-b'),
      );
      expect(
        controller.debugInactiveSnapshotIds.map((id) => id.trim()),
        isNot(contains('raw-session')),
      );
      expect(
        controller.messages.map((message) => message.text),
        contains('Raw snapshot history'),
      );
    },
  );

  test(
    'trimmed resume restores a raw local unstarted session without ACP resume',
    () async {
      final fake = _WhitespaceCreatedSessionCatalogClient(
        projects: const <AcpProjectSessions>[],
      );
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        agentName: 'Codex',
      );
      addTearDown(controller.dispose);

      await controller.newSession(cwd: '/workspace/raw-local');
      final rawSession = controller.currentSession!;
      final archived = controller.archiveSessionLocally(rawSession.id)!;
      addTearDown(archived.discard);
      expect(controller.currentSession, isNull);

      await controller.resumeSession('raw-session');

      expect(fake.resumeCalls, 0);
      expect(controller.currentSession?.id.trim(), 'raw-session');
      expect(controller.currentSession?.cwd, '/workspace/raw-local');
      expect(controller.messages, isEmpty);
    },
  );

  test('catalog merge deduplicates a raw bound session id', () async {
    final fake = _WhitespaceCreatedSessionCatalogClient(
      projects: const <AcpProjectSessions>[],
    );
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);

    await controller.newSession(cwd: '/workspace/raw-bound');
    final archived = controller.archiveSessionLocally(
      controller.currentSession!.id,
    )!;
    addTearDown(archived.discard);
    fake.projects = <AcpProjectSessions>[
      AcpProjectSessions(
        cwd: '/workspace/catalog',
        sessions: const <AcpSessionEntry>[
          AcpSessionEntry(
            id: 'raw-session',
            cwd: '/workspace/catalog',
            title: 'Catalog raw session',
            meta: <String, Object?>{'agentName': 'Other Agent'},
          ),
        ],
      ),
    ];

    await controller.loadSessionCatalog();

    final matching = controller.sessions
        .where((session) => session.id.trim() == 'raw-session')
        .toList(growable: false);
    expect(matching, hasLength(1));
    expect(matching.single.cwd, '/workspace/raw-bound');
    expect(matching.single.agentName, 'Codex');
    expect(matching.single.title, 'Catalog raw session');
  });

  test('pure catalog candidates refresh their workspace and agent', () async {
    final fake = _MutableBindingCatalogClient(
      projects: <AcpProjectSessions>[
        AcpProjectSessions(
          cwd: '/workspace/first',
          sessions: const <AcpSessionEntry>[
            AcpSessionEntry(
              id: 'catalog-only',
              cwd: '/workspace/first',
              title: 'First catalog title',
              additionalDirectories: <String>['/workspace/first-extra'],
              meta: <String, Object?>{'agentName': 'First Agent'},
            ),
          ],
        ),
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.loadSessionCatalog();
    fake.projects = <AcpProjectSessions>[
      AcpProjectSessions(
        cwd: '/workspace/second',
        sessions: const <AcpSessionEntry>[
          AcpSessionEntry(
            id: 'catalog-only',
            cwd: '/workspace/second',
            title: 'Second catalog title',
            additionalDirectories: <String>['/workspace/second-extra'],
            meta: <String, Object?>{'agentName': 'Second Agent'},
          ),
        ],
      ),
    ];
    await controller.loadSessionCatalog();

    final candidate = controller.sessions.single;
    expect(candidate.cwd, '/workspace/second');
    expect(candidate.additionalDirectories, ['/workspace/second-extra']);
    expect(candidate.agentName, 'Second Agent');
  });

  test('merge session index restores local sidebar metadata', () {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);

    controller.mergeSessionIndex([
      AgentSession(
        id: 'indexed-session',
        cwd: '/workspace/project',
        createdAt: DateTime(2026, 7, 1, 9),
        title: 'Indexed workspace session',
        titleOverride: 'Renamed indexed session',
        updatedAt: DateTime(2026, 7, 1, 10),
        agentName: 'Codex',
        pinned: true,
        unread: true,
      ),
    ]);

    expect(controller.sessions, hasLength(1));
    expect(controller.sessions.single.id, 'indexed-session');
    expect(controller.sessions.single.cwd, '/workspace/project');
    expect(controller.sessions.single.displayTitle, 'Renamed indexed session');
    expect(controller.sessions.single.pinned, isTrue);
    expect(controller.sessions.single.unread, isTrue);
  });

  test('restored local unstarted session resumes without ACP load', () async {
    final fake = _MutableBindingCatalogClient(
      projects: const <AcpProjectSessions>[],
    );
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);
    controller.mergeSessionIndex([
      AgentSession(
        id: 'persisted-blank',
        cwd: '/workspace/project',
        createdAt: DateTime(2026, 7, 15, 20, 47),
        agentName: 'Codex',
        localUnstarted: true,
      ),
    ]);

    await controller.resumeSession('persisted-blank');

    expect(fake.resumeCalls, 0);
    expect(controller.currentSession?.id, 'persisted-blank');
    expect(controller.currentSession?.cwd, '/workspace/project');
    expect(controller.messages, isEmpty);
    expect(controller.lastError, isNull);
    expect(controller.status, app_state.ConnectionStatus.sessionReady);
  });

  test(
    'merge session index preserves an established empty additional directory binding',
    () {
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        agentName: 'Codex',
      );
      addTearDown(controller.dispose);
      final current = AgentSession(
        id: 'active-session',
        cwd: '/workspace/project',
        createdAt: DateTime(2026, 7, 1, 9),
        additionalDirectories: const <String>[],
        agentName: 'Codex',
      );
      controller.currentSession = current;
      controller.sessions.add(current);

      controller.mergeSessionIndex([
        AgentSession(
          id: 'active-session',
          cwd: '/workspace/project',
          createdAt: DateTime(2026, 7, 1, 9),
          additionalDirectories: const <String>['/workspace/stale-extra'],
          agentName: 'Codex',
        ),
      ]);

      expect(controller.currentSession?.additionalDirectories, isEmpty);
      expect(controller.sessions.single.additionalDirectories, isEmpty);
    },
  );

  test('merge session index does not archive the current session', () {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);
    final current = AgentSession(
      id: 'active-session',
      cwd: '/workspace/project',
      createdAt: DateTime(2026, 7, 1, 9),
      title: 'Runtime title',
      updatedAt: DateTime(2026, 7, 2, 9),
      agentName: 'Codex',
    );
    controller.currentSession = current;
    controller.sessions.add(current);

    controller.mergeSessionIndex([
      AgentSession(
        id: 'active-session',
        cwd: '/workspace/project',
        createdAt: DateTime(2026, 7, 1, 9),
        title: 'Stale indexed title',
        titleOverride: 'Local title',
        updatedAt: DateTime(2026, 7, 1, 10),
        agentName: 'Codex',
        pinned: true,
        archived: true,
        unread: true,
      ),
    ]);

    expect(controller.currentSession?.title, 'Runtime title');
    expect(controller.currentSession?.displayTitle, 'Local title');
    expect(controller.currentSession?.pinned, isTrue);
    expect(controller.currentSession?.archived, isFalse);
    expect(controller.currentSession?.unread, isFalse);
    expect(controller.currentSession?.updatedAt, DateTime(2026, 7, 2, 9));
  });

  test('local session menu metadata updates sessions and current session', () {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);
    final session = AgentSession(
      id: 'session-a',
      cwd: '/workspace/project',
      createdAt: DateTime(2026, 7, 1, 9),
      title: 'Agent title',
      agentName: 'Codex',
    );
    controller.currentSession = session;
    controller.sessions.add(session);

    controller.renameSession('session-a', 'Local title');
    controller.setSessionPinned('session-a', true);
    controller.setSessionUnread('session-a', true);
    controller.setSessionArchived('session-a', true);

    expect(controller.currentSession?.displayTitle, 'Local title');
    expect(controller.sessions.single.pinned, isTrue);
    expect(controller.sessions.single.unread, isTrue);
    expect(controller.sessions.single.archived, isTrue);
  });

  test('local archive detaches and restores the current session', () {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);
    final session = AgentSession(
      id: 'session-a',
      cwd: '/workspace/project',
      createdAt: DateTime(2026, 7, 1, 9),
      title: 'Agent title',
      agentName: 'Codex',
      unread: true,
    );
    controller.currentSession = session;
    controller.sessions.add(session);
    controller.addMessageForTesting(
      ChatMessage(role: ChatMessageRole.assistant, text: 'Existing reply'),
      startsNewTurn: true,
    );
    controller.status = app_state.ConnectionStatus.sessionReady;

    final snapshot = controller.archiveSessionLocally('session-a');

    expect(snapshot, isNotNull);
    expect(controller.currentSession, isNull);
    expect(controller.messages, isEmpty);
    expect(controller.status, app_state.ConnectionStatus.connected);
    expect(controller.sessions.single.archived, isTrue);
    expect(controller.sessions.single.unread, isFalse);

    controller.restoreArchivedSessionLocally(snapshot!);

    expect(controller.currentSession?.id, 'session-a');
    expect(controller.currentSession?.archived, isFalse);
    expect(controller.sessions.single.archived, isFalse);
    expect(controller.sessions.single.unread, isTrue);
    expect(controller.messages.single.text, 'Existing reply');
    expect(controller.status, app_state.ConnectionStatus.sessionReady);
  });

  test('public archive snapshot owns deeply immutable frozen state', () {
    final directories = <String>['/workspace/shared'];
    final sourceMessage = ChatMessage(
      role: ChatMessageRole.assistant,
      text: 'original',
      metadata: const <String, Object?>{
        'nested': <String, Object?>{
          'items': <Object?>['safe'],
        },
      },
    );
    final commandPayload = <Object?>['safe'];
    final commands = <Map<String, Object?>>[
      <String, Object?>{'name': 'review', 'payload': commandPayload},
    ];
    final modes = <AcpSessionMode>[
      const AcpSessionMode(id: 'ask', name: 'Ask'),
    ];
    final choices = <AcpConfigOptionChoice>[
      const AcpConfigOptionChoice(value: 'on', name: 'On'),
    ];
    final options = <AcpConfigOption>[
      AcpConfigOption(
        id: 'approval',
        name: 'Approval',
        type: 'select',
        currentValue: 'on',
        options: choices,
      ),
    ];
    final settings = AcpSessionSettings(
      modes: AcpSessionModeInfo(currentModeId: 'ask', availableModes: modes),
      configOptions: options,
    );
    final snapshot = ArchivedSessionSnapshot(
      session: AgentSession(
        id: 'session-a',
        cwd: '/workspace',
        createdAt: DateTime(2026, 7, 12, 10),
        additionalDirectories: directories,
      ),
      wasCurrent: true,
      messages: <ChatMessage>[sourceMessage],
      availableCommands: commands,
      lastLatency: const Duration(milliseconds: 10),
      lastError: null,
      sessionSettings: settings,
      sessionUsage: null,
      sessionSettingsLoading: false,
      status: app_state.ConnectionStatus.sessionReady,
      activeSessionSettingsLoadId: 7,
    );
    final retained = snapshot.retainedBytes;

    sourceMessage.text = 'changed';
    commandPayload.add('changed');
    commands.clear();
    directories.clear();
    modes.clear();
    choices.clear();
    options.clear();

    expect(snapshot.messages.single.text, 'original');
    expect(() => snapshot.messages.single.text = 'no', throwsStateError);
    expect(snapshot.availableCommands.single['name'], 'review');
    expect(snapshot.availableCommands.single['payload'], ['safe']);
    expect(snapshot.session.additionalDirectories, ['/workspace/shared']);
    expect(snapshot.sessionSettings.modes.availableModes.single.id, 'ask');
    expect(
      snapshot.sessionSettings.configOptions.single.options.single.value,
      'on',
    );
    expect(snapshot.retainedBytes, retained);
    expect(() => snapshot.messages.clear(), throwsUnsupportedError);
    expect(() => snapshot.availableCommands.clear(), throwsUnsupportedError);
    expect(
      () => (snapshot.availableCommands.single['payload']! as List<Object?>)
          .add('no'),
      throwsUnsupportedError,
    );
    expect(
      () => snapshot.sessionSettings.modes.availableModes.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => snapshot.sessionSettings.configOptions.single.options.clear(),
      throwsUnsupportedError,
    );
  });

  test('archive snapshot remains subclass-compatible and defensive', () {
    final source = ChatMessage(
      role: ChatMessageRole.assistant,
      text: 'subclass original',
    );
    final messages = <ChatMessage>[source];

    final snapshot = _ArchivedSessionSnapshotSubclass(messages: messages);
    source.text = 'source changed';
    messages.clear();

    expect(snapshot.messages, hasLength(1));
    expect(snapshot.messages.single.text, 'subclass original');
    expect(snapshot.messages.single, isNot(same(source)));
    expect(() => snapshot.messages.single.text = 'no', throwsStateError);
  });

  test(
    'restore reapplies the receiving controller input budget to messages',
    () {
      final source = ChatMessage(
        role: ChatMessageRole.assistant,
        text: 'wide original',
        metadata: const <String, Object?>{'first': 'a', 'second': 'b'},
        omissions: <acp.AcpInputOmission>[
          acp.AcpInputOmission(
            reason: acp.AcpInputOmissionReason.invalidStructure,
            resource: 'first original omission',
            truncated: false,
          ),
          acp.AcpInputOmission(
            reason: acp.AcpInputOmissionReason.invalidEncoding,
            resource: 'second original omission',
            truncated: false,
          ),
        ],
      );
      final archived = ArchivedSessionSnapshot(
        session: AgentSession(
          id: 'rebudgeted-session',
          cwd: '/workspace',
          createdAt: DateTime(2026, 7, 13, 12),
        ),
        wasCurrent: true,
        messages: <ChatMessage>[source],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: const AcpSessionSettings(),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
      );
      final archivedRetained = archived.messages.single.retainedBytes;
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        inputBudget: const acp.AcpInputBudget(
          maxMetadataEntries: 1,
          maxCollectionItems: 3,
        ),
      );
      addTearDown(controller.dispose);

      controller.restoreArchivedSessionLocally(archived);

      final active = controller.messages.single;
      expect(archived.messages.single.metadata, <String, Object?>{
        'first': 'a',
        'second': 'b',
      });
      expect(archived.messages.single.omissions, hasLength(2));
      expect(archived.messages.single.text, 'wide original');
      expect(archived.messages.single.retainedBytes, archivedRetained);
      expect(active, isNot(same(archived.messages.single)));
      expect(active.metadata, isEmpty);
      expect(active.omissions, hasLength(3));
      expect(active.omissions.first.resource, 'first original omission');
      expect(
        active.omissions.map((omission) => omission.resource),
        contains('chat message metadata'),
      );
      expect(
        active.omissions
            .singleWhere(
              (omission) => omission.resource == 'chat message metadata',
            )
            .reason,
        acp.AcpInputOmissionReason.inputLimit,
      );
      expect(
        active.omissions.map((omission) => omission.resource),
        contains('second original omission'),
      );
      final activeRetained = active.retainedBytes;
      controller.setLastMessageTextForTesting('${active.text}!');
      expect(active.retainedBytes, greaterThan(activeRetained));
      expect(archived.messages.single.text, 'wide original');
      expect(archived.messages.single.retainedBytes, archivedRetained);
    },
  );

  test('restore reapplies target text byte and thought budgets', () {
    final high = String.fromCharCode(0xd83d);
    final archived = ArchivedSessionSnapshot(
      session: AgentSession(
        id: 'rebudgeted-text-session',
        cwd: '/workspace',
        createdAt: DateTime(2026, 7, 13, 13),
      ),
      wasCurrent: true,
      messages: <ChatMessage>[
        ChatMessage(role: ChatMessageRole.assistant, text: 'abcd'),
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: 'abcde',
          metadata: const <String, Object?>{'first': 'a', 'second': 'b'},
          omissions: <acp.AcpInputOmission>[
            acp.AcpInputOmission(
              reason: acp.AcpInputOmissionReason.invalidStructure,
              resource: 'trusted original omission',
              truncated: false,
            ),
          ],
        ),
        ChatMessage(role: ChatMessageRole.assistant, text: high),
        ChatMessage(
          role: ChatMessageRole.status,
          text: 'abc',
          metadata: const <String, Object?>{'kind': 'thought'},
        ),
      ],
      availableCommands: const <Map<String, Object?>>[],
      lastLatency: null,
      lastError: null,
      sessionSettings: const AcpSessionSettings(),
      sessionUsage: null,
      sessionSettingsLoading: false,
      status: app_state.ConnectionStatus.sessionReady,
      activeSessionSettingsLoadId: null,
    );
    final archivedTexts = archived.messages
        .map((message) => message.text)
        .toList(growable: false);
    final archivedRetained = archived.messages
        .map((message) => message.retainedBytes)
        .toList(growable: false);
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
      inputBudget: const acp.AcpInputBudget(
        maxMessageTextBytes: 4,
        maxThoughtTextBytes: 2,
        maxMarkdownFallbackBytes: 4,
        maxMetadataEntries: 1,
        maxCollectionItems: 3,
      ),
    );
    addTearDown(controller.dispose);

    controller.restoreArchivedSessionLocally(archived);

    final exact = controller.messages[0];
    final overflow = controller.messages[1];
    final pending = controller.messages[2];
    final thought = controller.messages[3];
    expect(exact.text, 'abcd');
    expect(exact.acceptedUtf8Bytes, 4);
    expect(
      exact.omissions.map((omission) => omission.resource),
      isNot(contains('message text')),
    );
    expect(overflow.text, 'abcd');
    expect(overflow.acceptedUtf8Bytes, 4);
    expect(overflow.metadata, isEmpty);
    expect(overflow.omissions, hasLength(3));
    expect(overflow.omissions.first.resource, 'trusted original omission');
    expect(overflow.omissions.map((omission) => omission.resource), <String>[
      'trusted original omission',
      'message text',
      'chat message metadata',
    ]);
    expect(pending.text, high);
    expect(pending.acceptedUtf8Bytes, 3);
    expect(thought.text, 'ab');
    expect(thought.acceptedUtf8Bytes, 2);
    expect(thought.omissions.single.resource, 'thought text');
    final overflowRetained = overflow.retainedBytes;
    controller.setMessageTextForTesting(1, '${overflow.text}!');
    expect(overflow.retainedBytes, greaterThan(overflowRetained));
    expect(archived.messages.map((message) => message.text), archivedTexts);
    expect(
      archived.messages.map((message) => message.retainedBytes),
      archivedRetained,
    );
    expect(archived.messages[1].metadata, hasLength(2));
    expect(archived.messages[1].omissions, hasLength(1));
  });

  test('restore reads wasCurrent before any observable mutation', () {
    const canary = 'SECRET_WAS_CURRENT_CANARY';
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);
    final activeSession = AgentSession(
      id: 'active-before-restore',
      cwd: '/workspace',
      createdAt: DateTime(2026, 7, 13, 14),
    );
    controller.currentSession = activeSession;
    controller.sessions.add(activeSession);
    controller.addMessageForTesting(
      ChatMessage(role: ChatMessageRole.assistant, text: 'active untouched'),
      startsNewTurn: true,
    );
    final hostile = _ThrowingWasCurrentArchivedSnapshot(canary: canary);

    expect(
      () => controller.restoreArchivedSessionLocally(hostile),
      throwsA(
        isA<StateError>().having((error) => error.message, 'message', canary),
      ),
    );

    expect(hostile.wasCurrentReads, 1);
    expect(controller.currentSession, same(activeSession));
    expect(controller.sessions, <AgentSession>[activeSession]);
    expect(controller.messages.single.text, 'active untouched');
    expect(controller.lastError, isNull);
    expect(
      controller.sessions.map((session) => session.id),
      isNot(contains('hostile-was-current')),
    );
  });

  test('restore reads a stateful wasCurrent getter exactly once', () {
    final snapshot = _StatefulWasCurrentArchivedSnapshot();
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    controller.restoreArchivedSessionLocally(snapshot);

    expect(snapshot.wasCurrentReads, 1);
    expect(controller.currentSession?.id, 'stateful-was-current');
  });

  test(
    'snapshot commands and settings fail safe without stringifying payloads',
    () {
      final canary = _CanaryPayload();
      final hostileModes = _ThrowingReadList<AcpSessionMode>();
      final snapshot = ArchivedSessionSnapshot(
        session: AgentSession(
          id: 'session-hostile',
          cwd: '/workspace',
          createdAt: DateTime(2026, 7, 12, 11),
        ),
        wasCurrent: false,
        messages: const <ChatMessage>[],
        availableCommands: <Map<String, Object?>>[
          <String, Object?>{'name': 'unsafe', 'payload': canary},
        ],
        lastLatency: null,
        lastError: null,
        sessionSettings: AcpSessionSettings(
          modes: AcpSessionModeInfo(availableModes: hostileModes),
          configOptions: const <AcpConfigOption>[
            AcpConfigOption(
              id: 'partial',
              name: 'Must not survive',
              type: 'boolean',
              currentValue: 'true',
              options: <AcpConfigOptionChoice>[],
            ),
          ],
        ),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
      );

      expect(snapshot.availableCommands, isEmpty);
      expect(snapshot.sessionSettings.modes.availableModes, isEmpty);
      expect(snapshot.sessionSettings.configOptions, isEmpty);
      expect(canary.toStringCalls, 0);

      final hostileOptions = _ThrowingReadList<AcpConfigOption>();
      final optionsSnapshot = ArchivedSessionSnapshot(
        session: AgentSession(
          id: 'session-hostile-options',
          cwd: '/workspace',
          createdAt: DateTime(2026, 7, 12, 11),
        ),
        wasCurrent: false,
        messages: const <ChatMessage>[],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: AcpSessionSettings(
          modes: const AcpSessionModeInfo(
            currentModeId: 'ask',
            availableModes: <AcpSessionMode>[
              AcpSessionMode(id: 'ask', name: 'Must not survive'),
            ],
          ),
          configOptions: hostileOptions,
        ),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
      );
      expect(optionsSnapshot.sessionSettings.modes.availableModes, isEmpty);
      expect(optionsSnapshot.sessionSettings.configOptions, isEmpty);
    },
  );

  test('snapshot settings budget counts only dynamic option strings', () {
    final snapshot = ArchivedSessionSnapshot(
      session: AgentSession(
        id: 'a',
        cwd: 'b',
        createdAt: DateTime(2026, 7, 13, 9),
      ),
      wasCurrent: false,
      messages: const <ChatMessage>[],
      availableCommands: const <Map<String, Object?>>[],
      lastLatency: null,
      lastError: null,
      sessionSettings: const AcpSessionSettings(
        configOptions: <AcpConfigOption>[
          AcpConfigOption(
            id: 'i',
            name: 'n',
            type: 't',
            currentValue: 'v',
            options: <AcpConfigOptionChoice>[],
          ),
        ],
      ),
      sessionUsage: null,
      sessionSettingsLoading: false,
      status: app_state.ConnectionStatus.sessionReady,
      activeSessionSettingsLoadId: null,
      inputBudget: const acp.AcpInputBudget(maxStructuredStringBytes: 1),
    );

    expect(snapshot.sessionSettings.configOptions, hasLength(1));
    expect(snapshot.sessionSettings.configOptions.single.id, 'i');
    expect(snapshot.sessionSettings.configOptions.single.name, 'n');
    expect(snapshot.sessionSettings.configOptions.single.type, 't');
    expect(snapshot.sessionSettings.configOptions.single.currentValue, 'v');
  });

  test('snapshot settings typed scalars share one root byte budget', () {
    final omission = acp.AcpInputOmission(
      reason: acp.AcpInputOmissionReason.inputLimit,
      resource: 'r',
      truncated: true,
      limit: 1,
      observedAtLeast: 2,
    );

    ArchivedSessionSnapshot snapshot(int maxBytes) {
      return ArchivedSessionSnapshot(
        session: AgentSession(
          id: 'a',
          cwd: 'b',
          createdAt: DateTime(2026, 7, 13, 9, 30),
        ),
        wasCurrent: false,
        messages: const <ChatMessage>[],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: AcpSessionSettings(
          omissions: <acp.AcpInputOmission>[omission],
          truncated: true,
        ),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
        inputBudget: acp.AcpInputBudget(maxStructuredUpdateBytes: maxBytes),
      );
    }

    final exact = snapshot(11);
    final overflow = snapshot(10);

    expect(exact.sessionSettings.omissions, hasLength(1));
    expect(exact.sessionSettings.truncated, isTrue);
    expect(overflow.sessionSettings.omissions, isEmpty);
    expect(overflow.sessionSettings.truncated, isFalse);
  });

  test('stateful settings collection lengths fail closed without partials', () {
    const canary = 'SECRET_SETTINGS_LENGTH_CANARY';
    const choice = AcpConfigOptionChoice(value: 'v', name: 'n');
    final option = AcpConfigOption(
      id: 'i',
      name: 'n',
      type: 't',
      currentValue: 'v',
      options: const <AcpConfigOptionChoice>[],
    );

    ArchivedSessionSnapshot snapshot(AcpSessionSettings settings) {
      return ArchivedSessionSnapshot(
        session: AgentSession(
          id: 'a',
          cwd: 'b',
          createdAt: DateTime(2026, 7, 13, 9, 45),
        ),
        wasCurrent: false,
        messages: const <ChatMessage>[],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: settings,
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
      );
    }

    final optionsSnapshot = snapshot(
      AcpSessionSettings(
        modes: const AcpSessionModeInfo(
          availableModes: <AcpSessionMode>[
            AcpSessionMode(id: 'partial', name: 'Must not survive'),
          ],
        ),
        configOptions: _GrowingLengthList<AcpConfigOption>(option, canary),
      ),
    );
    final choicesSnapshot = snapshot(
      AcpSessionSettings(
        modes: const AcpSessionModeInfo(
          availableModes: <AcpSessionMode>[
            AcpSessionMode(id: 'partial', name: 'Must not survive'),
          ],
        ),
        configOptions: <AcpConfigOption>[
          AcpConfigOption(
            id: 'i',
            name: 'n',
            type: 't',
            currentValue: 'v',
            options: _GrowingLengthList<AcpConfigOptionChoice>(choice, canary),
          ),
        ],
      ),
    );

    expect(optionsSnapshot.sessionSettings.modes.availableModes, isEmpty);
    expect(optionsSnapshot.sessionSettings.configOptions, isEmpty);
    expect(choicesSnapshot.sessionSettings.modes.availableModes, isEmpty);
    expect(choicesSnapshot.sessionSettings.configOptions, isEmpty);
    expect(optionsSnapshot.sessionSettings.toString(), isNot(contains(canary)));
    expect(choicesSnapshot.sessionSettings.toString(), isNot(contains(canary)));
  });

  test('initial events share one root byte budget and fail closed', () {
    ArchivedSessionSnapshot snapshot(
      List<AgentEvent> events, {
      int maxBytes = 8,
    }) {
      return ArchivedSessionSnapshot(
        session: AgentSession(
          id: 'a',
          cwd: 'b',
          createdAt: DateTime(2026, 7, 13, 10),
          initialEvents: events,
        ),
        wasCurrent: false,
        messages: const <ChatMessage>[],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: const AcpSessionSettings(),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
        inputBudget: acp.AcpInputBudget(maxStructuredUpdateBytes: maxBytes),
      );
    }

    final exact = snapshot(const <AgentEvent>[
      AgentEvent(type: AgentEventType.status, text: '12345678'),
    ]);
    final overflow = snapshot(const <AgentEvent>[
      AgentEvent(type: AgentEventType.status, text: '12345678'),
      AgentEvent(
        type: AgentEventType.status,
        text: 'abcdefgh',
        metadata: <String, Object?>{'secret': 'SECRET_EVENT_CANARY'},
      ),
    ]);
    final timestamp = DateTime.fromMicrosecondsSinceEpoch(1);
    final timestampExact = snapshot(<AgentEvent>[
      AgentEvent(
        type: AgentEventType.status,
        text: '12345678',
        timestamp: timestamp,
      ),
    ], maxBytes: 9);
    final timestampOverflow = snapshot(<AgentEvent>[
      AgentEvent(
        type: AgentEventType.status,
        text: '12345678',
        timestamp: timestamp,
      ),
    ]);

    expect(exact.session.initialEvents, hasLength(1));
    expect(exact.session.initialEvents.single.text, '12345678');
    expect(overflow.session.initialEvents, isEmpty);
    expect(timestampExact.session.initialEvents.single.timestamp, timestamp);
    expect(timestampOverflow.session.initialEvents, isEmpty);
    expect(
      overflow.session.initialEvents.toString(),
      isNot(contains('SECRET_EVENT_CANARY')),
    );
  });

  test('session snapshot clears directories when initial events fail', () {
    const canary = 'SECRET_EVENT_ROOT_CANARY';
    final snapshot = ArchivedSessionSnapshot(
      session: AgentSession(
        id: 'a',
        cwd: 'b',
        createdAt: DateTime(2026, 7, 13, 10, 30),
        additionalDirectories: const <String>['/safe'],
        initialEvents: const <AgentEvent>[
          AgentEvent(type: AgentEventType.status, text: '12345678'),
          AgentEvent(
            type: AgentEventType.status,
            text: 'abcdefgh',
            metadata: <String, Object?>{'secret': canary},
          ),
        ],
      ),
      wasCurrent: false,
      messages: const <ChatMessage>[],
      availableCommands: const <Map<String, Object?>>[],
      lastLatency: null,
      lastError: null,
      sessionSettings: const AcpSessionSettings(),
      sessionUsage: null,
      sessionSettingsLoading: false,
      status: app_state.ConnectionStatus.sessionReady,
      activeSessionSettingsLoadId: null,
      inputBudget: const acp.AcpInputBudget(maxStructuredUpdateBytes: 20),
    );

    expect(snapshot.session.additionalDirectories, isEmpty);
    expect(snapshot.session.initialEvents, isEmpty);
    expect(snapshot.session.initialEvents.toString(), isNot(contains(canary)));
  });

  test('session snapshot clears events when directories are hostile', () {
    const canary = 'SECRET_DIRECTORIES_CANARY';
    final snapshot = ArchivedSessionSnapshot(
      session: AgentSession(
        id: 'a',
        cwd: 'b',
        createdAt: DateTime(2026, 7, 13, 11),
        additionalDirectories: _ThrowingStringList(canary),
        initialEvents: const <AgentEvent>[
          AgentEvent(type: AgentEventType.status, text: 'safe'),
        ],
      ),
      wasCurrent: false,
      messages: const <ChatMessage>[],
      availableCommands: const <Map<String, Object?>>[],
      lastLatency: null,
      lastError: null,
      sessionSettings: const AcpSessionSettings(),
      sessionUsage: null,
      sessionSettingsLoading: false,
      status: app_state.ConnectionStatus.sessionReady,
      activeSessionSettingsLoadId: null,
    );

    expect(snapshot.session.additionalDirectories, isEmpty);
    expect(snapshot.session.initialEvents, isEmpty);
    expect(
      snapshot.session.additionalDirectories.toString(),
      isNot(contains(canary)),
    );
  });

  test(
    'session snapshot rejects changing event omission length atomically',
    () {
      const canary = 'SECRET_EVENT_OMISSION_LENGTH_CANARY';
      final omission = acp.AcpInputOmission(
        reason: acp.AcpInputOmissionReason.invalidStructure,
        resource: 'safe',
        truncated: false,
      );
      final snapshot = ArchivedSessionSnapshot(
        session: AgentSession(
          id: 'a',
          cwd: 'b',
          createdAt: DateTime(2026, 7, 13, 11, 30),
          additionalDirectories: const <String>['/safe'],
          initialEvents: <AgentEvent>[
            AgentEvent(
              type: AgentEventType.status,
              text: 'safe',
              omissions: _GrowingLengthList<acp.AcpInputOmission>(
                omission,
                canary,
              ),
            ),
          ],
        ),
        wasCurrent: false,
        messages: const <ChatMessage>[],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: const AcpSessionSettings(),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
      );

      expect(snapshot.session.additionalDirectories, isEmpty);
      expect(snapshot.session.initialEvents, isEmpty);
      expect(
        snapshot.session.initialEvents.toString(),
        isNot(contains(canary)),
      );
    },
  );

  test('hostile public message list fails closed without leaking payload', () {
    const canary = 'SECRET_MESSAGES_CANARY';
    final hostileMessages = _ThrowingChatMessageList(canary);

    final snapshot = ArchivedSessionSnapshot(
      session: AgentSession(
        id: 'hostile-messages',
        cwd: '/workspace',
        createdAt: DateTime(2026, 7, 13, 11),
      ),
      wasCurrent: false,
      messages: hostileMessages,
      availableCommands: const <Map<String, Object?>>[],
      lastLatency: null,
      lastError: null,
      sessionSettings: const AcpSessionSettings(),
      sessionUsage: null,
      sessionSettingsLoading: false,
      status: app_state.ConnectionStatus.sessionReady,
      activeSessionSettingsLoadId: null,
    );

    expect(snapshot.messages, isEmpty);
    expect(snapshot.messages.toString(), isNot(contains(canary)));
  });

  test(
    'snapshot owns initial event carriers and counts dynamic session state',
    () {
      final eventNested = <String, Object?>{'value': 'original'};
      final eventMetadata = <String, Object?>{'nested': eventNested};
      final initialEvents = <AgentEvent>[
        AgentEvent(
          type: AgentEventType.status,
          text: 'initial',
          metadata: eventMetadata,
        ),
      ];
      final directories = <String>['/short'];

      ArchivedSessionSnapshot buildSnapshot({
        required String id,
        required String cwd,
        required String title,
        required List<String> additionalDirectories,
        required List<AgentEvent> events,
        required String? lastError,
      }) {
        return ArchivedSessionSnapshot(
          session: AgentSession(
            id: id,
            cwd: cwd,
            createdAt: DateTime(2026, 7, 12, 12),
            additionalDirectories: additionalDirectories,
            title: title,
            initialEvents: events,
          ),
          wasCurrent: true,
          messages: const <ChatMessage>[],
          availableCommands: const <Map<String, Object?>>[],
          lastLatency: const Duration(milliseconds: 4),
          lastError: lastError,
          sessionSettings: const AcpSessionSettings(),
          sessionUsage: null,
          sessionSettingsLoading: false,
          status: app_state.ConnectionStatus.sessionReady,
          activeSessionSettingsLoadId: 3,
        );
      }

      final short = buildSnapshot(
        id: 'short',
        cwd: '/a',
        title: 'a',
        additionalDirectories: directories,
        events: initialEvents,
        lastError: null,
      );
      final long = buildSnapshot(
        id: 'long',
        cwd: '/workspace/${'deep/' * 20}',
        title: 'A much longer retained session title',
        additionalDirectories: <String>['/workspace/${'shared/' * 20}'],
        events: initialEvents,
        lastError: 'A long retained error ${'detail ' * 20}',
      );
      final retained = short.retainedBytes;

      eventNested['value'] = 'changed';
      eventMetadata.clear();
      initialEvents.clear();
      directories.clear();

      expect(short.session.initialEvents.single.text, 'initial');
      expect(
        (short.session.initialEvents.single.metadata['nested']!
            as Map<String, Object?>)['value'],
        'original',
      );
      expect(short.retainedBytes, retained);
      expect(long.retainedBytes, greaterThan(short.retainedBytes));
      expect(
        () => short.session.initialEvents.single.metadata['late'] = true,
        throwsUnsupportedError,
      );
      expect(
        () =>
            (short.session.initialEvents.single.metadata['nested']!
                    as Map<String, Object?>)['late'] =
                true,
        throwsUnsupportedError,
      );
      expect(() => short.session.initialEvents.clear(), throwsUnsupportedError);
    },
  );

  test('two controllers restore independent active copies of one snapshot', () {
    final omission = acp.AcpInputOmission(
      reason: acp.AcpInputOmissionReason.inputLimit,
      resource: 'message text',
      truncated: true,
      limit: 4,
      observedAtLeast: 5,
    );
    final snapshot = ArchivedSessionSnapshot(
      session: AgentSession(
        id: 'shared-archive',
        cwd: '/workspace',
        createdAt: DateTime(2026, 7, 12, 13),
      ),
      wasCurrent: true,
      messages: <ChatMessage>[
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: 'shared',
          metadata: const <String, Object?>{
            'nested': <String, Object?>{'value': 'safe'},
          },
          omissions: <acp.AcpInputOmission>[omission],
        ),
      ],
      availableCommands: const <Map<String, Object?>>[
        <String, Object?>{'name': 'review'},
      ],
      lastLatency: null,
      lastError: null,
      sessionSettings: const AcpSessionSettings(
        modes: AcpSessionModeInfo(
          currentModeId: 'ask',
          availableModes: <AcpSessionMode>[
            AcpSessionMode(id: 'ask', name: 'Ask'),
          ],
        ),
      ),
      sessionUsage: null,
      sessionSettingsLoading: false,
      status: app_state.ConnectionStatus.sessionReady,
      activeSessionSettingsLoadId: null,
    );
    final first = ChatController(client: FakeAgentClient(), cwd: '/workspace');
    final second = ChatController(client: FakeAgentClient(), cwd: '/workspace');
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    first.restoreArchivedSessionLocally(snapshot);
    second.restoreArchivedSessionLocally(snapshot);

    expect(first.messages.single, isNot(same(second.messages.single)));
    expect(
      first.messages.single.metadata,
      isNot(same(second.messages.single.metadata)),
    );
    expect(
      first.messages.single.omissions,
      isNot(same(second.messages.single.omissions)),
    );
    expect(first.availableCommands, isNot(same(second.availableCommands)));
    expect(first.sessionSettings, isNot(same(second.sessionSettings)));
    first.setLastMessageTextForTesting('shared first');
    first.availableCommands = const <Map<String, Object?>>[];
    first.sessionSettings = const AcpSessionSettings();

    expect(first.messages.single.text, 'shared first');
    expect(second.messages.single.text, 'shared');
    expect(snapshot.messages.single.text, 'shared');
    expect(second.availableCommands.single['name'], 'review');
    expect(snapshot.availableCommands.single['name'], 'review');
    expect(second.sessionSettings.modes.currentModeId, 'ask');
    expect(snapshot.sessionSettings.modes.currentModeId, 'ask');
  });

  test(
    'empty snapshots work with one collection item and metadata node',
    () async {
      const budget = acp.AcpInputBudget(
        maxCollectionItems: 1,
        maxMetadataNodes: 1,
      );
      final session = AgentSession(
        id: 'tiny-budget',
        cwd: '/workspace',
        createdAt: DateTime(2026, 7, 12, 14),
      );
      final snapshot = ArchivedSessionSnapshot(
        session: session,
        wasCurrent: true,
        messages: const <ChatMessage>[],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: const AcpSessionSettings(),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
        inputBudget: budget,
      );
      expect(snapshot.retainedBytes, greaterThan(0));
      final fixedLabelSnapshot = ArchivedSessionSnapshot(
        session: AgentSession(
          id: 'a',
          cwd: 'b',
          createdAt: DateTime(2026, 7, 12, 14),
        ),
        wasCurrent: false,
        messages: const <ChatMessage>[],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: const AcpSessionSettings(),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
        inputBudget: const acp.AcpInputBudget(
          maxCollectionItems: 1,
          maxMetadataNodes: 1,
          maxStructuredStringBytes: 1,
        ),
      );
      expect(fixedLabelSnapshot.retainedBytes, greaterThan(0));
      final boundedDirectoriesSnapshot = ArchivedSessionSnapshot(
        session: AgentSession(
          id: 'bounded-directories',
          cwd: '/workspace',
          createdAt: DateTime(2026, 7, 12, 14),
          additionalDirectories: const <String>['/one', '/two'],
        ),
        wasCurrent: false,
        messages: const <ChatMessage>[],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: const AcpSessionSettings(),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
        inputBudget: budget,
      );
      expect(boundedDirectoriesSnapshot.session.additionalDirectories, isEmpty);

      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        inputBudget: budget,
      );
      addTearDown(controller.dispose);
      await controller.connect();
      controller.currentSession = session;
      controller.sessions.add(session);
      controller.status = app_state.ConnectionStatus.sessionReady;

      final archived = controller.archiveSessionLocally(session.id);

      expect(archived, isNotNull);
      expect(archived!.retainedBytes, greaterThan(0));
      controller.restoreArchivedSessionLocally(archived);
      expect(controller.currentSession?.id, session.id);

      final other = AgentSession(
        id: 'tiny-budget-other',
        cwd: '/workspace/other',
        createdAt: DateTime(2026, 7, 12, 15),
      );
      controller.sessions.add(other);
      await controller.resumeSession(other.id, cwd: other.cwd);
      expect(controller.lastError, isNull);
      expect(controller.currentSession?.id, other.id);
      await controller.resumeSession(session.id);
      expect(controller.currentSession?.id, session.id);
      expect(controller.messages, isEmpty);
    },
  );

  test('sending after local archive starts a new session', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    final archivedSessionId = controller.currentSession!.id;
    final snapshot = controller.archiveSessionLocally(archivedSessionId);

    expect(snapshot, isNotNull);
    expect(controller.currentSession, isNull);

    await controller.sendPrompt('Continue somewhere else');
    await pumpEventQueue(times: 12);

    expect(controller.currentSession?.id, 'fake-session-2');
    expect(fake.sessionCount, 2);
    expect(fake.lastPrompt, 'Continue somewhere else');
    expect(
      controller.sessions
          .singleWhere((session) => session.id == archivedSessionId)
          .archived,
      isTrue,
    );
    expect(
      controller.sessions
          .singleWhere((session) => session.id == 'fake-session-2')
          .archived,
      isFalse,
    );
  });

  test(
    'archive lease transfers UI bytes and restore consumes it once',
    () async {
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      await controller.newSession();
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.assistant, text: 'leased history'),
        startsNewTurn: true,
      );
      final sessionId = controller.currentSession!.id;
      final activeBytes = controller.debugActiveUiStateRetainedBytes;

      final snapshot = controller.archiveSessionLocally(sessionId)!;

      expect(activeBytes, snapshot.retainedBytes);
      expect(controller.debugActiveUiStateRetainedBytes, 0);
      expect(controller.debugUiStateRetainedBytes, snapshot.retainedBytes);

      controller.restoreArchivedSessionLocally(snapshot);
      controller.setLastMessageTextForTesting('kept after first restore');
      final restoredBytes = controller.debugUiStateRetainedBytes;

      controller.restoreArchivedSessionLocally(snapshot);

      expect(controller.currentSession?.id, sessionId);
      expect(controller.messages.single.text, 'kept after first restore');
      expect(controller.debugUiStateRetainedBytes, restoredBytes);
      snapshot.discard();
      expect(controller.debugUiStateRetainedBytes, restoredBytes);
    },
  );

  test(
    'inactive archive transfers its snapshot bytes to a discardable lease',
    () async {
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      await controller.newSession(cwd: '/workspace/first');
      final first = controller.currentSession!;
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.assistant, text: 'inactive history'),
        startsNewTurn: true,
      );
      await controller.resumeSession('second', cwd: '/workspace/second');
      final activeSessionId = controller.currentSession!.id;
      final activeBytes = controller.debugActiveUiStateRetainedBytes;
      final totalBefore = controller.debugUiStateRetainedBytes;
      expect(controller.debugInactiveSnapshotIds, contains(first.id));

      final snapshot = controller.archiveSessionLocally(first.id)!;

      expect(controller.currentSession?.id, activeSessionId);
      expect(controller.debugActiveUiStateRetainedBytes, activeBytes);
      expect(controller.debugInactiveSnapshotIds, isNot(contains(first.id)));
      expect(controller.debugUiStateRetainedBytes, totalBefore);

      snapshot.discard();
      controller.restoreArchivedSessionLocally(snapshot);

      expect(controller.debugUiStateRetainedBytes, activeBytes);
      expect(controller.debugInactiveSnapshotIds, isNot(contains(first.id)));
      expect(
        controller.sessions
            .singleWhere((session) => session.id == first.id)
            .archived,
        isTrue,
      );
    },
  );

  test(
    'archive lease rejects foreign restore and discard releases once',
    () async {
      final owner = ChatController(client: FakeAgentClient(), cwd: '/owner');
      final foreign = ChatController(
        client: FakeAgentClient(),
        cwd: '/foreign',
      );
      addTearDown(owner.dispose);
      addTearDown(foreign.dispose);

      await owner.newSession();
      final sessionId = owner.currentSession!.id;
      final snapshot = owner.archiveSessionLocally(sessionId)!;
      final leasedBytes = owner.debugUiStateRetainedBytes;

      foreign.restoreArchivedSessionLocally(snapshot);

      expect(foreign.currentSession, isNull);
      expect(owner.debugUiStateRetainedBytes, leasedBytes);

      snapshot.discard();
      snapshot.discard();
      owner.restoreArchivedSessionLocally(snapshot);

      expect(owner.debugUiStateRetainedBytes, 0);
      expect(owner.currentSession, isNull);
      expect(
        owner.sessions
            .singleWhere((session) => session.id == sessionId)
            .archived,
        isTrue,
      );
    },
  );

  test(
    'archive lease capacity rejects new untracked snapshots without growth',
    () {
      final createdAt = DateTime(2026, 7, 12, 16);
      final measured = ArchivedSessionSnapshot(
        session: AgentSession(
          id: 'session-a',
          cwd: '/same',
          createdAt: createdAt,
        ),
        wasCurrent: false,
        messages: const <ChatMessage>[],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: const AcpSessionSettings(),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
      );
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        inputBudget: acp.AcpInputBudget(
          maxTurnRetainedBytes: measured.retainedBytes,
          maxTimelineBytes: measured.retainedBytes,
          maxUiStateBytes: measured.retainedBytes,
        ),
      );
      addTearDown(controller.dispose);
      controller.mergeSessionIndex(<AgentSession>[
        AgentSession(id: 'session-a', cwd: '/same', createdAt: createdAt),
        AgentSession(id: 'session-b', cwd: '/same', createdAt: createdAt),
      ]);

      final first = controller.archiveSessionLocally('session-a');
      final afterFirst = controller.debugUiStateRetainedBytes;
      final second = controller.archiveSessionLocally('session-b');

      expect(first, isNotNull);
      expect(afterFirst, measured.retainedBytes);
      expect(second, isNull);
      expect(controller.debugUiStateRetainedBytes, afterFirst);
      expect(
        controller.sessions
            .singleWhere((session) => session.id == 'session-b')
            .archived,
        isFalse,
      );
    },
  );

  test('controller dispose releases every pending archive lease', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    await controller.newSession();
    final snapshot = controller.archiveSessionLocally(
      controller.sessions.single.id,
    )!;
    expect(controller.debugUiStateRetainedBytes, snapshot.retainedBytes);

    controller.dispose();
    snapshot.discard();

    expect(controller.debugUiStateRetainedBytes, 0);
  });

  test('restore after switching sessions keeps the active session', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    final archivedSessionId = controller.currentSession!.id;
    final snapshot = controller.archiveSessionLocally(archivedSessionId);
    await controller.newSession();
    final activeSessionId = controller.currentSession!.id;

    controller.restoreArchivedSessionLocally(snapshot!);

    expect(controller.currentSession?.id, activeSessionId);
    expect(
      controller.sessions
          .singleWhere((session) => session.id == archivedSessionId)
          .archived,
      isFalse,
    );
  });

  test(
    'inactive archive uses its own snapshot and undo restores it later',
    () async {
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        agentName: 'Codex',
      );
      addTearDown(controller.dispose);

      await controller.newSession(cwd: '/workspace/first');
      final firstSession = controller.currentSession!;
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.assistant, text: 'first-only'),
        startsNewTurn: true,
      );
      controller.availableCommands = <Map<String, Object?>>[
        <String, Object?>{'name': 'first-command'},
      ];

      await controller.resumeSession(
        'second-session',
        cwd: '/workspace/second',
      );
      final secondSession = controller.currentSession!;
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.assistant, text: 'second-only'),
        startsNewTurn: true,
      );

      final archived = controller.archiveSessionLocally(firstSession.id)!;

      expect(controller.currentSession?.id, secondSession.id);
      expect(
        archived.messages.map((message) => message.text),
        contains('first-only'),
      );
      expect(
        archived.messages.map((message) => message.text),
        isNot(contains('second-only')),
      );
      expect(archived.availableCommands.single['name'], 'first-command');

      controller.restoreArchivedSessionLocally(archived);
      controller.setLastMessageTextForTesting('second-mutated');
      await controller.resumeSession(firstSession.id);

      expect(controller.currentSession?.id, firstSession.id);
      expect(
        controller.messages.map((message) => message.text),
        contains('first-only'),
      );
      expect(
        controller.messages.map((message) => message.text),
        isNot(contains('second-mutated')),
      );
      expect(controller.availableCommands.single['name'], 'first-command');
      expect(
        () => controller.messages.last.text = 'active mutation',
        throwsStateError,
      );
      controller.setLastMessageTextForTesting('active mutation');
      expect(
        archived.messages.map((message) => message.text),
        isNot(contains('active mutation')),
      );
    },
  );

  test('session catalog preserves local sidebar metadata', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);
    controller.mergeSessionIndex([
      AgentSession(
        id: 'session-a',
        cwd: '/workspace/project-a',
        createdAt: DateTime(2026, 5, 1, 9),
        title: 'Previous agent title',
        titleOverride: 'Local title',
        agentName: 'Codex',
        pinned: true,
        archived: true,
        unread: true,
      ),
    ]);

    await controller.connect();
    await controller.loadSessionCatalog();

    expect(
      controller.sessions.single.title,
      'Resume this project conversation',
    );
    expect(controller.sessions.single.displayTitle, 'Local title');
    expect(controller.sessions.single.pinned, isTrue);
    expect(controller.sessions.single.archived, isTrue);
    expect(controller.sessions.single.unread, isTrue);
  });

  test('resume session replays history into timeline', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-1');

    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.currentSession?.id, 'resumed-session-1');
    expect(controller.currentSession?.agentName, 'Codex');
    expect(controller.sessions, hasLength(1));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.user,
      ChatMessageRole.assistant,
      ChatMessageRole.tool,
      ChatMessageRole.status,
    ]);
    expect(controller.messages[1].text, contains('medium-sized transcript'));
  });

  test('resume session exposes loading state before replay returns', () async {
    final fake = FakeAgentClient(resumeDelay: const Duration(milliseconds: 20));
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    final pendingResume = controller.resumeSession('resumed-session-loading');
    await pumpEventQueue();

    expect(controller.currentSession?.id, 'resumed-session-loading');
    expect(controller.isSessionReplayLoading, isTrue);
    expect(controller.messages, isEmpty);

    await pendingResume;

    expect(controller.isSessionReplayLoading, isFalse);
    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.messages, isNotEmpty);
  });

  test('replayed messages stay hidden until restore completes', () async {
    final fake = _ControlledRestoreAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    final pending = controller.resumeSession('hidden-until-complete');
    await fake.firstEventDelivered.future;

    expect(controller.isSessionReplayLoading, isTrue);
    expect(controller.messages, hasLength(1));
    expect(controller.visibleMessages, isEmpty);

    fake.releaseRestore.complete();
    await pending;

    expect(controller.isSessionReplayLoading, isFalse);
    expect(controller.visibleMessages, same(controller.messages));
    expect(controller.messages.single.text, 'canonical tool');
    expect(controller.lastSessionLoadMetrics?.replayedHistory, isTrue);
    expect(controller.lastSessionLoadMetrics?.replayEventCount, 2);
    expect(controller.lastSessionLoadMetrics?.firstEventElapsed, isNotNull);
    expect(controller.lastSessionLoadMetrics?.eventSpan, isNotNull);
  });

  test(
    'fresh transcript cache resumes without replay and displays once',
    () async {
      final updatedAt = DateTime.utc(2026, 8, 4, 12);
      final cache = _MemoryTranscriptCache(
        SessionTranscriptSnapshot(
          identity: SessionTranscriptIdentity(
            agentName: 'Codex',
            sessionId: 'cached-session',
            cwd: '/workspace',
            additionalDirectories: const <String>[],
            updatedAt: updatedAt,
          ),
          messages: <Map<String, Object?>>[
            <String, Object?>{
              'role': 'user',
              'text': 'cached request',
              'timestamp': '2026-08-04T11:59:00.000Z',
              'metadata': <String, Object?>{},
              'omissions': <Object?>[],
              'turnId': 1,
            },
            <String, Object?>{
              'role': 'assistant',
              'text': 'cached answer',
              'timestamp': '2026-08-04T12:00:00.000Z',
              'metadata': <String, Object?>{},
              'omissions': <Object?>[],
              'turnId': 1,
            },
          ],
        ),
      );
      final controller = ChatController(
        client: FakeAgentClient(
          supportsResumeSession: true,
          resumeEvents: const <AgentEvent>[
            AgentEvent(
              type: AgentEventType.agentTextDelta,
              text: 'must not replay',
            ),
          ],
        ),
        cwd: '/workspace',
        sessionTranscriptCache: cache,
      );
      addTearDown(controller.dispose);
      final visibleDuringLoad = <List<String>>[];
      controller.addListener(() {
        if (controller.isSessionReplayLoading) {
          visibleDuringLoad.add(
            controller.visibleMessages
                .map((message) => message.text)
                .toList(growable: false),
          );
        }
      });

      await controller.resumeSession('cached-session', updatedAt: updatedAt);

      expect(visibleDuringLoad.first, isEmpty);
      expect(
        visibleDuringLoad,
        everyElement(
          anyOf(isEmpty, <String>['cached request', 'cached answer']),
        ),
      );
      expect(
        visibleDuringLoad,
        contains(equals(<String>['cached request', 'cached answer'])),
      );
      expect(controller.messages.map((message) => message.text), <String>[
        'cached request',
        'cached answer',
      ]);
      expect(controller.lastSessionLoadMetrics?.cacheHit, isTrue);
      expect(controller.lastSessionLoadMetrics?.cacheMessageCount, 2);
      expect(controller.lastSessionLoadMetrics?.replayedHistory, isFalse);
      expect(controller.lastSessionLoadMetrics?.replayEventCount, 0);
    },
  );

  test(
    'large cached transcript reconstruction yields before display',
    () async {
      final updatedAt = DateTime.utc(2026, 8, 4, 12);
      var eventLoopAdvanced = false;
      var visibleAfterYield = false;
      final cache = _MemoryTranscriptCache(
        SessionTranscriptSnapshot(
          identity: SessionTranscriptIdentity(
            agentName: 'Codex',
            sessionId: 'cooperative-cache',
            cwd: '/workspace',
            additionalDirectories: const <String>[],
            updatedAt: updatedAt,
          ),
          messages: <Map<String, Object?>>[
            <String, Object?>{
              'role': 'assistant',
              'text': 'complete cached transcript',
              'timestamp': '2026-08-04T12:00:00.000Z',
              'metadata': _YieldProbeMetadataMap(() {
                Timer.run(() => eventLoopAdvanced = true);
              }),
              'omissions': <Object?>[],
            },
          ],
        ),
      );
      final controller = ChatController(
        client: FakeAgentClient(supportsResumeSession: true),
        cwd: '/workspace',
        sessionTranscriptCache: cache,
      );
      addTearDown(controller.dispose);
      controller.addListener(() {
        if (controller.visibleMessages.isNotEmpty) {
          visibleAfterYield = eventLoopAdvanced;
        }
      });

      await controller.resumeSession('cooperative-cache', updatedAt: updatedAt);

      expect(visibleAfterYield, isTrue);
      expect(controller.messages.single.text, 'complete cached transcript');
    },
  );

  test(
    'history-free session resume completes with an empty visible transcript',
    () async {
      final fake = FakeAgentClient(
        supportsLoadSession: false,
        supportsResumeSession: true,
        restoreReplayedHistory: false,
        resumeEvents: const <AgentEvent>[],
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.resumeSession('history-free-resume');

      expect(controller.messages, isEmpty);
      expect(controller.visibleMessages, isEmpty);
      expect(controller.lastSessionLoadMetrics?.replayedHistory, isFalse);
    },
  );

  test(
    'resume session does not notify partial replay text while loading',
    () async {
      final replayEvents = List<AgentEvent>.generate(
        96,
        (_) => const AgentEvent(type: AgentEventType.agentTextDelta, text: 'x'),
      );
      final controller = ChatController(
        client: FakeAgentClient(resumeEvents: replayEvents),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      final partialReplayTexts = <String>[];
      controller.addListener(() {
        if (controller.isSessionReplayLoading &&
            controller.messages.isNotEmpty) {
          partialReplayTexts.add(controller.messages.single.text);
        }
      });

      await controller.resumeSession('resumed-session-large');

      expect(partialReplayTexts, isEmpty);
      expect(controller.messages, hasLength(1));
      expect(controller.messages.single.text.length, replayEvents.length);
    },
  );

  test('resume session preserves consecutive user messages', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(type: AgentEventType.userMessage, text: 'First request'),
          AgentEvent(type: AgentEventType.userMessage, text: 'Second request'),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-users');

    expect(controller.messages, hasLength(2));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.user,
      ChatMessageRole.user,
    ]);
    expect(controller.messages.map((message) => message.text), [
      'First request',
      'Second request',
    ]);
  });

  test(
    'resume session accepts one Rust-projected user render message',
    () async {
      final controller = ChatController(
        client: FakeAgentClient(
          resumeEvents: const [
            AgentEvent(
              type: AgentEventType.userMessage,
              text: 'Review this image',
              metadata: {
                'contentBlocks': [
                  {
                    'type': 'resource_link',
                    'uri': 'file:///tmp/reference.png',
                    'name': 'reference.png',
                    'mimeType': 'image/png',
                  },
                ],
              },
            ),
          ],
        ),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      await controller.resumeSession('resumed-session-user-chunks');

      expect(controller.messages, hasLength(1));
      expect(controller.messages.single.role, ChatMessageRole.user);
      expect(controller.messages.single.text, 'Review this image');
      expect(
        controller.messages.single.metadata['contentBlocks'],
        hasLength(1),
      );
    },
  );

  test('resume session uses selected project cwd', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-2', cwd: '/other/project');

    expect(controller.currentSession?.cwd, '/other/project');
    expect(fake.lastResumeCwd, '/other/project');
    expect(controller.sessionSettings.configOptions.single.id, 'approval');
  });

  test(
    'resume session rejects changed roots for the active session id',
    () async {
      final fake = _ResourceNotFoundForSessionAgentClient('never-missing');
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.resumeSession(
        'bound-session',
        cwd: '/workspace/current',
        additionalDirectories: const ['/workspace/a', '/workspace/b'],
      );

      await controller.resumeSession(
        ' bound-session ',
        cwd: ' /workspace/current ',
        additionalDirectories: const [
          '/workspace/b',
          '',
          ' /workspace/a ',
          '/workspace/a',
        ],
      );

      expect(fake.resumedSessionIds, ['bound-session']);
      expect(controller.lastError, isNull);

      controller.addMessageForTesting(
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: 'Active state must survive a rejected resume.',
        ),
        startsNewTurn: true,
      );
      controller.availableCommands = const <Map<String, Object?>>[
        <String, Object?>{'name': 'review-active-conflict'},
      ];
      controller.sessionSettings = _settingsWithMode('edit');
      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-active-conflict',
          lifecycleId: 'lifecycle-active-conflict',
          title: 'Run bound workspace command',
          rationale: 'Requested by the current bound session',
          sessionId: 'bound-session',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const <String>['Allow', 'Deny'],
          requestedAt: DateTime.utc(2026, 7, 15, 12),
        ),
      );
      await pumpEventQueue();
      final pendingBindingKeyBeforeConflict =
          controller.pendingPermissionRequest!.bindingKey;
      final permissionHistoryBeforeConflict = List<AcpPermissionAuditEntry>.of(
        controller.permissionHistory,
      );
      expect(permissionHistoryBeforeConflict, hasLength(1));
      expect(
        permissionHistoryBeforeConflict.single.status,
        AcpPermissionAuditStatus.pending,
      );
      expect(fake.lastPermissionRequestId, isNull);
      final statusBeforeConflict = controller.status;
      final messagesBeforeConflict = controller.messages
          .map((message) => message.text)
          .toList(growable: false);
      final turnItemsBeforeConflict = controller.debugCurrentTurnItems;
      final turnBytesBeforeConflict = controller.debugCurrentTurnRetainedBytes;
      final commandsBeforeConflict = controller.availableCommands;
      final settingsBeforeConflict = controller.sessionSettings;
      final snapshotsBeforeConflict = controller.debugInactiveSnapshotIds;

      await controller.resumeSession(
        'bound-session',
        cwd: '/workspace/changed',
        additionalDirectories: const ['/workspace/a', '/workspace/b'],
      );

      expect(fake.resumedSessionIds, ['bound-session']);
      expect(controller.status, statusBeforeConflict);
      expect(controller.isStreaming, isFalse);
      expect(controller.currentSession?.cwd, '/workspace/current');
      expect(controller.currentSession?.additionalDirectories, [
        '/workspace/a',
        '/workspace/b',
      ]);
      expect(
        controller.messages.map((message) => message.text),
        messagesBeforeConflict,
      );
      expect(controller.debugCurrentTurnItems, turnItemsBeforeConflict);
      expect(controller.debugCurrentTurnRetainedBytes, turnBytesBeforeConflict);
      expect(controller.availableCommands, commandsBeforeConflict);
      expect(controller.sessionSettings, same(settingsBeforeConflict));
      expect(controller.debugInactiveSnapshotIds, snapshotsBeforeConflict);
      expect(
        controller.pendingPermissionRequest?.bindingKey,
        pendingBindingKeyBeforeConflict,
      );
      expect(controller.permissionHistory, permissionHistoryBeforeConflict);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.pending,
      );
      expect(controller.permissionHistory.single.decisionSource, isNull);
      expect(controller.permissionHistory.single.resolvedAt, isNull);
      expect(fake.lastPermissionRequestId, isNull);
      expect(fake.lastPermissionDecision, isNull);
      expect(fake.lastPermissionOptionId, isNull);
      expect(controller.lastError, contains('different workspace'));
    },
  );

  test('resume session makes archived local session visible again', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);
    controller.mergeSessionIndex([
      AgentSession(
        id: 'archived-session',
        cwd: '/workspace/project',
        createdAt: DateTime(2026, 7, 1, 9),
        title: 'Archived session',
        titleOverride: 'Local archived title',
        agentName: 'Codex',
        pinned: true,
        archived: true,
        unread: true,
      ),
    ]);

    await controller.resumeSession(
      'archived-session',
      cwd: '/workspace/project',
    );

    expect(controller.currentSession?.id, 'archived-session');
    expect(controller.currentSession?.displayTitle, 'Local archived title');
    expect(controller.currentSession?.pinned, isTrue);
    expect(controller.currentSession?.archived, isFalse);
    expect(controller.currentSession?.unread, isFalse);
    expect(controller.sessions.single.archived, isFalse);
  });

  test('resume local unstarted session without ACP resume', () async {
    final fake = _ResourceNotFoundForSessionAgentClient('fake-session-1');
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);

    await controller.newSession(cwd: '/workspace/blank');
    final blankSession = controller.currentSession!;

    await controller.resumeSession('other-session', cwd: '/workspace/other');

    expect(controller.currentSession?.id, 'other-session');
    expect(fake.resumedSessionIds, ['other-session']);
    expect(controller.messages, isNotEmpty);

    await controller.resumeSession(blankSession.id);

    expect(fake.resumedSessionIds, ['other-session']);
    expect(controller.currentSession?.id, blankSession.id);
    expect(controller.currentSession?.cwd, '/workspace/blank');
    expect(controller.messages, isEmpty);
    expect(controller.lastError, isNull);
    expect(controller.status, app_state.ConnectionStatus.sessionReady);
  });

  test('temporary session switching preserves active local state', () async {
    final fake = _ResourceNotFoundForSessionAgentClient(
      'fake-session-1',
      createSessionEvents: const [
        AgentEvent(
          type: AgentEventType.status,
          text: 'review',
          metadata: {
            'kind': 'commands',
            'commands': [
              {'name': 'review', 'description': 'Review current changes.'},
            ],
          },
        ),
        AgentEvent(type: AgentEventType.agentTextDelta, text: 'Local reply'),
      ],
    );
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);

    await controller.newSession(cwd: '/workspace/active');
    final activeSession = controller.currentSession!;
    expect(
      controller.messages
          .where((message) => message.role == ChatMessageRole.assistant)
          .single
          .text,
      'Local reply',
    );
    expect(controller.availableCommands.single['name'], 'review');

    await controller.resumeSession('other-session', cwd: '/workspace/other');

    expect(controller.currentSession?.id, 'other-session');
    expect(fake.resumedSessionIds, ['other-session']);
    expect(
      controller.messages.map((message) => message.text),
      contains(contains('resumed Codex session')),
    );

    await controller.resumeSession(activeSession.id);

    expect(fake.resumedSessionIds, ['other-session']);
    expect(controller.currentSession?.id, activeSession.id);
    expect(controller.currentSession?.cwd, '/workspace/active');
    expect(
      controller.messages
          .where((message) => message.role == ChatMessageRole.assistant)
          .single
          .text,
      'Local reply',
    );
    expect(controller.availableCommands.single['name'], 'review');
    expect(controller.lastError, isNull);
    expect(controller.status, app_state.ConnectionStatus.sessionReady);
  });

  test('failed resume restores previous active session state', () async {
    final fake = _FailingResumeAgentClient(
      createSessionEvents: const [
        AgentEvent(
          type: AgentEventType.status,
          text: 'review',
          metadata: {
            'kind': 'commands',
            'commands': [
              {'name': 'review', 'description': 'Review current changes.'},
            ],
          },
        ),
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();

    final previousMessages = controller.messages
        .map((message) => message.text)
        .toList();

    await controller.resumeSession('failed-session', cwd: '/other/project');

    expect(fake.lastResumeCwd, '/other/project');
    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('resume failed'));
    expect(controller.currentSession?.id, 'fake-session-1');
    expect(controller.sessions.map((session) => session.id), [
      'fake-session-1',
    ]);
    expect(
      controller.messages.map((message) => message.text),
      previousMessages,
    );
    expect(controller.availableCommands.single['name'], 'review');
    expect(controller.sessionSettings.configOptions.single.id, 'approval');
    expect(
      controller.debugInactiveSnapshotIds,
      isNot(contains('fake-session-1')),
    );
    expect(
      controller.debugUiStateRetainedBytes,
      lessThanOrEqualTo(controller.inputBudget.maxUiStateBytes),
    );
  });

  test('failed resume cancels permission from the target session', () async {
    final fake = _PermissionThenFailingResumeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    var resumeCompleted = false;
    final resume = controller
        .resumeSession('failed-target', cwd: '/other/project')
        .whenComplete(() => resumeCompleted = true);
    await fake.permissionResponseStarted.future;
    await pumpEventQueue(times: 3);
    final completedBeforePermissionResponse = resumeCompleted;
    fake.completePermissionResponse();
    await resume;

    expect(completedBeforePermissionResponse, isTrue);
    expect(controller.currentSession?.id, 'fake-session-1');
    expect(controller.pendingPermissionRequest, isNull);
    expect(controller.permissionHistory, hasLength(1));
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.cancelled,
    );
    expect(
      controller.permissionHistory.single.decisionSource,
      AcpPermissionDecisionSource.system,
    );
    expect(fake.permissionDecisions, [AcpPermissionDecision.cancel]);

    await controller.resolvePermissionRequest(AcpPermissionDecision.allow);

    expect(fake.permissionDecisions, [AcpPermissionDecision.cancel]);
  });

  test(
    'snapshot activation cancels stale permission without waiting',
    () async {
      final fake = _NeverRespondingPermissionAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      final events = <ChatPermissionEvent>[];
      controller.addPermissionEventObserver(events.add);

      await controller.newSession(cwd: '/workspace/local');
      final snapshotSession = controller.currentSession!;
      await controller.resumeSession(
        'remote-session',
        cwd: '/workspace/remote',
      );
      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'snapshot-stale-permission',
          title: 'Run remote command',
          rationale: 'Requested by the previous session',
          sessionId: 'remote-session',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 11, 13),
        ),
      );
      await pumpEventQueue();

      var activationCompleted = false;
      final activation = controller
          .resumeSession(snapshotSession.id)
          .whenComplete(() => activationCompleted = true);
      await pumpEventQueue(times: 3);

      expect(activationCompleted, isTrue);
      expect(controller.currentSession?.id, snapshotSession.id);
      expect(controller.pendingPermissionRequest, isNull);
      expect(fake.permissionResponseStarted.isCompleted, isTrue);
      expect(fake.permissionDecisions, [AcpPermissionDecision.cancel]);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.system,
      );
      expect(
        events
            .where(
              (event) =>
                  event.type == ChatPermissionEventType.resolved &&
                  event.request.id == 'snapshot-stale-permission',
            )
            .length,
        1,
      );
      await activation;
    },
  );

  test(
    'local unstarted activation cancels stale permission without waiting',
    () async {
      final fake = _NeverRespondingPermissionAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      final events = <ChatPermissionEvent>[];
      controller.addPermissionEventObserver(events.add);

      await controller.newSession(cwd: '/workspace/local-target');
      final localSession = controller.currentSession!;
      await controller.newSession(cwd: '/workspace/previous');
      final previousSession = controller.currentSession!;
      final archived = controller.archiveSessionLocally(localSession.id)!;
      controller.restoreArchivedSessionLocally(archived);
      expect(controller.currentSession?.id, previousSession.id);

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'local-stale-permission',
          title: 'Run previous command',
          rationale: 'Requested by the previous session',
          sessionId: previousSession.id,
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 11, 13, 1),
        ),
      );
      await pumpEventQueue();

      var activationCompleted = false;
      final activation = controller
          .resumeSession(localSession.id)
          .whenComplete(() => activationCompleted = true);
      await pumpEventQueue(times: 3);

      expect(activationCompleted, isTrue);
      expect(controller.currentSession?.id, localSession.id);
      expect(controller.pendingPermissionRequest, isNull);
      expect(fake.permissionResponseStarted.isCompleted, isTrue);
      expect(fake.permissionDecisions, [AcpPermissionDecision.cancel]);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.system,
      );
      expect(
        events
            .where(
              (event) =>
                  event.type == ChatPermissionEventType.resolved &&
                  event.request.id == 'local-stale-permission',
            )
            .length,
        1,
      );
      await activation;
    },
  );

  test('resume session keeps ACP session title metadata', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(
            type: AgentEventType.status,
            text: 'Updated session title',
            metadata: {
              'kind': 'session_info_update',
              'sessionId': 'resumed-session-title',
              'title': 'Updated session title',
              'updatedAt': '2026-05-30T04:12:00Z',
            },
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession(
      'resumed-session-title',
      title: 'Original session title',
    );

    expect(controller.messages, isEmpty);
    expect(controller.currentSession?.displayTitle, 'Updated session title');
    expect(controller.sessions.single.displayTitle, 'Updated session title');
  });

  test('resume session ignores blank ACP session title updates', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(
            type: AgentEventType.status,
            text: 'Session info updated.',
            metadata: {
              'kind': 'session_info_update',
              'sessionId': 'resumed-session-title',
              'title': '   ',
              'updatedAt': '2026-05-30T04:12:00Z',
            },
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession(
      'resumed-session-title',
      title: 'Original session title',
    );

    expect(controller.messages, isEmpty);
    expect(controller.currentSession?.displayTitle, 'Original session title');
    expect(controller.sessions.single.displayTitle, 'Original session title');
    expect(controller.currentSession?.updatedAt, isNotNull);
  });

  test('plan status updates replace previous plan snapshot', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(
            type: AgentEventType.status,
            text: 'Initial plan',
            metadata: {
              'kind': 'plan',
              'title': 'Initial plan',
              'entries': [
                {'content': 'Inspect', 'priority': 'high', 'status': 'pending'},
              ],
            },
          ),
          AgentEvent(
            type: AgentEventType.status,
            text: 'Updated plan',
            metadata: {
              'kind': 'plan',
              'title': 'Updated plan',
              'entries': [
                {
                  'content': 'Inspect',
                  'priority': 'high',
                  'status': 'completed',
                },
              ],
            },
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-plan');

    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.text, 'Updated plan');
  });

  test(
    'available command updates are retained for prompt suggestions',
    () async {
      final controller = ChatController(
        client: FakeAgentClient(
          resumeEvents: const [
            AgentEvent(
              type: AgentEventType.status,
              text: 'review',
              metadata: {
                'kind': 'commands',
                'commands': [
                  {
                    'name': 'review',
                    'description': 'Review the current change.',
                  },
                ],
              },
            ),
          ],
        ),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      await controller.resumeSession('resumed-session-commands');

      expect(controller.availableCommands, hasLength(1));
      expect(controller.availableCommands.single['name'], 'review');
      expect(controller.messages.single.metadata['kind'], 'commands');
    },
  );

  test(
    'new session applies initial command updates to prompt suggestions',
    () async {
      final controller = ChatController(
        client: FakeAgentClient(
          createSessionEvents: const [
            AgentEvent(
              type: AgentEventType.status,
              text: 'review',
              metadata: {
                'kind': 'commands',
                'commands': [
                  {
                    'name': 'review',
                    'description': 'Review the current change.',
                  },
                ],
              },
            ),
          ],
        ),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      await controller.newSession();

      expect(controller.availableCommands, hasLength(1));
      expect(controller.availableCommands.single['name'], 'review');
      expect(controller.messages.single.metadata['kind'], 'commands');
    },
  );

  test('terminal status updates merge by terminal id', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(
            type: AgentEventType.status,
            text: 'printf terminal-output',
            metadata: {
              'kind': 'terminal',
              'terminalEvent': 'created',
              'terminalId': 'session-1:terminal-1',
              'status': 'running',
              'command': 'printf',
              'args': ['terminal-output'],
            },
          ),
          AgentEvent(
            type: AgentEventType.status,
            text: 'Terminal output.',
            metadata: {
              'kind': 'terminal',
              'terminalEvent': 'output',
              'terminalId': 'session-1:terminal-1',
              'status': 'completed',
              'output': 'terminal-output',
              'exitCode': 0,
            },
          ),
          AgentEvent(
            type: AgentEventType.status,
            text: 'Terminal released.',
            metadata: {
              'kind': 'terminal',
              'terminalEvent': 'released',
              'terminalId': 'session-1:terminal-1',
              'status': 'released',
            },
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('session-1');

    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.text, 'printf terminal-output');
    expect(controller.messages.single.metadata['status'], 'completed');
    expect(controller.messages.single.metadata['terminalEvent'], 'released');
    expect(controller.messages.single.metadata['command'], 'printf');
    expect(controller.messages.single.metadata['output'], 'terminal-output');
  });

  test('permission invalidation clears only the matching lifecycle', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    final permissionEvents = <ChatPermissionEvent>[];
    controller.addPermissionEventObserver(permissionEvents.add);
    final request = AcpPermissionRequest(
      id: 'permission-1',
      lifecycleId: 'lifecycle-current',
      title: 'Read file',
      rationale: 'Requested by agent',
      sessionId: 'session-1',
      toolName: 'read_text_file',
      options: const <String>['Allow', 'Deny'],
      requestedAt: DateTime.utc(2026, 7, 14, 12),
    );
    fake.emitPermissionRequest(request);
    await pumpEventQueue();

    final mismatches = <AcpPermissionInvalidation>[
      AcpPermissionInvalidation(
        requestId: 'permission-other',
        lifecycleId: request.lifecycleId,
        sessionId: request.sessionId,
        reason: AcpPermissionInvalidationReason.timedOut,
        invalidatedAt: DateTime.utc(2026, 7, 14, 12, 1),
      ),
      AcpPermissionInvalidation(
        requestId: request.id,
        lifecycleId: 'lifecycle-old',
        sessionId: request.sessionId,
        reason: AcpPermissionInvalidationReason.timedOut,
        invalidatedAt: DateTime.utc(2026, 7, 14, 12, 2),
      ),
      AcpPermissionInvalidation(
        requestId: request.id,
        lifecycleId: request.lifecycleId,
        sessionId: 'session-other',
        reason: AcpPermissionInvalidationReason.timedOut,
        invalidatedAt: DateTime.utc(2026, 7, 14, 12, 3),
      ),
    ];
    for (final mismatch in mismatches) {
      fake.emitPermissionInvalidation(mismatch);
      await pumpEventQueue();
      expect(
        controller.pendingPermissionRequest?.bindingKey,
        request.withGeneration(1).bindingKey,
      );
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.pending,
      );
      expect(fake.lastPermissionRequestId, isNull);
    }

    final matching = AcpPermissionInvalidation(
      requestId: request.id,
      lifecycleId: request.lifecycleId,
      sessionId: request.sessionId,
      reason: AcpPermissionInvalidationReason.timedOut,
      invalidatedAt: DateTime.utc(2026, 7, 14, 12, 4),
    );
    fake.emitPermissionInvalidation(matching);
    fake.emitPermissionInvalidation(matching);
    await pumpEventQueue(times: 2);

    expect(controller.pendingPermissionRequest, isNull);
    expect(controller.permissionHistory, hasLength(1));
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.cancelled,
    );
    expect(
      controller.permissionHistory.single.decisionSource,
      AcpPermissionDecisionSource.system,
    );
    expect(
      permissionEvents.where(
        (event) => event.type == ChatPermissionEventType.resolved,
      ),
      hasLength(1),
    );
    expect(
      fake.lastPermissionRequestId,
      isNull,
      reason: 'invalidation is not a UI permission response',
    );
  });

  test('permission invalidation reasons and UI races settle once', () async {
    AcpPermissionRequest requestFor(String suffix) => AcpPermissionRequest(
      id: 'permission-$suffix',
      lifecycleId: 'lifecycle-$suffix',
      title: 'Run command',
      rationale: 'Requested by agent',
      sessionId: 'session-1',
      toolName: 'terminal',
      toolKind: 'execute',
      options: const <String>['Allow', 'Deny'],
      requestedAt: DateTime.utc(2026, 7, 14, 13),
    );

    for (final decision in AcpPermissionDecision.values) {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      final request = requestFor('ui-${decision.name}');
      fake.emitPermissionRequest(request);
      await pumpEventQueue();

      await controller.resolvePermissionRequest(decision);
      final expectedStatus = switch (decision) {
        AcpPermissionDecision.allow => AcpPermissionAuditStatus.allowed,
        AcpPermissionDecision.deny => AcpPermissionAuditStatus.denied,
        AcpPermissionDecision.cancel => AcpPermissionAuditStatus.cancelled,
      };
      expect(fake.lastPermissionRequestId, request.id);
      expect(fake.lastPermissionDecision, decision);
      expect(controller.permissionHistory, hasLength(1));
      expect(controller.permissionHistory.single.status, expectedStatus);
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.manual,
      );

      fake.emitPermissionInvalidation(
        AcpPermissionInvalidation(
          requestId: request.id,
          lifecycleId: request.lifecycleId,
          sessionId: request.sessionId,
          reason: AcpPermissionInvalidationReason.connectionClosed,
          invalidatedAt: DateTime.utc(2026, 7, 14, 13, 1),
        ),
      );
      await pumpEventQueue();
      expect(fake.lastPermissionRequestId, request.id);
      expect(fake.lastPermissionDecision, decision);
      expect(controller.permissionHistory, hasLength(1));
      expect(controller.permissionHistory.single.status, expectedStatus);
      controller.dispose();
      await controller.disposalComplete;
    }

    expect(AcpPermissionInvalidationReason.values, hasLength(6));
    for (final reason in AcpPermissionInvalidationReason.values) {
      final fake = FakeAgentClient();
      final reviewer = _DelayedPermissionReviewer();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        permissionReviewer: reviewer,
      );
      controller.setToolCallExecutionPolicy(
        AcpToolCallExecutionPolicy.autoReview,
      );
      final permissionEvents = <ChatPermissionEvent>[];
      controller.addPermissionEventObserver(permissionEvents.add);
      final request = requestFor(reason.name);
      fake.emitPermissionRequest(request);
      await pumpEventQueue();
      expect(reviewer.requests.single.id, request.id);

      final invalidation = AcpPermissionInvalidation(
        requestId: request.id,
        lifecycleId: request.lifecycleId,
        sessionId: request.sessionId,
        reason: reason,
        invalidatedAt: DateTime.utc(2026, 7, 14, 13, 2),
      );
      fake.emitPermissionInvalidation(invalidation);
      fake.emitPermissionInvalidation(invalidation);
      final lateManual = controller.resolvePermissionRequest(
        AcpPermissionDecision.deny,
      );
      if (reason == AcpPermissionInvalidationReason.disposed) {
        controller.dispose();
      }
      reviewer.complete(
        const AcpPermissionReviewResult(
          decision: AcpPermissionDecision.allow,
          risk: 'low',
          rationale: 'Late reviewer result.',
        ),
      );
      await lateManual;
      await pumpEventQueue(times: 3);

      expect(controller.pendingPermissionRequest, isNull);
      expect(controller.permissionHistory, hasLength(1));
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.system,
      );
      expect(
        controller.permissionHistory.single.reviewResult?.rationale,
        reason == AcpPermissionInvalidationReason.disposed
            ? isNull
            : 'Late reviewer result.',
      );
      expect(
        permissionEvents.where(
          (event) => event.type == ChatPermissionEventType.resolved,
        ),
        hasLength(1),
      );
      expect(
        fake.lastPermissionRequestId,
        isNull,
        reason: '$reason invalidation must never respond to the agent',
      );
      expect(fake.lastPermissionDecision, isNull);
      controller.dispose();
      await controller.disposalComplete;
    }
  });

  test('permission history records user decisions', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Read file',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'read_text_file',
        toolKind: 'read',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();

    expect(controller.pendingPermissionRequest?.id, 'permission-1');
    expect(controller.permissionHistory, hasLength(1));
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.pending,
    );

    await controller.resolvePermissionRequest(AcpPermissionDecision.deny);

    expect(controller.pendingPermissionRequest, isNull);
    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.deny);
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.denied,
    );
    expect(
      controller.permissionHistory.single.decisionSource,
      AcpPermissionDecisionSource.manual,
    );
    expect(controller.permissionHistory.single.resolvedAt, isNotNull);
  });

  test('manual permission selection sends the exact option id', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Run command',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        options: const ['Allow once', 'Always allow', 'Reject'],
        choices: const [
          AcpPermissionChoice(
            optionId: 'allow-once',
            name: 'Allow once',
            kind: 'allow_once',
          ),
          AcpPermissionChoice(
            optionId: 'allow-always',
            name: 'Always allow',
            kind: 'allow_always',
          ),
          AcpPermissionChoice(
            optionId: 'reject-once',
            name: 'Reject',
            kind: 'reject_once',
          ),
        ],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();

    await controller.resolvePermissionOption('allow-always');

    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionOptionId, 'allow-always');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.allowed,
    );
    expect(
      controller.permissionHistory.single.decisionSource,
      AcpPermissionDecisionSource.manual,
    );
    expect(
      controller.permissionHistory.single.selectedOptionId,
      'allow-always',
    );
  });

  test(
    'duplicate permission decisions are ignored while one is sending',
    () async {
      final fake = _DelayedPermissionResponseAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Read file',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      final allow = controller.resolvePermissionRequest(
        AcpPermissionDecision.allow,
      );
      await fake.responseStarted.future;
      final deny = controller.resolvePermissionRequest(
        AcpPermissionDecision.deny,
      );
      await pumpEventQueue();

      expect(fake.permissionResponseCount, 1);
      expect(controller.pendingPermissionRequest?.id, 'permission-1');

      fake.allowResponse.complete();
      await Future.wait([allow, deny]);

      expect(fake.permissionResponseCount, 1);
      expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
      expect(controller.pendingPermissionRequest, isNull);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.allowed,
      );
    },
  );

  test(
    'superseded permission response cannot overwrite its cancelled audit',
    () async {
      final fake = _DelayedPermissionResponseAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      final events = <ChatPermissionEvent>[];
      controller.addPermissionEventObserver(events.add);

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-a',
          title: 'Read file',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 11, 12),
        ),
      );
      await pumpEventQueue();

      final allow = controller.resolvePermissionRequest(
        AcpPermissionDecision.allow,
      );
      await fake.responseStarted.future;

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-b',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 11, 12, 1),
        ),
      );
      await pumpEventQueue();

      fake.allowResponse.complete();
      await allow;
      await pumpEventQueue(times: 2);

      final auditA = controller.permissionHistory.singleWhere(
        (entry) => entry.request.id == 'permission-a',
      );
      expect(auditA.status, AcpPermissionAuditStatus.cancelled);
      expect(auditA.decisionSource, AcpPermissionDecisionSource.system);
      expect(controller.pendingPermissionRequest?.id, 'permission-b');
      expect(
        events
            .where(
              (event) =>
                  event.type == ChatPermissionEventType.resolved &&
                  event.request.id == 'permission-a',
            )
            .length,
        1,
      );
    },
  );

  test('repeated permission events receive a new generation', () async {
    final fake = _CountingPermissionResponseAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    final request = AcpPermissionRequest(
      id: 'permission-1',
      title: 'Read file',
      rationale: 'Requested by agent',
      sessionId: 'session-1',
      toolName: 'read_text_file',
      options: const ['Allow', 'Deny'],
      requestedAt: DateTime(2026, 5, 31, 12),
    );

    fake.emitPermissionRequest(request);
    await pumpEventQueue();
    await controller.resolvePermissionRequest(AcpPermissionDecision.allow);

    expect(fake.permissionResponseCount, 1);
    expect(controller.pendingPermissionRequest, isNull);
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.allowed,
    );

    fake.emitPermissionRequest(request);
    await pumpEventQueue();

    expect(fake.permissionResponseCount, 1);
    expect(controller.pendingPermissionRequest?.generation, 2);
    expect(controller.permissionHistory, hasLength(2));
    expect(
      controller.permissionHistory.first.status,
      AcpPermissionAuditStatus.pending,
    );
    expect(
      controller.permissionHistory.last.status,
      AcpPermissionAuditStatus.allowed,
    );
    expect(
      controller.permissionHistory.last.decisionSource,
      AcpPermissionDecisionSource.manual,
    );
  });

  test('failed manual permission responses keep the request pending', () async {
    final fake = FakeAgentClient(
      permissionResponseError: StateError('permission response failed'),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Read file',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'read_text_file',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();

    await controller.resolvePermissionRequest(AcpPermissionDecision.allow);

    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
    expect(controller.pendingPermissionRequest?.id, 'permission-1');
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.pending,
    );
    expect(controller.permissionHistory.single.decisionSource, isNull);
    expect(controller.permissionHistory.single.resolvedAt, isNull);
    expect(controller.lastError, contains('permission response failed'));
  });

  test('permission history cancels superseded pending requests', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Read file',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'read_text_file',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();
    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-2',
        title: 'Run command',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12, 1),
      ),
    );
    await pumpEventQueue();

    expect(controller.pendingPermissionRequest?.id, 'permission-2');
    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
    expect(controller.permissionHistory.map((entry) => entry.request.id), [
      'permission-2',
      'permission-1',
    ]);
    expect(
      controller.permissionHistory[0].status,
      AcpPermissionAuditStatus.pending,
    );
    expect(
      controller.permissionHistory[1].status,
      AcpPermissionAuditStatus.cancelled,
    );
    expect(
      controller.permissionHistory[1].decisionSource,
      AcpPermissionDecisionSource.system,
    );
  });

  test(
    'permission requests for inactive sessions do not replace current pending',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-active',
          title: 'Read file',
          rationale: 'Requested by agent',
          sessionId: 'fake-session-1',
          toolName: 'read_text_file',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest?.id, 'permission-active');

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-stale',
          title: 'Run command',
          rationale: 'Requested by previous session',
          sessionId: 'previous-session',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12, 1),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest?.id, 'permission-active');
      expect(fake.lastPermissionRequestId, 'permission-stale');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
      expect(controller.permissionHistory.map((entry) => entry.request.id), [
        'permission-stale',
        'permission-active',
      ]);
      expect(
        controller.permissionHistory[0].status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(
        controller.permissionHistory[0].decisionSource,
        AcpPermissionDecisionSource.system,
      );
      expect(
        controller.permissionHistory[1].status,
        AcpPermissionAuditStatus.pending,
      );
    },
  );

  test(
    'permission requests without a session id are cancelled before review',
    () async {
      final fake = FakeAgentClient();
      final reviewer = _FakePermissionReviewer(
        const AcpPermissionReviewResult(
          decision: AcpPermissionDecision.allow,
          risk: 'low',
        ),
      );
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        permissionReviewer: reviewer,
      );
      addTearDown(controller.dispose);
      controller.setToolCallExecutionPolicy(
        AcpToolCallExecutionPolicy.autoReview,
      );

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-empty-session',
          title: 'Run command',
          rationale: 'Missing session context',
          sessionId: '  ',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue(times: 2);

      expect(controller.pendingPermissionRequest, isNull);
      expect(reviewer.requests, isEmpty);
      expect(fake.lastPermissionRequestId, 'permission-empty-session');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.system,
      );
    },
  );

  test(
    'permission requests for closed sessions are cancelled without active session',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.closeCurrentSession();
      expect(controller.currentSession, isNull);

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-stale',
          title: 'Run command',
          rationale: 'Requested by closed session',
          sessionId: 'fake-session-1',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest, isNull);
      expect(fake.lastPermissionRequestId, 'permission-stale');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
      expect(controller.permissionHistory, hasLength(1));
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.system,
      );
    },
  );

  test(
    'stop continues prompt cancellation when permission cancel response fails',
    () async {
      final fake = FakeAgentClient(
        chunkDelay: const Duration(milliseconds: 20),
        permissionResponseError: StateError('permission response failed'),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.sendPrompt('Hi');
      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'fake-session-1',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest?.id, 'permission-1');

      await controller.stop();

      expect(fake.lastPermissionRequestId, 'permission-1');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
      expect(fake.cancelled, isTrue);
      expect(controller.pendingPermissionRequest, isNull);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(controller.lastError, contains('permission response failed'));
    },
  );

  test(
    'stop bounds a permission cancellation response that never settles',
    () async {
      final fake = _NeverRespondingPermissionAgentClient(
        chunkDelay: const Duration(milliseconds: 50),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.sendPrompt('Hi');
      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-never-responds',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'fake-session-1',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      await controller
          .stop(cancellationTimeout: const Duration(milliseconds: 20))
          .timeout(const Duration(seconds: 1));

      expect(fake.cancelled, isTrue);
      expect(controller.pendingPermissionRequest, isNull);
      expect(controller.isStreaming, isFalse);
      expect(controller.lastError, contains('TimeoutException'));
    },
  );

  test(
    'late permission cancellation failure does not poison a new session',
    () async {
      final fake = _DelayedFailingPermissionAgentClient(
        chunkDelay: const Duration(milliseconds: 50),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.sendPrompt('Hi');
      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-late-failure',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'fake-session-1',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      await controller.stop(
        cancellationTimeout: const Duration(milliseconds: 20),
      );
      expect(controller.lastError, contains('TimeoutException'));
      expect(await controller.newSession(), isTrue);
      expect(controller.lastError, isNull);

      fake.failResponse();
      await pumpEventQueue();

      expect(controller.lastError, isNull);
      expect(controller.currentSession?.id, 'fake-session-2');
    },
  );

  test(
    'permission history cancels pending request when stream closes',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Read file',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      await fake.closePermissionRequests();
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest, isNull);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.system,
      );
    },
  );

  test(
    'permission history cancels pending request when prompt stream ends',
    () async {
      final fake = FakeAgentClient(
        chunkDelay: const Duration(milliseconds: 10),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.sendPrompt('Hi');
      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'fake-session-1',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest?.id, 'permission-1');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      await pumpEventQueue(times: 4);

      expect(controller.isStreaming, isFalse);
      expect(controller.pendingPermissionRequest, isNull);
      expect(fake.lastPermissionRequestId, 'permission-1');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.system,
      );
      expect(controller.lastError, isNull);
    },
  );

  test(
    'permission history drops oldest entries over the in-memory limit',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        permissionHistoryLimit: 2,
      );
      addTearDown(controller.dispose);

      for (var index = 1; index <= 3; index += 1) {
        fake.emitPermissionRequest(
          AcpPermissionRequest(
            id: 'permission-$index',
            title: 'Permission $index',
            rationale: 'Requested by agent',
            sessionId: 'session-1',
            toolName: 'read_text_file',
            options: const ['Allow', 'Deny'],
            requestedAt: DateTime(2026, 5, 31, 12, index),
          ),
        );
        await pumpEventQueue();
      }

      expect(controller.permissionHistory.map((entry) => entry.request.id), [
        'permission-3',
        'permission-2',
      ]);
      expect(
        controller.permissionHistory[0].status,
        AcpPermissionAuditStatus.pending,
      );
      expect(
        controller.permissionHistory[1].status,
        AcpPermissionAuditStatus.cancelled,
      );
      expect(
        controller.permissionHistory[1].decisionSource,
        AcpPermissionDecisionSource.system,
      );
    },
  );

  test(
    'permission history encoded byte limit accepts exact and drops plus one',
    () async {
      final request = AcpPermissionRequest(
        id: 'permission-sized',
        title: 'Read file',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'read_text_file',
        options: const <String>['Allow', 'Deny'],
        requestedAt: DateTime.utc(2026, 7, 15),
      );
      final probeClient = FakeAgentClient();
      final probe = ChatController(client: probeClient, cwd: '/workspace');
      addTearDown(probe.dispose);
      probeClient.emitPermissionRequest(request);
      await pumpEventQueue();
      final exactBytes = acpPermissionAuditEntryEncodedBytes(
        probe.permissionHistory.single,
      );

      Future<ChatController> recordWithLimit(int limit) async {
        final client = FakeAgentClient();
        final controller = ChatController(
          client: client,
          cwd: '/workspace',
          permissionHistoryEncodedByteLimit: limit,
        );
        client.emitPermissionRequest(request);
        await pumpEventQueue();
        return controller;
      }

      final exact = await recordWithLimit(exactBytes);
      final plusOne = await recordWithLimit(exactBytes - 1);
      addTearDown(exact.dispose);
      addTearDown(plusOne.dispose);

      expect(exact.permissionHistory, hasLength(1));
      expect(exact.permissionHistoryEncodedBytes, exactBytes);
      expect(plusOne.permissionHistory, isEmpty);
      expect(plusOne.permissionHistoryEncodedBytes, 0);
    },
  );

  test(
    'permission history snapshots mutable request collections once',
    () async {
      final options = <String>['Allow', 'Deny'];
      final choices = <AcpPermissionChoice>[
        const AcpPermissionChoice(
          optionId: 'allow-once',
          name: 'Allow',
          kind: 'allow_once',
        ),
      ];
      final metadataItems = <Object?>['one'];
      final metadata = <String, Object?>{
        'nested': <String, Object?>{'items': metadataItems},
      };
      final client = FakeAgentClient();
      final controller = ChatController(client: client, cwd: '/workspace');
      addTearDown(controller.dispose);

      client.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-mutable-history',
          title: 'Review action',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'tool',
          options: options,
          choices: choices,
          metadata: metadata,
          requestedAt: DateTime.utc(2026, 7, 15),
        ),
      );
      await pumpEventQueue();
      final entry = controller.permissionHistory.single;
      final historyJson = jsonEncode(entry.toJson());
      final fingerprint = entry.request.contentFingerprint;
      final encodedBytes = controller.permissionHistoryEncodedBytes;

      options.add(List<String>.filled(4096, 'late-option').join());
      choices.add(
        const AcpPermissionChoice(optionId: 'late', name: 'Late choice'),
      );
      metadataItems.add(List<String>.filled(4096, 'late-metadata').join());

      expect(jsonEncode(entry.toJson()), historyJson);
      expect(entry.request.contentFingerprint, fingerprint);
      expect(controller.permissionHistoryEncodedBytes, encodedBytes);
      expect(acpPermissionAuditEntryEncodedBytes(entry), encodedBytes);
      expect(
        () => entry.request.options.add('blocked'),
        throwsUnsupportedError,
      );
      expect(
        () => entry.request.choices.add(choices.first),
        throwsUnsupportedError,
      );
      expect(
        () => entry.request.metadata['late'] = true,
        throwsUnsupportedError,
      );
    },
  );

  test(
    'oversized review results cannot accumulate in 500-entry history',
    () async {
      const tokenCanary = 'token-canary-review-history';
      final huge =
          '$tokenCanary${List<String>.filled(2 * 1024 * 1024, 'x').join()}';
      final fake = FakeAgentClient();
      final reviewer = _FakePermissionReviewer(
        AcpPermissionReviewResult(
          risk: 'unknown',
          rationale: huge,
          reviewer: 'remote-reviewer',
          details: <String, Object?>{
            'raw': <String, Object?>{'body': huge},
          },
        ),
      );
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        permissionReviewer: reviewer,
        permissionReviewResultEncodedByteLimit: 1024,
        permissionHistoryEncodedByteLimit: 128 * 1024,
      );
      addTearDown(controller.dispose);
      controller.setToolCallExecutionPolicy(
        AcpToolCallExecutionPolicy.autoReview,
      );

      for (var index = 0; index < 500; index += 1) {
        fake.emitPermissionRequest(
          AcpPermissionRequest(
            id: 'permission-$index',
            title: 'Read file $index',
            rationale: 'Requested by agent',
            sessionId: 'session-1',
            toolName: 'read_text_file',
            options: const <String>['Allow', 'Deny'],
            requestedAt: DateTime.utc(
              2026,
              7,
              15,
            ).add(Duration(seconds: index)),
          ),
        );
        await pumpEventQueue(times: 2);
      }

      final exported = acpPermissionAuditEntriesToJson(
        controller.permissionHistory,
        maxEncodedBytes: 128 * 1024,
      );
      expect(reviewer.requests, hasLength(500));
      expect(controller.permissionHistory.length, greaterThan(0));
      expect(controller.permissionHistory.length, lessThan(500));
      final retainedIds = controller.permissionHistory
          .map((entry) => entry.request.id)
          .toList(growable: false);
      expect(retainedIds.first, 'permission-499');
      expect(
        retainedIds,
        List<String>.generate(
          retainedIds.length,
          (index) => 'permission-${499 - index}',
        ),
      );
      for (final entry in controller.permissionHistory) {
        expect(entry.reviewResult, isNotNull);
        expect(entry.reviewResult?.decision, isNull);
        expect(entry.reviewResult?.details, const <String, Object?>{
          'omission': 'size_limit',
        });
      }
      expect(
        controller.permissionHistoryEncodedBytes,
        lessThanOrEqualTo(128 * 1024),
      );
      expect(
        controller.permissionHistoryEncodedBytes,
        controller.permissionHistory.fold<int>(
          0,
          (total, entry) => total + acpPermissionAuditEntryEncodedBytes(entry),
        ),
      );
      expect(utf8.encode(exported).length, lessThanOrEqualTo(128 * 1024));
      expect(exported, isNot(contains(tokenCanary)));
    },
  );

  test('permission result limits must be positive at runtime', () {
    final exact = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
      permissionReviewResultEncodedByteLimit:
          minimumPermissionReviewResultEncodedByteLimit,
    );
    addTearDown(exact.dispose);
    expect(
      () => ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        permissionReviewResultEncodedByteLimit: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        permissionReviewResultEncodedByteLimit:
            minimumPermissionReviewResultEncodedByteLimit - 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        permissionHistoryEncodedByteLimit: 0,
      ),
      throwsArgumentError,
    );
  });

  test('permission history limit must be positive at runtime', () {
    final dynamic invalidLimit = 0;

    expect(
      () => ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        permissionHistoryLimit: invalidLimit,
      ),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'permissionHistoryLimit')
            .having((error) => error.invalidValue, 'invalidValue', 0),
      ),
    );
  });

  test('permission policy defaults to manual confirmation', () {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    expect(
      controller.toolCallExecutionPolicy,
      AcpToolCallExecutionPolicy.defaultPermissions,
    );
  });

  test('permission trust rules auto resolve matching requests', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      permissionTrustRules: const [
        AcpPermissionTrustRule(
          toolName: 'read_text_file',
          toolKind: 'read',
          decision: AcpPermissionDecision.allow,
        ),
      ],
    );
    addTearDown(controller.dispose);
    controller.setToolCallExecutionPolicy(
      AcpToolCallExecutionPolicy.autoReview,
    );

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Read file',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'read_text_file',
        toolKind: 'read',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();

    expect(controller.pendingPermissionRequest, isNull);
    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
    expect(controller.permissionHistory, hasLength(1));
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.allowed,
    );
    expect(
      controller.permissionHistory.single.decisionSource,
      AcpPermissionDecisionSource.trustRule,
    );
    expect(controller.permissionHistory.single.resolvedAt, isNotNull);
  });

  test('auto review permission reviewer resolves requests', () async {
    final fake = FakeAgentClient();
    final reviewer = _FakePermissionReviewer(
      const AcpPermissionReviewResult(
        decision: AcpPermissionDecision.allow,
        risk: 'low',
        rationale: 'Command stays in the workspace.',
        reviewer: 'sidecar-reviewer',
        model: 'review-model',
      ),
    );
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      permissionReviewer: reviewer,
    );
    controller.sessionSettings = const AcpSessionSettings(
      configOptions: [
        AcpConfigOption(
          id: 'model',
          name: 'Model',
          type: 'select',
          currentValue: 'primary-model',
          options: [
            AcpConfigOptionChoice(value: 'primary-model', name: 'Primary'),
          ],
        ),
      ],
    );
    addTearDown(controller.dispose);
    controller.setToolCallExecutionPolicy(
      AcpToolCallExecutionPolicy.autoReview,
    );

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
        metadata: const <String, Object?>{
          'command': 'git status',
          'cwd': '/workspace',
          'workspaceRoot': '/workspace',
        },
      ),
    );
    await pumpEventQueue(times: 2);

    expect(reviewer.requests.single.id, 'permission-1');
    expect(reviewer.workspaceRoots.single, '/workspace');
    expect(reviewer.models.single, 'primary-model');
    expect(controller.pendingPermissionRequest, isNull);
    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.allowed,
    );
    expect(
      controller.permissionHistory.single.decisionSource,
      AcpPermissionDecisionSource.reviewAgent,
    );
    expect(controller.permissionHistory.single.reviewResult?.risk, 'low');
    expect(
      controller.permissionHistory.single.reviewResult?.model,
      'review-model',
    );
  });

  test('same-agent reviewer cannot auto approve', () async {
    final fake = FakeAgentClient();
    final reviewer = _FakePermissionReviewer(
      const AcpPermissionReviewResult(
        decision: AcpPermissionDecision.allow,
        risk: 'low',
        rationale: 'The executing agent considers this safe.',
        reviewer: 'same-agent',
      ),
      canAutoApprove: false,
    );
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      permissionReviewer: reviewer,
    );
    addTearDown(controller.dispose);
    controller.setToolCallExecutionPolicy(
      AcpToolCallExecutionPolicy.autoReview,
    );

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-same-agent',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue(times: 2);

    expect(reviewer.requests.single.id, 'permission-same-agent');
    expect(controller.pendingPermissionRequest?.id, 'permission-same-agent');
    expect(fake.lastPermissionRequestId, isNull);
    expect(fake.lastPermissionDecision, isNull);
    expect(controller.permissionHistory.single.reviewResult?.risk, 'low');
  });

  test('independent reviewer cannot auto approve non-low risk', () async {
    final fake = FakeAgentClient();
    final reviewer = _FakePermissionReviewer(
      const AcpPermissionReviewResult(
        decision: AcpPermissionDecision.allow,
        risk: 'medium',
        rationale: 'The result is still ambiguous.',
        reviewer: 'independent-reviewer',
      ),
    );
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      permissionReviewer: reviewer,
    );
    addTearDown(controller.dispose);
    controller.setToolCallExecutionPolicy(
      AcpToolCallExecutionPolicy.autoReview,
    );

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-medium-risk',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue(times: 2);

    expect(controller.pendingPermissionRequest?.id, 'permission-medium-risk');
    expect(fake.lastPermissionDecision, isNull);
    expect(controller.permissionHistory.single.reviewResult?.risk, 'medium');
  });

  test('auto review uses active session workspace roots', () async {
    final fake = FakeAgentClient();
    final reviewer = _FakePermissionReviewer(
      const AcpPermissionReviewResult(
        decision: AcpPermissionDecision.allow,
        risk: 'low',
        rationale: 'Command stays in an additional workspace.',
        reviewer: 'sidecar-reviewer',
      ),
    );
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      additionalDirectories: const ['/global-extra'],
      permissionReviewer: reviewer,
    );
    controller.currentSession = AgentSession(
      id: 'session-extra',
      cwd: '/other/project',
      createdAt: DateTime(2026, 5, 31, 12),
      additionalDirectories: const ['/other/shared'],
    );
    addTearDown(controller.dispose);
    controller.setToolCallExecutionPolicy(
      AcpToolCallExecutionPolicy.autoReview,
    );

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-extra',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
        metadata: const <String, Object?>{
          'command': 'ls',
          'cwd': '/other/shared',
        },
      ),
    );
    await pumpEventQueue(times: 2);

    expect(reviewer.workspaceRoots.single, '/other/project');
    expect(reviewer.additionalDirectories.single, ['/other/shared']);
    expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
  });

  test('auto review opinion without a decision keeps request manual', () async {
    final fake = FakeAgentClient();
    final reviewer = _FakePermissionReviewer(
      const AcpPermissionReviewResult(
        risk: 'medium',
        rationale: 'Needs human confirmation.',
        reviewer: 'sidecar-reviewer',
      ),
    );
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      permissionReviewer: reviewer,
    );
    addTearDown(controller.dispose);
    controller.setToolCallExecutionPolicy(
      AcpToolCallExecutionPolicy.autoReview,
    );

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue(times: 2);

    expect(controller.pendingPermissionRequest?.id, 'permission-1');
    expect(fake.lastPermissionRequestId, isNull);
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.pending,
    );
    expect(controller.permissionHistory.single.decisionSource, isNull);
    expect(controller.permissionHistory.single.reviewResult?.risk, 'medium');
    expect(
      controller.permissionHistory.single.reviewResult?.rationale,
      'Needs human confirmation.',
    );
  });

  test('disposing controller ignores late permission review results', () async {
    final fake = FakeAgentClient();
    final reviewer = _DelayedPermissionReviewer();
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      permissionReviewer: reviewer,
    );
    controller.setToolCallExecutionPolicy(
      AcpToolCallExecutionPolicy.autoReview,
    );

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();

    expect(reviewer.requests.single.id, 'permission-1');
    expect(controller.pendingPermissionRequest?.id, 'permission-1');

    controller.dispose();
    reviewer.complete(
      const AcpPermissionReviewResult(
        decision: AcpPermissionDecision.allow,
        risk: 'low',
        rationale: 'Read-only command.',
      ),
    );
    await pumpEventQueue(times: 3);

    expect(fake.lastPermissionRequestId, isNull);
    expect(fake.lastPermissionDecision, isNull);
  });

  test(
    'late review cannot approve a same-id request with metadata whitespace changes',
    () async {
      final fake = FakeAgentClient();
      final reviewer = _SequencedPermissionReviewer();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        permissionReviewer: reviewer,
      );
      addTearDown(controller.dispose);
      controller.setToolCallExecutionPolicy(
        AcpToolCallExecutionPolicy.autoReview,
      );

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-reused',
          title: 'Read report',
          rationale: 'Read the generated report',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          toolKind: 'read',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
          metadata: const {'path': '/workspace/report', 'note': 'value'},
        ),
      );
      await pumpEventQueue();

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-reused',
          title: 'Read report',
          rationale: 'Read the generated report',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          toolKind: 'read',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12, 1),
          metadata: const {'path': '/workspace/report ', 'note': ' value'},
        ),
      );
      await pumpEventQueue();

      expect(reviewer.requests, hasLength(2));
      expect(reviewer.requests.first.generation, 1);
      expect(controller.pendingPermissionRequest?.generation, 2);
      expect(
        controller.pendingPermissionRequest?.contentFingerprint,
        isNot(reviewer.requests.first.contentFingerprint),
      );
      expect(controller.permissionHistory, hasLength(2));
      expect(controller.permissionHistory.map((entry) => entry.status), [
        AcpPermissionAuditStatus.pending,
        AcpPermissionAuditStatus.cancelled,
      ]);

      reviewer.complete(
        0,
        const AcpPermissionReviewResult(
          decision: AcpPermissionDecision.allow,
          risk: 'low',
          rationale: 'The original read is low risk.',
        ),
      );
      await pumpEventQueue(times: 3);

      expect(fake.lastPermissionDecision, isNull);
      expect(fake.lastPermissionRequestId, isNull);
      expect(controller.pendingPermissionRequest?.generation, 2);
      expect(
        controller.permissionHistory.first.status,
        AcpPermissionAuditStatus.pending,
      );
      expect(controller.permissionHistory.first.reviewResult, isNull);
      expect(
        controller.permissionHistory.last.reviewResult?.rationale,
        'The original read is low risk.',
      );
    },
  );

  test(
    'default permission policy keeps matching trust rule requests manual',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        permissionTrustRules: const [
          AcpPermissionTrustRule(
            toolName: 'read_text_file',
            decision: AcpPermissionDecision.allow,
          ),
        ],
      );
      addTearDown(controller.dispose);
      controller.setToolCallExecutionPolicy(
        AcpToolCallExecutionPolicy.defaultPermissions,
      );

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Read file',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest?.id, 'permission-1');
      expect(fake.lastPermissionRequestId, isNull);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.pending,
      );
    },
  );

  test('full access lets the agent own external action decisions', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    controller.setToolCallExecutionPolicy(
      AcpToolCallExecutionPolicy.fullAccess,
    );

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Run command',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
        metadata: const <String, Object?>{'command': 'git push origin main'},
      ),
    );
    await pumpEventQueue();

    expect(controller.pendingPermissionRequest, isNull);
    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
    expect(
      controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.allowed,
    );
    expect(
      controller.permissionHistory.single.decisionSource,
      AcpPermissionDecisionSource.policy,
    );
  });

  test(
    'permission history redacts direct command credentials and URL tokens',
    () async {
      const secret = 'controller-history-secret';
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      final events = <ChatPermissionEvent>[];
      controller.addPermissionEventObserver(events.add);

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-direct-secret',
          title: 'Create terminal',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 11),
          metadata: const <String, Object?>{
            'command': 'curl',
            'args': <String>[
              '--user',
              'alice:$secret',
              'https://alice:pw@example.com/upload?token=$secret',
            ],
          },
        ),
      );
      await pumpEventQueue();

      expect(
        controller.pendingPermissionRequest?.id,
        'permission-direct-secret',
      );
      final historyJson = acpPermissionAuditEntriesToJson(
        controller.permissionHistory,
      );
      expect(historyJson, isNot(contains(secret)));
      expect(historyJson, isNot(contains('alice:pw')));
      expect(historyJson, contains('<redacted>'));
      expect(
        events.single.request.metadata.toString(),
        isNot(contains(secret)),
      );

      await controller.resolvePermissionRequest(AcpPermissionDecision.deny);
      expect(events, hasLength(2));
      for (final event in events) {
        expect(event.request.metadata.toString(), isNot(contains(secret)));
        expect(event.request.metadata.toString(), isNot(contains('alice:pw')));
      }
    },
  );

  test(
    'permission audit redacts commands extracted from title and rationale',
    () async {
      const secret = 'title-rationale-secret';
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      final events = <ChatPermissionEvent>[];
      controller.addPermissionEventObserver(events.add);

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-text-secret',
          title:
              "Run: bash -c 'curl --tlspassword=$secret "
              "example.com/upload?token=$secret'",
          rationale:
              'Executing: eval curl --cert client.pem:$secret '
              'https://example.com/private?token=$secret',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 11),
        ),
      );
      await pumpEventQueue();

      final historyJson = acpPermissionAuditEntriesToJson(
        controller.permissionHistory,
      );
      expect(historyJson, isNot(contains(secret)));
      expect(events.single.request.title, isNot(contains(secret)));
      expect(events.single.request.rationale, isNot(contains(secret)));

      await controller.resolvePermissionRequest(AcpPermissionDecision.deny);
      expect(events, hasLength(2));
      expect(events.last.request.toJson().toString(), isNot(contains(secret)));
    },
  );

  test(
    'permission audit allowlists command metadata and preserves active binding',
    () async {
      const secret = 'comprehensive-audit-secret';
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      final events = <ChatPermissionEvent>[];
      controller.addPermissionEventObserver(events.add);

      final request = AcpPermissionRequest(
        id: 'permission-comprehensive-secret',
        title: 'Upload to https://alice:$secret@collector.example/private',
        rationale: 'Archive destination intranet/upload?token=$secret',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 7, 11),
        metadata: const <String, Object?>{
          'command': 'bash',
          'argv': <String>[
            '-c',
            'curl -u alice:$secret '
                'https://example.com/upload?token=$secret',
          ],
          'cwd': '/workspace',
          'futureCommandAlias': <String, Object?>{'credential': secret},
        },
      );
      fake.emitPermissionRequest(request);
      await pumpEventQueue();

      expect(
        controller.pendingPermissionRequest?.id,
        'permission-comprehensive-secret',
      );
      final activeBindingKey = controller.pendingPermissionRequest!.bindingKey;
      expect(activeBindingKey, isNot(request.bindingKey));
      expect(fake.lastPermissionDecision, isNull);
      expect(events, hasLength(1));
      expect(events.single.type, ChatPermissionEventType.requested);
      expect(events.single.request.bindingKey, activeBindingKey);
      expect(
        acpPermissionAuditEntriesToJson(controller.permissionHistory),
        isNot(contains(secret)),
      );
      expect(
        events.single.request.toJson().toString(),
        isNot(contains(secret)),
      );

      await controller.resolvePermissionRequest(AcpPermissionDecision.deny);

      expect(events, hasLength(2));
      expect(events.last.type, ChatPermissionEventType.resolved);
      for (final event in events) {
        expect(event.request.bindingKey, activeBindingKey);
        expect(event.request.toJson().toString(), isNot(contains(secret)));
      }
      expect(
        acpPermissionAuditEntriesToJson(controller.permissionHistory),
        isNot(contains(secret)),
      );
    },
  );

  test('nested toolCall argv remains audit-safe', () async {
    const secret = 'nested-tool-call-policy-secret';
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    final events = <ChatPermissionEvent>[];
    controller.addPermissionEventObserver(events.add);

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-nested-tool-call',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 7, 11),
        metadata: const <String, Object?>{
          'toolCall': <String, Object?>{
            'command': 'bash',
            'rawInput': <String, Object?>{
              'argv': <String>[
                '-c',
                'curl -u alice:$secret https://example.com/upload',
              ],
            },
          },
        },
      ),
    );
    await pumpEventQueue();

    expect(
      controller.pendingPermissionRequest?.id,
      'permission-nested-tool-call',
    );
    expect(fake.lastPermissionDecision, isNull);
    expect(
      acpPermissionAuditEntriesToJson(controller.permissionHistory),
      isNot(contains(secret)),
    );
    expect(events.single.request.toJson().toString(), isNot(contains(secret)));

    await controller.resolvePermissionRequest(AcpPermissionDecision.deny);

    expect(events, hasLength(2));
    for (final event in events) {
      expect(event.request.toJson().toString(), isNot(contains(secret)));
    }
  });

  test(
    'deeply nested command audit fully redacts the depth boundary',
    () async {
      const secret = 'deep-history-executable-secret';
      String quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
      var nested = '/tmp/$secret/bash';
      for (var depth = 0; depth < 3; depth += 1) {
        nested = 'bash -c ${quote(nested)}';
      }
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      final events = <ChatPermissionEvent>[];
      controller.addPermissionEventObserver(events.add);

      final request = AcpPermissionRequest(
        id: 'permission-deep-command',
        title: 'Create terminal',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 7, 11),
        metadata: <String, Object?>{
          'command': 'bash',
          'args': <String>['-c', nested],
        },
      );
      fake.emitPermissionRequest(request);
      await pumpEventQueue();

      final activeBindingKey = controller.pendingPermissionRequest!.bindingKey;
      expect(activeBindingKey, isNot(request.bindingKey));
      expect(fake.lastPermissionDecision, isNull);
      expect(
        acpPermissionAuditEntriesToJson(controller.permissionHistory),
        isNot(contains(secret)),
      );
      expect(events.single.request.bindingKey, activeBindingKey);
      expect(
        events.single.request.toJson().toString(),
        isNot(contains(secret)),
      );

      await controller.resolvePermissionRequest(AcpPermissionDecision.deny);

      expect(events, hasLength(2));
      for (final event in events) {
        expect(event.request.bindingKey, activeBindingKey);
        expect(event.request.toJson().toString(), isNot(contains(secret)));
      }
    },
  );

  test('curl attached variables remain audit-safe', () async {
    const secret = 'curl-history-variable-secret';
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    final events = <ChatPermissionEvent>[];
    controller.addPermissionEventObserver(events.add);

    final request = AcpPermissionRequest(
      id: 'permission-curl-variable',
      title: 'Create terminal',
      rationale: 'Requested by agent',
      sessionId: 'session-1',
      toolName: 'terminal',
      toolKind: 'execute',
      options: const ['Allow', 'Deny'],
      requestedAt: DateTime(2026, 7, 11),
      metadata: const <String, Object?>{
        'command': 'curl',
        'args': <String>[
          '--variable=token=$secret',
          'https://example.com/upload',
        ],
      },
    );
    fake.emitPermissionRequest(request);
    await pumpEventQueue();

    final activeBindingKey = controller.pendingPermissionRequest!.bindingKey;
    expect(activeBindingKey, isNot(request.bindingKey));
    expect(fake.lastPermissionDecision, isNull);
    expect(
      acpPermissionAuditEntriesToJson(controller.permissionHistory),
      isNot(contains(secret)),
    );
    expect(events.single.request.bindingKey, activeBindingKey);
    expect(events.single.request.toJson().toString(), isNot(contains(secret)));

    await controller.resolvePermissionRequest(AcpPermissionDecision.deny);

    expect(events, hasLength(2));
    for (final event in events) {
      expect(event.request.bindingKey, activeBindingKey);
      expect(event.request.toJson().toString(), isNot(contains(secret)));
    }
  });

  test('permission audit drops unknown non-command metadata', () async {
    const secret = 'non-command-metadata-secret';
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    final events = <ChatPermissionEvent>[];
    controller.addPermissionEventObserver(events.add);

    final request = AcpPermissionRequest(
      id: 'permission-non-command-secret',
      title: 'Read file',
      rationale: 'Requested by agent',
      sessionId: 'session-1',
      toolName: 'read_text_file',
      toolKind: 'read',
      options: const ['Allow', 'Deny'],
      requestedAt: DateTime(2026, 7, 11),
      metadata: const <String, Object?>{
        'unknownRemoteField': <String, Object?>{'token': secret},
      },
    );
    fake.emitPermissionRequest(request);
    await pumpEventQueue();

    final activeBindingKey = controller.pendingPermissionRequest!.bindingKey;
    expect(activeBindingKey, isNot(request.bindingKey));
    expect(events.single.request.bindingKey, activeBindingKey);
    expect(events.single.request.metadata, isEmpty);
    expect(
      acpPermissionAuditEntriesToJson(controller.permissionHistory),
      isNot(contains(secret)),
    );

    await controller.resolvePermissionRequest(AcpPermissionDecision.deny);

    expect(events, hasLength(2));
    for (final event in events) {
      expect(event.request.bindingKey, activeBindingKey);
      expect(event.request.toJson().toString(), isNot(contains(secret)));
    }
  });

  test(
    'switching to full access resolves the current pending request',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'terminal',
          toolKind: 'execute',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();
      expect(controller.pendingPermissionRequest?.id, 'permission-1');

      controller.setToolCallExecutionPolicy(
        AcpToolCallExecutionPolicy.fullAccess,
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest, isNull);
      expect(fake.lastPermissionRequestId, 'permission-1');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
      expect(
        controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.policy,
      );
    },
  );

  test(
    'failed trust rule permission responses keep the request pending',
    () async {
      final fake = FakeAgentClient(
        permissionResponseError: StateError('permission response failed'),
      );
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        permissionTrustRules: const [
          AcpPermissionTrustRule(
            toolName: 'read_text_file',
            decision: AcpPermissionDecision.allow,
          ),
        ],
      );
      addTearDown(controller.dispose);
      controller.setToolCallExecutionPolicy(
        AcpToolCallExecutionPolicy.autoReview,
      );

      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Read file',
          rationale: 'Requested by agent',
          sessionId: 'session-1',
          toolName: 'read_text_file',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(fake.lastPermissionRequestId, 'permission-1');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
      expect(controller.pendingPermissionRequest?.id, 'permission-1');
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.pending,
      );
      expect(controller.permissionHistory.single.decisionSource, isNull);
      expect(controller.permissionHistory.single.resolvedAt, isNull);
      expect(controller.lastError, contains('permission response failed'));
    },
  );

  test('set session mode updates ACP session settings', () async {
    final fake = FakeAgentClient(sessionSettings: _settingsWithMode('ask'));
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.setSessionMode('edit');

    expect(fake.lastSetModeId, 'edit');
    expect(controller.sessionSettings.modes.currentModeId, 'edit');
    expect(controller.lastError, isNull);
  });

  test(
    'set session mode is ignored when config options are available',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.setSessionMode('edit');

      expect(fake.lastSetModeId, isNull);
      expect(controller.sessionSettings.modes.currentModeId, isNull);
      expect(controller.lastError, isNull);
    },
  );

  test('set config option updates ACP session settings', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.setConfigOption('approval', 'auto');

    expect(fake.lastConfigId, 'approval');
    expect(fake.lastConfigValue, 'auto');
    expect(
      controller.sessionSettings.configOptions.single.currentValue,
      'auto',
    );
    expect(controller.lastError, isNull);
  });

  test('runtime config option updates clear the mode fallback', () async {
    final controller = ChatController(
      client: _ConfigOptionUpdateAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    expect(controller.sessionSettings.modes.currentModeId, 'ask');

    await controller.sendPrompt('Update settings');
    await pumpEventQueue(times: 4);

    expect(controller.sessionSettings.configOptions.single.id, 'model');
    expect(controller.sessionSettings.currentModelLabel, 'GPT-5');
    expect(controller.sessionSettings.modes.currentModeId, isNull);
    expect(controller.sessionSettings.modes.availableModes, isEmpty);
  });

  test(
    'set config option preserves local options when response omits list',
    () async {
      final fake = _OmittingConfigOptionsAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.setConfigOption('approval', 'auto');

      expect(fake.lastConfigId, 'approval');
      expect(fake.lastConfigValue, 'auto');
      expect(controller.sessionSettings.configOptions, hasLength(1));
      expect(
        controller.sessionSettings.configOptions.single.currentValue,
        'auto',
      );
      expect(controller.lastError, isNull);
    },
  );

  test('set session model updates model config option', () async {
    final fake = FakeAgentClient(
      sessionSettings: const AcpSessionSettings(
        configOptions: [
          AcpConfigOption(
            id: 'model',
            name: 'Model',
            type: 'select',
            currentValue: 'gpt-5',
            options: [
              AcpConfigOptionChoice(value: 'gpt-5', name: 'GPT-5'),
              AcpConfigOptionChoice(
                value: 'claude-sonnet-4',
                name: 'Claude Sonnet 4',
              ),
            ],
          ),
        ],
      ),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.setSessionModel('claude-sonnet-4');

    expect(fake.lastConfigId, 'model');
    expect(fake.lastConfigValue, 'claude-sonnet-4');
    expect(controller.sessionSettings.currentModelLabel, 'Claude Sonnet 4');
    expect(controller.lastError, isNull);
  });

  test(
    'set session reasoning effort updates reasoning config option',
    () async {
      final fake = FakeAgentClient(
        sessionSettings: const AcpSessionSettings(
          configOptions: [
            AcpConfigOption(
              id: 'reasoning_effort',
              name: 'Reasoning Effort',
              type: 'select',
              currentValue: 'medium',
              options: [
                AcpConfigOptionChoice(value: 'medium', name: 'Medium'),
                AcpConfigOptionChoice(value: 'high', name: 'High'),
              ],
            ),
          ],
        ),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.setSessionReasoningEffort('high');

      expect(fake.lastConfigId, 'reasoning_effort');
      expect(fake.lastConfigValue, 'high');
      expect(controller.sessionSettings.currentReasoningEffortLabel, 'High');
      expect(controller.lastError, isNull);
    },
  );

  test(
    'session settings changes are ignored while a session operation runs',
    () async {
      final fake = _DelayedForkAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();

      final fork = controller.forkCurrentSession();
      await fake.forkStarted.future;

      expect(controller.isSessionOperationRunning, isTrue);

      await controller.refreshSessionSettings();
      await controller.setSessionMode('edit');
      await controller.setConfigOption('approval', 'auto');
      await controller.setSessionModel('gpt-5');

      expect(fake.lastSetModeId, isNull);
      expect(fake.lastConfigId, isNull);

      fake.allowFork.complete();
      await fork;
    },
  );

  test(
    'stale session settings refresh does not overwrite forked session settings',
    () async {
      final fake = _StaleSessionSettingsAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      expect(controller.currentSession?.id, 'fake-session-1');
      expect(controller.sessionSettings.modes.currentModeId, 'ask');

      final refresh = controller.refreshSessionSettings();
      await fake.staleRefreshStarted.future;
      expect(controller.sessionSettingsLoading, isTrue);

      await controller.forkCurrentSession();

      expect(controller.currentSession?.id, 'fake-fork-2');
      expect(controller.sessionSettings.modes.currentModeId, 'edit');
      expect(controller.sessionSettingsLoading, isFalse);

      fake.allowStaleRefresh.complete();
      await refresh;

      expect(controller.currentSession?.id, 'fake-fork-2');
      expect(controller.sessionSettings.modes.currentModeId, 'edit');
      expect(controller.sessionSettingsLoading, isFalse);
    },
  );

  test('stale session mode response is ignored after session close', () async {
    final fake = _DelayedSettingsMutationAgentClient(
      sessionSettings: _settingsWithMode('ask'),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    final updateMode = controller.setSessionMode('edit');
    await fake.modeStarted.future;

    await controller.closeCurrentSession();
    fake.allowMode.complete();
    await updateMode;

    expect(fake.lastSetModeId, 'edit');
    expect(fake.lastClosedSessionId, 'fake-session-1');
    expect(controller.currentSession, isNull);
    expect(controller.sessionSettings.modes.currentModeId, isNull);
    expect(controller.sessionSettings.modes.availableModes, isEmpty);
    expect(controller.lastError, isNull);
  });

  test('stale config option response is ignored after session close', () async {
    final fake = _DelayedSettingsMutationAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    final updateConfig = controller.setConfigOption('approval', 'auto');
    await fake.configStarted.future;

    await controller.closeCurrentSession();
    fake.allowConfig.complete();
    await updateConfig;

    expect(fake.lastConfigId, 'approval');
    expect(fake.lastConfigValue, 'auto');
    expect(fake.lastClosedSessionId, 'fake-session-1');
    expect(controller.currentSession, isNull);
    expect(controller.sessionSettings.configOptions, isEmpty);
    expect(controller.lastError, isNull);
  });

  test('fork current session creates independent active session', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 12);

    expect(controller.canForkCurrentSession, isTrue);
    expect(controller.sessions.map((session) => session.id), [
      'fake-session-1',
    ]);

    await controller.forkCurrentSession();

    expect(fake.lastForkedSessionId, 'fake-session-1');
    expect(controller.currentSession?.id, 'fake-fork-2');
    expect(controller.currentSession?.displayTitle, 'Fork of fake-ses');
    expect(controller.currentSession?.agentName, 'Codex');
    expect(controller.sessions.map((session) => session.id), [
      'fake-fork-2',
      'fake-session-1',
    ]);
    expect(controller.messages, isEmpty);
    expect(controller.status, app_state.ConnectionStatus.sessionReady);
  });

  test('fork current session applies initial fork events', () async {
    final fake = FakeAgentClient(
      forkSessionEvents: const [
        AgentEvent(
          type: AgentEventType.status,
          text: 'review',
          metadata: <String, Object?>{
            'kind': 'commands',
            'commands': [
              <String, Object?>{
                'name': 'review',
                'description': 'Review the forked session.',
              },
            ],
          },
        ),
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.forkCurrentSession();

    expect(controller.currentSession?.id, 'fake-fork-2');
    expect(controller.availableCommands.single['name'], 'review');
    expect(controller.messages.single.metadata['kind'], 'commands');
  });

  test('fork current session preserves initial error events', () async {
    final fake = FakeAgentClient(
      forkSessionEvents: const [
        AgentEvent(type: AgentEventType.error, text: 'fork setup failed'),
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.forkCurrentSession();

    expect(controller.currentSession?.id, 'fake-fork-2');
    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('fork setup failed'));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.error,
    ]);
  });

  test('close current session clears active state', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 12);
    expect(controller.currentSession?.id, 'fake-session-1');
    expect(controller.messages, isNotEmpty);

    await controller.closeCurrentSession();

    expect(fake.lastClosedSessionId, 'fake-session-1');
    expect(controller.currentSession, isNull);
    expect(controller.sessions, isEmpty);
    expect(controller.messages, isEmpty);
    expect(controller.status, app_state.ConnectionStatus.connected);
  });

  test(
    'close current session ignores permission cleanup response errors',
    () async {
      final fake = FakeAgentClient(
        permissionResponseError: StateError('permission response failed'),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-1',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: 'fake-session-1',
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await pumpEventQueue();

      expect(controller.pendingPermissionRequest?.id, 'permission-1');

      await controller.closeCurrentSession();

      expect(fake.lastClosedSessionId, 'fake-session-1');
      expect(fake.lastPermissionRequestId, 'permission-1');
      expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
      expect(controller.currentSession, isNull);
      expect(controller.pendingPermissionRequest, isNull);
      expect(controller.lastError, isNull);
      expect(controller.status, app_state.ConnectionStatus.connected);
      expect(
        controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled,
      );
    },
  );

  test(
    'close failure still clears local session state and preserves close error',
    () async {
      const closeCanary = 'REMOTE_CLOSE_FAILURE_CANARY';
      const cleanupCanary = 'PERMISSION_CLEANUP_FAILURE_CANARY';
      final fake = _LocallyClosingFailingAgentClient(
        closeError: StateError(closeCanary),
        permissionResponseError: StateError(cleanupCanary),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      final session = controller.currentSession!;
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.assistant, text: 'stale message'),
      );
      controller.availableCommands = const <Map<String, Object?>>[
        <String, Object?>{'name': 'stale-command'},
      ];
      controller.sessionSettings = _settingsWithMode('edit');
      controller.sessionUsage = const AcpSessionUsage(used: 2, size: 10);
      controller.lastLatency = const Duration(milliseconds: 7);
      controller.restoreArchivedSessionLocally(
        ArchivedSessionSnapshot(
          session: session,
          wasCurrent: false,
          messages: const <ChatMessage>[],
          availableCommands: const <Map<String, Object?>>[],
          lastLatency: null,
          lastError: null,
          sessionSettings: const AcpSessionSettings(),
          sessionUsage: null,
          sessionSettingsLoading: false,
          status: app_state.ConnectionStatus.sessionReady,
          activeSessionSettingsLoadId: null,
        ),
      );
      fake.emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-close-failure',
          title: 'Run command',
          rationale: 'Requested by agent',
          sessionId: session.id,
          toolName: 'terminal',
          options: const <String>['Allow', 'Deny'],
          requestedAt: DateTime(2026, 7, 16, 12),
        ),
      );
      await pumpEventQueue();

      expect(controller.debugInactiveSnapshotIds, contains(session.id));
      expect(
        controller.pendingPermissionRequest?.id,
        'permission-close-failure',
      );

      await controller.closeCurrentSession();

      expect(fake.locallyClosedSessionIds, <String>[session.id]);
      expect(controller.currentSession, isNull);
      expect(controller.sessions, isEmpty);
      expect(controller.messages, isEmpty);
      expect(controller.availableCommands, isEmpty);
      expect(controller.sessionSettings.modes.availableModes, isEmpty);
      expect(controller.sessionUsage, isNull);
      expect(controller.lastLatency, isNull);
      expect(controller.pendingPermissionRequest, isNull);
      expect(controller.debugInactiveSnapshotIds, isNot(contains(session.id)));
      expect(controller.debugActiveUiStateRetainedBytes, 0);
      expect(controller.lastError, contains(closeCanary));
      expect(controller.lastError, isNot(contains(cleanupCanary)));
      expect(controller.status, app_state.ConnectionStatus.connected);

      await controller.resumeSession(session.id, cwd: session.cwd);
      expect(fake.remotelyResumedSessionIds, <String>[session.id]);
    },
  );

  test('dispose invalidates a pending close before local cleanup', () async {
    final fake = _DisposalRaceCloseAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');

    await controller.newSession();
    final session = controller.currentSession!;
    controller.addMessageForTesting(
      ChatMessage(role: ChatMessageRole.assistant, text: 'keep after dispose'),
    );
    controller.availableCommands = const <Map<String, Object?>>[
      <String, Object?>{'name': 'keep-command'},
    ];
    controller.sessionSettings = _settingsWithMode('edit');
    controller.sessionUsage = const AcpSessionUsage(used: 3, size: 10);
    controller.lastLatency = const Duration(milliseconds: 9);
    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-dispose-close',
        title: 'Run command',
        rationale: 'Requested by agent',
        sessionId: session.id,
        toolName: 'terminal',
        options: const <String>['Allow', 'Deny'],
        requestedAt: DateTime(2026, 7, 16, 13),
      ),
    );
    await pumpEventQueue();

    final close = controller.closeCurrentSession();
    await fake.closeStarted.future;
    controller.dispose();
    await controller.disposalComplete;

    final sessionsBeforeRelease = List<AgentSession>.of(controller.sessions);
    final messagesBeforeRelease = List<ChatMessage>.of(controller.messages);
    final commandsBeforeRelease = controller.availableCommands;
    final settingsBeforeRelease = controller.sessionSettings;
    final usageBeforeRelease = controller.sessionUsage;
    final latencyBeforeRelease = controller.lastLatency;
    final permissionBeforeRelease = controller.pendingPermissionRequest;
    final historyBeforeRelease = List<AcpPermissionAuditEntry>.of(
      controller.permissionHistory,
    );
    final statusBeforeRelease = controller.status;
    final errorBeforeRelease = controller.lastError;

    fake.allowClose.complete();
    await close;

    expect(fake.permissionResponseCount, 0);
    expect(controller.currentSession, same(session));
    expect(controller.sessions, sessionsBeforeRelease);
    expect(controller.messages, messagesBeforeRelease);
    expect(controller.availableCommands, same(commandsBeforeRelease));
    expect(controller.sessionSettings, same(settingsBeforeRelease));
    expect(controller.sessionUsage, same(usageBeforeRelease));
    expect(controller.lastLatency, latencyBeforeRelease);
    expect(controller.pendingPermissionRequest, same(permissionBeforeRelease));
    expect(controller.permissionHistory, historyBeforeRelease);
    expect(controller.status, statusBeforeRelease);
    expect(controller.lastError, errorBeforeRelease);
  });

  test('logout clears local session state', () async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 12);
    expect(controller.canLogout, isTrue);

    await controller.logout();

    expect(fake.loggedOut, isTrue);
    expect(controller.currentSession, isNull);
    expect(controller.sessions, isEmpty);
    expect(controller.messages, isEmpty);
    expect(controller.status, app_state.ConnectionStatus.connected);

    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-logout-stale',
        title: 'Run command',
        rationale: 'Requested by logged-out session',
        sessionId: 'fake-session-1',
        toolName: 'terminal',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await pumpEventQueue();

    expect(controller.pendingPermissionRequest, isNull);
    expect(fake.lastPermissionRequestId, 'permission-logout-stale');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.cancel);
  });

  test('authenticate invokes advertised auth method', () async {
    final fake = FakeAgentClient(
      authMethods: const [
        {
          'id': 'browser',
          'name': 'Browser sign-in',
          'description': 'Continue in the agent browser flow.',
        },
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.canAuthenticate, isTrue);
    expect(controller.authMethods.single['id'], 'browser');

    final authenticated = await controller.authenticate('browser');

    expect(authenticated, isTrue);
    expect(fake.lastAuthenticatedMethodId, 'browser');
    expect(controller.lastError, isNull);
    expect(controller.status, app_state.ConnectionStatus.connected);
    expect(controller.isSessionOperationRunning, isFalse);
  });

  test('authenticate trims advertised auth method ids', () async {
    final fake = FakeAgentClient(
      authMethods: const [
        {'id': ' browser ', 'name': 'Browser sign-in'},
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();

    expect(controller.canAuthenticate, isTrue);
    await controller.authenticate('browser');

    expect(fake.lastAuthenticatedMethodId, 'browser');
    expect(controller.lastError, isNull);
  });

  test('auth required session errors point to authenticate action', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        createSessionError: const _AuthRequiredError(),
        authMethods: const [
          {'id': 'browser', 'name': 'Browser sign-in'},
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.currentSession, isNull);
    expect(controller.lastError, contains('Authentication required'));
    expect(controller.lastError, contains('Agents menu'));
    expect(controller.lastError, contains('Authenticate'));
  });

  test('auth required prompt errors point to authenticate action', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        promptError: const _AuthRequiredError(),
        authMethods: const [
          {'id': 'browser', 'name': 'Browser sign-in'},
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 4);

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('Agents menu'));
    expect(controller.messages.last.role, ChatMessageRole.error);
    expect(controller.messages.last.text, controller.lastError);
  });

  test('agentTextDone stop reason is rendered as a turn status', () async {
    final controller = ChatController(
      client: FakeAgentClient(
        resumeEvents: const [
          AgentEvent(
            type: AgentEventType.agentTextDone,
            text: '',
            metadata: {'stopReason': 'maxTokens', 'kind': 'turn'},
          ),
        ],
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.resumeSession('resumed-session-3');

    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.role, ChatMessageRole.status);
    expect(controller.messages.single.text, contains('token limit'));
    expect(controller.messages.single.metadata['stopReason'], 'maxTokens');
  });

  test('send prompt returns stream chunks appended to one message', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 12);

    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.isStreaming, isFalse);
    expect(controller.messages, hasLength(2));
    expect(controller.messages.first.role, ChatMessageRole.user);
    expect(controller.messages.first.text, 'Hi');
    expect(controller.messages.last.role, ChatMessageRole.assistant);
    expect(controller.messages.last.text, 'Hello, I am Codex.');
  });

  test('send prompt coalesces tool call chunks by call id', () async {
    final controller = ChatController(
      client: _ToolCallChunkAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Run command');
    await pumpEventQueue(times: 8);

    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.isStreaming, isFalse);
    expect(controller.messages, hasLength(2));
    expect(controller.messages.first.role, ChatMessageRole.user);

    final toolMessage = controller.messages.last;
    expect(toolMessage.role, ChatMessageRole.tool);
    expect(toolMessage.text, 'Bash');
    expect(toolMessage.metadata['toolCallId'], 'call-1');
    expect(toolMessage.metadata['status'], 'completed');
    expect(toolMessage.metadata['rawInput'], {'command': 'echo hi'});
    expect(toolMessage.metadata['rawOutput'], 'hi');
  });

  test('send prompt coalesces tool call chunks by id aliases', () async {
    final controller = ChatController(
      client: _AliasToolCallChunkAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Run command');
    await pumpEventQueue(times: 8);

    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.isStreaming, isFalse);
    expect(controller.messages, hasLength(2));

    final toolMessage = controller.messages.last;
    expect(toolMessage.role, ChatMessageRole.tool);
    expect(toolMessage.text, 'Bash');
    expect(toolMessage.metadata['id'], 'call-1');
    expect(toolMessage.metadata['callId'], 'call-1');
    expect(toolMessage.metadata['status'], 'completed');
    expect(toolMessage.metadata['rawOutput'], 'hi');
  });

  test(
    'send prompt coalesces tool call chunks by snake case id alias',
    () async {
      final controller = ChatController(
        client: _SnakeCaseToolCallChunkAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.sendPrompt('Run command');
      await pumpEventQueue(times: 8);

      expect(controller.status, app_state.ConnectionStatus.sessionReady);
      expect(controller.isStreaming, isFalse);
      expect(controller.messages, hasLength(2));

      final toolMessage = controller.messages.last;
      expect(toolMessage.role, ChatMessageRole.tool);
      expect(toolMessage.text, 'Bash');
      expect(toolMessage.metadata['tool_call_id'], 'call-1');
      expect(toolMessage.metadata['status'], 'completed');
      expect(toolMessage.metadata['raw_output'], 'hi');
    },
  );

  test(
    'send prompt forwards attachments and renders resource metadata',
    () async {
      final fake = FakeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      const attachment = PromptAttachment(
        path: '/workspace/readme.md',
        name: 'readme.md',
        mimeType: 'text/markdown',
        size: 2048,
      );

      await controller.newSession();
      await controller.sendPrompt(
        'Review this file',
        attachments: [attachment],
      );
      await pumpEventQueue(times: 12);

      expect(fake.lastPrompt, 'Review this file');
      expect(fake.lastAttachments, [attachment]);
      expect(controller.messages.first.role, ChatMessageRole.user);
      expect(controller.messages.first.text, 'Review this file');
      expect(controller.messages.first.metadata['contentBlocks'], [
        attachment.toResourceLink(),
      ]);
    },
  );

  test(
    'automatic titles and assistant summaries enhance completed turns',
    () async {
      final enhancer = _FakeAssistantAgentEnhancer();
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
        enableAutomaticSessionTitles: true,
        assistantAgentConfig: enhancer.config,
        assistantAgentEnhancer: enhancer,
      );
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.sendPrompt('实现一个可拖动的消息队列');
      await pumpEventQueue(times: 20);

      expect(controller.currentSession?.title, '消息队列与引导');
      final summary = controller.messages.where(
        (message) => message.metadata['kind'] == 'assistant_summary',
      );
      expect(summary, hasLength(1));
      expect(summary.single.text, contains('完成'));
      expect(summary.single.metadata['collapseProcess'], isTrue);
      expect(enhancer.titlePrompts, ['实现一个可拖动的消息队列']);
      expect(enhancer.summaryRequests, hasLength(1));
    },
  );

  test(
    'queued prompts prioritize a guided message at the next boundary',
    () async {
      final fake = _RecordingPromptAgentClient(
        chunkDelay: const Duration(milliseconds: 2),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.sendPrompt('first');
      expect(
        await controller.submitOrQueuePrompt('normal follow-up'),
        ChatPromptSubmissionResult.queued,
      );
      expect(
        controller.enqueuePrompt('guided follow-up', guide: true),
        ChatPromptSubmissionResult.queued,
      );
      expect(controller.queuedPrompts.first.guide, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      await pumpEventQueue(times: 20);

      expect(fake.prompts, ['first', 'guided follow-up', 'normal follow-up']);
      expect(controller.queuedPrompts, isEmpty);
    },
  );

  test(
    'guiding a queued prompt interrupts the active turn and dispatches it',
    () async {
      final fake = _AcknowledgedCancellationAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(() async {
        controller.dispose();
        await fake.closePromptStream();
      });

      await controller.newSession();
      await controller.sendPrompt('first');
      controller.enqueuePrompt('normal follow-up');
      controller.enqueuePrompt('guidance for active work');
      final guidanceId = controller.queuedPrompts.last.id;

      controller.guideQueuedPrompt(guidanceId);
      await fake.cancelRequested.future;

      expect(controller.queuedPrompts.first.text, 'guidance for active work');
      expect(controller.queuedPrompts.first.guide, isTrue);
      expect(fake.prompts, ['first']);

      await fake.acknowledgeCancellation();
      await pumpEventQueue(times: 20);

      expect(fake.prompts.take(2), ['first', 'guidance for active work']);
    },
  );

  test(
    'prompt idle warning follows stream activity and clears on completion',
    () async {
      final fake = _ControlledPromptAgentClient();
      final controller = ChatController(
        client: fake,
        cwd: '/workspace',
        promptIdleWarningDelay: const Duration(milliseconds: 20),
      );
      addTearDown(controller.dispose);

      await controller.newSession();
      await controller.sendPrompt('first');
      await Future<void>.delayed(const Duration(milliseconds: 35));

      expect(controller.isStreaming, isTrue);
      expect(controller.promptAppearsStalled, isTrue);

      fake.emit(
        const AgentEvent(type: AgentEventType.agentTextDelta, text: 'working'),
      );
      await pumpEventQueue(times: 4);
      expect(controller.promptAppearsStalled, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(controller.promptAppearsStalled, isTrue);

      await fake.finishPrompt();
      await pumpEventQueue(times: 4);
      expect(controller.isStreaming, isFalse);
      expect(controller.promptAppearsStalled, isFalse);
    },
  );

  test(
    'stop waits for cancellation acknowledgement before dispatching queue',
    () async {
      final fake = _AcknowledgedCancellationAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(() async {
        controller.dispose();
        await fake.closePromptStream();
      });

      await controller.newSession();
      await controller.sendPrompt('first');
      controller.enqueuePrompt('normal follow-up');
      controller.enqueuePrompt('guided follow-up', guide: true);

      final stop = controller.stop(
        cancellationTimeout: const Duration(seconds: 1),
      );
      await fake.cancelRequested.future;
      await pumpEventQueue(times: 4);

      expect(fake.prompts, ['first']);
      expect(controller.isStreaming, isTrue);
      expect(controller.queuedPrompts.map((prompt) => prompt.text), [
        'guided follow-up',
        'normal follow-up',
      ]);

      await fake.acknowledgeCancellation();
      await stop;
      await pumpEventQueue(times: 20);

      expect(fake.prompts, ['first', 'guided follow-up', 'normal follow-up']);
      expect(controller.queuedPrompts, isEmpty);
      expect(controller.lastError, isNull);
    },
  );

  test(
    'stop timeout preserves queued prompts instead of consuming them',
    () async {
      final fake = _AcknowledgedCancellationAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(() async {
        controller.dispose();
        await fake.closePromptStream();
      });

      await controller.newSession();
      await controller.sendPrompt('first');
      controller.enqueuePrompt('guided follow-up', guide: true);

      await controller.stop(
        cancellationTimeout: const Duration(milliseconds: 20),
      );
      await pumpEventQueue(times: 8);

      expect(fake.prompts, ['first']);
      expect(controller.isStreaming, isFalse);
      expect(controller.status, app_state.ConnectionStatus.error);
      expect(controller.queuedPrompts.single.text, 'guided follow-up');
      expect(controller.queuedPrompts.single.guide, isTrue);
      expect(controller.lastError, contains('TimeoutException'));
    },
  );

  test('queued prompts can be cleared together', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    expect(
      controller.enqueuePrompt('first'),
      ChatPromptSubmissionResult.queued,
    );
    expect(
      controller.enqueuePrompt('second'),
      ChatPromptSubmissionResult.queued,
    );
    expect(controller.queuedPrompts, hasLength(2));

    controller.clearQueuedPrompts();

    expect(controller.queuedPrompts, isEmpty);
  });

  test('queued prompts reorder with adjusted list indices', () async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    controller.enqueuePrompt('first');
    controller.enqueuePrompt('second');
    controller.enqueuePrompt('third');

    controller.reorderQueuedPrompt(0, 2);

    expect(controller.queuedPrompts.map((prompt) => prompt.text), [
      'second',
      'third',
      'first',
    ]);
  });

  test('send prompt error is rendered as error message', () async {
    final controller = ChatController(
      client: FakeAgentClient(promptError: Exception('prompt failed')),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue(times: 4);

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('prompt failed'));
    expect(controller.messages.last.role, ChatMessageRole.error);
  });

  test(
    'prompt stream error formatting always finishes streaming and notifies',
    () async {
      const canary = 'PROMPT_ERROR_SECRET';
      final promptError = _ThrowingErrorString(canary);
      final controller = ChatController(
        client: FakeAgentClient(promptError: promptError),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      await controller.newSession();
      final notifications =
          <
            ({app_state.ConnectionStatus status, bool streaming, String? error})
          >[];
      controller.addListener(() {
        notifications.add((
          status: controller.status,
          streaming: controller.isStreaming,
          error: controller.lastError,
        ));
      });

      final result = await controller.sendPrompt('Hi');
      await pumpEventQueue(times: 4);

      expect(result, ChatPromptSubmissionResult.submitted);
      expect(promptError.toStringCalls, 1);
      expect(controller.isStreaming, isFalse);
      expect(controller.status, app_state.ConnectionStatus.error);
      expect(controller.lastError, 'An unexpected error occurred.');
      expect(controller.lastError, isNot(contains(canary)));
      expect(controller.messages.last.role, ChatMessageRole.error);
      expect(controller.messages.last.text, controller.lastError);
      expect(
        notifications,
        contains((
          status: app_state.ConnectionStatus.error,
          streaming: false,
          error: 'An unexpected error occurred.',
        )),
      );
    },
  );

  test('send prompt error events finish streaming immediately', () async {
    final controller = ChatController(
      client: _OpenErrorEventAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    await pumpEventQueue();

    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.isStreaming, isFalse);
    expect(controller.lastError, contains('agent event failed'));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.user,
      ChatMessageRole.error,
    ]);
  });

  test('send prompt setup failures finish streaming with an error', () async {
    final controller = ChatController(
      client: _ThrowingPromptAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();
    final result = await controller.sendPrompt('Hi');

    expect(result, ChatPromptSubmissionResult.failed);
    expect(controller.isStreaming, isFalse);
    expect(controller.status, app_state.ConnectionStatus.error);
    expect(controller.lastError, contains('prompt setup failed'));
    expect(controller.messages.map((message) => message.role), [
      ChatMessageRole.user,
      ChatMessageRole.error,
    ]);
  });

  test('stop cancels streaming', () async {
    final fake = FakeAgentClient(chunkDelay: const Duration(milliseconds: 50));
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    final first = await controller.sendPrompt('Hi');
    expect(controller.isStreaming, isTrue);
    final second = await controller.sendPrompt('Ignored while busy');

    expect(first, ChatPromptSubmissionResult.submitted);
    expect(second, ChatPromptSubmissionResult.busy);
    expect(fake.lastPrompt, 'Hi');

    await controller.stop();

    expect(fake.cancelled, isTrue);
    expect(controller.isStreaming, isFalse);
    expect(controller.status, app_state.ConnectionStatus.sessionReady);
  });

  test('stop still finishes streaming when cancel fails', () async {
    final fake = FakeAgentClient(
      chunkDelay: const Duration(milliseconds: 50),
      cancelError: Exception('cancel failed'),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await controller.sendPrompt('Hi');
    expect(controller.isStreaming, isTrue);

    await controller.stop();

    expect(controller.isStreaming, isFalse);
    expect(controller.status, app_state.ConnectionStatus.sessionReady);
    expect(controller.lastError, contains('cancel failed'));
  });
}

final class _FakeAssistantAgentEnhancer implements AssistantAgentEnhancer {
  @override
  final AssistantAgentConfig config = const AssistantAgentConfig(
    enabled: true,
    agentName: 'Helper',
  );

  final List<String> titlePrompts = <String>[];
  final List<AssistantTurnSummaryRequest> summaryRequests =
      <AssistantTurnSummaryRequest>[];

  @override
  Future<String?> generateSessionTitle({
    required String sessionId,
    required String firstPrompt,
  }) async {
    titlePrompts.add(firstPrompt);
    return '消息队列与引导';
  }

  @override
  Future<String?> summarizeTurn(AssistantTurnSummaryRequest request) async {
    summaryRequests.add(request);
    return '已完成队列与引导交互，并保留原始执行过程。';
  }

  @override
  Future<void> dispose() async {}
}

final class _RecordingPromptAgentClient extends FakeAgentClient {
  _RecordingPromptAgentClient({required super.chunkDelay});

  final List<String> prompts = <String>[];

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    prompts.add(prompt);
    return super.sendPrompt(
      sessionId: sessionId,
      prompt: prompt,
      attachments: attachments,
    );
  }
}

final class _AcknowledgedCancellationAgentClient extends FakeAgentClient {
  final List<String> prompts = <String>[];
  final Completer<void> cancelRequested = Completer<void>();
  final StreamController<AgentEvent> _firstPrompt =
      StreamController<AgentEvent>();

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    prompts.add(prompt);
    if (prompts.length == 1) return _firstPrompt.stream;
    return Stream<AgentEvent>.value(
      AgentEvent(
        type: AgentEventType.agentTextDone,
        text: '',
        metadata: const <String, Object?>{
          'kind': 'turn',
          'stopReason': 'endTurn',
        },
      ),
    );
  }

  @override
  Future<void> cancel() async {
    await super.cancel();
    if (!cancelRequested.isCompleted) cancelRequested.complete();
  }

  Future<void> acknowledgeCancellation() async {
    if (_firstPrompt.isClosed) return;
    _firstPrompt.add(
      AgentEvent(
        type: AgentEventType.agentTextDone,
        text: '',
        metadata: const <String, Object?>{
          'kind': 'turn',
          'stopReason': 'cancelled',
        },
      ),
    );
    await _firstPrompt.close();
  }

  Future<void> closePromptStream() async {
    if (!_firstPrompt.isClosed) await _firstPrompt.close();
  }
}

class _AuthRequiredError {
  const _AuthRequiredError();

  int get code => -32001;

  String get message => 'Authentication is required.';

  Map<String, Object?> get data => const <String, Object?>{
    'code': 'auth_required',
    'message': 'Sign in before creating a session.',
  };

  @override
  String toString() => 'JSON-RPC error -32001';
}

class _ThrowingErrorString {
  _ThrowingErrorString(this.canary);

  final String canary;
  int toStringCalls = 0;

  @override
  String toString() {
    toStringCalls += 1;
    throw StateError(canary);
  }
}

class _ThrowingStringValue {
  _ThrowingStringValue(this.canary);

  final String canary;
  int toStringCalls = 0;

  @override
  String toString() {
    toStringCalls += 1;
    throw StateError(canary);
  }
}

class _StringValue {
  _StringValue(this.value);

  final String value;
  int toStringCalls = 0;

  @override
  String toString() {
    toStringCalls += 1;
    return value;
  }
}

class _StructuredError {
  const _StructuredError({required this.text, this.data, this.cause});

  final String text;
  final Object? data;
  final Object? cause;

  @override
  String toString() => text;
}

class _RecursiveSelfCauseError {
  bool _formatting = false;
  int toStringCalls = 0;

  Object get cause => this;

  @override
  String toString() {
    toStringCalls += 1;
    if (_formatting) throw StateError('recursive error formatting');
    _formatting = true;
    try {
      return cause.toString();
    } finally {
      _formatting = false;
    }
  }
}

class _CountingErrorIterable extends Iterable<Object?> {
  _CountingErrorIterable(this.itemCount);

  final int itemCount;
  int yielded = 0;

  @override
  Iterator<Object?> get iterator => _CountingErrorIterator(this);
}

class _CountingErrorIterator implements Iterator<Object?> {
  _CountingErrorIterator(this.owner);

  final _CountingErrorIterable owner;
  int _index = 0;

  @override
  Object? get current => _StringValue('ordinary value $_index');

  @override
  bool moveNext() {
    if (_index >= owner.itemCount) return false;
    _index += 1;
    owner.yielded += 1;
    return true;
  }
}

class _OmittingConfigOptionsAgentClient extends FakeAgentClient {
  @override
  Future<List<AcpConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
  }) async {
    await super.setConfigOption(
      sessionId: sessionId,
      configId: configId,
      value: value,
    );
    return const <AcpConfigOption>[];
  }
}

class _FailingReconnectAgentClient extends FakeAgentClient {
  int _connectAttempts = 0;

  @override
  Future<void> connect() async {
    _connectAttempts += 1;
    if (_connectAttempts == 1) {
      await super.connect();
      return;
    }
    connected = false;
    throw Exception('connection dropped');
  }
}

class _ReusedSessionSetupPermissionAgentClient extends FakeAgentClient {
  int _createSessionCount = 0;

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }

    _createSessionCount += 1;
    const sessionId = 'reused-session';
    if (_createSessionCount > 1) {
      emitPermissionRequest(
        AcpPermissionRequest(
          id: 'permission-reused-$_createSessionCount',
          title: 'Run command',
          rationale: 'Requested during session setup',
          sessionId: sessionId,
          toolName: 'terminal',
          options: const ['Allow', 'Deny'],
          requestedAt: DateTime(2026, 5, 31, 12),
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }

    return AgentSession(
      id: sessionId,
      cwd: cwd,
      createdAt: DateTime(2026, 5, 28, 12),
      additionalDirectories: additionalDirectories,
    );
  }
}

class _FailingResumeAgentClient extends FakeAgentClient {
  _FailingResumeAgentClient({super.createSessionEvents});

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    lastResumeCwd = cwd;
    throw StateError('resume failed');
  }
}

class _HostileCreateSessionAgentClient extends FakeAgentClient {
  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    return AgentSession(
      id: 'hostile-created',
      cwd: cwd,
      createdAt: DateTime(2026, 7, 13, 19),
      additionalDirectories: _ThrowingStringList('HOSTILE_REMOTE_SESSION'),
    );
  }
}

class _DelayedInitialSettingsAgentClient extends FakeAgentClient {
  final Completer<void> settingsStarted = Completer<void>();
  final Completer<void> allowSettings = Completer<void>();

  @override
  Future<AcpSessionSettings> sessionSettings(String sessionId) async {
    if (!settingsStarted.isCompleted) settingsStarted.complete();
    await allowSettings.future;
    return const AcpSessionSettings();
  }
}

class _GrowingInitialEventsAgentClient extends FakeAgentClient {
  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    return AgentSession(
      id: 'growing-events',
      cwd: cwd,
      createdAt: DateTime(2026, 7, 13, 20),
      initialEvents: _GrowingLengthList<AgentEvent>(
        const AgentEvent(type: AgentEventType.agentTextDelta, text: 'partial'),
        'GROWING_INITIAL_EVENTS',
      ),
    );
  }
}

class _DelayedCreateSessionAgentClient extends FakeAgentClient {
  final Completer<void> createStarted = Completer<void>();
  final Completer<void> allowCreate = Completer<void>();

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (!createStarted.isCompleted) createStarted.complete();
    await allowCreate.future;
    return AgentSession(
      id: 'delayed-created',
      cwd: cwd,
      createdAt: DateTime(2026, 7, 13, 21),
    );
  }
}

class _MutableCreateSessionAgentClient extends FakeAgentClient {
  final List<String> directories = <String>['/safe'];
  final List<AgentEvent> events = <AgentEvent>[
    const AgentEvent(type: AgentEventType.agentTextDelta, text: 'initial'),
  ];

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    return AgentSession(
      id: 'mutable-created',
      cwd: cwd,
      createdAt: DateTime(2026, 7, 13, 22),
      additionalDirectories: directories,
      initialEvents: events,
    );
  }
}

class _PermissionThenFailingResumeAgentClient extends FakeAgentClient {
  final List<AcpPermissionDecision> permissionDecisions =
      <AcpPermissionDecision>[];
  final Completer<void> permissionResponseStarted = Completer<void>();
  final Completer<void> _permissionResponse = Completer<void>();

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    lastResumeCwd = cwd;
    emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-during-resume',
        title: 'Run target command',
        rationale: 'Requested by target session',
        sessionId: sessionId,
        toolName: 'terminal',
        toolKind: 'execute',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 7, 11, 12),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    throw StateError('resume failed');
  }

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) async {
    permissionDecisions.add(decision);
    if (!permissionResponseStarted.isCompleted) {
      permissionResponseStarted.complete();
    }
    await _permissionResponse.future;
    await super.respondToPermissionRequest(
      id: id,
      decision: decision,
      selectedOptionId: selectedOptionId,
    );
  }

  void completePermissionResponse() {
    if (!_permissionResponse.isCompleted) _permissionResponse.complete();
  }
}

class _ResourceNotFoundForSessionAgentClient extends FakeAgentClient {
  _ResourceNotFoundForSessionAgentClient(
    this.missingSessionId, {
    super.createSessionEvents,
  });

  final String missingSessionId;
  final List<String> resumedSessionIds = <String>[];

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    resumedSessionIds.add(sessionId);
    if (sessionId == missingSessionId) {
      throw StateError('JSON-RPC error -32002: Resource not found');
    }
    return super.resumeSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }
}

class _ConfigOptionUpdateAgentClient extends FakeAgentClient {
  _ConfigOptionUpdateAgentClient()
    : super(sessionSettings: _settingsWithMode('ask'));

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    yield AgentEvent(
      type: AgentEventType.status,
      text: 'Session config options updated.',
      metadata: const <String, Object?>{
        'kind': 'config_option_update',
        'configOptions': <AcpConfigOption>[
          AcpConfigOption(
            id: 'model',
            name: 'Model',
            type: 'select',
            currentValue: 'gpt-5',
            category: 'model',
            options: [AcpConfigOptionChoice(value: 'gpt-5', name: 'GPT-5')],
          ),
        ],
      },
    );
    yield AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      timestamp: DateTime(2026, 5, 28, 12),
    );
  }
}

class _FailingDisposeAgentClient extends FakeAgentClient {
  @override
  Future<void> dispose() async {
    await super.dispose();
    throw StateError('dispose failed');
  }
}

class _DelayedPermissionResponseAgentClient extends FakeAgentClient {
  final Completer<void> responseStarted = Completer<void>();
  final Completer<void> allowResponse = Completer<void>();
  int permissionResponseCount = 0;

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) async {
    permissionResponseCount += 1;
    if (!responseStarted.isCompleted) {
      responseStarted.complete();
    }
    await allowResponse.future;
    await super.respondToPermissionRequest(
      id: id,
      decision: decision,
      selectedOptionId: selectedOptionId,
    );
  }
}

class _NeverRespondingPermissionAgentClient extends FakeAgentClient {
  _NeverRespondingPermissionAgentClient({super.chunkDelay});

  final Completer<void> _response = Completer<void>();
  final Completer<void> permissionResponseStarted = Completer<void>();
  final List<AcpPermissionDecision> permissionDecisions =
      <AcpPermissionDecision>[];

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) {
    permissionDecisions.add(decision);
    if (!permissionResponseStarted.isCompleted) {
      permissionResponseStarted.complete();
    }
    return _response.future;
  }

  @override
  Future<void> dispose() async {
    if (!_response.isCompleted) _response.complete();
    await super.dispose();
  }
}

class _DelayedFailingPermissionAgentClient extends FakeAgentClient {
  _DelayedFailingPermissionAgentClient({super.chunkDelay});

  final Completer<void> _response = Completer<void>();

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) async {
    await _response.future;
    throw StateError('late permission response failed');
  }

  void failResponse() {
    if (!_response.isCompleted) _response.complete();
  }

  @override
  Future<void> dispose() async {
    failResponse();
    await super.dispose();
  }
}

class _CountingPermissionResponseAgentClient extends FakeAgentClient {
  int permissionResponseCount = 0;

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) async {
    permissionResponseCount += 1;
    await super.respondToPermissionRequest(
      id: id,
      decision: decision,
      selectedOptionId: selectedOptionId,
    );
  }
}

class _ToolCallChunkAgentClient extends FakeAgentClient {
  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'toolCallId': 'call-1',
        'title': 'Bash',
        'status': 'pending',
      },
    );
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'toolCallId': 'call-1',
        'title': 'Bash',
        'status': 'in_progress',
        'rawInput': '{"command"',
      },
    );
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'toolCallId': 'call-1',
        'title': 'Bash',
        'status': 'completed',
        'rawInput': {'command': 'echo hi'},
        'rawOutput': 'hi',
      },
    );
    yield AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      timestamp: DateTime(2026, 5, 28, 12),
    );
  }
}

class _AliasToolCallChunkAgentClient extends FakeAgentClient {
  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'id': 'call-1',
        'title': 'Bash',
        'status': 'pending',
      },
    );
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'callId': 'call-1',
        'title': 'Bash',
        'status': 'completed',
        'rawOutput': 'hi',
      },
    );
    yield AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      timestamp: DateTime(2026, 5, 28, 12),
    );
  }
}

class _SnakeCaseToolCallChunkAgentClient extends FakeAgentClient {
  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'tool_call_id': 'call-1',
        'title': 'Bash',
        'status': 'pending',
      },
    );
    yield AgentEvent(
      type: AgentEventType.toolCall,
      text: 'Bash',
      metadata: const <String, Object?>{
        'kind': 'tool',
        'tool_call_id': 'call-1',
        'title': 'Bash',
        'status': 'completed',
        'raw_output': 'hi',
      },
    );
    yield AgentEvent(
      type: AgentEventType.agentTextDone,
      text: '',
      timestamp: DateTime(2026, 5, 28, 12),
    );
  }
}

class _ThrowingPromptAgentClient extends FakeAgentClient {
  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    throw StateError('prompt setup failed');
  }
}

class _FakePermissionReviewer extends AcpPermissionReviewer {
  _FakePermissionReviewer(this.result, {this.canAutoApprove = true});

  final AcpPermissionReviewResult result;
  @override
  final bool canAutoApprove;
  final List<AcpPermissionRequest> requests = <AcpPermissionRequest>[];
  final List<String> workspaceRoots = <String>[];
  final List<List<String>> additionalDirectories = <List<String>>[];
  final List<String?> models = <String?>[];

  @override
  Future<AcpPermissionReviewResult?> review(
    AcpPermissionRequest request, {
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
    String? model,
  }) async {
    requests.add(request);
    workspaceRoots.add(workspaceRoot);
    this.additionalDirectories.add(additionalDirectories);
    models.add(model);
    return result;
  }
}

class _DelayedPermissionReviewer extends AcpPermissionReviewer {
  final Completer<AcpPermissionReviewResult?> _result =
      Completer<AcpPermissionReviewResult?>();
  final List<AcpPermissionRequest> requests = <AcpPermissionRequest>[];

  void complete(AcpPermissionReviewResult? result) {
    _result.complete(result);
  }

  @override
  Future<AcpPermissionReviewResult?> review(
    AcpPermissionRequest request, {
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
    String? model,
  }) {
    requests.add(request);
    return _result.future;
  }
}

class _SequencedPermissionReviewer extends AcpPermissionReviewer {
  final List<AcpPermissionRequest> requests = <AcpPermissionRequest>[];
  final List<Completer<AcpPermissionReviewResult?>> _results =
      <Completer<AcpPermissionReviewResult?>>[];

  @override
  bool get canAutoApprove => true;

  void complete(int index, AcpPermissionReviewResult? result) {
    _results[index].complete(result);
  }

  @override
  Future<AcpPermissionReviewResult?> review(
    AcpPermissionRequest request, {
    required String workspaceRoot,
    List<String> additionalDirectories = const <String>[],
    String? model,
  }) {
    requests.add(request);
    final result = Completer<AcpPermissionReviewResult?>();
    _results.add(result);
    return result.future;
  }
}

class _OpenErrorEventAgentClient extends FakeAgentClient {
  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    late final StreamController<AgentEvent> controller;
    controller = StreamController<AgentEvent>(
      onListen: () {
        controller.add(
          AgentEvent(
            type: AgentEventType.error,
            text: 'agent event failed',
            timestamp: DateTime(2026, 5, 28, 12),
          ),
        );
      },
      onCancel: () => controller.close(),
    );
    return controller.stream;
  }
}

class _LocallyClosingFailingAgentClient extends FakeAgentClient {
  _LocallyClosingFailingAgentClient({
    required Object closeError,
    super.permissionResponseError,
  }) : super(closeError: closeError);

  final List<String> locallyClosedSessionIds = <String>[];
  final List<String> remotelyResumedSessionIds = <String>[];

  @override
  Future<void> closeSession({required String sessionId}) {
    locallyClosedSessionIds.add(sessionId);
    return super.closeSession(sessionId: sessionId);
  }

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) {
    remotelyResumedSessionIds.add(sessionId);
    return super.resumeSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }
}

class _DisposalRaceCloseAgentClient extends FakeAgentClient {
  final Completer<void> closeStarted = Completer<void>();
  final Completer<void> allowClose = Completer<void>();
  int permissionResponseCount = 0;

  @override
  Future<void> closeSession({required String sessionId}) async {
    if (!closeStarted.isCompleted) closeStarted.complete();
    await allowClose.future;
  }

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) async {
    permissionResponseCount += 1;
    await super.respondToPermissionRequest(
      id: id,
      decision: decision,
      selectedOptionId: selectedOptionId,
    );
  }
}

class _DelayedForkAgentClient extends FakeAgentClient {
  final Completer<void> forkStarted = Completer<void>();
  final Completer<void> allowFork = Completer<void>();

  @override
  Future<AgentSession> forkSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (!forkStarted.isCompleted) {
      forkStarted.complete();
    }
    await allowFork.future;
    return super.forkSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }
}

class _DelayedSettingsMutationAgentClient extends FakeAgentClient {
  _DelayedSettingsMutationAgentClient({super.sessionSettings});

  final Completer<void> modeStarted = Completer<void>();
  final Completer<void> allowMode = Completer<void>();
  final Completer<void> configStarted = Completer<void>();
  final Completer<void> allowConfig = Completer<void>();

  @override
  Future<bool> setSessionMode({
    required String sessionId,
    required String modeId,
  }) async {
    if (!modeStarted.isCompleted) {
      modeStarted.complete();
    }
    await allowMode.future;
    return super.setSessionMode(sessionId: sessionId, modeId: modeId);
  }

  @override
  Future<List<AcpConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
  }) async {
    if (!configStarted.isCompleted) {
      configStarted.complete();
    }
    await allowConfig.future;
    return super.setConfigOption(
      sessionId: sessionId,
      configId: configId,
      value: value,
    );
  }
}

class _AgentNamedCatalogClient extends FakeAgentClient {
  @override
  Future<List<AcpProjectSessions>> listSessions() async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    return [
      AcpProjectSessions(
        cwd: '/workspace/project',
        sessions: [
          AcpSessionEntry(
            id: 'session-fast',
            cwd: '/workspace/project',
            title: 'Fast session',
            updatedAt: DateTime(2026, 5, 28, 12),
            meta: const {'agentName': 'codex-fast'},
          ),
        ],
      ),
    ];
  }
}

class _MutableBindingCatalogClient extends FakeAgentClient {
  _MutableBindingCatalogClient({required this.projects});

  List<AcpProjectSessions> projects;
  int resumeCalls = 0;

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) {
    resumeCalls += 1;
    return super.resumeSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }

  @override
  Future<List<AcpProjectSessions>> listSessions() async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    return projects;
  }
}

class _WhitespaceCreatedSessionCatalogClient
    extends _MutableBindingCatalogClient {
  _WhitespaceCreatedSessionCatalogClient({required super.projects});

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    return AgentSession(
      id: ' raw-session ',
      cwd: cwd,
      createdAt: DateTime(2026, 7, 15, 11),
      additionalDirectories: additionalDirectories,
    );
  }
}

class _StaleSessionSettingsAgentClient extends FakeAgentClient {
  final Completer<void> staleRefreshStarted = Completer<void>();
  final Completer<void> allowStaleRefresh = Completer<void>();
  int _originalSessionSettingsCalls = 0;

  @override
  Future<AcpSessionSettings> sessionSettings(String sessionId) async {
    if (sessionId == 'fake-session-1') {
      _originalSessionSettingsCalls += 1;
      if (_originalSessionSettingsCalls == 1) {
        return _settingsWithMode('ask');
      }
      if (!staleRefreshStarted.isCompleted) {
        staleRefreshStarted.complete();
      }
      await allowStaleRefresh.future;
      return _settingsWithMode('ask');
    }
    if (sessionId.startsWith('fake-fork-')) {
      return _settingsWithMode('edit');
    }
    return super.sessionSettings(sessionId);
  }
}

class _ControlledPromptAgentClient extends FakeAgentClient {
  final StreamController<AgentEvent> _events = StreamController<AgentEvent>(
    sync: true,
  );

  void emit(AgentEvent event) => _events.add(event);

  Future<void> finishPrompt() => _events.close();

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    lastPrompt = prompt;
    lastAttachments = attachments;
    return _events.stream;
  }

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) await _events.close();
    await super.dispose();
  }
}

class _LateEventAgentClient extends FakeAgentClient {
  void Function(AgentEvent)? _onData;

  void emit(AgentEvent event) => _onData?.call(event);

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    lastPrompt = prompt;
    return _LateEventStream((onData) => _onData = onData);
  }
}

class _LateEventStream extends Stream<AgentEvent> {
  _LateEventStream(this.onListen);

  final void Function(void Function(AgentEvent)? onData) onListen;

  @override
  StreamSubscription<AgentEvent> listen(
    void Function(AgentEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    onListen(onData);
    return const _LateEventSubscription();
  }
}

class _LateEventSubscription implements StreamSubscription<AgentEvent> {
  const _LateEventSubscription();

  @override
  Future<void> cancel() async {}

  @override
  void onData(void Function(AgentEvent data)? handleData) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReportedLengthResourceMap extends MapBase<String, Object?> {
  _ReportedLengthResourceMap(this.canary);

  final String canary;

  @override
  int get length => 1;

  @override
  Iterable<String> get keys => <String>['uri', canary];

  @override
  Object? operator [](Object? key) => key == 'uri' ? 'u' : canary;

  @override
  void operator []=(String key, Object? value) => throw UnsupportedError('');

  @override
  void clear() => throw UnsupportedError('');

  @override
  Object? remove(Object? key) => throw UnsupportedError('');
}

class _ThrowingEqualityValue {
  int equalityCalls = 0;

  @override
  bool operator ==(Object other) {
    equalityCalls += 1;
    throw StateError('hostile equality');
  }

  @override
  int get hashCode => 0;
}

class _TrueEqualityValue {
  int equalityCalls = 0;

  @override
  bool operator ==(Object other) {
    equalityCalls += 1;
    return true;
  }

  @override
  int get hashCode => 0;
}

class _ThrowingIndexUsageCostMap extends MapBase<String, Object?> {
  _ThrowingIndexUsageCostMap(this.canary);

  final String canary;
  int indexReads = 0;

  @override
  Iterable<MapEntry<String, Object?>> get entries =>
      <MapEntry<String, Object?>>[
        const MapEntry<String, Object?>('amount', 1),
        MapEntry<String, Object?>('currency', <Object?>[canary]),
      ];

  @override
  Iterable<String> get keys => const <String>['amount', 'currency'];

  @override
  Object? operator [](Object? key) {
    indexReads += 1;
    throw StateError(canary);
  }

  @override
  void operator []=(String key, Object? value) => throw UnsupportedError('');

  @override
  void clear() => throw UnsupportedError('');

  @override
  Object? remove(Object? key) => throw UnsupportedError('');
}

class _ThrowingMetadataMap implements Map<String, Object?> {
  _ThrowingMetadataMap(this.canary);

  final String canary;

  @override
  Object? operator [](Object? key) => throw StateError(canary);

  @override
  Iterable<MapEntry<String, Object?>> get entries => throw StateError(canary);

  @override
  int get length => throw StateError(canary);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(canary);
}

class _CountingThrowingMetadataMap implements Map<String, Object?> {
  int accesses = 0;

  Never _fail() {
    accesses += 1;
    throw const FormatException('late metadata must not be accessed');
  }

  @override
  Object? operator [](Object? key) => _fail();

  @override
  Iterable<MapEntry<String, Object?>> get entries => _fail();

  @override
  int get length => _fail();

  @override
  dynamic noSuchMethod(Invocation invocation) => _fail();
}

class _StatefulTypedConfigMetadataMap implements Map<String, Object?> {
  _StatefulTypedConfigMetadataMap(this.canary);

  final String canary;
  int entriesReads = 0;

  @override
  int get length => 2;

  @override
  Iterable<MapEntry<String, Object?>> get entries {
    entriesReads += 1;
    if (entriesReads == 1) {
      return <MapEntry<String, Object?>>[
        const MapEntry<String, Object?>('kind', 'config_option_update'),
        MapEntry<String, Object?>('configOptions', <AcpConfigOption>[
          AcpConfigOption(
            id: canary,
            name: 'Valid',
            type: 'select',
            currentValue: 'on',
            options: <AcpConfigOptionChoice>[],
          ),
        ]),
      ];
    }
    return <MapEntry<String, Object?>>[
      const MapEntry<String, Object?>('unknown', true),
      MapEntry<String, Object?>('payload', canary),
    ];
  }

  @override
  Object? operator [](Object? key) => throw StateError(canary);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(canary);
}

class _StatefulConfigOptionsList implements List<Object?> {
  int lengthReads = 0;
  int indexReads = 0;

  @override
  int get length {
    lengthReads += 1;
    return 1;
  }

  @override
  set length(int value) => throw UnsupportedError('fixed');

  @override
  Object? operator [](int index) {
    indexReads += 1;
    throw const FormatException('stateful option access');
  }

  @override
  void operator []=(int index, Object? value) {
    throw UnsupportedError('fixed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CanaryPayload {
  int toStringCalls = 0;

  @override
  String toString() {
    toStringCalls += 1;
    return 'SNAPSHOT_PAYLOAD_CANARY';
  }
}

class _ThrowingReadList<T> extends ListBase<T> {
  @override
  int get length => 1;

  @override
  set length(int value) => throw UnsupportedError('fixed');

  @override
  T operator [](int index) {
    throw const FormatException('hostile settings list access');
  }

  @override
  void operator []=(int index, T value) {
    throw UnsupportedError('fixed');
  }
}

class _ThrowingChatMessageList extends ListBase<ChatMessage> {
  _ThrowingChatMessageList(this.canary);

  final String canary;

  @override
  int get length => 1;

  @override
  set length(int value) => throw UnsupportedError('fixed');

  @override
  ChatMessage operator [](int index) => throw StateError(canary);

  @override
  void operator []=(int index, ChatMessage value) {
    throw UnsupportedError('fixed');
  }
}

class _ThrowingStringList extends ListBase<String> {
  _ThrowingStringList(this.canary);

  final String canary;

  @override
  int get length => 1;

  @override
  set length(int value) => throw UnsupportedError('fixed');

  @override
  String operator [](int index) => throw StateError(canary);

  @override
  void operator []=(int index, String value) {
    throw UnsupportedError('fixed');
  }
}

class _GrowingLengthList<T> extends ListBase<T> {
  _GrowingLengthList(this.seed, this.canary);

  final T seed;
  final String canary;
  int lengthReads = 0;

  @override
  int get length {
    lengthReads += 1;
    return lengthReads == 1 ? 1 : 2;
  }

  @override
  set length(int value) => throw UnsupportedError('fixed');

  @override
  T operator [](int index) {
    if (index == 0) return seed;
    throw StateError(canary);
  }

  @override
  void operator []=(int index, T value) {
    throw UnsupportedError('fixed');
  }
}

class _ArchivedSessionSnapshotSubclass extends ArchivedSessionSnapshot {
  _ArchivedSessionSnapshotSubclass({required super.messages})
    : super(
        session: AgentSession(
          id: 'subclass-session',
          cwd: '/workspace',
          createdAt: DateTime(2026, 7, 13, 12, 30),
        ),
        wasCurrent: false,
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: const AcpSessionSettings(),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
      );
}

class _ThrowingWasCurrentArchivedSnapshot extends ArchivedSessionSnapshot {
  _ThrowingWasCurrentArchivedSnapshot({required this.canary})
    : super(
        session: AgentSession(
          id: 'hostile-was-current',
          cwd: '/workspace',
          createdAt: DateTime(2026, 7, 13, 14, 30),
        ),
        wasCurrent: false,
        messages: const <ChatMessage>[],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: const AcpSessionSettings(),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
      );

  final String canary;
  int wasCurrentReads = 0;

  @override
  bool get wasCurrent {
    wasCurrentReads += 1;
    throw StateError(canary);
  }
}

class _StatefulWasCurrentArchivedSnapshot extends ArchivedSessionSnapshot {
  _StatefulWasCurrentArchivedSnapshot()
    : super(
        session: AgentSession(
          id: 'stateful-was-current',
          cwd: '/workspace',
          createdAt: DateTime(2026, 7, 13, 15),
        ),
        wasCurrent: true,
        messages: const <ChatMessage>[],
        availableCommands: const <Map<String, Object?>>[],
        lastLatency: null,
        lastError: null,
        sessionSettings: const AcpSessionSettings(),
        sessionUsage: null,
        sessionSettingsLoading: false,
        status: app_state.ConnectionStatus.sessionReady,
        activeSessionSettingsLoadId: null,
      );

  int wasCurrentReads = 0;

  @override
  bool get wasCurrent {
    wasCurrentReads += 1;
    if (wasCurrentReads > 1) {
      throw StateError('wasCurrent read more than once');
    }
    return true;
  }
}

final class _ControlledRestoreAgentClient extends FakeAgentClient {
  final Completer<void> firstEventDelivered = Completer<void>();
  final Completer<void> releaseRestore = Completer<void>();

  @override
  Future<AcpSessionRestoreSummary> restoreSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    bool replayHistory = true,
    required AcpSessionRestoreEventObserver onEvent,
  }) async {
    onEvent(
      const AgentEvent(type: AgentEventType.toolCall, text: 'canonical tool'),
    );
    firstEventDelivered.complete();
    await releaseRestore.future;
    onEvent(const AgentEvent(type: AgentEventType.agentTextDone, text: ''));
    return const AcpSessionRestoreSummary(eventCount: 2, replayedHistory: true);
  }
}

final class _MemoryTranscriptCache implements SessionTranscriptCache {
  _MemoryTranscriptCache(this.snapshot);

  SessionTranscriptSnapshot? snapshot;

  @override
  Future<SessionTranscriptSnapshot?> load(
    SessionTranscriptIdentity identity,
  ) async {
    final current = snapshot;
    return current != null && current.identity.matches(identity)
        ? current
        : null;
  }

  @override
  Future<void> save(SessionTranscriptSnapshot snapshot) async {
    this.snapshot = snapshot;
  }
}

final class _YieldProbeMetadataMap extends MapBase<String, Object?> {
  _YieldProbeMetadataMap(this._onEntriesRead);

  final void Function() _onEntriesRead;
  final Map<String, Object?> _values = <String, Object?>{
    'probe': 'cooperative reconstruction',
  };
  bool _didProbe = false;

  @override
  Iterable<MapEntry<String, Object?>> get entries {
    if (!_didProbe) {
      _didProbe = true;
      _onEntriesRead();
      final timer = Stopwatch()..start();
      while (timer.elapsed < const Duration(milliseconds: 6)) {}
    }
    return _values.entries;
  }

  @override
  Object? operator [](Object? key) => _values[key];

  @override
  void operator []=(String key, Object? value) => _values[key] = value;

  @override
  void clear() => _values.clear();

  @override
  Iterable<String> get keys => _values.keys;

  @override
  Object? remove(Object? key) => _values.remove(key);
}

AcpSessionSettings _settingsWithMode(String modeId) {
  return AcpSessionSettings(
    modes: AcpSessionModeInfo(
      currentModeId: modeId,
      availableModes: const [
        AcpSessionMode(id: 'ask', name: 'Ask'),
        AcpSessionMode(id: 'edit', name: 'Edit'),
      ],
    ),
  );
}
