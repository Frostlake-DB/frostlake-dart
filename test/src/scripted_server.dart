import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// One request the driver sent, with its JSON body read back.
class Sent {
  Sent(this.method, this.path, this.body);

  final String method;
  final String path;

  /// The request's JSON object; empty for a request without a body.
  final Map<String, Object?> body;

  String? get sql => body['sql'] as String?;
  String? get sessionId => body['sessionId'] as String?;

  /// Whether the body carries the field at all, whatever its value.
  bool get hasRequireSession => body.containsKey('requireSession');
  Object? get requireSession => body['requireSession'];
  Object? get autoCommit => body['autoCommit'];

  @override
  String toString() => '$method $path ${jsonEncode(body)}';
}

/// What the stand-in does with one request.
class _Step {
  _Step.reply(this.status, this.body) : action = _Action.reply;
  _Step.hang()
      : action = _Action.hang,
        status = 0,
        body = '';
  _Step.drop()
      : action = _Action.drop,
        status = 0,
        body = '';

  final _Action action;
  final int status;
  final String body;
}

enum _Action { reply, hang, drop }

/// A stand-in engine that answers from a script and records what it was sent,
/// so a test can say exactly which round trips a scenario makes.
///
/// `GET /api/health` is answered as an engine answers it, unscripted; every
/// other request takes the next scripted step. A request with nothing scripted
/// for it is answered with HTTP 500 and kept in [unscripted] for the test to
/// fail on.
class ScriptedServer {
  ScriptedServer._(this._server) {
    _served = _server.forEach(_handle);
  }

  final HttpServer _server;
  late final Future<void> _served;
  final Queue<_Step> _script = Queue<_Step>();

  /// Requests held open by [hang], answered by nobody until [close].
  final List<HttpRequest> _held = [];

  /// Every request but the health check, in arrival order.
  final List<Sent> sent = [];

  /// Requests that arrived with nothing scripted for them.
  final List<Sent> unscripted = [];

  static Future<ScriptedServer> start() async =>
      ScriptedServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  /// A DSN for this stand-in; [suffix] carries a path and a query string.
  String dsn([String suffix = '']) =>
      'frostlake://127.0.0.1:${_server.port}$suffix';

  /// The next request is answered with [body] and [status].
  void reply(String body, {int status = HttpStatus.ok}) =>
      _script.add(_Step.reply(status, body));

  /// The next request is held open and never answered.
  void hang() => _script.add(_Step.hang());

  /// The next request's socket is closed without an answer.
  void drop() => _script.add(_Step.drop());

  /// How many scripted steps no request has taken yet.
  int get pending => _script.length;

  /// The SQL of every `POST /api/execute`, in order.
  List<String?> get statements => [
        for (final request in sent)
          if (request.path == '/api/execute') request.sql,
      ];

  /// Every `POST /api/execute`, in order.
  List<Sent> get executes => [
        for (final request in sent)
          if (request.path == '/api/execute') request
      ];

  Future<void> _handle(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    if (request.uri.path == '/api/health') {
      request.response.write('{"status":"healthy","activeSessions":0}');
      await request.response.close();
      return;
    }
    final decoded = text.isEmpty ? null : jsonDecode(text);
    final record = Sent(request.method, request.uri.path,
        decoded is Map<String, Object?> ? decoded : const {});
    sent.add(record);
    if (_script.isEmpty) {
      unscripted.add(record);
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('{"success":false,"errorMessage":"unscripted request"}');
      await request.response.close();
      return;
    }
    final step = _script.removeFirst();
    switch (step.action) {
      case _Action.reply:
        request.response
          ..statusCode = step.status
          ..headers.contentType = ContentType.json
          ..write(step.body);
        await request.response.close();
      case _Action.hang:
        _held.add(request);
      case _Action.drop:
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
    }
  }

  Future<void> close() async {
    await _server.close(force: true);
    for (final request in _held) {
      try {
        await request.response.close();
      } on Object {
        // Its client gave up on it long ago.
      }
    }
    await _served;
  }
}

/// A one-row result set holding a status line, as DDL and USE answer.
String statusSet(String text) =>
    '{"columns":[{"dataType":"VARCHAR","name":"status","nullable":false,'
    '"precision":0,"scale":0}],"rowCount":1,"rows":[["$text"]],'
    '"updateCount":-1}';

/// A one-row, one-column NUMBER result set.
String numberSet(String name, int value) =>
    '{"columns":[{"dataType":"NUMBER","name":"$name","nullable":false,'
    '"precision":38,"scale":0}],"rowCount":1,"rows":[[$value]],'
    '"updateCount":-1}';

/// An answer from an engine that reports `newSession` (0.1.0 and later).
String answer(String sessionId,
        {bool started = false, List<String> sets = const []}) =>
    '{"errorMessage":null,"executionTimeMs":1,"newSession":$started,'
    '"resultSets":[${sets.join(',')}],"sessionId":"$sessionId",'
    '"success":true}';

/// An answer from an engine that predates `newSession` (0.0.7).
String legacyAnswer(String sessionId, {List<String> sets = const []}) =>
    '{"errorMessage":null,"executionTimeMs":1,'
    '"resultSets":[${sets.join(',')}],"sessionId":"$sessionId",'
    '"success":true}';

/// A statement the engine refused, in the session it ran in.
String refused(String sessionId, String message) =>
    '{"errorMessage":${jsonEncode(message)},"executionTimeMs":0,'
    '"newSession":false,"resultSets":[],"sessionId":"$sessionId",'
    '"success":false}';

/// The 404 body a request that requires its session gets when it is gone.
String sessionGone(String sessionId) =>
    '{"errorMessage":"Session \'$sessionId\' does not exist or has expired.",'
    '"executionTimeMs":0,"newSession":false,"resultSets":[],'
    '"sessionId":null,"success":false}';

/// What `DELETE /api/sessions/{id}` answers for a live session.
const String released = '{"errorMessage":null,"executionTimeMs":0,'
    '"newSession":false,"resultSets":[],"sessionId":null,"success":true}';
