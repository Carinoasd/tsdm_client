/// Compares what the app shows of a floor with what the web page shows of it, both as token streams (see `dump.dart`
/// and `tools/render_regression/web_snapshot.mjs`), into counts of differences by kind.
///
/// Both streams are first laid out in lines:
///
/// * the web page's: a block boundary (`sb`) ends a line that has something in it, a line break (`br`) always ends
///   one (an empty one is a blank line);
/// * the app's: a line break is `br`; a widget as wide as the line (a quote, a code block, a spoiler, a table, an
///   aligned block) has `sb` before it and `full` after it: it takes its line, a line break after it only ends that
///   line, text after it goes to the next line.
///
/// The visible characters of the two (and images, rules and players, a character each) are then lined up
/// ([SequenceMatcher], Python's `difflib` as the audit tool had it) and compared:
///
/// * content: characters lost or added;
/// * line breaks: two characters next to each other in both on different lines in one and on the same line in the
///   other (a line break missing or added), or with more or fewer blank lines between them;
/// * style: bold, italic, underline, strikethrough, the color and size an author gave, the background, alignment,
///   links, character by character;
/// * tables (rows and columns), blocks (quotes, code, spoilers, hidden content), images, rules, players: their numbers.
///
/// What is not compared, on purpose (each is said where it is done):
///
/// * white space: spaces, the indent of a line, blank characters (`&nbsp;`, the ideographic space) — the web page
///   folds them, so does the app; only where a space stands between two characters on a line is counted, apart;
/// * fonts: the web page names fonts the app does not have (`font-family`, `<font face>`); the font, the line height
///   and the width of what is laid out depend on them and are not compared; images are compared by their number,
///   not their size (the web page is 828 wide, the app 346);
/// * the app's own interface: a link's icon, the button of a spoiler, the title of a card, the "go to the post" arrow
///   of a quote; and the web page's: the "click to expand" of a spoiler's header, the "copy code" of a code block,
///   the notice of an edit (`i.pstatus`);
/// * the text of hidden content (`div.locked`): the app and the web page word it differently, only that it is there
///   is compared;
/// * colors the forum's style sheet gives a block (the gray of a quote, the blue of a link), which are not the
///   author's; a background as white as the page, which the page does not show; a picture as a background (`url()`,
///   a gradient), which the app does not show (only colors are compared); colors closer than 30 (the sum of the
///   channels) and sizes closer than 12% of the body text, which the two round differently;
/// * the text of a code block: the app shows it in its own font and colors;
/// * the forum's jammer text (`font.jammer`): noise against copying, white on the web page, left out by the app;
/// * what shows a fold a post makes itself (an element whose click shows a hidden one): the title of a spoiler in the
///   app, as the button and header of a spoiler are.
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:tsdm_client/utils/html/author_style.dart';

/// An image, a rule and a player in the sequence of characters compared.
const imageChar = 0xE000;
const ruleChar = 0xE001;
const mediaChar = 0xE002;

/// The text and link colors of the app's light theme, and its body text size: not colors an author gave.
const _appDefaultColor = '#191c20';
const _appLinkColor = '#37618e';
const _appDefaultFontSize = 14.0;

/// The forum's link color (`.t_f a`).
const _webLinkColor = '#336699';

final _space = RegExp(r'\s');
final _rgb = RegExp(r'rgba?\(\s*(\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)');

/// `#rrggbb` of a css color or of a dumped one, empty when there is none or it is transparent.
String toHex(Object? c) {
  if (c is! String || c.isEmpty) {
    return '';
  }
  if (c.startsWith('#')) {
    return c.split('@').first.toLowerCase();
  }
  final m = _rgb.firstMatch(c);
  if (m == null) {
    return c;
  }
  if (m.group(4) != null && double.parse(m.group(4)!) == 0) {
    return '';
  }
  return '#${[for (var i = 1; i <= 3; i++) int.parse(m.group(i)!).toRadixString(16).padLeft(2, '0')].join()}';
}

/// Whether [c] (`#rrggbb`) is as white as the page.
bool _pageWhite(String c) {
  final v = _channels(c);
  return v != null && v.reduce(math.min) >= 248;
}

