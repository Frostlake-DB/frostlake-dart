# Changelog

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
