import 'acp_agent_capabilities.dart';
import 'acp_session_settings.dart';

class AcpPromptCapabilityResolution {
  const AcpPromptCapabilityResolution({
    required this.capabilities,
    this.imageLimitation,
  });

  final AcpPromptCapabilities? capabilities;
  final String? imageLimitation;
}

AcpPromptCapabilityResolution resolvePromptCapabilitiesForSession({
  required AcpPromptCapabilities? advertised,
  required AcpSessionSettings settings,
  required String agentName,
  Map<String, Object?> agentInfo = const <String, Object?>{},
}) {
  if (advertised?.image != true) {
    return AcpPromptCapabilityResolution(capabilities: advertised);
  }

  final modelOption = settings.modelOption;
  final modelValue = modelOption?.currentValue.trim() ?? '';
  final modelLabel = modelOption?.currentChoiceLabel.trim() ?? modelValue;
  AcpConfigOptionChoice? selectedChoice;
  if (modelOption != null) {
    for (final choice in modelOption.options) {
      if (choice.value == modelOption.currentValue) {
        selectedChoice = choice;
        break;
      }
    }
  }
  final description = selectedChoice?.description?.trim() ?? '';

  final explicitlySupportsImages = _descriptionSupportsImages(description);
  final explicitlyTextOnly = _descriptionIsTextOnly(description);
  final piDeepSeek =
      _isPiAdapter(agentName, agentInfo) && _isDeepSeekModel(modelValue);
  if (explicitlySupportsImages || (!explicitlyTextOnly && !piDeepSeek)) {
    return AcpPromptCapabilityResolution(capabilities: advertised);
  }

  final label = modelLabel.isEmpty ? 'The selected model' : modelLabel;
  return AcpPromptCapabilityResolution(
    capabilities: advertised!.copyWith(image: false),
    imageLimitation:
        '$label does not accept direct image input. The attachment will be '
        'shared as a file path instead; image recognition requires a '
        'vision-capable model or Pi vision extension.',
  );
}

bool _isPiAdapter(String agentName, Map<String, Object?> agentInfo) {
  final values = <String>[
    agentName,
    if (agentInfo['name'] is String) agentInfo['name']! as String,
    if (agentInfo['title'] is String) agentInfo['title']! as String,
  ].map((value) => value.trim().toLowerCase());
  return values.any(
    (value) =>
        value == 'pi' ||
        value == 'pi acp' ||
        value.contains('pi-acp') ||
        value.contains('pi acp adapter'),
  );
}

bool _isDeepSeekModel(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized == 'deepseek' ||
      normalized.startsWith('deepseek/') ||
      normalized.contains('/deepseek-') ||
      normalized.contains('/deepseek_');
}

bool _descriptionSupportsImages(String value) {
  final normalized = value.toLowerCase();
  return normalized.contains('vision') ||
      normalized.contains('multimodal') ||
      normalized.contains('multi-modal') ||
      normalized.contains('image input') ||
      normalized.contains('images supported') ||
      normalized.contains('input: text, image') ||
      normalized.contains('input: [text, image]');
}

bool _descriptionIsTextOnly(String value) {
  final normalized = value.toLowerCase();
  return normalized.contains('text-only') ||
      normalized.contains('text only') ||
      normalized.contains('no image') ||
      normalized.contains('images unsupported') ||
      normalized.contains('does not support image') ||
      normalized.contains('input: text');
}
