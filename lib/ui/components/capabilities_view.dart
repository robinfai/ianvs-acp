import 'package:ianvs_design/ianvs_design.dart';

import '../../acp/acp_agent_capabilities.dart';
import '../../acp/acp_input_budget.dart';
import 'package:ianvs_agent_chat/ui/bounded_metadata_preview.dart';

class CapabilitiesView extends StatelessWidget {
  const CapabilitiesView({
    super.key,
    required this.capabilities,
    this.inputBudget = const AcpInputBudget(),
    this.scrollable = true,
  });
  final AcpAgentCapabilities? capabilities;
  final AcpInputBudget inputBudget;
  final bool scrollable;
  @override
  Widget build(BuildContext context) {
    final caps = capabilities;
    if (caps == null) return const _EmptyState();
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _CapabilitySummary(),
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
            _BoolRow(label: 'session/load replay', supported: caps.loadSession),
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
            _BoolRow(label: 'Delete', supported: caps.session.delete),
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
            _BoolRow(
              label: 'Boolean config options',
              supported: caps.client.booleanConfigOptions,
            ),
            _BoolRow(label: 'Plan updates', supported: caps.client.plan),
          ],
        ),
        _Section(
          icon: Icons.science_outlined,
          title: 'Experimental',
          children: [
            _BoolRow(label: 'Agent providers', supported: caps.providers),
            _BoolRow(label: 'Agent NES', supported: caps.nes),
            _BoolRow(
              label: 'Client elicitation form',
              supported: caps.client.elicitationForm,
            ),
            _BoolRow(
              label: 'Client elicitation URL',
              supported: caps.client.elicitationUrl,
            ),
            _InfoRow(
              label: 'Position encoding',
              value: caps.positionEncoding ?? 'not negotiated',
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
        if (caps.rawAgentCapabilities.isNotEmpty)
          _RawSection(capabilities: caps, inputBudget: inputBudget),
      ],
    );
    return scrollable ? SingleChildScrollView(child: content) : content;
  }
}

