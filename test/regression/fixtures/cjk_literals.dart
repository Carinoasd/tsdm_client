import 'dart:io';

/// Chinese and full-width characters: what a string literal written for Chinese readers holds.
final cjkRe = RegExp('[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff00-\uffef]');

/// A string literal of Dart source holding [cjkRe] text outside its interpolations.
///
/// `source` is the literal as written, quotes and interpolations included, with its line breaks and tabs escaped
/// (`\n`, `\t`) so that it fits on one line of the allowlist.
typedef CjkLiteral = ({String path, String source});

/// The entry of [literal] in the allowlist: its path and its source, separated by a tab.
String cjkLiteralEntry(CjkLiteral literal) => '${literal.path}\t${literal.source}';

/// The Dart files of [root] the scan reads: everything but generated files.
List<File> scannedDartFiles(Directory root) {
  final files =
      root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !RegExp(r'\.(g|mapper|freezed)\.dart$').hasMatch(f.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// The string literals of [text] (the content of [path]) holding [cjkRe] text, in order.
///
/// Comments (`//`, `///`, nested `/* */`) are skipped. Raw, triple-quoted and adjacent strings are read; the code of
/// an interpolation (`${…}`) is scanned in turn, so a literal inside it is a literal of its own.
List<CjkLiteral> cjkLiteralsOf(String path, String text) {
  final out = <CjkLiteral>[];
  var i = 0;

  bool at(int at, String s) => text.startsWith(s, at);

  /// Reads code from [start] until the `}` closing an interpolation (when [inInterpolation]) or the end of the text;
  /// returns the index after it.
  late int Function(int start, {required bool inInterpolation}) code;

  /// Reads the string literal starting at [start] (at its `r` or its quote); returns the index after it.
  int string(int start) {
    var p = start;
    final raw = text[p] == 'r' || text[p] == 'R';
    if (raw) p++;
    final q = text[p];
    final triple = at(p, q * 3);
    final close = triple ? q * 3 : q;
    p += close.length;
    final literal = StringBuffer();
    while (p < text.length) {
      if (at(p, close)) {
        p += close.length;
        break;
      }
      final c = text[p];
      if (!raw && c == r'\') {
        literal.write(text.substring(p, (p + 2).clamp(0, text.length)));
        p += 2;
        continue;
      }
      if (!raw && c == r'$' && p + 1 < text.length && text[p + 1] == '{') {
        p = code(p + 2, inInterpolation: true);
        continue;
      }
      if (!triple && c == '\n') {
        break;
      }
      literal.write(c);
      p++;
    }
    if (cjkRe.hasMatch(literal.toString())) {
      final source = text.substring(start, p).replaceAll(r'\', r'\\').replaceAll('\n', r'\n').replaceAll('\t', r'\t');
      out.add((path: path, source: source));
    }
    return p;
  }

  code = (start, {required inInterpolation}) {
    var p = start;
    var depth = 0;
    while (p < text.length) {
      final c = text[p];
      if (at(p, '//')) {
        final end = text.indexOf('\n', p);
        p = end < 0 ? text.length : end + 1;
        continue;
      }
      if (at(p, '/*')) {
        var nest = 1;
        p += 2;
        while (p < text.length && nest > 0) {
          if (at(p, '/*')) {
            nest++;
            p += 2;
          } else if (at(p, '*/')) {
            nest--;
            p += 2;
          } else {
            p++;
          }
        }
        continue;
      }
      final isRawStart =
          (c == 'r' || c == 'R') &&
          p + 1 < text.length &&
          (text[p + 1] == "'" || text[p + 1] == '"') &&
          (p == 0 || !RegExp(r'[A-Za-z0-9_$]').hasMatch(text[p - 1]));
      if (c == "'" || c == '"' || isRawStart) {
        p = string(p);
        continue;
      }
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        if (inInterpolation && depth == 0) {
          return p + 1;
        }
        depth--;
      }
      p++;
    }
    return p;
  };

  i = code(0, inInterpolation: false);
  assert(i >= text.length, 'scanned to the end');
  return out;
}

/// The literals of every scanned file under [root] (a path relative to the working directory, like `lib`), their
/// paths as listed from it with `/` separators.
List<CjkLiteral> cjkLiteralsUnder(Directory root) => [
  for (final f in scannedDartFiles(root)) ...cjkLiteralsOf(f.path.replaceAll(r'\', '/'), f.readAsStringSync()),
];
