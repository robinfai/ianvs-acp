part of 'agent_config_dialog.dart';

class _AgentServerEditorDialog extends StatefulWidget {
  const _AgentServerEditorDialog({
    super.key,
    this.initialServer,
    this.onChanged,
    this.presets = const <AgentServerConfig>[],
  });

  final AgentServerConfig? initialServer;
  final VoidCallback? onChanged;
  final List<AgentServerConfig> presets;

  @override
  State<_AgentServerEditorDialog> createState() =>
      _AgentServerEditorDialogState();
}

class _AgentServerEditorDialogState extends State<_AgentServerEditorDialog> {
  static const String _customPreset = '__custom__';

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
  final List<TextEditingController> _argControllers = [];
  final List<_NameValueControllers> _envControllers = [];
  final List<_NameValueControllers> _headerControllers = [];
  late String _selectedPreset = _initialPresetName();
  String? _error;

  bool get _isRemote => !AgentServerConfig(name: '', type: _type).isStdio;

  final Set<TextEditingController> _watchedFields = {};
  late String _initialDraftSignature;

  Iterable<TextEditingController> get _fields => [
    _nameController,
    _commandController,
    _cwdController,
    _urlController,
    ..._argControllers,
    for (final row in [..._envControllers, ..._headerControllers]) ...[
      row.nameController,
      row.valueController,
    ],
  ];

  String get _draftSignature => jsonEncode([
    _type,
    for (final field in _fields) field.text,
    for (final row in _envControllers) row.isDirty,
    for (final row in _headerControllers) row.isDirty,
  ]);

  bool get hasChanges => _draftSignature != _initialDraftSignature;

  void _watchFields() {
    for (final field in _fields) {
      if (_watchedFields.add(field)) field.addListener(_fieldChanged);
    }
  }

