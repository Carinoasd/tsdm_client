/// Where a long paragraph of a post is cut into shorter ones on a narrow screen: after the end of a sentence, never
/// inside quotes or brackets.
///
/// Many posts are written with few line breaks: on the web page a paragraph of a few hundred characters is a block of
/// six or seven lines, on a phone it is twenty lines and more of dense text. Cutting it after the end of a sentence
/// every few lines only changes how the text is laid out, not the text: what is copied stays as it was written.
///
/// Pure Dart (no Flutter), so the rules can be run over a corpus of posts outside the app.
library;

/// A paragraph wider than this many lines (of [textWidth] units, about one Chinese character each, a line holding as
/// many as it does on the screen) is cut: five lines.
const longParagraphLines = 5;

/// A piece cut off a long paragraph is at least this many lines.
const minPieceLines = 2;

/// What is left after a cut is at least this many lines: a cut never leaves a line or so hanging on its own.
const minTailLines = 1.25;

/// A line of a phone 390 wide at a text scale of 1: about 24.7 characters (346 / 14).
const double phoneLineWidth = 346 / 14;

/// The placeholder of a widget (an image, a smiley) in the text of a paragraph.
const objectReplacementChar = '￼';

/// End of a sentence: Chinese and Japanese full stops, exclamation and question marks, full width and half width.
const _sentenceEnds = {'。', '｡', '．', '！', '？', '‼', '⁇', '⁈', '⁉', '!', '?'};

/// Ellipses: `…`, `⋯` (`……`, `⋯⋯` in Chinese).
const _ellipses = {'…', '⋯'};

/// Quotes and brackets: a sentence end inside them (dialogue, an aside) is not the end of the paragraph's sentence.
const _pairs = {
  '「': '」',
  '『': '』',
  '“': '”',
  '‘': '’',
  '（': '）',
  '(': ')',
  '【': '】',
  '《': '》',
  '〈': '〉',
  '［': '］',
  '﹁': '﹂',
  '﹃': '﹄',
};

/// Closing quotes and brackets, which go with the end of the sentence before them (`「好。」`): the cut goes after them.
final Set<String> _closers = {..._pairs.values, '"'};

/// Closers of a title or a bracket: the end mark before them is part of the title or the aside (`《LoveLive!》`,
/// `（笑。）`), the sentence goes on after it.
const _titleClosers = {'》', '〉', '】', '］', '）', ')'};

/// Marks that do not start a line: a cut never leaves one at the start of the next piece.
const _noLineStart = {'，', '、', '；', '：', ',', ';', ':', '.', '～', '~', '—', '-', '·', '…', '⋯'};

/// English abbreviations ending with a full stop, which do not end a sentence (lower case, without their points).
const _abbreviations = {
  'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'vs', 'etc', 'inc', 'ltd', 'co', 'no', 'vol', 'pp', 'fig', //
  'ver', 'approx', 'dept', 'est', 'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', //
  'dec', 'ch', 'ep', 'op', 'eg', 'ie', 'us', 'uk', 'am', 'pm',
};

bool _isWideUnit(int c) =>
    // CJK punctuation, kana, ideographs, Hangul, full width forms.
    (c >= 0x2E80 && c <= 0xA4CF) ||
    (c >= 0xAC00 && c <= 0xD7AF) ||
    (c >= 0xF900 && c <= 0xFAFF) ||
    (c >= 0xFE30 && c <= 0xFE4F) ||
    (c >= 0xFF00 && c <= 0xFF60) ||
    (c >= 0xFFE0 && c <= 0xFFE6) ||
    (c >= 0x2018 && c <= 0x201D) ||
    c == 0x2026 ||
    c == 0x22EF ||
    c == 0x2014;

bool _isWide(String c) => _isWideUnit(c.codeUnitAt(0));

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '　' || c == ' ';

bool _isAsciiLetter(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
}

bool _isAsciiLetterOrDigit(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
}

/// A Chinese character, kana or Hangul (not a full width Latin letter or mark).
bool _isIdeograph(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x3040 && u <= 0x30FF) ||
      (u >= 0x3400 && u <= 0x9FFF) ||
      (u >= 0xF900 && u <= 0xFAFF) ||
      (u >= 0xAC00 && u <= 0xD7AF);
}

bool _isUpperAscii(String c) {
  final u = c.codeUnitAt(0);
  return u >= 0x41 && u <= 0x5A;
}

bool _isEndMark(String c) => _sentenceEnds.contains(c) || _ellipses.contains(c) || c == '.';

/// Narrow ASCII characters (about 0.27 of a Chinese character in the common Chinese fonts).
const _narrow = " !',.:;`|ijlI";

/// ASCII characters about 0.4 of a Chinese character.
const _slim = r'"()[]{}-/\_*?frtJs';

/// ASCII characters about as wide as a Chinese character.
const _broad = 'MWm@%&';

