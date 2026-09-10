import 'dart:convert' as dart_convert;

import 'package:frostlake/frostlake.dart';
import 'package:frostlake/src/json.dart';
import 'package:test/test.dart';

void main() {
  group('decodeJson', () {
    test('reads the shapes a response is made of', () {
      final decoded =
          decodeJson('{"success":true,"sessionId":"s1","rows":[[1,"a",null]]}');
      expect(decoded, isA<Map<String, Object?>>());
      final body = decoded! as Map<String, Object?>;
      expect(body['success'], isTrue);
      expect(body['sessionId'], 's1');
      expect((body['rows']! as List).first, [const JsonNumber('1'), 'a', null]);
    });

    test('keeps an integer wider than 64 bits exact', () {
      // dart:convert cannot: it resolves this one to a double while parsing,
      // which is the reason this parser exists at all.
      const digits = '123456789012345678901234567890';
      final ours = (decodeJson('[$digits]')! as List).first! as JsonNumber;
      expect(ours.asBigInt.toString(), digits);
      expect(ours.asInt, isNull, reason: 'does not fit in 64 bits');

      final theirs = (dart_convert.jsonDecode('[$digits]') as List).first;
      expect(theirs, isA<double>());
      expect(theirs.toString(), isNot(digits));
    });

    test('keeps a decimal exact', () {
      final number = (decodeJson('[12345678901234567890.123456789]')! as List)
          .first! as JsonNumber;
      expect(number.text, '12345678901234567890.123456789');
      expect(number.isIntegral, isFalse);
      expect(number.asBigInt, isNull);
    });

    test('reads the whole number grammar', () {
      for (final literal in ['0', '-0', '1e10', '1E+10', '-1.5e-3', '-42']) {
        final number = (decodeJson('[$literal]')! as List).first! as JsonNumber;
        expect(number.text, literal);
        expect(number.asDouble, double.parse(literal));
      }
    });

    test('unescapes strings', () {
      final decoded = decodeJson(r'["a\"b\\c\/d\ne\tféA"]')! as List;
      expect(decoded.first, 'a"b\\c/d\ne\tféA');
    });

    test('reassembles a surrogate pair', () {
      expect((decodeJson(r'["😀"]')! as List).first, '\u{1f600}');
    });

    test('handles empty containers and nesting', () {
      expect(decodeJson('{}'), <String, Object?>{});
      expect(decodeJson('[]'), <Object?>[]);
      expect(decodeJson('[[[["deep"]]]]'), [
        [
          [
            ['deep'],
          ],
        ],
      ]);
    });

    test('accepts whitespace anywhere it is allowed', () {
      expect(decodeJson('  {\n "a" :\t[ 1 , 2 ]\r\n}  '), {
        'a': [const JsonNumber('1'), const JsonNumber('2')]
      });
    });

    test('refuses malformed input as a transport failure', () {
      // What the driver actually parses arrived over the wire, so a parse
      // failure means the far side is not a Frostlake engine.
      for (final bad in [
        '<html>502 Bad Gateway</html>',
        '{"a":}',
        '{"a" 1}',
        '[1,]',
        '[1',
        '"unterminated',
        '{"a":1} trailing',
        'nul',
        '01',
        r'["\q"]',
      ]) {
        expect(() => decodeJson(bad), throwsA(isA<ConnectionException>()),
            reason: 'should refuse: $bad');
      }
    });

    test('reads the engine\'s VARIANT undefined token', () {
      // Not JSON, but what the engine writes for a SQL NULL that entered an
      // ARRAY. Refusing it would throw away the whole response over one element.
      expect(decodeJson('[1,undefined,2]'),
          [const JsonNumber('1'), jsonUndefined, const JsonNumber('2')]);
      expect(decodeJson('undefined'), jsonUndefined);
      // It survives a round trip as the same bare token.
      expect(encodeJson(decodeJson('[1,undefined,2]')), '[1,undefined,2]');
    });

    test('a word that merely starts like undefined is still refused', () {
      expect(() => decodeJson('[undef]'), throwsA(isA<ConnectionException>()));
      expect(() => decodeJson('[nulled]'), throwsA(isA<ConnectionException>()));
    });

    test('refuses a document nested past the depth limit', () {
      final deep = '${'[' * 600}1${']' * 600}';
      expect(() => decodeJson(deep), throwsA(isA<ConnectionException>()));
    });

    test('quotes the neighbourhood of a failure', () {
      expect(
          () => decodeJson('{"status":"oops" "extra"}'),
          throwsA(isA<ConnectionException>()
              .having((e) => e.message, 'message', contains('extra'))));
    });
  });

  group('JsonNumber.asWholeNumber', () {
    test('reads exponent and zero-fraction spellings exactly', () {
      expect(const JsonNumber('7').asWholeNumber, 7);
      expect(const JsonNumber('1E+3').asWholeNumber, 1000);
      expect(const JsonNumber('1.2E+5').asWholeNumber, 120000);
      expect(const JsonNumber('12.000').asWholeNumber, 12);
      expect(const JsonNumber('-0.0').asWholeNumber, 0);
      expect(const JsonNumber('5E-3').asWholeNumber, isNull);
      expect(const JsonNumber('1.25E+1').asWholeNumber, isNull);
      expect(const JsonNumber('123456789012345678901234567890E+2').asWholeNumber,
          BigInt.parse('12345678901234567890123456789000'));
    });
  });

  group('encodeJson', () {
    test('writes a request body', () {
      expect(
          encodeJson(
              {'sql': 'SELECT 1', 'sessionId': 'abc', 'autoCommit': true}),
          '{"sql":"SELECT 1","sessionId":"abc","autoCommit":true}');
    });

    test('escapes control characters and quotes', () {
      expect(encodeJson('a"b\\c\nd\te'), r'"a\"b\\c\nd\te"');
      expect(encodeJson('\b\f'), r'"\b\f"');
      // A lone surrogate has no UTF-8 form, so it travels as an escape; a pair
      // is a character and travels raw.
      expect(encodeJson('\ud83d'), r'"\ud83d"');
      expect(encodeJson('\ud83d\ude00'), '"\ud83d\ude00"');
      // Everything else below 0x20 has no short escape and goes out as \u00xx;
      // written raw it would be a control character sitting inside a string,
      // which is not JSON.
      final control = String.fromCharCode(1);
      final encoded = encodeJson(control);
      expect(encoded.contains(control), isFalse,
          reason: 'a raw control character inside a string is not JSON');
      expect(encoded.length, 8,
          reason: 'quote + backslash-u + 4 digits + quote');
      expect(decodeJson(encoded), control);
    });

    test('round-trips through the decoder', () {
      final value = {
        'a': [1, 2.5, null, true, 'x'],
        'b': {'nested': 'yes'},
      };
      final decoded = decodeJson(encodeJson(value))! as Map<String, Object?>;
      expect(decoded['b'], {'nested': 'yes'});
      expect((decoded['a']! as List).map((v) => v.toString()).toList(),
          ['1', '2.5', 'null', 'true', 'x']);
    });

    test('writes a number that came off the wire exactly as it arrived', () {
      expect(encodeJson([const JsonNumber('1e400'), BigInt.two]), '[1e400,2]');
    });

    test('refuses what JSON cannot spell', () {
      expect(() => encodeJson(double.nan), throwsA(isA<UsageException>()));
      expect(() => encodeJson(double.infinity), throwsA(isA<UsageException>()));
      expect(() => encodeJson(Object()), throwsA(isA<UsageException>()));
    });
  });
}
