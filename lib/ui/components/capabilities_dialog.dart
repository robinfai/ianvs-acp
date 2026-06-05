import 'dart:convert';

import 'package:flutter/material.dart';

import '../../acp/acp_agent_capabilities.dart';
import '../theme/app_design_tokens.dart';

class CapabilitiesDialog extends StatelessWidget {
  const CapabilitiesDialog({super.key, required this.capabilities});

  final AcpAgentCapabilities? capabilities;

  @override
  Widget build(BuildContext context) {
    final caps = capabilities;
    return AlertDialog(
      title: const Text('ACP Compatibility'),
      content: SizedBox(
        width: 680,
        child: caps == null
            ? const _EmptyState()
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CapabilitySummary(capabilities: caps),
                    _Section(
                      icon: Icons.handshake_outlined,
                      title: 'Protocol',
                      children: [
                        _InfoRow(
                          label: 'Protocol version',
                          value: caps.protocolVersion.toString(),
                        ),
                        if (caps.clientInfo.isNotEmpty)
                          _InfoRow(
                            label: 'Client',
                            value: _implementationLabel(caps.clientInfo),
                          ),
                        if (caps.agentInfo.isNotEmpty)
                          _InfoRow(
                            label: 'Agent',
                            value: _implementationLabel(caps.agentInfo),
                          ),
                        _BoolRow(
                          label: 'session/load replay',
                          supported: caps.loadSession,
                        ),
                      ],
                    ),
                    _Section(
                      icon: Icons.chat_bubble_outline_rounded,
                      title: 'Prompt',
                      children: [
                        _BoolRow(label: 'Image', supported: caps.prompt.image),
                        _BoolRow(label: 'Audio', supported: caps.prompt.audio),
                        _BoolRow(
                          label: 'Embedded context',
                          supported: caps.prompt.embeddedContext,
                        ),
                      ],
                    ),
                    _Section(
                      icon: Icons.folder_copy_outlined,
                      title: 'Sessions',
                      children: [
                        _BoolRow(label: 'List', supported: caps.session.list),
                        _BoolRow(
                          label: 'Resume without history',
                          supported: caps.session.resume,
                        ),
                        _BoolRow(label: 'Fork', supported: caps.session.fork),
                        _BoolRow(
                          label: 'Config options',
                          supported: caps.session.configOptions,
                        ),
                        _BoolRow(
                          label: 'Additional directories',
                          supported: caps.session.additionalDirectories,
                        ),
                        _BoolRow(label: 'Close', supported: caps.session.close),
                        if (caps.session.rawKeys.isNotEmpty)
                          _InfoRow(
                            label: 'Raw keys',
                            value: caps.session.rawKeys.join(', '),
                          ),
                      ],
                    ),
                    _Section(
                      icon: Icons.hub_outlined,
                      title: 'MCP',
                      children: [
                        _BoolRow(label: 'HTTP', supported: caps.mcp.http),
                        _BoolRow(label: 'SSE', supported: caps.mcp.sse),
                        _BoolRow(label: 'ACP', supported: caps.mcp.acp),
                      ],
                    ),
                    _Section(
                      icon: Icons.desktop_mac_outlined,
                      title: 'Client',
                      children: [
                        _BoolRow(
                          label: 'Advertise fs/read_text_file',
                          supported: caps.client.fsReadTextFile,
                        ),
                        _BoolRow(
                          label: 'Advertise fs/write_text_file',
                          supported: caps.client.fsWriteTextFile,
                        ),
                        _BoolRow(
                          label: 'FS provider wired',
                          supported: caps.client.hasFsProvider,
                        ),
                        _BoolRow(
                          label: 'Terminal advertised',
                          supported: caps.client.terminal,
                        ),
                        _BoolRow(
                          label: 'Terminal provider wired',
                          supported: caps.client.hasTerminalProvider,
                        ),
                        _BoolRow(
                          label: 'Read outside workspace',
                          supported: caps.client.allowReadOutsideWorkspace,
                        ),
                      ],
                    ),
                    _Section(
                      icon: Icons.key_outlined,
                      title: 'Auth',
                      children: [
                        _BoolRow(label: 'Logout', supported: caps.auth.logout),
                        _InfoRow(
                          label: 'Auth methods',
                          value: caps.authMethods.isEmpty
                              ? 'none'
                              : caps.authMethods.length.toString(),
                        ),
                      ],
                    ),
                    if (caps.extensionMeta.isNotEmpty ||
                        caps.rawAgentCapabilities.isNotEmpty)
                      _RawSection(capabilities: caps),
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

class _CapabilitySummary extends StatelessWidget {
  const _CapabilitySummary({required this.capabilities});

  final AcpAgentCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final items = _summaryItems(capabilities);
    final readyItems = items.where((item) => item.supported).toList();
    final attentionItems = items.where((item) => !item.supported).toList();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.primaryMist,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.dashboard_customize_outlined,
                size: 15,
                color: AppColors.primaryDark,
              ),
              SizedBox(width: 6),
              Text(
                'Capability summary',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth < 520
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 8) / 2;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: width,
                    child: _SummaryPanel(
                      title: 'Ready now',
                      icon: Icons.check_circle_outline_rounded,
                      color: AppColors.success,
                      items: readyItems,
                      emptyLabel: 'No advertised capability yet',
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _SummaryPanel(
                      title: 'Needs attention',
                      icon: Icons.info_outline_rounded,
                      color: AppColors.warning,
                      items: attentionItems,
                      emptyLabel: 'No obvious gaps',
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  List<_SummaryItem> _summaryItems(AcpAgentCapabilities caps) {
    return [
      _SummaryItem('Load session', caps.loadSession),
      _SummaryItem('Image input', caps.prompt.image),
      _SummaryItem('Audio input', caps.prompt.audio),
      _SummaryItem('Embedded prompt context', caps.prompt.embeddedContext),
      _SummaryItem('Session list', caps.session.list),
      _SummaryItem('Resume session', caps.session.resume),
      _SummaryItem('Session fork', caps.session.fork),
      _SummaryItem('Session config options', caps.session.configOptions),
      _SummaryItem('Extra directories', caps.session.additionalDirectories),
      _SummaryItem('Session close', caps.session.close),
      _SummaryItem('HTTP MCP', caps.mcp.http),
      _SummaryItem('SSE MCP', caps.mcp.sse),
      _SummaryItem('ACP MCP', caps.mcp.acp),
      _SummaryItem('Auth logout', caps.auth.logout),
      _SummaryItem(
        'Client fs read',
        caps.client.fsReadTextFile && caps.client.hasFsProvider,
      ),
      _SummaryItem(
        'Client fs write',
        caps.client.fsWriteTextFile && caps.client.hasFsProvider,
      ),
      _SummaryItem(
        'Terminal',
        caps.client.terminal && caps.client.hasTerminalProvider,
      ),
    ];
  }
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({
    required this.title,
    required this.icon,
    required this.color,
    required this.items,
    required this.emptyLabel,
  });

  final String title;
  final IconData icon;
  final Color color;
  final List<_SummaryItem> items;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final labels = items.isEmpty
        ? [emptyLabel]
        : items.map((item) => item.label).toList(growable: false);
    return Container(
      constraints: const BoxConstraints(minHeight: 78),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 5),
              Text(
                title,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final label in labels)
                _SummaryChip(label: label, color: color),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _SummaryItem {
  const _SummaryItem(this.label, this.supported);

  final String label;
  final bool supported;
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 150,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.info_outline_rounded, color: AppColors.primaryDark),
          SizedBox(height: 8),
          Text(
            'Connect to an ACP agent to inspect capabilities.',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
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
              Icon(icon, size: 15, color: AppColors.primaryDark),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 7, runSpacing: 7, children: children),
        ],
      ),
    );
  }
}

class _BoolRow extends StatelessWidget {
  const _BoolRow({required this.label, required this.supported});

