import 'dart:io';
import 'dart:typed_data';

import 'package:frostlake/frostlake.dart';
import 'package:frostlake/src/json.dart';
import 'package:frostlake/src/values.dart';
import 'package:test/test.dart';

import 'src/test_server.dart';

/// Runs the engine-owned, language-neutral JSON test suites through THIS
/// driver.
///
/// The definitions live in the frostlake repo
/// (`engine/src/test/resources/testkit/suites/*.json`, spec in `SCHEMA.md` next
/// to them); every statement travels `connect` -> HTTP -> `DatabaseHttpServer`.
/// The engine owns the definitions and this file is only the Dart driver's
/// runner, so suites added on the engine side are picked up here with no driver
/// change at all.
///
/// ```sh
/// export FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit
/// JAVA_HOME=... FROSTLAKE_CLASSPATH=... dart test test/suites_test.dart
/// ```
///
/// `FL_CORPUS` names the testkit directory whose `suites/*.json` replay (a
/// relative path resolves against the working directory, the package root).
/// Without it this file is a single skipped test, and one holding no suites
/// fails it. Without `FROSTLAKE_CLASSPATH` every case skips — never falsely
/// green.
///
/// Semantics (mirrors SCHEMA.md and the Go, Ruby and dotnet runners):
///  * backend name for a suite's skip clause: `dart`; `http` entries are
///    honoured too, because this driver rides the HTTP transport and the same
///    engine.
///  * per-test isolation: `CREATE OR REPLACE DATABASE test_db` -> `USE` ->
///    `CREATE OR REPLACE SCHEMA test_schema` -> `USE`, then the steps on ONE
///    connection, which is what keeps USE, variables and transactions on a
///    single session.
///  * capabilities: SESSION, COLUMN_NAMES, UPDATE_COUNT. No ERROR_CODE — the
///    HTTP protocol carries a message only, so expected-error code/sqlState
///    checks are recorded as missing-API notes instead of failing.
const String backend = 'dart';

/// Notes collected while running: capabilities the transport cannot express,
/// and the driver limits a case ran into.
final Set<String> notes = <String>{};

/// Set once the engine stopped answering, with the failure that showed it. One
/// dead engine used to fail every remaining case on "cannot reach", thousands
/// of times over; now the rest of the run is skipped with the reason.
String? _engineLost;

void main() {
  final corpus = Platform.environment['FL_CORPUS'] ?? '';
  if (corpus.isEmpty) {
    test('testkit', () {},
        skip: "set FL_CORPUS to frostlake's engine/src/test/resources/testkit "
            'to replay the testkit corpus');
    return;
  }
  final suites = '$corpus${Platform.pathSeparator}suites';
  final files = _suiteFiles(suites);
  if (files.isEmpty) {
    test('testkit',
        () => fail('FL_CORPUS=$corpus: no *.json suites in $suites'));
    return;
  }

  group('testkit', () {
    late TestServer server;

    setUpAll(() async => server = await TestServer.start());

    tearDownAll(() async {
      await server.stop();
      for (final note in notes.toList()..sort()) {
        // ignore: avoid_print
        print(note);
      }
    });

    for (final file in files) {
      final suite = decodeJson(file.readAsStringSync());
      if (suite is! Map<String, Object?>) continue;
      final name = file.uri.pathSegments.last.replaceAll('.json', '');
      final cases = suite['tests'];
      if (cases is! List) continue;

      group(name, () {
        // One connection — one engine session — per suite file, the other
        // runners' default (FROSTLAKE_TESTKIT_SESSION=suite): a sweep then
        // costs 685 sockets and sessions rather than ~6800, and the reset
        // before every case is what isolates the cases from each other.
        Connection? conn;
        setUpAll(() async {
          if (_engineLost != null) return;
          try {
            conn = await connect(server.dsn);
            // A case whose step holds several statements is a pack, which the engine
            // refuses unless the session asks for one; the corpus asks for any number.
            await conn!.execute('ALTER SESSION SET MULTI_STATEMENT_COUNT = 0');
          } on ConnectionException catch (e) {
            _engineLost ??= e.message;
          }
        });
        tearDownAll(() async => conn?.close());
        for (final entry in cases) {
          if (entry is! Map<String, Object?>) continue;
          final caseName = entry['name']?.toString() ?? '(unnamed)';
          test(caseName, () async {
            final connection = conn;
            if (_engineLost != null || connection == null) {
              markTestSkipped('the engine stopped answering: $_engineLost');
              return;
            }
            await _runCase(connection, entry);
          }, skip: _skipReasonFor(entry));
        }
      });
    }
  }, skip: TestServer.skipReason);
}

