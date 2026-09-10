import 'dart:typed_data';

import 'errors.dart';
import 'sql.dart';

const int _question = 0x3f;
const int _colon = 0x3a;
const int _equals = 0x3d;
const int _zero = 0x30;
const int _nine = 0x39;
const int _rparen = 0x29;
const int _rbracket = 0x5d;
const int _rbrace = 0x7d;
const int _doubleQuote = 0x22;
const int _apostrophe = 0x27;

/// One bind site in a statement: a positional `?` ([name] is `null`) or a
/// `:name`.
class Placeholder {
  const Placeholder(this.start, this.end, this.name);

  /// Index of the first character of the marker.
  final int start;

  /// Index just past the marker.
  final int end;

  /// The parameter's name, upper-cased, or `null` for a positional marker.
  final String? name;
}

/// Finds every bind site in a statement, skipping string literals, quoted
/// identifiers, dollar-quoted bodies and comments.
///
/// Counting and substitution both read this one scan, so they cannot disagree
/// about what is a placeholder.
List<Placeholder> scanPlaceholders(String sql) {
  final out = <Placeholder>[];
  var i = 0;
  while (i < sql.length) {
    final skip = skipEnclosure(sql, i);
    if (skip >= 0) {
      i = skip;
      continue;
    }
    final c = sql.codeUnitAt(i);
    if (c == _question) {
      out.add(Placeholder(i, i + 1, null));
      i++;
      continue;
    }
    if (c != _colon) {
      i++;
      continue;
    }
    // `::` is a cast and `:=` an assignment; neither introduces a parameter.
    if (i + 1 < sql.length) {
      final next = sql.codeUnitAt(i + 1);
      if (next == _colon || next == _equals) {
        i += 2;
        continue;
      }
    }
    // A colon ADJACENT to the end of an expression — an identifier character,
    // `)`, `]`, `}`, `"` or `'` — is Snowflake's VARIANT path access (`v:field`,
    // `PARSE_JSON('...'):k`, `{'a': 1}:a`, `"V":k`), not a parameter: a bind
    // marker follows an operator, comma or keyword boundary instead.
    if (i > 0) {
      final prev = sql.codeUnitAt(i - 1);
      if (isWordChar(prev) ||
          prev == _rparen ||
          prev == _rbracket ||
          prev == _rbrace ||
          prev == _doubleQuote ||
          prev == _apostrophe) {
        i++;
        continue;
      }
    }
    var j = i + 1;
    while (j < sql.length && isWordChar(sql.codeUnitAt(j))) {
      j++;
    }
    // A leading digit means a positional reference (`:1`), not a name.
    final first = j > i + 1 ? sql.codeUnitAt(i + 1) : -1;
    if (j > i + 1 && !(first >= _zero && first <= _nine)) {
      out.add(Placeholder(i, j, sql.substring(i + 1, j).toUpperCase()));
      i = j;
      continue;
    }
    i++;
  }
  return out;
}

/// How many arguments a statement expects.
///
/// Named placeholders count once each however often they appear. A statement
/// mixing the two styles reports `-1`, so a caller checking the count leaves the
/// real complaint to [substitutePositional]/[substituteNamed].
int placeholderCount(String sql) {
  var positional = 0;
  final names = <String>{};
  for (final p in scanPlaceholders(sql)) {
    if (p.name == null) {
      positional++;
    } else {
      names.add(p.name!);
    }
  }
  if (positional > 0 && names.isNotEmpty) return -1;
  return names.isNotEmpty ? names.length : positional;
}

/// The parameter names a statement carries, upper-cased, in order of first
/// appearance.
List<String> placeholderNames(String sql) {
  final out = <String>[];
  final seen = <String>{};
  for (final p in scanPlaceholders(sql)) {
    final name = p.name;
    if (name != null && seen.add(name)) out.add(name);
  }
  return out;
}

