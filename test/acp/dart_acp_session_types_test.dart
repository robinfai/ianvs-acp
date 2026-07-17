// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart';
import 'package:dart_acp/src/rpc/peer.dart'
    show JsonRpcPeer, requireJsonRpcObjectResult;
import 'package:dart_acp/src/session/session_manager.dart'
    show InitializeResult, SessionManager;
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';

void main() {
  test('JSON-RPC result type guard returns a map without traversing it', () {
    final source = _PeerCountingMap(<String, dynamic>{'value': true});

    final result = requireJsonRpcObjectResult(
      source,
      resource: 'ACP initialize result',
    );

    expect(identical(result, source), isTrue);
    expect(source.entriesVisited, 0);
  });

  test('JSON-RPC initialize and sendRaw reject non-object results', () async {
    for (final method in <String>['initialize', 'test/raw']) {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <Object?>['result-shape-secret'],
          }),
        );
      });

      try {
        final response = method == 'initialize'
            ? peer.initialize(<String, dynamic>{})
            : peer.sendRaw(method, <String, dynamic>{});
        await expectLater(
          response,
          throwsA(
            isA<FormatException>()
                .having(
                  (error) => error.message,
                  'message',
                  'JSON-RPC $method result must be a JSON object.',
                )
                .having(
                  (error) => error.toString(),
                  'payload-free',
                  isNot(contains('result-shape-secret')),
                ),
          ),
        );
      } finally {
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    }
  });

  test('initialize result treats capability objects as supported', () {
    final result = InitializeResult(
      protocolVersion: 1,
      agentCapabilities: <String, dynamic>{
        'loadSession': <String, dynamic>{},
        'sessionCapabilities': <String, dynamic>{
          'list': <String, dynamic>{},
          'resume': true,
          'fork': <String, dynamic>{},
          'configOptions': <String, dynamic>{},
          'additionalDirectories': <String, dynamic>{},
        },
      },
      authMethods: const <Map<String, dynamic>>[],
    );

    expect(result.supportsLoadSession, isTrue);
    expect(result.supportsListSessions, isTrue);
    expect(result.supportsResumeSession, isTrue);
    expect(result.supportsForkSession, isTrue);
    expect(result.sessionCapabilities.configOptions, isTrue);
    expect(result.supportsAdditionalDirectories, isTrue);
  });

  test(
    'session manager initialize enforces shared UTF-8 byte budget',
    () async {
      const secret = '秘密';
      final atBoundary = await _initializeSessionManagerWithInput(
        result: <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{'token': secret},
          'authMethods': <Object?>[],
          'agentInfo': <String, dynamic>{},
        },
        inputBudget: const AcpInputBudget(maxCapabilityBytes: 11),
      );
      expect(atBoundary.agentCapabilities?['token'], secret);

      await expectLater(
        _initializeSessionManagerWithInput(
          result: <String, dynamic>{
            'protocolVersion': 1,
            'agentCapabilities': <String, dynamic>{'token': secret},
            'authMethods': <Object?>[],
            'agentInfo': <String, dynamic>{},
          },
          inputBudget: const AcpInputBudget(maxCapabilityBytes: 10),
        ),
        throwsA(
          isA<AcpInputLimitExceeded>()
              .having((error) => error.limit, 'limit', 10)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 11)
              .having(
                (error) => error.toString(),
                'payload-free',
                isNot(contains(secret)),
              ),
        ),
      );
    },
  );

  test('session manager initialize prechecks auth method count', () async {
    final atBoundary = await _initializeSessionManagerWithInput(
      result: <String, dynamic>{
        'protocolVersion': 1,
        'agentCapabilities': <String, dynamic>{},
        'authMethods': <Object?>[
          <String, dynamic>{'id': 'one'},
          <String, dynamic>{'id': 'two'},
        ],
        'agentInfo': <String, dynamic>{},
      },
      inputBudget: const AcpInputBudget(maxAuthMethods: 2),
    );
    expect(atBoundary.authMethods, hasLength(2));

    await expectLater(
      _initializeSessionManagerWithInput(
        result: <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Object?>[
            <String, dynamic>{'id': 'one'},
            <String, dynamic>{'id': 'two'},
            <String, dynamic>{'id': 'auth-secret'},
          ],
          'agentInfo': <String, dynamic>{},
        },
        inputBudget: const AcpInputBudget(maxAuthMethods: 2),
      ),
      throwsA(
        isA<AcpInputLimitExceeded>()
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

  test('session manager initialize rejects wrong auth method shapes', () async {
    const secret = 'session-auth-shape-secret';
    for (final authMethods in <Object?>[
      secret,
      <Object?>[
        const <String, dynamic>{'id': 'valid'},
        secret,
      ],
    ]) {
      await expectLater(
        _initializeSessionManagerWithInput(
          result: <String, dynamic>{
            'protocolVersion': 1,
            'agentCapabilities': <String, dynamic>{},
            'authMethods': authMethods,
            'agentInfo': <String, dynamic>{},
          },
          inputBudget: const AcpInputBudget(),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'payload-free',
            isNot(contains(secret)),
          ),
        ),
      );
    }
  });

  test('session manager runtime-validates input budget construction', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    try {
      expect(
        () => SessionManager(
          config: AcpConfig(),
          peer: peer,
          inputBudget: AcpInputBudget(maxCapabilityBytes: 0),
        ),
        throwsA(isA<ArgumentError>()),
      );
    } finally {
      await peer.close();
      await channel.local.sink.close();
    }
  });

  test(
    'AcpClient rejects invalid input budget before transport start',
    () async {
      final transport = _TrackingTransport();
      try {
        await expectLater(
          Future<void>.sync(() async {
            await AcpClient.start(
              config: AcpConfig(),
              transport: transport,
              inputBudget: AcpInputBudget(maxCapabilityBytes: 0),
            );
          }),
          throwsA(isA<ArgumentError>()),
        );
        expect(transport.started, isFalse);
      } finally {
        await transport.close();
      }
    },
  );

  test('session capabilities do not treat false or null as supported', () {
    final capabilities = SessionCapabilities.fromJson(<String, dynamic>{
      'sessionCapabilities': <String, dynamic>{
        'list': false,
        'resume': null,
        'fork': true,
        'configOptions': <String, dynamic>{},
        'additionalDirectories': false,
      },
    });

    expect(capabilities.list, isFalse);
    expect(capabilities.resume, isFalse);
    expect(capabilities.fork, isTrue);
    expect(capabilities.configOptions, isTrue);
    expect(capabilities.additionalDirectories, isFalse);
  });

  test('legacy session capability object uses the same support rules', () {
    final capabilities = SessionCapabilities.fromJson(<String, dynamic>{
      'session': <String, dynamic>{
        'list': <String, dynamic>{},
        'resume': false,
        'fork': null,
        'configOptions': true,
        'additionalDirectories': true,
      },
    });

    expect(capabilities.list, isTrue);
    expect(capabilities.resume, isFalse);
    expect(capabilities.fork, isFalse);
    expect(capabilities.configOptions, isTrue);
    expect(capabilities.additionalDirectories, isTrue);
  });

  test('session capabilities accept snake case additional directories', () {
    final capabilities = SessionCapabilities.fromJson(<String, dynamic>{
      'sessionCapabilities': <String, dynamic>{
        'additional_directories': <String, dynamic>{},
      },
    });

    expect(capabilities.additionalDirectories, isTrue);
  });

  test('session info parses additional directories', () {
    final session = SessionInfo.fromJson(<String, dynamic>{
      'sessionId': 'session-1',
      'cwd': '/workspace',
      'additionalDirectories': <Object>[
        '/workspace-extra',
        ' /workspace-other ',
        '/workspace-extra',
      ],
    });

    expect(session.additionalDirectories, [
      '/workspace-extra',
      '/workspace-other',
    ]);
    expect(session.toJson(), {
      'sessionId': 'session-1',
      'cwd': '/workspace',
      'additionalDirectories': ['/workspace-extra', '/workspace-other'],
    });
  });

  test('content blocks accept legacy text, image, and resource payloads', () {
    final delta = MessageDelta.fromRaw(
      role: 'assistant',
      rawContent: <Map<String, dynamic>>[
        <String, dynamic>{'content': 'hello from content'},
        <String, dynamic>{
          'type': 'image',
          'mime_type': 'image/png',
          'base64': 'aW1hZ2U=',
        },
        <String, dynamic>{
          'type': 'audio',
          'mime_type': 'audio/wav',
          'base64': 'YXVkaW8=',
        },
        <String, dynamic>{
          'type': 'resource',
          'resource': <String, dynamic>{
            'url': 'file:///workspace/README.md',
            'name': 'README.md',
            'mime_type': 'text/markdown',
            'content': '# Project notes',
          },
        },
        <String, dynamic>{
          'type': 'resourceLink',
          'path': 'file:///workspace/lib/main.dart',
          'label': 'main.dart',
        },
      ],
    );

    expect(delta.text, 'hello from content');
    expect(delta.content[0], isA<TextContent>());
    expect(delta.content[1].toJson(), {
      'type': 'image',
      'mimeType': 'image/png',
      'data': 'aW1hZ2U=',
    });
    expect(delta.content[2].toJson(), {
      'type': 'audio',
      'mimeType': 'audio/wav',
      'data': 'YXVkaW8=',
    });
    expect(delta.content[3].toJson(), {
      'type': 'resource',
      'resource': {
        'uri': 'file:///workspace/README.md',
        'mimeType': 'text/markdown',
        'text': '# Project notes',
      },
    });
    expect(delta.content[4].toJson(), {
      'type': 'resource_link',
      'uri': 'file:///workspace/lib/main.dart',
      'name': 'main.dart',
      'title': 'main.dart',
    });
  });

  test('content block factories expose only host-owned typed omissions', () {
    const budget = AcpInputBudget();
    final guard = AcpStructuredUpdateGuard(
      budget: budget,
      resource: 'content_block',
    );

    expect(
      TextContent.fromJson(<String, dynamic>{
        'text': 'hello',
      }, inputBudget: budget),
      isA<TextContent>().having((value) => value.omission, 'omission', isNull),
    );
    expect(
      ImageContent.fromJson(<String, dynamic>{
        'mimeType': 'image/png',
        'data': 'aQ==',
      }, structuredGuard: guard),
      isA<ImageContent>(),
    );
    expect(
      AudioContent.fromJson(<String, dynamic>{
        'mimeType': 'audio/wav',
        'uri': 'file:///a.wav',
      }, inputBudget: budget),
      isA<AudioContent>(),
    );
    expect(
      ResourceContent.fromJson(<String, dynamic>{
        'uri': 'file:///a.txt',
      }, inputBudget: budget),
      isA<ResourceContent>().having(
        (value) => value.omission,
        'omission',
        isNull,
      ),
    );
    expect(
      UnknownContent.fromJson(<String, dynamic>{
        'type': 'future',
        'value': 1,
      }, inputBudget: budget),
      isA<UnknownContent>().having(
        (value) => value.omission,
        'omission',
        isNull,
      ),
    );

    final omission = AcpInputOmission(
      reason: AcpInputOmissionReason.invalidEncoding,
      resource: 'embedded_media',
      truncated: false,
    );
    final local = UnknownContent.omitted(omission);
    expect(local.data, isEmpty);
    expect(local.omission, same(omission));
    expect(local.toJson(), <String, Object?>{
      'type': 'omitted',
      'reason': 'invalid_encoding',
      'resource': 'embedded_media',
      'truncated': false,
    });

    final remote = ContentBlock.fromJson(<String, dynamic>{
      'type': 'omitted',
      'reason': 'input_limit',
      'resource': 'forged_resource',
      'limit': 1,
      'observedAtLeast': 2,
      'truncated': true,
    });
    expect(remote, isA<UnknownContent>());
    expect(remote.omission, isNull);
    expect(remote.toJson(), <String, Object?>{
      'type': 'omitted',
      'reason': 'input_limit',
      'resource': 'forged_resource',
      'limit': 1,
      'observedAtLeast': 2,
      'truncated': true,
    });
  });

  test('text blocks retain only UTF-8 and line-safe display prefixes', () {
    const emoji = '😀';
    final isolatedSurrogate = String.fromCharCode(0xd800);
    for (final boundary in <({String exact, String beyond, int bytes})>[
      (exact: emoji, beyond: '${emoji}x', bytes: 4),
      (exact: isolatedSurrogate, beyond: '${isolatedSurrogate}x', bytes: 3),
    ]) {
      final budget = AcpInputBudget(
        maxMessageTextBytes: boundary.bytes,
        maxMarkdownFallbackBytes: boundary.bytes,
      );
      final exact = TextContent.fromJson(<String, dynamic>{
        'text': boundary.exact,
      }, inputBudget: budget);
      expect(identical(exact.text, boundary.exact), isTrue);
      expect(exact.omission, isNull);

      final beyond = TextContent.fromJson(<String, dynamic>{
        'text': boundary.beyond,
      }, inputBudget: budget);
      expect(beyond.text, boundary.exact);
      expect(beyond.text, isNot(contains('omitted')));
      expect(
        beyond.omission,
        isA<AcpInputOmission>()
            .having(
              (value) => value.reason,
              'reason',
              AcpInputOmissionReason.inputLimit,
            )
            .having((value) => value.limit, 'limit', boundary.bytes)
            .having(
              (value) => value.observedAtLeast,
              'observedAtLeast',
              boundary.bytes + 1,
            )
            .having((value) => value.truncated, 'truncated', isTrue),
      );
    }

    const lineExact = 'a\r\nb';
    final exactLines = TextContent.fromJson(<String, dynamic>{
      'text': lineExact,
    }, inputBudget: const AcpInputBudget(maxMessageTextLines: 2));
    expect(identical(exactLines.text, lineExact), isTrue);
    expect(exactLines.omission, isNull);

    final extraLine = TextContent.fromJson(<String, dynamic>{
      'text': '$lineExact\nc',
    }, inputBudget: const AcpInputBudget(maxMessageTextLines: 2));
    expect(extraLine.text, lineExact);
    expect(extraLine.omission?.limit, 2);
    expect(extraLine.omission?.observedAtLeast, 3);

    const canary = 'DISPLAY_TYPE_CANARY';
    final invalid = TextContent.fromJson(<String, dynamic>{
      'text': <String>[canary],
    });
    expect(invalid.text, isEmpty);
    expect(invalid.omission?.reason, AcpInputOmissionReason.invalidStructure);
    expect(invalid.omission?.toString(), isNot(contains(canary)));
  });

  test('resource text uses its own display budget and omission carrier', () {
    const exactText = '😀';
    final exact = ResourceContent.fromJson(
      <String, dynamic>{'uri': 'file:///exact', 'text': exactText},
      inputBudget: const AcpInputBudget(
        maxMessageTextBytes: 4,
        maxMarkdownFallbackBytes: 4,
      ),
    );
    expect(identical(exact.text, exactText), isTrue);
    expect(exact.omission, isNull);

    final beyond = ResourceContent.fromJson(
      <String, dynamic>{'uri': 'file:///beyond', 'text': '${exactText}x'},
      inputBudget: const AcpInputBudget(
        maxMessageTextBytes: 4,
        maxMarkdownFallbackBytes: 4,
      ),
    );
    expect(beyond.uri, 'file:///beyond');
    expect(beyond.text, exactText);
    expect(beyond.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(beyond.omission?.truncated, isTrue);

    const canary = 'RESOURCE_TEXT_TYPE_CANARY';
    final invalid = ResourceContent.fromJson(<String, dynamic>{
      'uri': 'file:///invalid',
      'text': <String>[canary],
    });
    expect(invalid.uri, 'file:///invalid');
    expect(invalid.text, isEmpty);
    expect(invalid.omission?.reason, AcpInputOmissionReason.invalidStructure);
    expect(invalid.omission?.toString(), isNot(contains(canary)));
  });

  test('embedded media accepts decoded boundary without decoding', () {
    const budget = AcpInputBudget(maxEmbeddedMediaBytes: 3);
    const encoded = 'TWFu';

    final image = ImageContent.fromJson(<String, dynamic>{
      'mimeType': 'image/png',
      'data': encoded,
    }, inputBudget: budget);
    final audio = AudioContent.fromJson(<String, dynamic>{
      'mimeType': 'audio/wav',
      'data': encoded,
    }, inputBudget: budget);
    final resource = ResourceContent.fromJson(<String, dynamic>{
      'type': 'resource',
      'resource': <String, dynamic>{'uri': 'file:///embedded', 'blob': encoded},
    }, inputBudget: budget);

    expect(identical(image.data, encoded), isTrue);
    expect(identical(audio.data, encoded), isTrue);
    expect(identical(resource.blob, encoded), isTrue);
    final linkedAudio = AudioContent.fromJson(<String, dynamic>{
      'mimeType': 'audio/wav',
      'uri': 'file:///linked.wav',
    }, inputBudget: budget);
    expect(linkedAudio.uri, 'file:///linked.wav');
    expect(linkedAudio.toJson(), <String, dynamic>{
      'type': 'audio',
      'mimeType': 'audio/wav',
      'data': '',
    });
  });

  test('owning content boundary omits invalid media without payload leaks', () {
    const canary = 'MEDIA_MIME_CANARY';
    final invalidPayloads = <String>['TW E', '____', 'TR=='];
    for (final data in invalidPayloads) {
      final blocks = <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'image',
          'mimeType': 'image/$canary',
          'data': data,
        },
        <String, dynamic>{
          'type': 'audio',
          'mimeType': 'audio/$canary',
          'data': data,
        },
        <String, dynamic>{
          'type': 'resource',
          'resource': <String, dynamic>{'uri': 'file:///$canary', 'blob': data},
        },
      ];
      for (final input in blocks) {
        final block = ContentBlock.fromJson(input);
        expect(block, isA<UnknownContent>(), reason: input['type'] as String);
        expect(
          block.omission?.reason,
          AcpInputOmissionReason.invalidEncoding,
          reason: data,
        );
        expect(block.omission?.truncated, isFalse);
        final marker = block.toJson().toString();
        expect(marker, isNot(contains(data)));
        expect(marker, isNot(contains(canary)));
      }
    }
  });

  test('media capacity and structure failures have fixed owning semantics', () {
    const canary = 'MEDIA_CAPACITY_CANARY';
    const budget = AcpInputBudget(maxEmbeddedMediaBytes: 3);
    final oversized = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'image',
        'mimeType': 'image/$canary',
        'data': 'TWFuTQ==',
      },
      <String, dynamic>{
        'type': 'audio',
        'mimeType': 'audio/$canary',
        'data': 'TWFuTQ==',
      },
      <String, dynamic>{
        'type': 'resource',
        'resource': <String, dynamic>{
          'uri': 'file:///$canary',
          'blob': 'TWFuTQ==',
        },
      },
    ];
    for (final input in oversized) {
      final block = ContentBlock.fromJson(input, inputBudget: budget);
      expect(block, isA<UnknownContent>());
      expect(block.omission?.reason, AcpInputOmissionReason.inputLimit);
      expect(block.omission?.limit, 3);
      expect(block.omission?.observedAtLeast, 4);
      expect(block.toJson().toString(), isNot(contains(canary)));
      expect(block.toJson().toString(), isNot(contains('TWFuTQ==')));
    }

    const invalidData = 'MEDIA_STRUCTURE_CANARY';
    final malformed = <String, dynamic>{
      'type': 'image',
      'mimeType': 'image/png',
      'data': <String>[invalidData],
    };
    expect(
      () => ImageContent.fromJson(malformed),
      throwsA(
        isA<FormatException>().having(
          (error) => error.toString(),
          'payload-free',
          isNot(contains(invalidData)),
        ),
      ),
    );
    final omitted = ContentBlock.fromJson(malformed);
    expect(omitted.omission?.reason, AcpInputOmissionReason.invalidStructure);
    expect(omitted.toJson().toString(), isNot(contains(invalidData)));

    final shared = AcpStructuredUpdateGuard(
      budget: const AcpInputBudget(),
      resource: 'content_block',
    );
    final bad = ContentBlock.fromJson(<String, dynamic>{
      'type': 'image',
      'mimeType': 'image/png',
      'data': 'TW E',
    }, structuredGuard: shared);
    final good = ContentBlock.fromJson(<String, dynamic>{
      'type': 'text',
      'text': 'still valid',
    }, structuredGuard: shared);
    expect(bad.omission?.reason, AcpInputOmissionReason.invalidEncoding);
    expect(good, isA<TextContent>());
    expect((good as TextContent).text, 'still valid');
  });

  test('unknown content is deeply immutable and detached from its source', () {
    final nested = <String, Object?>{
      'list': <Object?>[
        <String, Object?>{'value': 1},
      ],
    };
    final source = <String, dynamic>{'type': 'future', 'nested': nested};

    final unknown = UnknownContent.fromJson(source);
    nested['added'] = true;
    (nested['list']! as List<Object?>).add('changed');
    source['later'] = 'changed';

    expect(unknown.data, <String, Object?>{
      'type': 'future',
      'nested': <String, Object?>{
        'list': <Object?>[
          <String, Object?>{'value': 1},
        ],
      },
    });
    expect(() => unknown.data['x'] = 1, throwsUnsupportedError);
    final unknownNested = unknown.data['nested']! as Map<String, Object?>;
    expect(() => unknownNested['x'] = 1, throwsUnsupportedError);
    final unknownList = unknownNested['list']! as List<Object?>;
    expect(() => unknownList.add(2), throwsUnsupportedError);

    final json = unknown.toJson();
    json['local'] = true;
    expect(unknown.data, isNot(contains('local')));
  });

  test(
    'unknown content enforces depth, nodes, bytes, and entries boundaries',
    () {
      final exactNodes = UnknownContent.fromJson(<String, dynamic>{
        'a': null,
      }, inputBudget: const AcpInputBudget(maxStructuredUpdateNodes: 3));
      expect(exactNodes.data, <String, Object?>{'a': null});
      final nodeLimit = ContentBlock.fromJson(<String, dynamic>{
        'a': null,
      }, inputBudget: const AcpInputBudget(maxStructuredUpdateNodes: 2));
      expect(nodeLimit.omission?.reason, AcpInputOmissionReason.inputLimit);
      expect(nodeLimit.omission?.limit, 2);
      expect(nodeLimit.omission?.observedAtLeast, 3);

      final exactBytes = UnknownContent.fromJson(<String, dynamic>{
        'a': null,
      }, inputBudget: const AcpInputBudget(maxStructuredUpdateBytes: 5));
      expect(exactBytes.data, <String, Object?>{'a': null});
      final byteLimit = ContentBlock.fromJson(<String, dynamic>{
        'a': null,
      }, inputBudget: const AcpInputBudget(maxStructuredUpdateBytes: 4));
      expect(byteLimit.omission?.reason, AcpInputOmissionReason.inputLimit);
      expect(byteLimit.omission?.limit, 4);
      expect(byteLimit.omission?.observedAtLeast, 5);

      expect(
        UnknownContent.fromJson(<String, dynamic>{
          'a': 1,
          'b': 2,
        }, inputBudget: const AcpInputBudget(maxCollectionItems: 2)).data,
        hasLength(2),
      );
      final entryLimit = ContentBlock.fromJson(<String, dynamic>{
        'a': 1,
        'b': 2,
      }, inputBudget: const AcpInputBudget(maxCollectionItems: 1));
      expect(entryLimit.omission?.reason, AcpInputOmissionReason.inputLimit);
      expect(entryLimit.omission?.limit, 1);
      expect(entryLimit.omission?.observedAtLeast, 2);

      expect(
        UnknownContent.fromJson(<String, dynamic>{
          'nested': <String, Object?>{'value': true},
        }, inputBudget: const AcpInputBudget(maxMetadataDepth: 3)).data,
        contains('nested'),
      );
      final depthLimit = ContentBlock.fromJson(<String, dynamic>{
        'nested': <String, Object?>{'value': true},
      }, inputBudget: const AcpInputBudget(maxMetadataDepth: 2));
      expect(depthLimit.omission?.reason, AcpInputOmissionReason.inputLimit);
      expect(depthLimit.omission?.limit, 2);
      expect(depthLimit.omission?.observedAtLeast, 3);
    },
  );

  test('unknown type is measured once while its full map remains bounded', () {
    final exact = ContentBlock.fromJson(
      <String, dynamic>{'type': 'future'},
      inputBudget: const AcpInputBudget(
        maxStructuredUpdateNodes: 3,
        maxStructuredUpdateBytes: 10,
      ),
    );
    expect(exact, isA<UnknownContent>());
    expect(exact.omission, isNull);

    final nodeLimit = ContentBlock.fromJson(
      <String, dynamic>{'type': 'future'},
      inputBudget: const AcpInputBudget(
        maxStructuredUpdateNodes: 2,
        maxStructuredUpdateBytes: 10,
      ),
    );
    expect(nodeLimit.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(nodeLimit.omission?.limit, 2);
    expect(nodeLimit.omission?.observedAtLeast, 3);

    final byteLimit = ContentBlock.fromJson(
      <String, dynamic>{'type': 'future'},
      inputBudget: const AcpInputBudget(
        maxStructuredUpdateNodes: 3,
        maxStructuredUpdateBytes: 9,
      ),
    );
    expect(byteLimit.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(byteLimit.omission?.limit, 9);
    expect(byteLimit.omission?.observedAtLeast, 10);
  });

  test('bounded content type dispatch preserves padded known types', () {
    final paddedType = 'text${' ' * 61}';
    expect(paddedType.length, 65);

    final block = ContentBlock.fromJson(
      <String, dynamic>{'type': paddedType, 'text': 'ab'},
      inputBudget: const AcpInputBudget(
        maxMessageTextBytes: 1,
        maxMarkdownFallbackBytes: 1,
      ),
    );

    expect(block, isA<TextContent>());
    expect((block as TextContent).text, 'a');
    expect(block.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(block.omission?.limit, 1);
    expect(block.omission?.observedAtLeast, 2);
  });

  test('content type UTF-8 string budget accepts exact and rejects +1', () {
    const exactType = 'text\u00a0';
    final exact = ContentBlock.fromJson(<String, dynamic>{
      'type': exactType,
      'text': 'ok',
    }, inputBudget: const AcpInputBudget(maxStructuredStringBytes: 6));
    expect(exact, isA<TextContent>());
    expect(exact.omission, isNull);

    final beyond = ContentBlock.fromJson(<String, dynamic>{
      'type': '$exactType ',
      'text': 'not retained',
    }, inputBudget: const AcpInputBudget(maxStructuredStringBytes: 6));
    expect(beyond, isA<UnknownContent>());
    expect(beyond.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(beyond.omission?.limit, 6);
    expect(beyond.omission?.observedAtLeast, 7);
    expect(beyond.toJson().toString(), isNot(contains('not retained')));
  });

  test(
    'unknown content rejects cycles, invalid keys, and non-finite values',
    () {
      const canary = 'UNKNOWN_PAYLOAD_CANARY';
      final cycle = <String, dynamic>{'value': canary};
      cycle['self'] = cycle;
      final invalidKey = <Object?, Object?>{1: canary}.cast<String, dynamic>();
      final invalidValues = <Map<String, dynamic>>[
        cycle,
        invalidKey,
        <String, dynamic>{'value': double.nan, 'canary': canary},
        <String, dynamic>{'value': double.infinity, 'canary': canary},
      ];

      for (final input in invalidValues) {
        expect(
          () => UnknownContent.fromJson(input),
          throwsA(
            allOf(
              anyOf(isA<FormatException>(), isA<TypeError>()),
              predicate<Object>(
                (error) => !error.toString().contains(canary),
                'payload-free',
              ),
            ),
          ),
        );
        final omitted = ContentBlock.fromJson(input);
        expect(omitted, isA<UnknownContent>());
        expect(
          omitted.omission?.reason,
          AcpInputOmissionReason.invalidStructure,
        );
        expect(omitted.toJson().toString(), isNot(contains(canary)));
      }
    },
  );

  test('unknown failure rolls back metadata budget on a shared guard', () {
    final guard = AcpStructuredUpdateGuard(
      budget: const AcpInputBudget(maxStructuredUpdateNodes: 3),
      resource: 'content_block',
    );
    final cycle = <String, dynamic>{};
    cycle['self'] = cycle;

    final bad = ContentBlock.fromJson(cycle, structuredGuard: guard);
    final good = ContentBlock.fromJson(<String, dynamic>{
      'text': 'good',
    }, structuredGuard: guard);

    expect(bad.omission?.reason, AcpInputOmissionReason.invalidStructure);
    expect(good, isA<TextContent>());
    expect((good as TextContent).text, 'good');
  });

  test('standalone display factories consume one model node each', () {
    final exact = AcpStructuredUpdateGuard(
      budget: const AcpInputBudget(maxStructuredUpdateNodes: 1),
      resource: 'content_block',
    );
    expect(
      TextContent.fromJson(<String, dynamic>{
        'text': 'first',
      }, structuredGuard: exact).text,
      'first',
    );

    final shared = AcpStructuredUpdateGuard(
      budget: const AcpInputBudget(maxStructuredUpdateNodes: 1),
      resource: 'content_block',
    );
    TextContent.fromJson(<String, dynamic>{
      'text': 'first',
    }, structuredGuard: shared);
    expect(
      () => TextContent.fromJson(<String, dynamic>{
        'text': 'second',
      }, structuredGuard: shared),
      throwsA(isA<AcpInputLimitExceeded>()),
    );
  });

  test('structured fields share bytes while display and media do not', () {
    final display = TextContent.fromJson(<String, dynamic>{
      'type': 'text',
      'text': 'x' * 100,
    }, inputBudget: const AcpInputBudget(maxStructuredUpdateBytes: 4));
    expect(display.text, 'x' * 100);
    expect(
      () => TextContent.fromJson(<String, dynamic>{
        'type': 'text',
        'text': 'x',
      }, inputBudget: const AcpInputBudget(maxStructuredUpdateBytes: 3)),
      throwsA(isA<AcpInputLimitExceeded>()),
    );

    final media = ImageContent.fromJson(<String, dynamic>{
      'type': 'image',
      'mimeType': 'image/png',
      'data': 'TWFu',
    }, inputBudget: const AcpInputBudget(maxStructuredUpdateBytes: 14));
    expect(media.data, 'TWFu');
    final limitedMedia = ContentBlock.fromJson(<String, dynamic>{
      'type': 'image',
      'mimeType': 'image/png',
      'data': 'TWFu',
    }, inputBudget: const AcpInputBudget(maxStructuredUpdateBytes: 13));
    expect(limitedMedia.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(limitedMedia.omission?.limit, 13);
    expect(limitedMedia.omission?.observedAtLeast, 14);
  });

  test('raw tool output omits embedded media data from structured text', () {
    final tool = ToolCall.fromJson(
      <String, dynamic>{
        'toolCallId': 'image-tool',
        'status': 'completed',
        'rawOutput': <String, Object?>{
          'image_url': 'data:image/png;base64,${'A' * 128}',
          'caption': 'kept',
        },
      },
      inputBudget: const AcpInputBudget(
        maxStructuredStringBytes: 32,
        maxStructuredUpdateBytes: 256,
      ),
    );

    expect(tool.omission, isNull);
    expect(tool.rawOutput, <String, Object?>{
      'image_url': '<media omitted>',
      'caption': 'kept',
    });
  });

  test('content blocks never reset a caller-owned structured guard', () {
    final exact = AcpStructuredUpdateGuard(
      budget: const AcpInputBudget(maxStructuredUpdateBytes: 2),
      resource: 'content_block',
    );
    expect(
      ContentBlock.fromJson(<String, dynamic>{
        'uri': 'a',
      }, structuredGuard: exact),
      isA<ResourceContent>(),
    );
    expect(
      ContentBlock.fromJson(<String, dynamic>{
        'uri': 'b',
      }, structuredGuard: exact),
      isA<ResourceContent>(),
    );

    final beyond = AcpStructuredUpdateGuard(
      budget: const AcpInputBudget(maxStructuredUpdateBytes: 1),
      resource: 'content_block',
    );
    expect(
      ContentBlock.fromJson(<String, dynamic>{
        'uri': 'a',
      }, structuredGuard: beyond),
      isA<ResourceContent>(),
    );
    final second = ContentBlock.fromJson(<String, dynamic>{
      'uri': 'b',
    }, structuredGuard: beyond);
    expect(second, isA<UnknownContent>());
    expect(second.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(second.omission?.limit, 1);
    expect(second.omission?.observedAtLeast, 2);
  });

  test('nested resources consume one bounded shared structure', () {
    final exact = ContentBlock.fromJson(
      <String, dynamic>{
        'resource': <String, dynamic>{'uri': 'a'},
      },
      inputBudget: const AcpInputBudget(
        maxStructuredUpdateNodes: 4,
        maxStructuredUpdateBytes: 4,
      ),
    );
    expect(exact, isA<ResourceContent>());
    expect((exact as ResourceContent).uri, 'a');

    final nodeLimit = ContentBlock.fromJson(
      <String, dynamic>{
        'resource': <String, dynamic>{'uri': 'a'},
      },
      inputBudget: const AcpInputBudget(
        maxStructuredUpdateNodes: 3,
        maxStructuredUpdateBytes: 4,
      ),
    );
    expect(nodeLimit.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(nodeLimit.omission?.limit, 3);
    expect(nodeLimit.omission?.observedAtLeast, 4);

    final byteLimit = ContentBlock.fromJson(
      <String, dynamic>{
        'resource': <String, dynamic>{'uri': 'a'},
      },
      inputBudget: const AcpInputBudget(
        maxStructuredUpdateNodes: 4,
        maxStructuredUpdateBytes: 3,
      ),
    );
    expect(byteLimit.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(byteLimit.omission?.limit, 3);
    expect(byteLimit.omission?.observedAtLeast, 4);

    final overridden = ContentBlock.fromJson(<String, dynamic>{
      'type': 'resource',
      'uri': 'a',
      'resource': <String, dynamic>{
        'uri': 'nested-too-long',
        'text': 'x' * 100,
      },
    }, inputBudget: const AcpInputBudget(maxStructuredStringBytes: 8));
    expect(overridden.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(overridden.omission?.limit, 8);
    expect(overridden.omission?.observedAtLeast, 9);
  });

  test('resource URI aliases preserve legacy outer and nested precedence', () {
    final cases = <({Map<String, dynamic> input, String expected})>[
      (
        input: <String, dynamic>{
          'type': 'resource',
          'url': 'file:///outer-url',
          'resource': <String, dynamic>{'uri': 'file:///nested-uri'},
        },
        expected: 'file:///nested-uri',
      ),
      (
        input: <String, dynamic>{
          'type': 'resource',
          'path': 'file:///outer-path',
          'resource': <String, dynamic>{
            'url': 'file:///nested-url',
            'uri': 'file:///nested-uri',
          },
        },
        expected: 'file:///nested-uri',
      ),
      (
        input: <String, dynamic>{
          'type': 'resource',
          'path': 'file:///outer-path',
          'resource': <String, dynamic>{'url': 'file:///nested-url'},
        },
        expected: 'file:///nested-url',
      ),
      (
        input: <String, dynamic>{
          'type': 'resource',
          'uri': 'file:///outer-uri',
          'resource': <String, dynamic>{'uri': 'file:///nested-uri'},
        },
        expected: 'file:///outer-uri',
      ),
      (
        input: <String, dynamic>{
          'uri': 'file:///outer-uri',
          'url': 'file:///outer-url',
          'path': 'file:///outer-path',
        },
        expected: 'file:///outer-uri',
      ),
      (
        input: <String, dynamic>{
          'url': 'file:///outer-url',
          'path': 'file:///outer-path',
        },
        expected: 'file:///outer-url',
      ),
      (
        input: <String, dynamic>{'path': 'file:///outer-path'},
        expected: 'file:///outer-path',
      ),
    ];

    for (final testCase in cases) {
      expect(
        ResourceContent.fromJson(testCase.input).uri,
        testCase.expected,
        reason: testCase.input.toString(),
      );
    }
  });

  test('structural field failures are fixed and retain no partial block', () {
    const canary = 'STRUCTURE_FIELD_CANARY';
    final malformed = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'image',
        'mimeType': <String>[canary],
        'data': 'TQ==',
      },
      <String, dynamic>{'type': 'image', 'mimeType': 'image/png', 'data': null},
      <String, dynamic>{
        'type': 'audio',
        'mimeType': 'audio/wav',
        'uri': <String>[canary],
      },
      <String, dynamic>{
        'type': 'resource_link',
        'uri': 'file:///a',
        'title': <String>[canary],
      },
      <String, dynamic>{
        'type': 'resource',
        'resource': <String, dynamic>{
          'uri': 'file:///a',
          'size': double.nan,
          'canary': canary,
        },
      },
    ];

    for (final input in malformed) {
      final omitted = ContentBlock.fromJson(input);
      expect(omitted, isA<UnknownContent>());
      expect(omitted.omission?.reason, AcpInputOmissionReason.invalidStructure);
      expect(omitted.toJson().toString(), isNot(contains(canary)));
    }
  });

  test('malicious content maps fail with fixed payload-free errors', () {
    const canary = 'MALICIOUS_MAP_CANARY';
    final malicious = <Map<String, dynamic>>[
      _ContentThrowingLengthMap(canary),
      _ContentThrowingGetterMap(canary),
      _ContentThrowingEntriesMap(canary),
    ];

    for (final input in malicious) {
      final block = ContentBlock.fromJson(input);
      expect(block, isA<UnknownContent>());
      expect(block.omission?.reason, AcpInputOmissionReason.invalidStructure);
      expect(block.toJson().toString(), isNot(contains(canary)));
    }

    expect(
      () => TextContent.fromJson(_ContentThrowingGetterMap(canary)),
      throwsA(
        predicate<Object>(
          (error) => !error.toString().contains(canary),
          'payload-free',
        ),
      ),
    );
    expect(
      () => UnknownContent.fromJson(_ContentThrowingEntriesMap(canary)),
      throwsA(
        predicate<Object>(
          (error) => !error.toString().contains(canary),
          'payload-free',
        ),
      ),
    );

    final nested = <String, dynamic>{
      'type': 'resource',
      'resource': _ContentThrowingEntriesMap(canary, unknownType: false),
    };
    final nestedBlock = ContentBlock.fromJson(nested);
    expect(
      nestedBlock.omission?.reason,
      AcpInputOmissionReason.invalidStructure,
    );
    expect(nestedBlock.toJson().toString(), isNot(contains(canary)));
  });

  test('tool calls accept legacy content and location payloads', () {
    final toolCall = ToolCall.fromJson(<String, dynamic>{
      'tool_call_id': 'call-1',
      'status': 'started',
      'name': 'Read file',
      'tool_kind': 'read',
      'content': 'reading now',
      'locations': <Object>[
        '/workspace/a.dart',
        <String, dynamic>{'path': '/workspace/b.dart', 'line': 12},
      ],
    });

    expect(toolCall.toolCallId, 'call-1');
    expect(toolCall.status, ToolCallStatus.pending);
    expect(toolCall.title, 'Read file');
    expect(toolCall.kind, ToolKind.read);
    expect(toolCall.content, [containsPair('text', 'reading now')]);
    expect(toolCall.locations?.map((location) => location.path), [
      '/workspace/a.dart',
      '/workspace/b.dart',
    ]);
    expect(toolCall.locations?.last.line, 12);

    final merged = toolCall.merge(<String, dynamic>{
      'status': 'completed',
      'toolName': 'Write file',
      'toolKind': 'edit',
      'content': <String, dynamic>{'type': 'text', 'text': 'done'},
      'locations': '/workspace/done.dart',
    });

    expect(merged.status, ToolCallStatus.completed);
    expect(merged.title, 'Write file');
    expect(merged.kind, ToolKind.edit);
    expect(merged.content, [containsPair('text', 'done')]);
    expect(merged.locations?.single.path, '/workspace/done.dart');
  });

  test(
    'session manager merges snake case tool call ids independently',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File('${tempDir.path}/fake_snake_tool_agent.dart');
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

void send(Map<String, dynamic> message) {
  stdout.writeln(jsonEncode(message));
}

void sendSessionUpdate(Map<String, dynamic> update) {
  send(<String, dynamic>{
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': <String, dynamic>{
      'sessionId': 'session-1',
      'update': update,
    },
  });
}

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      });
    } else if (message['method'] == 'session/new') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      });
    } else if (message['method'] == 'session/prompt') {
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'tool_call_id': 'call-a',
        'title': 'Bash A',
        'status': 'pending',
      });
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'tool_call_id': 'call-b',
        'title': 'Bash B',
        'status': 'pending',
      });
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'tool_call_update',
        'tool_call_id': 'call-a',
        'status': 'completed',
        'raw_output': 'a done',
      });
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'tool_call_update',
        'tool_call_id': 'call-b',
        'status': 'completed',
        'raw_output': 'b done',
      });
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      });
    }
  }
}
''');

      final client = await AcpClient.start(
        config: AcpConfig(
          agentCommand: _dartExecutable(),
          agentArgs: [agentScript.path],
        ),
      );
      final updates = <AcpUpdate>[];
      StreamSubscription<AcpUpdate>? subscription;

      try {
        await client.initialize().timeout(const Duration(seconds: 5));
        final sessionId = await client
            .newSession('/workspace')
            .timeout(const Duration(seconds: 5));
        subscription = client.sessionUpdates(sessionId).listen(updates.add);

        await client
            .prompt(sessionId: sessionId, content: 'run tools')
            .drain<void>()
            .timeout(const Duration(seconds: 5));
        await pumpEventQueue();

        final toolUpdates = updates.whereType<ToolCallUpdate>().toList();
        expect(toolUpdates.map((update) => update.toolCall.toolCallId), [
          'call-a',
          'call-b',
          'call-a',
          'call-b',
        ]);
        expect(toolUpdates.map((update) => update.toolCall.title), [
          'Bash A',
          'Bash B',
          'Bash A',
          'Bash B',
        ]);
        expect(toolUpdates[2].toolCall.rawOutput, 'a done');
        expect(toolUpdates[3].toolCall.rawOutput, 'b done');
      } finally {
        await subscription?.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('session manager routes usage updates', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_usage_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

void send(Map<String, dynamic> message) {
  stdout.writeln(jsonEncode(message));
}

void sendSessionUpdate(Map<String, dynamic> update) {
  send(<String, dynamic>{
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': <String, dynamic>{
      'sessionId': 'session-usage',
      'update': update,
    },
  });
}

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      });
    } else if (message['method'] == 'session/new') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-usage'},
      });
    } else if (message['method'] == 'session/prompt') {
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'usage_update',
        'used': 53000,
        'size': 200000,
        'cost': <String, dynamic>{'amount': 0.045, 'currency': 'USD'},
      });
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      });
    }
  }
}
''');

    final client = await AcpClient.start(
      config: AcpConfig(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      ),
    );
    final updates = <AcpUpdate>[];
    StreamSubscription<AcpUpdate>? subscription;

    try {
      await client.initialize().timeout(const Duration(seconds: 5));
      final sessionId = await client
          .newSession('/workspace')
          .timeout(const Duration(seconds: 5));
      subscription = client.sessionUpdates(sessionId).listen(updates.add);

      await client
          .prompt(sessionId: sessionId, content: 'report usage')
          .drain<void>()
          .timeout(const Duration(seconds: 5));
      await pumpEventQueue();

      final usage = updates.whereType<UsageUpdate>().single;
      expect(usage.used, 53000);
      expect(usage.size, 200000);
      expect(usage.cost?.amount, 0.045);
      expect(usage.cost?.currency, 'USD');
    } finally {
      await subscription?.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('session manager accepts snake case session ids', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_snake_session_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

void send(Map<String, dynamic> message) {
  stdout.writeln(jsonEncode(message));
}

void sendSessionUpdate(Map<String, dynamic> update) {
  send(<String, dynamic>{
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': <String, dynamic>{
      'session_id': 'snake-session',
      'update': update,
    },
  });
}

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'fork': true,
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      });
    } else if (message['method'] == 'session/new') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'session_id': 'snake-session'},
      });
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'agent_message_chunk',
        'content': 'hello from snake session',
      });
    } else if (message['method'] == 'session/fork') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'session_id': 'forked-snake'},
      });
    }
  }
}
''');

    final client = await AcpClient.start(
      config: AcpConfig(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      ),
    );

    try {
      await client.initialize().timeout(const Duration(seconds: 5));
      final sessionId = await client
          .newSession('/workspace')
          .timeout(const Duration(seconds: 5));
      final update = await client
          .sessionUpdates(sessionId)
          .where((update) => update is MessageDelta)
          .cast<MessageDelta>()
          .first
          .timeout(const Duration(seconds: 5));
      final forked = await client
          .forkSession(sessionId: sessionId, workspaceRoot: '/workspace')
          .timeout(const Duration(seconds: 5));

      expect(sessionId, 'snake-session');
      expect(update.text, 'hello from snake session');
      expect(forked.sessionId, 'forked-snake');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('available commands accept legacy names, inputs, and schemas', () {
    final review = AvailableCommand.fromJson(<String, dynamic>{
      'id': 'review',
      'summary': 'Review the current diff.',
      'schema': <String, dynamic>{'type': 'object'},
      'input': 'Optional focus',
    });

    expect(review.name, 'review');
    expect(review.description, 'Review the current diff.');
    expect(review.parameters, containsPair('type', 'object'));
    expect(review.input?.hint, 'Optional focus');

    final apply = AvailableCommand.fromJson(<String, dynamic>{
      'command': 'apply',
      'input_schema': <String, dynamic>{'type': 'object'},
      'arguments': <String, dynamic>{'placeholder': 'Patch description'},
    });

    expect(apply.name, 'apply');
    expect(apply.parameters, containsPair('type', 'object'));
    expect(apply.input?.hint, 'Patch description');
  });

  test('plans accept legacy string steps and status aliases', () {
    final plan = Plan.fromJson(<String, dynamic>{
      'title': 'Legacy plan',
      'steps': <Object>[
        'Inspect current state',
        <String, dynamic>{
          'text': 'Patch parser',
          'priority': 'HIGH',
          'status': 'inProgress',
        },
        <String, dynamic>{'task': 'Run tests', 'status': 'done'},
        7,
      ],
    });

    expect(plan.entries.map((entry) => entry.content), [
      'Inspect current state',
      'Patch parser',
      'Run tests',
    ]);
    expect(plan.entries[0].priority, PlanEntryPriority.medium);
    expect(plan.entries[1].priority, PlanEntryPriority.high);
    expect(plan.entries[1].status, PlanEntryStatus.inProgress);
    expect(plan.entries[2].status, PlanEntryStatus.completed);
  });

  test('diffs accept legacy paths, string changes, and status aliases', () {
    final diff = Diff.fromJson(<String, dynamic>{
      'filePath': '/workspace/lib/main.dart',
      'status': 'done',
      'changes': <Object>[
        '+final enabled = true;',
        '-final enabled = false;',
        <String, dynamic>{
          'type': 'modified',
          'lineNumber': '42',
          'old': 'old call',
          'new': 'new call',
        },
      ],
    });

    expect(diff.id, '/workspace/lib/main.dart');
    expect(diff.uri, '/workspace/lib/main.dart');
    expect(diff.status, DiffStatus.applied);
    expect(diff.changes.map((change) => change.type), [
      'addition',
      'deletion',
      'modification',
    ]);
    expect(diff.changes.first.content, 'final enabled = true;');
    expect(diff.changes[1].content, 'final enabled = false;');
    expect(diff.changes[2].line, 42);
    expect(diff.changes[2].oldContent, 'old call');
    expect(diff.changes[2].newContent, 'new call');

    final rawDiff = Diff.fromJson(<String, dynamic>{
      'path': '/workspace/README.md',
      'status': 'failed',
      'diff': '+hello\n-world',
    });

    expect(rawDiff.status, DiffStatus.error);
    expect(rawDiff.uri, '/workspace/README.md');
    expect(rawDiff.changes.map((change) => change.type), [
      'addition',
      'deletion',
    ]);
  });

  test('session lists accept legacy field names', () {
    final result = SessionListResult.fromJson(<String, dynamic>{
      'items': <Object>[
        <String, dynamic>{
          'id': 'legacy-1',
          'workspaceRoot': '/workspace/app',
          'name': 'Legacy app',
          'updated_at': '2026-06-01T08:30:00Z',
          'metadata': <String, dynamic>{'agent': 'kimi'},
        },
        <String, dynamic>{
          'session_id': 'legacy-2',
          'path': '/workspace/tools',
          'label': 'Tooling',
        },
        'not-a-session',
        <String, dynamic>{'cwd': '/missing-id'},
      ],
      'next_cursor': 'cursor-2',
    });

    expect(result.nextCursor, 'cursor-2');
    expect(result.sessions.map((session) => session.sessionId), [
      'legacy-1',
      'legacy-2',
    ]);
    expect(result.sessions.first.cwd, '/workspace/app');
    expect(result.sessions.first.title, 'Legacy app');
    expect(
      result.sessions.first.updatedAt?.toUtc().toIso8601String(),
      '2026-06-01T08:30:00.000Z',
    );
    expect(result.sessions.first.meta, containsPair('agent', 'kimi'));
    expect(result.sessions[1].cwd, '/workspace/tools');
    expect(result.sessions[1].title, 'Tooling');
  });

  test('session results accept legacy config option payloads', () {
    final result = SessionResult.fromJson(<String, dynamic>{
      'session_id': 'session-1',
      'metadata': <String, dynamic>{'source': 'resume'},
      'config_options': <Object>[
        <String, dynamic>{
          'key': 'model',
          'label': 'Model',
          'current_value': 'kimi-k2',
          'choices': <Object>[
            'kimi-k2',
            <String, dynamic>{'id': 'glm-4.6', 'displayName': 'GLM 4.6'},
            <String, dynamic>{'value': 4, 'name': 'Four'},
          ],
          'category': 'model',
        },
        <String, dynamic>{
          'configId': 'auto_apply',
          'name': 'Auto apply',
          'type': ' BOOLEAN ',
          'selected': true,
          'values': <Map<String, Object>>[
            <String, Object>{'value': true, 'label': 'On'},
            <String, Object>{'value': false, 'label': 'Off'},
          ],
        },
      ],
    });

    expect(result.sessionId, 'session-1');
    expect(result.meta, containsPair('source', 'resume'));
    expect(result.configOptions, hasLength(2));

    final model = result.configOptions!.first;
    expect(model.id, 'model');
    expect(model.name, 'Model');
    expect(model.type, 'select');
    expect(model.currentValue, 'kimi-k2');
    expect(model.category, 'model');
    expect(model.group, isNull);
    expect(model.options.map((choice) => choice.value), [
      'kimi-k2',
      'glm-4.6',
      '4',
    ]);
    expect(model.options[1].name, 'GLM 4.6');

    final autoApply = result.configOptions!.last;
    expect(autoApply.id, 'auto_apply');
    expect(autoApply.type, 'boolean');
    expect(autoApply.currentValue, isTrue);
    expect(autoApply.options.map((choice) => choice.value), ['true', 'false']);
    expect(autoApply.options.map((choice) => choice.name), ['On', 'Off']);
  });

  test('client capabilities advertise ACP boolean config options', () {
    expect(const AcpCapabilities().toJson(), {
      'fs': {'readTextFile': true, 'writeTextFile': false},
      'session': {
        'configOptions': {'boolean': <String, dynamic>{}},
      },
      'plan': <String, dynamic>{},
    });
  });

  test('initialize result exposes MCP-over-ACP support', () {
    final result = InitializeResult(
      protocolVersion: 1,
      agentCapabilities: <String, dynamic>{
        'mcpCapabilities': <String, dynamic>{
          'http': true,
          'sse': false,
          'acp': true,
        },
      },
      authMethods: const <Map<String, dynamic>>[],
    );

    expect(result.mcpCapabilities, (http: true, sse: false, acp: true));
  });

  test('session config options preserve grouped select choices', () {
    final result = SessionResult.fromJson({
      'sessionId': 'grouped',
      'configOptions': [
        {
          'id': 'model',
          'name': 'Model',
          'type': 'select',
          'category': 'model',
          'currentValue': 'gpt-5.6',
          'options': [
            {
              'group': 'openai',
              'name': 'OpenAI',
              '_meta': {'source': 'registry'},
              'options': [
                {'value': 'gpt-5.6', 'name': 'GPT-5.6'},
                {'value': 'gpt-5.5', 'name': 'GPT-5.5'},
              ],
            },
          ],
        },
      ],
    });

    final model = result.configOptions!.single;
    expect(model.category, 'model');
    expect(model.options.map((choice) => choice.value), ['gpt-5.6', 'gpt-5.5']);
    expect(model.options.every((choice) => choice.groupId == 'openai'), isTrue);
    expect(
      model.options.every((choice) => choice.groupName == 'OpenAI'),
      isTrue,
    );
    expect(
      model.options.every(
        (choice) => choice.groupMeta?['source'] == 'registry',
      ),
      isTrue,
    );
    expect(model.toJson()['options'], [
      {
        'group': 'openai',
        'name': 'OpenAI',
        '_meta': {'source': 'registry'},
        'options': [
          {'value': 'gpt-5.6', 'name': 'GPT-5.6'},
          {'value': 'gpt-5.5', 'name': 'GPT-5.5'},
        ],
      },
    ]);
  });

  test('terminal provider retains the newest UTF-8 output bytes', () async {
    if (Platform.isWindows) return;
    final provider = DefaultTerminalProvider();
    final handle = await provider.create(
      sessionId: 'output-limit',
      command: 'printf "aé中z"',
      outputByteLimit: 4,
    );
    await provider.waitForExit(handle);
    await pumpEventQueue();

    expect(await provider.currentOutput(handle), '中z');
    expect(handle.truncated, isTrue);
    await provider.release(handle);
  });
  test('config options preserve separately bounded category and group', () {
    final option = ConfigOption.fromJson(<String, dynamic>{
      'id': 'temperature',
      'name': 'Temperature',
      'type': 'select',
      'currentValue': 'balanced',
      'category': 'model',
      'group': 'advanced',
      'options': <Object?>['balanced'],
    });

    expect(option.category, 'model');
    expect(option.group, 'advanced');
    expect(option.toJson(), containsPair('category', 'model'));
    expect(option.toJson(), containsPair('group', 'advanced'));

    final categoryOnly = ConfigOption.fromJson(<String, dynamic>{
      'id': 'category-only',
      'currentValue': 'value',
      'category': 'model',
    });
    expect(categoryOnly.category, 'model');
    expect(categoryOnly.group, isNull);

    final groupOnly = ConfigOption.fromJson(<String, dynamic>{
      'id': 'group-only',
      'currentValue': 'value',
      'group': 'advanced',
    });
    expect(groupOnly.category, isNull);
    expect(groupOnly.group, 'advanced');

    for (final field in <String>['category', 'group']) {
      expect(
        () => ConfigOption.fromJson(<String, dynamic>{
          'id': 'temperature',
          'currentValue': 'balanced',
          field: <String>['CONFIG_CLASSIFICATION_CANARY'],
        }),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'payload-free',
            isNot(contains('CONFIG_CLASSIFICATION_CANARY')),
          ),
        ),
      );
    }
  });

  test('diff details fail closed at collection and text boundaries', () {
    final numericLine = Diff.fromJson(<String, dynamic>{
      'changes': <Object?>[
        <String, dynamic>{'type': 'addition', 'line': 1.5, 'content': 'x'},
      ],
    });
    expect(numericLine.changes.single.line, 1);

    final exact = Diff.fromJson(
      <String, dynamic>{'id': 'd', 'diff': '+a\n-b'},
      inputBudget: const AcpInputBudget(
        maxCollectionItems: 2,
        maxMetadataBytes: 5,
      ),
    );
    expect(exact.changes.map((change) => change.content), ['a', 'b']);
    expect(exact.truncated, isFalse);
    expect(exact.omission, isNull);

    final tooManyLines = Diff.fromJson(
      <String, dynamic>{'id': 'd', 'diff': '+a\n-b\n+c'},
      inputBudget: const AcpInputBudget(
        maxCollectionItems: 2,
        maxMetadataBytes: 8,
      ),
    );
    expect(tooManyLines.id, 'd');
    expect(tooManyLines.uri, isNull);
    expect(tooManyLines.status, DiffStatus.started);
    expect(tooManyLines.changes, isEmpty);
    expect(tooManyLines.truncated, isTrue);
    expect(tooManyLines.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(tooManyLines.omission?.truncated, isFalse);

    const canary = 'DIFF_DETAIL_CANARY';
    final invalidStructured = Diff.fromJson(<String, dynamic>{
      'id': 'd',
      'uri': 'u',
      'status': 'done',
      'changes': <Object?>[
        <String, dynamic>{'type': 'addition', 'content': 'safe'},
        <String, dynamic>{
          'type': 'addition',
          'content': <String>[canary],
        },
      ],
    });
    expect(invalidStructured.changes, isEmpty);
    expect(invalidStructured.truncated, isTrue);
    expect(
      invalidStructured.omission?.reason,
      AcpInputOmissionReason.invalidStructure,
    );
    expect(invalidStructured.omission.toString(), isNot(contains(canary)));
  });

  test('diff structural strings share one root and reject before details', () {
    final exact = Diff.fromJson(<String, dynamic>{
      'id': 'é',
      'uri': 'u',
      'status': 'x',
      'changes': <Object?>[],
    }, inputBudget: const AcpInputBudget(maxStructuredStringBytes: 2));
    expect(exact.id, 'é');

    expect(
      () => Diff.fromJson(<String, dynamic>{
        'id': 'éx',
        'uri': 'u',
        'status': 'x',
        'changes': <Object?>['DIFF_URI_CANARY'],
      }, inputBudget: const AcpInputBudget(maxStructuredStringBytes: 2)),
      throwsA(
        isA<AcpInputLimitExceeded>()
            .having((error) => error.limit, 'limit', 2)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 3)
            .having(
              (error) => error.toString(),
              'payload-free',
              isNot(contains('DIFF_URI_CANARY')),
            ),
      ),
    );
  });

  test('raw diff scanner handles CR LF CRLF and final lines at boundaries', () {
    for (final separator in const <String>['\n', '\r', '\r\n']) {
      final exact = Diff.fromJson(<String, dynamic>{
        'diff': '+a$separator-b',
      }, inputBudget: const AcpInputBudget(maxCollectionItems: 2));
      expect(
        exact.changes.map((change) => change.type),
        <String>['addition', 'deletion'],
        reason: separator.codeUnits.toString(),
      );
      expect(exact.omission, isNull);

      final beyond = Diff.fromJson(<String, dynamic>{
        'diff': '+a$separator-b$separator+c',
      }, inputBudget: const AcpInputBudget(maxCollectionItems: 2));
      expect(beyond.changes, isEmpty);
      expect(beyond.omission?.reason, AcpInputOmissionReason.inputLimit);
      expect(beyond.omission?.limit, 2);
      expect(beyond.omission?.observedAtLeast, 3);
    }

    final exactBytes = Diff.fromJson(
      <String, dynamic>{'diff': '+é\r\n-b'},
      inputBudget: const AcpInputBudget(
        maxCollectionItems: 2,
        maxMetadataBytes: 7,
      ),
    );
    expect(exactBytes.changes, hasLength(2));
    final beyondBytes = Diff.fromJson(
      <String, dynamic>{'diff': '+é\r\n-bx'},
      inputBudget: const AcpInputBudget(
        maxCollectionItems: 2,
        maxMetadataBytes: 7,
      ),
    );
    expect(beyondBytes.changes, isEmpty);
    expect(beyondBytes.omission?.limit, 7);
    expect(beyondBytes.omission?.observedAtLeast, 8);
  });

  test('raw unified diff preserves file headers for every line separator', () {
    for (final separator in const <String>['\n', '\r', '\r\n']) {
      final diff = Diff.fromJson(<String, dynamic>{
        'diff': <String>[
          '+++ b/a.dart',
          '--- a/a.dart',
          '+++\tb/a.dart',
          '---a/a.dart',
          '+added',
          '-removed',
        ].join(separator),
      });
      expect(
        diff.changes.map((change) => change.type),
        <String>[
          'change',
          'change',
          'change',
          'change',
          'addition',
          'deletion',
        ],
        reason: separator.codeUnits.toString(),
      );
      expect(
        diff.changes.map((change) => change.content),
        <String>[
          '+++ b/a.dart',
          '--- a/a.dart',
          '+++\tb/a.dart',
          '---a/a.dart',
          'added',
          'removed',
        ],
        reason: separator.codeUnits.toString(),
      );
    }

    final structured = Diff.fromJson(<String, dynamic>{
      'changes': <Object?>['+++ b/a.dart'],
    });
    expect(structured.changes.single.type, 'addition');
    expect(structured.changes.single.content, '++ b/a.dart');
  });

  test('raw unified diff preserves trailing whitespace on every line', () {
    for (final separator in const <String>['\n', '\r', '\r\n']) {
      final diff = Diff.fromJson(<String, dynamic>{
        'diff': <String>[
          '+++ b/a.dart ',
          '---\ta/a.dart\t',
          '+added ',
          '-removed\t',
        ].join(separator),
      });
      expect(
        diff.changes.map((change) => change.type),
        <String>['change', 'change', 'addition', 'deletion'],
        reason: separator.codeUnits.toString(),
      );
      expect(
        diff.changes.map((change) => change.content),
        <String>['+++ b/a.dart ', '---\ta/a.dart\t', 'added ', 'removed\t'],
        reason: separator.codeUnits.toString(),
      );
    }

    final structured = Diff.fromJson(<String, dynamic>{
      'changes': <Object?>['+added ', '+++ b '],
    });
    expect(structured.changes.map((change) => change.content), <String>[
      'added',
      '++ b',
    ]);
  });

  test('plans retain only a bounded immutable display prefix', () {
    final sourceEntry = <String, dynamic>{
      'content': 'second',
      'metadata': <String, Object?>{
        'nested': <Object?>[1],
      },
    };
    final plan = Plan.fromJson(<String, dynamic>{
      'title': 'title',
      'entries': <Object?>['first', sourceEntry, 'third'],
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 2));

    expect(plan.entries.map((entry) => entry.content), ['first', 'second']);
    expect(plan.truncated, isTrue);
    expect(plan.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(plan.omission?.resource, 'plan_entries');
    expect(plan.omission?.limit, 2);
    expect(plan.omission?.observedAtLeast, 3);
    expect(plan.omission?.truncated, isTrue);

    (sourceEntry['metadata']! as Map<String, Object?>)['later'] = true;
    expect(plan.entries[1].metadata, isNot(contains('later')));
    expect(() => plan.entries.add(plan.entries.first), throwsUnsupportedError);
    expect(
      () => plan.entries[1].metadata!['later'] = true,
      throwsUnsupportedError,
    );
  });

  test('plan omission truncation reflects a retained visible prefix', () {
    final invalidAfterPrefix = Plan.fromJson(<String, dynamic>{
      'entries': <Object?>['safe', 3],
    });
    expect(invalidAfterPrefix.entries.single.content, 'safe');
    expect(invalidAfterPrefix.truncated, isTrue);
    expect(invalidAfterPrefix.omission?.truncated, isTrue);

    final invalidFirst = Plan.fromJson(<String, dynamic>{
      'entries': <Object?>[3, 'unread'],
    });
    expect(invalidFirst.entries, isEmpty);
    expect(invalidFirst.truncated, isTrue);
    expect(invalidFirst.omission?.truncated, isFalse);

    final limitedAfterPrefix = Plan.fromJson(<String, dynamic>{
      'entries': <Object?>['safe', 'too long'],
    }, inputBudget: const AcpInputBudget(maxStructuredStringBytes: 4));
    expect(limitedAfterPrefix.entries.single.content, 'safe');
    expect(
      limitedAfterPrefix.omission?.reason,
      AcpInputOmissionReason.inputLimit,
    );
    expect(limitedAfterPrefix.omission?.truncated, isTrue);
  });

  test('plan iterator failures report whether a prefix was retained', () {
    for (final failOnCurrent in <bool>[false, true]) {
      final afterPrefix = Plan.fromJson(<String, dynamic>{
        'entries': _FailingPlanList(
          values: const <Object?>['safe', 'unread'],
          failAtIndex: 1,
          failOnCurrent: failOnCurrent,
        ),
      });
      expect(afterPrefix.entries.single.content, 'safe');
      expect(afterPrefix.omission?.truncated, isTrue);

      final beforePrefix = Plan.fromJson(<String, dynamic>{
        'entries': _FailingPlanList(
          values: const <Object?>['unread'],
          failAtIndex: 0,
          failOnCurrent: failOnCurrent,
        ),
      });
      expect(beforePrefix.entries, isEmpty);
      expect(beforePrefix.omission?.truncated, isFalse);
    }
  });

  test('available commands fail closed without retaining partial input', () {
    final exact = AvailableCommandsUpdate.fromRaw(<Map<String, dynamic>>[
      <String, dynamic>{'name': 'one'},
      <String, dynamic>{'name': 'two'},
    ], inputBudget: const AcpInputBudget(maxCollectionItems: 2));
    expect(exact.commands.map((command) => command.name), ['one', 'two']);
    expect(exact.omission, isNull);
    expect(
      () => exact.commands.add(exact.commands.first),
      throwsUnsupportedError,
    );

    final tooMany = AvailableCommandsUpdate.fromRaw(<Map<String, dynamic>>[
      <String, dynamic>{'name': 'one'},
      <String, dynamic>{'name': 'two'},
      <String, dynamic>{'name': 'COMMAND_CANARY'},
    ], inputBudget: const AcpInputBudget(maxCollectionItems: 2));
    expect(tooMany.commands, isEmpty);
    expect(tooMany.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(tooMany.omission.toString(), isNot(contains('COMMAND_CANARY')));

    final malformed = AvailableCommandsUpdate.fromRaw(<Map<String, dynamic>>[
      <String, dynamic>{'name': 'safe'},
      <String, dynamic>{
        'name': <String>['COMMAND_STRUCTURE_CANARY'],
      },
    ]);
    expect(malformed.commands, isEmpty);
    expect(malformed.omission?.reason, AcpInputOmissionReason.invalidStructure);
    expect(
      malformed.omission.toString(),
      isNot(contains('COMMAND_STRUCTURE_CANARY')),
    );

    final missingName = AvailableCommandsUpdate.fromRaw(<Map<String, dynamic>>[
      <String, dynamic>{'name': 'safe'},
      <String, dynamic>{},
    ]);
    expect(missingName.commands, isEmpty);
    expect(
      missingName.omission?.reason,
      AcpInputOmissionReason.invalidStructure,
    );
  });

  test('available commands own bounded legacy string names', () {
    final exact = AvailableCommandsUpdate.fromRaw(const <Object?>[
      'abcd',
    ], inputBudget: const AcpInputBudget(maxStructuredStringBytes: 4));
    expect(exact.commands.map((command) => command.name), ['abcd']);
    expect(exact.omission, isNull);

    const canary = 'COMMAND_STRING_CANARY';
    final tooLong = AvailableCommandsUpdate.fromRaw(const <Object?>[
      'abcde$canary',
    ], inputBudget: const AcpInputBudget(maxStructuredStringBytes: 4));
    expect(tooLong.commands, isEmpty);
    expect(tooLong.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(tooLong.toString(), isNot(contains(canary)));
    expect(tooLong.omission.toString(), isNot(contains(canary)));

    for (final raw in const <List<Object?>>[
      <Object?>['   '],
      <Object?>[42],
      <Object?>['safe', 42],
    ]) {
      final invalid = AvailableCommandsUpdate.fromRaw(raw);
      expect(invalid.commands, isEmpty);
      expect(invalid.omission?.reason, AcpInputOmissionReason.invalidStructure);
    }
  });

  test('legacy message text consumes its owning root exactly once', () {
    final exact = MessageDelta.fromRaw(
      role: 'assistant',
      rawContent: const <Object?>['abcd'],
      inputBudget: const AcpInputBudget(maxStructuredUpdateNodes: 6),
    );
    expect(exact.text, 'abcd');

    expect(
      () => MessageDelta.fromRaw(
        role: 'assistant',
        rawContent: const <Object?>['abcd'],
        inputBudget: const AcpInputBudget(maxStructuredUpdateNodes: 5),
      ),
      throwsA(isA<AcpInputLimitExceeded>()),
    );
  });

  test('fromRaw owners validate dynamic list items without caller casts', () {
    final canary = _UpdateToStringCanary();
    final commands = AvailableCommandsUpdate.fromRaw(<Object?>[
      <String, dynamic>{'name': 'safe'},
      canary,
    ]);
    expect(commands.commands, isEmpty);
    expect(commands.omission?.reason, AcpInputOmissionReason.invalidStructure);

    final message = MessageDelta.fromRaw(
      role: 'assistant',
      rawContent: <Object?>[
        canary,
        <String, dynamic>{'text': 'good'},
      ],
    );
    expect(message.text, 'good');
    expect(
      message.omissions.single.reason,
      AcpInputOmissionReason.invalidStructure,
    );
    expect(message.content.first, isA<UnknownContent>());
    expect(canary.calls, 0);
  });

  test('structured collections count actual yielded items independently', () {
    const canary = 'EXTRA_ITERATOR_CANARY';
    final plan = Plan.fromJson(<String, dynamic>{
      'entries': _ExtraYieldList<Object?>(
        reportedLength: 2,
        actualValues: <Object?>['', '   ', canary],
      ),
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 2));
    expect(plan.entries, isEmpty);
    expect(plan.truncated, isTrue);
    expect(plan.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(plan.omission?.limit, 2);
    expect(plan.omission?.observedAtLeast, 3);
    expect(plan.omission.toString(), isNot(contains(canary)));

    final diff = Diff.fromJson(<String, dynamic>{
      'changes': _ExtraYieldList<Object?>(
        reportedLength: 1,
        actualValues: <Object?>['   ', canary],
      ),
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 1));
    expect(diff.changes, isEmpty);
    expect(diff.truncated, isTrue);
    expect(diff.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(diff.omission?.limit, 1);
    expect(diff.omission?.observedAtLeast, 2);
    expect(diff.omission.toString(), isNot(contains(canary)));
  });

  test('message deltas aggregate immutable deduplicated block omissions', () {
    final delta = MessageDelta.fromRaw(
      role: 'assistant',
      rawContent: <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': 'ab'},
        <String, dynamic>{
          'type': 'resource',
          'resource': <String, dynamic>{'uri': 'file:///r', 'text': 'cd'},
        },
        <String, dynamic>{
          'type': 'image',
          'mimeType': 'image/png',
          'data': 'TW E',
        },
      ],
      inputBudget: const AcpInputBudget(
        maxMessageTextBytes: 1,
        maxMarkdownFallbackBytes: 1,
      ),
    );

    expect(delta.text, 'a');
    expect(delta.text, isNot(contains('omitted')));
    expect(delta.content, hasLength(3));
    expect(delta.omissions, hasLength(2));
    expect(
      delta.omissions.map((omission) => omission.reason),
      <AcpInputOmissionReason>[
        AcpInputOmissionReason.inputLimit,
        AcpInputOmissionReason.invalidEncoding,
      ],
    );
    expect(
      () => delta.content.add(delta.content.first),
      throwsUnsupportedError,
    );
    expect(() => delta.omissions.clear(), throwsUnsupportedError);
  });

  test(
    'message content retains a bounded block prefix with typed omission',
    () {
      final delta = MessageDelta.fromRaw(
        role: 'assistant',
        rawContent: <Object?>[
          <String, dynamic>{'text': 'first'},
          <String, dynamic>{'text': 'MESSAGE_BLOCK_CANARY'},
        ],
        inputBudget: const AcpInputBudget(maxCollectionItems: 1),
      );
      expect(delta.text, 'first');
      expect(delta.content, hasLength(1));
      expect(delta.omissions.single.reason, AcpInputOmissionReason.inputLimit);
      expect(delta.omissions.single.resource, 'message_content');
      expect(delta.omissions.single.limit, 1);
      expect(delta.omissions.single.observedAtLeast, 2);
      expect(
        delta.omissions.toString(),
        isNot(contains('MESSAGE_BLOCK_CANARY')),
      );
    },
  );

  test('session info drops bad display metadata with trusted carrier only', () {
    final exact = SessionInfo.fromJson(<String, dynamic>{
      'sessionId': 's',
      'cwd': '/w',
      '_meta': <String, Object?>{'x': 'y'},
    }, inputBudget: const AcpInputBudget(maxMetadataBytes: 2));
    expect(exact.meta, <String, Object?>{'x': 'y'});
    expect(exact.metaOmission, isNull);

    final limited = SessionInfo.fromJson(<String, dynamic>{
      'sessionId': 's',
      'cwd': '/w',
      '_meta': <String, Object?>{'x': 'yz'},
      'metaOmission': <String, Object?>{
        'reason': 'invalid_structure',
        'resource': 'forged',
      },
    }, inputBudget: const AcpInputBudget(maxMetadataBytes: 2));
    expect(limited.meta, isEmpty);
    expect(limited.metaOmission?.reason, AcpInputOmissionReason.inputLimit);
    expect(limited.metaOmission?.resource, 'session_meta');
    expect(limited.metaOmission?.limit, 2);
    expect(limited.metaOmission?.observedAtLeast, 3);
    expect(() => limited.meta!['x'] = 'changed', throwsUnsupportedError);

    final forged = SessionInfo.fromJson(<String, dynamic>{
      'sessionId': 's',
      'cwd': '/w',
      'metaOmission': <String, Object?>{
        'reason': 'input_limit',
        'resource': 'forged',
      },
    });
    expect(forged.metaOmission, isNull);
  });

  test('session list preserves one bounded SessionInfo carrier instance', () {
    final result = SessionListResult.fromJson(
      <String, dynamic>{
        'sessions': <Object?>[
          <String, dynamic>{
            'sessionId': 's',
            'cwd': 'w',
            '_meta': <String, Object?>{'x': null},
          },
        ],
      },
      inputBudget: const AcpInputBudget(
        maxStructuredUpdateNodes: 7,
        maxStructuredUpdateBytes: 7,
      ),
    );

    expect(result.sessions, hasLength(1));
    final session = result.sessions.single;
    expect(session.meta, <String, Object?>{'x': null});
    expect(session.metaOmission, isNull);
    expect(() => result.sessions.add(session), throwsUnsupportedError);
    expect(() => session.meta!['x'] = true, throwsUnsupportedError);

    final limited = SessionListResult.fromJson(<String, dynamic>{
      'sessions': <Object?>[
        <String, dynamic>{
          'sessionId': 's',
          'cwd': 'w',
          '_meta': <String, Object?>{'x': 'yy'},
        },
      ],
    }, inputBudget: const AcpInputBudget(maxMetadataBytes: 2));
    expect(limited.sessions.single.meta, isEmpty);
    expect(
      limited.sessions.single.metaOmission?.reason,
      AcpInputOmissionReason.inputLimit,
    );
  });

  test(
    'additional directories reject invalid actionable entries atomically',
    () {
      final canary = _UpdateToStringCanary();
      expect(
        () => SessionInfo.fromJson(<String, dynamic>{
          'sessionId': 's',
          'cwd': '/w',
          'additionalDirectories': <Object?>['/safe', canary],
        }),
        throwsA(
          predicate<Object>(
            (error) => !error.toString().contains('UPDATE_TOSTRING_CANARY'),
            'payload-free',
          ),
        ),
      );
      expect(canary.calls, 0);
    },
  );

  test('session result config and modes fail closed as whole fields', () {
    final configResult = SessionResult.fromJson(<String, dynamic>{
      'sessionId': 's',
      'configOptions': <Object?>[
        <String, dynamic>{
          'id': 'model',
          'name': 'Model',
          'currentValue': 'a',
          'options': <Object?>['a', 'b', 'CONFIG_CANARY'],
        },
      ],
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 2));
    final modesResult = SessionResult.fromJson(<String, dynamic>{
      'currentModeId': 'code',
      'availableModes': <Object?>[
        <String, dynamic>{'id': 'code', 'name': 'Code'},
        <String, dynamic>{'id': 'ask', 'name': 'Ask'},
        <String, dynamic>{'id': 'MODE_CANARY', 'name': 'Canary'},
      ],
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 2));

    expect(configResult.sessionId, 's');
    expect(configResult.configOptions, isEmpty);
    expect(configResult.modes, isNull);
    expect(configResult.omissions, hasLength(1));
    expect(modesResult.modes, isNull);
    expect(modesResult.omissions, hasLength(1));
    expect(<String>[
      ...configResult.omissions.map((omission) => omission.resource),
      ...modesResult.omissions.map((omission) => omission.resource),
    ], containsAll(<String>['config_options', 'session_modes']));
    expect(configResult.omissions.toString(), isNot(contains('CONFIG_CANARY')));
    expect(modesResult.omissions.toString(), isNot(contains('MODE_CANARY')));
    expect(() => configResult.omissions.clear(), throwsUnsupportedError);

    final forged = SessionResult.fromJson(<String, dynamic>{
      'sessionId': 's',
      'omissions': <Object?>[
        <String, Object?>{'reason': 'invalid_structure'},
      ],
    });
    expect(forged.omissions, isEmpty);
  });

  test('session result owns nested legacy modes under the same guard', () {
    final valid = SessionResult.fromJson(<String, dynamic>{
      'sessionId': 'nested',
      'modes': <String, dynamic>{
        'current_mode_id': 'plan',
        'available_modes': <Object?>[
          <String, dynamic>{'id': 'plan', 'name': 'Plan'},
          <String, dynamic>{'mode_id': 'act', 'display_name': 'Act'},
        ],
      },
    });
    expect(valid.modes?.currentModeId, 'plan');
    expect(valid.modes?.availableModes, <({String id, String name})>[
      (id: 'plan', name: 'Plan'),
      (id: 'act', name: 'Act'),
    ]);
    expect(valid.omissions, isEmpty);
    expect(() => valid.modes!.availableModes.clear(), throwsUnsupportedError);

    final invalid = SessionResult.fromJson(<String, dynamic>{
      'sessionId': 'nested-invalid',
      'modes': <String, dynamic>{
        'current_mode_id': 'plan',
        'available_modes': <Object?>[
          <String, dynamic>{'id': 'plan', 'name': 'Plan'},
          'NESTED_MODE_CANARY',
        ],
      },
    });
    expect(invalid.modes, isNull);
    expect(invalid.omissions.single.resource, 'session_modes');
    expect(invalid.omissions.toString(), isNot(contains('NESTED_MODE_CANARY')));
  });

  test(
    'invalid config options and choices reject the whole actionable field',
    () {
      final invalidOption = SessionResult.fromJson(<String, dynamic>{
        'sessionId': 's',
        'configOptions': <Object?>[
          <String, dynamic>{'id': 'safe', 'currentValue': 'a'},
          <String, dynamic>{'name': 'missing id', 'currentValue': 'b'},
        ],
      });
      expect(invalidOption.configOptions, isEmpty);
      expect(
        invalidOption.omissions.single.reason,
        AcpInputOmissionReason.invalidStructure,
      );

      final invalidChoice = SessionResult.fromJson(<String, dynamic>{
        'sessionId': 's',
        'configOptions': <Object?>[
          <String, dynamic>{
            'id': 'model',
            'currentValue': 'a',
            'options': <Object?>['a', <String, dynamic>{}],
          },
        ],
      });
      expect(invalidChoice.configOptions, isEmpty);
      expect(
        invalidChoice.omissions.single.reason,
        AcpInputOmissionReason.invalidStructure,
      );
    },
  );

  test('all structured root maps precheck length before field access', () {
    const canary = 'ROOT_LENGTH_CANARY';
    final parsers = <Object? Function(Map<String, dynamic>)>[
      (json) => Plan.fromJson(json),
      (json) => Diff.fromJson(json),
      (json) => AvailableCommand.fromJson(json),
      (json) => SessionInfo.fromJson(json),
      (json) => SessionListResult.fromJson(json),
      (json) => SessionResult.fromJson(json),
      (json) => ToolCall.fromJson(json),
      (json) => UsageUpdate.fromJson(json),
    ];
    for (final parse in parsers) {
      expect(
        () => parse(_ContentThrowingLengthMap(canary)),
        throwsA(
          predicate<Object>(
            (error) => !error.toString().contains(canary),
            'payload-free root length failure',
          ),
        ),
      );
    }

    final unknown = UnknownUpdate.fromJson(_ContentThrowingLengthMap(canary));
    expect(unknown.raw, isEmpty);
    expect(unknown.omission?.reason, AcpInputOmissionReason.invalidStructure);
    final mode = ModeUpdate.fromJson(_ContentThrowingLengthMap(canary));
    expect(mode.currentModeId, isEmpty);
    expect(mode.omission?.reason, AcpInputOmissionReason.invalidStructure);
  });

  test(
    'update wrappers precheck root before consuming the shared model node',
    () {
      const canary = 'WRAPPER_LENGTH_CANARY';
      for (final parse in <void Function(AcpStructuredUpdateGuard)>[
        (guard) => PlanUpdate.fromJson(
          _ContentThrowingLengthMap(canary),
          structuredGuard: guard,
        ),
        (guard) => DiffUpdate.fromJson(
          _ContentThrowingLengthMap(canary),
          structuredGuard: guard,
        ),
        (guard) => ToolCallUpdate.fromJson(
          _ContentThrowingLengthMap(canary),
          structuredGuard: guard,
        ),
      ]) {
        final guard = AcpStructuredUpdateGuard(
          budget: const AcpInputBudget(maxStructuredUpdateNodes: 1),
          resource: 'update wrapper',
        );
        expect(
          () => parse(guard),
          throwsA(
            predicate<Object>(
              (error) => !error.toString().contains(canary),
              'payload-free',
            ),
          ),
        );
        guard.consumeEntry(field: 'after failure');
      }
    },
  );

  test('structured iterators detect extra yields before reading current', () {
    const canary = 'EXTRA_CURRENT_CANARY';
    final commandsRaw = _ExtraYieldTrapList<Map<String, dynamic>>(
      reportedLength: 1,
      values: <Map<String, dynamic>>[
        <String, dynamic>{'name': 'safe'},
        <String, dynamic>{'name': canary},
      ],
    );
    final commands = AvailableCommandsUpdate.fromRaw(commandsRaw);
    expect(commands.commands, isEmpty);
    expect(commands.omission?.reason, AcpInputOmissionReason.invalidStructure);
    expect(commandsRaw.currentReads, 1);

    final planRaw = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>['safe', canary],
    );
    final plan = Plan.fromJson(<String, dynamic>{
      'entries': planRaw,
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 1));
    expect(plan.entries.single.content, 'safe');
    expect(plan.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(planRaw.currentReads, 1);

    final diffRaw = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>['+safe', '+$canary'],
    );
    final diff = Diff.fromJson(<String, dynamic>{
      'changes': diffRaw,
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 1));
    expect(diff.changes, isEmpty);
    expect(diff.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(diffRaw.currentReads, 1);

    final messageRaw = _ExtraYieldTrapList<Map<String, dynamic>>(
      reportedLength: 1,
      values: <Map<String, dynamic>>[
        <String, dynamic>{'text': 'safe'},
        <String, dynamic>{'text': canary},
      ],
    );
    final message = MessageDelta.fromRaw(
      role: 'assistant',
      rawContent: messageRaw,
      inputBudget: const AcpInputBudget(maxCollectionItems: 1),
    );
    expect(message.text, 'safe');
    expect(message.omissions.single.reason, AcpInputOmissionReason.inputLimit);
    expect(message.omissions.single.resource, 'message_content');
    expect(messageRaw.currentReads, 1);
  });

  test('actual command capacity outranks a reported length mismatch', () {
    final raw = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>[
        <String, dynamic>{'name': 'safe'},
        <String, dynamic>{'name': 'unread'},
      ],
    );
    final update = AvailableCommandsUpdate.fromRaw(
      raw,
      inputBudget: const AcpInputBudget(maxCollectionItems: 1),
    );
    expect(update.commands, isEmpty);
    expect(update.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(update.omission?.limit, 1);
    expect(update.omission?.observedAtLeast, 2);
    expect(raw.currentReads, 1);
  });

  test('session list families classify actual capacity before mismatch', () {
    final directories = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>['/safe', '/unread'],
    );
    expect(
      () => SessionInfo.fromJson(<String, dynamic>{
        'additionalDirectories': directories,
      }, inputBudget: const AcpInputBudget(maxCollectionItems: 1)),
      throwsA(
        predicate<Object>((error) {
          return error is AcpInputLimitExceeded &&
              error.limit == 1 &&
              error.observedAtLeast == 2;
        }),
      ),
    );
    expect(directories.currentReads, 1);

    final sessions = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>[
        <String, dynamic>{'sessionId': 'safe'},
        <String, dynamic>{'sessionId': 'unread'},
      ],
    );
    expect(
      () => SessionListResult.fromJson(<String, dynamic>{
        'sessions': sessions,
      }, inputBudget: const AcpInputBudget(maxCollectionItems: 1)),
      throwsA(isA<AcpInputLimitExceeded>()),
    );
    expect(sessions.currentReads, 1);

    final configOptions = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>[
        <String, dynamic>{'id': 'safe'},
        <String, dynamic>{'id': 'unread'},
      ],
    );
    final configResult = SessionResult.fromJson(<String, dynamic>{
      'configOptions': configOptions,
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 1));
    expect(configResult.configOptions, isEmpty);
    expect(
      configResult.omissions.single.reason,
      AcpInputOmissionReason.inputLimit,
    );
    expect(configResult.omissions.single.limit, 1);
    expect(configResult.omissions.single.observedAtLeast, 2);
    expect(configOptions.currentReads, 1);

    final choices = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>['safe', 'unread'],
    );
    expect(
      () => ConfigOption.fromJson(<String, dynamic>{
        'options': choices,
      }, inputBudget: const AcpInputBudget(maxCollectionItems: 1)),
      throwsA(isA<AcpInputLimitExceeded>()),
    );
    expect(choices.currentReads, 1);

    final modes = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>[
        <String, dynamic>{'id': 'safe'},
        <String, dynamic>{'id': 'unread'},
      ],
    );
    final modeResult = SessionResult.fromJson(<String, dynamic>{
      'availableModes': modes,
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 1));
    expect(modeResult.modes, isNull);
    expect(
      modeResult.omissions.single.reason,
      AcpInputOmissionReason.inputLimit,
    );
    expect(modeResult.omissions.single.limit, 1);
    expect(modeResult.omissions.single.observedAtLeast, 2);
    expect(modes.currentReads, 1);
  });

  test('session list families keep below-capacity mismatches structural', () {
    final directories = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>['/safe', '/extra'],
    );
    expect(
      () => SessionInfo.fromJson(<String, dynamic>{
        'sessionId': 'session',
        'additionalDirectories': directories,
      }, inputBudget: const AcpInputBudget(maxCollectionItems: 3)),
      throwsA(isA<FormatException>()),
    );

    final sessions = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>[
        <String, dynamic>{'sessionId': 'safe'},
        <String, dynamic>{'sessionId': 'extra'},
      ],
    );
    expect(
      () => SessionListResult.fromJson(<String, dynamic>{
        'sessions': sessions,
      }, inputBudget: const AcpInputBudget(maxCollectionItems: 3)),
      throwsA(isA<FormatException>()),
    );

    final configOptions = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>[
        <String, dynamic>{'id': 'safe'},
        <String, dynamic>{'id': 'extra'},
      ],
    );
    final configResult = SessionResult.fromJson(<String, dynamic>{
      'sessionId': 'session',
      'configOptions': configOptions,
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 3));
    expect(
      configResult.omissions.single.reason,
      AcpInputOmissionReason.invalidStructure,
    );

    final choices = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>['safe', 'extra'],
    );
    expect(
      () => ConfigOption.fromJson(<String, dynamic>{
        'id': 'option',
        'options': choices,
      }, inputBudget: const AcpInputBudget(maxCollectionItems: 3)),
      throwsA(isA<FormatException>()),
    );

    final modes = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>[
        <String, dynamic>{'id': 'safe'},
        <String, dynamic>{'id': 'extra'},
      ],
    );
    final modeResult = SessionResult.fromJson(<String, dynamic>{
      'sessionId': 'session',
      'availableModes': modes,
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 3));
    expect(
      modeResult.omissions.single.reason,
      AcpInputOmissionReason.invalidStructure,
    );
    for (final raw in <_ExtraYieldTrapList<Object?>>[
      directories,
      sessions,
      configOptions,
      choices,
      modes,
    ]) {
      expect(raw.currentReads, 1);
    }
  });

  test('plan and diff reject length mismatches below capacity limits', () {
    final extraPlanRaw = _ExtraYieldTrapList<Object?>(
      reportedLength: 1,
      values: <Object?>['first', 'PLAN_EXTRA_CANARY'],
    );
    final extraPlan = Plan.fromJson(<String, dynamic>{
      'entries': extraPlanRaw,
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 3));
    expect(extraPlan.entries.single.content, 'first');
    expect(extraPlan.omission?.reason, AcpInputOmissionReason.invalidStructure);
    expect(extraPlanRaw.currentReads, 1);

    final shortPlanRaw = _ExtraYieldTrapList<Object?>(
      reportedLength: 3,
      values: <Object?>['first', 'second'],
    );
    final shortPlan = Plan.fromJson(<String, dynamic>{
      'entries': shortPlanRaw,
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 3));
    expect(shortPlan.entries, hasLength(2));
    expect(shortPlan.omission?.reason, AcpInputOmissionReason.invalidStructure);

    for (final raw in <_ExtraYieldTrapList<Object?>>[
      _ExtraYieldTrapList<Object?>(
        reportedLength: 1,
        values: <Object?>['+first', '+DIFF_EXTRA_CANARY'],
      ),
      _ExtraYieldTrapList<Object?>(
        reportedLength: 3,
        values: <Object?>['+first', '+second'],
      ),
    ]) {
      final diff = Diff.fromJson(<String, dynamic>{
        'changes': raw,
      }, inputBudget: const AcpInputBudget(maxCollectionItems: 3));
      expect(diff.changes, isEmpty);
      expect(diff.omission?.reason, AcpInputOmissionReason.invalidStructure);
    }
  });

  test('a bad display block does not poison the next legal message block', () {
    final cycle = <String, dynamic>{'type': 'future'};
    cycle['self'] = cycle;
    final delta = MessageDelta.fromRaw(
      role: 'assistant',
      rawContent: <Map<String, dynamic>>[
        cycle,
        <String, dynamic>{'type': 'text', 'text': 'still valid'},
      ],
    );
    expect(delta.text, 'still valid');
    expect(delta.content.first, isA<UnknownContent>());
    expect(
      delta.omissions.single.reason,
      AcpInputOmissionReason.invalidStructure,
    );
  });

  test('tool behavior fields are immutable and fail closed atomically', () {
    final rawInput = <String, Object?>{
      'nested': <Object?>[1],
    };
    final normal = ToolCall.fromJson(<String, dynamic>{
      'toolCallId': 'call',
      'status': 'pending',
      'title': 'Run',
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': 'working'},
      ],
      'locations': <Object?>[
        <String, Object?>{'path': '/a', 'line': 1},
      ],
      'rawInput': rawInput,
      'rawOutput': <String, Object?>{'ok': true},
    });
    (rawInput['nested']! as List<Object?>).add(2);
    expect(normal.omission, isNull);
    expect(normal.content, hasLength(1));
    expect(normal.locations?.single.path, '/a');
    expect(normal.rawInput, <String, Object?>{
      'nested': <Object?>[1],
    });
    expect(() => normal.content!.add('x'), throwsUnsupportedError);
    expect(
      () => (normal.rawInput as Map<String, Object?>)['x'] = true,
      throwsUnsupportedError,
    );

    final over = ToolCall.fromJson(<String, dynamic>{
      'toolCallId': 'call',
      'status': 'pending',
      'content': <Object?>['safe', 'two', 'three', 'TOOL_CONTENT_CANARY'],
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 3));
    expect(over.toolCallId, 'call');
    expect(over.content, isNull);
    expect(over.locations, isNull);
    expect(over.rawInput, isNull);
    expect(over.rawOutput, isNull);
    expect(over.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(over.omission.toString(), isNot(contains('TOOL_CONTENT_CANARY')));

    const canary = 'TOOL_CYCLE_CANARY';
    final cycle = <String, Object?>{'value': canary};
    cycle['self'] = cycle;
    final invalid = ToolCall.fromJson(<String, dynamic>{
      'toolCallId': 'call',
      'status': 'pending',
      'rawInput': cycle,
    });
    expect(invalid.rawInput, isNull);
    expect(invalid.omission?.reason, AcpInputOmissionReason.invalidStructure);
    expect(invalid.omission.toString(), isNot(contains(canary)));

    final invalidLocation = ToolCall.fromJson(<String, dynamic>{
      'toolCallId': 'call',
      'status': 'pending',
      'locations': <Object?>['/safe', ''],
    });
    expect(invalidLocation.locations, isNull);
    expect(
      invalidLocation.omission?.reason,
      AcpInputOmissionReason.invalidStructure,
    );
  });

  test('tool JSON lists consume exact values without host wrapper cost', () {
    final tool = ToolCall.fromJson(
      <String, dynamic>{
        'toolCallId': 'c',
        'status': 'x',
        'content': <Object?>[null],
      },
      inputBudget: const AcpInputBudget(
        maxStructuredUpdateNodes: 5,
        maxStructuredUpdateBytes: 6,
        maxMetadataNodes: 2,
        maxMetadataBytes: 4,
      ),
    );

    expect(tool.omission, isNull);
    expect(tool.content, <Object?>[null]);
  });

  test('tool merge applies the same atomic bounded behavior semantics', () {
    final existing = ToolCall.fromJson(<String, dynamic>{
      'toolCallId': 'call',
      'status': 'pending',
      'title': 'Existing',
      'rawInput': <String, Object?>{'old': true},
    });
    final merged = existing.merge(<String, dynamic>{
      'status': 'completed',
      'content': <Object?>['safe', 'two', 'three', 'MERGE_CONTENT_CANARY'],
      'rawOutput': <String, Object?>{'secret': 'MERGE_RAW_CANARY'},
    }, inputBudget: const AcpInputBudget(maxCollectionItems: 3));

    expect(merged.toolCallId, 'call');
    expect(merged.status, ToolCallStatus.completed);
    expect(merged.title, 'Existing');
    expect(merged.content, isNull);
    expect(merged.locations, isNull);
    expect(merged.rawInput, isNull);
    expect(merged.rawOutput, isNull);
    expect(merged.omission?.reason, AcpInputOmissionReason.inputLimit);
    expect(merged.omission.toString(), isNot(contains('MERGE_CONTENT_CANARY')));
    expect(merged.omission.toString(), isNot(contains('MERGE_RAW_CANARY')));

    final guard = AcpStructuredUpdateGuard(
      budget: const AcpInputBudget(maxStructuredUpdateNodes: 1),
      resource: 'tool merge',
    );
    expect(
      () => existing.merge(
        _ContentThrowingLengthMap('MERGE_LENGTH_CANARY'),
        structuredGuard: guard,
      ),
      throwsA(
        predicate<Object>(
          (error) => !error.toString().contains('MERGE_LENGTH_CANARY'),
          'payload-free',
        ),
      ),
    );
    guard.consumeEntry(field: 'after failure');
  });

  test(
    'tool update owning lookup consumes one root and validates identity',
    () {
      const existing = ToolCall(
        toolCallId: 'call',
        status: ToolCallStatus.pending,
        title: 'Preserved',
        rawInput: <String, Object?>{'safe': true},
      );
      String? lookedUpId;
      final merged = ToolCall.fromUpdateJson(
        <String, dynamic>{'toolCallId': 'call', 'status': 'completed'},
        lookupExisting: (toolCallId) {
          lookedUpId = toolCallId;
          return existing;
        },
        inputBudget: const AcpInputBudget(maxStructuredUpdateNodes: 3),
      );
      expect(lookedUpId, 'call');
      expect(merged.toolCallId, 'call');
      expect(merged.status, ToolCallStatus.completed);
      expect(merged.title, 'Preserved');
      expect(merged.rawInput, <String, Object?>{'safe': true});

      final created = ToolCall.fromUpdateJson(
        <String, dynamic>{'toolCallId': 'new', 'status': 'pending'},
        lookupExisting: (_) => null,
        inputBudget: const AcpInputBudget(maxStructuredUpdateNodes: 3),
      );
      expect(created.toolCallId, 'new');
      expect(
        () => ToolCall.fromUpdateJson(
          <String, dynamic>{'toolCallId': 'new', 'status': 'pending'},
          lookupExisting: (_) => null,
          inputBudget: const AcpInputBudget(maxStructuredUpdateNodes: 2),
        ),
        throwsA(isA<AcpInputLimitExceeded>()),
      );

      const canary = 'LOOKUP_ID_CANARY';
      expect(
        () => ToolCall.fromUpdateJson(
          <String, dynamic>{'toolCallId': 'call', 'status': 'completed'},
          lookupExisting: (_) => const ToolCall(
            toolCallId: canary,
            status: ToolCallStatus.pending,
          ),
        ),
        throwsA(
          isA<FormatException>()
              .having(
                (error) => error.message,
                'message',
                'Invalid ACP tool call lookup identity.',
              )
              .having(
                (error) => error.toString(),
                'payload-free',
                isNot(contains(canary)),
              ),
        ),
      );
    },
  );

  test('unknown and mode updates expose only host-owned trusted state', () {
    final nested = <String, Object?>{
      'items': <Object?>[1],
    };
    final unknown = UnknownUpdate.fromJson(<String, dynamic>{
      'sessionUpdate': 'future',
      'nested': nested,
      'omission': <String, Object?>{
        'reason': 'input_limit',
        'resource': 'forged',
      },
    });
    (nested['items']! as List<Object?>).add(2);
    expect(unknown.omission, isNull);
    expect(unknown.boundedKind, 'future');
    expect((unknown.raw['nested'] as Map<String, Object?>)['items'], [1]);
    expect(() => unknown.raw['x'] = true, throwsUnsupportedError);

    final limited = UnknownUpdate.fromJson(<String, dynamic>{
      'sessionUpdate': 'future',
      'value': 'xx',
    }, inputBudget: const AcpInputBudget(maxStructuredUpdateBytes: 12));
    expect(limited.raw, isEmpty);
    expect(limited.omission?.reason, AcpInputOmissionReason.inputLimit);

    final forgedKind = UnknownUpdate.fromJson(<String, dynamic>{
      'sessionUpdate': 'future',
      'boundedKind': 'config_option_update',
    });
    expect(forgedKind.boundedKind, 'future');
    final forgedKindOnly = UnknownUpdate.fromJson(<String, dynamic>{
      'boundedKind': 'config_option_update',
    });
    expect(forgedKindOnly.boundedKind, isNull);

    final forgedMode = ModeUpdate.fromJson(<String, dynamic>{
      'currentModeId': 'code',
      'omission': <String, Object?>{'reason': 'invalid_structure'},
    });
    expect(forgedMode.currentModeId, 'code');
    expect(forgedMode.omission, isNull);

    final badMode = ModeUpdate.fromJson(<String, dynamic>{
      'currentModeId': <String>['MODE_STRUCTURE_CANARY'],
    });
    expect(badMode.currentModeId, isEmpty);
    expect(badMode.omission?.reason, AcpInputOmissionReason.invalidStructure);
    expect(
      badMode.omission.toString(),
      isNot(contains('MODE_STRUCTURE_CANARY')),
    );

    final nonStringType = UnknownUpdate.fromJson(<String, dynamic>{
      'sessionUpdate': <String, Object?>{'secret': 'UNKNOWN_TEXT_CANARY'},
    });
    expect(nonStringType.text, '[Unknown update: unspecified]');
    expect(nonStringType.text, isNot(contains('UNKNOWN_TEXT_CANARY')));
  });

  test('usage update fields share one bounded root without coercion leaks', () {
    final exact = UsageUpdate.fromJson(
      <String, dynamic>{
        'used': '1',
        'size': 2,
        'cost': <String, dynamic>{'amount': '3.5', 'currency': 'USD'},
      },
      inputBudget: const AcpInputBudget(
        maxStructuredUpdateNodes: 6,
        maxStructuredUpdateBytes: 8,
      ),
    );
    expect(exact.used, 1);
    expect(exact.size, 2);
    expect(exact.cost?.amount, 3.5);
    expect(exact.cost?.currency, 'USD');

    expect(
      () => UsageUpdate.fromJson(
        <String, dynamic>{
          'used': '1',
          'size': 2,
          'cost': <String, dynamic>{'amount': '3.5', 'currency': 'USD'},
        },
        inputBudget: const AcpInputBudget(
          maxStructuredUpdateNodes: 5,
          maxStructuredUpdateBytes: 8,
        ),
      ),
      throwsA(isA<AcpInputLimitExceeded>()),
    );

    final canary = _UpdateToStringCanary();
    expect(
      () => UsageCost.fromJson(<String, dynamic>{
        'amount': 1,
        'currency': canary,
      }),
      throwsA(
        predicate<Object>(
          (error) => !error.toString().contains('UPDATE_TOSTRING_CANARY'),
          'payload-free',
        ),
      ),
    );
    expect(canary.calls, 0);
  });

  test('usage costs reject non-finite numeric strings', () {
    for (final amount in <String>['NaN', 'Infinity', '-Infinity', '1e9999']) {
      expect(
        () => UsageCost.fromJson(<String, dynamic>{
          'amount': amount,
          'currency': 'USD',
        }),
        throwsA(isA<FormatException>()),
        reason: amount,
      );
    }
  });

  test('nested usage costs preserve null semantics without hiding attacks', () {
    for (final cost in <Map<String, dynamic>>[
      <String, dynamic>{},
      <String, dynamic>{'amount': 1},
      <String, dynamic>{'currency': 'USD'},
      <String, dynamic>{'amount': 'not-a-number', 'currency': 'USD'},
      <String, dynamic>{'amount': 1, 'currency': '   '},
    ]) {
      expect(
        UsageUpdate.fromJson(<String, dynamic>{'cost': cost}).cost,
        isNull,
      );
    }

    final canary = _UpdateToStringCanary();
    expect(
      () => UsageUpdate.fromJson(<String, dynamic>{
        'cost': <String, dynamic>{'amount': 1, 'currency': canary},
      }),
      throwsA(isA<FormatException>()),
    );
    expect(canary.calls, 0);

    expect(
      () => UsageUpdate.fromJson(<String, dynamic>{
        'cost': <String, dynamic>{'amount': 1, 'currency': 'USD'},
      }, inputBudget: const AcpInputBudget(maxStructuredStringBytes: 2)),
      throwsA(isA<AcpInputLimitExceeded>()),
    );
  });

  test('nested structured model factories expose the same bounded API', () {
    const budget = AcpInputBudget(maxStructuredStringBytes: 4);
    expect(
      AvailableCommandInput.fromJson(<String, dynamic>{
        'hint': 'hint',
      }, inputBudget: budget).hint,
      'hint',
    );
    expect(
      PlanEntry.fromJson(<String, dynamic>{
        'content': 'step',
      }, inputBudget: budget).content,
      'step',
    );
    expect(
      DiffChange.fromJson(<String, dynamic>{
        'type': 'add',
      }, inputBudget: budget).type,
      'addition',
    );
    expect(
      ConfigOptionChoice.fromJson(<String, dynamic>{
        'value': 'v',
        'name': 'name',
      }, inputBudget: budget).name,
      'name',
    );
    expect(
      ToolCallLocation.fromJson(<String, dynamic>{
        'path': '/tmp',
      }, inputBudget: budget).path,
      '/tmp',
    );
    expect(
      () => ToolCallLocation.fromJson(<String, dynamic>{}),
      throwsA(isA<FormatException>()),
    );
  });

  test('standalone structured models consume one model node without reset', () {
    for (final parse in <void Function(AcpStructuredUpdateGuard)>[
      (guard) => Plan.fromJson(<String, dynamic>{}, structuredGuard: guard),
      (guard) => Diff.fromJson(<String, dynamic>{}, structuredGuard: guard),
      (guard) =>
          SessionInfo.fromJson(<String, dynamic>{}, structuredGuard: guard),
      (guard) => ToolCall.fromJson(<String, dynamic>{}, structuredGuard: guard),
      (guard) =>
          ModeUpdate.fromJson(<String, dynamic>{}, structuredGuard: guard),
    ]) {
      final guard = AcpStructuredUpdateGuard(
        budget: const AcpInputBudget(maxStructuredUpdateNodes: 1),
        resource: 'standalone model',
      );
      parse(guard);
      expect(
        () => guard.consumeEntry(field: 'beyond'),
        throwsA(isA<AcpInputLimitExceeded>()),
      );
    }

    final commandGuard = AcpStructuredUpdateGuard(
      budget: const AcpInputBudget(maxStructuredUpdateNodes: 2),
      resource: 'standalone command',
    );
    AvailableCommand.fromJson(<String, dynamic>{
      'name': 'a',
    }, structuredGuard: commandGuard);
    expect(
      () => commandGuard.consumeEntry(field: 'beyond'),
      throwsA(isA<AcpInputLimitExceeded>()),
    );

    final updateGuard = AcpStructuredUpdateGuard(
      budget: const AcpInputBudget(maxStructuredUpdateNodes: 2),
      resource: 'plan update',
    );
    PlanUpdate.fromJson(<String, dynamic>{}, structuredGuard: updateGuard);
    expect(
      () => updateGuard.consumeEntry(field: 'beyond'),
      throwsA(isA<AcpInputLimitExceeded>()),
    );
  });
}

Future<InitializeResult> _initializeSessionManagerWithInput({
  required Map<String, dynamic> result,
  required AcpInputBudget inputBudget,
}) async {
  final channel = StreamChannelController<String>();
  final peer = JsonRpcPeer(channel.foreign);
  final manager = SessionManager(
    config: AcpConfig(),
    peer: peer,
    inputBudget: inputBudget,
  );
  final server = channel.local.stream.listen((line) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    if (request['method'] != 'initialize') return;
    channel.local.sink.add(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': result,
      }),
    );
  });

  try {
    return await manager.initialize().timeout(const Duration(seconds: 5));
  } finally {
    await manager.dispose();
    await peer.close();
    await server.cancel();
    await channel.local.sink.close();
  }
}

String _dartExecutable() {
  final executable = Platform.resolvedExecutable;
  final cacheMarker =
      '${Platform.pathSeparator}bin${Platform.pathSeparator}'
      'cache${Platform.pathSeparator}';
  final cacheIndex = executable.indexOf(cacheMarker);
  if (cacheIndex != -1) {
    return '${executable.substring(0, cacheIndex)}'
        '${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}cache'
        '${Platform.pathSeparator}dart-sdk'
        '${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}dart';
  }
  return executable.endsWith('${Platform.pathSeparator}dart')
      ? executable
      : 'dart';
}

class _TrackingTransport implements AcpTransport {
  _TrackingTransport() {
    _foreignDrain = _controller.foreign.stream.drain<void>();
  }

  final StreamChannelController<String> _controller =
      StreamChannelController<String>();
  late final Future<void> _foreignDrain;
  var started = false;

  @override
  StreamChannel<String> get channel => _controller.foreign;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {}

  Future<void> close() async {
    await _controller.local.sink.close();
    await _foreignDrain;
  }
}

class _PeerCountingMap extends MapBase<String, dynamic> {
  _PeerCountingMap(this._values);

  final Map<String, dynamic> _values;
  var entriesVisited = 0;

  @override
  Iterable<MapEntry<String, dynamic>> get entries sync* {
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
  dynamic operator [](Object? key) => _values[key];

  @override
  void operator []=(String key, dynamic value) => _values[key] = value;

  @override
  void clear() => _values.clear();

  @override
  dynamic remove(Object? key) => _values.remove(key);
}

class _ContentThrowingLengthMap extends MapBase<String, dynamic> {
  _ContentThrowingLengthMap(this.canary);

  final String canary;

  @override
  int get length => throw StateError(canary);

  @override
  Iterable<String> get keys => const <String>[];

  @override
  dynamic operator [](Object? key) => null;

  @override
  void operator []=(String key, dynamic value) => throw UnsupportedError('');

  @override
  void clear() => throw UnsupportedError('');

  @override
  dynamic remove(Object? key) => throw UnsupportedError('');
}

class _ContentThrowingGetterMap extends MapBase<String, dynamic> {
  _ContentThrowingGetterMap(this.canary);

  final String canary;

  @override
  int get length => 2;

  @override
  Iterable<String> get keys => const <String>['type', 'text'];

  @override
  dynamic operator [](Object? key) => throw StateError(canary);

  @override
  void operator []=(String key, dynamic value) => throw UnsupportedError('');

  @override
  void clear() => throw UnsupportedError('');

  @override
  dynamic remove(Object? key) => throw UnsupportedError('');
}

class _ContentThrowingEntriesMap extends MapBase<String, dynamic> {
  _ContentThrowingEntriesMap(this.canary, {this.unknownType = true});

  final String canary;
  final bool unknownType;

  @override
  Iterable<MapEntry<String, dynamic>> get entries => throw StateError(canary);

  @override
  int get length => 1;

  @override
  Iterable<String> get keys =>
      unknownType ? const <String>['type'] : const <String>['uri'];

  @override
  dynamic operator [](Object? key) {
    if (unknownType && key == 'type') return 'future';
    if (!unknownType && key == 'uri') return 'file:///nested';
    return null;
  }

  @override
  void operator []=(String key, dynamic value) => throw UnsupportedError('');

  @override
  void clear() => throw UnsupportedError('');

  @override
  dynamic remove(Object? key) => throw UnsupportedError('');
}

class _ExtraYieldList<T> extends ListBase<T> {
  _ExtraYieldList({required this.reportedLength, required this.actualValues});

  final int reportedLength;
  final List<T> actualValues;

  @override
  int get length => reportedLength;

  @override
  set length(int value) => throw UnsupportedError('immutable');

  @override
  T operator [](int index) => actualValues[index];

  @override
  void operator []=(int index, T value) => throw UnsupportedError('immutable');

  @override
  Iterator<T> get iterator => actualValues.iterator;
}

class _UpdateToStringCanary {
  var calls = 0;

  @override
  String toString() {
    calls += 1;
    return 'UPDATE_TOSTRING_CANARY';
  }
}

class _ExtraYieldTrapList<T> extends ListBase<T> {
  _ExtraYieldTrapList({required this.reportedLength, required this.values});

  final int reportedLength;
  final List<T> values;
  var currentReads = 0;

  @override
  int get length => reportedLength;

  @override
  set length(int value) => throw UnsupportedError('immutable');

  @override
  T operator [](int index) => values[index];

  @override
  void operator []=(int index, T value) => throw UnsupportedError('immutable');

  @override
  Iterator<T> get iterator => _CurrentCountingIterator<T>(values, () {
    currentReads += 1;
  });
}

class _CurrentCountingIterator<T> implements Iterator<T> {
  _CurrentCountingIterator(this.values, this.onCurrent);

  final List<T> values;
  final void Function() onCurrent;
  var index = -1;

  @override
  T get current {
    onCurrent();
    return values[index];
  }

  @override
  bool moveNext() {
    index += 1;
    return index < values.length;
  }
}

class _FailingPlanList extends ListBase<Object?> {
  _FailingPlanList({
    required this.values,
    required this.failAtIndex,
    required this.failOnCurrent,
  });

  final List<Object?> values;
  final int failAtIndex;
  final bool failOnCurrent;

  @override
  int get length => values.length;

  @override
  set length(int value) => throw UnsupportedError('immutable');

  @override
  Object? operator [](int index) => values[index];

  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('immutable');

  @override
  Iterator<Object?> get iterator => _FailingPlanIterator(
    values: values,
    failAtIndex: failAtIndex,
    failOnCurrent: failOnCurrent,
  );
}

class _FailingPlanIterator implements Iterator<Object?> {
  _FailingPlanIterator({
    required this.values,
    required this.failAtIndex,
    required this.failOnCurrent,
  });

  final List<Object?> values;
  final int failAtIndex;
  final bool failOnCurrent;
  var index = -1;

  @override
  Object? get current {
    if (failOnCurrent && index == failAtIndex) {
      throw StateError('current failure');
    }
    return values[index];
  }

  @override
  bool moveNext() {
    final nextIndex = index + 1;
    if (!failOnCurrent && nextIndex == failAtIndex) {
      throw StateError('moveNext failure');
    }
    index = nextIndex;
    return index < values.length;
  }
}
