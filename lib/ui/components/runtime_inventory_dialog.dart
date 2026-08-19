import 'dart:convert';

import 'package:flutter/material.dart';

import '../../acp/acp_agent_capabilities.dart';
import '../../acp/acp_permission_request.dart';
import '../../acp/agent_session.dart';
import '../../config/acp_client_config.dart';
import '../../state/chat_controller.dart';
import '../../workspace/workspace.dart';
import '../theme/app_design_tokens.dart';

class RuntimeInventoryDialog extends StatelessWidget {
  const RuntimeInventoryDialog({
    super.key,
    required this.controller,
    required this.runtimeConfig,
  });

  final ChatController controller;
  final AcpClientConfig runtimeConfig;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _buildDialog(context),
    );
  }

  Widget _buildDialog(BuildContext context) {
    final capabilities = controller.capabilities;
    final session = controller.currentSession;
    final effectiveDirectories = _effectiveAdditionalDirectories(
      controller,
      runtimeConfig,
    );
    final templateAssessment = _assessTemplateRuntime(
      session,
      runtimeConfig,
      controller: controller,
      effectiveDirectories: effectiveDirectories,
    );
    final degradations = _degradations(
      controller: controller,
      templateAssessment: templateAssessment,
      effectiveDirectories: effectiveDirectories,
    );
    return AlertDialog(
      title: const Text('Runtime Inventory'),
      content: SizedBox(
        width: 760,
        height: 650,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _RuntimeSummary(
                controller: controller,
                runtimeConfig: runtimeConfig,
                effectiveDirectories: effectiveDirectories,
              ),
              _InventorySection(
                icon: Icons.memory_rounded,
                title: 'Agent runtime',
                rows: [
                  _InventoryValue('Agent', runtimeConfig.agentName),
                  _InventoryValue(
                    'Transport',
                    _agentTransport(runtimeConfig.activeAgentServer),
                  ),
                  _InventoryValue(
                    'Target',
                    _safeAgentTarget(runtimeConfig.activeAgentServer),
                  ),
                  _InventoryValue('Connection', controller.status.name),
                  _InventoryValue(
                    'Protocol',
                    capabilities == null
                        ? 'not negotiated'
                        : 'ACP ${capabilities.protocolVersion}',
                  ),
                  if (capabilities != null)
                    _InventoryValue(
                      'Agent implementation',
                      _implementationLabel(capabilities.agentInfo),
                    ),
                  if (capabilities != null)
                    _InventoryValue(
                      'Client implementation',
                      _implementationLabel(capabilities.clientInfo),
                    ),
                ],
              ),
              _InventorySection(
                icon: Icons.dashboard_customize_outlined,
                title: 'Session recipe',
                rows: [
                  _InventoryValue(
                    'Template',
                    _templateLabel(session, templateAssessment),
                  ),
                  _InventoryValue(
                    'Session',
                    session == null ? 'none' : session.id,
                  ),
                  _InventoryValue(
                    'Mode',
                    controller.sessionSettings.modes.currentModeId ?? 'none',
                  ),
                  _InventoryValue(
                    'Model',
                    controller.currentModelValue ?? 'agent default',
                  ),
                  _InventoryValue(
                    'Reasoning',
                    controller.currentReasoningEffortValue ?? 'agent default',
                  ),
                  _InventoryValue(
                    'Additional directories',
                    effectiveDirectories.isEmpty
                        ? 'none'
                        : _inventoryLines(effectiveDirectories),
                  ),
                ],
              ),
              _InventorySection(
                icon: Icons.hub_outlined,
                title: 'MCP and client providers',
                rows: [
                  _InventoryValue(
                    'MCP servers',
                    runtimeConfig.mcpServers.isEmpty
                        ? 'none'
                        : _inventoryLines(
                            runtimeConfig.mcpServers.map(
                              (server) =>
                                  '${_boundedInventoryText(server.name, maxCodeUnits: 480)} '
                                  '(${_boundedInventoryText(server.type, maxCodeUnits: 24)})',
                            ),
                          ),
                  ),
                  _InventoryValue(
                    'Filesystem',
                    _filesystemLabel(runtimeConfig),
                  ),
                  _InventoryValue(
                    'Terminal',
                    runtimeConfig.clientProviders.terminal.enabled
                        ? 'enabled'
                        : 'disabled',
                  ),
                  _InventoryValue(
                    'Permission policy',
                    _permissionPolicyLabel(controller),
                  ),
                  _InventoryValue(
                    'Trust rules',
                    controller.permissionTrustRules.length.toString(),
                  ),
                  _InventoryValue(
                    'Review agent',
                    _reviewAgentLabel(controller, runtimeConfig),
                  ),
                  _InventoryValue(
                    'Assistant enhancer',
                    _assistantLabel(runtimeConfig),
                  ),
                ],
              ),
              _InventorySection(
                icon: Icons.handshake_outlined,
                title: 'Negotiated capabilities',
                rows: _capabilityRows(capabilities),
              ),
              _InventorySection(
                icon: Icons.key_outlined,
                title: 'Credential inventory',
                rows: [
                  _InventoryValue(
                    'Agent secret references',
                    _agentCredentialLabel(runtimeConfig.activeAgentServer),
                  ),
                  _InventoryValue(
                    'MCP secret references',
                    _mcpCredentialLabel(runtimeConfig.mcpServers),
                  ),
                  _InventoryValue(
                    'Permission-review secret references',
                    _reviewCredentialLabel(runtimeConfig),
                  ),
                  const _InventoryValue(
                    'Values',
                    'redacted (inventory shows references only)',
                  ),
                ],
              ),
              if (degradations.isNotEmpty)
                _DegradationSection(messages: degradations),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _RuntimeSummary extends StatelessWidget {
  const _RuntimeSummary({
    required this.controller,
    required this.runtimeConfig,
    required this.effectiveDirectories,
  });

  final ChatController controller;
  final AcpClientConfig runtimeConfig;
  final List<String> effectiveDirectories;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primaryMist,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: AppColors.surface,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.account_tree_outlined,
              size: 19,
              color: AppColors.primaryDark,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _boundedInventoryText(runtimeConfig.agentName),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${runtimeConfig.mcpServers.length} MCP · '
                  '${effectiveDirectories.length} extra roots · '
                  '${controller.status.name}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _InventoryValue {
  const _InventoryValue(this.label, this.value);

  final String label;
  final String value;
}

class _InventorySection extends StatelessWidget {
  const _InventorySection({
    required this.icon,
    required this.title,
    required this.rows,
  });

  final IconData icon;
  final String title;
  final List<_InventoryValue> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: AppColors.primaryDark),
              const SizedBox(width: 7),
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          for (var index = 0; index < rows.length; index++) ...[
            _InventoryRow(value: rows[index]),
            if (index < rows.length - 1)
              const Divider(height: 13, color: AppColors.borderSoft),
          ],
        ],
      ),
    );
  }
}