/// A suite may declare that a backend cannot run a case.
String? _skipReasonFor(Map<String, Object?> entry) {
  final skip = entry['skip'];
  if (skip is! Map<String, Object?>) return null;
  final backends = skip['backends'];
  if (backends is! List) return null;
  final named = backends.map((b) => b.toString().toLowerCase()).toSet();
  if (!named.contains(backend) && !named.contains('http')) return null;
  return 'declared in the suite: ${skip['reason'] ?? 'no reason given'}';
}

Future<void> _runCase(Connection conn, Map<String, Object?> entry) async {
  await _resetContext(conn);
  final steps = entry['steps'];
  if (steps is! List) return;
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    if (step is! Map<String, Object?>) continue;
    final sql = step['sql']?.toString() ?? '';
    final outcome = await _run(conn, sql);
    final problem = _check(step['expect'], outcome, sql);
    if (problem != null) {
      fail('step ${i + 1}: $problem\n  [sql: $sql]');
    }
  }
}

/// The reset sequence SCHEMA.md prescribes: every case starts in an empty
/// `test_db.test_schema`.
Future<void> _resetContext(Connection conn) async {
  for (final sql in const [
    'CREATE OR REPLACE DATABASE test_db',
    'USE DATABASE test_db',
    'CREATE OR REPLACE SCHEMA test_schema',
    'USE SCHEMA test_schema',
  ]) {
    final outcome = await _run(conn, sql);
    if (outcome.error != null) {
      fail('resetContext failed on "$sql": ${outcome.error}');
    }
  }
}

/// What one step produced: a grid, an update count, or a failure.
class _Outcome {
  _Outcome(
      {this.columns = const [],
      this.rows = const [],
      this.updateCount = -1,
      this.error});

  final List<String> columns;
  final List<List<String?>> rows;
  final int updateCount;
  final String? error;
}

Future<_Outcome> _run(Connection conn, String sql) async {
  try {
    final result = await conn.execute(sql);
    return _Outcome(
      columns: result.columns.map((c) => c.name).toList(),
      rows: [
        for (final row in result.values)
          [
            for (var i = 0; i < row.length; i++)
              _cellText(row[i], result.columns[i]),
          ],
      ],
      updateCount: result.updateCount,
    );
  } on QueryException catch (e) {
    return _Outcome(error: e.message);
  } on ConnectionException catch (e) {
    // The transport failed, not the statement: no expectation is satisfied by
    // that — a dead engine must not pass an `error` step — so it is an ERROR
    // in SCHEMA.md's terms. Find out whether the engine is still there, so the
    // rest of the run can stop instead of failing case by case.
    if (!await _engineAnswers(conn.baseUrl)) _engineLost = e.message;
    throw StateError('transport failure: ${e.message}');
  }
  // A UsageException — the driver refusing to send — propagates as it is: a
  // driver problem the case must surface, never a statement failure.
}

Future<bool> _engineAnswers(String baseUrl) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(Uri.parse('$baseUrl/api/health'))
        .timeout(const Duration(seconds: 5));
    final response = await request.close().timeout(const Duration(seconds: 5));
    await response.drain<void>();
    return response.statusCode == HttpStatus.ok;
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

