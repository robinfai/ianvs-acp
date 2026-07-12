import 'package:flutter/material.dart';

import '../../acp/acp_agent_capabilities.dart';
import '../../config/acp_client_config.dart';
import '../../state/chat_controller.dart';
import '../theme/app_design_tokens.dart';

class ProtocolFeatureReviewDialog extends StatelessWidget {
  const ProtocolFeatureReviewDialog({
    super.key,
    required this.controller,
    this.agentServers = const <AgentServerConfig>[],
    this.mcpServers = const <McpServerConfig>[],
    this.additionalDirectories = const <String>[],
    this.clientProviders = const AcpClientProviderConfig(),
    this.configPath,
  });

  final ChatController controller;
  final List<AgentServerConfig> agentServers;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final String? configPath;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final features = _features(controller);
        return AlertDialog(
          title: const Text('Protocol Coverage'),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.72,
            ),
            child: SizedBox(
              width: 780,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Overview(
                      connected: controller.capabilities != null,
                      implementedCount: features
                          .where((feature) => feature.status.isImplemented)
                          .length,
                      totalCount: features.length,
                      configPath: configPath,
                    ),
                    const SizedBox(height: 10),
                    for (final feature in features) ...[
                      _FeaturePanel(feature: feature),
                      if (feature != features.last) const SizedBox(height: 8),
                    ],
                  ],
                ),
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
      },
    );
  }

  List<_ProtocolFeature> _features(ChatController controller) {
    final caps = controller.capabilities;
    final settings = controller.sessionSettings;
    final hasConfiguredRemoteAgent = agentServers.any(
      (server) => server.isWebSocket || server.isStreamableHttp,
    );
    final hasConfiguredStdioAgent =
        agentServers.isEmpty || agentServers.any((server) => server.isStdio);
    final hasPromptAttachments =
        caps?.prompt.image == true ||
        caps?.prompt.audio == true ||
        caps?.prompt.embeddedContext == true;
    final fs = clientProviders.filesystem;
    final terminal = clientProviders.terminal;
    final permissions = clientProviders.permissions;

    return [
      _ProtocolFeature(
        icon: Icons.cable_rounded,
        title: 'Transport',
        status: hasConfiguredRemoteAgent
            ? _FeatureStatus.partial
            : _FeatureStatus.done,
        reference: 'protocol/v1/transports',
        implementation: [
          if (hasConfiguredStdioAgent) 'stdio subprocess transport',
          if (hasConfiguredRemoteAgent)
            'WebSocket and draft Streamable HTTP/SSE transport config',
        ],
        gui: [
          'Agent Configuration shows command, URL, headers, cwd, args, env',
          'Agents menu switches configured servers',
        ],
        gap: hasConfiguredRemoteAgent
            ? 'Remote hardening still needs real-agent validation and HTTP/2 policy.'
            : 'Remote agents are available when configured in settings.json.',
      ),
      _ProtocolFeature(
        icon: Icons.handshake_outlined,
        title: 'Initialization',
        status: _FeatureStatus.done,
        reference: 'protocol/v1/initialization',
        implementation: [
          'initialize sends protocolVersion, clientCapabilities, clientInfo',
          'agentInfo, authMethods, and agentCapabilities are parsed',
        ],
        gui: [
          'ACP Compatibility shows negotiated protocol, agent, client, capabilities',
        ],
        runtime: _capabilityRuntime(caps),
      ),
      _ProtocolFeature(
        icon: Icons.key_outlined,
        title: 'Authentication / Logout',
        status: _FeatureStatus.done,
        reference: 'protocol/v1/authentication',
        implementation: [
          'authenticate(methodId) and logout() are capability-gated',
          'auth_required errors surface an Authenticate action',
        ],
        gui: [
          'Agents menu shows Authenticate and Log Out when advertised',
          'Logout confirms before clearing local session state',
        ],
        runtime: [
          _runtimeFlag('authMethods', controller.authMethods.isNotEmpty),
          _runtimeFlag('auth.logout', caps?.auth.logout == true),
        ],
      ),
      _ProtocolFeature(
        icon: Icons.create_new_folder_outlined,
        title: 'Session Setup / Load / Resume',
        status: _FeatureStatus.done,
        reference: 'protocol/v1/session-setup',
        implementation: [
          'session/new, session/load fallback, session/resume fallback',
          'additionalDirectories forwarded only when advertised',
        ],
        gui: [
          'New Session dialog collects agent and cwd',
          'Resume dialog loads listed sessions',
        ],
        runtime: [
          _runtimeFlag('session/load', caps?.loadSession == true),
          _runtimeFlag('session.resume', caps?.session.resume == true),
          _runtimeFlag(
            'additionalDirectories',
            caps?.session.additionalDirectories == true,
          ),
          _runtimeFlag(
            'configured extra roots',
            additionalDirectories.isNotEmpty,
          ),
        ],
      ),
      _ProtocolFeature(
        icon: Icons.history_rounded,
        title: 'Session List / Metadata',
        status: _FeatureStatus.done,
        reference: 'protocol/v1/session-list',
        implementation: [
          'session/list pagination is grouped by project',
          'session_info_update updates title and time without timeline noise',
        ],
        gui: [
          'Resume dialog supports project and conversation search',
          'Sidebar uses session title, agent, cwd, and update time',
        ],
        runtime: [_runtimeFlag('session.list', caps?.session.list == true)],
      ),
      _ProtocolFeature(
        icon: Icons.inventory_2_outlined,
        title: 'Session Lifecycle',
        status: _FeatureStatus.done,
        reference: 'protocol/v1/session-delete',
        implementation: [
          'session/close releases active resources without deleting history',
          'session/delete permanently removes advertised persisted sessions',
          'session/fork remains available for agents implementing the current RFD',
        ],
        gui: [
          'Session Settings exposes capability-gated Fork, Close, and Delete actions',
        ],
        runtime: [
          _runtimeFlag('session.close', caps?.session.close == true),
          _runtimeFlag('session.delete', caps?.session.delete == true),
          _runtimeFlag('session.fork', caps?.session.fork == true),
        ],
      ),
      _ProtocolFeature(
        icon: Icons.forum_outlined,
        title: 'Prompt Turn',
        status: _FeatureStatus.done,
        reference: 'protocol/v1/prompt-turn',
        implementation: [
          'session/prompt streaming, stop/cancel, turn status',
          'end-turn token usage and request cancellation metadata are retained',
          'user echo suppression and latency tracking',
        ],
        gui: [
          'Prompt composer sends, stops, and keeps draft during session operations',
          'Timeline streams assistant text, status, tool calls, and errors',
        ],
      ),
      _ProtocolFeature(
        icon: Icons.attachment_outlined,
        title: 'Content Blocks',
        status: _FeatureStatus.mostlyDone,
        reference: 'protocol/v1/content',
        implementation: [
          'text, image, audio, resource, blob resource, resource_link',
          'prompt attachments are gated by image/audio/embeddedContext',
        ],
        gui: [
          'Attachment chips show Image, Audio, Embed, or Link send mode',
          'Timeline renders content cards and unknown content fallbacks',
        ],
        runtime: [
          _runtimeFlag('image', caps?.prompt.image == true),
          _runtimeFlag('audio', caps?.prompt.audio == true),
          _runtimeFlag('embeddedContext', caps?.prompt.embeddedContext == true),
          if (!hasPromptAttachments) 'Connect to inspect prompt gates',
        ],
      ),
      _ProtocolFeature(
        icon: Icons.construction_rounded,
        title: 'Tool Calls / Permissions',
        status: _FeatureStatus.done,
        reference: 'protocol/v1/tool-calls',
        implementation: [
          'tool call grouping, status coalescing, raw call metadata',
          'session/request_permission with manual, trust-rule, review, and policy decisions',
        ],
        gui: [
          'Timeline groups tool calls',
          'Prompt composer shows Allow Once, Deny, Cancel and execution policy',
          'Agents menu opens Permission History with JSON export',
        ],
        runtime: [
          _runtimeFlag('trust rules', permissions.hasTrustRules),
          _runtimeFlag('review agent', permissions.hasReviewAgent),
          _runtimeFlag(
            'history entries',
            controller.permissionHistory.isNotEmpty,
          ),
        ],
        gap:
            'Long-term audit retention and trust-rule management remain product decisions.',
      ),
      _ProtocolFeature(
        icon: Icons.folder_copy_outlined,
        title: 'File System Provider',
        status: fs.enabled ? _FeatureStatus.done : _FeatureStatus.configOnly,
        reference: 'protocol/v1/file-system',
        implementation: [
          'fs/read_text_file and fs/write_text_file are off by default',
          'workspace jail includes cwd and advertised additional directories',
        ],
        gui: [
          'Agent Configuration shows FS read/write and outside-workspace policy',
          'ACP Compatibility shows advertised client fs capabilities',
        ],
        runtime: [
          _runtimeFlag('configured read', fs.readTextFile),
          _runtimeFlag('configured write', fs.writeTextFile),
          _runtimeFlag('allow outside read', fs.allowReadOutsideWorkspace),
          _runtimeFlag('advertised read', caps?.client.fsReadTextFile == true),
          _runtimeFlag(
            'advertised write',
            caps?.client.fsWriteTextFile == true,
          ),
        ],
      ),
      _ProtocolFeature(
        icon: Icons.terminal_rounded,
        title: 'Terminal Provider',
        status: terminal.enabled
            ? _FeatureStatus.partial
            : _FeatureStatus.configOnly,
        reference: 'protocol/v1/terminals',
        implementation: [
          'terminal/create/output/wait/kill/release via configured provider',
          'terminal lifecycle and output snapshots merge in timeline',
        ],
        gui: [
          'Agent Configuration and ACP Compatibility expose terminal enablement',
          'Timeline renders terminal status/output snapshots',
        ],
        runtime: [
          _runtimeFlag('configured terminal', terminal.enabled),
          _runtimeFlag('advertised terminal', caps?.client.terminal == true),
        ],
        gap: 'A persistent live terminal panel is still a follow-up.',
      ),
      _ProtocolFeature(
        icon: Icons.checklist_rounded,
        title: 'Agent Plan',
        status: _FeatureStatus.done,
        reference: 'protocol/v1/agent-plan',
        implementation: [
          'agent plan updates replace the complete current plan snapshot',
        ],
        gui: ['Timeline renders structured plan status cards'],
      ),
      _ProtocolFeature(
        icon: Icons.tune_rounded,
        title: 'Session Config Options',
        status: _FeatureStatus.done,
        reference: 'protocol/v1/session-config-options',
        implementation: [
          'session/set_config_option and config_option_update use complete-state semantics',
          'select and boolean controls are supported; unknown types are ignored/read-only',
        ],
        gui: [
          'Session Settings renders config controls',
          'Prompt composer mirrors model and reasoning effort selectors',
          'Status bar displays active model-like state',
        ],
        runtime: [
          _runtimeFlag(
            'configOptions capability',
            caps?.session.configOptions == true,
          ),
          _runtimeFlag('active config options', settings.hasConfigOptions),
          _runtimeFlag('model option', settings.modelOption != null),
          _runtimeFlag(
            'reasoning option',
            settings.reasoningEffortOption != null,
          ),
        ],
      ),
      _ProtocolFeature(
        icon: Icons.swap_horiz_rounded,
        title: 'Session Modes',
        status: _FeatureStatus.done,
        reference: 'protocol/v1/session-modes',
        implementation: [
          'legacy modes are used only when configOptions are absent',
        ],
        gui: ['Session Settings shows a fallback Mode selector'],
        runtime: [
          _runtimeFlag(
            'legacy modes visible',
            settings.shouldUseLegacyModes && settings.hasModes,
          ),
        ],
      ),
      _ProtocolFeature(
        icon: Icons.flash_on_rounded,
        title: 'Slash Commands',
        status: _FeatureStatus.done,
        reference: 'protocol/v1/slash-commands',
        implementation: [
          'available_commands_update replaces the current command snapshot',
        ],
        gui: ['Prompt input suggests advertised commands while typing /'],
        runtime: [
          _runtimeFlag(
            'commands advertised',
            controller.availableCommands.isNotEmpty,
          ),
        ],
      ),
      _ProtocolFeature(
        icon: Icons.extension_rounded,
        title: 'Extensibility / _meta',
        status: _FeatureStatus.mostlyDone,
        reference: 'protocol/v1/extensibility',
        implementation: [
          'raw _meta capability data is retained',
          'underscore-prefixed custom JSON-RPC requests can be sent manually',
        ],
        gui: [
          'ACP Compatibility shows raw capability data',
          'Agents menu opens Extension Request',
        ],
        runtime: [
          _runtimeFlag(
            'extension meta',
            caps?.extensionMeta.isNotEmpty == true,
          ),
        ],
        gap:
            'Vendor-specific extension workflows wait for concrete _meta contracts.',
      ),
      _ProtocolFeature(
        icon: Icons.science_outlined,
        title: 'ACP 1.2 Experimental Surfaces',
        status: _FeatureStatus.done,
        reference: 'rfds/updates',
        implementation: [
          'provider list/set/disable requests have named client APIs',
          'NES lifecycle, document notifications, and accept/reject are exposed',
          'elicitation and MCP-over-ACP agent callbacks are provider-driven',
          r'$/cancel_request and arbitrary JSON result requests are supported',
        ],
        gui: [
          'ACP Compatibility reports negotiated providers, NES, elicitation, and position encoding capabilities',
        ],
        runtime: [
          _runtimeFlag('agent providers', caps?.providers == true),
          _runtimeFlag('agent NES', caps?.nes == true),
          _runtimeFlag(
            'client boolean config',
            caps?.client.booleanConfigOptions == true,
          ),
        ],
      ),
      _ProtocolFeature(
        icon: Icons.hub_outlined,
        title: 'MCP Servers',
        status: _FeatureStatus.done,
        reference: 'protocol/v1/session-setup#mcp-servers',
        implementation: [
          'stdio, http, sse, and acp MCP entries validate from settings.json',
          'remote MCP entries are forwarded only when agent capabilities allow them',
        ],
        gui: [
          'Agent Configuration lists MCP names, transport type, command/url/serverId, headers',
          'ACP Compatibility shows negotiated MCP transport capabilities',
        ],
        runtime: [
          _runtimeFlag('configured MCP servers', mcpServers.isNotEmpty),
          _runtimeFlag('mcp.http', caps?.mcp.http == true),
          _runtimeFlag('mcp.sse', caps?.mcp.sse == true),
          _runtimeFlag('mcp.acp', caps?.mcp.acp == true),
        ],
      ),
      _ProtocolFeature(
        icon: Icons.travel_explore_rounded,
        title: 'ACP Registry',
        status: _FeatureStatus.followUp,
        reference: 'get-started/registry',
        implementation: [
          'Official registry is now stable, but this client still uses explicit settings.json agent servers',
        ],
        gui: ['Agent Configuration makes explicit local config inspectable'],
        gap:
            'Registry browsing, import, install, and cache strategy are not implemented yet.',
      ),
    ];
  }
}

