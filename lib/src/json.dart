import 'errors.dart';

/// A JSON number kept as the exact text the engine sent.
///
/// `dart:convert` resolves every JSON number to an `int` or a `double` while
/// parsing, which is lossy in both of the directions that matter here: a
/// `NUMBER(38,0)` wider than 64 bits collapses to the nearest `double`, and a
/// fixed-point value's trailing digits go with it. Keeping the literal lets the
/// conversion layer decide what the column's declared type actually calls for —
/// a [BigInt], an [int] or a [double] — instead of the parser deciding first.
class JsonNumber {
  const JsonNumber(this.text);

  /// The literal exactly as it appeared on the wire.
  final String text;

  /// Whether the literal names a whole number: no fraction, no exponent.
  bool get isIntegral {
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x2e || c == 0x65 || c == 0x45) return false; // '.', 'e', 'E'
    }
    return true;
  }

  /// The value as an [int], or `null` when it is not whole or does not fit in
  /// 64 bits.
  int? get asInt => isIntegral ? int.tryParse(text) : null;

  /// The value as a [BigInt] — exact at any width — or `null` when the literal
  /// is not whole.
  BigInt? get asBigInt => isIntegral ? BigInt.tryParse(text) : null;

  /// The value as a [double], rounding where the literal is finer than a binary
  /// float can hold.
  double get asDouble => double.parse(text);

  /// The value as a whole number — an [int] when it fits, a [BigInt] otherwise
  /// — or `null` when it is genuinely fractional.
  ///
  /// Unlike [asInt], this also reads the spellings a BigDecimal-producing
  /// engine uses for whole values: `1E+3`, `1.2E+5`, `12.000`.
  Object? get asWholeNumber {
    if (isIntegral) return asInt ?? asBigInt;
    final match = _shape.firstMatch(text);
    if (match == null) return null;
    final negative = match.group(1) != null;
    final fraction = match.group(3) ?? '';
    final exponent = int.tryParse(match.group(4) ?? '0');
    if (exponent == null) return null;
    var digits = match.group(2)! + fraction;
    var scale = exponent - fraction.length;
    if (scale < 0) {
      // Whole only if every digit right of the point is a zero.
      final keep = digits.length + scale;
      final dropped = keep <= 0 ? digits : digits.substring(keep);
      if (dropped.codeUnits.any((c) => c != 0x30)) return null;
      digits = keep <= 0 ? '0' : digits.substring(0, keep);
      scale = 0;
    }
    // Wider than any NUMBER: not a value this reading is for.
    if (digits.length + scale > 80) return null;
    var value = BigInt.parse(digits);
    if (scale > 0) value *= BigInt.from(10).pow(scale);
    if (negative) value = -value;
    return value.isValidInt ? value.toInt() : value;
  }

  static final RegExp _shape =
      RegExp(r'^(-)?(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$');

  @override
  String toString() => text;

  @override
  bool operator ==(Object other) => other is JsonNumber && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// Snowflake's VARIANT `undefined` — the sentinel a SQL NULL becomes on its way
/// into an ARRAY.
///
/// The engine spells it as a bare `undefined` token, which JSON has no word
/// for, so a strict parser refuses the whole response over one array element.
/// Reading it as this sentinel and writing it back out as the same token is
/// what keeps `[1,undefined,2]` intact, which is the text every other Frostlake
/// driver surfaces for it.
class JsonUndefined {
  const JsonUndefined._();

  @override
  String toString() => 'undefined';
}

/// The single [JsonUndefined] instance; compare with `identical` or `==`.
const JsonUndefined jsonUndefined = JsonUndefined._();

/// Parses [source] as JSON, leaving numbers as [JsonNumber] rather than
/// resolving them to `int`/`double`.
///
/// Objects become `Map<String, Object?>`, arrays `List<Object?>`, strings
/// `String`, `true`/`false` `bool`, and `null` `null`. Malformed input raises a
/// [ConnectionException], because the only JSON this driver parses arrived over
/// the wire — a parse failure means the far side is not answering like a
/// Frostlake engine.
Object? decodeJson(String source) => _Parser(source).parseDocument();

