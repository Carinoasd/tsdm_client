/// What the app shows of a floor, read from its widget tree as the same token stream the web snapshot has
/// (`tools/render_regression/web_snapshot.mjs`): text with its style, line breaks, blocks, images, rules, players.
///
/// A few widgets are matched by the name of their type, not their type: they move between files in the work on the
/// post display (tables, aligned blocks, players), and the test is not to break on that.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tsdm_client/utils/html/author_style.dart';
import 'package:tsdm_client/utils/html/post_table.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/card/code_card.dart';
import 'package:tsdm_client/widgets/card/lock_card/locked_card.dart';
import 'package:tsdm_client/widgets/card/review_card.dart';
import 'package:tsdm_client/widgets/card/spoiler_card.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';
import 'package:tsdm_client/widgets/quoted_text.dart';

/// `#rrggbb`, with `@aa` after it when not opaque; empty for null.
String hexColor(Color? c) {
  if (c == null) {
    return '';
  }
  final v = c.toARGB32();
  final rgb = '#${(v & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  return (v >> 24) == 0xFF ? rgb : '$rgb@${(v >> 24).toRadixString(16)}';
}

String _alignOf(TextAlign a) => switch (a) {
  TextAlign.center => 'c',
  TextAlign.right || TextAlign.end => 'r',
  _ => 'l',
};

/// Special cards a floor can hold: blocks of their own.
const _specialCards = {'BountyCard', 'BountyAnswerCard', 'RedPacketCard', 'NewcomerReportCard'};

/// Walks the widget tree of a floor into tokens (the web snapshot's format, and `full`: a widget as wide as the line
/// that takes the line it is on).
final class FloorDumper {
  /// The tokens.
  final tokens = <Map<String, Object?>>[];

  /// Blocks met, by kind.
  final kinds = <String, int>{};

  /// The backgrounds of the blocks the walk is in (an author's background, a table row's), innermost last.
  final _blockBackgrounds = <String>[];

  /// Everything painted under the walk (a card, an author's background, a table row), innermost last: what text is
  /// read on, for the readability rules of the dark theme.
  final _surfaces = <Color>[];

  /// The text of a card's title (a spoiler's, an embedded card's): the first rich text of that text is the app's
  /// interface, not content.
  final _skip = <String>[];

  void _add(Map<String, Object?> t) => tokens.add(t);

  /// Walks [root], the floor's content: what is painted under it is what its text is on.
  void floor(Element root) {
    // Up to the first opaque paint (a translucent card shows what is under it).
    final under = <Color>[];
    root.visitAncestorElements((a) {
      if (_paintedBy(a.widget) case final color?) {
        under.add(color);
        return color.a < 1;
      }
      return true;
    });
    under.reversed.forEach(_paint);
    element(root, link: false);
  }

  /// Paints [color] over what is painted already: a translucent card shows what is under it.
  void _paint(Color color) => _surfaces.add(
    color.a < 1 && _surfaces.isNotEmpty ? Color.alphaBlend(color, _surfaces.last) : color,
  );

  static Color? _paintedBy(Widget w) => switch (w) {
    Material(:final color?, :final type) when type != MaterialType.transparency && color.a > 0 => color,
    ColoredBox(:final color) when color.a > 0 => color,
    DecoratedBox(decoration: BoxDecoration(:final color?)) when color.a > 0 => color,
    _ => null,
  };

  /// Walks [e] and what is under it, in a link when [link].
  void element(Element e, {required bool link}) {
    final w = e.widget;
    final surface = _paintedBy(w);
    if (surface != null) {
      _paint(surface);
    }
    _element(e, w, link: link);
    if (surface != null) {
      _surfaces.removeLast();
    }
  }

