import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/memory/acp_sidecar_memory_extractor.dart';
import 'package:ianvs_acp/memory/memory_maintenance_extraction.dart';
import 'package:ianvs_acp/memory/openai_compatible_memory_extractor.dart';

void main() {
  test('maintenance prompt sends scoped memory only and parses requests', () {
    const memories = [
      MemoryMaintenanceItem(
        id: 'mem_1',
        kind: 'user_preference',
        scope: 'global',
        text: 'The user goes by Rod.',
      ),
      MemoryMaintenanceItem(
        id: 'mem_2',
        kind: 'user_preference',
        scope: 'global',
        text: 'The user prefers to be called Rodriguez.',
      ),
    ];

    final prompt = buildMemoryMaintenancePrompt(memories: memories);
    expect(prompt, contains('Return JSON only'));
    expect(prompt, contains('changeRequests'));
    expect(prompt, contains('mem_1'));
    expect(prompt, contains('The user goes by Rod.'));
    expect(prompt, isNot(contains('transcript')));

    final requests = parseMaintenanceChangeRequests('''
      {
        "changeRequests": [
          {
            "action": "merge",
            "targetMemoryIds": ["mem_1", "mem_2"],
            "proposedKind": "user_preference",
            "proposedScope": "global",
            "proposedText": "The user goes by Rodriguez.",
            "confidence": 0.93,
            "reason": "Both memories describe the same preferred name."
          }
        ]
      }
      ''');

    expect(requests, hasLength(1));
    expect(requests.single.action, 'merge');
    expect(requests.single.targetMemoryIds, ['mem_1', 'mem_2']);
    expect(requests.single.proposedText, 'The user goes by Rodriguez.');
  });

  test('maintenance prompt explains directional scope merge policy', () {
    final prompt = buildMemoryMaintenancePrompt(
      memories: const [
        MemoryMaintenanceItem(
          id: 'mem_session',
          kind: 'project_rule',
          scope: 'session',
          text: 'Use curl for local health checks.',
        ),
        MemoryMaintenanceItem(
          id: 'mem_repo',
          kind: 'project_rule',
          scope: 'repo',
          text: 'Use curl for local health checks.',
        ),
      ],
    );

    expect(prompt, contains('session -> repo -> global'));
    expect(prompt, contains('Do not skip intermediate scopes'));
    expect(prompt, contains('Never downgrade broader scopes'));
    expect(prompt, contains('session plus global stays global'));
    expect(prompt, contains('workspace'));
  });

  test('maintenance prompt includes memory status for cleanup decisions', () {
    final prompt = buildMemoryMaintenancePrompt(
      memories: const [
        MemoryMaintenanceItem(
          id: 'mem_disabled',
          kind: 'project_rule',
          scope: 'repo',
          status: 'disabled',
          text: 'Use curl for local health checks.',
        ),
      ],
    );

    expect(prompt, contains('"status": "disabled"'));
  });

  test('maintenance parser skips AGENTS and tool-use proposed text', () {
    final requests = parseMaintenanceChangeRequests('''
      {
        "changeRequests": [
          {
            "action": "summarize",
            "targetMemoryIds": ["mem_agents"],
            "proposedText": "AGENTS.md 约束：中文回复，严禁使用 nc 或 netcat。",
            "confidence": 0.96,
            "reason": "Agent operating rule."
          },
          {
            "action": "summarize",
            "targetMemoryIds": ["mem_project"],
            "proposedText": "The project uses Riverpod.",
            "confidence": 0.91,
            "reason": "Shorter project convention."
          }
        ]
      }
      ''');

    expect(requests, hasLength(1));
    expect(requests.single.targetMemoryIds, ['mem_project']);
    expect(requests.single.proposedText, 'The project uses Riverpod.');
  });

  test('maintenance prefilter includes cross-scope duplicate memories', () {
    final selected = prefilterMaintenanceMemories(
      memories: const [
        MemoryMaintenanceItem(
          id: 'mem_session',
          kind: 'project_rule',
          scope: 'session',
          text: 'Use curl for local health checks.',
        ),
        MemoryMaintenanceItem(
          id: 'mem_repo',
          kind: 'project_rule',
          scope: 'repo',
          text: 'Use curl for local health checks.',
        ),
      ],
    );

    expect(selected.map((memory) => memory.id), ['mem_session', 'mem_repo']);
  });

  test('maintenance prefilter includes Chinese synonym preferences', () {
    final selected = prefilterMaintenanceMemories(
      memories: const [
        MemoryMaintenanceItem(
          id: 'mem_a',
          kind: 'user_preference',
          scope: 'global',
          text: '用户偏好使用中文交流。',
        ),
        MemoryMaintenanceItem(
          id: 'mem_b',
          kind: 'user_preference',
          scope: 'global',
          text: '用户偏好以中文进行交流与回复。',
        ),
        MemoryMaintenanceItem(
          id: 'mem_c',
          kind: 'user_preference',
          scope: 'global',
          text: '用户偏好中文回复。',
        ),
      ],
    );

    expect(selected.map((memory) => memory.id), ['mem_a', 'mem_b', 'mem_c']);
  });

  test('maintenance prefilter keeps a broad batch for LLM review', () {
    final selected = prefilterMaintenanceMemories(
      maxItems: 4,
      memories: const [
        MemoryMaintenanceItem(
          id: 'mem_name',
          kind: 'user_preference',
          scope: 'global',
          text: '用户自称 Rodriguez。',
        ),
        MemoryMaintenanceItem(
          id: 'mem_city',
          kind: 'user_preference',
          scope: 'global',
          text: '用户当前位于深圳。',
        ),
        MemoryMaintenanceItem(
          id: 'mem_stack',
          kind: 'project_rule',
          scope: 'repo',
          text: '项目共享状态使用 Riverpod。',
        ),
        MemoryMaintenanceItem(
          id: 'mem_arch',
          kind: 'architecture_decision',
          scope: 'repo',
          text: 'Rust memory-core owns local persistence.',
        ),
        MemoryMaintenanceItem(
          id: 'mem_extra',
          kind: 'session_summary',
          scope: 'session',
          text: '用户在本轮测试记忆整理。',
        ),
      ],
    );

    expect(selected.map((memory) => memory.id), [
      'mem_name',
      'mem_city',
      'mem_stack',
      'mem_arch',
    ]);
  });

  test(
    'OpenAI-compatible extractor returns maintenance change requests',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final received = <String, Object?>{};
      unawaited(
        server.first.then((request) async {
          received['path'] = request.uri.path;
          received['authorization'] = request.headers.value(
            HttpHeaders.authorizationHeader,
          );
          received['body'] = jsonDecode(await utf8.decodeStream(request));
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content':
                        '{"changeRequests":[{"action":"summarize","targetMemoryIds":["mem_1"],"proposedText":"Use curl for local service checks.","confidence":0.86,"reason":"Shorter equivalent wording."}]}',
                  },
                },
              ],
            }),
          );
          await request.response.close();
        }),
      );

      final extractor = OpenAiCompatibleMemoryExtractor(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'qwen2.5:7b',
        apiKey: 'test-key',
      );
      final requests = await extractor.extractMaintenance(
        memories: const [
          MemoryMaintenanceItem(
            id: 'mem_1',
            kind: 'project_rule',
            scope: 'repo',
            text: 'Use curl for local service checks.',
          ),
        ],
      );

      expect(received['path'], '/v1/chat/completions');
      expect(received['authorization'], 'Bearer test-key');
      final body = received['body'] as Map;
      expect(body['model'], 'qwen2.5:7b');
      expect(body.toString(), contains('mem_1'));
      expect(body.toString(), isNot(contains('userPrompt')));
      expect(requests.single.action, 'summarize');
      expect(requests.single.confidence, 0.86);
    },
  );

  test('sidecar maintenance extractor sets requested model', () async {
    final fake = _JsonMaintenanceAgentClient();
    final extractor = AcpSidecarMemoryMaintenanceExtractor(
      clientFactory: () => fake,
    );

    final requests = await extractor.extract(
      memories: const [
        MemoryMaintenanceItem(
          id: 'mem_1',
          kind: 'user_preference',
          scope: 'global',
          text: 'The user goes by Rod.',
        ),
      ],
      cwd: '/workspace',
      model: 'GPT-5.3-Codex-Spark',
    );

    expect(fake.didConnect, isTrue);
    expect(fake.connected, isFalse);
    expect(fake.lastConfigId, 'model');
    expect(fake.lastConfigValue, 'GPT-5.3-Codex-Spark');
    expect(fake.lastPrompt, contains('mem_1'));
    expect(requests.single.action, 'update');
  });
}

class _JsonMaintenanceAgentClient extends FakeAgentClient {
  bool didConnect = false;

  @override
  Future<void> connect() async {
    await super.connect();
    didConnect = true;
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    String? memoryContext,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    lastPrompt = prompt;
    yield const AgentEvent(
      type: AgentEventType.agentTextDelta,
      text:
          '{"changeRequests":[{"action":"update","targetMemoryIds":["mem_1"],"proposedText":"The user goes by Rodriguez.","confidence":0.82,"reason":"Normalize preferred name."}]}',
    );
    yield const AgentEvent(type: AgentEventType.agentTextDone, text: '');
  }
}
