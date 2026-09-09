part of 'agent_config_dialog.dart';

enum SettingsExitAction { newSession, diagnostics }

enum _SettingsSection {
  agents('Agent', Icons.smart_toy_outlined),
  tools('工具与目录', Icons.folder_open_outlined),
  permissions('权限', Icons.shield_outlined),
  assistant('AI 助手', Icons.auto_awesome_outlined),
  storage('本地存储', Icons.storage_rounded);

  const _SettingsSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

extension _SettingsPageLayout on _AgentConfigDialogState {
  Widget _buildSettingsPage(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.runtimeBusy ?? const AlwaysStoppedAnimation(false),
      builder: (context, _) => PopScope(
        canPop: _allowPop || (!_hasChanges && !_saving),
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && !_saving) _requestClose();
        },
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () {
              if (_canSave) _save(context);
            },
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                _requestClose(),
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: AppColors.surface,
              body: SafeArea(
                child: LayoutBuilder(
                  builder: (context, bounds) {
                    final wide = bounds.maxWidth >= 1000;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (wide) ...[
                          SizedBox(
                            width: 268,
                            child: _buildSettingsNavigation(),
                          ),
                          const VerticalDivider(
                            width: 1,
                            color: AppColors.border,
                          ),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildSettingsHeader(wide),
                              if (!wide)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    0,
                                    20,
                                    12,
                                  ),
                                  child:
                                      DropdownButtonFormField<_SettingsSection>(
                                        key: const Key(
                                          'settings-section-picker',
                                        ),
                                        initialValue: _section,
                                        isExpanded: true,
                                        decoration: const InputDecoration(
                                          labelText: '设置分类',
                                        ),
                                        items: [
                                          for (final section
                                              in _SettingsSection.values)
                                            DropdownMenuItem(
                                              value: section,
                                              child: Text(section.label),
                                            ),
                                        ],
                                        onChanged: _saving
                                            ? null
                                            : (value) {
                                                if (value != null) {
                                                  _change(
                                                    () => _section = value,
                                                  );
                                                }
                                              },
                                      ),
                                ),
                              if (_error != null)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    0,
                                    24,
                                    12,
                                  ),
                                  child: _ErrorPanel(message: _error!),
                                ),
                              const Divider(height: 1, color: AppColors.border),
                              Expanded(
                                child: IndexedStack(
                                  index: _section.index,
                                  children: [
                                    _buildAgentSettings(),
                                    _buildToolSettings(),
                                    _settingsScroll(
                                      _buildClientProvidersSection(),
                                    ),
                                    _settingsScroll(
                                      _buildAssistantAgentSection(),
                                    ),
                                    _settingsScroll(
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          _buildStorageSection(),
                                          const SizedBox(height: 32),
                                          _ConfigPathPanel(
                                            path: widget.configPath,
                                          ),
                                          if (_savedConfig
                                              .sessionTemplates
                                              .isNotEmpty) ...[
                                            const SizedBox(height: 24),
                                            const Text(
                                              '会话模板',
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            const Text(
                                              '模板由配置文件管理；新建会话时可选择。此处保存会保留模板及高级配置。',
                                              style: TextStyle(
                                                color: AppColors.textSecondary,
                                              ),
                                            ),
                                            for (final template
                                                in _savedConfig
                                                    .sessionTemplates)
                                              ListTile(
                                                contentPadding: EdgeInsets.zero,
                                                title: Text(template.name),
                                                subtitle: Text(
                                                  '${template.id} · v${template.version}',
                                                ),
                                                trailing:
                                                    template.id ==
                                                        _savedConfig
                                                            .defaultSessionTemplateId
                                                    ? const Text('默认模板')
                                                    : null,
                                              ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              _buildSettingsFooter(),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsNavigation() {
    return ColoredBox(
      color: AppColors.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(112, 16, 12, 12),
            child: Text(
              'ACP Client',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          _navRow(
            '新对话',
            Icons.edit_square,
            false,
            widget.allowAppNavigation && !_saving
                ? () => _requestClose(SettingsExitAction.newSession)
                : null,
          ),
          _navRow('设置', Icons.settings_outlined, true, null),
          _navRow(
            '活动与诊断',
            Icons.timeline_rounded,
            false,
            widget.allowAppNavigation && !_saving
                ? () => _requestClose(SettingsExitAction.diagnostics)
                : null,
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 30, 24, 12),
            child: Text(
              '设置',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final section in _SettingsSection.values)
                  _navRow(
                    section.label,
                    section.icon,
                    _section == section,
                    _saving ? null : () => _change(() => _section = section),
                    key: Key('settings-section-${section.name}'),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                const Icon(
                  Icons.account_circle,
                  color: AppColors.textTertiary,
                  size: 28,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _activeAgentName,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _navRow(
    String label,
    IconData icon,
    bool selected,
    VoidCallback? onTap, {
    Key? key,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      child: Material(
        color: selected
            ? AppColors.primary.withValues(alpha: 0.09)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: ListTile(
          key: key,
          selected: selected,
          enabled: onTap != null || selected,
          onTap: onTap,
          dense: true,
          visualDensity: VisualDensity.compact,
          minLeadingWidth: 22,
          leading: Icon(icon, size: 21),
          title: Text(
            label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
          selectedColor: AppColors.primary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
      ),
    );
  }

  Widget _buildSettingsHeader(bool wide) {
    return Padding(
      padding: EdgeInsets.fromLTRB(wide ? 24 : 20, 10, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            key: const Key('settings-back'),
            onPressed: _saving ? null : () => _requestClose(),
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('返回会话'),
          ),
          const SizedBox(height: 14),
          const Text(
            '设置',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 5),
          Text(
            _readOnly ? '应用配置 · 只读，当前无法保存' : '应用配置',
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsFooter() {
    final status = _saving
        ? '正在保存…'
        : _readOnly
        ? '配置为只读'
        : _hasChanges
        ? '有未保存的更改'
        : _saveStatus ?? '所有更改已保存';
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 27),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final details = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _hasChanges
                    ? Icons.info_outline_rounded
                    : Icons.check_circle_outline_rounded,
                color: _hasChanges ? AppColors.warning : AppColors.textTertiary,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status,
                      key: const Key('settings-save-status'),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: _hasChanges
                            ? AppColors.warning
                            : AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _runtimeBusy
                          ? '会话仍在运行或切换，请完成操作后保存。'
                          : '保存会重新加载连接配置；当前会话可能需要恢复。',
                      key: const Key('settings-save-impact'),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          final actions = Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: const Key('settings-discard'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(112, 42),
                  textStyle: AppTypography.label.copyWith(fontSize: 14),
                  visualDensity: VisualDensity.standard,
                ),
                onPressed: _hasChanges && !_saving ? _discardChanges : null,
                child: const Text('放弃更改'),
              ),
              FilledButton(
                key: const Key('settings-save'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(112, 42),
                  textStyle: AppTypography.label.copyWith(fontSize: 14),
                  visualDensity: VisualDensity.standard,
                ),
                onPressed: _canSave ? () => _save(context) : null,
                child: Text(_saving ? '正在保存…' : '保存更改'),
              ),
            ],
          );
          if (bounds.maxWidth < 720) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                details,
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: details),
              const SizedBox(width: 24),
              actions,
            ],
          );
        },
      ),
    );
  }

  Widget _settingsScroll(Widget child, {Key? key}) => SingleChildScrollView(
    key: key,
    padding: const EdgeInsets.all(30),
    child: Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: AbsorbPointer(
          absorbing: _saving || _readOnly,
          child: Focus(
            canRequestFocus: !_saving && !_readOnly,
            descendantsAreFocusable: !_saving && !_readOnly,
            child: child,
          ),
        ),
      ),
    ),
  );

  Widget _connectionLayout({
    required Widget list,
    required Widget detail,
    required Widget compactSelector,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: compactSelector,
              ),
              const Divider(height: 1, color: AppColors.border),
              Expanded(child: detail),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 336, child: list),
            const VerticalDivider(width: 1, color: AppColors.border),
            Expanded(child: detail),
          ],
        );
      },
    );
  }

