import 'package:flutter/material.dart';

import '../../acp/agent_session.dart';

enum WorkspaceSessionMenuAction {
  togglePinned,
  rename,
  toggleUnread,
  archive,
  openSideSession,
  revealInFinder,
  copyWorkingDirectory,
  copySessionId,
  copyDeepLink,
  copyMarkdown,
  forkLocally,
  forkToNewWorktree,
  openInNewWindow,
  close,
  delete,
}

enum SessionMenuActionSection { organize, open, copy, continueSession, danger }

@immutable
class SessionActionAvailability {
  const SessionActionAvailability({
    this.canFork = false,
    this.supportsClose = false,
    this.canClose = false,
    this.supportsDelete = false,
    this.canDelete = false,
  });

  final bool canFork;
  final bool supportsClose;
  final bool canClose;
  final bool supportsDelete;
  final bool canDelete;

  bool isVisible(WorkspaceSessionMenuAction action) {
    return switch (action) {
      WorkspaceSessionMenuAction.close => supportsClose,
      WorkspaceSessionMenuAction.delete => supportsDelete,
      _ => true,
    };
  }

  bool isEnabled(WorkspaceSessionMenuAction action) {
    return switch (action) {
      WorkspaceSessionMenuAction.forkLocally ||
      WorkspaceSessionMenuAction.forkToNewWorktree => canFork,
      WorkspaceSessionMenuAction.close => canClose,
      WorkspaceSessionMenuAction.delete => canDelete,
      _ => true,
    };
  }
}

const List<WorkspaceSessionMenuAction> workspaceSessionMenuActionOrder = [
  WorkspaceSessionMenuAction.togglePinned,
  WorkspaceSessionMenuAction.rename,
  WorkspaceSessionMenuAction.toggleUnread,
  WorkspaceSessionMenuAction.archive,
  WorkspaceSessionMenuAction.openSideSession,
  WorkspaceSessionMenuAction.revealInFinder,
  WorkspaceSessionMenuAction.openInNewWindow,
  WorkspaceSessionMenuAction.copyWorkingDirectory,
  WorkspaceSessionMenuAction.copySessionId,
  WorkspaceSessionMenuAction.copyDeepLink,
  WorkspaceSessionMenuAction.copyMarkdown,
  WorkspaceSessionMenuAction.forkLocally,
  WorkspaceSessionMenuAction.forkToNewWorktree,
  WorkspaceSessionMenuAction.close,
  WorkspaceSessionMenuAction.delete,
];

extension WorkspaceSessionMenuActionPresentation on WorkspaceSessionMenuAction {
  SessionMenuActionSection get section {
    return switch (this) {
      WorkspaceSessionMenuAction.togglePinned ||
      WorkspaceSessionMenuAction.rename ||
      WorkspaceSessionMenuAction.toggleUnread ||
      WorkspaceSessionMenuAction.archive => SessionMenuActionSection.organize,
      WorkspaceSessionMenuAction.openSideSession ||
      WorkspaceSessionMenuAction.revealInFinder ||
      WorkspaceSessionMenuAction.openInNewWindow =>
        SessionMenuActionSection.open,
      WorkspaceSessionMenuAction.copyWorkingDirectory ||
      WorkspaceSessionMenuAction.copySessionId ||
      WorkspaceSessionMenuAction.copyDeepLink ||
      WorkspaceSessionMenuAction.copyMarkdown => SessionMenuActionSection.copy,
      WorkspaceSessionMenuAction.forkLocally ||
      WorkspaceSessionMenuAction.forkToNewWorktree =>
        SessionMenuActionSection.continueSession,
      WorkspaceSessionMenuAction.close ||
      WorkspaceSessionMenuAction.delete => SessionMenuActionSection.danger,
    };
  }

  String labelFor(AgentSession session) {
    return switch (this) {
      WorkspaceSessionMenuAction.togglePinned =>
        session.pinned ? '取消固定' : '固定会话',
      WorkspaceSessionMenuAction.rename => '重命名会话',
      WorkspaceSessionMenuAction.toggleUnread =>
        session.unread ? '标为已读' : '标为未读',
      WorkspaceSessionMenuAction.archive => '归档会话',
      WorkspaceSessionMenuAction.openSideSession => '在侧边打开',
      WorkspaceSessionMenuAction.revealInFinder => '在 Finder 中显示',
      WorkspaceSessionMenuAction.copyWorkingDirectory => '复制工作目录',
      WorkspaceSessionMenuAction.copySessionId => '复制会话 ID',
      WorkspaceSessionMenuAction.copyDeepLink => '复制会话链接',
      WorkspaceSessionMenuAction.copyMarkdown => '复制为 Markdown',
      WorkspaceSessionMenuAction.forkLocally => '继续到新会话',
      WorkspaceSessionMenuAction.forkToNewWorktree => '继续到新工作树',
      WorkspaceSessionMenuAction.openInNewWindow => '在新窗口打开',
      WorkspaceSessionMenuAction.close => '关闭会话',
      WorkspaceSessionMenuAction.delete => '删除 Agent 历史',
    };
  }

  IconData iconFor(AgentSession session) {
    return switch (this) {
      WorkspaceSessionMenuAction.togglePinned =>
        session.pinned ? Icons.push_pin : Icons.push_pin_outlined,
      WorkspaceSessionMenuAction.rename => Icons.edit_outlined,
      WorkspaceSessionMenuAction.toggleUnread =>
        session.unread
            ? Icons.mark_chat_read_outlined
            : Icons.mark_chat_unread_outlined,
      WorkspaceSessionMenuAction.archive => Icons.archive_outlined,
      WorkspaceSessionMenuAction.openSideSession =>
        Icons.add_circle_outline_rounded,
      WorkspaceSessionMenuAction.revealInFinder => Icons.folder_open_outlined,
      WorkspaceSessionMenuAction.copyWorkingDirectory =>
        Icons.folder_copy_outlined,
      WorkspaceSessionMenuAction.copySessionId => Icons.tag_rounded,
      WorkspaceSessionMenuAction.copyDeepLink => Icons.link_rounded,
      WorkspaceSessionMenuAction.copyMarkdown => Icons.description_outlined,
      WorkspaceSessionMenuAction.forkLocally => Icons.call_split_rounded,
      WorkspaceSessionMenuAction.forkToNewWorktree =>
        Icons.account_tree_outlined,
      WorkspaceSessionMenuAction.openInNewWindow => Icons.open_in_new_rounded,
      WorkspaceSessionMenuAction.close => Icons.close_rounded,
      WorkspaceSessionMenuAction.delete => Icons.delete_outline_rounded,
    };
  }

  bool get isDestructive {
    return this == WorkspaceSessionMenuAction.delete;
  }
}

List<WorkspaceSessionMenuAction> visibleWorkspaceSessionMenuActions({
  required SessionActionAvailability availability,
  required bool supportsGitWorktrees,
}) {
  return [
    for (final action in workspaceSessionMenuActionOrder)
      if (availability.isVisible(action) &&
          (action != WorkspaceSessionMenuAction.forkToNewWorktree ||
              supportsGitWorktrees))
        action,
  ];
}
