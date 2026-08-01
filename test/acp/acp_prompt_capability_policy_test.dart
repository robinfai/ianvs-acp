import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_agent_capabilities.dart';
import 'package:ianvs_acp/acp/acp_prompt_capability_policy.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';

void main() {
  const advertised = AcpPromptCapabilities(
    image: true,
    audio: false,
    embeddedContext: false,
  );

  test('ACP image capability remains authoritative for Pi DeepSeek', () {
    final resolution = resolvePromptCapabilitiesForSession(
      advertised: advertised,
      settings: _settings(
        currentValue: 'deepseek/deepseek-v4-pro',
        name: 'deepseek/DeepSeek V4 Pro',
      ),
      agentName: 'Pi',
      agentInfo: const <String, Object?>{'name': 'pi-acp'},
    );

    expect(resolution.capabilities?.image, isTrue);
    expect(resolution.imageLimitation, isNull);
  });

  test('Pi keeps image support for an unknown model', () {
    final resolution = resolvePromptCapabilitiesForSession(
      advertised: advertised,
      settings: _settings(
        currentValue: 'google/gemini-3-pro',
        name: 'google/Gemini 3 Pro',
      ),
      agentName: 'Pi',
      agentInfo: const <String, Object?>{'name': 'pi-acp'},
    );

    expect(resolution.capabilities?.image, isTrue);
    expect(resolution.imageLimitation, isNull);
  });

  test('model metadata cannot override ACP image capability', () {
    final textOnly = resolvePromptCapabilitiesForSession(
      advertised: advertised,
      settings: _settings(
        currentValue: 'custom/text',
        name: 'Text model',
        description: 'Text-only input',
      ),
      agentName: 'Custom',
    );
    final vision = resolvePromptCapabilitiesForSession(
      advertised: advertised,
      settings: _settings(
        currentValue: 'deepseek/custom-vision',
        name: 'Custom vision',
        description: 'Multimodal image input',
      ),
      agentName: 'Pi',
      agentInfo: const <String, Object?>{'name': 'pi-acp'},
    );

    expect(textOnly.capabilities?.image, isTrue);
    expect(vision.capabilities?.image, isTrue);
  });

  test('missing ACP image support is not inferred from model metadata', () {
    final resolution = resolvePromptCapabilitiesForSession(
      advertised: const AcpPromptCapabilities(
        image: false,
        audio: false,
        embeddedContext: false,
      ),
      settings: _settings(
        currentValue: 'custom/vision',
        name: 'Vision model',
        description: 'Multimodal image input',
      ),
      agentName: 'Custom',
    );

    expect(resolution.capabilities?.image, isFalse);
    expect(resolution.imageLimitation, isNull);
  });
}

AcpSessionSettings _settings({
  required String currentValue,
  required String name,
  String? description,
}) {
  return AcpSessionSettings(
    configOptions: <AcpConfigOption>[
      AcpConfigOption(
        id: 'model',
        name: 'Model',
        type: 'select',
        currentValue: currentValue,
        options: <AcpConfigOptionChoice>[
          AcpConfigOptionChoice(
            value: currentValue,
            name: name,
            description: description,
          ),
        ],
      ),
    ],
  );
}