class _Overview extends StatelessWidget {
  const _Overview({
    required this.connected,
    required this.implementedCount,
    required this.totalCount,
    required this.configPath,
  });

  final bool connected;
  final int implementedCount;
  final int totalCount;
  final String? configPath;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.primaryMist,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.primarySoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusPill(
                label: connected ? 'Connected' : 'Not connected',
                color: connected ? AppColors.success : AppColors.textTertiary,
              ),
              _StatusPill(
                label:
                    '$implementedCount/$totalCount implemented or mostly done',
                color: AppColors.primaryDark,
              ),
              const _StatusPill(
                label: 'ACP v1 official surface',
                color: AppColors.primaryDark,
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            configPath == null || configPath!.isEmpty
                ? 'Config path not resolved'
                : configPath!,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeaturePanel extends StatelessWidget {
  const _FeaturePanel({required this.feature});

  final _ProtocolFeature feature;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(feature.icon, size: 17, color: feature.status.color),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  feature.title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _StatusPill(
                label: feature.status.label,
                color: feature.status.color,
              ),
            ],
          ),
          const SizedBox(height: 8),
          _DetailLine(label: 'Official', values: [feature.reference]),
          _DetailLine(label: 'Implemented', values: feature.implementation),
          _DetailLine(label: 'GUI', values: feature.gui),
          if (feature.runtime.isNotEmpty)
            _DetailLine(label: 'Runtime', values: feature.runtime),
          if (feature.gap != null && feature.gap!.isNotEmpty)
            _DetailLine(label: 'Gap', values: [feature.gap!]),
        ],
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.values});

  final String label;
  final List<String> values;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 5,
              children: [for (final value in values) _TinyChip(value: value)],
            ),
          ),
        ],
      ),
    );
  }
}

