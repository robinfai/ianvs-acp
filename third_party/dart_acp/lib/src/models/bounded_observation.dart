import 'session_types.dart';
import 'updates.dart';

/// Session operations that can publish a bounded result observation.
enum AcpBoundedSessionOperation {
  /// A newly created session.
  newSession,

  /// An existing session loaded with replayed history.
  loadSession,

  /// An existing session resumed without loading history.
  resumeSession,

  /// A new session forked from an existing session.
  forkSession,
}

/// Base type for bounded, typed session observations.
sealed class AcpBoundedObservation {
  /// Creates a bounded observation.
  const AcpBoundedObservation();
}

/// A committed result from a session lifecycle operation.
final class AcpBoundedSessionResultObservation extends AcpBoundedObservation {
  /// Creates a bounded session result observation.
  const AcpBoundedSessionResultObservation({
    required this.operation,
    required this.sessionId,
    required this.result,
  });

  /// The session lifecycle operation that produced [result].
  final AcpBoundedSessionOperation operation;

  /// The committed session identifier.
  final String sessionId;

  /// The bounded typed result produced by the owning parser.
  final SessionResult result;
}

/// A committed typed session update.
final class AcpBoundedUpdateObservation extends AcpBoundedObservation {
  /// Creates a bounded update observation.
  const AcpBoundedUpdateObservation({
    required this.sessionId,
    required this.update,
  });

  /// The session receiving [update].
  final String sessionId;

  /// The bounded typed update produced by the owning parser.
  final AcpUpdate update;
}

/// Receives a bounded observation synchronously when it is committed.
typedef AcpBoundedObservationListener =
    void Function(AcpBoundedObservation observation);

/// A source of synchronous, non-replayed bounded observations.
abstract interface class AcpBoundedObservationSource {
  /// Registers [listener] for future bounded observations.
  void addBoundedObservationListener(AcpBoundedObservationListener listener);

  /// Stops sending future bounded observations to [listener].
  void removeBoundedObservationListener(AcpBoundedObservationListener listener);
}
