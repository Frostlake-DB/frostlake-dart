import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:frostlake/frostlake.dart';
import 'package:frostlake/src/sql.dart';
import 'package:test/test.dart';

import 'src/scripted_server.dart';
import 'src/test_server.dart';

/// How a connection keeps its idea of the engine session in step with the
/// engine's: what it asks of the engine, what it does when the session is
/// gone, and how it lets go of it.
void main() {
  group('what a statement leaves on the session', () {
    test('a moved scope, a variable, a setting or a temporary object', () {
      for (final statement in [
        'USE SCHEMA s',
        'SET v = 1',
        'UNSET v',
        "ALTER SESSION SET TIMEZONE = 'UTC'",
        'CREATE DATABASE d',
        'DROP SCHEMA IF EXISTS s',
        'CREATE TEMPORARY TABLE t (a INT)',
        'create or replace temp stage st',
        'CREATE LOCAL VOLATILE TABLE t (a INT)',
        'CREATE OR REPLACE SECURE TEMPORARY VIEW v AS SELECT 1',
        '-- note\nCREATE TEMP TABLE t (a INT)',
      ]) {
        expect(touchesSession(statement), isTrue, reason: statement);
      }
    });

    test('nothing a fresh session would miss', () {
      for (final statement in [
        'SELECT 1',
        'CREATE TABLE t (a INT)',
        'CREATE TRANSIENT TABLE t (a INT)',
        'CREATE TABLE temp (a INT)',
        'DROP TABLE t',
        'ALTER TABLE t ADD COLUMN b INT',
        "SELECT 'USE SCHEMA s'",
      ]) {
        expect(touchesSession(statement), isFalse, reason: statement);
      }
    });

    test('where a transaction begins and ends', () {
      for (final statement in [
        'BEGIN',
        'begin transaction',
        'BEGIN WORK',
        'BEGIN NAME t1',
        'START TRANSACTION',
      ]) {
        expect(transactionEffect(statement), TransactionEffect.begins,
            reason: statement);
      }
      for (final statement in ['COMMIT', 'ROLLBACK', 'commit work']) {
        expect(transactionEffect(statement), TransactionEffect.ends,
            reason: statement);
      }
      // BEGIN followed by a statement opens a scripting block instead.
      for (final statement in [
        'BEGIN SELECT 1',
        'SELECT 1',
        'BEGINNING',
        "SELECT 'BEGIN'",
      ]) {
        expect(transactionEffect(statement), TransactionEffect.none,
            reason: statement);
      }
    });
  });

  group('session lifetime, scripted', () {
    // Over a stand-in engine: every request a scenario makes is one it
    // scripted, and every one it sent is on record.
    late ScriptedServer server;

    const scope = ['USE DATABASE "APP"', 'USE SCHEMA "PUBLIC"'];

    setUp(() async => server = await ScriptedServer.start());

    tearDown(() async {
      await server.close();
      expect(server.unscripted, isEmpty,
          reason: 'requests arrived that the scenario did not script');
    });

    /// A connection opened on an engine that reports newSession.
    Future<Connection> opened([String query = '']) async {
      server.reply(answer('s1', started: true, sets: [statusSet('ok')]));
      server.reply(answer('s1', sets: [statusSet('ok')]));
      return connect(server.dsn('/APP?schema=PUBLIC$query'));
    }

    test('an older engine is never sent requireSession, nor a DELETE',
        () async {
      server.reply(legacyAnswer('old1', sets: [statusSet('ok')]));
      server.reply(legacyAnswer('old1', sets: [statusSet('ok')]));
      final conn = await connect(server.dsn('/APP?schema=PUBLIC'));
      server.reply(legacyAnswer('old1', sets: [numberSet('N', 1)]));
      expect((await conn.execute('SELECT 1 AS N')).value, 1);
      await conn.close();
      expect(server.statements, [...scope, 'SELECT 1 AS N']);
      // The session id travels once it is known, the flag never does: an
      // older engine's parser need not accept a field it does not know.
      expect(server.executes.skip(1).map((s) => s.sessionId),
          everyElement('old1'));
      expect(server.sent.where((s) => s.hasRequireSession), isEmpty);
      expect(server.sent.where((s) => s.method == 'DELETE'), isEmpty);
    });

    test('requireSession travels only once the engine is known to read it',
        () async {
      final conn = await opened();
      server.reply(answer('s1', sets: [numberSet('N', 1)]));
      await conn.execute('SELECT 1 AS N');
      final executes = server.executes;
      // The first request names no session, so there is nothing to require
      // yet; its answer's newSession is what says the engine understands.
      expect(executes[0].sessionId, isNull);
      expect(executes[0].hasRequireSession, isFalse);
      for (final request in executes.skip(1)) {
        expect(request.sessionId, 's1');
        expect(request.requireSession, true);
      }
      server.reply(released);
      await conn.close();
    });

    test(
        'a lost session is replaced on the scope and the statement sent once '
        'more', () async {
      final conn = await opened();
      server.reply(sessionGone('s1'), status: HttpStatus.notFound);
      server.reply(answer('s2', started: true, sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [numberSet('N', 1)]));
      expect((await conn.execute('SELECT 1 AS N')).value, 1);
      expect(server.statements,
          [...scope, 'SELECT 1 AS N', ...scope, 'SELECT 1 AS N']);
      final executes = server.executes;
      // The replacement starts without an id, as a first request does.
      expect(executes[3].sessionId, isNull);
      expect(executes[3].hasRequireSession, isFalse);
      expect(executes[5].sessionId, 's2');
      expect(executes[5].requireSession, true);
      expect(conn.sessionId, 's2');
      expect(server.pending, 0);
      server.reply(released);
      await conn.close();
      expect(server.sent.last.path, '/api/sessions/s2');
    });

    test('a second 404 is raised, and the connection starts over after it',
        () async {
      final conn = await opened();
      server.reply(sessionGone('s1'), status: HttpStatus.notFound);
      server.reply(answer('s2', started: true, sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [statusSet('ok')]));
      server.reply(sessionGone('s2'), status: HttpStatus.notFound);
      await expectLater(
          conn.execute('SELECT 1 AS N'),
          throwsA(isA<SessionLostException>()
              .having((e) => e.statement, 'statement', 'SELECT 1 AS N')));
      expect(server.statements,
          [...scope, 'SELECT 1 AS N', ...scope, 'SELECT 1 AS N']);
      // Usable still: the next statement starts a fresh session on the scope.
      server.reply(answer('s3', started: true, sets: [statusSet('ok')]));
      server.reply(answer('s3', sets: [statusSet('ok')]));
      server.reply(answer('s3', sets: [numberSet('N', 2)]));
      expect((await conn.execute('SELECT 2 AS N')).value, 2);
      expect(server.executes[6].sessionId, isNull);
      server.reply(released);
      await conn.close();
    });

    test('a lost session with an open transaction is reported, not replaced',
        () async {
      final conn = await opened();
      server.reply(answer('s1', sets: [statusSet('ok')]));
      await conn.begin();
      expect(conn.inTransaction, isTrue);
      server.reply(sessionGone('s1'), status: HttpStatus.notFound);
      await expectLater(
          conn.execute('INSERT INTO t VALUES (1)'),
          throwsA(isA<SessionLostException>()
              .having((e) => e.message, 'message', contains('transaction'))));
      expect(conn.inTransaction, isFalse);
      expect(conn.isClosed, isFalse);
      expect(
          server.statements, [...scope, 'BEGIN', 'INSERT INTO t VALUES (1)']);
      // The next statement starts over on the DSN's scope, in autocommit.
      server.reply(answer('s2', started: true, sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [numberSet('N', 1)]));
      await conn.execute('SELECT 1 AS N');
      expect(server.statements, [
        ...scope,
        'BEGIN',
        'INSERT INTO t VALUES (1)',
        ...scope,
        'SELECT 1 AS N',
      ]);
      expect(server.executes.last.autoCommit, true);
      server.reply(released);
      await conn.close();
    });

    test('a transaction opened by a statement is guarded the same way',
        () async {
      final conn = await opened();
      server.reply(answer('s1', sets: [statusSet('ok')]));
      await conn.execute('BEGIN TRANSACTION');
      server.reply(sessionGone('s1'), status: HttpStatus.notFound);
      await expectLater(
          conn.execute('INSERT INTO t VALUES (1)'),
          throwsA(isA<SessionLostException>()
              .having((e) => e.message, 'message', contains('transaction'))));
      expect(server.pending, 0);
      await conn.close();
    });

    test('a transaction a COMMIT ended is no reason to refuse', () async {
      final conn = await opened();
      server.reply(answer('s1', sets: [statusSet('ok')]));
      server.reply(answer('s1', sets: [statusSet('ok')]));
      await conn.execute('BEGIN');
      await conn.execute('COMMIT');
      server.reply(sessionGone('s1'), status: HttpStatus.notFound);
      server.reply(answer('s2', started: true, sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [numberSet('N', 1)]));
      expect((await conn.execute('SELECT 1 AS N')).value, 1);
      server.reply(released);
      await conn.close();
    });

    test('a lost session whose context moved is reported, not replaced',
        () async {
      final conn = await opened();
      server.reply(answer('s1', sets: [statusSet('ok')]));
      await conn.execute('USE SCHEMA OTHER');
      server.reply(sessionGone('s1'), status: HttpStatus.notFound);
      await expectLater(
          conn.execute('SELECT * FROM t'),
          throwsA(isA<SessionLostException>()
              .having((e) => e.message, 'message', contains('context'))));
      expect(
          server.statements, [...scope, 'USE SCHEMA OTHER', 'SELECT * FROM t']);
      // The next statement starts over on the DSN's scope.
      server.reply(answer('s2', started: true, sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [numberSet('N', 1)]));
      await conn.execute('SELECT 1 AS N');
      expect(server.statements.skip(4), [...scope, 'SELECT 1 AS N']);
      server.reply(released);
      await conn.close();
    });

    test('a variable, a setting or a temporary object is context too',
        () async {
      for (final statement in [
        'SET v = 1',
        "ALTER SESSION SET TIMEZONE = 'UTC'",
        'CREATE TEMPORARY TABLE scratch (a INT)',
        'SELECT 1; USE SCHEMA OTHER',
      ]) {
        final conn = await opened();
        server.reply(answer('s1', sets: [statusSet('ok')]));
        await conn.executeAllDeclaring(statement, multiStatementCount: 0);
        server.reply(sessionGone('s1'), status: HttpStatus.notFound);
        await expectLater(
            conn.execute('SELECT 2'), throwsA(isA<SessionLostException>()),
            reason: statement);
        await conn.close();
        expect(server.pending, 0, reason: statement);
      }
    });

    test('an ordinary statement leaves nothing a replacement would miss',
        () async {
      final conn = await opened();
      server.reply(answer('s1', sets: [statusSet('ok')]));
      await conn.execute('CREATE TABLE t (a INT)');
      server.reply(sessionGone('s1'), status: HttpStatus.notFound);
      server.reply(answer('s2', started: true, sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [numberSet('N', 1)]));
      expect((await conn.execute('SELECT 1 AS N')).value, 1);
      server.reply(released);
      await conn.close();
    });

    test('putting the DSN scope back makes a moved session replaceable again',
        () async {
      final conn = await opened();
      server.reply(answer('s1', sets: [statusSet('ok')]));
      await conn.execute('USE SCHEMA OTHER');
      server.reply(answer('s1', sets: [statusSet('ok')]));
      server.reply(answer('s1', sets: [statusSet('ok')]));
      await conn.applyDsnScope();
      server.reply(sessionGone('s1'), status: HttpStatus.notFound);
      server.reply(answer('s2', started: true, sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [numberSet('N', 1)]));
      expect((await conn.execute('SELECT 1 AS N')).value, 1);
      server.reply(released);
      await conn.close();
    });

    test('BEGIN on a lost session is re-sent on a fresh one', () async {
      final conn = await opened();
      server.reply(sessionGone('s1'), status: HttpStatus.notFound);
      server.reply(answer('s2', started: true, sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [statusSet('ok')]));
      server.reply(answer('s2', sets: [statusSet('ok')]));
      await conn.begin();
      expect(conn.inTransaction, isTrue);
      expect(server.statements, [...scope, 'BEGIN', ...scope, 'BEGIN']);
      // Both went out with autocommit off, the mode the transaction runs in.
      expect(server.executes[2].autoCommit, false);
      expect(server.executes[5].autoCommit, false);
      server.reply(released);
      await conn.close();
    });

    test('a COMMIT whose session is gone is reported, not re-sent', () async {
      final conn = await opened();
      server.reply(answer('s1', sets: [statusSet('ok')]));
      await conn.begin();
      server.reply(sessionGone('s1'), status: HttpStatus.notFound);
      await expectLater(conn.commit(), throwsA(isA<SessionLostException>()));
      expect(conn.inTransaction, isFalse);
      expect(server.statements, [...scope, 'BEGIN', 'COMMIT']);
      await conn.close();
    });

    test(
        'the idle re-scope is left to engines that cannot report a lost '
        'session', () async {
      // An older engine gives nothing away, so an idle session is assumed lost
      // and the scope goes back on.
      server.reply(legacyAnswer('old1', sets: [statusSet('ok')]));
      server.reply(legacyAnswer('old1', sets: [statusSet('ok')]));
      final old = await connect(server.dsn('/APP?schema=PUBLIC&idleLimit=1ms'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      server.reply(legacyAnswer('old1', sets: [statusSet('ok')]));
      server.reply(legacyAnswer('old1', sets: [statusSet('ok')]));
      server.reply(legacyAnswer('old1', sets: [numberSet('N', 1)]));
      await old.execute('SELECT 1 AS N');
      expect(server.statements, [...scope, ...scope, 'SELECT 1 AS N']);
      await old.close();

      // One that reports newSession refuses a lost session instead, so the
      // clock is not needed.
      server.sent.clear();
      final conn = await opened('&idleLimit=1ms');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      server.reply(answer('s1', sets: [numberSet('N', 1)]));
      await conn.execute('SELECT 1 AS N');
      expect(server.statements, [...scope, 'SELECT 1 AS N']);
      server.reply(released);
      await conn.close();
    });

    test('closing releases the session with one DELETE', () async {
      final conn = await opened();
      server.reply(released);
      await conn.close();
      final last = server.sent.last;
      expect(last.method, 'DELETE');
      expect(last.path, '/api/sessions/s1');
      expect(server.pending, 0);
      final count = server.sent.length;
      await conn.close();
      expect(server.sent.length, count);
      expect(conn.sessionId, isNull);
      await expectLater(
          conn.execute('SELECT 1'), throwsA(isA<UsageException>()));
    });

    test(
        'a scope the engine refuses fails the connect and releases the '
        'session', () async {
      server.reply(refused(
          's9',
          "Database 'APP' does not exist or not "
              'authorized.'));
      server.reply(released);
      await expectLater(connect(server.dsn('/APP?schema=PUBLIC')),
          throwsA(isA<QueryException>()));
      expect(server.sent.last.method, 'DELETE');
      expect(server.sent.last.path, '/api/sessions/s9');
    });

    group('a release that fails is no failure of close', () {
      Future<void> closeAgainst(void Function() script,
          [String query = '']) async {
        final conn = await opened(query);
        script();
        await conn.close().timeout(const Duration(seconds: 10));
        expect(server.sent.where((s) => s.method == 'DELETE'), hasLength(1));
        expect(conn.isClosed, isTrue);
      }

      test('a 404', () async {
        await closeAgainst(() => server.reply(
            '{"success":false,"errorMessage":"Session \'s1\' does not exist '
            'or has expired.","sessionId":null}',
            status: HttpStatus.notFound));
      });

      test('a 405 from an engine without the endpoint', () async {
        await closeAgainst(
            () => server.reply('', status: HttpStatus.methodNotAllowed));
      });

      test('a socket closed without an answer', () async {
        await closeAgainst(server.drop);
      });

      test('an engine that never answers', () async {
        // Bounded by the DSN's timeout when that is the shorter.
        await closeAgainst(server.hang, '&timeout=300ms');
      });
    });
  });

  group('session lifetime against an engine', () {
    late TestServer server;
    late String scoped;

    setUpAll(() async {
      server = await TestServer.start();
      final setup = await connect(server.dsn);
      await setup.execute('CREATE OR REPLACE DATABASE sess_db');
      await setup.execute('CREATE OR REPLACE SCHEMA sess_db.sess_schema');
      await setup.close();
      scoped = '${server.dsn}/sess_db?schema=sess_schema';
    });

    tearDownAll(() async => server.stop());

    Future<HttpClientResponse> call(String method, String path) async {
      final client = HttpClient();
      try {
        final request = await client.openUrl(method,
            Uri.parse('${server.dsn.replaceFirst('frostlake', 'http')}$path'));
        return await request.close();
      } finally {
        client.close();
      }
    }

    /// Ends a session behind the driver's back, as an idle expiry would.
    Future<void> releaseOutOfBand(String id) async {
      final response = await call('DELETE', '/api/sessions/$id');
      await response.drain<void>();
      expect(response.statusCode, HttpStatus.ok);
    }

    Future<int> activeSessions() async {
      final response = await call('GET', '/api/sessions');
      final body = await utf8.decoder.bind(response).join();
      return (jsonDecode(body) as Map<String, Object?>)['activeSessions']!
          as int;
    }

    test('a session released out of band is replaced on the DSN\'s scope',
        () async {
      final conn = await connect(scoped);
      try {
        final lost = conn.sessionId!;
        await releaseOutOfBand(lost);
        final where =
            await conn.execute('SELECT CURRENT_DATABASE(), CURRENT_SCHEMA()');
        expect(where.values.single, ['SESS_DB', 'SESS_SCHEMA']);
        expect(conn.sessionId, isNot(lost));
      } finally {
        await conn.close();
      }
    });

    test('a session lost with BEGIN open is reported, and nothing is re-run',
        () async {
      final conn = await connect(scoped);
      try {
        await conn.execute('CREATE OR REPLACE TABLE kept (id INTEGER)');
        await conn.execute('BEGIN');
        await conn.execute('INSERT INTO kept VALUES (1)');
        await releaseOutOfBand(conn.sessionId!);
        await expectLater(conn.execute('INSERT INTO kept VALUES (2)'),
            throwsA(isA<SessionLostException>()));
        // A fresh session on the DSN's scope: the release rolled the first
        // INSERT back, and the second never ran.
        expect((await conn.execute('SELECT COUNT(*) FROM kept')).value, 0);
      } finally {
        await conn.close();
      }
    });

    test('a session lost after a USE is reported', () async {
      final conn = await connect(scoped);
      try {
        await conn.execute('USE SCHEMA sess_db.public');
        await releaseOutOfBand(conn.sessionId!);
        await expectLater(conn.execute('SELECT CURRENT_SCHEMA()'),
            throwsA(isA<SessionLostException>()));
        expect((await conn.execute('SELECT CURRENT_SCHEMA()')).value,
            'SESS_SCHEMA');
      } finally {
        await conn.close();
      }
    });

    test('closing releases the session', () async {
      final before = await activeSessions();
      final conn = await connect(scoped);
      expect(await activeSessions(), before + 1);
      await conn.close();
      expect(await activeSessions(), before);
    });
  }, skip: TestServer.skipReason);
}
