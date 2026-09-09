import 'dart:io';

import 'package:flutter/material.dart';

import '../../config/acp_client_config.dart';
import '../../config/assistant_agent_config.dart';
import 'package:ianvs_agent_chat/ui/theme/app_design_tokens.dart';

class NewSessionSelection {
  const NewSessionSelection({
    required this.cwd,
    this.agentServer,
    this.sessionTemplate,
  });

  final String cwd;
  final AgentServerConfig? agentServer;
  final SessionTemplateConfig? sessionTemplate;
}

class NewSessionAgentDialog extends StatefulWidget {
  const NewSessionAgentDialog({
    super.key,
    required this.agentServers,
    required this.currentAgentName,
    this.sessionTemplates = const <SessionTemplateConfig>[],
    this.defaultSessionTemplateId,
    this.initialCwd = '',
    this.baseConfig,
  });

  final List<AgentServerConfig> agentServers;
  final String currentAgentName;
  final List<SessionTemplateConfig> sessionTemplates;
  final String? defaultSessionTemplateId;
  final String initialCwd;
  final AcpClientConfig? baseConfig;

  @override
  State<NewSessionAgentDialog> createState() => _NewSessionAgentDialogState();
}

class _NewSessionAgentDialogState extends State<NewSessionAgentDialog> {
  AgentServerConfig? _selectedServer;
  SessionTemplateConfig? _selectedTemplate;
  late String _cwd;
  late final TextEditingController _cwdController;
  String? _cwdError;

  @override
  void initState() {
    super.initState();
    _selectedServer = _initialSelectedServer();
    _selectedTemplate = _initialSelectedTemplate();
    _cwd = widget.initialCwd.trim();
    _cwdController = TextEditingController(text: _cwd);
  }

  @override
  void dispose() {
    _cwdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Session'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SessionScopeNotice(),
              const SizedBox(height: 16),
              if (widget.sessionTemplates.isNotEmpty) ...[
                const _ChoiceSectionLabel('Session template'),
                const SizedBox(height: 8),
                for (final template in widget.sessionTemplates) ...[
                  _TemplateChoiceTile(
                    template: template,
                    selected: template.id == _selectedTemplate?.id,
                    onTap: () => setState(() => _selectedTemplate = template),
                  ),
                  const SizedBox(height: 8),
                ],
                _CustomSessionChoiceTile(
                  selected: _selectedTemplate == null,
                  onTap: () => setState(() => _selectedTemplate = null),
                ),
                if (_selectedTemplate != null) ...[
                  const SizedBox(height: 10),
                  _TemplateSummary(
                    template: _selectedTemplate!,
                    baseConfig: widget.baseConfig,
                    currentAgentName: widget.currentAgentName,
                  ),
                ],
                const SizedBox(height: 18),
              ],
              if (_selectedTemplate == null &&
                  widget.agentServers.isNotEmpty) ...[
                const _ChoiceSectionLabel('Agent for this session'),
                const SizedBox(height: 8),
                for (final server in widget.agentServers) ...[
                  _AgentChoiceTile(
                    server: server,
                    selected: server.name == _selectedServer?.name,
                    isCurrent: server.name == widget.currentAgentName,
                    isStartupDefault: server.name == _startupDefaultAgentName(),
                    onTap: () => setState(() => _selectedServer = server),
                  ),
                  if (server != widget.agentServers.last)
                    const SizedBox(height: 8),
                ],
                const SizedBox(height: 12),
              ],
              _PathAutocompleteField(
                controller: _cwdController,
                suggestions: newSessionPathSuggestions(
                  _cwd,
                ).toList(growable: false),
                errorText: _cwdError,
                onChanged: _handleCwdChanged,
                onSelected: _handleCwdSelected,
                onSubmitted: _submit,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _cwd.trim().isEmpty ? null : _submit,
          child: const Text('Start'),
        ),
      ],
    );
  }

  AgentServerConfig? _initialSelectedServer() {
    for (final server in widget.agentServers) {
      if (server.name == widget.currentAgentName) return server;
    }
    return widget.agentServers.isEmpty ? null : widget.agentServers.first;
  }

  SessionTemplateConfig? _initialSelectedTemplate() {
    final requested = widget.defaultSessionTemplateId?.trim();
    if (requested != null && requested.isNotEmpty) {
      for (final template in widget.sessionTemplates) {
        if (template.id == requested) return template;
      }
    }
    return null;
  }

  String? _startupDefaultAgentName() {
    final config = widget.baseConfig;
    if (config == null) return null;
    final explicit = config.defaultAgentServerName?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final servers = config.selectableAgentServers;
    return servers.isEmpty ? null : servers.first.name;
  }

  void _handleCwdChanged(String value) {
    setState(() {
      _cwd = value;
      _cwdError = null;
    });
  }

  void _handleCwdSelected(String value) {
    _cwdController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _handleCwdChanged(value);
  }

  void _submit() {
    final cwd = _normalizedCwd(_cwd);
    if (cwd == null) {
      setState(() => _cwdError = 'Enter an absolute working directory.');
      return;
    }
    Navigator.of(context).pop(
      NewSessionSelection(
        cwd: cwd,
        agentServer: _selectedTemplate == null ? _selectedServer : null,
        sessionTemplate: _selectedTemplate,
      ),
    );
  }
}