  void _element(Element e, Widget w, {required bool link}) {
    switch (w) {
      case Icon() || IconButton() || CircularProgressIndicator():
        // The app's own marks (a link's icon, a card's button): not content.
        return;
      case RichText():
        _richText(e, link: link);
        return;
      case QuotedText():
        _block(e, 'quote', link);
        return;
      case CodeCard():
        kinds['code'] = (kinds['code'] ?? 0) + 1;
        _add({'k': 'open', 'kind': 'code'});
        for (final (i, l) in w.code.split('\n').indexed) {
          if (i > 0) {
            _add({'k': 'br'});
          }
          if (l.isNotEmpty) {
            _add({
              'k': 't',
              's': l,
              'st': {'b': 0, 'i': 0, 'u': 0, 's': 0, 'c': '', 'fs': 0, 'bg': '', 'al': 'l', 'a': 0, 'code': 1},
            });
          }
        }
        _add({'k': 'close', 'kind': 'code'});
        return;
      case SpoilerCard():
        kinds['spoiler'] = (kinds['spoiler'] ?? 0) + 1;
        final title = w.title.toPlainText();
        _add({'k': 'open', 'kind': 'spoiler', 'title': title});
        _skip.add(title);
        e.visitChildren((c) => element(c, link: link));
        _add({'k': 'close', 'kind': 'spoiler'});
        return;
      case AppEmbedCard():
        _skip.add(w.title);
        if (w.subtitle != null) {
          _skip.add(w.subtitle!);
        }
        e.visitChildren((c) => element(c, link: link));
        return;
      case LockedCard():
        _block(e, 'locked', link);
        return;
      case ReviewCard():
        _block(e, 'comment', link);
        return;
      case Table():
        _table(e, w, link);
        return;
      case PostTable():
        _postTable(e, w, link);
        return;
      case Divider():
        _add({'k': 'hr'});
        return;
      case NetworkIndicatorImage():
        _image(e, w.src, link);
        return;
      case CachedImage():
        _image(e, w.imageUrl, link);
        return;
      case Text() when w.data == '@':
        // The mark the app puts before a mention.
        _add({'k': 'decor', 's': '@'});
        return;
      case PostBlockBackground():
        _blockBackgrounds.add(hexColor(w.color));
        e.visitChildren((c) => element(c, link: link));
        _blockBackgrounds.removeLast();
        return;
      default:
        final name = w.runtimeType.toString();
        // Players: the web page's iframe, embed, audio, video (the title and buttons of the card are the app's).
        if (name == 'NeteaseCard') {
          kinds[name] = (kinds[name] ?? 0) + 1;
          _add({'k': 'open', 'kind': name});
          _add({'k': 'media'});
          _add({'k': 'close', 'kind': name});
          return;
        }
        if (name == 'PostMediaCard') {
          kinds['media'] = (kinds['media'] ?? 0) + 1;
          _add({'k': 'media'});
          return;
        }
        if (_specialCards.contains(name)) {
          _block(e, name, link);
          return;
        }
        e.visitChildren((c) => element(c, link: link));
    }
  }

  void _image(Element e, String src, bool link) {
    final box = e.findRenderObject() as RenderBox?;
    _add({
      'k': 'img',
      'src': src,
      'w': box == null || !box.hasSize ? null : (box.size.width * 10).round() / 10,
      'h': box == null || !box.hasSize ? null : (box.size.height * 10).round() / 10,
      'a': link ? 1 : 0,
    });
  }

  void _table(Element e, Table w, bool link) {
    kinds['table'] = (kinds['table'] ?? 0) + 1;
    final rows = w.children.length;
    final cols = w.children.fold<int>(0, (m, r) => math.max(m, r.children.length));
    final box = e.findRenderObject() as RenderBox?;
    _add({'k': 'open', 'kind': 'table', 'rows': rows, 'cols': cols, 'w': box?.size.width.round()});
    final rowColors = [
      for (final r in w.children)
        switch (r.decoration) {
          BoxDecoration(:final color?) => color,
          _ => null,
        },
    ];
    var i = 0;
    e.visitChildren((c) {
      final rowColor = cols == 0 ? null : rowColors[math.min(rows - 1, i ~/ cols)];
      i++;
      if (rowColor != null) {
        _blockBackgrounds.add(hexColor(rowColor));
        _paint(rowColor);
      }
      _add({'k': 'sb'});
      element(c, link: link);
      _add({'k': 'sb'});
      if (rowColor != null) {
        _blockBackgrounds.removeLast();
        _surfaces.removeLast();
      }
    });
    _add({'k': 'close', 'kind': 'table'});
  }

  /// A table of a post laid out by [PostTable]: its rows, and its columns as the web page counts them (the most cells
  /// a row has, a cell spanning columns one cell); the backgrounds it paints under its cells (the table's, then each
  /// cell's own or its row's).
  void _postTable(Element e, PostTable w, bool link) {
    kinds['table'] = (kinds['table'] ?? 0) + 1;
    final cells = w.children.cast<PostTableCell>();
    final perRow = <int, int>{};
    for (final cell in cells) {
      perRow[cell.row] = (perRow[cell.row] ?? 0) + 1;
    }
    final box = e.findRenderObject() as RenderBox?;
    _add({
      'k': 'open',
      'kind': 'table',
      'rows': w.rowCount,
      'cols': perRow.values.fold<int>(0, math.max),
      'w': box?.size.width.round(),
    });
    final tableColor = w.background;
    if (tableColor != null) {
      _blockBackgrounds.add(hexColor(tableColor));
      _paint(tableColor);
    }
    var i = 0;
    e.visitChildren((c) {
      final cell = cells[math.min(i++, cells.length - 1)];
      final color = cell.background ?? (cell.row < w.rowBackgrounds.length ? w.rowBackgrounds[cell.row] : null);
      if (color != null) {
        _blockBackgrounds.add(hexColor(color));
        _paint(color);
      }
      _add({'k': 'sb'});
      element(c, link: link);
      _add({'k': 'sb'});
      if (color != null) {
        _blockBackgrounds.removeLast();
        _surfaces.removeLast();
      }
    });
    if (tableColor != null) {
      _blockBackgrounds.removeLast();
      _surfaces.removeLast();
    }
    _add({'k': 'close', 'kind': 'table'});
  }

