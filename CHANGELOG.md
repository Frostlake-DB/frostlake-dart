# Changelog

## Unreleased

- A colon glued to a `?` reads a path off the bound value. `SELECT ?:a` was refused as mixing
  `?` and `:name` placeholders, whatever arguments came with it; a `?` now ends an operand as a
  name, a closing bracket or a quote already did. Spaced off (`? :a`), the colon still opens a
  `:name` placeholder.
- A connection keeps its engine session in step with the engine's. Against an engine that
  reports `newSession` (0.1.0 and later), every request naming the session sends
  `requireSession: true`, so a session the engine lost (idle expiry, release, restart) is
  refused with HTTP 404 instead of quietly replaced at the server's default scope. The driver
  then puts the DSN's scope on a fresh session and sends the statement once more — or, when the
  lost session held an open transaction or context of the caller's own (`USE`, `SET`/`UNSET`,
  `ALTER SESSION`, a temporary object, `CREATE`/`DROP` of a database or schema), raises the new
  `SessionLostException` and leaves the connection usable. An exhaustive `switch` over
  `FrostlakeException` needs a case for it.
- `close` releases the session with `DELETE /api/sessions/{id}`, which also rolls back a
  transaction left open on it: best effort, at most five seconds, never an error. Engines before
  0.1.0 are sent neither the flag nor the `DELETE`, and keep the `idleLimit` re-scope, which the
  newer ones no longer need.

## 0.1.0

First release. A dependency-free Dart driver for Frostlake over the engine's HTTP protocol,
verified against engine 0.0.7.

- `connect` opens a connection and applies the DSN's role, warehouse, database and schema
  before the first statement, so a name that does not exist is reported at connect.
- `execute` / `executeAll` for positional `?` parameters, `executeNamed` / `executeAllNamed`
  for `:name`. Binding is client-side, skipping string literals, quoted identifiers,
  dollar-quoted bodies and comments, and refusing a count mismatch whenever arguments are
  supplied; with none at all the `?` marks pass through to the server, where a Snowflake
  Scripting cursor binds them.
- `Result` reports the grid positionally and keyed by column name, with column metadata,
  a DML `updateCount` and the raw counters behind it.
- Types map to Dart natives: `BigInt` for a `NUMBER` past 64 bits, `Uint8List` for `BINARY`,
  `Duration` for `TIME`, `DateTime` for the date and timestamp types.
- `begin` / `commit` / `rollback` and a `transaction` helper that rolls back on a throw.
- Failures are typed: `QueryException`, `ConnectionException`, `UsageException`, all under
  `FrostlakeException`.
- Statements on one connection are serialized, so a connection maps to one engine session
  however many callers await it at once.
- Unit tests that need no engine, and integration tests that boot a real `DatabaseHttpServer`
  and skip themselves when none is configured: no failures.
