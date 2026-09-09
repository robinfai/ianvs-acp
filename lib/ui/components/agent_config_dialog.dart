import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../acp/acp_permission_request.dart';
import '../../acp/acp_session_settings.dart';
import '../../config/acp_client_config.dart';
import '../../config/config_reference_updates.dart';
import '../../config/assistant_agent_config.dart';
import '../../storage/sqlite_storage_config.dart';
import 'package:ianvs_agent_chat/ui/theme/app_design_tokens.dart';

part 'settings_connection_editors.dart';
part 'settings_page_layout.dart';

typedef AcpConfigSaveCallback =
    Future<AcpClientConfig> Function(AcpClientConfig config);
typedef AssistantAgentValidationCallback =
    Future<void> Function(AssistantAgentConfig config);
typedef AssistantAgentModelsLoadCallback =
    Future<AcpConfigOption?> Function(String agentName);

class AgentConfigDialog extends StatefulWidget {
  const AgentConfigDialog({
    super.key,
    required this.agentServers,
    required this.activeAgentName,
    this.agentPresets = const <AgentServerConfig>[],
    this.mcpServers = const <McpServerConfig>[],
    this.additionalDirectories = const <String>[],
    this.clientProviders = const AcpClientProviderConfig(),
    this.storage = const SqliteStorageConfig(),
    this.assistantAgent = const AssistantAgentConfig(),
    this.sessionTemplates = const <SessionTemplateConfig>[],
    this.defaultSessionTemplateId,
    this.configPath,
    this.defaultAgentName,
    this.onSaveConfig,
    this.runtimeBusy,
    this.allowAppNavigation = false,
    this.onValidateAssistantAgent,
    this.onLoadAssistantAgentModels,
  });

  final List<AgentServerConfig> agentServers;
  final List<AgentServerConfig> agentPresets;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final SqliteStorageConfig storage;
  final AssistantAgentConfig assistantAgent;
  final List<SessionTemplateConfig> sessionTemplates;
  final String? defaultSessionTemplateId;
  final String activeAgentName;
  final String? configPath;
  final String? defaultAgentName;
  final AcpConfigSaveCallback? onSaveConfig;
  final ValueListenable<bool>? runtimeBusy;
  final bool allowAppNavigation;
  final AssistantAgentValidationCallback? onValidateAssistantAgent;
  final AssistantAgentModelsLoadCallback? onLoadAssistantAgentModels;

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
      widget.clientProviders.permissions.reviewAgent.enabled;
  late final TextEditingController
  _reviewAgentServerNameController = TextEditingController(
    text: widget.clientProviders.permissions.reviewAgent.agentServerName ?? '',
  );
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
  late McpServerConfig? _reviewInlineMcpServer =
      widget.clientProviders.permissions.reviewAgent.mcpServer;
  late String _reviewTargetKind = _reviewInlineMcpServer != null
      ? 'inline'
      : _reviewServerNameController.text.isNotEmpty
      ? 'mcp'
      : 'agent';
  late bool _assistantEnabled = widget.assistantAgent.enabled;
  late String? _assistantAgentName = widget.assistantAgent.agentName;
  late bool _assistantGenerateTitles =
      widget.assistantAgent.generateSessionTitles;
  late bool _assistantSummarizeTurns = widget.assistantAgent.summarizeTurns;
  late bool _assistantCollapseProcess =
      widget.assistantAgent.collapseExecutionProcess;
  late String? _assistantModel = widget.assistantAgent.model;
  AcpConfigOption? _assistantModelOption;
  bool _assistantModelsLoading = false;
  String? _assistantModelsError;
  int _assistantModelLoadGeneration = 0;
  late final TextEditingController _assistantFallbackTitleController =
      TextEditingController(
        text: widget.assistantAgent.fallbackTitleCharacters.toString(),
      );
  String? _assistantValidationStatus;
  bool _assistantValidationSucceeded = false;
  bool _assistantValidating = false;
  late final TextEditingController _storageMaxSizeController =
      TextEditingController(text: widget.storage.maxSizeGb.toString());
  late final TextEditingController _storageRetentionController =
      TextEditingController(text: widget.storage.retentionDays.toString());
  late String? _defaultAgentName = widget.defaultAgentName;
  bool _saving = false;
  String? _error;

  _SettingsSection _section = _SettingsSection.agents;
  AgentServerConfig? _selectedAgent;
  McpServerConfig? _selectedMcp;
  final Map<AgentServerConfig, GlobalKey<_AgentServerEditorDialogState>>
  _agentEditors = {};
  final Map<McpServerConfig, GlobalKey<_McpServerEditorDialogState>>
  _mcpEditors = {};
  late AcpClientConfig _savedConfig;
  late String _baselineSignature;
  late String _activeAgentName = widget.activeAgentName;
  bool _allowPop = false;
  bool _confirmingExit = false;
  bool _restoring = false;
  String? _saveStatus;

  bool get _readOnly =>
      widget.onSaveConfig == null ||
      widget.configPath?.trim().isNotEmpty != true;
  bool get _runtimeBusy => widget.runtimeBusy?.value ?? false;
  bool get _hasChanges =>
      _generalSignature != _baselineSignature ||
      _agentEditors.values.any(
        (key) => key.currentState?.hasChanges ?? false,
      ) ||
      _mcpEditors.values.any((key) => key.currentState?.hasChanges ?? false);
  bool get _canSave => !_readOnly && !_saving && !_runtimeBusy && _hasChanges;