class _SessionScopeNotice extends StatelessWidget {
  const _SessionScopeNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.primaryMist,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.play_circle_outline_rounded,
            size: 18,
            color: AppColors.primaryDark,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'These choices apply to this new session. They do not change the startup default Agent.',
              style: TextStyle(
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

class _ChoiceSectionLabel extends StatelessWidget {
  const _ChoiceSectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.textTertiary,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
    );
  }
}

class _TemplateChoiceTile extends StatelessWidget {
  const _TemplateChoiceTile({
    required this.template,
    required this.selected,
    required this.onTap,
  });

  final SessionTemplateConfig template;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      if (template.agentServerName != null) template.agentServerName!,
      if (template.model != null) template.model!,
      if (template.mode != null) template.mode!,
      if (template.reasoningEffort != null)
        '${template.reasoningEffort} reasoning',
    ];
    final description = template.description?.trim();
    final subtitle = description != null && description.isNotEmpty
        ? description
        : details.isEmpty
        ? 'Configured runtime · v${template.version}'
        : '${details.join(' · ')} · v${template.version}';
    return Semantics(
      button: true,
      selected: selected,
      label: '${template.name}, template version ${template.version}',
      onTap: onTap,
      child: ExcludeSemantics(
        child: _SessionChoiceSurface(
          selected: selected,
          icon: Icons.dashboard_customize_outlined,
          title: template.name,
          subtitle: subtitle,
          onTap: onTap,
        ),
      ),
    );
  }
}

class _CustomSessionChoiceTile extends StatelessWidget {
  const _CustomSessionChoiceTile({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Custom session',
      onTap: onTap,
      child: ExcludeSemantics(
        child: _SessionChoiceSurface(
          selected: selected,
          icon: Icons.tune_rounded,
          title: 'Custom',
          subtitle: 'Choose an agent without a template',
          onTap: onTap,
        ),
      ),
    );
  }
}

class _TemplateSummary extends StatelessWidget {
  const _TemplateSummary({
    required this.template,
    required this.baseConfig,
    required this.currentAgentName,
  });

