# frostlake-dart

A dependency-free Dart driver for [Frostlake](https://frostlake.dev), speaking the engine's
HTTP protocol against a running `DatabaseHttpServer`. Dart 3, `dart:io` only — no JVM, no
native extensions, nothing in `pubspec.yaml` but the SDK.

## Engine version

Requires a Frostlake engine **0.2.0 or newer**. Ask a running server which one it is with
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
| `idleLimit` | against an engine before 0.1.0, how long a connection may idle before its scope is re-applied; `0` switches the check off | `30m` |
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
| `columns` | `ColumnInfo` per column: name, declared type, nullability, precision, scale, length (characters for text, bytes for binary; `null` for every other type) |
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

### Several statements in one request

A session runs one statement per request until it asks for more, so such a request is otherwise
refused on its count rather than answered. `executeAllDeclaring` says how many this one request
holds:

```dart
final results =
    await conn.executeAllDeclaring('SELECT 1; SELECT 2', multiStatementCount: 2);
```

`0` means any number. The count travels with that one request and outranks the session's
`MULTI_STATEMENT_COUNT` without changing it, so nothing has to be saved and put back, and two
connections sharing nothing but the server cannot disturb each other. Leave the argument out and
no count is sent at all — the session's value, which
`execute('ALTER SESSION SET MULTI_STATEMENT_COUNT = n')` sets, decides as before.

It is a method of its own because Dart allows named arguments only on a signature with no optional
positional ones, and `executeAll`'s parameter list is one. So `executeAllDeclaring` takes its binds
named too: `parameters:` for `?` markers, `namedParameters:` for `:name` ones.

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

A bound `DateTime` goes into a `TIMESTAMP_TZ` column as it is. A `TIMESTAMP_NTZ` or
`TIMESTAMP_LTZ` column refuses it while compiling, as the account refuses any `TIMESTAMP_TZ`
written into one (`expecting TIMESTAMP_NTZ(9) but got TIMESTAMP_TZ(9)`), so cast the bind there:
`CAST(? AS TIMESTAMP_NTZ)` keeps the wall clock the `DateTime` was written with, and
`CAST(? AS TIMESTAMP_LTZ)` keeps its instant.

Statements may use positional `?` or named `:name` placeholders, one style per statement:

```dart
await conn.executeNamed('SELECT :a + :b AS total', {'a': 2, 'b': 40});
```

Names match case-insensitively and their order does not matter. A `::` cast, a `:=` assignment
and a `:1` positional reference are never parameters — and neither is Snowflake's VARIANT path
access: a colon glued to the end of an expression (`v:field`, `PARSE_JSON('…'):k`, `"V":k`,
and `?:k`, a path off a bound value) reads a field, so a bind marker has to follow a space, an
operator, a comma or a keyword boundary — `v :name` is a marker. With **no arguments at all**,
colon references pass through to the server untouched, because that is what Snowflake Scripting
variables look like (`EXECUTE IMMEDIATE :v`, `IFF(:flag, …)`).

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
- **`SessionLostException`** — the engine no longer held the connection's session, and the
  statement did **not** run, nor was it re-run: the lost session held an open transaction or
  context of the caller's own. The connection stays usable; see
  [Session lifetime](#session-lifetime).
- **`UsageException`** — the driver never sent it: a malformed DSN, a closed connection, a bind
  value with no SQL equivalent, an argument count that does not match the placeholders.

`SessionLostException` is newer than the others, so an exhaustive `switch` over
`FrostlakeException` needs a case for it.

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

### Session lifetime

The engine can lose a session: it expires one after 30 idle minutes, a `DELETE
/api/sessions/{id}` releases one, and a restart ends them all. Against an engine from 0.1.0 on —
one whose answers carry `newSession` — the driver keeps its session in step:

- **What is sent.** Every request that names the session also sends `requireSession: true`, so an
  engine that no longer holds the session refuses the request with HTTP 404 and runs nothing,
  rather than quietly starting a fresh session at its default scope. The first answer that names
  a session says whether the engine understands the flag: `newSession` present means it does.
  An engine before 0.1.0 is never sent the flag.
- **After a lost session.** The driver drops the session and decides from what the lost one held.
  - Nothing of the caller's own: the DSN's scope (`USE ROLE`, `WAREHOUSE`, `DATABASE`, `SCHEMA`)
    goes onto a fresh session and the statement is sent **once** more. A second refusal raises
    `SessionLostException`.
  - An open transaction (from `begin` or a `BEGIN` / `START TRANSACTION` statement, until
    `COMMIT` or `ROLLBACK`): `SessionLostException`, saying the transaction is gone and the
    statement did not run.
  - Context the caller set up — a `USE`, `SET` / `UNSET`, `ALTER SESSION`, a temporary object, or
    a `CREATE` / `DROP` of a database or schema: `SessionLostException`, saying the context went
    with the session and the statement was not re-run. `applyDsnScope` puts the connection back
    on the DSN's scope, and after it a lost session is replaced again.

  Either way the connection stays usable: the next statement starts a fresh session on the DSN's
  scope, in autocommit.
- **What `close` does.** It sends `DELETE /api/sessions/{id}`, which releases the session and
  rolls back a transaction left open on it. The release is best effort: it waits five seconds at
  most (less when `timeout` is shorter), and a release the engine refuses or never answers is not
  an error. Closing again sends nothing.

Against an engine before 0.1.0 nothing of this applies: it cannot say that a session was lost, so
the driver re-applies the DSN's scope after `idleLimit` of idleness instead (see *Known
limitations*), and `close` sends nothing, leaving the session to the engine's own idle expiry.

## Known limitations

- **Against an engine before 0.1.0, a session idle past its expiry silently resumes at the
  server's default scope**, because such an engine re-creates an expired session under the very
  same id — nothing in the answer tells a client its session was reclaimed. The driver covers
  this by re-applying the DSN's scope to a connection that has been idle longer than
  `idleLimit`, but anything else the session held (a session variable, an `ALTER SESSION`
  setting) is gone. It stops doing so once the caller has issued their own `USE`, since the DSN
  no longer describes where they are. Such an engine has no endpoint for releasing a session
  either, so a closed connection's session lingers until the engine's 30-minute idle sweep.
- **Timestamps carry milliseconds in transit.** The engine holds full nanoseconds, but the HTTP
  layer serialises milliseconds, so a temporal cell arrives millisecond-precise however fine the
  stored value. `TO_VARCHAR(ts, 'YYYY-MM-DD HH24:MI:SS.FF9')` is the way to read the rest.
- **Failures carry no error code.** The protocol reports a message only — no code, no SQLSTATE —
  so `QueryException` has none to offer.
- **Engines before 0.1.0 refuse a blank statement at the endpoint**, with HTTP 400 and `SQL is
  required`, before the engine sees it, so their own `Empty SQL statement.` wording never reaches
  a client over this transport. From 0.1.0 a blank statement runs and fails with that wording.
- **`dart:io` only.** The transport is `HttpClient`, so the package runs on the Dart VM and in
  Flutter's mobile and desktop targets, not on the web.

## Tests

The unit tests need nothing installed — no engine, no JVM:

```bash
dart test test/json_test.dart test/dsn_test.dart test/binding_test.dart test/values_test.dart
```

`test/session_test.dart` plays its session-lifetime scenarios — a lost session, a refused
re-run, the release on close — against a scripted stand-in engine that needs nothing installed
either; its engine-backed half skips itself like the integration tests below.

The integration tests additionally boot a real server from an engine classpath, and skip
themselves when `FROSTLAKE_CLASSPATH` is unset, so an unconfigured run is never falsely green:

```bash
JAVA_HOME=/path/to/jdk17 FROSTLAKE_CLASSPATH="<engine classes>;<dependency classpath>" dart test
```

Those drive a real engine over the driver's own HTTP path — DDL and DML, every type that can be
bound and read back, transactions, session scope, and the transport failures — so nothing in
them is mocked. Against engine 0.0.7 all 143 tests pass.

`test/suites_test.dart` replays the engine's language-neutral test corpus — the `suites/*.json`
of the testkit directory `FL_CORPUS` names — through the driver, against an engine booted from the
same classpath:

```bash
FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit dart test
```

Without `FL_CORPUS` it is a single skipped test, and a directory with no suites fails it. Give an
absolute path — a relative one resolves against the package root, where `dart test` runs.

## License

Apache-2.0 — see [LICENSE](LICENSE).
