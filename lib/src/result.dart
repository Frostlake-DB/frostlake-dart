import 'dart:collection';

/// What the engine reported about one column of a result set.
class ColumnInfo {
  const ColumnInfo({
    required this.name,
    required this.dataType,
    this.nullable,
    this.precision,
    this.scale,
  });

  /// The column's name, as the engine cased it.
  final String name;

  /// The declared SQL type, e.g. `NUMBER`, `VARCHAR`, `TIMESTAMP_NTZ`.
  final String dataType;

  /// Whether the column admits NULL, or `null` when the server did not say —
  /// engines that predate the field report nothing rather than `false`.
  final bool? nullable;

  /// Decimal precision, for the fixed-point numeric types.
  final int? precision;

  /// Decimal scale, for the fixed-point numeric types.
  final int? scale;

  @override
  String toString() => '$name $dataType';
}

/// One result set: what a single statement answered with.
class Result {
  Result({
    required this.columns,
    required this.values,
    required this.updateCount,
    this.counters = const {},
  });

  /// The columns of the grid, in order.
  ///
  /// A DML statement answers with a status grid rather than data — one row of
  /// `number of rows inserted`-style counters — and that grid is reported here
  /// as it arrived. [updateCount] is the friendly reading of it.
  final List<ColumnInfo> columns;

  /// Every cell, positionally aligned with [columns] — the shape the wire
  /// actually delivered, and the lossless one: a self-join reports `ID` twice
  /// and a map cannot hold both.
  final List<List<Object?>> values;

  /// Rows affected by a DML statement, or `-1` when the statement returned data
  /// instead.
  ///
  /// The protocol carries no out-of-band count, so this is derived from the
  /// status grid Frostlake and Snowflake both answer DML with
  /// (`number of rows inserted`, `number of rows updated`, ...).
  final int updateCount;

  /// The raw counters behind [updateCount], keyed by the engine's own wording.
  ///
  /// A `MERGE` reports an inserted and an updated count separately;
  /// [updateCount] adds them up, and this is where the split survives.
  final Map<String, int> counters;

  /// Rows returned, or rows affected for a DML statement.
  int get rowCount => updateCount >= 0 ? updateCount : values.length;

  /// Whether this result came from a DML statement rather than a query.
  bool get isUpdate => updateCount >= 0;

  List<Map<String, Object?>>? _rows;

  /// Each row keyed by column name, built on first use and kept.
  ///
  /// A map cannot represent two columns called the same thing — a self-join
  /// reports `ID` twice and the later one wins — so [values] is the lossless
  /// view. Building these lazily keeps a caller who only reads [values] from
  /// paying for them.
  List<Map<String, Object?>> get rows => _rows ??= UnmodifiableListView(
        values
            .map((cells) => UnmodifiableMapView(<String, Object?>{
                  for (var i = 0; i < columns.length; i++)
                    columns[i].name: i < cells.length ? cells[i] : null,
                }))
            .toList(growable: false),
      );

  /// The first cell of the first row, or `null` when there is none.
  ///
  /// What a single-value query — `SELECT COUNT(*)`, `SELECT CURRENT_VERSION()` —
  /// is actually after.
  Object? get value =>
      values.isEmpty || values.first.isEmpty ? null : values.first.first;

  @override
  String toString() => isUpdate
      ? 'Result(updateCount: $updateCount)'
      : 'Result(${columns.length} column(s), ${values.length} row(s))';
}
