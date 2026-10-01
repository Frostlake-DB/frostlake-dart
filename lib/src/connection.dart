import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'binding.dart';
import 'dsn.dart';
import 'errors.dart';
import 'json.dart';
import 'result.dart';
import 'sql.dart';
import 'values.dart';

/// How much of an unrecognisable response is quoted back in an error.
const int _maxErrorBody = 512;

/// The longest [Connection.close] waits for the engine to release a session.
const Duration _releaseLimit = Duration(seconds: 5);

/// Opens a connection to a Frostlake HTTP server.
///
/// ```dart
/// final conn = await connect('frostlake://localhost:18082/MY_DB?schema=PUBLIC');
/// ```
///
/// The server is contacted before this returns: its health endpoint is called,
/// and the database, schema, role and warehouse the DSN names are selected. A
/// name that does not exist is therefore reported here, rather than surfacing
/// later on whichever query happened to run first.
///
/// Every argument may also be given in the DSN query string, where an explicit
/// argument outranks it.
Future<Connection> connect(
  String dsn, {
  Duration? connectTimeout,
  Duration? timeout,
  Duration? idleLimit,
  SecurityContext? securityContext,
  bool? verifyCertificate,
}) async {
  final base = parseDsn(dsn);
  final config = Config(
    host: base.host,
    port: base.port,
    secure: base.secure,
    database: base.database,
    schema: base.schema,
    role: base.role,
    warehouse: base.warehouse,
    connectTimeout: connectTimeout ?? base.connectTimeout,
    timeout: timeout ?? base.timeout,
    idleLimit: idleLimit ?? base.idleLimit,
  );
  if (!config.secure &&
      (securityContext != null || verifyCertificate != null)) {
    throw const UsageException(
        'securityContext and verifyCertificate apply to https DSNs only');
  }
  final connection = Connection._(config, securityContext, verifyCertificate);
  try {
    await connection.ping();
    await connection.applyDsnScope();
  } on Object {
    // Nothing usable came of it, so do not leave a client behind.
    await connection.close();
    rethrow;
  }
  return connection;
}

/// A connection to a Frostlake HTTP server, and the engine session behind it.
///
/// Statements are serialized in call order, so awaiting several at once is safe
/// and stays on one session — session state (`USE`, variables, an open
/// transaction) carries from one statement to the next, which is exactly what a
/// half-interleaved second statement would break.
///
/// The engine can lose the session: it expires after 30 idle minutes, and a
/// restart ends them all. A statement that finds its session gone is sent once
/// more on a fresh session with the DSN's scope, unless the lost session held
/// an open transaction or context of the caller's own — then it raises
/// [SessionLostException] instead. [close] releases the session.
class Connection {
  Connection._(this._config, SecurityContext? context, bool? verifyCertificate)
      : _client = HttpClient(context: context) {
    _client.connectionTimeout = _config.connectTimeout;
    if (verifyCertificate == false) {
      _client.badCertificateCallback = (_, __, ___) => true;
    }
    _pendingUse = _config.useStatements();
    _sessionDefaults = List.unmodifiable(_pendingUse);
  }

  final Config _config;
  final HttpClient _client;

  /// Statements are handed to the session one at a time: the queue is the tail
  /// of the chain, and each new call waits on it before running.
  Future<void> _queue = Future.value();

  /// A clock that cannot jump backwards over an idle connection, unlike the
  /// wall clock.
  final Stopwatch _clock = Stopwatch()..start();

  late List<String> _pendingUse;
  late List<String> _sessionDefaults;

  String? _sessionId;
  bool _autoCommit = true;
  bool _closed = false;

  /// When the connection last had an answer, or `null` before its first.
  Duration? _lastUsedAt;

  /// Whether the caller has selected a scope themselves; if they have, the
  /// DSN's defaults are no longer the whole truth about this session.
  bool _sessionTouched = false;

  /// Whether the engine reports `newSession` — which arrived together with
  /// `requireSession` and `DELETE /api/sessions/{id}` — or `null` until the
  /// first answer that names a session settles it.
  bool? _tracksSessions;

  /// Set once a statement left state behind that a fresh session would not
  /// have (see [touchesSession]); cleared when the DSN's scope goes back on.
  bool _dirty = false;

