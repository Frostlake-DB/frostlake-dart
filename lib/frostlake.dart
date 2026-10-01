/// A Dart driver for [Frostlake](https://frostlake.dev), speaking the engine's
/// HTTP protocol against a running `DatabaseHttpServer`.
///
/// ```dart
/// import 'package:frostlake/frostlake.dart';
///
/// Future<void> main() async {
///   final conn = await connect('frostlake://localhost:18082/MY_DB?schema=PUBLIC');
///   await conn.execute('CREATE TABLE people (id INTEGER, name VARCHAR)');
///   await conn.execute('INSERT INTO people VALUES (?, ?)', [1, 'Ada']);
///
///   final result = await conn.execute('SELECT id, name FROM people WHERE id = ?', [1]);
///   print(result.rows.first['NAME']); // Ada
///
///   await conn.close();
/// }
/// ```
///
/// Parameters are inlined client-side — the protocol has no server-side
/// binding — with the same rules as Frostlake's JDBC driver: a `?` inside a
/// string literal, quoted identifier, `$$...$$` body or comment is never a
/// placeholder, and the argument count has to match whenever arguments are
/// supplied. With none at all the `?` marks pass through to the server, which
/// is where a Snowflake Scripting cursor binds them (`OPEN c USING (...)`).
///
/// The package has no dependencies: the transport is `dart:io`'s `HttpClient`
/// and the JSON layer is the driver's own, which is what lets a `NUMBER(38,0)`
/// wider than 64 bits arrive as an exact [BigInt] rather than a rounded double.
library;

export 'src/binding.dart' show formatLiteral, formatTime, formatTimestamp;
export 'src/connection.dart' show Connection, connect;
export 'src/dsn.dart'
    show
        Config,
        defaultConnectTimeout,
        defaultPort,
        defaultRequestTimeout,
        defaultSessionIdleLimit,
        parseDsn,
        quoteIdentifier;
export 'src/errors.dart'
    show
        ConnectionException,
        FrostlakeException,
        QueryException,
        SessionLostException,
        UsageException;
export 'src/result.dart' show ColumnInfo, Result;
