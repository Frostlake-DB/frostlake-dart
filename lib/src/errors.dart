/// Every failure the driver raises is a [FrostlakeException], so one `on
/// FrostlakeException` still catches the lot; the subclasses only say which
/// kind it was.
///
/// The split is the one a caller actually branches on: did the engine refuse
/// the statement ([QueryException]), did the request never become an answer
/// ([ConnectionException]), did the session it belonged to go away before it
/// ran ([SessionLostException]), or did the driver never send it in the first
/// place ([UsageException])?
sealed class FrostlakeException implements Exception {
  const FrostlakeException(this.message);

  /// Human-readable description of what went wrong. For a [QueryException]
  /// this is the engine's own wording, unmodified.
  final String message;

  @override
  String toString() => 'FrostlakeException: $message';
}

/// The server could not be reached, the request died mid-flight, or what came
/// back was not a Frostlake response at all.
///
/// A statement that failed this way has an *unknown* fate: the request may
/// have arrived and run before the connection broke, so it must not be blindly
/// retried — re-running an INSERT would duplicate it.
class ConnectionException extends FrostlakeException {
  const ConnectionException(super.message,
      {this.endpoint, this.status, this.cause});

  /// The URL that was called, when the failure names one.
  final String? endpoint;

  /// The HTTP status the answer arrived with, or `null` when the request never
  /// completed.
  final int? status;

  /// The underlying error, where the failure came from the HTTP client.
  final Object? cause;

  @override
  String toString() => 'ConnectionException: $message';
}

/// The engine rejected a statement: it compiled badly, referenced something
/// that does not exist, or failed while running.
class QueryException extends FrostlakeException {
  const QueryException(super.message, {required this.statement, this.status});

  /// The SQL as it was sent, **after client-side parameter substitution**.
  ///
  /// Because binding is client-side, every parameter appears inlined here — a
  /// bound password or card number verbatim. [toString] and [message] carry
  /// none of it, so log those freely and treat this as sensitive.
  final String statement;

  /// The HTTP status the answer arrived with. Statement failures are reported
  /// with a 4xx status carrying the error payload; 500 means the engine threw
  /// while handling the request.
  final int? status;

  @override
  String toString() => 'QueryException: $message';
}

/// The engine no longer holds the connection's session — it expired, was
/// released, or the server restarted — and the statement did **not** run.
///
/// A lost session is replaced without a word when nothing went with it: the
/// DSN's scope goes onto a fresh session and the statement is sent once more.
/// This is raised instead when the lost session held something a fresh one
/// cannot reproduce — an open transaction, or context set up with `USE`, `SET`,
/// `ALTER SESSION` or a temporary object — because re-running the statement
/// would put it somewhere its author did not intend.
///
/// The connection stays usable: the next statement starts a fresh session on
/// the DSN's scope. Whatever the unit of work had done in the lost session is
/// gone, so it is the unit of work that has to start over.
class SessionLostException extends FrostlakeException {
  const SessionLostException(super.message, {required this.statement});

  /// The SQL that did not run, **after client-side parameter substitution** —
  /// sensitive for the same reason as [QueryException.statement].
  final String statement;

  @override
  String toString() => 'SessionLostException: $message';
}

/// The driver was asked for something impossible, and never sent a request: a
/// malformed DSN, a closed connection, a bind value with no SQL equivalent, an
/// argument count that does not match the placeholders.
class UsageException extends FrostlakeException {
  const UsageException(super.message);

  @override
  String toString() => 'UsageException: $message';
}