  /// Whether a transaction is open on the session: set by a `BEGIN` or `START
  /// TRANSACTION` that succeeded, cleared by a `COMMIT` or `ROLLBACK`, however
  /// each was sent.
  bool _inTransaction = false;

  /// The engine's id for this connection's session, once it has one.
  String? get sessionId => _sessionId;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Whether a transaction is open — that is, whether [begin] has run without a
  /// matching [commit] or [rollback].
  bool get inTransaction => !_autoCommit;

  /// The server this connection speaks to, as `scheme://host:port`.
  String get baseUrl => _config.baseUrl;

  /// Runs one statement and returns its first result set.
  ///
  /// [parameters] fill the statement's positional `?` placeholders; the count
  /// has to match exactly whenever arguments are supplied. With none at all
  /// the `?` marks pass through to the server — they are what a Snowflake
  /// Scripting cursor placeholder looks like, bound by `OPEN c USING (...)`. A
  /// string holding several `;`-separated statements answers with the first
  /// one's result — use [executeAll] for the rest.
  Future<Result> execute(String sql,
          [List<Object?> parameters = const []]) async =>
      (await executeAll(sql, parameters)).first;

  /// Runs one statement with `:name` placeholders and returns its first result
  /// set.
  ///
  /// Names match case-insensitively and order does not matter. With **no**
  /// parameters at all, use [execute] instead: colon references then belong to
  /// the server — they are what Snowflake Scripting variables look like
  /// (`EXECUTE IMMEDIATE :v`, `IFF(:flag, ...)`) — and pass through untouched.
  Future<Result> executeNamed(
          String sql, Map<String, Object?> parameters) async =>
      (await executeAllNamed(sql, parameters)).first;

  /// Runs a statement string and returns every result set it produced, in
  /// order. A single statement gives a one-element list.
  ///
  /// `async`, so a bind problem or a closed connection arrives as a rejected
  /// Future rather than a synchronous throw — one that `Future.wait`,
  /// `catchError` and `unawaited` would never see.
  Future<List<Result>> executeAll(String sql,
          [List<Object?> parameters = const []]) async =>
      _run(sql, substitutePositional(sql, parameters));

  /// Runs a statement string with `:name` placeholders and returns every result
  /// set it produced, in order.
  Future<List<Result>> executeAllNamed(
          String sql, Map<String, Object?> parameters) async =>
      _run(sql, substituteNamed(sql, parameters));

  /// Runs a statement string that says how many statements it holds, and
  /// returns every result set it produced, in order.
  ///
  /// The engine refuses a request holding more statements than it was told to
  /// expect, so a pack says how many it holds:
  ///
  /// ```dart
  /// await conn.executeAllDeclaring('SELECT 1; SELECT 2', multiStatementCount: 2);
  /// ```
  ///
  /// [multiStatementCount] travels with this one request. It outranks the
  /// session's `MULTI_STATEMENT_COUNT` without changing it, so there is nothing
  /// to put back afterwards, and `0` allows any number. Left out, no count is
  /// sent at all and the session's value decides, exactly as it does for every
  /// other method here.
  ///
  /// [parameters] fill positional `?` markers and [namedParameters] fill
  /// `:name` ones, as they do for [executeAll] and [executeAllNamed]; at most
  /// one of the two. They are named here because Dart allows named arguments
  /// only on a signature with no optional positional ones — which is also why
  /// the count lives on a method of its own rather than on [executeAll].
  Future<List<Result>> executeAllDeclaring(
    String sql, {
    int? multiStatementCount,
    List<Object?> parameters = const [],
    Map<String, Object?>? namedParameters,
  }) async {
    if (parameters.isNotEmpty && namedParameters != null) {
      throw const UsageException('give parameters or namedParameters, not both: '
          'a statement carries one placeholder style');
    }
    final rendered = namedParameters == null
        ? substitutePositional(sql, parameters)
        : substituteNamed(sql, namedParameters);
    return _run(sql, rendered, _statementCount(multiStatementCount));
  }