/// Digits: 0.6 of a Chinese character.
const _digits = '0123456789';

/// ASCII characters about 0.65 of a Chinese character (capitals, symbols); the other ones (small letters, Latin
/// letters beyond ASCII) are 0.55.
const _capital = r'ABCDEFGHJKLNOPQRSTUVXYZw#$+<=>^~';

/// How wide one UTF-16 code unit [c] is, in Chinese characters: a wide character (Chinese, Japanese, Korean, full
/// width) or a widget (a smiley) is 1, ASCII by its shape (measured in Microsoft YaHei; a space is 0.27, `m` is 0.95),
/// anything else 0.55 (a surrogate pair is two halves).
double _unitWidth(String c) {
  if (c == objectReplacementChar || _isWide(c)) {
    return 1;
  }
  if (_narrow.contains(c)) {
    return 0.27;
  }
  if (_digits.contains(c)) {
    return 0.6;
  }
  if (_slim.contains(c)) {
    return 0.4;
  }
  if (_broad.contains(c)) {
    return 0.95;
  }
  if (_capital.contains(c)) {
    return 0.65;
  }
  return 0.55;
}

/// How wide [text] is, roughly in Chinese characters: a wide character or a widget is 1, other characters by their
/// shape ([_unitWidth]). Line breaks do not count.
double textWidth(String text) {
  var width = 0.0;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c != '\n' && c != '\r') {
      width += _unitWidth(c);
    }
  }
  return width;
}

/// The quotes and brackets open at a point of a paragraph.
final class _Quotes {
  /// The closer each open quote or bracket waits for, innermost last.
  final _open = <String>[];

  /// An ASCII double quote is open: they open and close alike.
  bool _asciiOpen = false;

  bool get inside => _open.isNotEmpty || _asciiOpen;

  /// Whether the closer [c] right after the end of a sentence goes with it: an ASCII double quote only when one is
  /// open (`He said "Go." Then` / `Done. "Next`), any other closer always (even one whose opener is in an earlier
  /// paragraph).
  bool takesCloser(String c) => c != '"' || _asciiOpen;

  void take(String c) {
    final closer = _pairs[c];
    if (closer != null) {
      _open.add(closer);
    } else if (c == '"') {
      _asciiOpen = !_asciiOpen;
    } else if (_open.isNotEmpty && _open.last == c) {
      _open.removeLast();
    } else if (_open.contains(c)) {
      // The opener of an inner pair was never closed: it ends with the outer pair.
      _open.removeRange(_open.lastIndexOf(c), _open.length);
    }
    // A stray closer (its opener in an earlier paragraph, or `’` as an apostrophe) closes nothing.
  }
}

/// Offsets in [paragraph] (one paragraph, no line breaks in it) where a cut goes when it is wide enough to be cut
/// ([longParagraphLines] of [lineWidth] characters): each one the offset of the first character of the next piece.
///
/// A cut goes after the end of a sentence (`。！？`, `!?` before white space or a wide character, an ellipsis that
/// ends the sentence, a `.` before white space and a capital letter), after the closing quotes or brackets that go
/// with it and the white space after them. Never cut:
///
/// * inside quotes and brackets (`「」『』“”‘’（）()《》【】`, `"…"`): dialogue and asides stay whole; nor after a
///   title ending with a mark (`《LoveLive!》`);
/// * between the marks of a run (`！？`, `...`, `……`, `。。。`), or after an ellipsis the sentence goes on after
///   (`他……走了`);
/// * after the point of a number (`3.5`, `v1.0`), in a URL or a file name (`a.php?x=1`), after an abbreviation
///   (`Mr.`, `e.g.`) or an initial (`J. K.`);
/// * before two spaces or more, which separate the items of a list written on one line;
/// * where the piece before would be shorter than [minPieceLines] or the rest shorter than [minTailLines], or the
///   next piece would start with a mark that does not start a line.
List<int> sentenceBreaks(String paragraph, {double lineWidth = phoneLineWidth}) {
  final minPieceWidth = minPieceLines * lineWidth;
  final minTailWidth = minTailLines * lineWidth;
  final n = paragraph.length;
  final widths = List<double>.filled(n + 1, 0);
  for (var i = 0; i < n; i++) {
    widths[i + 1] = widths[i] + _unitWidth(paragraph[i]);
  }
  final total = widths[n];
  if (total <= longParagraphLines * lineWidth) {
    return const [];
  }
  var wide = 0;
  for (var i = 0; i < n; i++) {
    if (_isWide(paragraph[i])) {
      wide++;
    }
  }
  // Mostly Chinese or Japanese: more than half of its width.
  final wideText = wide > total / 2;
  final quotes = _Quotes();
  final cuts = <int>[];
  var pieceStart = 0;
  var i = 0;
  while (i < n) {
    final end = _sentenceEndAt(paragraph, i, wideText: wideText);
    if (end == null) {
      quotes.take(paragraph[i]);
      i++;
      continue;
    }
    var k = end;
    var inTitle = false;
    while (k < n && _closers.contains(paragraph[k]) && quotes.takesCloser(paragraph[k])) {
      inTitle = inTitle || _titleClosers.contains(paragraph[k]);
      quotes.take(paragraph[k]);
      k++;
    }
    // White space after it hangs at the end of the line before the cut. Two half width spaces or more separate the
    // items of a list written on one line (`FREE！   弹丸论破   …`), not sentences.
    final spaceStart = k;
    while (k < n && _isSpace(paragraph[k])) {
      k++;
    }
    final separator = paragraph.substring(spaceStart, k).replaceAll('\u3000', '').length >= 2;
    if (!quotes.inside &&
        !separator &&
        !inTitle &&
        k < n &&
        !_noLineStart.contains(paragraph[k]) &&
        !_isEndMark(paragraph[k]) &&
        widths[k] - widths[pieceStart] >= minPieceWidth &&
        total - widths[k] >= minTailWidth) {
      cuts.add(k);
      pieceStart = k;
    }
    i = k;
  }
  return cuts;
}

