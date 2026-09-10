# frostlake-dart

A dependency-free Dart driver for [Frostlake](https://frostlake.dev), speaking the engine's
HTTP protocol against a running `DatabaseHttpServer`. Dart 3, `dart:io` only — no JVM, no
native extensions, nothing in `pubspec.yaml` but the SDK.

## Engine version

Requires a Frostlake engine **0.0.7 or newer**. Ask a running server which one it is with
`SELECT CURRENT_VERSION()` — every release answers it, so the check works against any engine.

The driver versions independently of the engine: it speaks the HTTP protocol, not the jar, so
this is a floor rather than a lockstep pin.

## Usage

```dart
import 'package:frostlake/frostlake.dart';

Future<void> main() async {
  final conn = await connect('frostlake://localhost:18082/MY_DB?schema=PUBLIC');

  await conn.execute('CREATE TABLE people (id INTEGER, name VARCHAR)');

  final inserted = await conn.execute(
      'INSERT INTO people VALUES (?, ?), (?, ?)', [1, 'Ada', 2, 'Grace']);
  print(inserted.updateCount); // 2

  final result = await conn.execute('SELECT id, name FROM people WHERE id = ?', [1]);
  print(result.rows.first['NAME']); // Ada

  await conn.close();
}
```

`connect` contacts the server before it returns: it calls the health endpoint and applies the
scope the DSN names, so a database that does not exist is reported there rather than surfacing
later on whichever query happened to run first.

### DSN

```
frostlake://host[:port][/DATABASE][?param=value&…]
```

`http://` and `https://` are accepted too and mean the same thing. Omitting the port means the
engine's own default, `18082`; for `http`/`https` it means their standard ports.

| Parameter | Meaning | Default |
| --- | --- | --- |
| `schema` | schema to `USE` on the session | — |
| `role` | role to `USE` on the session | — |
| `warehouse` | warehouse to `USE` on the session | — |
| `timeout` | how long one statement may take; `0` removes the bound | `5m` |
| `connectTimeout` | how long to wait for the socket | `10s` |
| `idleLimit` | how long a connection may idle before its scope is re-applied; `0` switches the check off | `30m` |
| `tls` | `true` to speak HTTPS — an `https://` DSN does the same | `false` |

Durations are written as a bare number of seconds or with a `ms`/`s`/`m`/`h` suffix. An unknown
parameter is an error rather than a silent no-op, and so is a username or password — the
engine's HTTP API has no authentication to hand them to, and quietly dropping a password is
worse than saying so.

`timeout`, `connectTimeout` and `idleLimit` can also be passed to `connect` directly, where an
explicit argument outranks the DSN.

### Results

`execute` resolves to a `Result`:

| Member | What it holds |
| --- | --- |
| `columns` | `ColumnInfo` per column: name, declared type, nullability, precision, scale |
| `values` | every cell, positionally aligned with `columns` — the lossless view |
| `rows` | each row keyed by column name, built on first use |
| `value` | the first cell of the first row, for a single-value query |
| `rowCount` | rows returned, or rows affected for DML |
| `updateCount` | rows affected by DML, or `-1` when the statement returned data |
| `counters` | the raw `number of rows …` counters behind `updateCount` |

`rows` cannot represent two columns called the same thing — a self-join reports `ID` twice and
the later one wins — which is why `values` is there.

A statement string holding several `;`-separated statements answers with one result each:
`executeAll` returns them all, and `execute` hands back the first.

### Bind values

Parameters are inlined client-side — the protocol has no server-side binding — with the same
rules as Frostlake's JDBC driver. A `?` inside a string literal, quoted identifier, `$$…$$`
body or comment is never a placeholder, and the argument count has to match exactly whenever
arguments are supplied. With no arguments at all the `?` marks pass through to the server: they
are then a Snowflake Scripting cursor placeholder, bound by `OPEN c USING (...)`.

| Dart value | SQL literal |
| --- | --- |
| `null` | `NULL` |
| `bool` | `TRUE` / `FALSE` |
| `int`, `BigInt` | the digits, exactly |
| `double` | the shortest round-tripping form; NaN and the infinities cast from text |
| `String` | `'…'`, backslashes and quotes escaped |
| `Uint8List` | `X'hex'` |
| `DateTime` | `'…'::TIMESTAMP_TZ`, carrying its UTC offset |
| `Duration` | `'…'::TIME`, as a time of day |
| `List` | `[…]`, elements formatted recursively |
| `Map` | `{'key': …}`, values formatted recursively |

A `Uint8List` is the deliberate marker for binary; a plain `List<int>` is an array of numbers.
Guessing between them from the element type would make `[1, 2, 3]` mean two different things.

Statements may use positional `?` or named `:name` placeholders, one style per statement:

```dart
await conn.executeNamed('SELECT :a + :b AS total', {'a': 2, 'b': 40});
```

Names match case-insensitively and their order does not matter. A `::` cast, a `:=` assignment
and a `:1` positional reference are never parameters — and neither is Snowflake's VARIANT path
access: a colon glued to the end of an expression (`v:field`, `PARSE_JSON('…'):k`, `"V":k`)
reads a field, so a bind marker has to follow an operator, comma or keyword boundary. With **no
arguments at all**, colon references pass through to the server untouched, because that is what
Snowflake Scripting variables look like (`EXECUTE IMMEDIATE :v`, `IFF(:flag, …)`).

### Types coming back

| SQL type | Dart type |
| --- | --- |
| integral `NUMBER`, `INTEGER` and friends | `int`, or `BigInt` past 64 bits |
| fractional `NUMBER`, `FLOAT`, `DOUBLE`, `REAL` | `double` |
| `VARCHAR` and the text types | `String` |
| `BOOLEAN` | `bool` |
| `BINARY` | `Uint8List` |
| `DATE` | `DateTime`, flagged UTC |
| `TIME` | `Duration` since midnight |
| `TIMESTAMP`, `TIMESTAMP_NTZ`, `DATETIME` | `DateTime`, flagged UTC |
| `TIMESTAMP_LTZ`, `TIMESTAMP_TZ` | `DateTime` — the instant, in UTC |
| `VARIANT`, `OBJECT`, `ARRAY` | `String`, the engine's own rendering |

A `NUMBER(38,0)` holds integers no `int` can name. The driver's JSON layer keeps every number's
literal text rather than resolving it while parsing, so those arrive as an exact `BigInt`
instead of the rounded `double` `dart:convert` would produce.

Two notes on time. A `DATE` and a `TIMESTAMP_NTZ` are wall clocks with no zone of their own, so
they come back flagged UTC and their fields read back exactly as stored, rather than being
shifted by whatever zone the host is in. And `DateTime`'s `==` compares the zone flag as well
as the instant, so compare a zoned value with `isAtSameMomentAs` rather than `==`.

A `TIME` has no Dart type of its own; putting one on an arbitrary date would invent a day the
value never had, so it arrives as a `Duration` since midnight — and a bound `Duration` goes back
as a `TIME`, so the column round-trips.

### Transactions

```dart
await conn.transaction((c) async {
  await c.execute('INSERT INTO acc VALUES (1)');
});
```

The helper commits when the body returns and rolls back when it throws, re-raising the original
error either way. `begin`, `commit` and `rollback` are there for hand-rolled control. The engine
offers read committed.

A transaction lives on the session, not on the closure, so anything else run on the same
connection meanwhile joins it. Give a transaction its own connection if that is not what you
want.

### Errors

Every failure is a `FrostlakeException`, so one `on FrostlakeException` catches the lot. The
subclasses say which kind it was, which is the distinction a caller actually branches on:

- **`QueryException`** — the engine refused the statement. `message` is the engine's own
  wording, unmodified.
- **`ConnectionException`** — the request never became an answer: the host refused, the socket
  died, the deadline passed, or a proxy replied with something that is not a Frostlake response.
  A statement that failed this way has an *unknown* fate, so it must not be blindly retried —
  re-running an INSERT would duplicate it.
- **`UsageException`** — the driver never sent it: a malformed DSN, a closed connection, a bind
  value with no SQL equivalent, an argument count that does not match the placeholders.

**`QueryException.statement` holds the rendered SQL.** Because binding is client-side, that
means every parameter inlined — a bound password or card number appears in it verbatim.
`toString()` and `message` carry none of it, so log those freely and treat `statement` as
sensitive.

### Sessions and concurrency

One HTTP session per `Connection`. Statements on a connection are serialized in call order, so
awaiting several at once is safe and stays on one session — which is what keeps `USE`, session
variables and an open transaction carrying from one statement to the next.

```dart
await Future.wait([
  conn.execute('INSERT INTO t VALUES (1)'),
  conn.execute('INSERT INTO t VALUES (2)'),
]); // serialized, one session
```

Sockets are reused, which is `HttpClient`'s default; `close` drops them. Measured against a real
`DatabaseHttpServer`, a kept-alive connection is a shade faster than a fresh one per statement
with no stalls in either mode.

## Known limitations

- **Server sessions are not released on close.** The HTTP API has no endpoint for ending a
  session, so a closed connection's session lingers until the engine's own 30-minute idle sweep
  reclaims it. Connection churn therefore accrues server-side sessions.
- **A session idle past that sweep silently resumes at the server's default scope**, because the
  engine re-creates an expired session under the very same id — nothing in the answer tells a
  client its session was reclaimed. The driver covers this by re-applying the DSN's scope to a
  connection that has been idle longer than `idleLimit`, but anything else the session held (a
  session variable, an `ALTER SESSION` setting) is gone. It stops doing so once the caller has
  issued their own `USE`, since the DSN no longer describes where they are.
- **Timestamps carry milliseconds in transit.** The engine holds full nanoseconds, but the HTTP
  layer serialises milliseconds, so a temporal cell arrives millisecond-precise however fine the
  stored value. `TO_VARCHAR(ts, 'YYYY-MM-DD HH24:MI:SS.FF9')` is the way to read the rest.
- **Failures carry no error code.** The protocol reports a message only — no code, no SQLSTATE —
  so `QueryException` has none to offer.
- **A blank statement is refused by the endpoint**, with HTTP 400 and `SQL is required`, before
  the engine sees it; the engine's own `Empty SQL statement.` wording never reaches a client
  over this transport.
- **`dart:io` only.** The transport is `HttpClient`, so the package runs on the Dart VM and in
  Flutter's mobile and desktop targets, not on the web.

## Tests

The unit tests need nothing installed — no engine, no JVM:

```bash
dart test test/json_test.dart test/dsn_test.dart test/binding_test.dart test/values_test.dart
```

The integration tests additionally boot a real server from an engine classpath, and skip
themselves when `FROSTLAKE_CLASSPATH` is unset, so an unconfigured run is never falsely green:

```bash
JAVA_HOME=/path/to/jdk17 FROSTLAKE_CLASSPATH="<engine classes>;<dependency classpath>" dart test
```

Those drive a real engine over the driver's own HTTP path — DDL and DML, every type that can be
bound and read back, transactions, session scope, and the transport failures — so nothing in
them is mocked. Against engine 0.0.7 all 143 tests pass.

## License

Apache-2.0 — see [LICENSE](LICENSE).