List<int>? _channels(String c) {
  if (c.length < 7) {
    return null;
  }
  final r = int.tryParse(c.substring(1, 3), radix: 16);
  final g = int.tryParse(c.substring(3, 5), radix: 16);
  final b = int.tryParse(c.substring(5, 7), radix: 16);
  return r == null || g == null || b == null ? null : [r, g, b];
}

/// The sum of the differences of the channels of two colors, 999 when one is not a color.
int _hexDistance(String a, String b) {
  final x = _channels(a);
  final y = _channels(b);
  if (x == null || y == null) {
    return 999;
  }
  return (x[0] - y[0]).abs() + (x[1] - y[1]).abs() + (x[2] - y[2]).abs();
}

/// A visible character (or image, rule, player) of a floor, on its line.
final class Unit {
  Unit(this.ch, this.st, this.tp, {this.img, this.media});

  /// The character: a code point, or [imageChar], [ruleChar], [mediaChar].
  final int ch;

  /// The style of the text it is in.
  final Map<String, Object?> st;

  /// Where it is in the web page's elements (`div.quote>blockquote>font`), empty in the app's.
  final String tp;

  final Map<String, Object?>? img;
  final Map<String, Object?>? media;

  late int line;

  /// A space before it on its line.
  late bool space;

  /// The blocks it is in, outermost first.
  late List<String> blocks;
}

/// A floor laid out in lines.
final class Layout {
  final units = <Unit>[];

  /// Text of the interface (not content), see [compareFloor].
  final ctl = <String>[];

  /// Marks the app adds (the `@` of a mention).
  final decor = <String>[];

  /// What started each line (the web page's: `br`, `div`, `after-block`…).
  final causes = <int, String>{};
}

/// Lays [tokens] out in lines (see the library's documentation).
Layout layout(List<Map<String, Object?>> tokens) {
  final out = Layout();
  var line = 0;
  var has = false;
  var full = false;
  var pendingSpace = false;
  final stack = <String>[];

  void endLine(String cause) {
    line++;
    has = false;
    full = false;
    pendingSpace = false;
    out.causes.putIfAbsent(line, () => cause);
  }

  void content(Unit u) {
    if (full) {
      endLine('after-block');
    }
    u
      ..line = line
      ..space = pendingSpace && has
      ..blocks = List.of(stack);
    out.units.add(u);
    has = true;
    pendingSpace = false;
  }

  for (final t in tokens) {
    switch (t['k']) {
      case 't':
        final st = (t['st'] as Map<String, Object?>?) ?? const {};
        final tp = (t['tp'] as String?) ?? '';
        final s = t['s']! as String;
        // The "click to expand" of a spoiler's header: the web page's interface. What shows a fold the post makes
        // itself (`.fold-header`, see web_snapshot.mjs): the app makes it the title of a spoiler. The forum's jammer
        // text: noise the app leaves out.
        if (tp.contains('div.spoilerheader') || tp.contains('.fold-header') || tp.contains('font.jammer')) {
          out.ctl.add(s);
          continue;
        }
        // The notice of an edit (`i.pstatus`): the app shows it its own way.
        if (st['ps'] == 1) {
          out.ctl.add(s);
          continue;
        }
        for (final ch in s.runes) {
          if (ch == 0xA0 || ch == 0x3000) {
            // A blank character: not seen, but it takes room (a line of only it is a blank line on the web page);
            // not in the characters compared.
            if (full) {
              endLine('after-block');
            }
            has = true;
            pendingSpace = true;
            continue;
          }
          if (_space.hasMatch(String.fromCharCode(ch))) {
            pendingSpace = true;
            continue;
          }
          content(Unit(ch, st, tp));
        }
      case 'img':
        final src = (t['src'] as String?) ?? '';
        if (src.endsWith('static/image/common/back.gif')) {
          // The "go to the post" arrow of a quote: the app shows a button for it.
          out.ctl.add('back.gif');
          continue;
        }
        content(Unit(imageChar, {'a': t['a'] ?? 0}, (t['tp'] as String?) ?? '', img: t));
      case 'hr':
        content(Unit(ruleChar, const {}, 'hr'));
      case 'media':
        content(Unit(mediaChar, const {}, (t['tag'] as String?) ?? '', media: t));
      case 'br':
        endLine((t['tag'] as String?) ?? 'br');
      case 'sb':
        if (has) {
          endLine((t['tag'] as String?) ?? 'block');
        }
      case 'full':
        has = true;
        full = true;
      case 'open':
        stack.add(t['kind']! as String);
      case 'close':
        final i = stack.lastIndexOf(t['kind']! as String);
        if (i >= 0) {
          stack.removeAt(i);
        }
      case 'ctl':
        out.ctl.add(t['s']! as String);
      case 'decor':
        out.decor.add(t['s']! as String);
    }
  }
  return out;
}

