import 'package:flutter/material.dart';

import '../../acp/acp_permission_request.dart';
import '../../config/acp_client_config.dart';
import '../theme/app_design_tokens.dart';

typedef AcpConfigSaveCallback =
    Future<AcpClientConfig> Function(AcpClientConfig config);

class AgentConfigDialog extends StatefulWidget {
  const AgentConfigDialog({
    super.key,
    required this.agentServers,
    required this.activeAgentName,
    this.mcpServers = const <McpServerConfig>[],
    this.additionalDirectories = const <String>[],
    this.clientProviders = const AcpClientProviderConfig(),
    this.configPath,
    this.defaultAgentName,
    this.onSaveConfig,
  });

  final List<AgentServerConfig> agentServers;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final String activeAgentName;
  final String? configPath;
  final String? defaultAgentName;
  final AcpConfigSaveCallback? onSaveConfig;

  @override
  State<AgentConfigDialog> createState() => _AgentConfigDialogState();
}

class _AgentConfigDialogState extends State<AgentConfigDialog> {
  late final List<AgentServerConfig> _agentServers = List.of(
    widget.agentServers,
  );
  late final List<McpServerConfig> _mcpServers = List.of(widget.mcpServers);
  late final List<String> _additionalDirectories = List.of(
    widget.additionalDirectories,
  );
  late bool _filesystemRead = widget.clientProviders.filesystem.readTextFile;
  late bool _filesystemWrite = widget.clientProviders.filesystem.writeTextFile;
  late bool _filesystemOutside =
      widget.clientProviders.filesystem.allowReadOutsideWorkspace;
  late bool _terminalEnabled = widget.clientProviders.terminal.enabled;
  late final List<AcpPermissionTrustRule> _trustRules = List.of(
    widget.clientProviders.permissions.trustRules,
  );
  late bool _reviewAgentEnabled =
      widget.clientProviders.permissions.reviewAgent.enabled ||
      widget.clientProviders.permissions.reviewAgent.isConfigured;
  late final TextEditingController _reviewServerNameController =
      TextEditingController(
        text:
            widget.clientProviders.permissions.reviewAgent.mcpServerName ?? '',
      );
  late final TextEditingController _reviewToolNameController =
      TextEditingController(
        text: widget.clientProviders.permissions.reviewAgent.toolName,
      );
  late final TextEditingController _reviewModelController =
      TextEditingController(
        text: widget.clientProviders.permissions.reviewAgent.model ?? '',
      );
  late final TextEditingController _reviewTimeoutController =
      TextEditingController(
        text:
            widget.clientProviders.permissions.reviewAgent.timeout ==
                const Duration(seconds: 10)
            ? ''
            : widget
                  .clientProviders
                  .permissions
                  .reviewAgent
                  .timeout
                  .inMilliseconds
                  .toString(),
      );
  late String? _defaultAgentName = widget.defaultAgentName;
  bool _saving = false;
  String? _error;

  bool get _canSave {
    return widget.onSaveConfig != null &&
        widget.configPath?.trim().isNotEmpty == true &&
        !_saving;
  }

