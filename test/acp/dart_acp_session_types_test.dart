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
        'title': 'README.md',
        'mimeType': 'text/markdown',
        'text': '# Project notes',
      },
    });
    expect(delta.content[4].toJson(), {
      'type': 'resource_link',
      'uri': 'file:///workspace/lib/main.dart',
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
    expect(
      AudioContent.fromJson(<String, dynamic>{
        'mimeType': 'audio/wav',
        'uri': 'file:///linked.wav',
      }, inputBudget: budget).toJson(),
      <String, dynamic>{
        'type': 'audio',
        'mimeType': 'audio/wav',
        'uri': 'file:///linked.wav',
      },
    );
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
        13,
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
            <String, dynamic>{},
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
        'not-a-config-option',
        <String, dynamic>{'name': 'Missing id', 'currentValue': 'x'},
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
    expect(model.group, 'model');
    expect(model.options.map((choice) => choice.value), [
      'kimi-k2',
      'glm-4.6',
      '4',
    ]);
    expect(model.options[1].name, 'GLM 4.6');

    final autoApply = result.configOptions!.last;
    expect(autoApply.id, 'auto_apply');
    expect(autoApply.type, 'boolean');
    expect(autoApply.currentValue, 'true');
    expect(autoApply.options.map((choice) => choice.value), ['true', 'false']);
    expect(autoApply.options.map((choice) => choice.name), ['On', 'Off']);
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
