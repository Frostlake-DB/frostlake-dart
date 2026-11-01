/// Lexical helpers shared by parameter binding and session-scope tracking.
///
/// Both need to walk a statement while stepping over the places where SQL
/// syntax stops meaning what it says — string literals, quoted identifiers,
/// dollar-quoted bodies and comments — so both read the same scanner and cannot
/// disagree about what is inside one.
library;

const int _tab = 0x09;
const int _lf = 0x0a;
const int _cr = 0x0d;
const int _space = 0x20;
const int _dollar = 0x24;
const int _apostrophe = 0x27;
const int _star = 0x2a;
const int _minus = 0x2d;
const int _slash = 0x2f;
const int _zero = 0x30;
const int _nine = 0x39;
const int _semicolon = 0x3b;
const int _upperA = 0x41;
const int _upperZ = 0x5a;
const int _underscore = 0x5f;
const int _lowerA = 0x61;
const int _lowerZ = 0x7a;
const int _doubleQuote = 0x22;

/// Whether [c] can appear in an unquoted identifier.
bool isWordChar(int c) =>
    c == _underscore ||
    c == _dollar ||
    (c >= _lowerA && c <= _lowerZ) ||
    (c >= _upperA && c <= _upperZ) ||
    (c >= _zero && c <= _nine);

/// Whether an unquoted identifier can start with [c].
bool _isNameStart(int c) =>
    c == _underscore ||
    (c >= _lowerA && c <= _lowerZ) ||
    (c >= _upperA && c <= _upperZ);

bool _isSpace(int c) => c == _space || c == _tab || c == _lf || c == _cr;

/// The index just past the single-quoted literal starting at [i].
///
/// Both `''` and backslash escapes end up inside the literal — a backslash
/// always escapes in Frostlake's string dialect.
int skipString(String sql, int i) {
  var j = i + 1;
  while (j < sql.length) {
    final c = sql.codeUnitAt(j);
    if (c == 0x5c) {
      j += 2; // backslash always escapes
    } else if (c == _apostrophe) {
      if (j + 1 < sql.length && sql.codeUnitAt(j + 1) == _apostrophe) {
        j += 2;
      } else {
        return j + 1;
      }
    } else {
      j++;
    }
  }
  return j;
}

/// The index just past the double-quoted identifier starting at [i].
int skipQuoted(String sql, int i) {
  var j = i + 1;
  while (j < sql.length) {
    if (sql.codeUnitAt(j) == _doubleQuote) {
      if (j + 1 < sql.length && sql.codeUnitAt(j + 1) == _doubleQuote) {
        j += 2;
        continue;
      }
      return j + 1;
    }
    j++;
  }
  return j;
}

/// The index just past the unquoted identifier starting at [i], read as the
/// lexer reads one: `[A-Za-z_][A-Za-z0-9_$]*`.
///
/// A `$` is legal inside an unquoted identifier, so `A$$B` is one name rather
/// than a name and the start of a body.
int skipName(String sql, int i) {
  var j = i + 1;
  while (j < sql.length && isWordChar(sql.codeUnitAt(j))) {
    j++;
  }
  return j;
}

/// The index just past the `$$...$$` body starting at [i].
///
/// Function and procedure bodies are written this way, and their contents are
/// not SQL — a `?` inside one is part of the body, never a placeholder.
int skipDollarQuoted(String sql, int i) {
  final stop = sql.indexOf(r'$$', i + 2);
  return stop < 0 ? sql.length : stop + 2;
}

/// The index just past the line comment starting at [i] and the line end that
/// closes it.
///
/// The comment ends at a line feed or a carriage return, whichever comes
/// first, as the lexer's `('--' | '//') ~[\r\n]*` does: a lone carriage return
/// ends it too.
int skipLine(String sql, int i) {
  var j = i;
  while (j < sql.length) {
    final c = sql.codeUnitAt(j);
    if (c == _lf || c == _cr) return j + 1;
    j++;
  }
  return sql.length;
}

/// The index just past the block comment starting at [i].
int skipBlockComment(String sql, int i) {
  final stop = sql.indexOf('*/', i + 2);
  return stop < 0 ? sql.length : stop + 2;
}

/// Whether a comment, a quoted region or a name opens at [i], and where it
/// ends.
///
/// Returns the index just past it, or `-1` when [i] does not open one. Every
/// walk over a statement starts here, so none of them can forget a case.
int skipEnclosure(String sql, int i) {
  final c = sql.codeUnitAt(i);
  // A name is read whole, as the lexer reads one, so a `$` inside it — the
  // `$$` in `A$$B` — opens no dollar-quoted body.
  if (_isNameStart(c)) return skipName(sql, i);
  switch (c) {
    case _apostrophe:
      return skipString(sql, i);
    case _doubleQuote:
      return skipQuoted(sql, i);
    case _dollar:
      return i + 1 < sql.length && sql.codeUnitAt(i + 1) == _dollar
          ? skipDollarQuoted(sql, i)
          : -1;
    case _minus:
      if (i + 1 < sql.length && sql.codeUnitAt(i + 1) == _minus) {
        return skipLine(sql, i);
      }
      return -1;
    case _slash:
      if (i + 1 < sql.length) {
        final next = sql.codeUnitAt(i + 1);
        if (next == _slash) return skipLine(sql, i);
        if (next == _star) return skipBlockComment(sql, i);
      }
      return -1;
    default:
      return -1;
  }
}