  Iterable<TextEditingController> get _generalFields => [
    _reviewAgentServerNameController,
    _reviewServerNameController,
    _reviewToolNameController,
    _reviewModelController,
    _reviewTimeoutController,
    _assistantFallbackTitleController,
    _storageMaxSizeController,
    _storageRetentionController,
  ];

  String get _generalSignature => jsonEncode([
    _defaultAgentName,
    _additionalDirectories,
    for (final agent in _agentServers) [agent.name, agent.toJson()],
    for (final server in _mcpServers) server.toJson(),
    _filesystemRead,
    _filesystemWrite,
    _filesystemOutside,
    _terminalEnabled,
    for (final rule in _trustRules)
      [rule.toolName, rule.toolKind, rule.decision.name],
    _reviewAgentEnabled,
    _reviewInlineMcpServer?.toJson(),
    _assistantEnabled,
    _assistantAgentName,
    _assistantModel,
    _assistantGenerateTitles,
    _assistantSummarizeTurns,
    _assistantCollapseProcess,
    _reviewTargetKind,
    for (final field in _generalFields) field.text,
  ]);

  void _change(VoidCallback fn) => setState(fn);
  void _draftChanged() {
    if (mounted && !_restoring) {
      setState(() {
        _saveStatus = null;
      });
    }
  }

  AcpClientConfig _widgetConfig() => AcpClientConfig(
    activeAgentServer: widget.agentServers
        .where((a) => a.name == widget.activeAgentName)
        .firstOrNull,
    agentServers: widget.agentServers,
    mcpServers: widget.mcpServers,
    additionalDirectories: widget.additionalDirectories,
    clientProviders: widget.clientProviders,
    storage: widget.storage,
    assistantAgent: widget.assistantAgent,
    sessionTemplates: widget.sessionTemplates,
    defaultSessionTemplateId: widget.defaultSessionTemplateId,
    configPath: widget.configPath,
    defaultAgentServerName: widget.defaultAgentName,
  );