String? _check(Object? expectation, _Outcome outcome, String sql) {
  if (expectation is! Map<String, Object?>) {
    return outcome.error == null ? null : 'unexpected error: ${outcome.error}';
  }

  if (expectation.containsKey('error')) {
    if (outcome.error == null) {
      return 'expected an error, the statement succeeded';
    }
    final expected = expectation['error'];
    if (expected is Map<String, Object?>) {
      final contains = expected['messageContains']?.toString();
      if (contains != null &&
          !outcome.error!.toLowerCase().contains(contains.toLowerCase())) {
        // A blank statement is refused by the HTTP endpoint itself — 400, "SQL
        // is required" — so the engine never runs it and never produces its own
        // wording. No driver over this transport can, which makes it a
        // capability gap rather than a mismatch. The statement did still fail.
        if (sql.trim().isEmpty) {
          notes.add('missing-API [$backend] EMPTY_STATEMENT: the HTTP API '
              'refuses a blank statement itself (HTTP 400 "SQL is required"), '
              "so the engine's own \"Empty SQL statement.\" error cannot be "
              'observed over this transport');
          return null;
        }
        return 'the error [${outcome.error}] does not contain [$contains]';
      }
      if (expected.containsKey('code') || expected.containsKey('sqlState')) {
        notes.add('missing-API [$backend] ERROR_CODE: failures carry a message '
            'only, so an error code or SQLSTATE cannot be checked');
      }
    }
    return null;
  }

  if (outcome.error != null) return 'unexpected error: ${outcome.error}';

  if (expectation.containsKey('value')) {
    final actual = outcome.rows.isEmpty || outcome.rows.first.isEmpty
        ? null
        : outcome.rows.first.first;
    final want = _normalize(_scalarText(expectation['value']));
    if (want != _normalize(actual)) {
      return 'value [${actual ?? 'NULL'}] != expected [${expectation['value']}]';
    }
  }

  if (expectation['rows'] case final List<Object?> wanted) {
    final want = [
      for (final row in wanted)
        if (row is List) row.map((c) => _normalize(_scalarText(c))).join(' | '),
    ];
    final got = [
      for (final row in outcome.rows) row.map(_normalize).join(' | '),
    ];
    if (expectation['ordered'] != true) {
      want.sort();
      got.sort();
    }
    if (want.join(' ;; ') != got.join(' ;; ')) {
      return 'rows differ:\n    expected $want\n    got      $got';
    }
  }

  if (expectation['rowCount'] case final Object wanted) {
    final want = _asInt(wanted);
    if (want != null && outcome.rows.length != want) {
      return 'rowCount ${outcome.rows.length} != expected $want';
    }
  }

  if (expectation['columns'] case final List<Object?> wanted) {
    final want = wanted.map((c) => c.toString().toUpperCase()).toList();
    final got = outcome.columns.map((c) => c.toUpperCase()).toList();
    if (want.join(',') != got.join(',')) {
      return 'columns $got != expected $want';
    }
  }

  if (expectation['updateCount'] case final Object wanted) {
    final want = _asInt(wanted);
    if (want != null && outcome.updateCount != want) {
      return 'updateCount ${outcome.updateCount} != expected $want';
    }
  }

  return null;
}

/// Renders a converted cell the way the other runners' transports render theirs.
String? _cellText(Object? value, ColumnInfo column) {
  switch (value) {
    case null:
      return null;
    case final bool b:
      return b ? 'true' : 'false';
    case final Uint8List bytes:
      return [
        for (final byte in bytes)
          byte.toRadixString(16).padLeft(2, '0').toUpperCase(),
      ].join();
    case final Duration d:
      return _timeText(d);
    case final DateTime t:
      return temporalKindOf(column.dataType) == TemporalKind.date
          ? '${_pad(t.year, 4)}-${_pad(t.month, 2)}-${_pad(t.day, 2)}'
          : _timestampText(t);
    case final String text:
      return _isSemiStructured(column.dataType)
          ? _semiStructuredValue(text)
          : text;
    default:
      return value.toString();
  }
}

/// Whether a column carries semi-structured values, read from the type the
/// engine declared.
bool _isSemiStructured(String dataType) {
  final name = dataType.toUpperCase();
  return name == 'VARIANT' || name == 'OBJECT' || name == 'ARRAY';
}

