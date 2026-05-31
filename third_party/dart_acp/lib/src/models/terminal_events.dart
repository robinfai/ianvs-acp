/// Base class for terminal lifecycle events emitted for UI consumption.
sealed class TerminalEvent {
  /// Create a terminal event.
  const TerminalEvent();
}

/// Event indicating a terminal process was created.
class TerminalCreated extends TerminalEvent {
  /// Create a [TerminalCreated] event.
  const TerminalCreated({
    required this.terminalId,
    required this.sessionId,
    required this.command,
    required this.args,
    this.cwd,
  });

  /// Identifier of the terminal.
  final String terminalId;

  /// Owning session id.
  final String sessionId;

  /// Command executed in the terminal.
  final String command;

  /// Command arguments.
  final List<String> args;

  /// Optional working directory.
  final String? cwd;
}

/// Event containing current buffered terminal output and exit status.
class TerminalOutputEvent extends TerminalEvent {
  /// Construct a [TerminalOutputEvent]. [exitCode] is null if still running.
  const TerminalOutputEvent({
    required this.terminalId,
    required this.output,
    required this.truncated,
    required this.exitCode,
  });

  /// Identifier of the terminal.
  final String terminalId;

  /// Captured output since last read.
  final String output;

  /// Whether output was truncated.
  final bool truncated;

  /// Exit code if process has exited; otherwise null.
  final int? exitCode;
}

/// Event indicating a terminal process exited.
class TerminalExited extends TerminalEvent {
  /// Create a [TerminalExited] event.
  const TerminalExited({required this.terminalId, required this.code});

  /// Identifier of the terminal.
  final String terminalId;

  /// Exit code returned by the process.
  final int code;
}

/// Event indicating client released a terminal handle.
class TerminalReleased extends TerminalEvent {
  /// Create a [TerminalReleased] event.
  const TerminalReleased({required this.terminalId});

  /// Identifier of the terminal.
  final String terminalId;
}
