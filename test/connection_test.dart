import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:frostlake/frostlake.dart';
import 'package:test/test.dart';

import 'src/test_server.dart';

void main() {
  group('Connection', () {
    late TestServer server;
    late Connection conn;

    setUpAll(() async {
      server = await TestServer.start();
    });

    tearDownAll(() async => server.stop());

    setUp(() async {
      conn = await connect(server.dsn);
      await conn.execute('CREATE OR REPLACE DATABASE test_db');
      await conn.execute('USE DATABASE test_db');
      await conn.execute('CREATE OR REPLACE SCHEMA test_schema');
      await conn.execute('USE SCHEMA test_schema');
    });

    tearDown(() async => conn.close());

    test('reaches a real engine', () async {
      final result = await conn.execute('SELECT CURRENT_VERSION()');
      expect(result.value, isNotEmpty);
      expect(conn.sessionId, isNotNull);
    });

    test('runs DDL, DML and a query', () async {
      await conn.execute('CREATE TABLE people (id INTEGER, name VARCHAR)');

      final inserted = await conn
          .execute("INSERT INTO people VALUES (1, 'Ada'), (2, 'Grace')");
      expect(inserted.isUpdate, isTrue);
      expect(inserted.updateCount, 2);
      expect(inserted.rowCount, 2);

      final rows =
          await conn.execute('SELECT id, name FROM people ORDER BY id');
      expect(rows.isUpdate, isFalse);
      expect(rows.rowCount, 2);
      expect(rows.columns.map((c) => c.name), ['ID', 'NAME']);
      expect(rows.rows, [
        {'ID': 1, 'NAME': 'Ada'},
        {'ID': 2, 'NAME': 'Grace'},
      ]);
      expect(rows.value, 1);
    });

    test('counts an UPDATE without double-counting its sub-counter', () async {
      // UPDATE answers with "number of rows updated" AND "number of
      // multi-joined rows updated"; the latter counts rows already counted.
      await conn.execute('CREATE TABLE t (id INTEGER)');
      await conn.execute('INSERT INTO t VALUES (1), (2), (3)');
      final updated =
          await conn.execute('UPDATE t SET id = id + 10 WHERE id > 1');
      expect(updated.updateCount, 2);
      expect(updated.counters['number of multi-joined rows updated'], 0);
    });

    test('keeps a MERGE\'s counters apart while adding them up', () async {
      await conn.execute('CREATE TABLE target (id INTEGER, v VARCHAR)');
      await conn.execute("INSERT INTO target VALUES (1, 'a')");
      await conn.execute('CREATE TABLE source (id INTEGER, v VARCHAR)');
      await conn.execute("INSERT INTO source VALUES (1, 'x'), (2, 'y')");
      final merged = await conn.execute('''
        MERGE INTO target t USING source s ON t.id = s.id
        WHEN MATCHED THEN UPDATE SET t.v = s.v
        WHEN NOT MATCHED THEN INSERT (id, v) VALUES (s.id, s.v)''');
      expect(merged.updateCount, 2);
      expect(merged.counters['number of rows inserted'], 1);
      expect(merged.counters['number of rows updated'], 1);
    });

    test('keeps the DML status grid rather than folding it away', () async {
      // A statement whose answer merely looks like a status grid is
      // indistinguishable from one that is, so the rows are kept either way and
      // updateCount is the friendly reading of them.
      await conn.execute('CREATE TABLE grid (id INTEGER)');
      final inserted = await conn.execute('INSERT INTO grid VALUES (1), (2)');
      expect(inserted.columns.single.name, 'number of rows inserted');
      expect(inserted.values, [
        [2],
      ]);
      expect(inserted.updateCount, 2);
    });

    test('a query shaped like a status grid is still a query', () async {
      // The flow operator reads a DML result as a table; hiding its rows lost
      // the only copy of them.
      final flowed = await conn.execute(
          'CREATE TABLE flowed (id INTEGER) ->> SELECT 1 AS "number of rows inserted"');
      expect(flowed.values, [
        [1],
      ]);
    });

    test('DDL answers without throwing, and not as an update', () async {
      // Engines before 0.1.0 answer DDL with an empty result; 0.1.0 answers
      // with a one-row status grid, as live does.
      final result = await conn.execute('CREATE TABLE ddl_only (a INTEGER)');
      expect(result.isUpdate, isFalse);
      expect(result.rows.length, lessThanOrEqualTo(1));
      expect(result.value, anyOf(isNull, isA<String>()));
    });

    test('answers a multi-statement request with one result each', () async {
      // A pack has to be asked for, as the account requires; 0 means any number.
      await conn.execute('ALTER SESSION SET MULTI_STATEMENT_COUNT = 0');
      final results = await conn.executeAll('SELECT 1; SELECT 2; SELECT 3');
      expect(results, hasLength(3));
      expect(results.map((r) => r.value), [1, 2, 3]);
      // execute() hands back the first of them.
      expect((await conn.execute('SELECT 1; SELECT 2')).value, 1);
    });

    test('a pack declares its own count, with no ALTER SESSION anywhere',
        () async {
      // setUp gives every test its own connection, so this session's
      // MULTI_STATEMENT_COUNT is the default 1 and the request itself is the
      // only thing that can have let the pack through.
      final results = await conn
          .executeAllDeclaring('SELECT 1; SELECT 2', multiStatementCount: 2);
      expect(results.map((r) => r.value), [1, 2]);

      // 0 is how a pack asks for any number.
      expect(
          await conn.executeAllDeclaring('SELECT 1; SELECT 2; SELECT 3',
              multiStatementCount: 0),
          hasLength(3));

      // The count did not stay behind: nothing was altered, so there is
      // nothing to put back.
      //
      // Only an engine that counts the statements in a request refuses a pack
      // at all, and this driver supports older ones than that. Against one of
      // those the refusal never comes, so the check is SKIPPED rather than
      // passed: a green tick would claim an engine had been checked for a
      // refusal it does not make.
      try {
        await conn.executeAll('SELECT 1; SELECT 2');
        markTestSkipped('this engine accepts a pack nobody asked for, so it '
            'has no refusal to assert');
      } on QueryException {
        // Refused, as an engine with the gate does: the session is where it
        // was left.
      }
    });

    group('parameters', () {
      test('bind positionally', () async {
        await conn.execute('CREATE TABLE p (id INTEGER, name VARCHAR)');
        await conn.execute('INSERT INTO p VALUES (?, ?)', [1, 'Ada']);
        final found =
            await conn.execute('SELECT name FROM p WHERE id = ?', [1]);
        expect(found.value, 'Ada');
      });

      test('bind by name', () async {
        final result = await conn.executeNamed(
            'SELECT :a + :b AS total, :a AS again', {'a': 2, 'B': 40});
        expect(result.rows.first['TOTAL'], 42);
        expect(result.rows.first['AGAIN'], 2);
      });

      test('a path off a bound value reads its field', () async {
        // The colon glued to the ? reads a path rather than opening a :name
        // marker, so the statement is not refused for mixing the two styles.
        final result = await conn.execute('SELECT ?:a::INTEGER AS a', [
          {'a': 42},
        ]);
        expect(result.value, 42);
      });

      test('a value cannot become syntax', () async {
        await conn.execute('CREATE TABLE q (v VARCHAR)');
        const hostile = "'); DROP TABLE q; --";
        await conn.execute('INSERT INTO q VALUES (?)', [hostile]);
        final read = await conn.execute('SELECT v FROM q');
        expect(read.value, hostile);
      });

      test('a count mismatch never reaches the engine', () async {
        await expectLater(
            conn.execute('SELECT ?, ?', [1]), throwsA(isA<UsageException>()));
        // A bare ? with nothing bound is the SERVER's to reject now: the driver sends
        // it verbatim and the engine answers "Positional bind placeholder '?' has no
        // value; bind it via OPEN ... USING".
        await expectLater(
            conn.execute('SELECT ?'), throwsA(isA<QueryException>()));
      });

      test('colon references pass through when nothing is bound', () async {
        // Snowflake Scripting variables belong to the server, not the client.
        final result =
            await conn.execute("EXECUTE IMMEDIATE 'SELECT 7 AS SEVEN'");
        expect(result.value, 7);
      });
    });

    group('types', () {
      Future<Object?> roundTrip(String type, Object? value) async {
        await conn.execute('CREATE OR REPLACE TABLE rt (v $type)');
        await conn.execute('INSERT INTO rt VALUES (?)', [value]);
        return (await conn.execute('SELECT v FROM rt')).value;
      }

      test('integers, including ones wider than 64 bits', () async {
        expect(await roundTrip('INTEGER', 42), 42);
        expect(await roundTrip('INTEGER', -1), -1);
        expect(await roundTrip('NUMBER(38,0)', 9223372036854775807),
            9223372036854775807);
        final wide = BigInt.parse('99999999999999999999999999999999999999');
        final read = await roundTrip('NUMBER(38,0)', wide);
        expect(read, isA<BigInt>());
        expect(read, wide);
      });

      test('floating point and fixed point', () async {
        expect(await roundTrip('FLOAT', 1.5), 1.5);
        expect(await roundTrip('DOUBLE', -0.25), -0.25);
        expect(await roundTrip('NUMBER(10,2)', 1.25), 1.25);
      });

      test('strings, booleans and NULL', () async {
        expect(await roundTrip('VARCHAR', 'Ada'), 'Ada');
        expect(await roundTrip('VARCHAR', "quote ' and \\ backslash"),
            "quote ' and \\ backslash");
        expect(await roundTrip('VARCHAR', ''), '');
        expect(await roundTrip('BOOLEAN', true), true);
        expect(await roundTrip('BOOLEAN', false), false);
        expect(await roundTrip('VARCHAR', null), isNull);
      });

      test('binary', () async {
        final bytes = Uint8List.fromList([0x00, 0x0f, 0xff, 0x42]);
        final read = await roundTrip('BINARY', bytes);
        expect(read, isA<Uint8List>());
        expect(read, bytes);
      });

      test('a DATE keeps its calendar day', () async {
        final read = await roundTrip('DATE', DateTime.utc(2024, 3, 4));
        expect(read, DateTime.utc(2024, 3, 4));
      });

      test('a TIME keeps its time of day', () async {
        const noonish = Duration(hours: 12, minutes: 34, seconds: 56);
        expect(await roundTrip('TIME', noonish), noonish);
      });

      test('a timestamp keeps the instant it named', () async {
        final instant = DateTime.utc(2024, 3, 4, 5, 6, 7, 890);
        // A bound DateTime is a TIMESTAMP_TZ, which a TIMESTAMP_TZ column
        // keeps as it is.
        final read = (await roundTrip('TIMESTAMP_TZ', instant))! as DateTime;
        // A DateTime carries its zone flag into ==, so the instant is what to
        // compare on.
        expect(read.isAtSameMomentAs(instant), isTrue,
            reason: 'read $read, bound $instant');
      });

      test('a timestamp reaches an NTZ column through a cast', () async {
        final instant = DateTime.utc(2024, 3, 4, 5, 6, 7, 890);
        await conn.execute('CREATE OR REPLACE TABLE rt (v TIMESTAMP_NTZ)');
        // The account refuses a TIMESTAMP_TZ written into a TIMESTAMP_NTZ
        // column while compiling, so a bare bound DateTime is refused too.
        await expectLater(
            conn.execute('INSERT INTO rt VALUES (?)', [instant]),
            throwsA(isA<QueryException>().having(
                (e) => e.message,
                'message',
                contains(
                    'expecting TIMESTAMP_NTZ(9) but got TIMESTAMP_TZ(9)'))));
        // Cast, it keeps the wall clock the DateTime was written with, which
        // for a UTC DateTime is the instant an NTZ reads back as.
        await conn.execute(
            'INSERT INTO rt VALUES (CAST(? AS TIMESTAMP_NTZ))', [instant]);
        final read =
            (await conn.execute('SELECT v FROM rt')).value! as DateTime;
        expect(read.isAtSameMomentAs(instant), isTrue,
            reason: 'read $read, bound $instant');
      });

      test('an array and an object arrive as the engine renders them',
          () async {
        final array = await conn.execute('SELECT ? AS a', [
          [1, 2, 3],
        ]);
        expect(array.value, isA<String>());
        expect(array.value.toString().replaceAll(RegExp(r'\s'), ''), '[1,2,3]');

        final object = await conn.execute('SELECT ? AS o', [
          {'k': 'v'},
        ]);
        expect(object.value.toString(), contains('"k"'));
      });

      test('reports column metadata', () async {
        final result =
            await conn.execute('SELECT 1.25::NUMBER(10,2) AS n, NULL AS x');
        final number = result.columns.first;
        expect(number.name, 'N');
        expect(number.dataType, 'NUMBER');
        expect(number.precision, 10);
        expect(number.scale, 2);
        expect(number.nullable, isNotNull);
      });

      test('reports the declared length of text and binary columns', () async {
        // Characters for text, bytes for binary, the type's maximum when the
        // column is unbounded. Nothing else carries one, and an absent length
        // stays null rather than reading back as a width of 0.
        await conn.execute('CREATE OR REPLACE TABLE widths '
            '(s VARCHAR(9), b BINARY(5), big VARCHAR, n NUMBER(10,2))');
        final result = await conn.execute('SELECT s, b, big, n FROM widths');
        // Engines before 0.1.0 send no length at all, and this driver supports
        // them: a column then reports none, and there is no width to check.
        // SKIPPED rather than passed — a green tick would claim an engine had
        // been checked for a width it never sends.
        if (result.columns[0].length == null) {
          markTestSkipped('this engine sends no column length, so there are '
              'no declared widths to check');
        } else {
          expect(result.columns[0].length, 9);
          expect(result.columns[1].length, 5);
          expect(result.columns[2].length, 16777216);
        }
        // A number carries no length on either engine.
        expect(result.columns[3].length, isNull);
        await conn.execute('DROP TABLE widths');
      });
    });

    group('errors', () {
      test('a refused statement carries the engine\'s own wording', () async {
        await expectLater(
            conn.execute('SELECT * FROM does_not_exist'),
            throwsA(isA<QueryException>().having(
                (e) => e.message, 'message', contains('does not exist'))));
      });

      test('the rendered statement is kept, and kept out of toString',
          () async {
        // Binding is client-side, so Statement holds every parameter inlined —
        // a bound secret appears in it verbatim.
        try {
          await conn.execute('SELECT * FROM missing WHERE p = ?', ['s3cret']);
          fail('expected a QueryException');
        } on QueryException catch (e) {
          expect(e.statement, contains("'s3cret'"));
          expect(e.toString(), isNot(contains('s3cret')));
          expect(e.message, isNot(contains('s3cret')));
        }
      });

      test('a syntax error is a QueryException, not a transport failure',
          () async {
        await expectLater(
            conn.execute('SELECT FROM'), throwsA(isA<QueryException>()));
      });

      test('an empty statement is refused with the endpoint\'s own error',
          () async {
        // This one answers {"error": ...} rather than a statement response.
        await expectLater(conn.execute('  '), throwsA(isA<QueryException>()));
      });

      test('a failed statement leaves the connection usable', () async {
        await expectLater(conn.execute('SELECT * FROM missing'),
            throwsA(isA<QueryException>()));
        expect((await conn.execute('SELECT 1')).value, 1);
      });
    });

    group('transactions', () {
      setUp(() async {
        await conn.execute('CREATE OR REPLACE TABLE acc (id INTEGER)');
      });

      test('commit keeps the rows', () async {
        await conn.begin();
        expect(conn.inTransaction, isTrue);
        await conn.execute('INSERT INTO acc VALUES (1)');
        await conn.commit();
        expect(conn.inTransaction, isFalse);
        expect((await conn.execute('SELECT COUNT(*) FROM acc')).value, 1);
      });

      test('rollback discards them', () async {
        await conn.begin();
        await conn.execute('INSERT INTO acc VALUES (1)');
        await conn.rollback();
        expect((await conn.execute('SELECT COUNT(*) FROM acc')).value, 0);
      });

      test('the helper commits on success', () async {
        final total = await conn.transaction((c) async {
          await c.execute('INSERT INTO acc VALUES (1)');
          return (await c.execute('SELECT COUNT(*) FROM acc')).value;
        });
        expect(total, 1);
        expect((await conn.execute('SELECT COUNT(*) FROM acc')).value, 1);
      });

      test('the helper rolls back on a throw, and re-raises it', () async {
        await expectLater(conn.transaction((c) async {
          await c.execute('INSERT INTO acc VALUES (1)');
          throw StateError('changed my mind');
        }), throwsA(isA<StateError>()));
        expect((await conn.execute('SELECT COUNT(*) FROM acc')).value, 0);
        expect(conn.inTransaction, isFalse);
      });
    });

    group('sessions', () {
      test('session state carries across statements on one connection',
          () async {
        await conn.execute('CREATE OR REPLACE TABLE scoped (id INTEGER)');
        await conn.execute(r'SET my_var = 7');
        expect((await conn.execute(r'SELECT $my_var')).value, 7);
      });

      test('two connections hold two sessions', () async {
        final other = await connect(server.dsn);
        try {
          expect(other.sessionId, isNot(conn.sessionId));
        } finally {
          await other.close();
        }
      });

      test('the DSN scope is applied before the first statement', () async {
        final scoped =
            await connect('${server.dsn}/test_db?schema=test_schema');
        try {
          await scoped.execute('CREATE OR REPLACE TABLE in_scope (a INTEGER)');
          // Visible from the other connection under its fully qualified name,
          // which is what says the USE statements actually ran.
          final found = await conn
              .execute('SELECT COUNT(*) FROM test_db.information_schema.tables '
                  "WHERE table_name = 'IN_SCOPE'");
          expect(found.value, 1);
        } finally {
          await scoped.close();
        }
      });

      test('a DSN naming a database that does not exist fails at connect',
          () async {
        // Reported here rather than surfacing later on whichever query happened
        // to run first.
        await expectLater(connect('${server.dsn}/no_such_db'),
            throwsA(isA<QueryException>()));
      });

      test('statements are serialized, so awaiting several is safe', () async {
        await conn.execute('CREATE OR REPLACE TABLE ordered (id INTEGER)');
        await Future.wait([
          for (var i = 0; i < 10; i++)
            conn.execute('INSERT INTO ordered VALUES (?)', [i]),
        ]);
        final count = await conn.execute('SELECT COUNT(*) FROM ordered');
        expect(count.value, 10);
        // All of it on one session: an interleaved second session would have
        // lost the USE this connection is riding on.
        expect(conn.sessionId, isNotNull);
      });
    });

    group('lifecycle', () {
      test('a closed connection refuses further statements', () async {
        final other = await connect(server.dsn);
        await other.close();
        expect(other.isClosed, isTrue);
        await expectLater(
            other.execute('SELECT 1'), throwsA(isA<UsageException>()));
      });

      test('closing twice is not an error', () async {
        final other = await connect(server.dsn);
        await other.close();
        await other.close();
      });

      test('ping reports a healthy engine', () async {
        await conn.ping();
      });
    });
  }, skip: TestServer.skipReason);

  group('the statement count a request declares', () {
    // A stub rather than an engine: these cases are about what the driver PUT
    // ON THE WIRE, so the answers are the least an engine could send.
    Future<void> withRecorder(
        Future<void> Function(Connection conn, List<String> bodies) body) async {
      final bodies = <String>[];
      final stub = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(stub.forEach((request) async {
        final sent = await utf8.decoder.bind(request).join();
        if (request.uri.path == '/api/health') {
          request.response.write('{"status":"healthy"}');
        } else {
          bodies.add(sent);
          request.response
              .write('{"success":true,"sessionId":"s-1","resultSets":[]}');
        }
        await request.response.close();
      }));
      try {
        final conn = await connect('frostlake://127.0.0.1:${stub.port}');
        try {
          await body(conn, bodies);
        } finally {
          await conn.close();
        }
      } finally {
        await stub.close(force: true);
      }
    }

    test('is absent unless the caller asked for one', () async {
      await withRecorder((conn, bodies) async {
        // The field is left out entirely, not sent as 0 or null: a request
        // without it is the one the engine has always seen, and the session's
        // MULTI_STATEMENT_COUNT decides.
        await conn.execute('SELECT 1');
        expect(bodies.last, isNot(contains('multiStatementCount')));
        await conn.executeAllNamed('SELECT :a', {'a': 1});
        expect(bodies.last, isNot(contains('multiStatementCount')));
      });
    });

    test('rides on that one request, and alters nothing', () async {
      await withRecorder((conn, bodies) async {
        await conn.executeAllDeclaring('SELECT 1; SELECT 2',
            multiStatementCount: 2);
        expect(bodies.last, contains('"multiStatementCount":2'));

        // 0 is a count like any other, and goes out as one.
        await conn.executeAllDeclaring('SELECT 1; SELECT 2; SELECT 3',
            multiStatementCount: 0);
        expect(bodies.last, contains('"multiStatementCount":0'));

        // It declared that one request only, and nothing was altered to make
        // it work: there is no ALTER SESSION to send and none to undo.
        await conn.execute('SELECT 4');
        expect(bodies.last, isNot(contains('multiStatementCount')));
        expect(bodies.join(), isNot(contains('ALTER SESSION')));
      });
    });

    test('carries either placeholder style, and not both', () async {
      await withRecorder((conn, bodies) async {
        await conn.executeAllDeclaring('SELECT ?',
            parameters: [1], multiStatementCount: 1);
        expect(bodies.last, contains('"multiStatementCount":1'));
        expect(bodies.last, contains('SELECT 1'));

        await conn.executeAllDeclaring('SELECT :a',
            namedParameters: {'a': 2}, multiStatementCount: 1);
        expect(bodies.last, contains('"multiStatementCount":1'));
        expect(bodies.last, contains('SELECT 2'));

        await expectLater(
            conn.executeAllDeclaring('SELECT ?',
                parameters: [1], namedParameters: {'a': 2}),
            throwsA(isA<UsageException>()));
      });
    });

    test('a count that is not a whole number of statements is refused',
        () async {
      await withRecorder((conn, bodies) async {
        await expectLater(
            conn.executeAllDeclaring('SELECT 1', multiStatementCount: -1),
            throwsA(isA<UsageException>()));
      });
    });
  });

  group('transport failures', () {
    test('a refused connection is a ConnectionException', () async {
      // Port 1 on loopback is not listening.
      await expectLater(
          connect('frostlake://127.0.0.1:1',
              connectTimeout: const Duration(seconds: 2)),
          throwsA(isA<ConnectionException>()));
    });

    test('a server that is not an engine is reported, not passed off',
        () async {
      final stub = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(stub.forEach((request) async {
        request.response
          ..statusCode = 200
          ..write('<html>hello from a proxy</html>');
        await request.response.close();
      }));
      try {
        await expectLater(
            connect('frostlake://127.0.0.1:${stub.port}'),
            throwsA(isA<ConnectionException>().having((e) => e.message,
                'message', contains('not a Frostlake response'))));
      } finally {
        await stub.close(force: true);
      }
    });

    test('a statement that outlives its timeout is reported as one', () async {
      final stub = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(stub.forEach((request) async {
        if (request.uri.path == '/api/health') {
          request.response.write('{"status":"healthy"}');
          await request.response.close();
          return;
        }
        // Never answers: what a wedged engine looks like.
      }));
      try {
        final conn = await connect('frostlake://127.0.0.1:${stub.port}',
            timeout: const Duration(milliseconds: 300));
        try {
          await expectLater(
              conn.execute('SELECT 1'),
              throwsA(isA<ConnectionException>().having(
                  (e) => e.message, 'message', contains('did not answer'))));
        } finally {
          await conn.close();
        }
      } finally {
        await stub.close(force: true);
      }
    });
  });
}
