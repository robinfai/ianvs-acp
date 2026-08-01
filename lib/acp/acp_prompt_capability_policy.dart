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
  // ACP capability negotiation is authoritative. Model labels, descriptions,
  // and adapter names are presentation metadata and must not override it.
  return AcpPromptCapabilityResolution(capabilities: advertised);
}
