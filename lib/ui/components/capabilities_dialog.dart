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
        width: 760,
        child: caps == null
            ? const _EmptyState()
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Section(
                      icon: Icons.handshake_outlined,
                      title: 'Protocol',
                      children: [
                        _InfoRow(
                          label: 'Protocol version',
                          value: caps.protocolVersion.toString(),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 220,
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
          SizedBox(height: 10),
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
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
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
              Icon(icon, size: 17, color: AppColors.primaryDark),
              const SizedBox(width: 8),
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
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, children: children),
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
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
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
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
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
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
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
          if (capabilities.authMethods.isNotEmpty) ...[
            const SizedBox(height: 10),
            _RawBlock(label: 'authMethods', value: capabilities.authMethods),
          ],
        ],
      ),
    );
  }
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
      padding: const EdgeInsets.all(12),
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
          const SizedBox(height: 8),
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
