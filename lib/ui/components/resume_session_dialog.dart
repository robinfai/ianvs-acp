import 'dart:async';

import 'package:dart_acp/dart_acp.dart';
import 'package:flutter/material.dart';

import '../../acp/acp_session_catalog.dart';
import '../theme/app_design_tokens.dart';
import '../bounded_metadata_preview.dart';

const String resumeSessionAgentNameMetaKey = 'agentName';

class ResumeSessionSelection {
  const ResumeSessionSelection({
    required this.project,
    required this.conversation,
  });

  final AcpProjectSessions project;
  final AcpSessionEntry conversation;
}

class ResumeSessionDialog extends StatefulWidget {
  const ResumeSessionDialog({
    super.key,
    required this.loadSessions,
    this.initialCwd,
    this.inputBudget = const AcpInputBudget(),
  });

  final Future<List<AcpProjectSessions>> Function() loadSessions;
  final String? initialCwd;
  final AcpInputBudget inputBudget;

  @override
  State<ResumeSessionDialog> createState() => _ResumeSessionDialogState();
}

class _ResumeSessionDialogState extends State<ResumeSessionDialog> {
  final TextEditingController _projectSearchController =
      TextEditingController();
  final TextEditingController _conversationSearchController =
      TextEditingController();

  List<AcpProjectSessions> _projects = const [];
  AcpProjectSessions? _selectedProject;
  AcpSessionEntry? _selectedConversation;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.inputBudget.validate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void didUpdateWidget(covariant ResumeSessionDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.inputBudget.validate();
  }

  @override
  void dispose() {
    _projectSearchController.dispose();
    _conversationSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Resume ACP Session'),
      content: SizedBox(
        width: 640,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: _content(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton.icon(
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Refresh'),
        ),
        FilledButton(
          onPressed: !_canLoadSelection()
              ? null
              : () {
                  Navigator.of(context).pop(
                    ResumeSessionSelection(
                      project: _selectedProject!,
                      conversation: _selectedConversation!,
                    ),
                  );
                },
          child: const Text('Load'),
        ),
      ],
    );
  }

  bool _canLoadSelection() {
    final selectedProject = _selectedProject;
    final selectedConversation = _selectedConversation;
    if (_loading ||
        _error != null ||
        selectedProject == null ||
        selectedConversation == null) {
      return false;
    }
    if (!_filteredProjects().contains(selectedProject)) return false;
    return _filteredConversations(
      selectedProject.sessions,
    ).contains(selectedConversation);
  }

  Widget _content() {
    if (_loading) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return _MessagePanel(
        icon: Icons.error_outline_rounded,
        title: 'Could not list ACP sessions',
        message: _error.toString(),
      );
    }

    if (_projects.isEmpty) {
      return const _MessagePanel(
        icon: Icons.search_off_rounded,
        title: 'No sessions found',
        message: 'The connected ACP agent did not return any sessions.',
      );
    }