/// Splits a request on its top-level semicolons, leaving alone any that sit
/// inside a string literal, a quoted identifier, a dollar-quoted body or a
/// comment.
///
/// A procedural block is split along with everything else, which only makes the
/// scope check below more willing to flag — the safe direction.
List<String> splitStatements(String sql) {
  final out = <String>[];
  var start = 0;
  var i = 0;
  while (i < sql.length) {
    final skip = skipEnclosure(sql, i);
    if (skip >= 0) {
      i = skip;
      continue;
    }
    if (sql.codeUnitAt(i) == _semicolon) {
      out.add(sql.substring(start, i));
      start = i + 1;
    }
    i++;
  }
  out.add(sql.substring(start));
  return out;
}

/// Whether a request can move the session off the scope the DSN established.
///
/// A request may hold more than one statement, and a `USE` riding behind a
/// leading `SELECT` moves the scope just as surely as one standing alone, so
/// every statement is examined rather than only the first.
bool changesSessionScope(String sql) =>
    splitStatements(sql).any(_statementChangesScope);

/// Decides for a single statement.
///
/// Only `USE`, the `SET` family, `ALTER SESSION`, and `CREATE`/`DROP` of a
/// `DATABASE` or `SCHEMA` move the session — `CREATE TABLE` and its kind leave
/// the scope exactly where it was, and counting those would mark the session
/// dirty for every DDL statement a caller runs.
bool _statementChangesScope(String statement) {
  final words = leadingWords(statement, 6);
  if (words.isEmpty) return false;
  switch (words.first) {
    case 'USE' || 'SET' || 'UNSET':
      return true;
    case 'ALTER':
      return _namesObject(words.skip(1), const ['SESSION']);
    case 'CREATE' || 'DROP':
      return _namesObject(words.skip(1), const ['DATABASE', 'SCHEMA']);
    default:
      return false;
  }
}

/// Modifiers that may sit between `CREATE`/`DROP`/`ALTER` and the kind of
/// object being named.
const List<String> _objectModifiers = [
  'OR', 'REPLACE', 'TRANSIENT', 'TEMPORARY', 'TEMP', 'VOLATILE', //
  'LOCAL', 'GLOBAL', 'SECURE', 'IF', 'NOT', 'EXISTS',
];

/// Walks the words between the verb and the object being named, stepping over
/// the modifiers that may sit between them — `CREATE OR REPLACE DATABASE`,
/// `DROP SCHEMA IF EXISTS` — and reports whether the object is one of [want].
bool _namesObject(Iterable<String> words, List<String> want) {
  for (final word in words) {
    if (_objectModifiers.contains(word)) continue;
    return want.contains(word);
  }
  return false;
}

/// Whether one statement leaves behind state a fresh session would not have: a
/// moved scope or a session setting (everything [changesSessionScope] spots),
/// or a temporary object.
///
/// A session holding such state cannot be quietly swapped for a new one when
/// the engine loses it: the statement would run somewhere its author did not
/// intend.
bool touchesSession(String statement) =>
    _statementChangesScope(statement) || _createsTemporary(statement);

/// The words that may sit between `CREATE` and the kind of object it makes.
const List<String> _createModifiers = [
  'OR', 'REPLACE', 'TRANSIENT', 'TEMPORARY', 'TEMP', 'VOLATILE', //
  'LOCAL', 'GLOBAL', 'SECURE', 'IF', 'NOT', 'EXISTS', 'PUBLIC', 'PRIVATE',
  'ICEBERG', 'DYNAMIC', 'HYBRID', 'EVENT', 'RECURSIVE', 'MATERIALIZED',
  'EXTERNAL',
];

const List<String> _temporary = ['TEMPORARY', 'TEMP', 'VOLATILE'];

/// `CREATE TEMPORARY TABLE`, `CREATE OR REPLACE TEMP STAGE` and the like: an
/// object that lives exactly as long as the session.
bool _createsTemporary(String statement) {
  final words = leadingWords(statement, 16);
  if (words.isEmpty || words.first != 'CREATE') return false;
  for (final word in words.skip(1)) {
    if (_temporary.contains(word)) return true;
    if (!_createModifiers.contains(word)) return false;
  }
  return false;
}

/// What a statement does to the session's transaction.
enum TransactionEffect {
  /// `BEGIN` on its own (or with `TRANSACTION`, `WORK` or `NAME`), or
  /// `START TRANSACTION`.
  begins,

  /// `COMMIT` or `ROLLBACK`.
  ends,

  /// Anything else.
  none,
}

/// Whether one statement opens or ends a transaction.
///
/// `BEGIN` followed by a statement opens a Snowflake Scripting block rather
/// than a transaction, so it has no effect of its own.
TransactionEffect transactionEffect(String statement) =>
    switch (leadingWords(statement, 2)) {
      ['BEGIN'] ||
      ['BEGIN', 'TRANSACTION' || 'WORK' || 'NAME'] ||
      ['START', 'TRANSACTION'] =>
        TransactionEffect.begins,
      ['COMMIT' || 'ROLLBACK', ...] => TransactionEffect.ends,
      _ => TransactionEffect.none,
    };

/// Up to [n] words from the start of a statement, upper-cased, skipping
/// whitespace and comments and stopping at the first thing that is not a word.
List<String> leadingWords(String statement, int n) {
  final out = <String>[];
  var i = 0;
  while (i < statement.length && out.length < n) {
    final c = statement.codeUnitAt(i);
    if (_isSpace(c)) {
      i++;
      continue;
    }
    // Only comments are stepped over here: a leading string literal or quoted
    // identifier means the statement does not start with a keyword at all.
    if (c == _minus || c == _slash) {
      final skip = skipEnclosure(statement, i);
      if (skip >= 0) {
        i = skip;
        continue;
      }
    }
    if (!isWordChar(c)) return out;
    final start = i;
    while (i < statement.length && isWordChar(statement.codeUnitAt(i))) {
      i++;
    }
    out.add(statement.substring(start, i).toUpperCase());
  }
  return out;
}