  Future<List<Result>> _run(String sql, String rendered,
      [int? multiStatementCount]) {
    _checkOpen();
    // The pending USE statements and the statement itself have to reach the
    // session as one unit: another caller must not slip a query in between, and
    // two must not both try to send the same pending entry.
    return _serialize(() async {
      _restoreSessionDefaults();
      final body = await _statement(rendered,
          multiStatementCount: multiStatementCount, scoped: true);
      if (changesSessionScope(sql)) _sessionTouched = true;
      _track(sql);
      return _shapeResults(body);
    });
  }

  /// Sends one statement of the caller's — after the pending DSN scope when
  /// [scoped] — and replaces a session the engine no longer holds.
  ///
  /// The engine answers 404 to a request that requires a session it does not
  /// have, and runs nothing. When the lost session held nothing a fresh one
  /// could not reproduce, the DSN's scope goes onto a fresh session and the
  /// statement is sent once more; otherwise [_loseSession] raises.
  Future<Map<String, Object?>> _statement(String sql,
      {int? multiStatementCount, bool? autoCommit, bool scoped = false}) async {
    final answer =
        await _unit(sql, multiStatementCount, autoCommit, scoped: scoped);
    if (answer != null) return answer;
    _loseSession(sql);
    final again =
        await _unit(sql, multiStatementCount, autoCommit, scoped: true);
    if (again != null) return again;
    _sessionId = null;
    _startOver();
    throw SessionLostException(
        'the engine refused a session it had just started',
        statement: sql);
  }

  /// The pending DSN scope when [scoped], then [sql]: `null` when the engine
  /// refused the session as unknown on any of them, so that neither that
  /// request nor anything after it ran.
  Future<Map<String, Object?>?> _unit(
      String sql, int? multiStatementCount, bool? autoCommit,
      {required bool scoped}) async {
    if (scoped && !await _drainScope()) return null;
    return _roundTrip(sql, multiStatementCount, autoCommit);
  }

  /// Sends the pending `USE` statements; `false` when the engine refused the
  /// session as unknown.
  Future<bool> _drainScope() async {
    while (_pendingUse.isNotEmpty) {
      // Each USE leaves the queue only once it has succeeded. A DSN naming a
      // database that does not exist has to keep failing; the alternative is
      // later statements quietly running in the default scope. Each is one
      // statement of its own, whatever the request behind it declares.
      final queue = _pendingUse;
      if (await _roundTrip(queue.first) == null) return false;
      // An answer saying the engine replaced the session queued the whole
      // scope afresh, and that queue starts from the top.
      if (identical(queue, _pendingUse)) queue.removeAt(0);
    }
    return true;
  }

  /// The engine no longer holds the session — it expired, was released, or
  /// the server restarted — and nothing ran. The next request starts a fresh
  /// session on the DSN's scope.
  ///
  /// With an open transaction or a moved context gone with it, re-running the
  /// statement would put it somewhere its author did not intend, so that is
  /// refused here rather than done.
  void _loseSession(String sql) {
    final hadTransaction = _inTransaction || !_autoCommit;
    final hadContext = _dirty;
    _sessionId = null;
    _startOver();
    if (hadTransaction) {
      _autoCommit = true;
      throw SessionLostException(
          "the engine no longer holds this connection's session (it expired, "
          'was released, or the server restarted), so its open transaction is '
          'gone; the statement did not run',
          statement: sql);
    }
    if (hadContext) {
      throw SessionLostException(
          "the engine no longer holds this connection's session (it expired, "
          'was released, or the server restarted), and the context set up on '
          'it (USE, SET, ALTER SESSION or a temporary object) went with it, so '
          'the statement was not re-run; the next statement starts a fresh '
          "session on the connection's scope",
          statement: sql);
    }
  }

  /// Forgets what the session held: the one the next statement meets is fresh,
  /// and gets the DSN's scope first.
  void _startOver() {
    _dirty = false;
    _inTransaction = false;
    _sessionTouched = false;
    _pendingUse = [..._sessionDefaults];
  }

  /// Follows what a statement that succeeded did to the session.
  void _track(String sql) {
    for (final statement in splitStatements(sql)) {
      if (touchesSession(statement)) _dirty = true;
      final effect = transactionEffect(statement);
      if (effect == TransactionEffect.begins) _inTransaction = true;
      if (effect == TransactionEffect.ends) _inTransaction = false;
    }
  }

