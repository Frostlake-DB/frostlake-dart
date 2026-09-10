import 'dart:typed_data';

import 'package:frostlake/frostlake.dart';
import 'package:frostlake/src/json.dart';
import 'package:frostlake/src/values.dart';
import 'package:test/test.dart';

ColumnInfo column(String dataType, {int? scale, int? precision}) => ColumnInfo(
    name: 'C', dataType: dataType, scale: scale, precision: precision);

void main() {
  group('type names', () {
    test('strips a (p,s) suffix', () {
      expect(baseTypeName('NUMBER(38,0)'), 'NUMBER');
      expect(baseTypeName(' varchar(16) '), 'VARCHAR');
      expect(baseTypeName(null), '');
    });

    test('classifies the temporal types', () {
      expect(temporalKindOf('DATE'), TemporalKind.date);
      expect(temporalKindOf('TIME'), TemporalKind.time);
      expect(temporalKindOf('TIMESTAMP_NTZ'), TemporalKind.naive);
      expect(temporalKindOf('TIMESTAMP'), TemporalKind.naive);
      expect(temporalKindOf('DATETIME'), TemporalKind.naive);
      expect(temporalKindOf('TIMESTAMP_LTZ'), TemporalKind.zoned);
      expect(temporalKindOf('TIMESTAMP_TZ'), TemporalKind.zoned);
      expect(temporalKindOf('VARCHAR'), TemporalKind.none);
    });

    test('reads scale from the wire field, falling back to the type name', () {
      expect(declaredScale(column('NUMBER', scale: 2)), 2);
      expect(declaredScale(column('NUMBER(10,3)')), 3);
      expect(declaredScale(column('NUMBER(38,0)')), 0);
      expect(declaredScale(column('NUMBER')), 0);
    });

    test('reads the non-finite spellings of a FLOAT column as doubles', () {
      // The engine sends them as JSON strings even on a DOUBLE column.
      final nan = convertCell('NaN', column('FLOAT'));
      expect(nan, isA<double>());
      expect((nan! as double).isNaN, isTrue);
      expect(convertCell('Infinity', column('DOUBLE')), double.infinity);
      expect(convertCell('-Infinity', column('REAL')), double.negativeInfinity);
      // On a text column the words are just words.
      expect(convertCell('NaN', column('VARCHAR')), 'NaN');
    });

    test('reads a whole number however the engine spelled it', () {
      final integral = column('NUMBER', scale: 0, precision: 38);
      expect(convertCell(const JsonNumber('1E+3'), integral), 1000);
      expect(convertCell(const JsonNumber('12.000'), integral), 12);
      expect(convertCell(const JsonNumber('-1.5E+1'), integral), -15);
      expect(convertCell(const JsonNumber('12345678901234567890123.00'), integral),
          BigInt.parse('12345678901234567890123'));
      // Genuinely fractional stays a double.
      expect(convertCell(const JsonNumber('1.25E+1'), integral), 12.5);
    });

    test('knows which columns hold whole numbers', () {
      expect(isIntegralColumn(column('INTEGER')), isTrue);
      expect(isIntegralColumn(column('NUMBER', scale: 0)), isTrue);
      expect(isIntegralColumn(column('NUMBER', scale: 2)), isFalse);
      expect(isIntegralColumn(column('FLOAT')), isFalse);
      expect(isIntegralColumn(column('VARCHAR')), isFalse);
    });
  });

  group('convertCell', () {
    test('passes NULL and booleans through', () {
      expect(convertCell(null, column('VARCHAR')), isNull);
      expect(convertCell(true, column('BOOLEAN')), isTrue);
      expect(convertCell(false, column('BOOLEAN')), isFalse);
    });

    test('reads an integral column as an int', () {
      expect(convertCell(const JsonNumber('42'), column('INTEGER')), 42);
      expect(
          convertCell(const JsonNumber('-1'), column('NUMBER', scale: 0)), -1);
      expect(
          convertCell(const JsonNumber('42'), column('INTEGER')), isA<int>());
    });

    test('reads an integer wider than 64 bits as an exact BigInt', () {
      // NUMBER(38,0) holds values no int can name; a double would round them.
      const digits = '99999999999999999999999999999999999999';
      final value =
          convertCell(const JsonNumber(digits), column('NUMBER', scale: 0));
      expect(value, isA<BigInt>());
      expect(value.toString(), digits);
    });

    test('reads fractional and approximate columns as doubles', () {
      expect(convertCell(const JsonNumber('1.5'), column('NUMBER', scale: 1)),
          1.5);
      expect(convertCell(const JsonNumber('2'), column('FLOAT')), 2.0);
      expect(
          convertCell(const JsonNumber('2'), column('FLOAT')), isA<double>());
      expect(convertCell(const JsonNumber('1e3'), column('DOUBLE')), 1000.0);
    });

    test('reads a DATE as a UTC-flagged calendar day', () {
      // A DATE is a wall clock with no zone of its own, so it comes back
      // flagged UTC and its fields read back exactly as stored.
      final value = convertCell('2024-03-04', column('DATE'))! as DateTime;
      expect(value, DateTime.utc(2024, 3, 4));
      expect(value.isUtc, isTrue);
    });

    test('reads a TIME as a Duration since midnight', () {
      // Dart has no time-of-day type, and putting one on an arbitrary date
      // would invent a day the value never had.
      expect(convertCell('01:02:03', column('TIME')),
          const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(convertCell('00:00:00.123456', column('TIME')),
          const Duration(microseconds: 123456));
    });

    test('reads a zoneless timestamp as its wall clock', () {
      for (final text in [
        '2024-03-04 05:06:07.008',
        '2024-03-04T05:06:07.008'
      ]) {
        final value = convertCell(text, column('TIMESTAMP_NTZ'))! as DateTime;
        expect(value, DateTime.utc(2024, 3, 4, 5, 6, 7, 8));
        expect(value.isUtc, isTrue, reason: text);
      }
    });

    test('reads a zoned timestamp as the instant it names', () {
      for (final text in [
        '2024-03-04 05:06:07 +0200',
        '2024-03-04 05:06:07 +02:00',
        '2024-03-04T05:06:07+02:00',
      ]) {
        expect(convertCell(text, column('TIMESTAMP_TZ')),
            DateTime.utc(2024, 3, 4, 3, 6, 7),
            reason: text);
      }
      expect(convertCell('2024-03-04 05:06:07 -0130', column('TIMESTAMP_LTZ')),
          DateTime.utc(2024, 3, 4, 6, 36, 7));
      expect(convertCell('2024-03-04T05:06:07Z', column('TIMESTAMP_TZ')),
          DateTime.utc(2024, 3, 4, 5, 6, 7));
    });

    test('reads a zoned column that arrived without an offset', () {
      // Still readable as a wall clock rather than lost.
      expect(convertCell('2024-03-04 05:06:07', column('TIMESTAMP_TZ')),
          DateTime.utc(2024, 3, 4, 5, 6, 7));
    });

    test('rounds sub-microsecond precision away rather than failing', () {
      expect(
          convertCell('2024-03-04 05:06:07.123456789', column('TIMESTAMP_NTZ')),
          DateTime.utc(2024, 3, 4, 5, 6, 7, 123, 456));
    });

    test('reads BINARY as bytes', () {
      expect(convertCell('000FFF', column('BINARY')),
          Uint8List.fromList([0x00, 0x0f, 0xff]));
      expect(convertCell('00ff', column('VARBINARY')),
          Uint8List.fromList([0x00, 0xff]));
      expect(convertCell('', column('BINARY')), Uint8List(0));
    });

    test('hands back the text when a value is not what its type promised', () {
      // Losing the value would be worse than handing back something readable.
      expect(convertCell('nothex', column('BINARY')), 'nothex');
      expect(convertCell('0F0', column('BINARY')), '0F0', reason: 'odd length');
      expect(convertCell('not a date', column('DATE')), 'not a date');
      expect(convertCell('25:00:00', column('TIME')), isA<Duration>(),
          reason: 'hours past 24 still parse as a duration');
    });

    test('reads semi-structured columns as the engine rendered them', () {
      expect(convertCell('{"a": 1}', column('VARIANT')), '{"a": 1}');
      expect(convertCell('[1, 2]', column('ARRAY')), '[1, 2]');
    });

    test('reads a number on a non-numeric column without inventing a type', () {
      // A VARIANT holding a whole number is still a whole number.
      expect(convertCell(const JsonNumber('7'), column('VARIANT')), 7);
      expect(convertCell(const JsonNumber('7.5'), column('VARIANT')), 7.5);
    });
  });

  group('decodeHex', () {
    test('decodes what the engine renders BINARY as', () {
      expect(
          decodeHex('DEADBEEF'), Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]));
      expect(
          decodeHex('deadbeef'), Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]));
      expect(decodeHex(''), Uint8List(0));
    });

    test('refuses what is not hex rather than guessing', () {
      expect(decodeHex('ZZ'), isNull);
      expect(decodeHex('ABC'), isNull);
      expect(decodeHex('0x41'), isNull);
    });
  });

  group('Result', () {
    final result = Result(
      columns: const [
        ColumnInfo(name: 'ID', dataType: 'NUMBER'),
        ColumnInfo(name: 'NAME', dataType: 'VARCHAR'),
      ],
      values: const [
        [1, 'Ada'],
        [2, 'Grace'],
      ],
      updateCount: -1,
    );

    test('keys rows by column name', () {
      expect(result.rows, [
        {'ID': 1, 'NAME': 'Ada'},
        {'ID': 2, 'NAME': 'Grace'},
      ]);
    });

    test('counts rows and reports the first cell', () {
      expect(result.rowCount, 2);
      expect(result.value, 1);
      expect(result.isUpdate, isFalse);
    });

    test('builds rows once and keeps them', () {
      expect(identical(result.rows, result.rows), isTrue);
    });

    test('reports an update by its affected count', () {
      final update = Result(
          columns: const [],
          values: const [],
          updateCount: 3,
          counters: const {'number of rows inserted': 3});
      expect(update.isUpdate, isTrue);
      expect(update.rowCount, 3);
      expect(update.rows, isEmpty);
      expect(update.counters['number of rows inserted'], 3);
    });

    test('an empty result reads as empty rather than throwing', () {
      final empty =
          Result(columns: const [], values: const [], updateCount: -1);
      expect(empty.value, isNull);
      expect(empty.rowCount, 0);
      expect(empty.rows, isEmpty);
    });
  });
}
