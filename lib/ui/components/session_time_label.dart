DateTime Function()? debugSessionTimeNow;

String formatRelativeSessionTime(DateTime time, {DateTime? now}) {
  final reference = now ?? debugSessionTimeNow?.call() ?? DateTime.now();
  final elapsed = reference.difference(time);

  if (elapsed.isNegative || elapsed < const Duration(minutes: 1)) {
    return 'just now';
  }
  if (elapsed < const Duration(hours: 1)) {
    return '${elapsed.inMinutes}m ago';
  }
  if (elapsed < const Duration(days: 1)) {
    return '${elapsed.inHours}h ago';
  }
  if (elapsed < const Duration(days: 7)) {
    return '${elapsed.inDays}d ago';
  }
  if (elapsed < const Duration(days: 30)) {
    return '${elapsed.inDays ~/ 7}w ago';
  }
  if (elapsed < const Duration(days: 365)) {
    return '${elapsed.inDays ~/ 30}mo ago';
  }

  return '${elapsed.inDays ~/ 365}y ago';
}