  void _fieldChanged() => setState(() {});

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _watchFields();
    widget.onChanged?.call();
  }

  void _finishInitialization() {
    _initialDraftSignature = _draftSignature;
    _watchFields();
  }

  @override
  void initState() {
    super.initState();
    final server = widget.initialServer;
    if (server == null) {
      if (widget.presets.isNotEmpty) _applyPreset(widget.presets.first);
      _finishInitialization();
      return;
    }
    _argControllers.addAll(
      server.args.map((arg) => TextEditingController(text: arg)),
    );
    _envControllers.addAll(
      server.env.entries.map(
        (entry) => _NameValueControllers(
          name: entry.key,
          value: entry.value,
          initiallyDirty: server.explicitEnvKeys.contains(entry.key),
        ),
      ),
    );
    _headerControllers.addAll(
      server.headers.entries.map(
        (entry) => _NameValueControllers(
          name: entry.key,
          value: entry.value,
          initiallyDirty: server.explicitHeaderKeys.contains(entry.key),
        ),
      ),
    );
    _finishInitialization();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _commandController.dispose();
    _cwdController.dispose();
    _urlController.dispose();
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.presets.isNotEmpty) ...[
          DropdownButtonFormField<String>(
            key: const Key('agent-preset-field'),
            isExpanded: true,
            initialValue: _selectedPreset,
            decoration: _fieldDecoration(
              label: '连接预设',
              icon: Icons.smart_toy_outlined,
            ),
            items: [
              for (final preset in widget.presets)
                DropdownMenuItem(value: preset.name, child: Text(preset.name)),
              const DropdownMenuItem(
                value: _customPreset,
                child: Text('自定义连接'),
              ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _selectedPreset = value;
                final preset = _presetNamed(value);
                if (preset != null) _applyPreset(preset);
                _error = null;
              });
            },
          ),
          const SizedBox(height: 24),
        ],
        const Text(
          '启动配置',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 24),
        _SettingsField(
          key: const Key('agent-name-field'),
          controller: _nameController,
          label: '名称',
        ),
        const SizedBox(height: 22),
        if (_isRemote) ...[
          const _InlineError(message: '远程 ACP 当前不可用。保留此配置以兼容已有文件；请使用本地进程创建会话。'),
          const SizedBox(height: 16),
          _SettingsField(
            key: const Key('agent-url-field'),
            controller: _urlController,
            label: '连接 URL',
          ),
        ] else ...[
          _SettingsField(
            key: const Key('agent-command-field'),
            controller: _commandController,
            label: '启动命令',
          ),
          const SizedBox(height: 22),
          _StringListEditor(
            title: '启动参数',
            addLabel: '添加参数',
            itemPrefix: 'agent-arg',
            controllers: _argControllers,
            onAdd: () =>
                setState(() => _argControllers.add(TextEditingController())),
            onRemove: (i) =>
                setState(() => _argControllers.removeAt(i).dispose()),
          ),
        ],
        const SizedBox(height: 28),
        const Divider(height: 1, color: AppColors.border),
        ExpansionTile(
          key: const Key('agent-advanced-settings'),
          controlAffinity: ListTileControlAffinity.leading,
          shape: const Border(),
          collapsedShape: const Border(),
          initiallyExpanded: true,
          maintainState: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 24),
          title: const Text(
            '高级设置',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          children: [
            if (!_isRemote) ...[
              _SettingsField(
                key: const Key('agent-cwd-field'),
                controller: _cwdController,
                label: '启动工作目录',
                hint: '可选',
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8, bottom: 24),
                child: Text(
                  'Agent 进程的启动目录，留空使用默认值；会话工作区在新建会话时选择。',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
              _NameValueListEditor(
                title: '环境变量',
                addLabel: '添加变量',
                itemPrefix: 'agent-env',
                controllers: _envControllers,
                onAdd: () => setState(
                  () => _envControllers.add(
                    _NameValueControllers(initiallyDirty: true),
                  ),
                ),
                onRemove: (i) =>
                    setState(() => _envControllers.removeAt(i).dispose()),
              ),
            ] else
              _NameValueListEditor(
                title: '请求头',
                addLabel: '添加请求头',
                itemPrefix: 'agent-header',
                controllers: _headerControllers,
                onAdd: () => setState(
                  () => _headerControllers.add(
                    _NameValueControllers(initiallyDirty: true),
                  ),
                ),
                onRemove: (i) =>
                    setState(() => _headerControllers.removeAt(i).dispose()),
              ),
            const SizedBox(height: 24),
            DropdownButtonFormField<String>(
              key: const Key('agent-type-field'),
              isExpanded: true,
              initialValue: _type,
              decoration: _fieldDecoration(
                label: '连接类型',
                icon: Icons.cable_rounded,
              ),
              items: [
                const DropdownMenuItem(
                  value: 'custom',
                  child: Text('本地进程 · custom'),
                ),
                const DropdownMenuItem(
                  value: 'stdio',
                  child: Text('本地进程 · stdio'),
                ),
                if (_type != 'custom' && _type != 'stdio')
                  DropdownMenuItem(
                    value: _type,
                    enabled: false,
                    child: Text(
                      _isRemote ? '$_type（已有配置，当前不可用）' : '本地进程 · $_type',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _type = value;
                    _selectedPreset = _customPreset;
                    _error = null;
                  });
                }
              },
            ),
            if (widget.initialServer?.permissionReviewAgent.isConfigured ==
                true) ...[
              const SizedBox(height: 24),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '此连接的审查覆盖',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: _SettingsHelp(
                  '${widget.initialServer!.permissionReviewAgent.displayTarget} · 模型：${widget.initialServer!.permissionReviewAgent.model ?? "继承默认"}',
                ),
              ),
              const SizedBox(height: 6),
              const _SettingsHelp('此连接保留独立的审查覆盖；具体字段以配置文件为准。应用级默认值在“权限”中设置。'),
            ],
          ],
        ),
        if (_error != null) _InlineError(message: _error!),
      ],
    );
  }

  String _initialPresetName() {
    final initial = widget.initialServer;
    if (initial != null) {
      for (final preset in widget.presets) {
        if (_sameAgentTarget(initial, preset)) return preset.name;
      }
      return _customPreset;
    }
    return widget.presets.isEmpty ? _customPreset : widget.presets.first.name;
  }

  AgentServerConfig? _presetNamed(String name) {
    for (final preset in widget.presets) {
      if (preset.name == name) return preset;
    }
    return null;
  }

  void _applyPreset(AgentServerConfig preset) {
    _type = preset.type;
    _nameController.text = preset.name;
    _commandController.text = preset.command;
    _cwdController.text = preset.cwd ?? '';
    _urlController.text = preset.url;
    for (final controller in _argControllers) {
      controller.dispose();
    }
    _argControllers
      ..clear()
      ..addAll(preset.args.map((arg) => TextEditingController(text: arg)));
    for (final controllers in _envControllers) {
      controllers.dispose();
    }
    _envControllers
      ..clear()
      ..addAll(
        preset.env.entries.map(
          (entry) => _NameValueControllers(name: entry.key, value: entry.value),
        ),
      );
    for (final controllers in _headerControllers) {
      controllers.dispose();
    }
    _headerControllers
      ..clear()
      ..addAll(
        preset.headers.entries.map(
          (entry) => _NameValueControllers(name: entry.key, value: entry.value),
        ),
      );
  }

  AgentServerConfig? validatedServer() {
    try {
      final json = <String, dynamic>{
        ...?widget.initialServer?.additionalProperties,
        if (widget.initialServer case final initial?) ...{
          'persistence_id': initial.persistenceIdentity,
          'persistence_aliases': initial.persistenceNames,
        },
        'type': _type,
      };
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
      final server = AgentServerConfig.fromJson(
        name: _nameController.text.trim(),
        json: json,
      );
      final initial = widget.initialServer;
      if (initial == null) {
        return server;
      }
      final sameIdentity = initial.name == server.name;
      final initialReview = initial.permissionReviewAgent;
      final inlineReviewServer = initialReview.mcpServer;
      final review = sameIdentity || inlineReviewServer == null
          ? initialReview
          : AcpPermissionReviewAgentConfig(
              enabled: initialReview.enabled,
              mcpServer: inlineReviewServer.withSecrets(
                env: inlineReviewServer.env,
                headers: inlineReviewServer.headers,
                envRefs: const <String, String>{},
                headerRefs: const <String, String>{},
              ),
              mcpServerName: initialReview.mcpServerName,
              agentServerName: initialReview.agentServerName,
              toolName: initialReview.toolName,
              model: initialReview.model,
              timeout: initialReview.timeout,
            );
      return server.withSecrets(
        env: server.env,
        headers: server.headers,
        envRefs: sameIdentity
            ? {
                for (final key in server.env.keys)
                  if (initial.envRefs[key] != null) key: initial.envRefs[key]!,
              }
            : const <String, String>{},
        headerRefs: sameIdentity
            ? {
                for (final key in server.headers.keys)
                  if (initial.headerRefs[key] != null)
                    key: initial.headerRefs[key]!,
              }
            : const <String, String>{},
        explicitEnvKeys: _dirtyNameValueKeys(_envControllers),
        explicitHeaderKeys: _dirtyNameValueKeys(_headerControllers),
        permissionReviewAgent: review,
      );
    } catch (error) {
      setState(() => _error = '$error');
      return null;
    }
  }
}

