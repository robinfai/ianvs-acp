import 'package:flutter/material.dart';

import '../../tasks/task_record.dart';
import '../../workspace/workspace.dart';
import '../theme/app_design_tokens.dart';

class TaskDraft {
  const TaskDraft({
    required this.title,
    required this.description,
    required this.workspacePath,
    required this.agentName,
    required this.priority,
  });

  final String title;
  final String description;
  final String workspacePath;
  final String agentName;
  final TaskPriority priority;
}

class TaskEditorDialog extends StatefulWidget {
  const TaskEditorDialog({
    super.key,
    required this.initialWorkspacePath,
    required this.initialAgentName,
    this.agentNames = const <String>[],
  });

  final String initialWorkspacePath;
  final String initialAgentName;
  final List<String> agentNames;

  @override
  State<TaskEditorDialog> createState() => _TaskEditorDialogState();
}

class _TaskEditorDialogState extends State<TaskEditorDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _workspaceController;
  late final TextEditingController _agentController;
  late TaskPriority _priority;
  late String _selectedAgentName;
  String? _titleError;
  String? _workspaceError;
  String? _agentError;

  @override
  void initState() {
    super.initState();
    final agentName = widget.initialAgentName.trim();
    final normalizedWorkspace = normalizeWorkspacePath(
      widget.initialWorkspacePath,
    );
    _titleController = TextEditingController();
    _descriptionController = TextEditingController();
    _workspaceController = TextEditingController(text: normalizedWorkspace);
    _agentController = TextEditingController(text: agentName);
    _selectedAgentName = _agentNames().contains(agentName)
        ? agentName
        : (_agentNames().isEmpty ? agentName : _agentNames().first);
    _priority = TaskPriority.normal;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _workspaceController.dispose();
    _agentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Task'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                label: 'Task title',
                container: true,
                explicitChildNodes: true,
                child: TextField(
                  key: const Key('task-title-field'),
                  controller: _titleController,
                  autofocus: true,
                  decoration: _inputDecoration(
                    labelText: 'Title',
                    icon: Icons.task_alt_rounded,
                    errorText: _titleError,
                  ),
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() => _titleError = null),
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                label: 'Task description',
                container: true,
                explicitChildNodes: true,
                child: TextField(
                  key: const Key('task-description-field'),
                  controller: _descriptionController,
                  minLines: 3,
                  maxLines: 5,
                  decoration: _inputDecoration(
                    labelText: 'Description',
                    icon: Icons.subject_rounded,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                label: 'Task workspace path',
                container: true,
                explicitChildNodes: true,
                child: TextField(
                  key: const Key('task-workspace-field'),
                  controller: _workspaceController,
                  decoration: _inputDecoration(
                    labelText: 'Workspace Path',
                    icon: Icons.folder_open_rounded,
                    errorText: _workspaceError,
                  ),
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() => _workspaceError = null),
                ),
              ),
              const SizedBox(height: 12),
              _agentNames().isEmpty
                  ? Semantics(
                      label: 'Task agent',
                      container: true,
                      explicitChildNodes: true,
                      child: TextField(
                        key: const Key('task-agent-field'),
                        controller: _agentController,
                        decoration: _inputDecoration(
                          labelText: 'Agent',
                          icon: Icons.smart_toy_outlined,
                          errorText: _agentError,
                        ),
                        textInputAction: TextInputAction.next,
                        onChanged: (_) => setState(() => _agentError = null),
                      ),
                    )
                  : DropdownButtonFormField<String>(
                      key: const Key('task-agent-dropdown'),
                      initialValue: _selectedAgentName,
                      decoration: _inputDecoration(
                        labelText: 'Agent',
                        icon: Icons.smart_toy_outlined,
                        errorText: _agentError,
                      ),
                      items: [
                        for (final agentName in _agentNames())
                          DropdownMenuItem<String>(
                            value: agentName,
                            child: Text(
                              agentName,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _selectedAgentName = value;
                          _agentError = null;
                        });
                      },
                    ),
              const SizedBox(height: 12),
              DropdownButtonFormField<TaskPriority>(
                key: const Key('task-priority-dropdown'),
                initialValue: _priority,
                decoration: _inputDecoration(
                  labelText: 'Priority',
                  icon: Icons.flag_outlined,
                ),
                items: [
                  for (final priority in TaskPriority.values)
                    DropdownMenuItem<TaskPriority>(
                      value: priority,
                      child: Text(_priorityLabel(priority)),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _priority = value);
                },
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
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }

  InputDecoration _inputDecoration({
    required String labelText,
    required IconData icon,
    String? errorText,
  }) {
    return InputDecoration(
      labelText: labelText,
      prefixIcon: Icon(icon),
      errorText: errorText,
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
    );
  }

  void _submit() {
    final title = _titleController.text.trim();
    final workspacePath = normalizeWorkspacePath(_workspaceController.text);
    final agentName = _agentNames().isEmpty
        ? _agentController.text.trim()
        : _selectedAgentName.trim();

    setState(() {
      _titleError = title.isEmpty ? 'Enter a title.' : null;
      _workspaceError = workspacePath.isEmpty
          ? 'Enter a workspace path.'
          : null;
      _agentError = agentName.isEmpty ? 'Enter an agent.' : null;
    });
    if (_titleError != null || _workspaceError != null || _agentError != null) {
      return;
    }

    Navigator.of(context).pop(
      TaskDraft(
        title: title,
        description: _descriptionController.text.trim(),
        workspacePath: workspacePath,
        agentName: agentName,
        priority: _priority,
      ),
    );
  }

  List<String> _agentNames() {
    final names = <String>{};
    for (final name in widget.agentNames) {
      final trimmed = name.trim();
      if (trimmed.isNotEmpty) names.add(trimmed);
    }
    final initial = widget.initialAgentName.trim();
    if (initial.isNotEmpty) names.add(initial);
    final sorted = names.toList()..sort();
    return sorted;
  }
}

String _priorityLabel(TaskPriority priority) {
  return switch (priority) {
    TaskPriority.low => 'Low',
    TaskPriority.normal => 'Normal',
    TaskPriority.high => 'High',
    TaskPriority.urgent => 'Urgent',
  };
}