  final SessionTemplateConfig template;
  final AcpClientConfig? baseConfig;
  final String currentAgentName;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('Agent', _agentSummary()),
      ('MCP', _mcpSummary()),
      ('Additional directories', _directorySummary()),
      ('Permissions', _permissionSummary()),
      ('Assistant', _assistantSummary()),
      ('Session options', _sessionOptionSummary()),
    ];
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
          const Text(
            'Template summary',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 7),
          for (final row in rows) ...[
            _TemplateSummaryRow(label: row.$1, value: row.$2),
            if (row != rows.last) const SizedBox(height: 4),
          ],
          const SizedBox(height: 8),
          const Text(
            'Session option requests are applied after creation only when the selected Agent exposes matching capabilities.',
            style: TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10.5,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  String _agentSummary() {
    final configured = template.agentServerName?.trim();
    if (configured != null && configured.isNotEmpty) {
      return '$configured (selected by template)';
    }
    final inherited = baseConfig?.activeAgentServer?.name.trim();
    final name = inherited == null || inherited.isEmpty
        ? currentAgentName
        : inherited;
    return 'Inherit current Agent · $name';
  }

  String _mcpSummary() {
    final selected = template.mcpServerNames;
    if (selected != null) {
      return selected.isEmpty ? 'None' : selected.join(', ');
    }
    final inherited = baseConfig?.mcpServers ?? const <McpServerConfig>[];
    if (baseConfig == null) return 'Inherit app defaults';
    if (inherited.isEmpty) return 'Inherit app defaults · none configured';
    return 'Inherit app defaults · ${inherited.map((server) => server.name).join(', ')}';
  }

  String _directorySummary() {
    final inherited = baseConfig?.additionalDirectories ?? const <String>[];
    final added = template.additionalDirectories;
    if (inherited.isEmpty && added.isEmpty) {
      return baseConfig == null ? 'Inherit app defaults' : 'None';
    }
    final parts = <String>[
      if (inherited.isNotEmpty) 'App: ${inherited.join(', ')}',
      if (added.isNotEmpty) 'Template adds: ${added.join(', ')}',
    ];
    return parts.join(' · ');
  }

  String _permissionSummary() {
    final permissions = template.permissions;
    if (permissions == null) return 'Inherit Agent and app settings';
    final details = <String>[
      if (permissions.trustRules.isNotEmpty)
        '${permissions.trustRules.length} trust rule${permissions.trustRules.length == 1 ? '' : 's'}',
      if (permissions.reviewAgent.enabled) 'reviewer enabled',
    ];
    return details.isEmpty
        ? 'Template override · no trust rules or reviewer'
        : 'Template override · ${details.join(', ')}';
  }

  String _assistantSummary() {
    final assistant = template.assistantAgent;
    if (assistant == null) {
      final inherited = baseConfig?.assistantAgent;
      if (inherited == null) return 'Inherit app settings';
      if (!inherited.enabled) return 'Inherit app settings · disabled';
      return 'Inherit app settings · ${_assistantTarget(inherited)}';
    }
    if (!assistant.enabled) return 'Disabled by template';
    return 'Template · ${_assistantTarget(assistant)}';
  }

  String _assistantTarget(AssistantAgentConfig assistant) {
    final details = <String>[
      if (assistant.agentName?.trim().isNotEmpty == true)
        assistant.agentName!.trim(),
      if (assistant.model?.trim().isNotEmpty == true)
        'model ${assistant.model!.trim()}',
    ];
    return details.isEmpty ? 'enabled; target incomplete' : details.join(' · ');
  }

  String _sessionOptionSummary() {
    final requests = <String>[
      if (template.model?.trim().isNotEmpty == true)
        'model ${template.model!.trim()}',
      if (template.mode?.trim().isNotEmpty == true)
        'mode ${template.mode!.trim()}',
      if (template.reasoningEffort?.trim().isNotEmpty == true)
        'reasoning ${template.reasoningEffort!.trim()}',
    ];
    return requests.isEmpty ? 'No requests' : requests.join(' · ');
  }
}

class _TemplateSummaryRow extends StatelessWidget {
  const _TemplateSummaryRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 116,
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10.5,
              height: 1.25,
            ),
          ),
        ),
      ],
    );
  }
}