    final filteredProjects = _filteredProjects();
    final selectedProject = _selectedProject;
    final selectedProjectValue = filteredProjects.contains(selectedProject)
        ? selectedProject
        : null;
    final conversations =
        selectedProjectValue?.sessions ?? const <AcpSessionEntry>[];
    final filteredConversations = _filteredConversations(conversations);
    final selectedConversationValue =
        filteredConversations.contains(_selectedConversation)
        ? _selectedConversation
        : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          key: const ValueKey('loaded'),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _FieldLabel(
                  icon: Icons.folder_open_rounded,
                  label: 'Project',
                  helper: 'Search by project name or path.',
                ),
                const SizedBox(height: 6),
                _SearchField(
                  key: const ValueKey('resume-project-search'),
                  controller: _projectSearchController,
                  hintText: 'Filter projects...',
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<AcpProjectSessions>(
                  key: const ValueKey('resume-project-dropdown'),
                  initialValue: selectedProjectValue,
                  isExpanded: true,
                  decoration: _inputDecoration(
                    icon: Icons.folder_outlined,
                    hintText: filteredProjects.isEmpty
                        ? 'No matching projects'
                        : 'Select a project',
                  ),
                  menuMaxHeight: 280,
                  items: filteredProjects
                      .map(
                        (project) => DropdownMenuItem<AcpProjectSessions>(
                          value: project,
                          child: Text(
                            project.dropdownLabel,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: filteredProjects.isEmpty
                      ? null
                      : (project) {
                          if (project == null) return;
                          setState(() {
                            _selectedProject = project;
                            _selectedConversation = project.sessions.isEmpty
                                ? null
                                : project.sessions.first;
                            _conversationSearchController.clear();
                          });
                        },
                ),
                const SizedBox(height: 12),
                _FieldLabel(
                  icon: Icons.chat_bubble_outline_rounded,
                  label: 'Conversation',
                  helper: 'Search by title, short id, or updated time.',
                ),
                const SizedBox(height: 6),
                _SearchField(
                  key: const ValueKey('resume-conversation-search'),
                  controller: _conversationSearchController,
                  hintText: 'Filter conversations...',
                  enabled: conversations.isNotEmpty,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<AcpSessionEntry>(
                  key: const ValueKey('resume-conversation-dropdown'),
                  initialValue: selectedConversationValue,
                  isExpanded: true,
                  decoration: _inputDecoration(
                    icon: Icons.forum_outlined,
                    hintText: conversations.isEmpty
                        ? 'No conversations'
                        : filteredConversations.isEmpty
                        ? 'No matching conversations'
                        : 'Select a conversation',
                  ),
                  menuMaxHeight: 320,
                  items: filteredConversations
                      .map(
                        (conversation) => DropdownMenuItem<AcpSessionEntry>(
                          value: conversation,
                          child: Text(
                            _conversationLabel(conversation),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: filteredConversations.isEmpty
                      ? null
                      : (conversation) {
                          if (conversation == null) return;
                          setState(() {
                            _selectedConversation = conversation;
                          });
                        },
                ),
                const SizedBox(height: 12),
                _ConversationPreview(
                  conversation: selectedConversationValue,
                  inputBudget: widget.inputBudget,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final projects = await widget.loadSessions();
      if (!mounted) return;
      final selectedProject = _initialProject(projects);
      final selectedConversation =
          selectedProject == null || selectedProject.sessions.isEmpty
          ? null
          : selectedProject.sessions.first;
      setState(() {
        _projects = projects;
        _selectedProject = selectedProject;
        _selectedConversation = selectedConversation;
        _projectSearchController.clear();
        _conversationSearchController.clear();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  AcpProjectSessions? _initialProject(List<AcpProjectSessions> projects) {
    if (projects.isEmpty) return null;
    final initialCwd = widget.initialCwd;
    if (initialCwd == null || initialCwd.isEmpty) return projects.first;
    for (final project in projects) {
      if (project.cwd == initialCwd) return project;
    }
    return projects.first;
  }

  List<AcpProjectSessions> _filteredProjects() {
    final query = _projectSearchController.text.trim().toLowerCase();
    if (query.isEmpty) return _projects;
    return _projects.where((project) {
      return project.name.toLowerCase().contains(query) ||
          project.cwd.toLowerCase().contains(query) ||
          project.dropdownLabel.toLowerCase().contains(query);
    }).toList();
  }

  List<AcpSessionEntry> _filteredConversations(
    List<AcpSessionEntry> conversations,
  ) {
    final query = _conversationSearchController.text.trim().toLowerCase();
    if (query.isEmpty) return conversations;
    return conversations.where((conversation) {
      final updatedAt = conversation.updatedAt == null
          ? ''
          : _formatDateTime(conversation.updatedAt!);
      return conversation.title.toLowerCase().contains(query) ||
          _conversationAgentName(conversation).toLowerCase().contains(query) ||
          conversation.id.toLowerCase().contains(query) ||
          conversation.shortId.toLowerCase().contains(query) ||
          conversation.cwd.toLowerCase().contains(query) ||
          conversation.dropdownLabel.toLowerCase().contains(query) ||
          updatedAt.toLowerCase().contains(query);
    }).toList();
  }
}

String _conversationLabel(AcpSessionEntry conversation) {
  final agentName = _conversationAgentName(conversation);
  if (agentName.isEmpty) return conversation.dropdownLabel;
  return '$agentName - ${conversation.dropdownLabel}';
}

String _conversationAgentName(AcpSessionEntry conversation) {
  final agentName = conversation.meta[resumeSessionAgentNameMetaKey];
  return agentName is String ? agentName.trim() : '';
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      onChanged: onChanged,
      style: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      decoration: _inputDecoration(
        icon: Icons.search_rounded,
        hintText: hintText,
      ),
    );
  }
}

InputDecoration _inputDecoration({
  required IconData icon,
  required String hintText,
}) {
  return InputDecoration(
    prefixIcon: Icon(icon, size: 18, color: AppColors.textSecondary),
    hintText: hintText,
    hintStyle: const TextStyle(
      color: AppColors.textTertiary,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    filled: true,
    fillColor: AppColors.surface,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      borderSide: const BorderSide(color: AppColors.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      borderSide: const BorderSide(color: AppColors.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      borderSide: const BorderSide(color: AppColors.primary),
    ),
    disabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      borderSide: const BorderSide(color: AppColors.borderSoft),
    ),
  );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({
    required this.icon,
    required this.label,
    required this.helper,
  });

  final IconData icon;
  final String label;
  final String helper;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.primaryDark),
        const SizedBox(width: 7),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            helper,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textTertiary, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _ConversationPreview extends StatelessWidget {
  const _ConversationPreview({
    required this.conversation,
    required this.inputBudget,
  });

  final AcpSessionEntry? conversation;
  final AcpInputBudget inputBudget;

  @override
  Widget build(BuildContext context) {
    final conversation = this.conversation;
    if (conversation == null) {
      return const _MessagePanel(
        icon: Icons.forum_outlined,
        title: 'Select a conversation',
        message: 'Choose a project first, then select an ACP session.',
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            conversation.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          _PreviewRow(icon: Icons.tag_rounded, label: conversation.id),
          const SizedBox(height: 5),
          if (_conversationAgentName(conversation).isNotEmpty) ...[
            _PreviewRow(
              icon: Icons.smart_toy_outlined,
              label: _conversationAgentName(conversation),
            ),
            const SizedBox(height: 5),
          ],
          _PreviewPathRow(label: 'Main workspace', path: conversation.cwd),
          for (final directory in _visibleAdditionalDirectories(
            conversation,
          )) ...[
            const SizedBox(height: 5),
            _PreviewPathRow(label: 'Additional directory', path: directory),
          ],
          if (conversation.updatedAt != null) ...[
            const SizedBox(height: 5),
            _PreviewRow(
              icon: Icons.access_time_rounded,
              label: _formatDateTime(conversation.updatedAt!),
            ),
          ],
          if (conversation.hasMeta || conversation.metaOmission != null) ...[
            const SizedBox(height: 8),
            if (conversation.hasMeta)
              _MetadataPreview(
                meta: conversation.meta,
                inputBudget: inputBudget,
                sessionIdentity: conversation,
              ),
            if (conversation.metaOmission != null)
              _MetadataOmissionLabel(omission: conversation.metaOmission!),
          ],
        ],
      ),
    );
  }
}

class _MetadataPreview extends StatefulWidget {
  const _MetadataPreview({
    required this.meta,
    required this.inputBudget,
    required this.sessionIdentity,
  });

  final Map<String, Object?> meta;
  final AcpInputBudget inputBudget;
  final Object sessionIdentity;

  @override
  State<_MetadataPreview> createState() => _MetadataPreviewState();
}

class _MetadataPreviewState extends State<_MetadataPreview> {
  BoundedMetadataPreview? _preview;
  var _expanded = false;

  @override
  void didUpdateWidget(covariant _MetadataPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(widget.sessionIdentity, oldWidget.sessionIdentity) &&
        identical(widget.meta, oldWidget.meta) &&
        identical(widget.inputBudget, oldWidget.inputBudget)) {
      return;
    }
    _preview = _expanded ? _writePreview() : null;
  }

  BoundedMetadataPreview _writePreview() =>
      writeBoundedMetadataPreview(widget.meta, budget: widget.inputBudget);

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        color: Colors.transparent,
        child: ExpansionTile(
          onExpansionChanged: (expanded) {
            setState(() {
              _expanded = expanded;
              _preview = expanded ? _writePreview() : null;
            });
          },
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: const Text(
            'Metadata',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          leading: const Icon(
            Icons.data_object_rounded,
            color: AppColors.primaryDark,
            size: 18,
          ),
          children: _preview == null
              ? const <Widget>[]
              : [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: SelectableText(
                      _preview!.text,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
                  if (_preview!.omission != null)
                    _MetadataOmissionLabel(omission: _preview!.omission!),
                ],
        ),
      ),
    );
  }
}

class _MetadataOmissionLabel extends StatelessWidget {
  const _MetadataOmissionLabel({required this.omission});

  final AcpInputOmission omission;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        'Details omitted · ${omission.resource}',
        style: const TextStyle(
          color: AppColors.warning,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: AppColors.textTertiary),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

List<String> _visibleAdditionalDirectories(AcpSessionEntry conversation) {
  final mainWorkspace = conversation.cwd.trim();
  final seen = <String>{if (mainWorkspace.isNotEmpty) mainWorkspace};
  final directories = <String>[];
  for (final rawDirectory in conversation.additionalDirectories) {
    final directory = rawDirectory.trim();
    if (directory.isEmpty || !seen.add(directory)) continue;
    directories.add(directory);
  }
  return directories;
}

class _PreviewPathRow extends StatelessWidget {
  const _PreviewPathRow({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Icon(
            Icons.folder_outlined,
            size: 15,
            color: AppColors.textTertiary,
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SelectableText(
                path,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 160,
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: AppColors.primaryDark, size: 28),
          const SizedBox(height: 8),
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textSecondary,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDateTime(DateTime value) {
  String two(int input) => input.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
