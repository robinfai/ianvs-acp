import 'dart:io';

import 'package:flutter/material.dart';

import '../../config/acp_client_config.dart';
import '../theme/app_design_tokens.dart';

class NewSessionSelection {
  const NewSessionSelection({required this.cwd, this.agentServer});

  final String cwd;
  final AgentServerConfig? agentServer;
}

class NewSessionAgentDialog extends StatefulWidget {
  const NewSessionAgentDialog({
    super.key,
    required this.agentServers,
    required this.currentAgentName,
    this.initialCwd = '',
  });

  final List<AgentServerConfig> agentServers;
  final String currentAgentName;
  final String initialCwd;

  @override
  State<NewSessionAgentDialog> createState() => _NewSessionAgentDialogState();
}

class _NewSessionAgentDialogState extends State<NewSessionAgentDialog> {
  AgentServerConfig? _selectedServer;
  late String _cwd;
  late final TextEditingController _cwdController;
  String? _cwdError;

  @override
  void initState() {
    super.initState();
    _selectedServer = _initialSelectedServer();
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
              if (widget.agentServers.isNotEmpty) ...[
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
    Navigator.of(
      context,
    ).pop(NewSessionSelection(cwd: cwd, agentServer: _selectedServer));
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
      label: '${server.name}, ${server.displayTarget}',
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
                          message: server.displayTarget,
                          child: Text(
                            server.displayTarget,
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
