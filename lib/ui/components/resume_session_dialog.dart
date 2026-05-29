import 'dart:convert';

import 'package:flutter/material.dart';

import '../../acp/acp_session_catalog.dart';
import '../theme/app_design_tokens.dart';

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
  });

  final Future<List<AcpProjectSessions>> Function() loadSessions;
  final String? initialCwd;

  @override
  State<ResumeSessionDialog> createState() => _ResumeSessionDialogState();
}

class _ResumeSessionDialogState extends State<ResumeSessionDialog> {
  final TextEditingController _projectController = TextEditingController();
  final TextEditingController _conversationController = TextEditingController();

  List<AcpProjectSessions> _projects = const [];
  AcpProjectSessions? _selectedProject;
  AcpSessionEntry? _selectedConversation;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _projectController.dispose();
    _conversationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Resume ACP Session'),
      content: SizedBox(
        width: 720,
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
          onPressed: _selectedProject == null || _selectedConversation == null
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

  Widget _content() {
    if (_loading) {
      return const SizedBox(
        height: 240,
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

    final selectedProject = _selectedProject;
    final conversations =
        selectedProject?.sessions ?? const <AcpSessionEntry>[];

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Column(
          key: const ValueKey('loaded'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _FieldLabel(
              icon: Icons.folder_open_rounded,
              label: 'Project',
              helper: 'Search by project name or path.',
            ),
            const SizedBox(height: 8),
            DropdownMenu<AcpProjectSessions>(
              controller: _projectController,
              width: width,
              menuHeight: 280,
              enableFilter: true,
              enableSearch: true,
              requestFocusOnTap: true,
              leadingIcon: const Icon(Icons.folder_outlined),
              initialSelection: _selectedProject,
              dropdownMenuEntries: _projects
                  .map(
                    (project) => DropdownMenuEntry<AcpProjectSessions>(
                      value: project,
                      label: project.dropdownLabel,
                    ),
                  )
                  .toList(),
              onSelected: (project) {
                if (project == null) return;
                setState(() {
                  _selectedProject = project;
                  _selectedConversation = project.sessions.isEmpty
                      ? null
                      : project.sessions.first;
                  _projectController.text = project.dropdownLabel;
                  _conversationController.text =
                      _selectedConversation?.dropdownLabel ?? '';
                });
              },
            ),
            const SizedBox(height: 18),
            _FieldLabel(
              icon: Icons.chat_bubble_outline_rounded,
              label: 'Conversation',
              helper: 'Search by title, short id, or updated time.',
            ),
            const SizedBox(height: 8),
            DropdownMenu<AcpSessionEntry>(
              controller: _conversationController,
              width: width,
              menuHeight: 320,
              enabled: conversations.isNotEmpty,
              enableFilter: true,
              enableSearch: true,
              requestFocusOnTap: true,
              leadingIcon: const Icon(Icons.forum_outlined),
              initialSelection: _selectedConversation,
              dropdownMenuEntries: conversations
                  .map(
                    (conversation) => DropdownMenuEntry<AcpSessionEntry>(
                      value: conversation,
                      label: conversation.dropdownLabel,
                    ),
                  )
                  .toList(),
              onSelected: (conversation) {
                if (conversation == null) return;
                setState(() {
                  _selectedConversation = conversation;
                  _conversationController.text = conversation.dropdownLabel;
                });
              },
            ),
            const SizedBox(height: 18),
            _ConversationPreview(conversation: _selectedConversation),
          ],
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
        _projectController.text = selectedProject?.dropdownLabel ?? '';
        _conversationController.text =
            selectedConversation?.dropdownLabel ?? '';
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
        Icon(icon, size: 18, color: AppColors.primaryDark),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(width: 10),
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
  const _ConversationPreview({required this.conversation});

  final AcpSessionEntry? conversation;

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
      padding: const EdgeInsets.all(14),
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
          const SizedBox(height: 10),
          _PreviewRow(icon: Icons.tag_rounded, label: conversation.id),
          const SizedBox(height: 6),
          _PreviewRow(icon: Icons.folder_outlined, label: conversation.cwd),
          if (conversation.updatedAt != null) ...[
            const SizedBox(height: 6),
            _PreviewRow(
              icon: Icons.access_time_rounded,
              label: _formatDateTime(conversation.updatedAt!),
            ),
          ],
          if (conversation.hasMeta) ...[
            const SizedBox(height: 12),
            _MetadataPreview(meta: conversation.meta),
          ],
        ],
      ),
    );
  }
}

class _MetadataPreview extends StatelessWidget {
  const _MetadataPreview({required this.meta});

  final Map<String, Object?> meta;

  @override
  Widget build(BuildContext context) {
    const encoder = JsonEncoder.withIndent('  ');
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        color: Colors.transparent,
        child: ExpansionTile(
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
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: AppColors.border),
              ),
              child: SelectableText(
                encoder.convert(meta),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
          ],
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
        const SizedBox(width: 8),
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
      height: 240,
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: AppColors.primaryDark, size: 34),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
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