  @override
  void initState() {
    super.initState();
    _savedConfig = _widgetConfig();
    _selectedAgent =
        _agentServers
            .where((a) => a.name == widget.activeAgentName)
            .firstOrNull ??
        _agentServers.firstOrNull;
    if (_selectedAgent != null) {
      _agentEditors[_selectedAgent!] =
          GlobalKey<_AgentServerEditorDialogState>();
    }
    _baselineSignature = _generalSignature;
    for (final field in _generalFields) {
      field.addListener(_draftChanged);
    }
    if (_assistantEnabled && _assistantAgentName?.trim().isNotEmpty == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadAssistantAgentModels(_assistantAgentName);
      });
    }
  }

  @override
  void dispose() {
    _reviewAgentServerNameController.dispose();
    _reviewServerNameController.dispose();
    _reviewToolNameController.dispose();
    _reviewModelController.dispose();
    _reviewTimeoutController.dispose();
    _assistantFallbackTitleController.dispose();
    _storageMaxSizeController.dispose();
    _storageRetentionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildSettingsPage(context);

  void _adoptConfig(AcpClientConfig config) {
    _restoring = true;
    _savedConfig = config;
    _agentServers
      ..clear()
      ..addAll(config.agentServers);
    _mcpServers
      ..clear()
      ..addAll(config.mcpServers);
    _additionalDirectories
      ..clear()
      ..addAll(config.additionalDirectories);
    _defaultAgentName = config.defaultAgentServerName;
    _agentEditors.clear();
    _mcpEditors.clear();
    _selectedAgent =
        _agentServers.where((a) => a.name == _activeAgentName).firstOrNull ??
        _agentServers.firstOrNull;
    _selectedMcp = null;
    if (_selectedAgent != null) {
      _agentEditors[_selectedAgent!] =
          GlobalKey<_AgentServerEditorDialogState>();
    }
    final providers = config.clientProviders;
    _filesystemRead = providers.filesystem.readTextFile;
    _filesystemWrite = providers.filesystem.writeTextFile;
    _filesystemOutside = providers.filesystem.allowReadOutsideWorkspace;
    _terminalEnabled = providers.terminal.enabled;
    _trustRules
      ..clear()
      ..addAll(providers.permissions.trustRules);
    final review = providers.permissions.reviewAgent;
    _reviewAgentEnabled = review.enabled;
    _reviewInlineMcpServer = review.mcpServer;
    _reviewTargetKind = review.mcpServer != null
        ? 'inline'
        : review.mcpServerName != null
        ? 'mcp'
        : 'agent';
    _reviewAgentServerNameController.text = review.agentServerName ?? '';
    _reviewServerNameController.text = review.mcpServerName ?? '';
    _reviewToolNameController.text = review.toolName;
    _reviewModelController.text = review.model ?? '';
    _reviewTimeoutController.text =
        review.timeout == const Duration(seconds: 10)
        ? ''
        : review.timeout.inMilliseconds.toString();
    final assistant = config.assistantAgent;
    _assistantEnabled = assistant.enabled;
    _assistantAgentName = assistant.agentName;
    _assistantModel = assistant.model;
    _assistantGenerateTitles = assistant.generateSessionTitles;
    _assistantSummarizeTurns = assistant.summarizeTurns;
    _assistantCollapseProcess = assistant.collapseExecutionProcess;
    _assistantFallbackTitleController.text = assistant.fallbackTitleCharacters
        .toString();
    _storageMaxSizeController.text = config.storage.maxSizeGb.toString();
    _storageRetentionController.text = config.storage.retentionDays.toString();
    _assistantModelLoadGeneration += 1;
    _assistantModelsLoading = false;
    _assistantModelOption = null;
    _assistantModelsError = null;
    _assistantValidationStatus = null;
    _error = null;
    _baselineSignature = _generalSignature;
    _restoring = false;
  }

  Future<bool> _confirmDiscard() async {
    if (!_hasChanges) return true;
    if (_saving || _confirmingExit) return false;
    _confirmingExit = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃未保存的更改？'),
        content: const Text('连接和各分类中的编辑都尚未写入配置文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃更改'),
          ),
        ],
      ),
    );
    _confirmingExit = false;
    return discard == true;
  }

  Future<void> _requestClose([SettingsExitAction? destination]) async {
    if (_saving || !await _confirmDiscard() || !mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(destination);
    });
  }

  Future<void> _discardChanges() async {
    if (_saving || !await _confirmDiscard() || !mounted) return;
    setState(() {
      _adoptConfig(_savedConfig);
      _saveStatus = '已放弃更改';
    });
  }

  Future<void> _save(BuildContext context) async {
    if (!_canSave) return;
    var failingSection = _section;
    try {
      final agents = <AgentServerConfig>[];
      final agentNames = <String, String>{};
      final mcpNames = <String, String>{};
      for (final original in _agentServers) {
        final editor = _agentEditors[original]?.currentState;
        final edited = editor == null ? original : editor.validatedServer();
        if (edited == null) {
          setState(() {
            _section = _SettingsSection.agents;
            _selectedAgent = original;
            _error = '请修正此 Agent 的启动配置。';
          });
          return;
        }
        if (original.name != edited.name) {
          agentNames[original.name] = edited.name;
        }
        agents.add(edited);
      }
      final mcps = <McpServerConfig>[];
      for (final original in _mcpServers) {
        final editor = _mcpEditors[original]?.currentState;
        final edited = editor == null ? original : editor.validatedServer();
        if (edited == null) {
          setState(() {
            _section = _SettingsSection.tools;
            _selectedMcp = original;
            _error = '请修正此 MCP 连接配置。';
          });
          return;
        }
        if (original.name != edited.name) mcpNames[original.name] = edited.name;
        mcps.add(edited);
      }
      failingSection = _SettingsSection.agents;
      if (agents.map((a) => a.name).toSet().length != agents.length) {
        throw const FormatException('Agent 名称不能重复。');
      }
      failingSection = _SettingsSection.tools;
      if (mcps.map((a) => a.name).toSet().length != mcps.length) {
        throw const FormatException('MCP 名称不能重复。');
      }
      failingSection = _SettingsSection.permissions;
      final providers = _clientProvidersConfig();
      failingSection = _SettingsSection.assistant;
      final assistant = _assistantAgentConfig();
      failingSection = _SettingsSection.storage;
      final storage = _storageConfig();
      final referenced = remapConfigurationReferences(
        AcpClientConfig(
          agentServers: List.unmodifiable(agents),
          mcpServers: List.unmodifiable(mcps),
          additionalDirectories: List.unmodifiable(_additionalDirectories),
          clientProviders: providers,
          storage: storage,
          assistantAgent: assistant,
          sessionTemplates: _savedConfig.sessionTemplates,
          configPath: widget.configPath,
          defaultAgentServerName: _defaultAgentName,
          defaultSessionTemplateId: _savedConfig.defaultSessionTemplateId,
        ),
        agentNames: agentNames,
        mcpNames: mcpNames,
      );
      final candidate = referenced.agentServers.isEmpty
          ? referenced
          : referenced.withActiveAgentServer(
              referenced.defaultAgentServerName ??
                  referenced.agentServers.first.name,
            );
      failingSection = _section;
      // Validate typed UI output too; injected writers must not bypass config contracts.
      final validated = AcpClientConfig.fromJson({
        if (candidate.defaultAgentServerName != null)
          'default_agent_server': candidate.defaultAgentServerName,
        'agent_servers': {
          for (final agent in candidate.agentServers)
            agent.name: agent.toJson(),
        },
        'mcp_servers': [for (final server in mcps) server.toJson()],
        'additional_directories': _additionalDirectories,
        'client_providers': candidate.clientProviders.toJson(),
        'storage': {
          'max_size_gb': storage.maxSizeGb,
          'retention_days': storage.retentionDays,
        },
        'assistant_agent': candidate.assistantAgent.toJson(),
        'session_templates': {
          for (final template in candidate.sessionTemplates)
            template.id: template.toJson(),
        },
        if (candidate.defaultSessionTemplateId != null)
          'default_session_template': candidate.defaultSessionTemplateId,
      });
      for (final template in validated.sessionTemplates) {
        validated.forSessionTemplate(template);
      }
      if (_runtimeBusy) {
        setState(() => _error = '会话仍在运行或切换，请完成操作后保存。');
        return;
      }
      setState(() {
        _saving = true;
        _error = null;
        _saveStatus = null;
      });
      final saved = await widget.onSaveConfig!(candidate);
      if (!context.mounted) return;
      setState(() {
        _saving = false;
        _activeAgentName = saved.agentName;
        _adoptConfig(saved);
        _saveStatus = '更改已保存';
      });
    } catch (error) {
      if (!context.mounted) return;
      setState(() {
        _saving = false;
        _section = failingSection;
        _error = error.toString().replaceFirst('FormatException: ', '');
      });
    }
  }

  Widget _buildDirectoriesSection() => _Panel(
    icon: Icons.folder_copy_outlined,
    title: '默认附加目录',
    trailing: TextButton.icon(
      onPressed: _saving ? null : _addDirectory,
      icon: const Icon(Icons.add_rounded),
      label: const Text('添加目录'),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SettingsHelp('提供给新会话的额外目录。会话模板可以覆盖此默认值；它们与 Agent 进程工作目录分别设置。'),
        const SizedBox(height: 24),
        if (_additionalDirectories.isEmpty) const _SettingsHelp('尚未添加目录。'),
        for (final directory in _additionalDirectories)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                const Icon(
                  Icons.folder_outlined,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SelectableText(
                    directory,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                _PanelActionButton(
                  tooltip: '移除目录 $directory',
                  icon: Icons.delete_outline_rounded,
                  onPressed: _saving ? null : () => _deleteDirectory(directory),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  bool get _connectionsHaveChanges =>
      !listEquals(_agentServers, _savedConfig.agentServers) ||
      _agentEditors.values.any((key) => key.currentState?.hasChanges ?? false);

  Widget _buildAssistantAgentSection() {
    final names = _agentServers
        .map((server) => server.name)
        .toList(growable: false);
    final selected = names.contains(_assistantAgentName)
        ? _assistantAgentName
        : null;
    return _Panel(
      icon: Icons.auto_awesome_outlined,
      title: 'AI 辅助',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SettingsHelp('使用独立的只读 Agent 生成会话标题和已完成轮次的摘要。'),
          const SizedBox(height: 16),
          _ConfigSwitch(
            key: const Key('assistant-agent-enabled-switch'),
            title: '启用 AI 辅助',
            value: _assistantEnabled,
            onChanged: (value) {
              setState(() {
                _assistantEnabled = value;
                _assistantValidationStatus = null;
                if (!value) {
                  _assistantModelLoadGeneration += 1;
                  _assistantModelsLoading = false;
                }
              });
              if (value) _loadAssistantAgentModels(_assistantAgentName);
            },
          ),
          if (_assistantEnabled) ...[
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              key: const Key('assistant-agent-name-field'),
              initialValue: selected,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '辅助 Agent'),
              items: [
                for (final name in names)
                  DropdownMenuItem(value: name, child: Text(name)),
              ],
              onChanged: (value) {
                setState(() {
                  _assistantAgentName = value;
                  _assistantModel = null;
                  _assistantModelOption = null;
                  _assistantModelsError = null;
                  _assistantValidationStatus = null;
                });
                _loadAssistantAgentModels(value);
              },
            ),
            const SizedBox(height: 20),
            _buildAssistantModelField(selected),
            const SizedBox(height: 16),
            if (_connectionsHaveChanges)
              const _SettingsHelp('Agent 连接有未保存的更改。请先保存，再加载模型或验证连接。'),
            OutlinedButton.icon(
              key: const Key('assistant-agent-validate-button'),
              onPressed:
                  _assistantValidating ||
                      _assistantModelsLoading ||
                      _connectionsHaveChanges ||
                      _runtimeBusy ||
                      widget.onValidateAssistantAgent == null
                  ? null
                  : _validateAssistantConfiguration,
              icon: _assistantValidating
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline_rounded, size: 18),
              label: Text(_assistantValidating ? '正在验证…' : '验证连接与模型'),
            ),
            if (_assistantValidationStatus case final status?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  status,
                  style: TextStyle(
                    fontSize: 13,
                    color: _assistantValidationSucceeded
                        ? AppColors.success
                        : AppColors.warning,
                  ),
                ),
              ),
            const Divider(height: 40, color: AppColors.border),
            _ConfigSwitch(
              key: const Key('assistant-session-title-switch'),
              title: '生成会话标题',
              value: _assistantGenerateTitles,
              onChanged: (value) =>
                  setState(() => _assistantGenerateTitles = value),
            ),
            _ConfigSwitch(
              key: const Key('assistant-turn-summary-switch'),
              title: '生成已完成轮次的摘要',
              value: _assistantSummarizeTurns,
              onChanged: (value) =>
                  setState(() => _assistantSummarizeTurns = value),
            ),
            _ConfigSwitch(
              key: const Key('assistant-collapse-process-switch'),
              title: '默认折叠已总结的执行过程',
              value: _assistantCollapseProcess,
              onChanged: !_assistantSummarizeTurns
                  ? null
                  : (value) =>
                        setState(() => _assistantCollapseProcess = value),
            ),
            const SizedBox(height: 16),
            const _SettingsHelp(
              '辅助 Agent 会收到首条提示和已完成轮次的内容，没有文件、终端或 MCP 工具权限。失败或超时时仍保留原始内容。',
            ),
          ],
          const Divider(height: 40, color: AppColors.border),
          const Text(
            '备用标题',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          const _SettingsHelp('未启用 AI 辅助或生成失败时，从首条提示截取标题。'),
          const SizedBox(height: 20),
          _SettingsField(
            key: const Key('assistant-title-character-limit-field'),
            controller: _assistantFallbackTitleController,
            label: '标题字数',
            hint: '8–128',
          ),
        ],
      ),
    );
  }

  Widget _buildAssistantModelField(String? selectedAgent) {
    final option = _assistantModelOption;
    final choicesByValue = <String, AcpConfigOptionChoice>{};
    for (final choice in option?.options ?? const <AcpConfigOptionChoice>[]) {
      if (choice.value.trim().isEmpty) continue;
      choicesByValue.putIfAbsent(choice.value, () => choice);
    }
    final choices = choicesByValue.values.toList(growable: false);
    final configuredModel = _trimmedOrNull(_assistantModel);
    final hasConfiguredChoice = configuredModel == null
        ? true
        : choices.any((choice) => choice.value == configuredModel);
    final selectedValue = configuredModel ?? '';
    final canSelect =
        _assistantEnabled &&
        selectedAgent != null &&
        !_assistantModelsLoading &&
        !_connectionsHaveChanges &&
        !_runtimeBusy &&
        widget.onLoadAssistantAgentModels != null &&
        choices.isNotEmpty;
    final defaultModelLabel = option?.currentChoiceLabel.trim();
    final defaultLabel = defaultModelLabel == null || defaultModelLabel.isEmpty
        ? '使用 Agent 默认模型'
        : '使用默认模型（$defaultModelLabel）';
    String? helperText;
    if (_assistantModelsLoading && selectedAgent != null) {
      helperText = '正在读取 $selectedAgent 提供的模型…';
    } else if (selectedAgent == null) {
      helperText = '选择辅助 Agent 后读取模型。';
    } else if (widget.onLoadAssistantAgentModels == null) {
      helperText = '当前无法读取 Agent 模型。';
    } else if (option == null && _assistantModelsError == null) {
      helperText = '此 Agent 未提供可选模型，将使用默认模型。';
    }

    return KeyedSubtree(
      key: const Key('assistant-agent-model-field'),
      child: DropdownButtonFormField<String>(
        key: ValueKey((selectedAgent, selectedValue, _assistantModelsLoading)),
        initialValue: selectedValue,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: '模型（可选）',
          prefixIcon: const Icon(Icons.memory_outlined),
          helperText: helperText,
          errorText: _assistantModelsError,
          errorMaxLines: 2,
          suffixIcon: _assistantModelsLoading
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : selectedAgent != null &&
                    _assistantEnabled &&
                    widget.onLoadAssistantAgentModels != null
              ? IconButton(
                  tooltip: 'Reload models from $selectedAgent',
                  onPressed: () => _loadAssistantAgentModels(selectedAgent),
                  icon: const Icon(Icons.refresh_rounded),
                )
              : null,
        ),
        items: <DropdownMenuItem<String>>[
          DropdownMenuItem(value: '', child: Text(defaultLabel)),
          if (configuredModel != null && !hasConfiguredChoice)
            DropdownMenuItem(
              value: configuredModel,
              child: Text('$configuredModel（已配置）'),
            ),
          for (final choice in choices)
            DropdownMenuItem(value: choice.value, child: Text(choice.label)),
        ],
        onChanged: canSelect
            ? (value) {
                setState(() {
                  _assistantModel = _trimmedOrNull(value);
                  _assistantValidationStatus = null;
                });
              }
            : null,
      ),
    );
  }

  Future<void> _loadAssistantAgentModels(String? agentName) async {
    final normalizedAgentName = _trimmedOrNull(agentName);
    final loader = widget.onLoadAssistantAgentModels;
    final generation = ++_assistantModelLoadGeneration;
    if (!_assistantEnabled ||
        _connectionsHaveChanges ||
        _runtimeBusy ||
        normalizedAgentName == null ||
        loader == null) {
      if (!mounted) return;
      setState(() {
        _assistantModelsLoading = false;
        _assistantModelOption = null;
        _assistantModelsError = null;
      });
      return;
    }
    setState(() {
      _assistantModelsLoading = true;
      _assistantModelOption = null;
      _assistantModelsError = null;
    });
    try {
      final option = await loader(normalizedAgentName);
      if (!mounted ||
          generation != _assistantModelLoadGeneration ||
          normalizedAgentName != _assistantAgentName?.trim()) {
        return;
      }
      setState(() {
        _assistantModelsLoading = false;
        _assistantModelOption = option;
      });
    } on Object catch (error) {
      if (!mounted || generation != _assistantModelLoadGeneration) return;
      setState(() {
        _assistantModelsLoading = false;
        _assistantModelOption = null;
        _assistantModelsError = error
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('Exception: ', '');
      });
    }
  }

  Widget _buildClientProvidersSection() => _Panel(
    icon: Icons.security_outlined,
    title: '权限与审查',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SettingsHelp(
          '应用向 Agent 提供的能力默认值。模板可覆盖这些设置；每次操作是否审批由当前会话的执行策略决定。',
        ),
        const SizedBox(height: 20),
        _ConfigSwitch(
          key: const Key('filesystem-read-switch'),
          title: '允许读取文本文件',
          value: _filesystemRead,
          onChanged: (value) => setState(() => _filesystemRead = value),
        ),
        _ConfigSwitch(
          key: const Key('filesystem-write-switch'),
          title: '允许写入文本文件',
          value: _filesystemWrite,
          onChanged: (value) => setState(() => _filesystemWrite = value),
        ),
        _ConfigSwitch(
          key: const Key('filesystem-outside-switch'),
          title: '允许读取工作区外的文件',
          value: _filesystemOutside,
          onChanged: (value) => setState(() => _filesystemOutside = value),
        ),
        _ConfigSwitch(
          key: const Key('terminal-enabled-switch'),
          title: '允许使用终端',
          value: _terminalEnabled,
          onChanged: (value) => setState(() => _terminalEnabled = value),
        ),
        const Divider(height: 40, color: AppColors.border),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '信任规则 · ${_trustRules.length}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            TextButton.icon(
              onPressed: _saving ? null : _addTrustRule,
              icon: const Icon(Icons.add_rounded),
              label: const Text('添加规则'),
            ),
          ],
        ),
        const _SettingsHelp('匹配工具名称和类型的请求可按规则直接允许或拒绝。'),
        for (final rule in _trustRules)
          Row(
            children: [
              Expanded(
                child: Text(
                  _permissionTrustRuleLabel(rule),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              _PanelActionButton(
                tooltip: '移除规则 ${rule.toolName}',
                icon: Icons.delete_outline_rounded,
                onPressed: _saving ? null : () => _deleteTrustRule(rule),
              ),
            ],
          ),
        const Divider(height: 40, color: AppColors.border),
        const Text(
          '自动审查来源',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        const _SettingsHelp(
          '当输入区的执行策略设为 Auto Review 时使用。默认由当前 Agent 的独立审查会话处理。',
        ),
        _ConfigSwitch(
          key: const Key('review-agent-enabled-switch'),
          title: '使用指定审查来源',
          value: _reviewAgentEnabled,
          onChanged: (value) => setState(() => _reviewAgentEnabled = value),
        ),
        if (_reviewAgentEnabled) ...[
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: const Key('review-target-kind'),
            initialValue: _reviewTargetKind,
            decoration: const InputDecoration(labelText: '来源类型'),
            items: [
              const DropdownMenuItem(
                value: 'agent',
                child: Text('已配置的 ACP Agent'),
              ),
              const DropdownMenuItem(value: 'mcp', child: Text('已配置的 MCP 服务器')),
              if (_reviewInlineMcpServer != null)
                const DropdownMenuItem(
                  value: 'inline',
                  child: Text('配置文件中的内嵌 MCP'),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _reviewTargetKind = value;
                if (value != 'agent') _reviewAgentServerNameController.clear();
                if (value != 'mcp') _reviewServerNameController.clear();
              });
            },
          ),
          const SizedBox(height: 20),
          if (_reviewTargetKind == 'agent')
            _SettingsField(
              key: const Key('review-agent-server-name-field'),
              controller: _reviewAgentServerNameController,
              label: 'Agent 名称',
            ),
          if (_reviewTargetKind == 'mcp')
            _SettingsField(
              key: const Key('review-mcp-server-name-field'),
              controller: _reviewServerNameController,
              label: 'MCP 名称',
            ),
          if (_reviewTargetKind == 'inline')
            _SettingsHelp(
              '保留已有内嵌 MCP：${_reviewInlineMcpServer?.name ?? ""}。选择其他来源后保存会替换它。',
            ),
          if (_reviewTargetKind != 'agent') ...[
            const SizedBox(height: 20),
            _SettingsField(
              key: const Key('review-tool-name-field'),
              controller: _reviewToolNameController,
              label: '审查工具',
            ),
          ],
          const SizedBox(height: 20),
          _SettingsField(
            key: const Key('review-model-field'),
            controller: _reviewModelController,
            label: '审查模型',
            hint: '可选',
          ),
          const SizedBox(height: 20),
          _SettingsField(
            key: const Key('review-timeout-field'),
            controller: _reviewTimeoutController,
            label: '超时（毫秒）',
            hint: '默认 10000',
          ),
        ],
      ],
    ),
  );

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

  Widget _buildStorageSection() => _Panel(
    icon: Icons.storage_outlined,
    title: '本地恢复存储',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SettingsHelp('以下上限和保留期分别应用于会话恢复数据库、对话缓存。到期的本地恢复数据会自动清理。'),
        const SizedBox(height: 28),
        _SettingsField(
          key: const Key('storage-max-size-gb-field'),
          controller: _storageMaxSizeController,
          label: '每库上限（GB）',
        ),
        const SizedBox(height: 24),
        _SettingsField(
          key: const Key('storage-retention-days-field'),
          controller: _storageRetentionController,
          label: '保留天数',
        ),
        const SizedBox(height: 24),
        const _SettingsHelp('此处不是整个应用的磁盘占用上限，也不会删除 Agent 服务端的会话。'),
      ],
    ),
  );

  SqliteStorageConfig _storageConfig() {
    final maxSize = _positiveIntValue(
      _storageMaxSizeController.text,
      'Local recovery storage limit',
    );
    final retention = _positiveIntValue(
      _storageRetentionController.text,
      'Storage retention',
    );
    if (maxSize > 8192) {
      throw const FormatException(
        'Local recovery storage limit must be at most 8192 GB.',
      );
    }
    if (retention > 3650) {
      throw const FormatException(
        'Storage retention must be at most 3650 days.',
      );
    }
    return SqliteStorageConfig(maxSizeGb: maxSize, retentionDays: retention);
  }

  AssistantAgentConfig _assistantAgentConfig() {
    final fallbackTitleCharacters = _positiveIntValue(
      _assistantFallbackTitleController.text,
      'Assistant fallback title characters',
    );
    if (fallbackTitleCharacters <
            AssistantAgentConfig.minimumFallbackTitleCharacters ||
        fallbackTitleCharacters >
            AssistantAgentConfig.maximumFallbackTitleCharacters) {
      throw const FormatException(
        'Assistant fallback title characters must be between 8 and 128.',
      );
    }
    final agentName = _assistantAgentName?.trim();
    if (_assistantEnabled &&
        (agentName == null ||
            !_agentServers.any((server) => server.name == agentName))) {
      throw const FormatException(
        'Choose a configured agent for Assistant Agent.',
      );
    }
    return AssistantAgentConfig(
      enabled: _assistantEnabled,
      agentName: agentName,
      model: _trimmedOrNull(_assistantModel),
      generateSessionTitles: _assistantGenerateTitles,
      summarizeTurns: _assistantSummarizeTurns,
      collapseExecutionProcess: _assistantCollapseProcess,
      fallbackTitleCharacters: fallbackTitleCharacters,
      timeout: widget.assistantAgent.timeout,
    );
  }

  Future<void> _validateAssistantConfiguration() async {
    if (_connectionsHaveChanges || _runtimeBusy) return;
    AssistantAgentConfig config;
    try {
      config = _assistantAgentConfig();
    } on Object catch (error) {
      setState(() {
        _assistantValidationSucceeded = false;
        _assistantValidationStatus = error.toString().replaceFirst(
          'FormatException: ',
          '',
        );
      });
      return;
    }
    final validator = widget.onValidateAssistantAgent;
    if (validator == null) {
      setState(() {
        _assistantValidationSucceeded = false;
        _assistantValidationStatus = '当前无法验证连接';
      });
      return;
    }
    setState(() {
      _assistantValidating = true;
      _assistantValidationSucceeded = false;
      _assistantValidationStatus = null;
    });
    final validationSignature = jsonEncode(config.toJson());
    final validationGeneration = _assistantModelLoadGeneration;
    bool isCurrent() =>
        mounted &&
        validationGeneration == _assistantModelLoadGeneration &&
        validationSignature == jsonEncode(_assistantAgentConfig().toJson());
    try {
      await validator(config);
      if (!isCurrent()) return;
      setState(() {
        _assistantValidationSucceeded = true;
        _assistantValidationStatus = '连接与模型验证通过';
      });
    } on Object catch (error) {
      if (!mounted || validationGeneration != _assistantModelLoadGeneration) {
        return;
      }
      setState(() {
        _assistantValidationSucceeded = false;
        _assistantValidationStatus = error.toString().replaceFirst(
          'Bad state: ',
          '',
        );
      });
    } finally {
      if (mounted) setState(() => _assistantValidating = false);
    }
  }

  AcpPermissionReviewAgentConfig _reviewAgentConfig() {
    final mcpServerName = _trimmedOrNull(_reviewServerNameController.text);
    final agentServerName = _trimmedOrNull(
      _reviewAgentServerNameController.text,
    );
    if (mcpServerName != null && agentServerName != null) {
      throw const FormatException(
        'Choose either a review ACP agent or a review MCP server, not both.',
      );
    }
    return AcpPermissionReviewAgentConfig(
      enabled: _reviewAgentEnabled,
      mcpServer:
          mcpServerName == null &&
              agentServerName == null &&
              (!_reviewAgentEnabled || _reviewTargetKind == 'inline')
          ? _reviewInlineMcpServer
          : null,
      mcpServerName: mcpServerName,
      agentServerName: agentServerName,
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

  void _selectAgent(AgentServerConfig server) {
    setState(() {
      _selectedAgent = server;
      _agentEditors.putIfAbsent(
        server,
        () => GlobalKey<_AgentServerEditorDialogState>(),
      );
    });
  }

  void _addAgent() {
    final preset = widget.agentPresets
        .where((p) => !_agentServers.any((a) => a.name == p.name))
        .firstOrNull;
    var name = preset?.name ?? '新 Agent';
    var suffix = 2;
    while (_agentServers.any((a) => a.name == name)) {
      name = '新 Agent ${suffix++}';
    }
    final server = AgentServerConfig(
      name: name,
      type: preset?.type ?? 'custom',
      command: preset?.command ?? '',
      args: preset?.args ?? const [],
      cwd: preset?.cwd,
      env: preset?.env ?? const {},
    );
    setState(() {
      _agentServers.add(server);
      _defaultAgentName ??= server.name;
      _selectedAgent = server;
      _agentEditors[server] = GlobalKey<_AgentServerEditorDialogState>();
      _error = null;
      _saveStatus = null;
    });
  }

  void _deleteAgent(AgentServerConfig server) {
    if (server.name == _activeAgentName) return;
    setState(() {
      _agentServers.remove(server);
      _agentEditors.remove(server);
      if (_defaultAgentName == server.name) {
        _defaultAgentName = _agentServers.firstOrNull?.name;
      }
      _selectedAgent = _agentServers.firstOrNull;
      if (_selectedAgent != null) {
        _agentEditors.putIfAbsent(
          _selectedAgent!,
          () => GlobalKey<_AgentServerEditorDialogState>(),
        );
      }
      _error = null;
    });
  }

  void _selectMcp(McpServerConfig server) {
    setState(() {
      _selectedMcp = server;
      _mcpEditors.putIfAbsent(
        server,
        () => GlobalKey<_McpServerEditorDialogState>(),
      );
    });
  }

  void _addMcpServer() {
    var name = '新 MCP';
    var suffix = 2;
    while (_mcpServers.any((m) => m.name == name)) {
      name = '新 MCP ${suffix++}';
    }
    final server = McpServerConfig(
      raw: {'name': name, 'type': 'stdio', 'command': ''},
    );
    setState(() {
      _mcpServers.add(server);
      _selectedMcp = server;
      _mcpEditors[server] = GlobalKey<_McpServerEditorDialogState>();
      _error = null;
      _saveStatus = null;
    });
  }

  void _deleteMcpServer(McpServerConfig server) {
    setState(() {
      _mcpServers.remove(server);
      _mcpEditors.remove(server);
      _selectedMcp = null;
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
  final ValueChanged<bool>? onChanged;

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
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0,
          ),
        ),
        subtitle: Text(
          value ? '已开启' : '已关闭',
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
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
      title: const Text('添加附加目录'),
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
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('添加到草稿')),
      ],
    );
  }

  void _submit() {
    final path = _pathController.text.trim();
    if (path.isEmpty || !path.startsWith('/')) {
      setState(() => _error = '请输入绝对目录路径。');
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
      title: const Text('添加信任规则'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DialogTextField(
              key: const Key('trust-tool-name-field'),
              controller: _toolNameController,
              label: '工具名称',
              icon: Icons.build_outlined,
            ),
            const SizedBox(height: 10),
            _DialogTextField(
              key: const Key('trust-tool-kind-field'),
              controller: _toolKindController,
              label: '工具类型（可选）',
              icon: Icons.category_outlined,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<AcpPermissionDecision>(
              key: const Key('trust-decision-field'),
              initialValue: _decision,
              decoration: _fieldDecoration(
                label: '规则结果',
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
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('添加到草稿')),
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

class _DialogTextField extends StatelessWidget {
  const _DialogTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
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
  final String title, addLabel, itemPrefix;
  final List<TextEditingController> controllers;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final fields = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < controllers.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      label: '$title ${index + 1}',
                      child: TextField(
                        key: Key('$itemPrefix-$index-field'),
                        controller: controllers[index],
                        style: const TextStyle(fontSize: 14),
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _PanelActionButton(
                    tooltip: '移除$title ${index + 1}',
                    icon: Icons.close_rounded,
                    onPressed: () => onRemove(index),
                  ),
                ],
              ),
            ),
          TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(addLabel),
          ),
        ],
      );
      final label = Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      );
      if (bounds.maxWidth < 440) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [label, const SizedBox(height: 10), fields],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 94, child: label),
          const SizedBox(width: 16),
          Expanded(child: fields),
        ],
      );
    },
  );
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
  final String title, addLabel;
  final VoidCallback onAdd;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
          TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: Text(addLabel),
          ),
        ],
      ),
      if (children.isNotEmpty) ...[const SizedBox(height: 10), ...children],
    ],
  );
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
        fontWeight: FontWeight.w600,
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

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