  /// Selects the database, schema, role and warehouse the DSN names.
  ///
  /// [connect] calls this, so it is only worth calling again after the session
  /// has been moved somewhere else deliberately.
  Future<void> applyDsnScope() async {
    _checkOpen();
    if (_sessionDefaults.isEmpty) return;
    await _serialize(() async {
      // Re-queue the whole scope: [connect] drained the queue already, so
      // without this a second call would send nothing and report success.
      _pendingUse = [..._sessionDefaults];
      _sessionTouched = false;
      if (!await _drainScope()) {
        // The refused USE is still at the head of the queue.
        final refused = _pendingUse.first;
        _loseSession(refused);
        if (!await _drainScope()) {
          _sessionId = null;
          _startOver();
          throw SessionLostException(
              'the engine refused a session it had just started',
              statement: refused);
        }
      }
      _dirty = false;
    });
  }

  /// Checks that a Frostlake engine is answering, via `GET /api/health`.
  ///
  /// A 200 on its own only says something is listening — anything can serve
  /// that. The health payload is what says it is an engine, so a body that is
  /// not one is reported rather than passed off as healthy.
  Future<void> ping() async {
    _checkOpen();
    final endpoint = '${_config.baseUrl}/api/health';
    final answer = await _get(endpoint);
    final health = _decodeBody(endpoint, answer);
    if (health['status'] == null) {
      throw ConnectionException(
          '$endpoint answered HTTP ${answer.status} with a body that is not a '
          'Frostlake response: ${_snippet(answer.body)}',
          endpoint: endpoint,
          status: answer.status);
    }
  }

  /// Reads a response body as the JSON object a Frostlake answer is.
  ///
  /// A proxy error page, the wrong port, a crashed server: report what came
  /// back rather than where the JSON parser gave up, which is the difference
  /// between "malformed JSON at offset 0" and a message naming the address that
  /// answered.
  Map<String, Object?> _decodeBody(String endpoint, _Answer answer) {
    Object? decoded;
    try {
      decoded = decodeJson(answer.body);
    } on ConnectionException {
      decoded = null;
    }
    if (decoded is! Map<String, Object?>) {
      throw ConnectionException(
          '$endpoint answered HTTP ${answer.status} with a body that is not a '
          'Frostlake response: ${_snippet(answer.body)}',
          endpoint: endpoint,
          status: answer.status);
    }
    return decoded;
  }

  /// Opens a transaction: autocommit goes off and `BEGIN` is sent.
  Future<void> begin() async {
    _checkOpen();
    await _serialize(() async {
      // BEGIN travels with autocommit off, the mode the transaction runs in;
      // the connection takes that mode on only once BEGIN has succeeded.
      await _statement('BEGIN', autoCommit: false);
      _autoCommit = false;
      _track('BEGIN');
    });
  }

  /// Commits the open transaction and restores autocommit.
  Future<void> commit() async {
    _checkOpen();
    await _serialize(() async {
      try {
        await _statement('COMMIT');
        _track('COMMIT');
      } finally {
        _autoCommit = true;
      }
    });
  }

  /// Rolls the open transaction back and restores autocommit.
  Future<void> rollback() async {
    _checkOpen();
    await _serialize(() async {
      try {
        await _statement('ROLLBACK');
      } finally {
        _autoCommit = true;
        _inTransaction = false;
      }
    });
  }

  /// Runs [body] inside `BEGIN` ... `COMMIT`, rolling back if it throws.
  ///
  /// The connection is *not* held for the duration: a transaction lives on the
  /// session, so anything else run on this same connection meanwhile joins the
  /// transaction. Give a transaction its own connection if that is not what you
  /// want.
  Future<T> transaction<T>(
      Future<T> Function(Connection connection) body) async {
    await begin();
    final T result;
    try {
      result = await body(this);
    } on Object {
      try {
        await rollback();
      } on Object {
        // A failed rollback must not replace the error that caused it.
      }
      rethrow;
    }
    await commit();
    return result;
  }

