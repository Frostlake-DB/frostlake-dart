import 'dart:typed_data';

import 'package:frostlake/frostlake.dart';
import 'package:frostlake/src/binding.dart';
import 'package:frostlake/src/sql.dart';
import 'package:test/test.dart';

void main() {
  group('positional binding', () {
    test('inlines values in order', () {
      expect(substitutePositional('SELECT ?, ?', [1, 'a']), "SELECT 1, 'a'");
    });

    test('leaves a statement with no placeholders alone', () {
      expect(substitutePositional('SELECT 1', []), 'SELECT 1');
    });

    test('refuses a count mismatch in either direction', () {
      expect(() => substitutePositional('SELECT ?, ?', [1]),
          throwsA(isA<UsageException>()));
      expect(() => substitutePositional('SELECT ?', [1, 2]),
          throwsA(isA<UsageException>()));
      // With no arguments at all the ? marks belong to the server too — they are
      // what a Snowflake Scripting cursor placeholder looks like, bound later by
      // `OPEN c USING (...)`, so the statement passes through verbatim.
      expect(substitutePositional('SELECT ?', []), 'SELECT ?');
    });

    test('a ? inside a string literal is not a placeholder', () {
      expect(substitutePositional("SELECT 'a?b', ?", [1]), "SELECT 'a?b', 1");
      expect(substitutePositional("SELECT 'it''s ?'", []), "SELECT 'it''s ?'");
      expect(
          substitutePositional(r"SELECT 'a\'?', ?", [2]), r"SELECT 'a\'?', 2");
    });

    test('a ? inside a quoted identifier is not a placeholder', () {
      expect(substitutePositional('SELECT "a?b" FROM t WHERE x = ?', [1]),
          'SELECT "a?b" FROM t WHERE x = 1');
    });

    test('a ? inside a dollar-quoted body is not a placeholder', () {
      const sql = r'CREATE FUNCTION f() AS $$ return "?" $$';
      expect(substitutePositional(sql, []), sql);
      expect(placeholderCount(sql), 0);
    });

    test('a bare dollar inside an identifier does not open a body', () {
      // A$$B is a name, so the ? after it is still a placeholder.
      expect(substitutePositional(r'SELECT A$$B FROM t WHERE x = ?', [1]),
          r'SELECT A$$B FROM t WHERE x = 1');
    });

    test('a name is read whole, so only dollars outside one open a body', () {
      expect(substitutePositional(r'SELECT 1 AS a$$b, ?', [7]),
          r'SELECT 1 AS a$$b, 7');
      expect(
          substitutePositional(r'SELECT a$$b, ? FROM t$$ WHERE c$ = ?', [7, 8]),
          r'SELECT a$$b, 7 FROM t$$ WHERE c$ = 8');
      // A $$ right after a number or a positional reference does open one.
      expect(
          substitutePositional(r'SELECT 1$$?$$, ?', [7]), r'SELECT 1$$?$$, 7');
      expect(substitutePositional(r'SELECT $1$$?$$, ?', [7]),
          r'SELECT $1$$?$$, 7');
    });

    test('a ? inside a comment is not a placeholder', () {
      expect(substitutePositional('SELECT 1 -- ?\n, ?', [2]),
          'SELECT 1 -- ?\n, 2');
      expect(substitutePositional('SELECT 1 // ?\n, ?', [2]),
          'SELECT 1 // ?\n, 2');
      expect(substitutePositional('SELECT /* ? */ ?', [3]), 'SELECT /* ? */ 3');
    });

    test('a line comment ends at a carriage return as well as a line feed', () {
      expect(substitutePositional('SELECT 1 -- c\r, ?', [7]),
          'SELECT 1 -- c\r, 7');
      expect(substitutePositional('SELECT 1 // c?\r\n, ?', [7]),
          'SELECT 1 // c?\r\n, 7');
      expect(substitutePositional('SELECT 1 -- c?\n, ?', [7]),
          'SELECT 1 -- c?\n, 7');
    });
  });

  group('named binding', () {
    test('binds by name, in any order, case-insensitively', () {
      expect(substituteNamed('SELECT :a, :b', {'b': 2, 'A': 1}), 'SELECT 1, 2');
    });

    test('binds a name used more than once', () {
      expect(substituteNamed('SELECT :x + :x', {'x': 5}), 'SELECT 5 + 5');
      expect(placeholderCount('SELECT :x + :x'), 1);
    });

    test('refuses a name with no argument, and an argument with no name', () {
      expect(() => substituteNamed('SELECT :a, :b', {'a': 1}),
          throwsA(isA<UsageException>()));
      expect(
          () => substituteNamed('SELECT :a', {'a': 1, 'typo': 2}),
          throwsA(isA<UsageException>()
              .having((e) => e.message, 'message', contains(':typo'))));
    });

    test(':: is a cast and := an assignment, not parameters', () {
      expect(placeholderNames("SELECT '1'::INTEGER"), isEmpty);
      expect(placeholderNames('LET x := 1'), isEmpty);
      expect(substitutePositional("SELECT '1'::INTEGER", []),
          "SELECT '1'::INTEGER");
    });

    test(':1 is a positional reference, not a name', () {
      expect(placeholderNames('SELECT :1'), isEmpty);
    });

    test('VARIANT path access is not a parameter', () {
      // A colon glued to the end of an expression reads a field; a bind marker
      // follows an operator, comma or keyword boundary instead.
      for (final sql in [
        'SELECT v:field FROM t',
        "SELECT PARSE_JSON('{}'):k",
        'SELECT "V":k FROM t',
        "SELECT {'a': 1}:a",
        'SELECT arr[0]:k FROM t',
        "SELECT '{}':k",
        r'SELECT $1:k FROM t',
      ]) {
        expect(placeholderNames(sql), isEmpty, reason: sql);
      }
    });

    test('a path off a ? is not a parameter', () {
      // A ? ends an operand just as a name or a closing bracket does, so a
      // colon glued to it reads a field of the bound value...
      expect(placeholderNames('SELECT ?:a'), isEmpty);
      expect(placeholderCount('SELECT ?:a'), 1);
      expect(substitutePositional('SELECT ?:a', [1]), 'SELECT 1:a');
      expect(
          substitutePositional('SELECT ?:a::INTEGER', [
            {'a': 1},
          ]),
          "SELECT {'a': 1}:a::INTEGER");
      // ...while one spaced off it opens a :name marker, as after any operand.
      expect(placeholderNames('SELECT ? :a'), ['A']);
      expect(placeholderNames('SELECT v :a FROM t'), ['A']);
    });

    test('a bind marker after an operator or comma is a parameter', () {
      expect(
          placeholderNames('WHERE x = :a AND y IN (:b, :c)'), ['A', 'B', 'C']);
    });

    test('refuses mixing the two styles', () {
      expect(() => substitutePositional('SELECT ?, :a', [1, 2]),
          throwsA(isA<UsageException>()));
      expect(() => substituteNamed('SELECT ?, :a', {'a': 2}),
          throwsA(isA<UsageException>()));
      expect(placeholderCount('SELECT ?, :a'), -1);
    });

    test('points a caller at the other method rather than guessing', () {
      expect(
          () => substitutePositional('SELECT :a', [1]),
          throwsA(isA<UsageException>()
              .having((e) => e.message, 'message', contains('map'))));
      expect(
          () => substituteNamed('SELECT ?', {'a': 1}),
          throwsA(isA<UsageException>()
              .having((e) => e.message, 'message', contains('list'))));
    });

    test('with no arguments the colon references pass through untouched', () {
      // These are the SERVER's: Snowflake Scripting variables, not client binds.
      const sql = 'EXECUTE IMMEDIATE :stmt';
      expect(substitutePositional(sql, []), sql);
      expect(substitutePositional('SELECT IFF(:flag, 1, 2)', []),
          'SELECT IFF(:flag, 1, 2)');
    });
  });

  group('formatLiteral', () {
    test('renders the scalar types', () {
      expect(formatLiteral(null), 'NULL');
      expect(formatLiteral(true), 'TRUE');
      expect(formatLiteral(false), 'FALSE');
      expect(formatLiteral(42), '42');
      expect(formatLiteral(1.5), '1.5');
      expect(formatLiteral(BigInt.parse('123456789012345678901234567890')),
          '123456789012345678901234567890');
    });

    test('escapes strings so a value cannot become syntax', () {
      expect(formatLiteral("O'Brien"), "'O''Brien'");
      expect(formatLiteral(r'back\slash'), r"'back\\slash'");
      expect(formatLiteral("'; DROP TABLE t; --"), "'''; DROP TABLE t; --'");
      expect(formatLiteral(''), "''");
    });

    test('casts the non-finite doubles from text', () {
      // Dart spells these NaN, Infinity and -Infinity, which the parser would
      // read as identifiers; 'Infinity' is the spelling the engine's cast
      // accepts (it refuses 'Inf').
      expect(formatLiteral(double.nan), "'NaN'::FLOAT");
      expect(formatLiteral(double.infinity), "'Infinity'::FLOAT");
      expect(formatLiteral(double.negativeInfinity), "'-Infinity'::FLOAT");
    });

    test('parenthesizes a negative so it cannot open a comment', () {
      expect(formatLiteral(-7), '(-7)');
      expect(formatLiteral(-1.5), '(-1.5)');
      expect(formatLiteral(BigInt.parse('-123456789012345678901')),
          '(-123456789012345678901)');
      // Spliced bare after a minus, -5 turned `3-?` into the comment `3--5`.
      expect(substitutePositional('SELECT 3-?', [-5]), 'SELECT 3-(-5)');
      expect(substitutePositional('SELECT 3-?', [5]), 'SELECT 3-5');
    });

    test('keeps a negative one value wherever it lands', () {
      // Bare, ?::VARCHAR would cast before it negates.
      expect(substitutePositional('SELECT ?::VARCHAR', [-5]),
          'SELECT (-5)::VARCHAR');
      expect(substitutePositional('SELECT 3-?, ?::VARCHAR', [-2.5, -2.5]),
          'SELECT 3-(-2.5), (-2.5)::VARCHAR');
      expect(
          substitutePositional(
              'SELECT 3-?', [BigInt.parse('-123456789012345678901234567890')]),
          'SELECT 3-(-123456789012345678901234567890)');
      // Negative zero is not below zero, but it is written with a minus.
      expect(formatLiteral(-0.0), '(-0.0)');
      expect(substitutePositional('SELECT 3-?', [-0.0]), 'SELECT 3-(-0.0)');
      expect(formatLiteral([-1, 2]), '[(-1), 2]');
    });

    test('refuses a timestamp year outside the calendar', () {
      expect(() => formatLiteral(DateTime.utc(-1, 1, 1)),
          throwsA(isA<UsageException>()));
      expect(() => formatLiteral(DateTime.utc(10000, 1, 1)),
          throwsA(isA<UsageException>()));
      expect(formatLiteral(DateTime.utc(1, 1, 1)),
          "'0001-01-01T00:00:00.000000+00:00'::TIMESTAMP_TZ");
    });

    test('renders a Uint8List as a hex BINARY literal', () {
      expect(
          formatLiteral(Uint8List.fromList([0x00, 0x0f, 0xff])), "X'000FFF'");
      expect(formatLiteral(Uint8List(0)), "X''");
    });

    test('a plain List is an array, not binary', () {
      // Guessing between them from the element type would make [1, 2, 3] mean
      // two different things.
      expect(formatLiteral([1, 2, 3]), '[1, 2, 3]');
      expect(formatLiteral(['a', null, true]), "['a', NULL, TRUE]");
      expect(
          formatLiteral([
            [1, 2],
            [3],
          ]),
          '[[1, 2], [3]]');
    });

    test('renders a Map as an object literal', () {
      expect(formatLiteral({'a': 1, 'b': 'x'}), "{'a': 1, 'b': 'x'}");
      expect(() => formatLiteral({1: 'a'}), throwsA(isA<UsageException>()));
    });

    test('renders a DateTime as a TIMESTAMP_TZ carrying its offset', () {
      expect(formatLiteral(DateTime.utc(2024, 3, 4, 5, 6, 7, 8, 9)),
          "'2024-03-04T05:06:07.008009+00:00'::TIMESTAMP_TZ");
    });

    test('renders a Duration as a TIME', () {
      expect(formatLiteral(const Duration(hours: 1, minutes: 2, seconds: 3)),
          "'01:02:03.000000'::TIME");
      expect(formatLiteral(const Duration(microseconds: 1)),
          "'00:00:00.000001'::TIME");
    });

    test('refuses a TIME that does not fall within one day', () {
      expect(() => formatLiteral(const Duration(hours: 24)),
          throwsA(isA<UsageException>()));
      expect(() => formatLiteral(const Duration(seconds: -1)),
          throwsA(isA<UsageException>()));
    });

    test('refuses a type with no SQL equivalent', () {
      expect(() => formatLiteral(Object()), throwsA(isA<UsageException>()));
      expect(() => formatLiteral(#symbol), throwsA(isA<UsageException>()));
    });
  });

  group('statement scanning', () {
    test('splits on top-level semicolons only', () {
      expect(splitStatements('A; B'), ['A', ' B']);
      expect(splitStatements("SELECT 'a;b'"), ["SELECT 'a;b'"]);
      expect(splitStatements(r'CREATE FUNCTION f() AS $$ a; b $$'),
          [r'CREATE FUNCTION f() AS $$ a; b $$']);
      expect(splitStatements('SELECT 1 -- ;\n'), ['SELECT 1 -- ;\n']);
    });

    test('ends a line comment at a carriage return as well as a line feed', () {
      expect(splitStatements('SELECT 1 -- a\r; SELECT 2'),
          ['SELECT 1 -- a\r', ' SELECT 2']);
      expect(splitStatements('SELECT 1 // a\r; SELECT 2'),
          ['SELECT 1 // a\r', ' SELECT 2']);
      expect(changesSessionScope('SELECT 1 -- c\r; USE DATABASE db'), isTrue);
      expect(leadingWords('-- c\rUSE DATABASE d', 2), ['USE', 'DATABASE']);
      expect(touchesSession('-- c\rCREATE TEMP TABLE t (a INT)'), isTrue);
      expect(transactionEffect('-- c\rBEGIN'), TransactionEffect.begins);
    });

    test('reads a name whole, so only dollars outside one open a body', () {
      expect(splitStatements(r'SELECT A$$B; SELECT 2'),
          [r'SELECT A$$B', ' SELECT 2']);
      // A $$ right after a number or a closed body does open one.
      expect(splitStatements(r'SELECT 1$$;$$; SELECT 2'),
          [r'SELECT 1$$;$$', ' SELECT 2']);
      expect(splitStatements(r'SELECT $$a$$$$;$$; SELECT 2'),
          [r'SELECT $$a$$$$;$$', ' SELECT 2']);
    });

    test('spots the statements that move a session', () {
      for (final sql in [
        'USE DATABASE db',
        'use schema s',
        'SET x = 1',
        'UNSET x',
        'ALTER SESSION SET TIMEZONE = \'UTC\'',
        'CREATE DATABASE db',
        'CREATE OR REPLACE DATABASE db',
        'DROP SCHEMA IF EXISTS s',
        'CREATE TRANSIENT SCHEMA s',
        // A USE riding behind a leading SELECT moves the scope just as surely.
        'SELECT 1; USE DATABASE db',
        '-- comment\nUSE DATABASE db',
      ]) {
        expect(changesSessionScope(sql), isTrue, reason: sql);
      }
    });

    test('leaves ordinary statements alone', () {
      for (final sql in [
        'SELECT 1',
        'CREATE TABLE t (a INT)',
        'CREATE OR REPLACE VIEW v AS SELECT 1',
        'DROP TABLE t',
        'ALTER TABLE t ADD COLUMN b INT',
        'INSERT INTO t VALUES (1)',
        "SELECT 'USE DATABASE db'",
      ]) {
        expect(changesSessionScope(sql), isFalse, reason: sql);
      }
    });
  });
}