/// When a sentence ends at [i] (the first of its end marks): the offset right after its last end mark; null when [i]
/// does not end a sentence. [wideText]: the paragraph is mostly Chinese or Japanese.
int? _sentenceEndAt(String text, int i, {required bool wideText}) {
  final n = text.length;
  final c = text[i];
  if (!_isEndMark(c)) {
    return null;
  }
  // Only the first of a run of marks is looked at.
  if (i > 0 && _isEndMark(text[i - 1])) {
    return null;
  }
  var j = i;
  while (j < n && _isEndMark(text[j])) {
    j++;
  }
  final run = text.substring(i, j);
  final atEnd = j >= n;
  final next = atEnd ? '' : text[j];
  final prev = i > 0 ? text[i - 1] : '';

  // An ellipsis (`…`, `……`, `...`, `。。。`): the end of the sentence only when a closer or white space follows it, or
  // a full stop, an exclamation or a question mark ends it (`……。`, `...?`); otherwise the sentence goes on after
  // the pause.
  final isEllipsis =
      run.split('').any(_ellipses.contains) ||
      (run.length >= 2 && run.split('').every((m) => m == '.' || m == '。' || m == '｡' || m == '．'));
  if (isEllipsis) {
    if (atEnd || _closers.contains(next) || _isSpace(next)) {
      return j;
    }
    final last = run[run.length - 1];
    if (const {'！', '？', '!', '?', '‼', '⁇', '⁈', '⁉'}.contains(last) ||
        (run.split('').any(_ellipses.contains) && const {'。', '｡', '．'}.contains(last))) {
      return j;
    }
    return null;
  }

  final halfWidth = run.split('').every((m) => m == '!' || m == '?' || m == '.');
  if (!halfWidth) {
    // Full width marks always end a sentence.
    return j;
  }
  if (wideText && prev.isNotEmpty && _isAsciiLetterOrDigit(prev)) {
    // In Chinese or Japanese text, `!`, `?` and `.` right after a Latin letter or a digit belong to a name or a number
    // (`Love Live!`, `K-ON!!`, `D.C.`, `v1.0`), not to the end of the sentence.
    return null;
  }
  if (run != '.') {
    // `!` and `?` before white space, a wide character or a closer (not `a.php?x=1`, `!important`).
    return _halfWidthEnd(next, atEnd) ? j : null;
  }
  if (wideText) {
    // Chinese written with a half width point (`好的.然后`), after a Chinese or Japanese character.
    return prev.isNotEmpty && _isIdeograph(prev) && _halfWidthEnd(next, atEnd) ? j : null;
  }
  // English: a point before white space and then a capital letter, a wide character or a quote.
  if (atEnd || !_isSpace(next)) {
    return null;
  }
  var k = j;
  while (k < n && _isSpace(text[k])) {
    k++;
  }
  if (k >= n) {
    return null;
  }
  final after = text[k];
  if (!(_isUpperAscii(after) || _isWide(after) || after == '"' || after == '“')) {
    return null;
  }
  // The word before the point (letters and points: `e.g`, `U.S`).
  var s = i;
  while (s > 0 && (_isAsciiLetter(text[s - 1]) || text[s - 1] == '.')) {
    s--;
  }
  final word = text.substring(s, i);
  if (word.isEmpty) {
    // After a digit (`3. `) or a symbol.
    return null;
  }
  if (word.length == 1 || word.contains('.') || _abbreviations.contains(word.toLowerCase())) {
    // An initial (`J.`), an abbreviation (`Mr.`, `e.g.`, `U.S.`).
    return null;
  }
  return j;
}

bool _halfWidthEnd(String next, bool atEnd) => atEnd || _isSpace(next) || _isWide(next) || _closers.contains(next);