  /// Closes the connection, releasing the engine session behind it.
  ///
  /// The release is one `DELETE /api/sessions/{id}`, which also rolls back a
  /// transaction left open on the session. It is a courtesy: bounded to five
  /// seconds (less when the DSN's `timeout` is shorter), and a release that
  /// fails or never answers is not an error — the engine expires the session
  /// on its own. An engine before 0.1.0 has no such endpoint and is sent
  /// nothing; its session lingers until that expiry, as it always did.
  ///
  /// Closing frees the client's sockets, and lets the next statement on this
  /// object fail loudly rather than quietly opening a second session. Closing
  /// again does nothing.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Let a statement already in flight finish before the sockets go, so its
    // caller gets an answer rather than a torn connection.
    try {
      await _queue;
    } on Object {
      // Its own caller is the one who hears about that failure.
    }
    await _release();
    _client.close(force: true);
  }

  /// Sends the `DELETE` that ends the session, when there is one to end and
  /// the engine is known to have the endpoint. Never throws.
  Future<void> _release() async {
    final id = _sessionId;
    _sessionId = null;
    _inTransaction = false;
    if (id == null || _tracksSessions != true) return;
    final endpoint =
        '${_config.baseUrl}/api/sessions/${Uri.encodeComponent(id)}';
    final timeout = _config.timeout;
    final limit = timeout == Duration.zero || timeout > _releaseLimit
        ? _releaseLimit
        : timeout;
    final inFlight = _InFlight();
    Future<void> send() async {
      final request = await _client.deleteUrl(Uri.parse(endpoint));
      inFlight.request = request;
      final response = await request.close();
      await response.drain<void>();
    }

    try {
      await send().timeout(limit,
          onTimeout: () => inFlight.abort(TimeoutException(
              '$endpoint did not answer within ${_describe(limit)}', limit)));
    } on Object {
      // Whatever became of it, the connection is closed: a session the engine
      // did not release expires on its own.
    }
  }

  void _checkOpen() {
    if (_closed) throw const UsageException('the connection is closed');
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final previous = _queue;
    final gate = Completer<void>();
    _queue = gate.future;
    return previous.then((_) => action()).whenComplete(gate.complete);
  }

  /// An engine before 0.1.0 reclaims a session once it has been idle long
  /// enough, then quietly builds a fresh one for the id we keep sending —
  /// losing the scope we selected. Nothing in the reply gives it away: the id
  /// we sent is echoed back either way. So past the limit the only safe reading
  /// is that the session is new, and the DSN's defaults go back on.
  ///
  /// Not once the caller has selected a scope themselves: putting our defaults
  /// over their choice is its own surprise.
  ///
  /// An engine that reports `newSession` needs no clock: the connection
  /// requires its session, so a lost one is refused rather than rebuilt, and
  /// the statement that finds it gone puts the scope back (see [_statement]).
  void _restoreSessionDefaults() {
    if (_tracksSessions != false) return;
    if (_sessionDefaults.isEmpty || _sessionTouched) return;
    if (_config.idleLimit == Duration.zero) return;
    final last = _lastUsedAt;
    if (last == null) return;
    if (_clock.elapsed - last < _config.idleLimit) return;
    _pendingUse = [..._sessionDefaults];
  }

  /// One `POST /api/execute`, with no recovery: the decoded answer, or `null`
  /// when the engine refused the session as unknown and ran nothing.
  Future<Map<String, Object?>?> _roundTrip(String sql,
      [int? multiStatementCount, bool? autoCommit]) async {
    final endpoint = '${_config.baseUrl}/api/execute';
    final id = _sessionId;
    // Resume this session or refuse: without the flag, an engine that no
    // longer holds the session starts a fresh one under the same id, at its
    // default scope, and runs the statement there. Only an engine known to
    // read the flag is sent it; an older one's parser need not accept a field
    // it does not know.
    final requireSession = id != null && _tracksSessions == true;
    final payload = encodeJson(<String, Object?>{
      'sql': sql,
      if (id != null) 'sessionId': id,
      if (requireSession) 'requireSession': true,
      'autoCommit': autoCommit ?? _autoCommit,
      // Absent unless the caller asked for a count: a request without the field
      // is the one the server has always seen, and the session's value decides.
      if (multiStatementCount != null)
        'multiStatementCount': multiStatementCount,
    });

    final inFlight = _InFlight();
    final _Answer answer;
    try {
      answer = await _withTimeout(
          () => _post(endpoint, payload, inFlight), endpoint, inFlight);
    } on ConnectionException {
      rethrow;
    } on Object catch (e) {
      throw ConnectionException('$endpoint: $e', endpoint: endpoint, cause: e);
    }

    final decoded = _decodeBody(endpoint, answer);

    // The one answer that names no session for a request that required one:
    // the session is gone, and nothing ran.
    if (answer.status == HttpStatus.notFound &&
        requireSession &&
        decoded['success'] != true &&
        decoded['sessionId'] == null) {
      return null;
    }

    _absorbSession(decoded, sentId: id != null);

    if (decoded['success'] != true) {
      throw QueryException(_failureMessage(decoded, answer),
          statement: sql, status: answer.status);
    }
    _lastUsedAt = _clock.elapsed;
    return decoded;
  }

  /// Keeps the session an answer names, and learns from it whether the engine
  /// tracks sessions: a `newSession` field, true or false, says it does.
  void _absorbSession(Map<String, Object?> decoded, {required bool sentId}) {
    final session = decoded['sessionId'];
    if (session is! String || session.isEmpty) return;
    _sessionId = session;
    final started = decoded['newSession'];
    if (started is bool) {
      _tracksSessions = true;
      // The engine ran the statement in a fresh session in place of ours:
      // whatever the old one held is gone, and the DSN's scope goes back on
      // before the next statement.
      if (started && sentId) _startOver();
    } else {
      _tracksSessions ??= false;
    }
  }

  Future<T> _withTimeout<T>(Future<T> Function() action, String endpoint,
      [_InFlight? inFlight]) {
    final limit = _config.timeout;
    if (limit == Duration.zero) return action();
    return action().timeout(limit, onTimeout: () {
      final message = '$endpoint did not answer within ${_describe(limit)}';
      // Stop the request as well as the wait. Left in flight it would hold its
      // socket until the engine answered, and — the engine running a session's
      // statements one at a time — every later statement would queue behind it
      // server-side and time out in turn, each leaking one more socket.
      inFlight?.abort(TimeoutException(message, limit));
      throw ConnectionException(message, endpoint: endpoint);
    });
  }

  Future<_Answer> _post(String endpoint, String payload,
      [_InFlight? inFlight]) async {
    final request = await _client.postUrl(Uri.parse(endpoint));
    inFlight?.request = request;
    request.headers.contentType = ContentType.json;
    // Sockets are reused, which is HttpClient's default. Measured against a
    // real DatabaseHttpServer, a kept-alive connection is a shade faster than a
    // fresh one per statement with no stalls in either mode, and it keeps a
    // busy caller from churning through ephemeral ports. `close` drops them.
    request.add(utf8.encode(payload));
    final response = await request.close();
    return _Answer(response.statusCode, await _readBody(response));
  }

  Future<_Answer> _get(String endpoint) async {
    try {
      return await _withTimeout(() async {
        final request = await _client.getUrl(Uri.parse(endpoint));
        final response = await request.close();
        final body = await _readBody(response);
        if (response.statusCode != HttpStatus.ok) {
          throw ConnectionException(
              '$endpoint answered HTTP ${response.statusCode}: ${_snippet(body)}',
              endpoint: endpoint,
              status: response.statusCode);
        }
        return _Answer(response.statusCode, body);
      }, endpoint);
    } on ConnectionException {
      rethrow;
    } on Object catch (e) {
      throw ConnectionException('cannot reach $endpoint: $e',
          endpoint: endpoint, cause: e);
    }
  }

  Future<String> _readBody(HttpClientResponse response) =>
      response.transform(utf8.decoder).join();

  /// Never returns the empty string: a response can report failure carrying no
  /// message at all, and an error that prints as nothing tells the caller less
  /// than the status code would.
  String _failureMessage(Map<String, Object?> body, _Answer answer) {
    final message = body['errorMessage'];
    if (message is String && message.isNotEmpty) return message;
    final error = body['error'];
    if (error is String && error.isNotEmpty) return error;
    return 'the statement failed with HTTP ${answer.status} and no error '
        'message: ${_snippet(answer.body)}';
  }

  List<Result> _shapeResults(Map<String, Object?> body) {
    final sets = body['resultSets'];
    if (sets is! List || sets.isEmpty) {
      return [Result(columns: const [], values: const [], updateCount: -1)];
    }
    return [
      for (final set in sets)
        if (set is Map<String, Object?>) _shapeResult(set),
    ];
  }

  Result _shapeResult(Map<String, Object?> set) {
    final columns = <ColumnInfo>[];
    final rawColumns = set['columns'];
    if (rawColumns is List) {
      for (final column in rawColumns) {
        if (column is! Map<String, Object?>) continue;
        columns.add(ColumnInfo(
          name: _asString(column['name']) ?? '',
          dataType: _asString(column['dataType']) ?? '',
          nullable:
              column['nullable'] is bool ? column['nullable']! as bool : null,
          precision: _asInt(column['precision']),
          scale: _asInt(column['scale']),
          length: _asInt(column['length']),
        ));
      }
    }

    final values = <List<Object?>>[];
    final rawRows = set['rows'];
    if (rawRows is List) {
      for (final row in rawRows) {
        if (row is! List) continue;
        values.add([
          for (var i = 0; i < columns.length; i++)
            convertCell(i < row.length ? row[i] : null, columns[i]),
        ]);
      }
    }

    // The protocol carries no statement type, so a DML answer is recognised by
    // its shape: a single row whose every column is a "number of ..." counter.
    // INSERT and DELETE report one, UPDATE adds "number of multi-joined rows
    // updated", and MERGE reports an inserted and an updated count.
    if (values.length == 1 &&
        columns.isNotEmpty &&
        columns.every((c) => c.name.toLowerCase().startsWith('number of '))) {
      final counters = <String, int>{};
      var affected = 0;
      for (var i = 0; i < columns.length; i++) {
        final count = _asInt(values.first[i]);
        if (count == null) continue;
        counters[columns[i].name] = count;
        // "number of multi-joined rows updated" is a diagnostic sub-count of
        // rows already counted as updated, so only the "number of rows ..."
        // counters are summed.
        if (columns[i].name.toLowerCase().startsWith('number of rows ')) {
          affected += count;
        }
      }
      // The grid itself is kept rather than folded away. A statement whose
      // answer merely LOOKS like a status grid is indistinguishable from one
      // that is — `... ->> SELECT * FROM $1` reads a DML result as a table, and
      // hiding its rows lost the only copy of them.
      return Result(
          columns: columns,
          values: values,
          updateCount: affected,
          counters: Map.unmodifiable(counters));
    }

    return Result(columns: columns, values: values, updateCount: -1);
  }
}

