// A tour of the driver against a running DatabaseHttpServer.
//
//   dart run example/frostlake_example.dart [dsn]
//
// Start an engine first, e.g.
//   java -cp "<engine classpath>" dev.frostlake.http.DatabaseHttpServer 18082

import 'dart:typed_data';

import 'package:frostlake/frostlake.dart';

Future<void> main(List<String> arguments) async {
  final dsn =
      arguments.isEmpty ? 'frostlake://localhost:18082' : arguments.first;

  final Connection conn;
  try {
    conn = await connect(dsn);
  } on ConnectionException catch (e) {
    print('no engine at $dsn: ${e.message}');
    return;
  }

  try {
    print('engine ${(await conn.execute('SELECT CURRENT_VERSION()')).value}');

    await conn.execute('CREATE OR REPLACE DATABASE demo');
    await conn.execute('USE DATABASE demo');
    await conn.execute('CREATE OR REPLACE SCHEMA main');
    await conn.execute('USE SCHEMA main');

    await conn.execute('''
      CREATE TABLE people (
        id      NUMBER(38,0),
        name    VARCHAR,
        hired   DATE,
        salary  NUMBER(10,2),
        badge   BINARY
      )''');

    // Parameters are inlined client-side; a value can never become syntax.
    final inserted = await conn.execute(
      'INSERT INTO people VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)',
      [
        1,
        "O'Brien",
        DateTime.utc(2021, 3, 1),
        4250.50,
        Uint8List.fromList([0xde, 0xad]),
        2,
        'Grace',
        DateTime.utc(2019, 11, 12),
        5100.00,
        Uint8List.fromList([0xbe, 0xef]),
      ],
    );
    print('inserted ${inserted.updateCount} row(s)');

    // Named parameters bind in any order, case-insensitively.
    final rows = await conn.executeNamed(
        'SELECT id, name, hired, salary, badge FROM people '
        'WHERE salary > :floor ORDER BY id',
        {'floor': 4000});

    for (final row in rows.rows) {
      print('  ${row['ID']}  ${row['NAME']}  hired ${row['HIRED']}  '
          'salary ${row['SALARY']}  badge ${row['BADGE']}');
    }

    // Column metadata comes back with the grid.
    for (final column in rows.columns) {
      print('  column ${column.name}: ${column.dataType}'
          '${column.scale != null && column.scale != 0 ? ' scale ${column.scale}' : ''}');
    }

    // A NUMBER(38,0) wider than 64 bits stays exact.
    final wide = await conn
        .execute('SELECT 99999999999999999999999999999999999999::NUMBER(38,0)');
    print('wide ${wide.value} (${wide.value.runtimeType})');

    // The helper commits on success and rolls back on a throw.
    await conn.transaction((c) async {
      await c.execute('DELETE FROM people WHERE id = ?', [2]);
      print('inside the transaction: '
          '${(await c.execute('SELECT COUNT(*) FROM people')).value} row(s)');
    });
    print('after commit: '
        '${(await conn.execute('SELECT COUNT(*) FROM people')).value} row(s)');

    // A refused statement carries the engine's own wording.
    try {
      await conn.execute('SELECT * FROM no_such_table');
    } on QueryException catch (e) {
      print('engine refused: ${e.message.replaceAll('\n', ' ')}');
    }

    await conn.execute('DROP DATABASE demo');
  } finally {
    await conn.close();
  }
}
