import 'errors.dart';

/// The port a `DatabaseHttpServer` listens on unless told otherwise.
const int defaultPort = 18082;

/// Long enough for a slow query, short enough that an unreachable host fails
/// while someone is still watching.
const Duration defaultConnectTimeout = Duration(seconds: 10);
const Duration defaultRequestTimeout = Duration(minutes: 5);

/// The engine reclaims a session after 30 minutes idle. Past that the driver
/// has to assume its own is gone when the engine predates 0.1.0, because
/// nothing in such an engine's response says so.
const Duration defaultSessionIdleLimit = Duration(minutes: 30);

/// Everything the DSN query string may carry. Anything else is a typo, and a
/// typo in `schema` or `timeout` changes behaviour without saying so.
const List<String> dsnParameters = [
  'connectTimeout',
  'idleLimit',
  'role',
  'schema',
  'timeout',
  'tls',
  'warehouse',
];

/// A parsed DSN: everything a [Connection] needs to reach a server and put a
/// session on the right scope.
class Config {
  Config({
    required this.host,
    required this.port,
    required this.secure,
    this.database,
    this.schema,
    this.role,
    this.warehouse,
    this.connectTimeout = defaultConnectTimeout,
    this.timeout = defaultRequestTimeout,
    this.idleLimit = defaultSessionIdleLimit,
  });

  final String host;
  final int port;

  /// Whether to speak HTTPS.
  final bool secure;

  final String? database;
  final String? schema;
  final String? role;
  final String? warehouse;

  /// How long to wait for the socket itself.
  final Duration connectTimeout;

  /// How long one statement may take. [Duration.zero] removes the bound.
  final Duration timeout;

  /// How long a connection may sit idle before the driver stops trusting that
  /// its engine session survived. [Duration.zero] switches the check off.
  ///
  /// Only an engine before 0.1.0 needs the check: a newer one refuses a
  /// session it no longer holds, and the driver replaces it then.
  final Duration idleLimit;

  /// The base URL of the server, without a trailing slash. An IPv6 literal
  /// goes back into the brackets `Uri` stripped: `http://::1:18082` is not a
  /// URL.
  String get baseUrl =>
      '${secure ? 'https' : 'http'}://${host.contains(':') ? '[$host]' : host}'
      ':$port';

  /// The DSN's scope rendered as the `USE` statements a fresh session needs, in
  /// dependency order. Rebuilt on demand, so a session that may have lapsed can
  /// be put back on this scope.
  List<String> useStatements() => [
        if (role != null) 'USE ROLE ${_useIdentifier(role!)}',
        if (warehouse != null) 'USE WAREHOUSE ${_useIdentifier(warehouse!)}',
        if (database != null) 'USE DATABASE ${_useIdentifier(database!)}',
        if (schema != null) 'USE SCHEMA ${_useIdentifier(schema!)}',
      ];
}

/// Quotes an identifier for use in a statement.
///
/// Always quoted. Leaving "unambiguous" names bare lets through ones that
/// cannot legally appear that way — `1ABC` starts with a digit, `SELECT` is
/// reserved — and quoting costs nothing: `"NAME"` and `NAME` name the same
/// object, so only genuinely lower-case names are affected, and those had to be
/// quoted anyway. Embedded quotes are doubled, so a name arriving from a DSN
/// cannot break out.
String quoteIdentifier(String name) {
  if (name.isEmpty) {
    throw const UsageException('an identifier cannot be empty');
  }
  return '"${name.replaceAll('"', '""')}"';
}

/// A DSN name as a `USE` statement needs it. A plain name means what it means
/// unquoted in SQL — the upper-case object it folds to — so it is folded before
/// it is quoted; anything else is quoted exactly as given. Quoted as given, a
/// lower-case name would ask for a lower-case object, which `USE` refuses: it
/// resolves names exactly, as live does.
String _useIdentifier(String name) => quoteIdentifier(
    _plainIdentifier.hasMatch(name) ? name.toUpperCase() : name);

final _plainIdentifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_$]*$');