/// Python's `difflib.SequenceMatcher` without junk (`autojunk=False`), on sequences of ints.
final class SequenceMatcher {
  SequenceMatcher(this.a, this.b) {
    for (final (j, x) in b.indexed) {
      (_b2j[x] ??= []).add(j);
    }
  }

  final List<int> a;
  final List<int> b;
  final _b2j = <int, List<int>>{};

  (int, int, int) _longestMatch(int alo, int ahi, int blo, int bhi) {
    var besti = alo;
    var bestj = blo;
    var bestsize = 0;
    var j2len = <int, int>{};
    for (var i = alo; i < ahi; i++) {
      final next = <int, int>{};
      for (final j in _b2j[a[i]] ?? const <int>[]) {
        if (j < blo) {
          continue;
        }
        if (j >= bhi) {
          break;
        }
        final k = next[j] = (j2len[j - 1] ?? 0) + 1;
        if (k > bestsize) {
          besti = i - k + 1;
          bestj = j - k + 1;
          bestsize = k;
        }
      }
      j2len = next;
    }
    while (besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1]) {
      besti--;
      bestj--;
      bestsize++;
    }
    while (besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize]) {
      bestsize++;
    }
    return (besti, bestj, bestsize);
  }

  /// The matching blocks (i, j, size), the last one (len(a), len(b), 0).
  List<(int, int, int)> matchingBlocks() {
    final queue = [(0, a.length, 0, b.length)];
    final blocks = <(int, int, int)>[];
    while (queue.isNotEmpty) {
      final (alo, ahi, blo, bhi) = queue.removeLast();
      final (i, j, k) = _longestMatch(alo, ahi, blo, bhi);
      if (k > 0) {
        blocks.add((i, j, k));
        if (alo < i && blo < j) {
          queue.add((alo, i, blo, j));
        }
        if (i + k < ahi && j + k < bhi) {
          queue.add((i + k, ahi, j + k, bhi));
        }
      }
    }
    blocks.sort((x, y) => x.$1 != y.$1 ? x.$1.compareTo(y.$1) : x.$2.compareTo(y.$2));
    var (i1, j1, k1) = (0, 0, 0);
    final collapsed = <(int, int, int)>[];
    for (final (i2, j2, k2) in blocks) {
      if (i1 + k1 == i2 && j1 + k1 == j2) {
        k1 += k2;
      } else {
        if (k1 > 0) {
          collapsed.add((i1, j1, k1));
        }
        (i1, j1, k1) = (i2, j2, k2);
      }
    }
    if (k1 > 0) {
      collapsed.add((i1, j1, k1));
    }
    collapsed.add((a.length, b.length, 0));
    return collapsed;
  }

  /// The edits from [a] to [b]: (op, i1, i2, j1, j2), op one of equal, replace, delete, insert.
  List<(String, int, int, int, int)> opcodes() {
    var i = 0;
    var j = 0;
    final out = <(String, int, int, int, int)>[];
    for (final (ai, bj, size) in matchingBlocks()) {
      final tag = i < ai && j < bj
          ? 'replace'
          : i < ai
          ? 'delete'
          : j < bj
          ? 'insert'
          : '';
      if (tag.isNotEmpty) {
        out.add((tag, i, ai, j, bj));
      }
      i = ai + size;
      j = bj + size;
      if (size > 0) {
        out.add(('equal', ai, i, bj, j));
      }
    }
    return out;
  }
}

String _show(int ch) => switch (ch) {
  imageChar => '[img]',
  ruleChar => '[hr]',
  mediaChar => '[media]',
  _ => String.fromCharCode(ch),
};