class _SessionChoiceSurface extends StatelessWidget {
  const _SessionChoiceSurface({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected ? AppColors.primaryMist : AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected
                  ? AppColors.primary.withValues(alpha: 0.22)
                  : AppColors.border,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.check_circle_rounded : icon,
                size: 20,
                color: selected ? AppColors.success : AppColors.primaryDark,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                        height: 1.25,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PathAutocompleteField extends StatelessWidget {
  const _PathAutocompleteField({
    required this.controller,
    required this.suggestions,
    required this.onChanged,
    required this.onSelected,
    required this.onSubmitted,
    this.errorText,
  });

  final TextEditingController controller;
  final List<String> suggestions;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSelected;
  final VoidCallback onSubmitted;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Session working directory',
            helperText: 'Used as this session’s main workspace.',
            prefixIcon: const Icon(Icons.folder_open_outlined),
            errorText: errorText,
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
          ),
          textInputAction: TextInputAction.done,
          onChanged: onChanged,
          onSubmitted: (_) => onSubmitted(),
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: AppColors.border),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                itemCount: suggestions.length,
                itemBuilder: (context, index) {
                  final suggestion = suggestions[index];
                  return InkWell(
                    onTap: () => onSelected(suggestion),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.folder_outlined,
                            size: 16,
                            color: AppColors.primaryDark,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              suggestion,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _AgentChoiceTile extends StatelessWidget {
  const _AgentChoiceTile({
    required this.server,
    required this.selected,
    required this.isCurrent,
    required this.isStartupDefault,
    required this.onTap,
  });

  final AgentServerConfig server;
  final bool selected;
  final bool isCurrent;
  final bool isStartupDefault;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${server.name}, ${server.safeDisplayTarget}',
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: onTap,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.primaryMist
                    : AppColors.surfaceRaised,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                  color: selected
                      ? AppColors.primary.withValues(alpha: 0.22)
                      : AppColors.border,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    selected ? Icons.check_circle_rounded : Icons.hub_outlined,
                    size: 20,
                    color: selected ? AppColors.success : AppColors.primaryDark,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          server.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Tooltip(
                          message: server.safeDisplayTarget,
                          child: Text(
                            server.safeDisplayTarget,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textTertiary,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                        if (isCurrent || isStartupDefault) ...[
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              if (isCurrent)
                                const _AgentScopeLabel('Current Agent'),
                              if (isStartupDefault)
                                const _AgentScopeLabel('Startup default'),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AgentScopeLabel extends StatelessWidget {
  const _AgentScopeLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primaryMist,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.primaryDark,
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

Iterable<String> newSessionPathSuggestions(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const <String>[];

  final home = _homeDirectory();
  if (text == '~' && home != null) return <String>[home];

  final path = _expandUserPath(text);
  final target = _completionTarget(path);
  if (target == null) return const <String>[];

  final directory = Directory(target.directory);
  List<FileSystemEntity> entries;
  try {
    entries = directory.listSync(followLinks: false);
  } on FileSystemException {
    return const <String>[];
  }

  final prefix = target.prefix.toLowerCase();
  final suggestions =
      entries.whereType<Directory>().map((entry) => entry.path).where((path) {
        final name = _basename(path).toLowerCase();
        return path != target.path &&
            (prefix.isEmpty || name.startsWith(prefix));
      }).toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  return suggestions.take(12);
}

_CompletionTarget? _completionTarget(String path) {
  if (!File(path).isAbsolute) return null;
  final separator = Platform.pathSeparator;
  if (path == separator) {
    return _CompletionTarget(directory: separator, prefix: '', path: path);
  }
  if (path.endsWith(separator)) {
    return _CompletionTarget(directory: path, prefix: '', path: path);
  }

  final index = path.lastIndexOf(separator);
  if (index == -1) return null;
  return _CompletionTarget(
    directory: index == 0 ? separator : path.substring(0, index),
    prefix: path.substring(index + 1),
    path: path,
  );
}

String? _normalizedCwd(String raw) {
  final path = _expandUserPath(raw.trim());
  if (path.isEmpty || !File(path).isAbsolute) return null;
  return path;
}

String _expandUserPath(String path) {
  final home = _homeDirectory();
  if (home == null) return path;
  if (path == '~') return home;
  if (path.startsWith('~/')) {
    return '$home${Platform.pathSeparator}${path.substring(2)}';
  }
  return path;
}

String? _homeDirectory() {
  final home = Platform.environment['HOME']?.trim();
  return home == null || home.isEmpty ? null : home;
}

String _basename(String path) {
  final trimmed = path.endsWith(Platform.pathSeparator) && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final index = trimmed.lastIndexOf(Platform.pathSeparator);
  return index == -1 ? trimmed : trimmed.substring(index + 1);
}

class _CompletionTarget {
  const _CompletionTarget({
    required this.directory,
    required this.prefix,
    required this.path,
  });

  final String directory;
  final String prefix;
  final String path;
}