class _TinyChip extends StatelessWidget {
  const _TinyChip({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Text(
        value,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _ProtocolFeature {
  const _ProtocolFeature({
    required this.icon,
    required this.title,
    required this.status,
    required this.reference,
    required this.implementation,
    required this.gui,
    this.runtime = const <String>[],
    this.gap,
  });

  final IconData icon;
  final String title;
  final _FeatureStatus status;
  final String reference;
  final List<String> implementation;
  final List<String> gui;
  final List<String> runtime;
  final String? gap;
}

enum _FeatureStatus {
  done('Done', AppColors.success, true),
  mostlyDone('Mostly done', AppColors.success, true),
  partial('Partial', AppColors.warning, false),
  configOnly('Config-only', AppColors.primaryDark, true),
  followUp('Follow-up', AppColors.textTertiary, false);

  const _FeatureStatus(this.label, this.color, this.isImplemented);

  final String label;
  final Color color;
  final bool isImplemented;
}

List<String> _capabilityRuntime(AcpAgentCapabilities? caps) {
  if (caps == null) return const ['Connect to inspect negotiated capabilities'];
  return [
    'protocolVersion ${caps.protocolVersion}',
    if (caps.agentInfo.isNotEmpty)
      _implementationInfo('agentInfo', caps.agentInfo),
    if (caps.clientInfo.isNotEmpty)
      _implementationInfo('clientInfo', caps.clientInfo),
  ];
}

String _implementationInfo(String label, Map<String, Object?> info) {
  final name = info['title'] ?? info['name'];
  final version = info['version'];
  final nameText = name is String && name.trim().isNotEmpty
      ? name.trim()
      : 'unknown';
  final versionText = version is String && version.trim().isNotEmpty
      ? ' ${version.trim()}'
      : '';
  return '$label $nameText$versionText';
}

String _runtimeFlag(String label, bool value) {
  return '$label ${value ? 'on' : 'off'}';
}