/// [units] from [i] to [j] with [around] more on each side, its line breaks as `⏎`: for messages.
String lined(List<Unit> units, int i, int j, [int around = 12]) {
  final lo = math.max(0, i - around);
  final hi = math.min(units.length, j + around);
  final b = StringBuffer();
  for (var k = lo; k < hi; k++) {
    if (k > lo) {
      final d = units[k].line - units[k - 1].line;
      if (d > 0) {
        b.write('⏎' * d);
      } else if (units[k].space) {
        b.write(' ');
      }
    }
    b.write(_show(units[k].ch));
  }
  return b.toString();
}

const _defaultFaces = r'yahei|雅黑|^\s*$';

Map<String, Object?> _webStyle(Map<String, Object?> st, Map<String, Object?> base) {
  String c;
  bool explicit;
  if (st.containsKey('ec')) {
    // Only a color the author gave (a <font color>, a style) is a color of the text, not one of the forum's css
    // (the gray of a quote, the blue of a link). A link in a <font color> is the forum's link color all the same.
    c = toHex(st['ec']);
    explicit = c.isNotEmpty && !(st['a'] == 1 && _hexDistance(c, _webLinkColor) <= 6);
  } else {
    c = toHex(st['c']);
    final linkDefault = toHex(base['link']);
    explicit =
        c.isNotEmpty &&
        _hexDistance(c, toHex(base['c'])) > 6 &&
        !(st['a'] == 1 && linkDefault.isNotEmpty && _hexDistance(c, linkDefault) <= 6);
  }
  var face = st.containsKey('face')
      ? (st['face'] as String? ?? '')
      : ((st['ff'] ?? '') == (base['ff'] ?? '') ? '' : (st['ff'] as String? ?? ''));
  if (RegExp(_defaultFaces, caseSensitive: false).hasMatch(face)) {
    face = '';
  }
  final baseSize = (base['fs'] as num?)?.toDouble() ?? 14;
  final bg = toHex(st['bg']);
  return {
    'b': st['b'] ?? 0,
    'i': st['i'] ?? 0,
    'u': st['u'] ?? 0,
    's': st['s'] ?? 0,
    'c': explicit ? c : '',
    'rfs': (((st['fs'] as num?)?.toDouble() ?? baseSize) / baseSize * 100).round() / 100,
    // A background as white as the page is not seen there; the app does not paint it.
    'bg': _pageWhite(bg) ? '' : bg,
    'bbg': toHex(st['bbg']),
    'al': st['al'] ?? 'l',
    'ff': face,
    'a': st['a'] ?? 0,
  };
}

Map<String, Object?> _appStyle(Map<String, Object?> st) {
  final c = toHex(st['c']);
  final explicit = c.isNotEmpty && c != _appDefaultColor && !(st['a'] == 1 && c == _appLinkColor);
  final fs = (st['fs'] as num?)?.toDouble() ?? _appDefaultFontSize;
  return {
    'b': st['b'] ?? 0,
    'i': st['i'] ?? 0,
    'u': st['u'] ?? 0,
    's': st['s'] ?? 0,
    'c': explicit ? c : '',
    'rfs': (fs / _appDefaultFontSize * 100).round() / 100,
    'bg': toHex(st['bg']),
    'bbg': toHex(st['bbg']),
    'al': st['al'] ?? 'l',
    'a': st['a'] ?? 0,
    'code': st['code'] ?? 0,
  };
}

/// The differences of a floor: [counts] by kind (what the baseline holds), an [examples] of each.
final class FloorDiff {
  final counts = <String, int>{};
  final examples = <String, String>{};

  /// Differences that are not counted (see the library's documentation), for the report.
  final tolerated = <String, int>{};

  void add(String key, int n, String example) {
    if (n <= 0) {
      return;
    }
    counts[key] = (counts[key] ?? 0) + n;
    examples.putIfAbsent(key, () => example);
  }
}

/// The pairs of indexes of [web] and [app] lined up, and the edits between them.
(List<(int, int)>, List<(String, int, int, int, int)>) align(List<Unit> web, List<Unit> app) {
  final m = SequenceMatcher([for (final u in web) u.ch], [for (final u in app) u.ch]);
  final ops = m.opcodes();
  final pairs = <(int, int)>[];
  for (final (op, i1, i2, j1, _) in ops) {
    if (op == 'equal') {
      for (var k = 0; k < i2 - i1; k++) {
        pairs.add((i1 + k, j1 + k));
      }
    }
  }
  return (pairs, ops);
}