class _InventoryRow extends StatelessWidget {
  const _InventoryRow({required this.value});

  final _InventoryValue value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 174,
          child: Text(
            value.label,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            _boundedInventoryText(value.value),
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _DegradationSection extends StatelessWidget {
  const _DegradationSection({required this.messages});

  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('runtime-inventory-degradations'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 17,
                color: AppColors.warning,
              ),
              SizedBox(width: 7),
              Text(
                'Degradations',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          for (final message in messages)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '• ${_boundedInventoryText(message, maxCodeUnits: 4094)}',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

List<_InventoryValue> _capabilityRows(AcpAgentCapabilities? capabilities) {
  if (capabilities == null) {
    return const <_InventoryValue>[
      _InventoryValue('Initialize', 'capabilities not negotiated'),
    ];
  }
  String supported(bool value) => value ? 'supported' : 'not advertised';
  return <_InventoryValue>[
    _InventoryValue('Session list', supported(capabilities.session.list)),
    _InventoryValue('Session resume', supported(capabilities.session.resume)),
    _InventoryValue('Session fork', supported(capabilities.session.fork)),
    _InventoryValue(
      'Config options',
      supported(capabilities.session.configOptions),
    ),
    _InventoryValue(
      'Additional directories',
      supported(capabilities.session.additionalDirectories),
    ),
    _InventoryValue(
      'Prompt media',
      [
            if (capabilities.prompt.image) 'image',
            if (capabilities.prompt.audio) 'audio',
            if (capabilities.prompt.embeddedContext) 'embedded context',
          ].join(', ').isEmpty
          ? 'none advertised'
          : [
              if (capabilities.prompt.image) 'image',
              if (capabilities.prompt.audio) 'audio',
              if (capabilities.prompt.embeddedContext) 'embedded context',
            ].join(', '),
    ),
    _InventoryValue(
      'MCP transports',
      [
            if (capabilities.mcp.http) 'HTTP',
            if (capabilities.mcp.sse) 'SSE',
            if (capabilities.mcp.acp) 'ACP',
          ].join(', ').isEmpty
          ? 'none advertised'
          : [
              if (capabilities.mcp.http) 'HTTP',
              if (capabilities.mcp.sse) 'SSE',
              if (capabilities.mcp.acp) 'ACP',
            ].join(', '),
    ),
  ];
}

List<String> _degradations({
  required ChatController controller,
  required _TemplateRuntimeAssessment templateAssessment,
  required List<String> effectiveDirectories,
}) {
  final messages = <String>[...controller.sessionTemplateWarnings];
  final templateWarning = templateAssessment.warning;
  if (templateWarning != null) messages.add(templateWarning);
  if (controller.capabilities == null) {
    messages.add('ACP capabilities have not been negotiated.');
  }
  if (effectiveDirectories.isNotEmpty &&
      controller.capabilities != null &&
      !controller.capabilities!.session.additionalDirectories) {
    messages.add('The agent did not advertise additional-directory support.');
  }
  return List<String>.unmodifiable(messages.toSet());
}

List<String> _effectiveAdditionalDirectories(
  ChatController controller,
  AcpClientConfig runtimeConfig,
) {
  final session = controller.currentSession;
  if (session != null) return session.additionalDirectories;
  return runtimeConfig.additionalDirectories;
}

String _templateLabel(
  AgentSession? session,
  _TemplateRuntimeAssessment assessment,
) {
  final id = session?.sessionTemplateId?.trim();
  if (id == null || id.isEmpty) return 'custom';
  final version = session?.sessionTemplateVersion;
  final identity = version == null ? id : '$id@$version';
  final configuredTemplate = assessment.template;
  if (!assessment.applied) return '$identity (base runtime fallback)';
  return configuredTemplate == null
      ? '$identity (definition unavailable)'
      : '$identity · ${_boundedInventoryText(configuredTemplate.name)}';
}

final class _TemplateRuntimeAssessment {
  const _TemplateRuntimeAssessment({
    this.template,
    required this.applied,
    this.warning,
  });

  final SessionTemplateConfig? template;
  final bool applied;
  final String? warning;
}

_TemplateRuntimeAssessment _assessTemplateRuntime(
  AgentSession? session,
  AcpClientConfig runtimeConfig, {
  required ChatController controller,
  required List<String> effectiveDirectories,
}) {
  final templateId = session?.sessionTemplateId?.trim();
  if (templateId == null || templateId.isEmpty) {
    return const _TemplateRuntimeAssessment(applied: false);
  }
  final template = runtimeConfig.sessionTemplateNamed(templateId);
  if (template == null) {
    return _TemplateRuntimeAssessment(
      applied: false,
      warning:
          'Template "$templateId" is no longer configured; base runtime is in use.',
    );
  }
  final recordedVersion = session?.sessionTemplateVersion;
  if (recordedVersion == null) {
    return _TemplateRuntimeAssessment(
      template: template,
      applied: false,
      warning:
          'Session template "$templateId" has no recorded version; base runtime is in use.',
    );
  }
  if (recordedVersion != template.version) {
    return _TemplateRuntimeAssessment(
      template: template,
      applied: false,
      warning:
          'Session used ${template.id}@$recordedVersion; configured version is ${template.version}. Base runtime is in use.',
    );
  }
  final base = runtimeConfig.configForSessionIndexAgent(session?.agentName);
  if (base == null) {
    return _TemplateRuntimeAssessment(
      template: template,
      applied: false,
      warning:
          'The persisted Agent for ${template.identity} is unavailable; base runtime is in use.',
    );
  }
  try {
    final expected = base.forSessionTemplate(template);
    final persistedAgent =
        base.activeAgentServer?.persistenceIdentity ?? base.agentName;
    final templateAgent =
        expected.activeAgentServer?.persistenceIdentity ?? expected.agentName;
    if (persistedAgent != templateAgent) {
      return _TemplateRuntimeAssessment(
        template: template,
        applied: false,
        warning:
            '${template.identity} now targets a different Agent; the persisted Agent and base runtime are in use.',
      );
    }
    if (!_sameRuntimeSemantics(
      runtimeConfig,
      expected,
      effectiveDirectories: effectiveDirectories,
    )) {
      return _TemplateRuntimeAssessment(
        template: template,
        applied: false,
        warning:
            '${template.identity} is recorded for this session, but the active runtime does not match its MCP, directory, permission, or assistant settings. Base runtime is in use.',
      );
    }
    final settingMismatches = _templateSettingMismatches(controller, template);
    if (settingMismatches.isNotEmpty) {
      return _TemplateRuntimeAssessment(
        template: template,
        applied: true,
        warning:
            '${template.identity} runtime is active, but its requested ${settingMismatches.join(', ')} do not match the current session settings.',
      );
    }
  } on FormatException catch (error) {
    return _TemplateRuntimeAssessment(
      template: template,
      applied: false,
      warning:
          '${template.identity} could not be applied ($error); base runtime is in use.',
    );
  }
  return _TemplateRuntimeAssessment(template: template, applied: true);
}

List<String> _templateSettingMismatches(
  ChatController controller,
  SessionTemplateConfig template,
) {
  final mismatches = <String>[];
  void compare(String label, String? requested, String? active) {
    final expected = requested?.trim();
    if (expected == null || expected.isEmpty) return;
    if (active?.trim() != expected) mismatches.add(label);
  }

  compare(
    'mode',
    template.mode,
    controller.sessionSettings.modes.currentModeId,
  );
  compare('model', template.model, controller.currentModelValue);
  compare(
    'reasoning effort',
    template.reasoningEffort,
    controller.currentReasoningEffortValue,
  );
  return mismatches;
}

bool _sameRuntimeSemantics(
  AcpClientConfig actual,
  AcpClientConfig expected, {
  required List<String> effectiveDirectories,
}) {
  final actualAgent =
      actual.activeAgentServer?.persistenceIdentity ?? actual.agentName;
  final expectedAgent =
      expected.activeAgentServer?.persistenceIdentity ?? expected.agentName;
  return actualAgent == expectedAgent &&
      _sameStrings(
        actual.mcpServers.map((server) => server.name),
        expected.mcpServers.map((server) => server.name),
      ) &&
      _sameNormalizedPaths(
        effectiveDirectories,
        expected.additionalDirectories,
      ) &&
      jsonEncode(actual.clientProviders.toJson()) ==
          jsonEncode(expected.clientProviders.toJson()) &&
      jsonEncode(actual.assistantAgent.toJson()) ==
          jsonEncode(expected.assistantAgent.toJson());
}

bool _sameNormalizedPaths(Iterable<String> left, Iterable<String> right) {
  final leftValues = left.map(normalizeWorkspacePath).toSet();
  final rightValues = right.map(normalizeWorkspacePath).toSet();
  return leftValues.length == rightValues.length &&
      leftValues.containsAll(rightValues);
}

bool _sameStrings(Iterable<String> left, Iterable<String> right) {
  final leftValues = left.toList(growable: false);
  final rightValues = right.toList(growable: false);
  if (leftValues.length != rightValues.length) return false;
  for (var index = 0; index < leftValues.length; index += 1) {
    if (leftValues[index] != rightValues[index]) return false;
  }
  return true;
}

String _agentTransport(AgentServerConfig? server) {
  if (server == null) return 'unconfigured';
  if (server.isWebSocket) return 'WebSocket';
  if (server.isStreamableHttp) return 'Streamable HTTP';
  return 'stdio';
}

String _safeAgentTarget(AgentServerConfig? server) {
  if (server == null) return 'unconfigured';
  return server.safeDisplayTarget;
}

String _implementationLabel(Map<String, Object?> info) {
  final name = info['name'] ?? info['title'];
  final version = info['version'];
  if (name is String) {
    final safeName = _boundedInventoryText(name, maxCodeUnits: 2048).trim();
    if (safeName.isEmpty) return 'not reported';
    final safeVersion = version is String
        ? _boundedInventoryText(version, maxCodeUnits: 1024).trim()
        : '';
    return safeVersion.isNotEmpty ? '$safeName $safeVersion' : safeName;
  }
  return 'not reported';
}

String _filesystemLabel(AcpClientConfig config) {
  final fs = config.clientProviders.filesystem;
  final features = <String>[
    if (fs.readTextFile) 'read',
    if (fs.writeTextFile) 'write',
    if (fs.allowReadOutsideWorkspace) 'outside workspace',
  ];
  return features.isEmpty ? 'disabled' : features.join(', ');
}

String _permissionPolicyLabel(ChatController controller) {
  return switch (controller.toolCallExecutionPolicy) {
    AcpToolCallExecutionPolicy.defaultPermissions => 'manual confirmation',
    AcpToolCallExecutionPolicy.autoReview => 'automatic review',
    AcpToolCallExecutionPolicy.fullAccess => 'full access',
  };
}

String _reviewAgentLabel(ChatController controller, AcpClientConfig config) {
  final review = _effectiveReviewAgent(config);
  if (!review.enabled) {
    return controller.hasPermissionReviewer
        ? '${_boundedInventoryText(config.agentName)} (active-Agent fallback)'
        : 'disabled';
  }
  final target = _boundedInventoryText(review.displayTarget);
  final model = review.model;
  return '$target${model == null ? '' : ' · ${_boundedInventoryText(model)}'}';
}

AcpPermissionReviewAgentConfig _effectiveReviewAgent(AcpClientConfig config) {
  final base = config.clientProviders.permissions.reviewAgent;
  final override = config.activeAgentServer?.permissionReviewAgent;
  if (override == null || !override.isConfigured) return base;
  final hasOverrideTarget = override.hasExplicitTarget;
  return AcpPermissionReviewAgentConfig(
    enabled: override.enabled || base.enabled,
    mcpServer: hasOverrideTarget ? override.mcpServer : base.mcpServer,
    mcpServerName: hasOverrideTarget
        ? override.mcpServerName
        : base.mcpServerName,
    agentServerName: hasOverrideTarget
        ? override.agentServerName
        : base.agentServerName,
    toolName: override.toolName != 'review_permission'
        ? override.toolName
        : base.toolName,
    model: override.model ?? base.model,
    timeout: override.timeout != const Duration(seconds: 10)
        ? override.timeout
        : base.timeout,
  );
}

String _assistantLabel(AcpClientConfig config) {
  final assistant = config.assistantAgent;
  if (!assistant.isConfigured) return 'disabled';
  final agentName = _boundedInventoryText(assistant.agentName ?? '');
  final model = assistant.model;
  return '$agentName${model == null ? '' : ' · ${_boundedInventoryText(model)}'}';
}

String _agentCredentialLabel(AgentServerConfig? server) {
  if (server == null) return 'none';
  final count = server.envRefs.length + server.headerRefs.length;
  return count == 0
      ? 'none'
      : '$count reference(s) · ${server.secretRefsResolved ? 'resolved' : 'unresolved'}';
}

String _mcpCredentialLabel(List<McpServerConfig> servers) {
  var references = 0;
  var unresolved = 0;
  for (final server in servers) {
    references += server.envRefs.length + server.headerRefs.length;
    if (!server.secretRefsResolved) unresolved += 1;
  }
  if (references == 0) return 'none';
  return '$references reference(s) · '
      '${unresolved == 0 ? 'resolved' : '$unresolved server(s) unresolved'}';
}

String _reviewCredentialLabel(AcpClientConfig config) {
  final server = _effectiveReviewAgent(config).mcpServer;
  if (server == null) return 'none';
  return _mcpCredentialLabel(<McpServerConfig>[server]);
}

String _inventoryLines(
  Iterable<String> values, {
  int maxItems = 6,
  int maxLineCodeUnits = 512,
}) {
  final lines = <String>[];
  var omitted = false;
  for (final value in values) {
    if (lines.length >= maxItems) {
      omitted = true;
      break;
    }
    lines.add(_boundedInventoryText(value, maxCodeUnits: maxLineCodeUnits));
  }
  if (omitted) lines.add('… [additional items truncated]');
  return _boundedInventoryText(lines.join('\n'));
}

String _boundedInventoryText(String value, {int maxCodeUnits = 4096}) {
  if (value.length <= maxCodeUnits) return value;
  const marker = '… [truncated]';
  var end = maxCodeUnits - marker.length;
  if (end < 0) end = 0;
  if (end > 0) {
    final last = value.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end -= 1;
  }
  return '${value.substring(0, end)}$marker';
}