/// How deeply nested a document may be before it is refused. Deep enough for
/// any result set, shallow enough that a hostile body cannot exhaust the stack.
const int _maxDepth = 512;

const int _tab = 0x09;
const int _lf = 0x0a;
const int _cr = 0x0d;
const int _space = 0x20;
const int _quote = 0x22;
const int _plus = 0x2b;
const int _comma = 0x2c;
const int _minus = 0x2d;
const int _dot = 0x2e;
const int _slash = 0x2f;
const int _zero = 0x30;
const int _nine = 0x39;
const int _colon = 0x3a;
const int _upperE = 0x45;
const int _lbracket = 0x5b;
const int _backslash = 0x5c;
const int _rbracket = 0x5d;
const int _lowerB = 0x62;
const int _lowerE = 0x65;
const int _lowerF = 0x66;
const int _lowerN = 0x6e;
const int _lowerR = 0x72;
const int _lowerT = 0x74;
const int _lowerU = 0x75;
const int _lbrace = 0x7b;
const int _rbrace = 0x7d;

class _Parser {
  _Parser(this.source);

  final String source;
  int pos = 0;

  Object? parseDocument() {
    final value = _parseValue(0);
    _skipWhitespace();
    if (pos != source.length) {
      _fail('unexpected trailing content');
    }
    return value;
  }

  Never _fail(String what) {
    // Quote a little of the neighbourhood: "unexpected character" on its own
    // does not say which body came back.
    final from = pos < 24 ? 0 : pos - 24;
    final to = pos + 24 < source.length ? pos + 24 : source.length;
    final near = source.substring(from, to);
    throw ConnectionException(
        'malformed JSON at offset $pos: $what (near $near)');
  }

  void _skipWhitespace() {
    while (pos < source.length) {
      final c = source.codeUnitAt(pos);
      if (c == _space || c == _tab || c == _lf || c == _cr) {
        pos++;
      } else {
        return;
      }
    }
  }

  Object? _parseValue(int depth) {
    if (depth > _maxDepth) _fail('nested more than $_maxDepth deep');
    _skipWhitespace();
    if (pos >= source.length) _fail('input ended early');
    final c = source.codeUnitAt(pos);
    switch (c) {
      case _lbrace:
        return _parseObject(depth);
      case _lbracket:
        return _parseArray(depth);
      case _quote:
        return _parseString();
      case _lowerT:
        _expect('true');
        return true;
      case _lowerF:
        _expect('false');
        return false;
      case _lowerN:
        _expect('null');
        return null;
      case _lowerU:
        // Not JSON, but what the engine writes for a VARIANT `undefined`.
        _expect('undefined');
        return jsonUndefined;
      default:
        if (c == _minus || (c >= _zero && c <= _nine)) return _parseNumber();
        _fail('unexpected character');
    }
  }

  void _expect(String word) {
    if (!source.startsWith(word, pos)) _fail('expected $word');
    pos += word.length;
  }

  Map<String, Object?> _parseObject(int depth) {
    pos++; // '{'
    final out = <String, Object?>{};
    _skipWhitespace();
    if (pos < source.length && source.codeUnitAt(pos) == _rbrace) {
      pos++;
      return out;
    }
    while (true) {
      _skipWhitespace();
      if (pos >= source.length || source.codeUnitAt(pos) != _quote) {
        _fail('expected a member name');
      }
      final key = _parseString();
      _skipWhitespace();
      if (pos >= source.length || source.codeUnitAt(pos) != _colon) {
        _fail('expected : after a member name');
      }
      pos++;
      out[key] = _parseValue(depth + 1);
      _skipWhitespace();
      if (pos >= source.length) _fail('input ended inside an object');
      final c = source.codeUnitAt(pos);
      if (c == _comma) {
        pos++;
        continue;
      }
      if (c == _rbrace) {
        pos++;
        return out;
      }
      _fail('expected , or } in an object');
    }
  }