/// Parses a DSN of the form
/// `frostlake://host[:port][/DATABASE][?param=value&...]`.
///
/// `http://` and `https://` are accepted too, and mean the same thing; the
/// custom scheme exists so a DSN reads as a database URL rather than a web one.
Config parseDsn(String dsn) {
  final Uri uri;
  try {
    uri = Uri.parse(dsn);
  } on FormatException catch (e) {
    throw UsageException('invalid DSN "$dsn": ${e.message}');
  }

  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'frostlake' && scheme != 'http' && scheme != 'https') {
    throw const UsageException(
        'a DSN must start with frostlake://, http:// or https://');
  }
  if (uri.host.isEmpty) {
    throw const UsageException('the DSN is missing host[:port]');
  }
  // The server authenticates nobody, so credentials in a DSN would be silently
  // dropped — and silently dropping a password is worse than saying so.
  if (uri.userInfo.isNotEmpty) {
    throw const UsageException(
        'the server takes no credentials; remove user:password from the DSN');
  }

  // Uri drops a port that is its scheme's default, so `https://h:443` arrives
  // with hasPort false — reading the engine's own default into that would
  // quietly move the DSN to another port. Only the custom scheme, which has no
  // default of its own, falls back to the engine's.
  final port = uri.hasPort
      ? uri.port
      : switch (scheme) {
          'http' => 80,
          'https' => 443,
          _ => defaultPort,
        };
  if (port < 1 || port > 65535) {
    throw UsageException('the DSN port must be between 1 and 65535, got $port');
  }

  // A trailing slash is fine; a second segment means the caller meant something
  // the DSN cannot express, and "db/extra" is not an identifier.
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length > 1) {
    throw UsageException('the DSN path names one database, got "${uri.path}"');
  }
  final database = segments.isEmpty ? null : segments.first;

  final query = uri.queryParameters;
  final unknown = query.keys.where((k) => !dsnParameters.contains(k)).toList()
    ..sort();
  if (unknown.isNotEmpty) {
    throw UsageException('unknown DSN parameter: ${unknown.join(', ')} '
        '(expected ${dsnParameters.join(', ')})');
  }

  var secure = scheme == 'https';
  final tls = query['tls'];
  if (tls != null && _parseBool('tls', tls)) secure = true;

  return Config(
    host: uri.host,
    port: port,
    secure: secure,
    database: database,
    schema: _nonEmpty('schema', query['schema']),
    role: _nonEmpty('role', query['role']),
    warehouse: _nonEmpty('warehouse', query['warehouse']),
    connectTimeout: _parseDuration(
        'connectTimeout', query['connectTimeout'], defaultConnectTimeout),
    timeout: _parseDuration('timeout', query['timeout'], defaultRequestTimeout),
    idleLimit: _parseDuration(
        'idleLimit', query['idleLimit'], defaultSessionIdleLimit),
  );
}

String? _nonEmpty(String name, String? value) {
  if (value == null) return null;
  if (value.isEmpty) {
    throw UsageException('the DSN parameter $name cannot be empty');
  }
  return value;
}

bool _parseBool(String name, String value) {
  switch (value.toLowerCase()) {
    case 'true' || '1' || 'yes':
      return true;
    case 'false' || '0' || 'no':
      return false;
    default:
      throw UsageException('$name must be true or false, got "$value"');
  }
}

/// Reads a duration written the way a connection string writes one: a bare
/// number of seconds, or a number with a `ms`/`s`/`m`/`h` suffix. Zero is
/// meaningful — it removes the bound — so it is accepted where a negative
/// number is not.
Duration _parseDuration(String name, String? value, Duration fallback) {
  if (value == null) return fallback;
  final match =
      RegExp(r'^(\d+(?:\.\d+)?)(ms|s|m|h)?$').firstMatch(value.trim());
  if (match == null) {
    throw UsageException('$name must be a duration such as 30s, 500ms or 5m, '
        'got "$value"');
  }
  final amount = double.parse(match.group(1)!);
  final microsecondsPerUnit = switch (match.group(2) ?? 's') {
    'ms' => Duration.microsecondsPerMillisecond,
    'm' => Duration.microsecondsPerMinute,
    'h' => Duration.microsecondsPerHour,
    _ => Duration.microsecondsPerSecond,
  };
  return Duration(microseconds: (amount * microsecondsPerUnit).round());
}
