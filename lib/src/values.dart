import 'dart:typed_data';

import 'json.dart';
import 'result.dart';

/// How a column's text should be read back into a Dart temporal value.
enum TemporalKind {
  /// Not a temporal column.
  none,

  /// `DATE` — a calendar day.
  date,

  /// `TIME` — a point within one day.
  time,

  /// `TIMESTAMP_NTZ` and friends — a wall clock with no zone of its own.
  naive,

  /// `TIMESTAMP_LTZ` / `TIMESTAMP_TZ` — a wall clock plus an offset.
  zoned,
}

/// The engine's binary floating-point types. Every other numeric it reports is
/// fixed-point.
const Set<String> approximateTypes = {
  'FLOAT',
  'FLOAT4',
  'FLOAT8',
  'DOUBLE',
  'DOUBLE PRECISION',
  'REAL',
};

/// The whole-number types that carry no scale of their own.
const Set<String> integerTypes = {
  'INT',
  'INTEGER',
  'BIGINT',
  'SMALLINT',
  'TINYINT',
  'BYTEINT',
};

/// The fixed-point types, whose scale decides whether they hold whole numbers.
const Set<String> fixedPointTypes = {'NUMBER', 'NUMERIC', 'DECIMAL'};

/// Strips any `(p,s)` suffix, so `NUMBER(38,0)` and `NUMBER` answer alike.
String baseTypeName(String? dataType) {
  final name = (dataType ?? '').trim().toUpperCase();
  final open = name.indexOf('(');
  return open < 0 ? name : name.substring(0, open).trim();
}

/// Which temporal shape, if any, a declared type names.
TemporalKind temporalKindOf(String? dataType) =>
    switch (baseTypeName(dataType)) {
      'DATE' => TemporalKind.date,
      'TIME' => TemporalKind.time,
      'TIMESTAMP' || 'TIMESTAMP_NTZ' || 'DATETIME' => TemporalKind.naive,
      'TIMESTAMP_LTZ' || 'TIMESTAMP_TZ' => TemporalKind.zoned,
      _ => TemporalKind.none,
    };

bool isBinaryType(String? dataType) {
  final name = baseTypeName(dataType);
  return name == 'BINARY' || name == 'VARBINARY';
}

/// Whether a column holds whole numbers.
///
/// The wire carries precision and scale as their own fields — `dataType` is the
/// bare word `NUMBER` — so scale is what decides, with an inline `NUMBER(p,s)`
/// spelling honoured as a fallback.
bool isIntegralColumn(ColumnInfo column) {
  final name = baseTypeName(column.dataType);
  if (integerTypes.contains(name)) return true;
  if (fixedPointTypes.contains(name)) return declaredScale(column) == 0;
  return false;
}

/// The column's scale, preferring the wire's own field and falling back to an
/// inline `NUMBER(p,s)` spelling for servers that put both in the type name.
int declaredScale(ColumnInfo column) {
  final scale = column.scale;
  if (scale != null && scale != 0) return scale;
  final name = column.dataType;
  final open = name.indexOf('(');
  final comma = name.indexOf(',');
  final close = name.indexOf(')');
  if (open >= 0 && comma > open && close > comma) {
    final parsed = int.tryParse(name.substring(comma + 1, close).trim());
    if (parsed != null) return parsed;
  }
  return scale ?? 0;
}

/// Maps one decoded JSON cell to a Dart value, guided by the column's declared
/// type.
///
/// Temporals become [DateTime] (or [Duration] for `TIME`), `BINARY` a
/// [Uint8List], integral numerics an [int] — or a [BigInt] past 64 bits — and
/// everything approximate or fractional a [double]. `VARIANT`, `OBJECT` and
/// `ARRAY` arrive as the engine's own text rendering.
Object? convertCell(Object? raw, ColumnInfo column) {
  switch (raw) {
    case null:
      return null;
    // A VARIANT `undefined` standing alone is SQL NULL: the sentinel exists
    // inside an ARRAY and never leaks into scalar evaluation.
    case JsonUndefined _:
      return null;
    case final bool b:
      return b;
    case final String text:
      final kind = temporalKindOf(column.dataType);
      if (kind != TemporalKind.none) {
        return parseTemporal(text, kind) ?? text;
      }
      if (isBinaryType(column.dataType)) {
        return decodeHex(text) ?? text;
      }
      if (approximateTypes.contains(baseTypeName(column.dataType))) {
        return floatSpecial(text) ?? text;
      }
      return text;
    case final JsonNumber number:
      return _convertNumber(number, column);
    // The engine renders semi-structured values as text, so these only appear
    // if a server takes to sending them structurally. Handing back the JSON
    // text keeps the column reading the same either way.
    case final List<Object?> _ || final Map<String, Object?> _:
      return encodeJson(raw);
    default:
      return raw;
  }
}

Object? _convertNumber(JsonNumber number, ColumnInfo column) {
  final name = baseTypeName(column.dataType);
  if (approximateTypes.contains(name)) return number.asDouble;
  if (isIntegralColumn(column) || !_isNumericType(name)) {
    // Exact at any width. A NUMBER(38,0) holds values no int can name, and a
    // double would silently round them away — including one the engine spelled
    // `1E+3` or `12.000`, which is a whole number all the same.
    final whole = number.asWholeNumber;
    if (whole != null) return whole;
  }
  return number.asDouble;
}

