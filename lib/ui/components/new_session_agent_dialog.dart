import 'dart:io';

import 'package:flutter/material.dart';

import '../../config/acp_client_config.dart';
import '../theme/app_design_tokens.dart';

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
  });

  final List<AgentServerConfig> agentServers;
  final String currentAgentName;
  final List<SessionTemplateConfig> sessionTemplates;
  final String? defaultSessionTemplateId;
  final String initialCwd;

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
                const SizedBox(height: 16),
              ],
              if (_selectedTemplate == null &&
                  widget.agentServers.isNotEmpty) ...[
                if (widget.sessionTemplates.isNotEmpty) ...[
                  const _ChoiceSectionLabel('Agent'),
                  const SizedBox(height: 8),
                ],
                for (final server in widget.agentServers) ...[
                  _AgentChoiceTile(
                    server: server,
                    selected: server.name == _selectedServer?.name,
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
            labelText: 'Working Directory',
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
    required this.onTap,
  });

  final AgentServerConfig server;
  final bool selected;
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