  List<Object?> _parseArray(int depth) {
    pos++; // '['
    final out = <Object?>[];
    _skipWhitespace();
    if (pos < source.length && source.codeUnitAt(pos) == _rbracket) {
      pos++;
      return out;
    }
    while (true) {
      out.add(_parseValue(depth + 1));
      _skipWhitespace();
      if (pos >= source.length) _fail('input ended inside an array');
      final c = source.codeUnitAt(pos);
      if (c == _comma) {
        pos++;
        continue;
      }
      if (c == _rbracket) {
        pos++;
        return out;
      }
      _fail('expected , or ] in an array');
    }
  }

  String _parseString() {
    pos++; // opening quote
    final start = pos;
    // The common case is a string with nothing to unescape, which can be handed
    // back as one substring rather than assembled character by character. Only
    // a backslash forces the slower path.
    while (pos < source.length) {
      final c = source.codeUnitAt(pos);
      if (c == _quote) {
        final text = source.substring(start, pos);
        pos++;
        return text;
      }
      if (c == _backslash) return _parseStringEscaped(start);
      pos++;
    }
    _fail('input ended inside a string');
  }

  String _parseStringEscaped(int start) {
    final out = StringBuffer()..write(source.substring(start, pos));
    while (pos < source.length) {
      final c = source.codeUnitAt(pos);
      if (c == _quote) {
        pos++;
        return out.toString();
      }
      if (c != _backslash) {
        out.writeCharCode(c);
        pos++;
        continue;
      }
      pos++;
      if (pos >= source.length) _fail('input ended inside an escape');
      final esc = source.codeUnitAt(pos);
      pos++;
      switch (esc) {
        case _quote:
          out.writeCharCode(_quote);
        case _backslash:
          out.writeCharCode(_backslash);
        case _slash:
          out.writeCharCode(_slash);
        case _lowerB:
          out.writeCharCode(0x08);
        case _lowerF:
          out.writeCharCode(0x0c);
        case _lowerN:
          out.writeCharCode(_lf);
        case _lowerR:
          out.writeCharCode(_cr);
        case _lowerT:
          out.writeCharCode(_tab);
        case _lowerU:
          // A half of a surrogate pair is written straight through: Dart
          // strings are UTF-16, so the pair reassembles itself once its other
          // half arrives, and a lone one is what the wire actually said.
          out.writeCharCode(_parseHex4());
        default:
          pos--;
          _fail('unknown escape');
      }
    }
    _fail('input ended inside a string');
  }

  int _parseHex4() {
    if (pos + 4 > source.length) _fail('truncated unicode escape');
    var value = 0;
    for (var i = 0; i < 4; i++) {
      final c = source.codeUnitAt(pos + i);
      final digit = switch (c) {
        >= 0x30 && <= 0x39 => c - 0x30,
        >= 0x61 && <= 0x66 => c - 0x61 + 10,
        >= 0x41 && <= 0x46 => c - 0x41 + 10,
        _ => -1,
      };
      if (digit < 0) _fail('bad hex digit in a unicode escape');
      value = value * 16 + digit;
    }
    pos += 4;
    return value;
  }

  JsonNumber _parseNumber() {
    final start = pos;
    if (source.codeUnitAt(pos) == _minus) pos++;
    // JSON's integer part is `0` or a digit string that does not lead with one.
    // Accepting `01` would mean a body that is not JSON at all still parsed,
    // and the point of parsing strictly is to notice when the far side is not
    // an engine.
    if (pos < source.length && source.codeUnitAt(pos) == _zero) {
      pos++;
    } else {
      _skipDigits();
    }
    if (pos < source.length && source.codeUnitAt(pos) == _dot) {
      pos++;
      _skipDigits();
    }
    if (pos < source.length) {
      final c = source.codeUnitAt(pos);
      if (c == _lowerE || c == _upperE) {
        pos++;
        if (pos < source.length) {
          final sign = source.codeUnitAt(pos);
          if (sign == _plus || sign == _minus) pos++;
        }
        _skipDigits();
      }
    }
    return JsonNumber(source.substring(start, pos));
  }