  void _block(Element e, String kind, bool link) {
    kinds[kind] = (kinds[kind] ?? 0) + 1;
    _add({'k': 'open', 'kind': kind});
    e.visitChildren((c) => element(c, link: link));
    _add({'k': 'close', 'kind': kind});
  }

  /// The kind of block the subtree of a [WidgetSpan] is when it is as wide as the line (a quote, a code block, a
  /// spoiler, a table, a rule, an aligned block…), null when it is inline (an image, a player).
  static String? blockKindOf(Element e) {
    String? found;
    void visit(Element c, int depth) {
      if (found != null || depth > 12) {
        return;
      }
      final w = c.widget;
      switch (w) {
        case QuotedText():
          found = 'quote';
        case CodeCard():
          found = 'code';
        case SpoilerCard():
          found = 'spoiler';
        case LockedCard():
          found = 'locked';
        case ReviewCard():
          found = 'comment';
        case Table() || PostTable():
          found = 'table';
        case Divider():
          found = 'hr';
        case Row() when w.children.any((x) => x is Expanded):
          found = 'align';
        case Container() when w.constraints?.maxWidth == double.infinity && w.constraints?.minWidth == double.infinity:
          found = 'box';
        case RichText() || NetworkIndicatorImage() || CachedImage() || Card() || Icon():
          return;
        default:
          final name = w.runtimeType.toString();
          if (_specialCards.contains(name) || name == 'NeteaseCard') {
            found = name;
            return;
          }
          if (name == 'PostTableScrollView') {
            found = 'table';
            return;
          }
          if (name == 'FullWidthBlock') {
            found = 'align';
            return;
          }
          if (name == 'PostMediaCard') {
            return;
          }
          c.visitChildren((x) => visit(x, depth + 1));
      }
    }

    visit(e, 0);
    return found;
  }

  void _richText(Element e, {required bool link}) {
    final rt = e.widget as RichText;
    final plain = rt.text.toPlainText(includeSemanticsLabels: false);
    if (_skip.remove(plain)) {
      _add({'k': 'ctl', 's': plain});
      return;
    }
    final children = <Element>[];
    e.visitChildren(children.add);
    var idx = 0;
    final align = _alignOf(rt.textAlign);
    void visitSpan(InlineSpan span, TextStyle? parent, {required bool inLink}) {
      // The gap between paragraphs is layout, not a line break of the content.
      if (span.runtimeType.toString() == 'ParagraphGapSpan') {
        return;
      }
      if (span is TextSpan) {
        final style = parent == null ? span.style : parent.merge(span.style);
        final l = inLink || span.recognizer != null;
        final text = span.text;
        if (text != null && text.isNotEmpty) {
          final st = {
            'b': (style?.fontWeight?.value ?? 400) >= 600 ? 1 : 0,
            'i': style?.fontStyle == FontStyle.italic ? 1 : 0,
            'u': (style?.decoration?.contains(TextDecoration.underline) ?? false) ? 1 : 0,
            's': (style?.decoration?.contains(TextDecoration.lineThrough) ?? false) ? 1 : 0,
            'c': hexColor(style?.color),
            'fs': style?.fontSize ?? 14,
            'bg': hexColor(style?.backgroundColor ?? style?.background?.color),
            'al': align,
            'a': l ? 1 : 0,
            'bbg': _blockBackgrounds.lastOrNull ?? '',
            'sf': hexColor(_surfaces.lastOrNull),
          };
          for (final (i, p) in text.split('\n').indexed) {
            if (i > 0) {
              _add({'k': 'br'});
            }
            if (p.isNotEmpty) {
              _add({'k': 't', 's': p, 'st': st});
            }
          }
        }
        for (final c in span.children ?? const <InlineSpan>[]) {
          visitSpan(c, style, inLink: l);
        }
      } else if (span is WidgetSpan) {
        if (idx >= children.length) {
          return;
        }
        final child = children[idx++];
        final kind = blockKindOf(child);
        if (kind != null) {
          _add({'k': 'sb'});
          if (kind == 'align') {
            _add({'k': 'open', 'kind': 'align'});
          }
        }
        element(child, link: inLink);
        if (kind != null) {
          if (kind == 'align') {
            // The empty line a block's content ends with (the `br` added below for the line break it ends with) is
            // the block's own last line, which `full` takes: without this, a blank line too many after the block.
            final last = tokens.lastIndexWhere((t) => t['k'] != 'close');
            if (last >= 0 && tokens[last]['k'] == 'br') {
              tokens.removeAt(last);
            }
            _add({'k': 'close', 'kind': 'align'});
          }
          _add({'k': 'full'});
        }
      }
    }

    visitSpan(rt.text, null, inLink: link);
    // A line break a rich text ends with lays out one more, empty line in Flutter (a cell, an aligned block are each
    // a rich text of their own); a `<br>` at the end of a block on the web page does not.
    if (plain.endsWith('\n')) {
      _add({'k': 'br'});
    }
  }
}