class _CapabilitySummary extends StatelessWidget {
  const _CapabilitySummary();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.ianvs.accent.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(context.ianvs.panelRadius),
        border: Border.all(color: context.ianvs.separator),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.dashboard_customize_outlined,
                size: 15,
                color: context.ianvs.focus,
              ),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Negotiated capability status',
                  style: TextStyle(
                    color: context.ianvs.text,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            'The statuses below reflect the capabilities available after runtime and Agent negotiation.',
            style: TextStyle(
              color: context.ianvs.muted,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 150,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.ianvs.raised,
        borderRadius: BorderRadius.circular(context.ianvs.panelRadius),
        border: Border.all(color: context.ianvs.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.info_outline_rounded, color: context.ianvs.focus),
          SizedBox(height: 8),
          Text(
            'Connect to an ACP agent to inspect capabilities.',
            style: TextStyle(color: context.ianvs.muted),
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
      padding: const EdgeInsets.fromLTRB(2, 12, 2, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.ianvs.separator)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: context.ianvs.focus),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  color: context.ianvs.text,
                  fontWeight: FontWeight.w600,
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
      color: supported ? context.ianvs.success : context.ianvs.subtle,
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return _Pill(label: label, value: value, color: context.ianvs.focus);
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
        color: context.ianvs.canvas,
        borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
        border: Border.all(color: context.ianvs.separator),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.ianvs.text,
                fontSize: 11,
                fontWeight: FontWeight.w600,
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
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RawSection extends StatefulWidget {
  const _RawSection({required this.capabilities, required this.inputBudget});

  final AcpAgentCapabilities capabilities;
  final AcpInputBudget inputBudget;

  @override
  State<_RawSection> createState() => _RawSectionState();
}

class _RawSectionState extends State<_RawSection> {
  final Map<_RawBlockKind, _RawPreviewCacheEntry> _previewCache = {};
  var _expanded = false;

  @override
  void didUpdateWidget(covariant _RawSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.inputBudget, oldWidget.inputBudget)) {
      _previewCache.clear();
      return;
    }
    _invalidateChangedInput(
      _RawBlockKind.agentCapabilities,
      oldWidget.capabilities.rawAgentCapabilities,
      widget.capabilities.rawAgentCapabilities,
    );
    _invalidateChangedInput(
      _RawBlockKind.agentInfo,
      oldWidget.capabilities.agentInfo,
      widget.capabilities.agentInfo,
    );
    _invalidateChangedInput(
      _RawBlockKind.clientInfo,
      oldWidget.capabilities.clientInfo,
      widget.capabilities.clientInfo,
    );
    _invalidateChangedInput(
      _RawBlockKind.authMethods,
      oldWidget.capabilities.authMethods,
      widget.capabilities.authMethods,
    );
  }

  void _invalidateChangedInput(
    _RawBlockKind kind,
    Object? previous,
    Object? current,
  ) {
    if (!identical(previous, current)) {
      _previewCache.remove(kind);
    }
  }

  BoundedMetadataPreview _previewFor(_RawBlockKind kind, Object? value) {
    final cached = _previewCache[kind];
    if (cached != null &&
        identical(cached.value, value) &&
        identical(cached.inputBudget, widget.inputBudget)) {
      return cached.preview;
    }
    final preview = writeBoundedMetadataPreview(
      value,
      budget: widget.inputBudget,
    );
    _previewCache[kind] = _RawPreviewCacheEntry(
      value: value,
      inputBudget: widget.inputBudget,
      preview: preview,
    );
    return preview;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
        onExpansionChanged: (expanded) {
          setState(() {
            _expanded = expanded;
          });
        },
        title: Text(
          'Raw capability data',
          style: TextStyle(
            color: context.ianvs.text,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: const Icon(Icons.data_object_rounded),
        children: _expanded
            ? [
                _RawBlock(
                  label: 'agentCapabilities',
                  preview: _previewFor(
                    _RawBlockKind.agentCapabilities,
                    widget.capabilities.rawAgentCapabilities,
                  ),
                ),
                if (widget.capabilities.agentInfo.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _RawBlock(
                    label: 'agentInfo',
                    preview: _previewFor(
                      _RawBlockKind.agentInfo,
                      widget.capabilities.agentInfo,
                    ),
                  ),
                ],
                if (widget.capabilities.clientInfo.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _RawBlock(
                    label: 'clientInfo',
                    preview: _previewFor(
                      _RawBlockKind.clientInfo,
                      widget.capabilities.clientInfo,
                    ),
                  ),
                ],
                if (widget.capabilities.authMethods.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _RawBlock(
                    label: 'authMethods',
                    preview: _previewFor(
                      _RawBlockKind.authMethods,
                      widget.capabilities.authMethods,
                    ),
                  ),
                ],
              ]
            : const <Widget>[],
      ),
    );
  }
}

enum _RawBlockKind { agentCapabilities, agentInfo, clientInfo, authMethods }

final class _RawPreviewCacheEntry {
  const _RawPreviewCacheEntry({
    required this.value,
    required this.inputBudget,
    required this.preview,
  });

  final Object? value;
  final AcpInputBudget inputBudget;
  final BoundedMetadataPreview preview;
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
  const _RawBlock({required this.label, required this.preview});

  final String label;
  final BoundedMetadataPreview preview;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: context.ianvs.raised,
        borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
        border: Border.all(color: context.ianvs.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: context.ianvs.focus,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            preview.text,
            style: TextStyle(
              color: context.ianvs.muted,
              fontFamily: context.ianvsTypography.code.fontFamily,
              fontFamilyFallback:
                  context.ianvsTypography.code.fontFamilyFallback,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          if (preview.omission case final omission?) ...[
            const SizedBox(height: 6),
            Text(
              omission.truncated
                  ? 'Preview truncated · ${omission.resource}'
                  : 'Details omitted · ${omission.resource}',
              style: TextStyle(
                color: context.ianvs.warning,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