/// What the web page wants hidden and what the app shows of it: see [darkReadability].
typedef Readability = ({int hiddenShown, int unreadable, String hiddenExample, String unreadableExample});

/// Compares a floor of the web page ([web]: its tokens and its `base` style) with the app's [app] tokens.
FloorDiff compareFloor(List<Map<String, Object?>> web, Map<String, Object?> base, List<Map<String, Object?>> app) {
  final res = FloorDiff();
  final wl = layout(web);
  final al = layout(app);
  // Hidden content: only that it is there is compared (the app words it differently).
  final wu = [
    for (final u in wl.units)
      if (!u.blocks.contains('locked')) u,
  ];
  final au = [
    for (final u in al.units)
      if (!u.blocks.contains('locked')) u,
  ];
  final (pairs, ops) = align(wu, au);

  // Content.
  for (final (op, i1, i2, j1, j2) in ops) {
    if ((op == 'delete' || op == 'replace') && i2 > i1) {
      final images = wu.sublist(i1, i2).every((u) => u.ch == imageChar);
      if (!images) {
        res.add('content.lost', i2 - i1, 'web: ${lined(wu, i1, i2, 10)}  app: ${lined(au, j1, j2, 10)}');
      }
    }
    if ((op == 'insert' || op == 'replace') && j2 > j1) {
      final images = au.sublist(j1, j2).every((u) => u.ch == imageChar);
      if (!images) {
        res.add('content.extra', j2 - j1, 'app: ${lined(au, j1, j2, 10)}  web: ${lined(wu, i1, i2, 10)}');
      }
    }
  }

  // Line breaks.
  for (var k = 0; k + 1 < pairs.length; k++) {
    final (i, j) = pairs[k];
    final (i2, j2) = pairs[k + 1];
    if (i2 != i + 1 || j2 != j + 1) {
      continue;
    }
    final dw = wu[i2].line - wu[i].line;
    final da = au[j2].line - au[j].line;
    if (dw == da) {
      continue;
    }
    final example = 'web: ${lined(wu, i, i2)}  app: ${lined(au, j, j2)}';
    final key = dw > 0 && da == 0
        ? 'breaks.missing'
        : dw == 0 && da > 0
        ? 'breaks.extra'
        : da > dw
        ? 'breaks.blank_more'
        : 'breaks.blank_less';
    res.add(key, 1, example);
  }

  // Style, links.
  final style = <String, List<int>>{};
  for (final (i, j) in pairs) {
    final w = wu[i];
    final a = au[j];
    if (w.ch == imageChar || w.ch == ruleChar || w.ch == mediaChar) {
      continue;
    }
    final ws = _webStyle(w.st, base);
    final as = _appStyle(a.st);
    // The text of a code block: the app shows it in its own font and colors.
    if (as['code'] == 1) {
      continue;
    }
    void add(String key) => (style[key] ??= []).add(i);
    for (final key in ['b', 'i', 'u', 's']) {
      if (ws[key] != as[key]) {
        if (key == 'u' && ws['a'] == 1 && as['a'] == 1 && ws['u'] == 1 && as['u'] != 1) {
          add('link-underline:lost');
          continue;
        }
        add('$key:${ws[key] == 1 ? 'lost' : 'extra'}');
      }
    }
    final wc = ws['c']! as String;
    final ac = as['c']! as String;
    // Colors closer than 30 (the sum of the channels) are the same color: the two sides round differently.
    if (wc.isNotEmpty && ac.isEmpty) {
      add('color:lost');
    } else if (ac.isNotEmpty && wc.isEmpty) {
      add('color:extra');
    } else if (wc.isNotEmpty && ac.isNotEmpty && _hexDistance(wc, ac) > 30) {
      add('color:diff');
    }
    // Sizes relative to the body text of each side (14 on both), a step of 12% or more.
    final wr = ws['rfs']! as double;
    final ar = as['rfs']! as double;
    if ((wr - ar).abs() > 0.12) {
      add(
        'size:${(ar - 1).abs() < 0.05
            ? 'flattened'
            : ar < wr
            ? 'smaller'
            : 'bigger'}',
      );
    }
    final wbg = ws['bg']! as String;
    final abg = as['bg']! as String;
    final wbbg = ws['bbg']! as String;
    if (wbbg.isNotEmpty && wbg.isEmpty && abg.isEmpty && (as['bbg']! as String).isEmpty && wbbg != '#ffffff') {
      add('block-bg:lost');
    }
    if (wbg.isNotEmpty && abg.isEmpty) {
      add('bg:lost');
    } else if (abg.isNotEmpty && wbg.isEmpty) {
      add('bg:extra');
    }
    if (ws['al'] != as['al']) {
      add('align:${ws['al']}->${as['al']}');
    }
    if ((ws['ff']! as String).isNotEmpty) {
      // A font the author named: the app has none of them (see the library's documentation).
      res.tolerated['font-face'] = (res.tolerated['font-face'] ?? 0) + 1;
    }
    if (ws['a'] != as['a']) {
      add(ws['a'] == 1 ? 'link:lost' : 'link:extra');
    }
  }
  for (final MapEntry(:key, :value) in style.entries) {
    final ex = value[value.length ~/ 2];
    res.add('style.$key', value.length, 'web: ${lined(wu, ex, ex + 1, 10)}');
  }

  // Images, rules, players: their numbers.
  int count(List<Unit> units, int ch) => units.where((u) => u.ch == ch).length;
  for (final (key, ch) in [('images', imageChar), ('hr', ruleChar), ('media', mediaChar)]) {
    final w = count(wl.units, ch);
    final a = count(al.units, ch);
    res.add(key, (w - a).abs(), 'web $w, app $a');
  }

  // Tables: rows × columns, in order. A table of one cell on the web page is a frame the app does not draw.
  List<(int, int)> tables(List<Map<String, Object?>> tokens) => [
    for (final t in tokens)
      if (t['k'] == 'open' && t['kind'] == 'table') ((t['rows']! as num).toInt(), (t['cols']! as num).toInt()),
  ];
  final wt = [
    for (final t in tables(web))
      if (t != (1, 1)) t,
  ];
  final at = tables(app);
  var tableDiffs = (wt.length - at.length).abs();
  for (var k = 0; k < math.min(wt.length, at.length); k++) {
    if (wt[k] != at[k]) {
      tableDiffs++;
    }
  }
  res.add('tables', tableDiffs, 'web $wt, app $at');

  // Blocks.
  Map<String, int> blocks(List<Map<String, Object?>> tokens) {
    final c = <String, int>{};
    for (final t in tokens) {
      if (t['k'] == 'open') {
        c[t['kind']! as String] = (c[t['kind']! as String] ?? 0) + 1;
      }
    }
    return c;
  }

  final wb = blocks(web);
  final ab = blocks(app);
  for (final kind in ['quote', 'code', 'spoiler', 'locked', 'hide']) {
    final w = wb[kind] ?? 0;
    final a = ab[kind] ?? 0;
    res.add('blocks.$kind', (w - a).abs(), 'web $w, app $a');
  }

  // Spaces between two characters on a line.
  for (var k = 0; k + 1 < pairs.length; k++) {
    final (i, j) = pairs[k];
    final (i2, j2) = pairs[k + 1];
    if (i2 != i + 1 || j2 != j + 1 || wu[i2].line != wu[i].line || au[j2].line != au[j].line) {
      continue;
    }
    if (wu[i2].space != au[j2].space) {
      res.add(
        wu[i2].space ? 'spaces.lost' : 'spaces.extra',
        1,
        'web: ${lined(wu, i, i2, 8)}  app: ${lined(au, j, j2, 8)}',
      );
    }
  }
  return res;
}