/// Inlines positional `?` placeholders with formatted literals.
///
/// This is the same client-side binding Frostlake's JDBC driver performs, since
/// the HTTP protocol has no server-side binding.
String substitutePositional(String sql, List<Object?> parameters) {
  final sites = scanPlaceholders(sql);
  final named = sites.where((p) => p.name != null).length;
  if (named > 0 && sites.length != named) {
    throw const UsageException(
        'a statement may use ? or :name placeholders, not both');
  }
  if (named > 0) {
    // With no arguments at all, the colon references are the SERVER's —
    // Snowflake Scripting variables (`EXECUTE IMMEDIATE :v`, `IFF(:flag, ...)`)
    // — and the statement passes through verbatim. Named client binds exist
    // only when named arguments are supplied.
    if (parameters.isEmpty) return sql;
    throw UsageException('the statement uses :name placeholders; '
        'pass a map of named parameters instead of a list');
  }
  // Symmetrically, with no arguments at all the ? marks are the SERVER's — a
  // Snowflake Scripting cursor placeholder bound by `OPEN c USING (...)` — and the
  // statement passes through verbatim. Positional client binds exist only when
  // arguments are supplied.
  if (parameters.isEmpty) return sql;
  if (sites.length != parameters.length) {
    throw UsageException('the statement has ${sites.length} placeholder(s), '
        'got ${parameters.length} argument(s)');
  }
  if (sites.isEmpty) return sql;
  return _render(sql, sites, (site, index) => formatLiteral(parameters[index]));
}

/// Inlines `:name` placeholders with formatted literals.
///
/// Names match case-insensitively, and order does not matter. An argument that
/// no placeholder mentions is an error rather than a silent no-op — it almost
/// always means the name was misspelled on one side or the other.
String substituteNamed(String sql, Map<String, Object?> parameters) {
  final sites = scanPlaceholders(sql);
  final positional = sites.where((p) => p.name == null).length;
  if (positional > 0 && sites.length != positional) {
    throw const UsageException(
        'a statement may use ? or :name placeholders, not both');
  }
  if (positional > 0) {
    throw UsageException('the statement uses positional ? placeholders; '
        'pass a list of parameters instead of a map');
  }
  final values = <String, Object?>{};
  for (final entry in parameters.entries) {
    values[entry.key.toUpperCase()] = entry.value;
  }
  if (sites.isEmpty) {
    if (values.isEmpty) return sql;
    throw UsageException('the statement has no placeholders, '
        'got ${values.length} named argument(s)');
  }
  final used = <String>{};
  final rendered = _render(sql, sites, (site, _) {
    final name = site.name!;
    if (!values.containsKey(name)) {
      throw UsageException('no argument bound for :${name.toLowerCase()}');
    }
    used.add(name);
    return formatLiteral(values[name]);
  });
  final unused = values.keys.where((name) => !used.contains(name)).toList()
    ..sort();
  if (unused.isNotEmpty) {
    throw UsageException('argument(s) '
        '${unused.map((n) => ':${n.toLowerCase()}').join(', ')} '
        'do not appear in the statement');
  }
  return rendered;
}

String _render(
  String sql,
  List<Placeholder> sites,
  String Function(Placeholder site, int index) literalFor,
) {
  final out = StringBuffer();
  var cursor = 0;
  for (var i = 0; i < sites.length; i++) {
    final site = sites[i];
    out
      ..write(sql.substring(cursor, site.start))
      ..write(literalFor(site, i));
    cursor = site.end;
  }
  out.write(sql.substring(cursor));
  return out.toString();
}