int _positiveIntValue(String value, String label) {
  final parsed = int.tryParse(value.trim());
  if (parsed == null || parsed <= 0) {
    throw FormatException('$label must be a positive integer.');
  }
  return parsed;
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

Set<String> _dirtyNameValueKeys(List<_NameValueControllers> controllers) {
  return Set.unmodifiable(<String>{
    for (final controllers in controllers)
      if (controllers.isDirty &&
          controllers.nameController.text.trim().isNotEmpty)
        controllers.nameController.text.trim(),
  });
}

List<_NameValueControllers> _nameValueControllersFromList(
  List raw, {
  Set<String> initiallyDirtyKeys = const <String>{},
}) {
  return [
    for (final entry in raw)
      if (entry is Map && entry['name'] is String && entry['value'] is String)
        _NameValueControllers(
          name: entry['name'] as String,
          value: entry['value'] as String,
          initiallyDirty: initiallyDirtyKeys.contains(entry['name']),
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

class _ConfigPathPanel extends StatelessWidget {
  const _ConfigPathPanel({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      icon: Icons.description_outlined,
      title: '配置文件',
      child: SelectableText(
        path == null || path!.isEmpty ? '未提供可写配置路径' : path!,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.icon,
    required this.title,
    required this.child,
    this.trailing,
  });
  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: AppColors.textSecondary),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          ?trailing,
        ],
      ),
      const SizedBox(height: 26),
      child,
    ],
  );
}

class _SettingsHelp extends StatelessWidget {
  const _SettingsHelp(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: AppColors.textSecondary,
      fontSize: 13,
      height: 1.6,
    ),
  );
}