  void _skipDigits() {
    final start = pos;
    while (pos < source.length) {
      final c = source.codeUnitAt(pos);
      if (c < _zero || c > _nine) break;
      pos++;
    }
    if (pos == start) _fail('expected a digit');
  }
}

/// Renders [value] as JSON text.
///
/// Only what a request body holds needs encoding — strings, numbers, booleans,
/// null and maps of those — so this stays small rather than reaching for
/// `dart:convert` to do the same job.
String encodeJson(Object? value) {
  final out = StringBuffer();
  _writeJson(out, value);
  return out.toString();
}

void _writeJson(StringBuffer out, Object? value) {
  switch (value) {
    case null:
      out.write('null');
    case final bool b:
      out.write(b ? 'true' : 'false');
    case final int n:
      out.write(n.toString());
    case final BigInt n:
      out.write(n.toString());
    // A number that came off the wire is written back exactly as it arrived,
    // which is the whole point of having kept its literal.
    case final JsonNumber n:
      out.write(n.text);
    // Written back as the bare token it arrived as, so the array's text reads
    // the way the engine spells it.
    case JsonUndefined _:
      out.write('undefined');
    case final double d:
      // JSON has no way to spell these, and a body carrying one would be
      // refused by the far side rather than misread.
      if (d.isNaN || d.isInfinite) {
        throw UsageException('$d cannot be written as JSON');
      }
      out.write(d.toString());
    case final String s:
      _writeJsonString(out, s);
    case final List<Object?> list:
      out.write('[');
      for (var i = 0; i < list.length; i++) {
        if (i > 0) out.write(',');
        _writeJson(out, list[i]);
      }
      out.write(']');
    case final Map<String, Object?> map:
      out.write('{');
      var first = true;
      for (final entry in map.entries) {
        if (!first) out.write(',');
        first = false;
        _writeJsonString(out, entry.key);
        out.write(':');
        _writeJson(out, entry.value);
      }
      out.write('}');
    default:
      throw UsageException('${value.runtimeType} cannot be written as JSON');
  }
}

void _writeJsonString(StringBuffer out, String text) {
  out.writeCharCode(_quote);
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    switch (c) {
      case _quote:
        out.write(r'\"');
      case _backslash:
        out.write(r'\\');
      case _lf:
        out.write(r'\n');
      case _cr:
        out.write(r'\r');
      case _tab:
        out.write(r'\t');
      case 0x08:
        out.write(r'\b');
      case 0x0c:
        out.write(r'\f');
      default:
        if (c < 0x20 || (_isSurrogate(c) && !_isPairedSurrogate(text, i))) {
          // A lone surrogate has no UTF-8 form — utf8.encode would replace it
          // with U+FFFD on the way out — so it travels as an escape instead.
          out.write(r'\u');
          out.write(c.toRadixString(16).padLeft(4, '0'));
        } else {
          out.writeCharCode(c);
        }
    }
  }
  out.writeCharCode(_quote);
}

bool _isSurrogate(int c) => c >= 0xd800 && c <= 0xdfff;

/// Whether the surrogate at [i] has its other half beside it.
bool _isPairedSurrogate(String text, int i) {
  final c = text.codeUnitAt(i);
  if (c <= 0xdbff) {
    return i + 1 < text.length &&
        text.codeUnitAt(i + 1) >= 0xdc00 &&
        text.codeUnitAt(i + 1) <= 0xdfff;
  }
  return i > 0 &&
      text.codeUnitAt(i - 1) >= 0xd800 &&
      text.codeUnitAt(i - 1) <= 0xdbff;
}
