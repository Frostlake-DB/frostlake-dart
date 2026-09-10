import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A real `DatabaseHttpServer`, booted from an engine classpath for the tests
/// that need one.
///
/// Nothing here is mocked: every statement the integration tests run travels
/// the driver's own HTTP path to a live engine. Without `FROSTLAKE_CLASSPATH`
/// there is no server, and the tests that need one skip themselves rather than
/// passing on a stub — a green suite that never reached an engine would be
/// worse than a skipped one.
class TestServer {
  TestServer._(this.dsn, this._process, this._log, this._drained, this._home);

  /// A DSN pointing at this server, with no database or schema selected.
  final String dsn;

  final Process _process;
  final IOSink _log;

  /// Completes once both of the engine's pipes have been copied into the log.
  final Future<void> _drained;

  /// The engine's private home directory for this run.
  final Directory _home;

  /// The engine classpath the tests were given, or `null` when they were given
  /// none.
  static String? get classpath {
    final value = Platform.environment['FROSTLAKE_CLASSPATH'];
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Why the integration tests cannot run, or `null` when they can.
  static String? get skipReason => classpath == null
      ? 'FROSTLAKE_CLASSPATH is not set, so no engine can be started'
      : null;

  static String get _java {
    final home = Platform.environment['JAVA_HOME'];
    if (home == null || home.isEmpty) return 'java';
    return '$home${Platform.pathSeparator}bin${Platform.pathSeparator}java';
  }

  /// Boots a server on a free port and waits for it to answer.
  static Future<TestServer> start() async {
    // Bind port 0 to have the OS name a free one, then hand it straight to the
    // engine. A race is possible in principle and has never been the problem in
    // practice; picking a fixed port collides with a developer's own server.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final log = File('${Directory.systemTemp.path}${Platform.pathSeparator}'
        'frostlake-dart-server-$port.log');
    // Closed in stop(); the lint cannot see across that boundary.
    // ignore: close_sinks
    final sink = log.openWrite();
    // A default-configured engine persists outside its working directory —
    // stages under ~/.frostlake_stages, the catalog under ~/.frostlake_engine
    // when persistence is on — so consecutive runs would inherit each other's
    // objects. This run gets its own home, which also keeps the engine's
    // db-engine.log out of the repository.
    final home = Directory.systemTemp.createTempSync('frostlake-dart-engine-');
    final process = await Process.start(
      _java,
      [
        '-Duser.home=${home.path}',
        '-cp',
        classpath!,
        'dev.frostlake.http.DatabaseHttpServer',
        '$port',
      ],
      workingDirectory: home.path,
      environment: {
        'SQL_ENGINE_DATA_DIR': '${home.path}${Platform.pathSeparator}data',
      },
    );
    // A real log file, not a null sink: a full pipe would block the server, and
    // the log is what says why a boot failed anyway. The copies are awaited in
    // stop(), so the sink is not closed under them.
    final drained = Future.wait<void>([
      process.stdout.transform(utf8.decoder).forEach(sink.write),
      process.stderr.transform(utf8.decoder).forEach(sink.write),
    ]);

    final server = TestServer._(
        'frostlake://127.0.0.1:$port', process, sink, drained, home);
    try {
      await server._waitUntilHealthy(port);
    } on Object {
      await server.stop();
      throw StateError('the engine did not answer /api/health within 30s; '
          'see ${log.path}');
    }
    return server;
  }

  Future<void> _waitUntilHealthy(int port) async {
    final client = HttpClient();
    final deadline = Stopwatch()..start();
    try {
      while (deadline.elapsed < const Duration(seconds: 30)) {
        try {
          final request = await client
              .getUrl(Uri.parse('http://127.0.0.1:$port/api/health'));
          final response = await request.close();
          await response.drain<void>();
          if (response.statusCode == HttpStatus.ok) return;
        } on Object {
          // Not up yet.
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw TimeoutException('no answer from /api/health');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> stop() async {
    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode;
    await _drained;
    await _log.flush();
    await _log.close();
    try {
      _home.deleteSync(recursive: true);
    } on FileSystemException {
      // A handle still held by the dying JVM; the temp directory can wait.
    }
  }
}