/// The request a statement has in flight, so a timeout can abort it.
class _InFlight {
  HttpClientRequest? request;

  void abort(Object reason) => request?.abort(reason);
}

class _Answer {
  const _Answer(this.status, this.body);

  final int status;
  final String body;
}

/// The statement count a call declares, checked here so a bad value is a usage
/// error rather than a request body the engine cannot read.
int? _statementCount(int? given) {
  if (given == null) return null;
  if (given < 0) {
    throw UsageException('multiStatementCount is a whole number of statements, '
        '0 for any number, not $given');
  }
  return given;
}

String? _asString(Object? value) => value is String ? value : null;

int? _asInt(Object? value) => switch (value) {
      final int n => n,
      final BigInt n => n.isValidInt ? n.toInt() : null,
      final double d => d == d.roundToDouble() ? d.toInt() : null,
      final JsonNumber n => n.asInt,
      final String s => int.tryParse(s),
      _ => null,
    };

String _snippet(String payload) {
  final text = payload.trim();
  if (text.isEmpty) return '(empty body)';
  if (text.length > _maxErrorBody) {
    return '${text.substring(0, _maxErrorBody)}…';
  }
  return text;
}

String _describe(Duration limit) {
  if (limit.inMilliseconds < 1000) return '${limit.inMilliseconds}ms';
  final seconds = limit.inMilliseconds / 1000;
  return seconds == seconds.roundToDouble()
      ? '${seconds.round()}s'
      : '${seconds}s';
}
