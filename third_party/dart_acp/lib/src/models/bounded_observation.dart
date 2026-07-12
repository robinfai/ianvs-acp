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
///
/// The source isolates exceptions thrown by a listener. A throwing listener
/// does not prevent the remaining listeners from receiving the observation
/// and does not fail the operation that committed it.
///
/// For updates, the typed update is queued to the asynchronous
/// `sessionUpdates` stream before this callback runs. The synchronous
/// observation callback therefore normally runs before asynchronous stream
/// listeners receive the same instance.
typedef AcpBoundedObservationListener =
    void Function(AcpBoundedObservation observation);

/// A source of synchronous, non-replayed bounded observations.
///
/// Each publish traverses a snapshot of the listeners taken when that publish
/// begins. Adding or removing a listener from inside a callback, including
/// removing a listener that has not run yet, affects only later observations;
/// every listener in the current snapshot is still called once.
///
/// Observations are emitted only after their result or update has committed.
/// Closing or disposing the source from a callback stops later observations,
/// but does not retroactively undo the current committed result or update, or
/// prevent the remaining listeners in the current snapshot from running.
abstract interface class AcpBoundedObservationSource {
  /// Registers [listener] for future synchronous bounded observations.
  ///
  /// Previously committed observations are not replayed.
  void addBoundedObservationListener(AcpBoundedObservationListener listener);

  /// Stops sending later bounded observations to [listener].
  ///
  /// Removing a listener during a publish does not remove it from that
  /// publish's listener snapshot.
  void removeBoundedObservationListener(AcpBoundedObservationListener listener);
}