/// Renders [value] as the SQL literal that stands in for it.
///
/// | Dart value | SQL literal |
/// | --- | --- |
/// | `null` | `NULL` |
/// | `bool` | `TRUE` / `FALSE` |
/// | `int`, `BigInt` | the digits, exactly; a negative in parentheses |
/// | `double` | the shortest round-tripping form; NaN and the infinities cast from text |
/// | `String` | `'...'` with backslashes and quotes escaped |
/// | `Uint8List` | `X'hex'` |
/// | `DateTime` | `'...'::TIMESTAMP_TZ`, carrying its UTC offset |
/// | `Duration` | `'...'::TIME`, as a time of day |
/// | `List` | `[...]`, elements formatted recursively |
/// | `Map` | `{'key': ...}`, values formatted recursively |
String formatLiteral(Object? value) {
  switch (value) {
    case null:
      return 'NULL';
    case final bool b:
      return b ? 'TRUE' : 'FALSE';
    case final int n:
      return _numeral(n.toString());
    case final BigInt n:
      return _numeral(n.toString());
    case final double d:
      // Dart spells these NaN, Infinity and -Infinity, which the parser reads
      // as identifiers. Cast from text they are the engine's own spellings —
      // the shorter 'Inf' is refused.
      if (d.isNaN) return "'NaN'::FLOAT";
      if (d == double.infinity) return "'Infinity'::FLOAT";
      if (d == double.negativeInfinity) return "'-Infinity'::FLOAT";
      return _numeral(d.toString());
    case final String s:
      return encodeStringLiteral(s);
    // Uint8List is the deliberate marker for binary data. A plain List<int> is
    // an array of numbers — Snowflake has both, and guessing between them from
    // the element type would make `[1, 2, 3]` mean two different things.
    case final Uint8List bytes:
      return _formatBinary(bytes);
    case final ByteBuffer buffer:
      return _formatBinary(buffer.asUint8List());
    case final DateTime t:
      return "'${formatTimestamp(t)}'::TIMESTAMP_TZ";
    case final Duration d:
      return "'${formatTime(d)}'::TIME";
    case final List<Object?> list:
      return '[${list.map(formatLiteral).join(', ')}]';
    case final Map<Object?, Object?> map:
      final entries = map.entries.map((entry) {
        final key = entry.key;
        if (key is! String) {
          throw UsageException('an object key must be a String, '
              'got ${key.runtimeType}');
        }
        return '${encodeStringLiteral(key)}: ${formatLiteral(entry.value)}';
      });
      return '{${entries.join(', ')}}';
    default:
      throw UsageException('unsupported bind type ${value.runtimeType}');
  }
}

/// A negative numeral goes in parentheses: spliced straight after a minus it
/// would otherwise open a `--` comment, so `SELECT 3-?` bound -5 became
/// `SELECT 3--5`, which the engine reads as `SELECT 3`.
String _numeral(String digits) => digits.startsWith('-') ? '($digits)' : digits;

String _formatBinary(Uint8List bytes) {
  final hex = StringBuffer();
  for (final byte in bytes) {
    hex.write(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
  }
  return "X'$hex'";
}

/// Mirrors the engine's canonical literal encoder: backslashes doubled (a
/// backslash always escapes), quotes doubled.
String encodeStringLiteral(String text) {
  final escaped = text.replaceAll(r'\', r'\\').replaceAll("'", "''");
  return "'$escaped'";
}

/// Renders a [DateTime] as an offset-carrying timestamp literal.
///
/// A Dart `DateTime` is always an instant with a known offset — UTC, or the
/// host's zone — so it maps to `TIMESTAMP_TZ`. Casting to `TIMESTAMP_NTZ` here
/// would silently discard that offset, and two `DateTime`s naming the same
/// instant would then store as two different timestamps.
String formatTimestamp(DateTime value) {
  if (value.year < 1 || value.year > 9999) {
    // The engine's calendar stops there, and a year padded to four digits
    // would silently name a different one.
    throw UsageException(
        'a timestamp year must fall within 1..9999, got ${value.year}');
  }
  final offset = value.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final absolute = offset.abs();
  final offsetHours = _pad(absolute.inHours, 2);
  final offsetMinutes = _pad(absolute.inMinutes.remainder(60), 2);
  final fraction = _pad(value.millisecond * 1000 + value.microsecond, 6);
  return '${_pad(value.year, 4)}-${_pad(value.month, 2)}-${_pad(value.day, 2)}'
      'T${_pad(value.hour, 2)}:${_pad(value.minute, 2)}:${_pad(value.second, 2)}'
      '.$fraction$sign$offsetHours:$offsetMinutes';
}

/// Renders a [Duration] as a time-of-day literal.
///
/// `TIME` holds a point within one day, so a negative duration or one reaching
/// past 24 hours has nowhere to go and is refused rather than wrapped.
String formatTime(Duration value) {
  if (value.isNegative || value.inDays >= 1) {
    throw UsageException('a TIME must fall within one day, got $value');
  }
  final fraction = _pad(value.inMicroseconds.remainder(1000000), 6);
  return '${_pad(value.inHours, 2)}:${_pad(value.inMinutes.remainder(60), 2)}:'
      '${_pad(value.inSeconds.remainder(60), 2)}.$fraction';
}

String _pad(int value, int width) => value.toString().padLeft(width, '0');
