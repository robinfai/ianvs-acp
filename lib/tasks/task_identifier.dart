import 'task_record.dart';

String taskCommitSubject(TaskRecord task, String subject) {
  final normalized = subject.trim().replaceAll(RegExp(r'\s+'), ' ');
  final fallback = normalized.isEmpty ? 'Task update' : normalized;
  final taskId = task.id.trim();
  if (taskId.isEmpty || fallback.startsWith('$taskId:')) return fallback;
  return '$taskId: $fallback';
}

String taskBranchName(
  TaskRecord task, {
  String prefix = 'ianvs',
  String? slug,
}) {
  final taskId = _taskIdPart(task.id);
  final titleSlug = _slugPart(slug ?? task.title);
  final branchPrefix = prefix.trim().replaceAll(RegExp(r'/+$'), '');
  final suffix = titleSlug.isEmpty ? taskId : '$taskId-$titleSlug';
  return branchPrefix.isEmpty ? suffix : '$branchPrefix/$suffix';
}

String taskIdentifierLine(TaskRecord task) => 'Task ID: ${task.id}';

String _taskIdPart(String raw) {
  return raw
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}

String _slugPart(String raw) {
  return raw
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}