/// The engine renders a non-finite double as the JSON *string* `NaN`,
/// `Infinity` or `-Infinity`, even on a FLOAT column; on such a column that text
/// reads back as the double it names. Anything else is `null`.
double? floatSpecial(String text) => switch (text.trim().toLowerCase()) {
      'nan' => double.nan,
      'inf' || '+inf' || 'infinity' || '+infinity' => double.infinity,
      '-inf' || '-infinity' => double.negativeInfinity,
      _ => null,
    };

bool _isNumericType(String name) =>
    integerTypes.contains(name) ||
    fixedPointTypes.contains(name) ||
    approximateTypes.contains(name);

/// Reads a temporal cell, or `null` when the text does not parse as one.
///
/// A `DATE` and a `TIMESTAMP_NTZ` are wall clocks with no zone of their own;
/// both come back flagged UTC so their fields read back exactly as stored,
/// rather than being shifted by whatever zone the host happens to be in.
Object? parseTemporal(String text, TemporalKind kind) {
  switch (kind) {
    case TemporalKind.none:
      return null;
    case TemporalKind.date:
      final match = _datePattern.firstMatch(text.trim());
      if (match == null) return null;
      return DateTime.utc(int.parse(match.group(1)!),
          int.parse(match.group(2)!), int.parse(match.group(3)!));
    case TemporalKind.time:
      return parseTime(text);
    case TemporalKind.naive:
      return _parseNaive(text);
    case TemporalKind.zoned:
      return _parseZoned(text) ?? _parseNaive(text);
  }
}

final RegExp _datePattern = RegExp(r'^(\d{4,})-(\d{2})-(\d{2})$');

final RegExp _timePattern = RegExp(r'^(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d+))?$');

final RegExp _timestampPattern = RegExp(
    r'^(\d{4,})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?$');

final RegExp _zonedPattern =
    RegExp(r'^(\d{4,}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s*'
        r'(Z|[+-]\d{2}:?\d{2})$');

/// Reads a `TIME` cell as a [Duration] since midnight.
///
/// Dart has no time-of-day type, and putting one on an arbitrary date would
/// invent a day that the value never had.
Duration? parseTime(String text) {
  final match = _timePattern.firstMatch(text.trim());
  if (match == null) return null;
  return Duration(
    hours: int.parse(match.group(1)!),
    minutes: int.parse(match.group(2)!),
    seconds: int.parse(match.group(3)!),
    microseconds: _fractionMicroseconds(match.group(4)),
  );
}

DateTime? _parseNaive(String text) {
  final match = _timestampPattern.firstMatch(text.trim());
  if (match == null) return null;
  return DateTime.utc(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
    0,
    _fractionMicroseconds(match.group(7)),
  );
}

/// Reads a zoned timestamp as the instant it names, in UTC.
///
/// A Dart [DateTime] is either UTC or the host's own zone, with nowhere to keep
/// a third offset, so the instant is what survives — the same choice
/// [DateTime.parse] makes for a string carrying an offset.
DateTime? _parseZoned(String text) {
  final match = _zonedPattern.firstMatch(text.trim());
  if (match == null) return null;
  final local = _parseNaive(match.group(1)!);
  if (local == null) return null;
  final zone = match.group(2)!;
  if (zone == 'Z') return local;
  final digits = zone.replaceAll(':', '');
  final offset = Duration(
    hours: int.parse(digits.substring(1, 3)),
    minutes: int.parse(digits.substring(3, 5)),
  );
  return digits.startsWith('-') ? local.add(offset) : local.subtract(offset);
}

/// Converts a fractional-seconds group to microseconds, rounding away anything
/// finer than a [DateTime] or [Duration] can hold.
int _fractionMicroseconds(String? digits) {
  if (digits == null || digits.isEmpty) return 0;
  final padded =
      digits.length >= 6 ? digits.substring(0, 6) : digits.padRight(6, '0');
  return int.parse(padded);
}

/// Decodes the hex text the engine renders `BINARY` as, or `null` when the text
/// is not hex after all.
///
/// Anything else is not the driver's to reinterpret: silently dropping a stray
/// character would turn a value the caller can still read into one they cannot.
Uint8List? decodeHex(String text) {
  if (text.isEmpty) return Uint8List(0);
  if (text.length.isOdd) return null;
  final out = Uint8List(text.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final high = _hexDigit(text.codeUnitAt(i * 2));
    final low = _hexDigit(text.codeUnitAt(i * 2 + 1));
    if (high < 0 || low < 0) return null;
    out[i] = high * 16 + low;
  }
  return out;
}

int _hexDigit(int c) => switch (c) {
      >= 0x30 && <= 0x39 => c - 0x30,
      >= 0x61 && <= 0x66 => c - 0x61 + 10,
      >= 0x41 && <= 0x46 => c - 0x41 + 10,
      _ => -1,
    };