  @override
  void dispose() {
    _reviewServerNameController.dispose();
    _reviewToolNameController.dispose();
    _reviewModelController.dispose();
    _reviewTimeoutController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Agent Configuration'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.68,
        ),
        child: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ConfigPathPanel(path: widget.configPath),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  _ErrorPanel(message: _error!),
                ],
                const SizedBox(height: 10),
                _buildDirectoriesSection(),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'MCP Servers',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _saving ? null : _addMcpServer,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add MCP Server'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_mcpServers.isNotEmpty)
                  _McpServersPanel(
                    servers: _mcpServers,
                    onEdit: _saving ? null : _editMcpServer,
                    onDelete: _saving ? null : _deleteMcpServer,
                  ),
                const SizedBox(height: 10),
                _buildClientProvidersSection(),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Agents',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _saving ? null : _addAgent,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add Agent'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_agentServers.isEmpty)
                  const _EmptyState()
                else
                  Column(
                    children: [
                      for (final server in _agentServers) ...[
                        _AgentServerPanel(
                          server: server,
                          selected: server.name == widget.activeAgentName,
                          isDefault: server.name == _defaultAgentName,
                          onSetDefault:
                              server.name == _defaultAgentName || _saving
                              ? null
                              : () => setState(() {
                                  _defaultAgentName = server.name;
                                  _error = null;
                                }),
                          onEdit: _saving ? null : () => _editAgent(server),
                          onDelete:
                              server.name == widget.activeAgentName || _saving
                              ? null
                              : () => _deleteAgent(server),
                        ),
                        if (server != _agentServers.last)
                          const SizedBox(height: 8),
                      ],
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (widget.onSaveConfig != null)
          FilledButton.icon(
            onPressed: _canSave ? () => _save(context) : null,
            icon: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('Save'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Future<void> _save(BuildContext context) async {
    final save = widget.onSaveConfig;
    if (save == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await save(
        AcpClientConfig(
          activeAgentServer: _agentServerNamed(_defaultAgentName),
          agentServers: _agentServers,
          mcpServers: _mcpServers,
          additionalDirectories: List.unmodifiable(_additionalDirectories),
          clientProviders: _clientProvidersConfig(),
          configPath: widget.configPath,
          defaultAgentServerName: _defaultAgentName,
        ),
      );
      if (!context.mounted) return;
      setState(() => _saving = false);
    } catch (error) {
      if (!context.mounted) return;
      setState(() {
        _saving = false;
        _error = '$error';
      });
    }
  }

  AgentServerConfig? _agentServerNamed(String? name) {
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    for (final server in _agentServers) {
      if (server.name == trimmed) return server;
    }
    return null;
  }

  Widget _buildDirectoriesSection() {
    return _Panel(
      icon: Icons.folder_copy_outlined,
      title: 'Additional Directories',
      accent: AppColors.primary,
      trailing: TextButton.icon(
        onPressed: _saving ? null : _addDirectory,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Directory'),
      ),
      child: _additionalDirectories.isEmpty
          ? const Text(
              'No additional directories.',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            )
          : Column(
              children: [
                for (final directory in _additionalDirectories)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: _DetailRow(
                            label: 'Directory',
                            value: directory,
                          ),
                        ),
                        _PanelActionButton(
                          tooltip: 'Delete directory $directory',
                          icon: Icons.delete_outline_rounded,
                          onPressed: _saving
                              ? null
                              : () => _deleteDirectory(directory),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildClientProvidersSection() {
    return _Panel(
      icon: Icons.security_rounded,
      title: 'Client Providers',
      accent: AppColors.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ConfigSwitch(
            key: const Key('filesystem-read-switch'),
            title: 'FS read',
            value: _filesystemRead,
            onChanged: (value) => setState(() => _filesystemRead = value),
          ),
          _ConfigSwitch(
            key: const Key('filesystem-write-switch'),
            title: 'FS write',
            value: _filesystemWrite,
            onChanged: (value) => setState(() => _filesystemWrite = value),
          ),
          _ConfigSwitch(
            key: const Key('filesystem-outside-switch'),
            title: 'Outside',
            value: _filesystemOutside,
            onChanged: (value) => setState(() => _filesystemOutside = value),
          ),
          _ConfigSwitch(
            key: const Key('terminal-enabled-switch'),
            title: 'Terminal',
            value: _terminalEnabled,
            onChanged: (value) => setState(() => _terminalEnabled = value),
          ),
          const Divider(height: 18, color: AppColors.border),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Text(
                      'Trust rules',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0,
                      ),
                    ),
                    if (_trustRules.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      _TinyPill('${_trustRules.length}', AppColors.warning),
                    ],
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _saving ? null : _addTrustRule,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add Trust Rule'),
              ),
            ],
          ),
          for (final rule in _trustRules)
            Row(
              children: [
                const SizedBox(
                  width: 82,
                  child: Text(
                    'Rule',
                    style: TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    _permissionTrustRuleLabel(rule),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                _PanelActionButton(
                  tooltip: 'Delete rule ${rule.toolName}',
                  icon: Icons.delete_outline_rounded,
                  onPressed: _saving ? null : () => _deleteTrustRule(rule),
                ),
              ],
            ),
          const Divider(height: 18, color: AppColors.border),
          _ConfigSwitch(
            key: const Key('review-agent-enabled-switch'),
            title: 'Review agent',
            value: _reviewAgentEnabled,
            onChanged: (value) => setState(() => _reviewAgentEnabled = value),
          ),
          const SizedBox(height: 8),
          _DialogTextField(
            key: const Key('review-mcp-server-name-field'),
            controller: _reviewServerNameController,
            label: 'Review MCP server name',
            icon: Icons.extension_outlined,
          ),
          const SizedBox(height: 8),
          _DialogTextField(
            key: const Key('review-tool-name-field'),
            controller: _reviewToolNameController,
            label: 'Review tool',
            icon: Icons.build_circle_outlined,
          ),
          const SizedBox(height: 8),
          _DialogTextField(
            key: const Key('review-model-field'),
            controller: _reviewModelController,
            label: 'Review model',
            icon: Icons.memory_rounded,
          ),
          const SizedBox(height: 8),
          _DialogTextField(
            key: const Key('review-timeout-field'),
            controller: _reviewTimeoutController,
            label: 'Review timeout ms',
            icon: Icons.timer_outlined,
          ),
        ],
      ),
    );
  }

  AcpClientProviderConfig _clientProvidersConfig() {
    return AcpClientProviderConfig(
      filesystem: AcpFilesystemProviderConfig(
        readTextFile: _filesystemRead,
        writeTextFile: _filesystemWrite,
        allowReadOutsideWorkspace: _filesystemOutside,
      ),
      terminal: AcpTerminalProviderConfig(enabled: _terminalEnabled),
      permissions: AcpPermissionProviderConfig(
        trustRules: List.unmodifiable(_trustRules),
        reviewAgent: _reviewAgentConfig(),
      ),
    );
  }

  AcpPermissionReviewAgentConfig _reviewAgentConfig() {
    return AcpPermissionReviewAgentConfig(
      enabled: _reviewAgentEnabled,
      mcpServerName: _trimmedOrNull(_reviewServerNameController.text),
      toolName:
          _trimmedOrNull(_reviewToolNameController.text) ?? 'review_permission',
      model: _trimmedOrNull(_reviewModelController.text),
      timeout: _reviewTimeout(),
    );
  }

  Duration _reviewTimeout() {
    final timeoutText = _reviewTimeoutController.text.trim();
    if (timeoutText.isEmpty) return const Duration(seconds: 10);
    final timeoutMs = int.tryParse(timeoutText);
    if (timeoutMs == null || timeoutMs <= 0) {
      throw const FormatException(
        'Review timeout must be a positive integer in milliseconds.',
      );
    }
    return Duration(milliseconds: timeoutMs);
  }

  Future<void> _addDirectory() async {
    final directory = await showDialog<String>(
      context: context,
      builder: (context) => const _DirectoryEditorDialog(),
    );
    if (directory == null || !mounted) return;
    setState(() {
      _additionalDirectories.remove(directory);
      _additionalDirectories.add(directory);
      _error = null;
    });
  }

  void _deleteDirectory(String directory) {
    setState(() {
      _additionalDirectories.remove(directory);
      _error = null;
    });
  }

  Future<void> _addTrustRule() async {
    final rule = await showDialog<AcpPermissionTrustRule>(
      context: context,
      builder: (context) => const _TrustRuleEditorDialog(),
    );
    if (rule == null || !mounted) return;
    setState(() {
      _trustRules.removeWhere((candidate) {
        return candidate.toolName == rule.toolName &&
            candidate.toolKind == rule.toolKind;
      });
      _trustRules.add(rule);
      _error = null;
    });
  }

  void _deleteTrustRule(AcpPermissionTrustRule rule) {
    setState(() {
      _trustRules.remove(rule);
      _error = null;
    });
  }

  Future<void> _addAgent() async {
    final server = await showDialog<AgentServerConfig>(
      context: context,
      builder: (context) => const _AgentServerEditorDialog(),
    );
    if (server == null || !mounted) return;
    setState(() {
      _agentServers.removeWhere((candidate) => candidate.name == server.name);
      _agentServers.add(server);
      _defaultAgentName ??= server.name;
      _error = null;
    });
  }

  Future<void> _editAgent(AgentServerConfig server) async {
    final edited = await showDialog<AgentServerConfig>(
      context: context,
      builder: (context) => _AgentServerEditorDialog(initialServer: server),
    );
    if (edited == null || !mounted) return;
    setState(() {
      final index = _agentServers.indexWhere(
        (candidate) => candidate.name == server.name,
      );
      if (index == -1) {
        _agentServers.add(edited);
      } else {
        _agentServers[index] = edited;
      }
      if (_defaultAgentName == server.name) _defaultAgentName = edited.name;
      _error = null;
    });
  }

  void _deleteAgent(AgentServerConfig server) {
    setState(() {
      _agentServers.removeWhere((candidate) => candidate.name == server.name);
      if (_defaultAgentName == server.name) {
        _defaultAgentName = _agentServers.isEmpty
            ? null
            : _agentServers.first.name;
      }
      _error = null;
    });
  }

  Future<void> _addMcpServer() async {
    final server = await showDialog<McpServerConfig>(
      context: context,
      builder: (context) => const _McpServerEditorDialog(),
    );
    if (server == null || !mounted) return;
    setState(() {
      _mcpServers.removeWhere((candidate) => candidate.name == server.name);
      _mcpServers.add(server);
      _error = null;
    });
  }

  Future<void> _editMcpServer(McpServerConfig server) async {
    final edited = await showDialog<McpServerConfig>(
      context: context,
      builder: (context) => _McpServerEditorDialog(initialServer: server),
    );
    if (edited == null || !mounted) return;
    setState(() {
      final index = _mcpServers.indexWhere(
        (candidate) => candidate.name == server.name,
      );
      if (index == -1) {
        _mcpServers.add(edited);
      } else {
        _mcpServers[index] = edited;
      }
      _error = null;
    });
  }

  void _deleteMcpServer(McpServerConfig server) {
    setState(() {
      _mcpServers.removeWhere((candidate) => candidate.name == server.name);
      _error = null;
    });
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: AppColors.danger,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelActionButton extends StatelessWidget {
  const _PanelActionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: Key(tooltip),
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: 17,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
    );
  }
}

class _ConfigSwitch extends StatelessWidget {
  const _ConfigSwitch({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(
          title,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
        ),
        subtitle: Text(
          value ? 'Enabled' : 'Disabled',
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

class _DirectoryEditorDialog extends StatefulWidget {
  const _DirectoryEditorDialog();

  @override
  State<_DirectoryEditorDialog> createState() => _DirectoryEditorDialogState();
}

class _DirectoryEditorDialogState extends State<_DirectoryEditorDialog> {
  final TextEditingController _pathController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Additional Directory'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DialogTextField(
              key: const Key('directory-path-field'),
              controller: _pathController,
              label: 'Directory',
              icon: Icons.folder_open_outlined,
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              _InlineError(message: _error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save Directory')),
      ],
    );
  }

  void _submit() {
    final path = _pathController.text.trim();
    if (path.isEmpty || !path.startsWith('/')) {
      setState(() => _error = 'Enter an absolute directory path.');
      return;
    }
    Navigator.of(context).pop(path);
  }
}

class _TrustRuleEditorDialog extends StatefulWidget {
  const _TrustRuleEditorDialog();

  @override
  State<_TrustRuleEditorDialog> createState() => _TrustRuleEditorDialogState();
}

class _TrustRuleEditorDialogState extends State<_TrustRuleEditorDialog> {
  final TextEditingController _toolNameController = TextEditingController();
  final TextEditingController _toolKindController = TextEditingController();
  AcpPermissionDecision _decision = AcpPermissionDecision.allow;
  String? _error;

  @override
  void dispose() {
    _toolNameController.dispose();
    _toolKindController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Trust Rule'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DialogTextField(
              key: const Key('trust-tool-name-field'),
              controller: _toolNameController,
              label: 'Tool name',
              icon: Icons.build_outlined,
            ),
            const SizedBox(height: 10),
            _DialogTextField(
              key: const Key('trust-tool-kind-field'),
              controller: _toolKindController,
              label: 'Tool kind',
              icon: Icons.category_outlined,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<AcpPermissionDecision>(
              key: const Key('trust-decision-field'),
              initialValue: _decision,
              decoration: _fieldDecoration(
                label: 'Decision',
                icon: Icons.rule_rounded,
              ),
              items: const [
                DropdownMenuItem(
                  value: AcpPermissionDecision.allow,
                  child: Text('allow'),
                ),
                DropdownMenuItem(
                  value: AcpPermissionDecision.deny,
                  child: Text('deny'),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _decision = value);
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              _InlineError(message: _error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save Rule')),
      ],
    );
  }

  void _submit() {
    final toolName = _toolNameController.text.trim();
    if (toolName.isEmpty) {
      setState(() => _error = 'Enter a tool name.');
      return;
    }
    Navigator.of(context).pop(
      AcpPermissionTrustRule(
        toolName: toolName,
        toolKind: _trimmedOrNull(_toolKindController.text),
        decision: _decision,
      ),
    );
  }
}

class _AgentServerEditorDialog extends StatefulWidget {
  const _AgentServerEditorDialog({this.initialServer});

  final AgentServerConfig? initialServer;

  @override
  State<_AgentServerEditorDialog> createState() =>
      _AgentServerEditorDialogState();
}

class _AgentServerEditorDialogState extends State<_AgentServerEditorDialog> {
  late String _type = widget.initialServer?.type ?? 'custom';
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialServer?.name ?? '',
  );
  late final TextEditingController _commandController = TextEditingController(
    text: widget.initialServer?.command ?? '',
  );
  late final TextEditingController _cwdController = TextEditingController(
    text: widget.initialServer?.cwd ?? '',
  );
  late final TextEditingController _urlController = TextEditingController(
    text: widget.initialServer?.url ?? '',
  );
  late final TextEditingController _systemPromptController =
      TextEditingController(text: widget.initialServer?.systemPrompt ?? '');
  final List<TextEditingController> _argControllers = [];
  final List<_NameValueControllers> _envControllers = [];
  final List<_NameValueControllers> _headerControllers = [];
  String? _error;

  bool get _isRemote =>
      _type == 'websocket' || _type == 'http' || _type == 'sse';

  @override
  void initState() {
    super.initState();
    final server = widget.initialServer;
    if (server == null) return;
    _argControllers.addAll(
      server.args.map((arg) => TextEditingController(text: arg)),
    );
    _envControllers.addAll(
      server.env.entries.map(
        (entry) => _NameValueControllers(name: entry.key, value: entry.value),
      ),
    );
    _headerControllers.addAll(
      server.headers.entries.map(
        (entry) => _NameValueControllers(name: entry.key, value: entry.value),
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _commandController.dispose();
    _cwdController.dispose();
    _urlController.dispose();
    _systemPromptController.dispose();
    for (final controller in _argControllers) {
      controller.dispose();
    }
    for (final controllers in _envControllers) {
      controllers.dispose();
    }
    for (final controllers in _headerControllers) {
      controllers.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Agent Server'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DialogTextField(
                key: const Key('agent-name-field'),
                controller: _nameController,
                label: 'Name',
                icon: Icons.badge_outlined,
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: const Key('agent-type-field'),
                initialValue: _type,
                decoration: _fieldDecoration(
                  label: 'Type',
                  icon: Icons.cable_rounded,
                ),
                items: const [
                  DropdownMenuItem(value: 'custom', child: Text('custom')),
                  DropdownMenuItem(value: 'stdio', child: Text('stdio')),
                  DropdownMenuItem(
                    value: 'websocket',
                    child: Text('websocket'),
                  ),
                  DropdownMenuItem(value: 'http', child: Text('http')),
                  DropdownMenuItem(value: 'sse', child: Text('sse')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _type = value;
                    _error = null;
                  });
                },
              ),
              const SizedBox(height: 10),
              if (_isRemote) ...[
                _DialogTextField(
                  key: const Key('agent-url-field'),
                  controller: _urlController,
                  label: 'URL',
                  icon: Icons.link_rounded,
                ),
                const SizedBox(height: 10),
                _NameValueListEditor(
                  title: 'Headers',
                  addLabel: 'Add Header',
                  itemPrefix: 'agent-header',
                  controllers: _headerControllers,
                  onAdd: () => setState(() {
                    _headerControllers.add(_NameValueControllers());
                  }),
                  onRemove: (index) => setState(() {
                    _headerControllers.removeAt(index).dispose();
                  }),
                ),
              ] else ...[
                _DialogTextField(
                  key: const Key('agent-command-field'),
                  controller: _commandController,
                  label: 'Command',
                  icon: Icons.terminal_rounded,
                ),
                const SizedBox(height: 10),
                _DialogTextField(
                  key: const Key('agent-cwd-field'),
                  controller: _cwdController,
                  label: 'CWD',
                  icon: Icons.folder_open_outlined,
                ),
                const SizedBox(height: 10),
                _StringListEditor(
                  title: 'Args',
                  addLabel: 'Add Arg',
                  itemPrefix: 'agent-arg',
                  controllers: _argControllers,
                  onAdd: () => setState(() {
                    _argControllers.add(TextEditingController());
                  }),
                  onRemove: (index) => setState(() {
                    _argControllers.removeAt(index).dispose();
                  }),
                ),
                const SizedBox(height: 10),
                _NameValueListEditor(
                  title: 'Env',
                  addLabel: 'Add Env',
                  itemPrefix: 'agent-env',
                  controllers: _envControllers,
                  onAdd: () => setState(() {
                    _envControllers.add(_NameValueControllers());
                  }),
                  onRemove: (index) => setState(() {
                    _envControllers.removeAt(index).dispose();
                  }),
                ),
              ],
              const SizedBox(height: 10),
              _DialogTextField(
                key: const Key('agent-system-prompt-field'),
                controller: _systemPromptController,
                label: 'System Prompt',
                icon: Icons.psychology_alt_outlined,
                maxLines: 4,
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                _InlineError(message: _error!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save Agent')),
      ],
    );
  }

  void _submit() {
    try {
      final json = <String, dynamic>{'type': _type};
      if (_isRemote) {
        json['url'] = _urlController.text;
        final headers = _nameValueMap(_headerControllers);
        if (headers.isNotEmpty) json['headers'] = headers;
      } else {
        json['command'] = _commandController.text;
        if (_cwdController.text.trim().isNotEmpty) {
          json['cwd'] = _cwdController.text;
        }
        final args = _stringValues(_argControllers);
        if (args.isNotEmpty) json['args'] = args;
        final env = _nameValueMap(_envControllers);
        if (env.isNotEmpty) json['env'] = env;
      }
      if (_systemPromptController.text.trim().isNotEmpty) {
        json['system_prompt'] = _systemPromptController.text;
      }
      final server = AgentServerConfig.fromJson(
        name: _nameController.text.trim(),
        json: json,
      );
      Navigator.of(context).pop(server);
    } catch (error) {
      setState(() => _error = '$error');
    }
  }
}

class _McpServerEditorDialog extends StatefulWidget {
  const _McpServerEditorDialog({this.initialServer});

  final McpServerConfig? initialServer;

  @override
  State<_McpServerEditorDialog> createState() => _McpServerEditorDialogState();
}

class _McpServerEditorDialogState extends State<_McpServerEditorDialog> {
  late String _type = widget.initialServer?.type ?? 'stdio';
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialServer?.name == 'MCP server'
        ? ''
        : widget.initialServer?.name ?? '',
  );
  late final TextEditingController _commandController = TextEditingController(
    text: widget.initialServer?.command ?? '',
  );
  late final TextEditingController _urlController = TextEditingController(
    text: widget.initialServer?.url ?? '',
  );
  late final TextEditingController _idController = TextEditingController(
    text: widget.initialServer?.id ?? '',
  );
  final List<TextEditingController> _argControllers = [];
  final List<_NameValueControllers> _envControllers = [];
  final List<_NameValueControllers> _headerControllers = [];
  String? _error;

  bool get _isRemote => _type == 'http' || _type == 'sse';

  @override
  void initState() {
    super.initState();
    final raw = widget.initialServer?.raw;
    if (raw == null) return;
    final args = raw['args'];
    if (args is List) {
      _argControllers.addAll(
        args.whereType<String>().map((arg) => TextEditingController(text: arg)),
      );
    }
    final env = raw['env'];
    if (env is List) {
      _envControllers.addAll(_nameValueControllersFromList(env));
    }
    final headers = raw['headers'];
    if (headers is Map) {
      _headerControllers.addAll(
        headers.entries
            .where((entry) {
              return entry.key is String && entry.value is String;
            })
            .map(
              (entry) => _NameValueControllers(
                name: entry.key as String,
                value: entry.value as String,
              ),
            ),
      );
    } else if (headers is List) {
      _headerControllers.addAll(_nameValueControllersFromList(headers));
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _commandController.dispose();
    _urlController.dispose();
    _idController.dispose();
    for (final controller in _argControllers) {
      controller.dispose();
    }
    for (final controllers in _envControllers) {
      controllers.dispose();
    }
    for (final controllers in _headerControllers) {
      controllers.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('MCP Server'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DialogTextField(
                key: const Key('mcp-name-field'),
                controller: _nameController,
                label: 'Name',
                icon: Icons.extension_outlined,
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: const Key('mcp-type-field'),
                initialValue: _type,
                decoration: _fieldDecoration(
                  label: 'Type',
                  icon: Icons.cable_rounded,
                ),
                items: const [
                  DropdownMenuItem(value: 'stdio', child: Text('stdio')),
                  DropdownMenuItem(value: 'http', child: Text('http')),
                  DropdownMenuItem(value: 'sse', child: Text('sse')),
                  DropdownMenuItem(value: 'acp', child: Text('acp')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _type = value;
                    _error = null;
                  });
                },
              ),
              const SizedBox(height: 10),
              if (_type == 'acp') ...[
                _DialogTextField(
                  key: const Key('mcp-id-field'),
                  controller: _idController,
                  label: 'ID',
                  icon: Icons.fingerprint_rounded,
                ),
              ] else if (_isRemote) ...[
                _DialogTextField(
                  key: const Key('mcp-url-field'),
                  controller: _urlController,
                  label: 'URL',
                  icon: Icons.link_rounded,
                ),
                const SizedBox(height: 10),
                _NameValueListEditor(
                  title: 'Headers',
                  addLabel: 'Add Header',
                  itemPrefix: 'mcp-header',
                  controllers: _headerControllers,
                  onAdd: () => setState(() {
                    _headerControllers.add(_NameValueControllers());
                  }),
                  onRemove: (index) => setState(() {
                    _headerControllers.removeAt(index).dispose();
                  }),
                ),
              ] else ...[
                _DialogTextField(
                  key: const Key('mcp-command-field'),
                  controller: _commandController,
                  label: 'Command',
                  icon: Icons.terminal_rounded,
                ),
                const SizedBox(height: 10),
                _StringListEditor(
                  title: 'Args',
                  addLabel: 'Add Arg',
                  itemPrefix: 'mcp-arg',
                  controllers: _argControllers,
                  onAdd: () => setState(() {
                    _argControllers.add(TextEditingController());
                  }),
                  onRemove: (index) => setState(() {
                    _argControllers.removeAt(index).dispose();
                  }),
                ),
                const SizedBox(height: 10),
                _NameValueListEditor(
                  title: 'Env',
                  addLabel: 'Add Env',
                  itemPrefix: 'mcp-env',
                  controllers: _envControllers,
                  onAdd: () => setState(() {
                    _envControllers.add(_NameValueControllers());
                  }),
                  onRemove: (index) => setState(() {
                    _envControllers.removeAt(index).dispose();
                  }),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                _InlineError(message: _error!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save MCP Server')),
      ],
    );
  }

  void _submit() {
    try {
      final raw = <String, dynamic>{
        'name': _nameController.text,
        'type': _type,
      };
      if (_type == 'acp') {
        raw['id'] = _idController.text;
      } else if (_isRemote) {
        raw['url'] = _urlController.text;
        final headers = _nameValueEntries(_headerControllers);
        if (headers.isNotEmpty) raw['headers'] = headers;
      } else {
        raw['command'] = _commandController.text;
        final args = _stringValues(_argControllers);
        if (args.isNotEmpty) raw['args'] = args;
        final env = _nameValueEntries(_envControllers);
        if (env.isNotEmpty) raw['env'] = env;
      }
      final server = McpServerConfig.fromJson(index: 0, json: raw);
      Navigator.of(context).pop(server);
    } catch (error) {
      setState(() => _error = '$error');
    }
  }
}

class _NameValueControllers {
  _NameValueControllers({String name = '', String value = ''})
    : nameController = TextEditingController(text: name),
      valueController = TextEditingController(text: value);

  final TextEditingController nameController;
  final TextEditingController valueController;

  void dispose() {
    nameController.dispose();
    valueController.dispose();
  }
}

class _DialogTextField extends StatelessWidget {
  const _DialogTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.obscureText = false,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscureText;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      maxLines: maxLines,
      decoration: _fieldDecoration(label: label, icon: icon),
    );
  }
}

class _StringListEditor extends StatelessWidget {
  const _StringListEditor({
    required this.title,
    required this.addLabel,
    required this.itemPrefix,
    required this.controllers,
    required this.onAdd,
    required this.onRemove,
  });

  final String title;
  final String addLabel;
  final String itemPrefix;
  final List<TextEditingController> controllers;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    return _ListEditorFrame(
      title: title,
      addLabel: addLabel,
      onAdd: onAdd,
      children: [
        for (var index = 0; index < controllers.length; index += 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: _DialogTextField(
                    key: Key('$itemPrefix-$index-field'),
                    controller: controllers[index],
                    label: '$title ${index + 1}',
                    icon: Icons.notes_rounded,
                  ),
                ),
                const SizedBox(width: 8),
                _PanelActionButton(
                  tooltip: 'Remove $title ${index + 1}',
                  icon: Icons.remove_circle_outline_rounded,
                  onPressed: () => onRemove(index),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _NameValueListEditor extends StatelessWidget {
  const _NameValueListEditor({
    required this.title,
    required this.addLabel,
    required this.itemPrefix,
    required this.controllers,
    required this.onAdd,
    required this.onRemove,
  });

  final String title;
  final String addLabel;
  final String itemPrefix;
  final List<_NameValueControllers> controllers;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    return _ListEditorFrame(
      title: title,
      addLabel: addLabel,
      onAdd: onAdd,
      children: [
        for (var index = 0; index < controllers.length; index += 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: _DialogTextField(
                    key: Key('$itemPrefix-name-$index-field'),
                    controller: controllers[index].nameController,
                    label: 'Name',
                    icon: Icons.label_outline_rounded,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _DialogTextField(
                    key: Key('$itemPrefix-value-$index-field'),
                    controller: controllers[index].valueController,
                    label: 'Value',
                    icon: Icons.key_rounded,
                    obscureText: true,
                  ),
                ),
                const SizedBox(width: 8),
                _PanelActionButton(
                  tooltip: 'Remove $title ${index + 1}',
                  icon: Icons.remove_circle_outline_rounded,
                  onPressed: () => onRemove(index),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ListEditorFrame extends StatelessWidget {
  const _ListEditorFrame({
    required this.title,
    required this.addLabel,
    required this.onAdd,
    required this.children,
  });

  final String title;
  final String addLabel;
  final VoidCallback onAdd;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add_rounded),
                label: Text(addLabel),
              ),
            ],
          ),
          if (children.isNotEmpty) ...[const SizedBox(height: 8), ...children],
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: const TextStyle(
        color: AppColors.danger,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
    );
  }
}

InputDecoration _fieldDecoration({
  required String label,
  required IconData icon,
}) {
  return InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon),
    isDense: true,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
    ),
  );
}

List<String> _stringValues(List<TextEditingController> controllers) {
  return controllers
      .map((controller) => controller.text.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
}

String? _trimmedOrNull(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Map<String, String> _nameValueMap(List<_NameValueControllers> controllers) {
  return <String, String>{
    for (final controllers in controllers)
      if (controllers.nameController.text.trim().isNotEmpty ||
          controllers.valueController.text.trim().isNotEmpty)
        controllers.nameController.text.trim():
            controllers.valueController.text,
  };
}

List<Map<String, String>> _nameValueEntries(
  List<_NameValueControllers> controllers,
) {
  return [
    for (final controllers in controllers)
      if (controllers.nameController.text.trim().isNotEmpty ||
          controllers.valueController.text.trim().isNotEmpty)
        {
          'name': controllers.nameController.text.trim(),
          'value': controllers.valueController.text,
        },
  ];
}

List<_NameValueControllers> _nameValueControllersFromList(List raw) {
  return [
    for (final entry in raw)
      if (entry is Map && entry['name'] is String && entry['value'] is String)
        _NameValueControllers(
          name: entry['name'] as String,
          value: entry['value'] as String,
        ),
  ];
}

String _permissionTrustRuleLabel(AcpPermissionTrustRule rule) {
  final kind = rule.toolKind?.trim();
  final target = kind == null || kind.isEmpty
      ? rule.toolName.trim()
      : '${rule.toolName.trim()} / $kind';
  return '$target -> ${rule.displayDecision}';
}

String _reviewAgentTargetLabel(AcpPermissionReviewAgentConfig reviewAgent) {
  return reviewAgent.hasMcpTarget ? reviewAgent.displayTarget : 'Same agent';
}

class _McpServersPanel extends StatelessWidget {
  const _McpServersPanel({required this.servers, this.onEdit, this.onDelete});

  final List<McpServerConfig> servers;
  final ValueChanged<McpServerConfig>? onEdit;
  final ValueChanged<McpServerConfig>? onDelete;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      icon: Icons.extension_rounded,
      title: 'Configured MCP Servers',
      accent: AppColors.success,
      trailing: _TinyPill('${servers.length}', AppColors.success),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < servers.length; index += 1)
            _McpServerDetails(
              server: servers[index],
              isLast: index == servers.length - 1,
              onEdit: onEdit == null ? null : () => onEdit!(servers[index]),
              onDelete: onDelete == null
                  ? null
                  : () => onDelete!(servers[index]),
            ),
        ],
      ),
    );
  }
}

class _McpServerDetails extends StatelessWidget {
  const _McpServerDetails({
    required this.server,
    required this.isLast,
    this.onEdit,
    this.onDelete,
  });

  final McpServerConfig server;
  final bool isLast;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final headerKeys = server.headerKeys;
    final targetLabel = server.type == 'acp' && server.id.isNotEmpty
        ? 'ID'
        : server.command.isNotEmpty
        ? 'Command'
        : 'URL';
    final targetValue = server.type == 'acp' && server.id.isNotEmpty
        ? server.id
        : server.command.isNotEmpty
        ? server.command
        : server.url;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _DetailRow(label: 'Name', value: server.name),
            ),
            _PanelActionButton(
              tooltip: 'Edit ${server.name}',
              icon: Icons.edit_outlined,
              onPressed: onEdit,
            ),
            _PanelActionButton(
              tooltip: 'Delete ${server.name}',
              icon: Icons.delete_outline_rounded,
              onPressed: onDelete,
            ),
          ],
        ),
        const SizedBox(height: 6),
        _DetailRow(label: 'Type', value: server.type),
        const SizedBox(height: 6),
        _DetailRow(label: targetLabel, value: targetValue),
        if (server.url.isNotEmpty) ...[
          const SizedBox(height: 6),
          _DetailRow(
            label: 'Headers',
            value: headerKeys.isEmpty
                ? 'No header keys'
                : headerKeys.join(', '),
          ),
        ],
        if (!isLast) ...[
          const SizedBox(height: 8),
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _ConfigPathPanel extends StatelessWidget {
  const _ConfigPathPanel({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      icon: Icons.description_outlined,
      title: 'User Config',
      child: SelectableText(
        path == null || path!.isEmpty ? 'Not resolved' : path!,
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

class _AgentServerPanel extends StatelessWidget {
  const _AgentServerPanel({
    required this.server,
    required this.selected,
    required this.isDefault,
    this.onSetDefault,
    this.onEdit,
    this.onDelete,
  });

  final AgentServerConfig server;
  final bool selected;
  final bool isDefault;
  final VoidCallback? onSetDefault;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final args = server.args.isEmpty ? 'No args' : server.args.join(' ');
    final envKeys = server.env.keys.toList()..sort();
    final headerKeys = server.headers.keys.toList()..sort();
    final reviewAgent = server.permissionReviewAgent;

    return _Panel(
      icon: selected ? Icons.check_circle_rounded : Icons.hub_outlined,
      title: server.name,
      accent: selected ? AppColors.success : AppColors.primaryDark,
      trailing: Wrap(
        spacing: 5,
        runSpacing: 5,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (selected) const _TinyPill('Current', AppColors.success),
          if (isDefault) const _TinyPill('Default', AppColors.primaryDark),
          if (!isDefault)
            _PanelActionButton(
              tooltip: 'Set ${server.name} as default',
              icon: Icons.star_outline_rounded,
              onPressed: onSetDefault,
            ),
          _PanelActionButton(
            tooltip: 'Edit ${server.name}',
            icon: Icons.edit_outlined,
            onPressed: onEdit,
          ),
          _PanelActionButton(
            tooltip: 'Delete ${server.name}',
            icon: Icons.delete_outline_rounded,
            onPressed: onDelete,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(label: 'Type', value: server.type),
          const SizedBox(height: 6),
          if (!server.isStdio) ...[
            _DetailRow(label: 'URL', value: server.url),
            const SizedBox(height: 6),
            _DetailRow(
              label: 'Headers',
              value: headerKeys.isEmpty
                  ? 'No header keys'
                  : headerKeys.join(', '),
            ),
          ] else ...[
            _DetailRow(label: 'Command', value: server.command),
            if (server.cwd != null) ...[
              const SizedBox(height: 6),
              _DetailRow(label: 'CWD', value: server.cwd!),
            ],
            const SizedBox(height: 6),
            _DetailRow(label: 'Args', value: args),
            const SizedBox(height: 6),
            _DetailRow(
              label: 'Env',
              value: envKeys.isEmpty ? 'No env keys' : envKeys.join(', '),
            ),
          ],
          if (reviewAgent.isConfigured) ...[
            const SizedBox(height: 6),
            _DetailRow(
              label: 'Review',
              value: _reviewAgentTargetLabel(reviewAgent),
            ),
            const SizedBox(height: 6),
            _DetailRow(
              label: 'Review model',
              value: reviewAgent.model ?? 'Current model',
            ),
          ],
          if (server.systemPrompt.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            const _DetailRow(label: 'System', value: 'System prompt set'),
          ],
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 82,
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.icon,
    required this.title,
    required this.child,
    this.accent = AppColors.primaryDark,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Color accent;
  final Widget? trailing;

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
              Icon(icon, size: 17, color: accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _TinyPill extends StatelessWidget {
  const _TinyPill(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
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

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 130,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(10),
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
            'No user-configured agent servers.',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}