  Widget _buildAgentSettings() {
    final selected = _selectedAgent;
    final add = TextButton.icon(
      key: const Key('settings-add-agent'),
      onPressed: _saving || _readOnly ? null : _addAgent,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text('添加'),
    );
    return _connectionLayout(
      list: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 14, 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Agent 连接',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
                add,
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _agentServers.length,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemBuilder: (context, i) {
                final server = _agentServers[i];
                return _connectionRow(
                  key: Key('settings-agent-${server.name}'),
                  name: server.name,
                  subtitle: server.isStdio
                      ? (_defaultAgentName == server.name
                            ? '本地进程 · 启动默认'
                            : '本地进程')
                      : '远程连接 · 当前不可用',
                  selected: identical(server, selected),
                  onTap: () => _selectAgent(server),
                );
              },
            ),
          ),
        ],
      ),
      compactSelector: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<AgentServerConfig>(
              key: const Key('settings-agent-picker'),
              initialValue: selected,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Agent 连接'),
              items: [
                for (final server in _agentServers)
                  DropdownMenuItem(
                    value: server,
                    child: Text(server.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) {
                if (value != null) _selectAgent(value);
              },
            ),
          ),
          const SizedBox(width: 10),
          add,
        ],
      ),
      detail: selected == null
          ? const Center(child: Text('添加一个本地 Agent 连接以开始使用。'))
          : Stack(
              children: [
                for (final entry in _agentEditors.entries)
                  Offstage(
                    offstage: !identical(entry.key, selected),
                    child: _settingsScroll(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _connectionHeader(
                            entry.key.name,
                            entry.key.isStdio
                                ? '本地进程 · stdio'
                                : '远程 ACP · 当前不可用',
                            menu: PopupMenuButton<String>(
                              enabled: !_saving && !_readOnly,
                              tooltip: 'Agent 操作',
                              onSelected: (value) {
                                if (value == 'default') {
                                  _change(
                                    () => _defaultAgentName = entry.key.name,
                                  );
                                }
                                if (value == 'delete') _deleteAgent(entry.key);
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'default',
                                  enabled: _defaultAgentName != entry.key.name,
                                  child: const Text('设为启动默认 Agent'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  enabled: entry.key.name != _activeAgentName,
                                  child: const Text('移除此连接'),
                                ),
                              ],
                            ),
                          ),
                          _AgentServerEditorDialog(
                            key: entry.value,
                            initialServer: entry.key,
                            presets:
                                _savedConfig.agentServers.contains(entry.key)
                                ? const []
                                : widget.agentPresets,
                            onChanged: _draftChanged,
                          ),
                        ],
                      ),
                      key: PageStorageKey(entry.value),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildToolSettings() {
    final selected = _selectedMcp;
    final add = TextButton.icon(
      key: const Key('settings-add-mcp'),
      onPressed: _saving || _readOnly ? null : _addMcpServer,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text('添加'),
    );
    final directories = _settingsScroll(_buildDirectoriesSection());
    return _connectionLayout(
      list: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: _connectionRow(
              key: const Key('settings-default-directories'),
              name: '默认附加目录',
              subtitle: '所有新会话的目录默认值',
              selected: selected == null,
              onTap: () => _change(() => _selectedMcp = null),
              icon: Icons.folder_open_outlined,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'MCP 服务器',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
                add,
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _mcpServers.length,
              itemBuilder: (context, i) {
                final server = _mcpServers[i];
                return _connectionRow(
                  key: Key('settings-mcp-${server.name}'),
                  name: server.name,
                  subtitle: server.type == 'acp' ? 'acp · 当前不可用' : server.type,
                  selected: identical(server, selected),
                  onTap: () => _selectMcp(server),
                  icon: Icons.extension_outlined,
                );
              },
            ),
          ),
        ],
      ),
      compactSelector: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              key: const Key('settings-mcp-picker'),
              initialValue: selected == null
                  ? -1
                  : _mcpServers.indexOf(selected),
              isExpanded: true,
              decoration: const InputDecoration(labelText: '工具与目录'),
              items: [
                const DropdownMenuItem(value: -1, child: Text('默认附加目录')),
                for (var i = 0; i < _mcpServers.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      _mcpServers[i].name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                if (value == -1) {
                  _change(() => _selectedMcp = null);
                } else {
                  _selectMcp(_mcpServers[value]);
                }
              },
            ),
          ),
          const SizedBox(width: 10),
          add,
        ],
      ),
      detail: Stack(
        children: [
          Offstage(offstage: selected != null, child: directories),
          for (final entry in _mcpEditors.entries)
            Offstage(
              offstage: !identical(entry.key, selected),
              child: _settingsScroll(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _connectionHeader(
                      entry.key.name,
                      'MCP · ${entry.key.type}',
                      menu: IconButton(
                        tooltip: '移除此 MCP 连接',
                        onPressed: _saving || _readOnly
                            ? null
                            : () => _deleteMcpServer(entry.key),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ),
                    _McpServerEditorDialog(
                      key: entry.value,
                      initialServer: entry.key,
                      onChanged: _draftChanged,
                    ),
                  ],
                ),
                key: PageStorageKey(entry.value),
              ),
            ),
        ],
      ),
    );
  }

  Widget _connectionHeader(
    String title,
    String subtitle, {
    required Widget menu,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 26),
    child: Column(
      children: [
        Row(
          children: [
            const Icon(
              Icons.terminal_rounded,
              size: 46,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            menu,
          ],
        ),
        const SizedBox(height: 26),
        const Divider(height: 1, color: AppColors.border),
      ],
    ),
  );

  Widget _connectionRow({
    Key? key,
    required String name,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    IconData icon = Icons.terminal_rounded,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: selected
          ? AppColors.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: ListTile(
        key: key,
        selected: selected,
        onTap: onTap,
        leading: Icon(icon, size: 27, color: AppColors.textSecondary),
        title: Text(
          name,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      ),
    ),
  );
}

class _SettingsField extends StatelessWidget {
  const _SettingsField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
  });
  final TextEditingController controller;
  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final field = MergeSemantics(
      child: Semantics(
        label: label,
        child: TextField(
          controller: controller,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 13,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        final labelWidget = Text(
          label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        );
        if (bounds.maxWidth < 440) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [labelWidget, const SizedBox(height: 8), field],
          );
        }
        return Row(
          children: [
            SizedBox(width: 94, child: labelWidget),
            const SizedBox(width: 16),
            Expanded(child: field),
          ],
        );
      },
    );
  }
}
