import 'task_inbox_snapshot.dart';

abstract class TaskStore {
  Future<TaskInboxSnapshot> load();
  Future<void> save(TaskInboxSnapshot snapshot);
}