class _McpServerEditorDialog extends StatefulWidget {
  const _McpServerEditorDialog({super.key, this.initialServer, this.onChanged});

  final McpServerConfig? initialServer;
  final VoidCallback? onChanged;

  @override
  State<_McpServerEditorDialog> createState() => _McpServerEditorDialogState();
}

bool _sameAgentTarget(AgentServerConfig left, AgentServerConfig right) {
  if (left.type != right.type) return false;
  if (left.command.trim() != right.command.trim()) return false;
  if (left.url.trim() != right.url.trim()) return false;
  if (left.args.length != right.args.length) return false;
  for (var index = 0; index < left.args.length; index += 1) {
    if (left.args[index] != right.args[index]) return false;
  }
  return true;
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

  final Set<TextEditingController> _watchedFields = {};
  late String _initialDraftSignature;

  Iterable<TextEditingController> get _fields => [
    _nameController,
    _commandController,
    _urlController,
    _idController,
    ..._argControllers,
    for (final row in [..._envControllers, ..._headerControllers]) ...[
      row.nameController,
      row.valueController,
    ],
  ];

  String get _draftSignature => jsonEncode([
    _type,
    for (final field in _fields) field.text,
    for (final row in _envControllers) row.isDirty,
    for (final row in _headerControllers) row.isDirty,
  ]);

  bool get hasChanges => _draftSignature != _initialDraftSignature;

  void _watchFields() {
    for (final field in _fields) {
      if (_watchedFields.add(field)) field.addListener(_fieldChanged);
    }
  }

  void _fieldChanged() => setState(() {});

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _watchFields();
    widget.onChanged?.call();
  }

  void _finishInitialization() {
    _initialDraftSignature = _draftSignature;
    _watchFields();
  }

  @override
  void initState() {
    super.initState();
    final raw = widget.initialServer?.raw;
    if (raw == null) {
      _finishInitialization();
      return;
    }
    final args = raw['args'];
    if (args is List) {
      _argControllers.addAll(
        args.whereType<String>().map((arg) => TextEditingController(text: arg)),
      );
    }
    final env = raw['env'];
    if (env is List) {
      _envControllers.addAll(
        _nameValueControllersFromList(
          env,
          initiallyDirtyKeys:
              widget.initialServer?.explicitEnvKeys ?? const <String>{},
        ),
      );
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
                initiallyDirty:
                    widget.initialServer?.explicitHeaderKeys.contains(
                      entry.key,
                    ) ??
                    false,
              ),
            ),
      );
    } else if (headers is List) {
      _headerControllers.addAll(
        _nameValueControllersFromList(
          headers,
          initiallyDirtyKeys:
              widget.initialServer?.explicitHeaderKeys ?? const <String>{},
        ),
      );
    }
    _finishInitialization();
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DialogTextField(
          key: const Key('mcp-name-field'),
          controller: _nameController,
          label: '名称',
          icon: Icons.extension_outlined,
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          key: const Key('mcp-type-field'),
          initialValue: _type,
          decoration: _fieldDecoration(
            label: '连接类型',
            icon: Icons.cable_rounded,
          ),
          items: [
            const DropdownMenuItem(value: 'stdio', child: Text('stdio')),
            const DropdownMenuItem(value: 'http', child: Text('http')),
            const DropdownMenuItem(value: 'sse', child: Text('sse')),
            if (_type == 'acp')
              const DropdownMenuItem(
                value: 'acp',
                enabled: false,
                child: Text('acp (unavailable)'),
              ),
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
          const Text(
            'MCP-over-ACP is unavailable. This saved entry is retained; use stdio, HTTP or SSE for active sessions.',
          ),
          const SizedBox(height: 10),
          _DialogTextField(
            key: const Key('mcp-id-field'),
            controller: _idController,
            label: 'Server ID',
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
            title: '请求头',
            addLabel: '添加请求头',
            itemPrefix: 'mcp-header',
            controllers: _headerControllers,
            onAdd: () => setState(() {
              _headerControllers.add(
                _NameValueControllers(initiallyDirty: true),
              );
            }),
            onRemove: (index) => setState(() {
              _headerControllers.removeAt(index).dispose();
            }),
          ),
        ] else ...[
          _DialogTextField(
            key: const Key('mcp-command-field'),
            controller: _commandController,
            label: '启动命令',
            icon: Icons.terminal_rounded,
          ),
          const SizedBox(height: 10),
          _StringListEditor(
            title: '启动参数',
            addLabel: '添加参数',
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
            title: '环境变量',
            addLabel: '添加变量',
            itemPrefix: 'mcp-env',
            controllers: _envControllers,
            onAdd: () => setState(() {
              _envControllers.add(_NameValueControllers(initiallyDirty: true));
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
    );
  }

  McpServerConfig? validatedServer() {
    try {
      final raw = <String, dynamic>{
        for (final entry
            in widget.initialServer?.raw.entries ??
                const <MapEntry<String, dynamic>>[])
          if (!_mcpEditorManagedKeys.contains(entry.key))
            entry.key: entry.value,
        'name': _nameController.text,
        'type': _type,
      };
      if (_type == 'acp') {
        raw['serverId'] = _idController.text;
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
      final initial = widget.initialServer;
      if (initial == null) {
        return server;
      }
      final sameIdentity = initial.name == server.name;
      final env = <String, String>{
        for (final item in _nameValueEntries(_envControllers))
          item['name']!: item['value']!,
      };
      final headers = <String, String>{
        for (final item in _nameValueEntries(_headerControllers))
          item['name']!: item['value']!,
      };
      return server.withSecrets(
        env: env,
        headers: headers,
        envRefs: {
          for (final key in env.keys)
            if (sameIdentity && initial.envRefs[key] != null)
              key: initial.envRefs[key]!,
        },
        headerRefs: {
          for (final key in headers.keys)
            if (sameIdentity && initial.headerRefs[key] != null)
              key: initial.headerRefs[key]!,
        },
        explicitEnvKeys: _dirtyNameValueKeys(_envControllers),
        explicitHeaderKeys: _dirtyNameValueKeys(_headerControllers),
      );
    } catch (error) {
      setState(() => _error = '$error');
      return null;
    }
  }
}

const Set<String> _mcpEditorManagedKeys = <String>{
  'name',
  'type',
  'command',
  'url',
  'id',
  'args',
  'env',
  'headers',
  'env_refs',
  'envRefs',
  'header_refs',
  'headerRefs',
};

class _NameValueControllers {
  _NameValueControllers({
    String name = '',
    String value = '',
    bool initiallyDirty = false,
  }) : nameController = TextEditingController(text: name),
       valueController = TextEditingController(text: value),
       _dirty = initiallyDirty {
    _dirtyListener = () => _dirty = true;
    nameController.addListener(_dirtyListener);
    valueController.addListener(_dirtyListener);
  }

  final TextEditingController nameController;
  final TextEditingController valueController;
  late final VoidCallback _dirtyListener;
  bool _dirty;

  bool get isDirty => _dirty;

  void dispose() {
    nameController.removeListener(_dirtyListener);
    valueController.removeListener(_dirtyListener);
    nameController.dispose();
    valueController.dispose();
  }
}