/// Relative luminance of `#rrggbb`, as WCAG has it.
double _luminance(List<double> rgb) {
  double ch(double c) => c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(rgb[0]) + 0.7152 * ch(rgb[1]) + 0.0722 * ch(rgb[2]);
}

/// Contrast ratio of two colors, as WCAG has it: 1 to 21.
double contrast(List<double> a, List<double> b) {
  final x = _luminance(a);
  final y = _luminance(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// A css or dumped color as channels 0–1 and its alpha, null when it is none.
(List<double>, double)? parseColor(Object? c) {
  if (c is! String || c.isEmpty) {
    return null;
  }
  if (c.startsWith('#')) {
    final parts = c.split('@');
    final v = _channels(parts.first);
    if (v == null) {
      return null;
    }
    final alpha = parts.length > 1 ? int.parse(parts[1], radix: 16) / 255 : 1.0;
    return ([for (final x in v) x / 255], alpha);
  }
  final m = _rgb.firstMatch(c);
  if (m == null) {
    return null;
  }
  return (
    [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!) / 255],
    m.group(4) == null ? 1.0 : double.parse(m.group(4)!),
  );
}

List<double> _over((List<double>, double) fg, List<double> bg) => [
  for (var i = 0; i < 3; i++) fg.$1[i] * fg.$2 + bg[i] * (1 - fg.$2),
];

Color _color(List<double> rgb) => Color.from(alpha: 1, red: rgb[0], green: rgb[1], blue: rgb[2]);

/// Text hidden in the app: what it is on shows through it.
const appHiddenContrast = 1.5;

/// Contrast text needs to be read: WCAG AA for body text.
const readableContrast = 4.5;

/// The readability rules of a dark theme, on [app] (the floor in a dark theme) against [web] (the web page's floor,
/// light): text the web page hides (as light as what it is on and of its color, [isCamouflaged]: an answer to
/// select, "反白") is hidden in the app too, text it shows reads
/// ([readableContrast]) on what it is on in the app. [defaultInk]: the color of text without one; [surface]: the
/// floor's card.
Readability darkReadability(
  List<Map<String, Object?>> web,
  List<Map<String, Object?>> app, {
  required String defaultInk,
  required String surface,
}) {
  final wu = [
    for (final u in layout(web).units)
      if (!u.blocks.contains('locked')) u,
  ];
  final au = [
    for (final u in layout(app).units)
      if (!u.blocks.contains('locked')) u,
  ];
  final (pairs, _) = align(wu, au);
  const white = [1.0, 1.0, 1.0];
  var hiddenShown = 0;
  var unreadable = 0;
  var hiddenExample = '';
  var unreadableExample = '';
  for (final (i, j) in pairs) {
    final w = wu[i];
    final a = au[j];
    if (w.ch == imageChar || w.ch == ruleChar || w.ch == mediaChar || a.st['code'] == 1) {
      continue;
    }
    // The web page: on the background of the text, else of its block, else on the white page.
    final webBack = parseColor(w.st['bg']) ?? parseColor(w.st['bbg']);
    final webOn = webBack == null || webBack.$2 == 0 ? white : _over(webBack, white);
    final webInk = parseColor(w.st['c']) ?? ([0.0, 0.0, 0.0], 1.0);
    // On a picture (white text on a dark photo) it is not hidden, whatever the color under the picture.
    final hidden = webInk.$2 == 0 || (w.st['pic'] != 1 && isCamouflaged(_color(_over(webInk, webOn)), _color(webOn)));
    // The app: on the background of the text, else what is painted under it, else the card.
    final appBack = parseColor(a.st['bg']);
    final under = parseColor(a.st['sf']) ?? parseColor(surface)!;
    final appOn = appBack == null ? under.$1 : _over(appBack, under.$1);
    final appInk = parseColor(a.st['c']) ?? parseColor(defaultInk)!;
    final ratio = contrast(_over(appInk, appOn), appOn);
    if (hidden && ratio > appHiddenContrast) {
      hiddenShown++;
      if (hiddenExample.isEmpty) {
        hiddenExample = '${lined(wu, i, i + 1, 8)} (${ratio.toStringAsFixed(2)})';
      }
    } else if (!hidden && ratio < readableContrast) {
      unreadable++;
      if (unreadableExample.isEmpty) {
        unreadableExample =
            '${lined(wu, i, i + 1, 8)} (${a.st['c']} on ${a.st['bg'] ?? a.st['sf']}, '
            '${ratio.toStringAsFixed(2)})';
      }
    }
  }
  return (
    hiddenShown: hiddenShown,
    unreadable: unreadable,
    hiddenExample: hiddenExample,
    unreadableExample: unreadableExample,
  );
}
