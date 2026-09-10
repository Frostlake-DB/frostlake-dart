import 'package:frostlake/frostlake.dart';
import 'package:test/test.dart';

void main() {
  group('parseDsn', () {
    test('reads host, port and database', () {
      final config = parseDsn('frostlake://localhost:18082/MY_DB');
      expect(config.host, 'localhost');
      expect(config.port, 18082);
      expect(config.database, 'MY_DB');
      expect(config.secure, isFalse);
      expect(config.baseUrl, 'http://localhost:18082');
    });

    test('puts an IPv6 literal back into brackets for the base URL', () {
      final config = parseDsn('frostlake://[::1]:18082/DB');
      expect(config.host, '::1');
      expect(config.baseUrl, 'http://[::1]:18082');
    });

    test('falls back to the engine port when the DSN names none', () {
      expect(parseDsn('frostlake://localhost').port, defaultPort);
      expect(parseDsn('frostlake://localhost/DB').port, defaultPort);
    });

    test('keeps the scheme default port for http and https', () {
      expect(
          parseDsn('http://localhost:8080').baseUrl, 'http://localhost:8080');
      // Uri drops a port that is its scheme's default, so these have to be put
      // back rather than falling through to the engine's own port.
      expect(parseDsn('https://example.test:443').baseUrl,
          'https://example.test:443');
      expect(
          parseDsn('http://example.test:80').baseUrl, 'http://example.test:80');
      expect(parseDsn('http://example.test').port, 80);
      expect(parseDsn('https://example.test').port, 443);
    });

    test('https and tls=true both mean HTTPS', () {
      expect(parseDsn('https://host:1/DB').secure, isTrue);
      expect(parseDsn('frostlake://host:1/DB?tls=true').secure, isTrue);
      expect(parseDsn('frostlake://host:1/DB?tls=1').secure, isTrue);
      expect(parseDsn('frostlake://host:1/DB?tls=false').secure, isFalse);
    });

    test('reads the scope parameters', () {
      final config = parseDsn(
          'frostlake://h:1/DB?schema=PUBLIC&role=SYSADMIN&warehouse=WH');
      expect(config.schema, 'PUBLIC');
      expect(config.role, 'SYSADMIN');
      expect(config.warehouse, 'WH');
    });

    test('renders the scope as USE statements in dependency order', () {
      final config = parseDsn(
          'frostlake://h:1/MY_DB?schema=PUBLIC&role=SYSADMIN&warehouse=WH');
      expect(config.useStatements(), [
        'USE ROLE "SYSADMIN"',
        'USE WAREHOUSE "WH"',
        'USE DATABASE "MY_DB"',
        'USE SCHEMA "PUBLIC"',
      ]);
    });

    test('names no scope when the DSN names none', () {
      expect(parseDsn('frostlake://h:1').useStatements(), isEmpty);
    });

    test('reads durations with and without a unit', () {
      expect(parseDsn('frostlake://h:1?timeout=30').timeout,
          const Duration(seconds: 30));
      expect(parseDsn('frostlake://h:1?timeout=30s').timeout,
          const Duration(seconds: 30));
      expect(parseDsn('frostlake://h:1?timeout=500ms').timeout,
          const Duration(milliseconds: 500));
      expect(parseDsn('frostlake://h:1?timeout=5m').timeout,
          const Duration(minutes: 5));
      expect(parseDsn('frostlake://h:1?timeout=1h').timeout,
          const Duration(hours: 1));
      expect(parseDsn('frostlake://h:1?timeout=1.5s').timeout,
          const Duration(milliseconds: 1500));
    });

    test('zero removes a bound rather than being rejected', () {
      expect(parseDsn('frostlake://h:1?timeout=0').timeout, Duration.zero);
      expect(parseDsn('frostlake://h:1?idleLimit=0').idleLimit, Duration.zero);
    });

    test('applies the defaults', () {
      final config = parseDsn('frostlake://h:1');
      expect(config.timeout, defaultRequestTimeout);
      expect(config.connectTimeout, defaultConnectTimeout);
      expect(config.idleLimit, defaultSessionIdleLimit);
      expect(config.database, isNull);
      expect(config.schema, isNull);
    });

    test('refuses a scheme that is not ours', () {
      expect(() => parseDsn('jdbc:frostlake:direct:'),
          throwsA(isA<UsageException>()));
      expect(() => parseDsn('ftp://host/db'), throwsA(isA<UsageException>()));
      expect(() => parseDsn('localhost:18082'), throwsA(isA<UsageException>()));
    });

    test('refuses a DSN with no host', () {
      expect(() => parseDsn('frostlake:///DB'), throwsA(isA<UsageException>()));
    });

    test('refuses credentials rather than dropping them silently', () {
      // The server authenticates nobody, so a password in a DSN would go
      // nowhere — and silently dropping one is worse than saying so.
      expect(
          () => parseDsn('frostlake://user:secret@host:1/DB'),
          throwsA(isA<UsageException>().having(
              (e) => e.message, 'message', contains('no credentials'))));
    });

    test('refuses an unknown parameter rather than ignoring it', () {
      expect(
          () => parseDsn('frostlake://h:1?shcema=PUBLIC'),
          throwsA(isA<UsageException>()
              .having((e) => e.message, 'message', contains('shcema'))));
    });

    test('refuses a path naming more than one database', () {
      expect(() => parseDsn('frostlake://h:1/DB/EXTRA'),
          throwsA(isA<UsageException>()));
    });

    test('accepts a trailing slash', () {
      expect(parseDsn('frostlake://h:1/DB/').database, 'DB');
      expect(parseDsn('frostlake://h:1/').database, isNull);
    });

    test('refuses a malformed duration and an empty scope name', () {
      expect(() => parseDsn('frostlake://h:1?timeout=soon'),
          throwsA(isA<UsageException>()));
      expect(() => parseDsn('frostlake://h:1?timeout=-5s'),
          throwsA(isA<UsageException>()));
      expect(() => parseDsn('frostlake://h:1?schema='),
          throwsA(isA<UsageException>()));
    });

    test('refuses a port outside the legal range', () {
      expect(() => parseDsn('frostlake://h:70000'), throwsA(isA<Object>()));
    });
  });

  group('quoteIdentifier', () {
    test('always quotes, so a reserved or oddly cased name still resolves', () {
      expect(quoteIdentifier('MY_DB'), '"MY_DB"');
      expect(quoteIdentifier('select'), '"select"');
      expect(quoteIdentifier('1ABC'), '"1ABC"');
    });

    test('doubles embedded quotes, so a name cannot break out', () {
      expect(quoteIdentifier('a"b'), '"a""b"');
      expect(quoteIdentifier('"; DROP DATABASE X; --'),
          '"""; DROP DATABASE X; --"');
    });

    test('refuses an empty name', () {
      expect(() => quoteIdentifier(''), throwsA(isA<UsageException>()));
    });
  });
}