  final String label;
  final bool supported;

  @override
  Widget build(BuildContext context) {
    return _Pill(
      label: label,
      value: supported ? 'supported' : 'off',
      color: supported ? AppColors.success : AppColors.textTertiary,
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return _Pill(label: label, value: value, color: AppColors.primaryDark);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RawSection extends StatelessWidget {
  const _RawSection({required this.capabilities});

  final AcpAgentCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
        title: const Text(
          'Raw capability data',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
        leading: const Icon(Icons.data_object_rounded),
        children: [
          _RawBlock(
            label: 'agentCapabilities',
            value: capabilities.rawAgentCapabilities,
          ),
          if (capabilities.agentInfo.isNotEmpty) ...[
            const SizedBox(height: 6),
            _RawBlock(label: 'agentInfo', value: capabilities.agentInfo),
          ],
          if (capabilities.clientInfo.isNotEmpty) ...[
            const SizedBox(height: 6),
            _RawBlock(label: 'clientInfo', value: capabilities.clientInfo),
          ],
          if (capabilities.authMethods.isNotEmpty) ...[
            const SizedBox(height: 6),
            _RawBlock(label: 'authMethods', value: capabilities.authMethods),
          ],
        ],
      ),
    );
  }
}

String _implementationLabel(Map<String, Object?> info) {
  final name = info['name'];
  final version = info['version'];
  final label = name is String && name.trim().isNotEmpty
      ? name.trim()
      : 'Unknown';
  if (version is String && version.trim().isNotEmpty) {
    return '$label ${version.trim()}';
  }
  return label;
}

class _RawBlock extends StatelessWidget {
  const _RawBlock({required this.label, required this.value});

  final String label;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    const encoder = JsonEncoder.withIndent('  ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.primaryDark,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            encoder.convert(value),
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}