/// The value a semi-structured cell carries, as the suites record it.
///
/// A `VARIANT`, `OBJECT` or `ARRAY` cell reaches a client as its JSON *text* —
/// a string's own quotes included — which is what the account's own drivers do.
/// The suites record the *value* (`a`, not `"a"`), so such a cell is decoded
/// once: a JSON string becomes its content, which for a whole object or array
/// is the object's own text, and anything else — a number, a boolean, text that
/// is not JSON at all — is left exactly as it came. Only a semi-structured
/// *column* is decoded, so a `VARCHAR` whose content merely looks quoted keeps
/// its quotes.
String _semiStructuredValue(String text) {
  try {
    final decoded = decodeJson(text);
    return decoded is String ? decoded : text;
  } on ConnectionException {
    return text;
  }
}

String _timestampText(DateTime t) {
  // The engine renders milliseconds when that is all a value has, and more when
  // it has more; matching that keeps the exact-string comparison honest rather
  // than turning every timestamp into a formatting difference.
  final micros = t.microsecond;
  final fraction = micros == 0
      ? _pad(t.millisecond, 3)
      : _pad(t.millisecond * 1000 + micros, 6);
  return '${_pad(t.year, 4)}-${_pad(t.month, 2)}-${_pad(t.day, 2)} '
      '${_pad(t.hour, 2)}:${_pad(t.minute, 2)}:${_pad(t.second, 2)}.$fraction';
}

String _timeText(Duration d) {
  final micros = d.inMicroseconds.remainder(1000000);
  final base = '${_pad(d.inHours, 2)}:${_pad(d.inMinutes.remainder(60), 2)}:'
      '${_pad(d.inSeconds.remainder(60), 2)}';
  return micros == 0 ? base : '$base.${_pad(micros, 6)}';
}

String _pad(int value, int width) => value.toString().padLeft(width, '0');

/// The scalar an expectation names, as text.
String? _scalarText(Object? value) => switch (value) {
      null => null,
      final bool b => b ? 'true' : 'false',
      final JsonNumber n => n.text,
      _ => value.toString(),
    };

int? _asInt(Object? value) => switch (value) {
      final JsonNumber n => n.asInt,
      final int n => n,
      final String s => int.tryParse(s),
      _ => null,
    };

/// SCHEMA.md value normalization, applied to both sides before comparing:
/// `null`/empty becomes NULL, booleans compare case-insensitively, anything
/// numeric compares as a number rounded to 10 significant digits, and everything
/// else is an exact trimmed string.
String _normalize(String? value) {
  if (value == null) return 'NULL';
  final text = value.trim();
  if (text.isEmpty) return 'NULL';
  final lower = text.toLowerCase();
  if (lower == 'null') return 'NULL';
  if (lower == 'true') return 'TRUE';
  if (lower == 'false') return 'FALSE';
  final number = double.tryParse(text);
  if (number != null && number.isFinite) {
    return number == 0 ? '0' : _significant10(number);
  }
  return text;
}

/// The equivalent of `%.10g`: ten significant digits with trailing zeros
/// dropped, so `2` and `2.000000` compare equal and so do `3.5` and `3.500000`.
String _significant10(double value) {
  final text = value.toStringAsPrecision(10);
  final exponent = text.indexOf('e');
  if (exponent < 0) return _dropTrailingZeros(text);
  return '${_dropTrailingZeros(text.substring(0, exponent))}'
      '${text.substring(exponent)}';
}

String _dropTrailingZeros(String text) {
  if (!text.contains('.')) return text;
  var end = text.length;
  while (end > 0 && text.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  if (end > 0 && text.codeUnitAt(end - 1) == 0x2e) end--;
  return text.substring(0, end);
}

/// The suite files in [directory], none when it does not exist.
List<File> _suiteFiles(String directory) {
  final suites = Directory(directory);
  if (!suites.existsSync()) return const [];
  final entries = suites
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return entries;
}
