import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/utils/html/sentence_breaks.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/text_widget_span.dart';

/// How the content of a post is laid out for reading: line height, spacing between paragraphs, long paragraphs cut
/// after the end of a sentence.
///
/// Posts are often written with few line breaks. The web page shows them 712 wide, at a line height of 1.5; on a phone
/// the same paragraph is three times as many lines, and at the line height of the material body text (1.43), with
/// letter spacing and nothing between paragraphs, it read as a wall of text. The defaults open it up: a taller line,
/// a gap between paragraphs, no letter spacing (the web page has none; it spread Chinese text further apart).
///
/// Only the content of posts is laid out this way (see [PostTypographyScope]); the html of notices, messages,
/// profiles and the like keeps the body text style.
@immutable
final class PostTypography {
  /// Constructor.
  const PostTypography({
    this.lineHeight = defaultLineHeight,
    this.paragraphSpacing = defaultParagraphSpacing,
    this.splitLongParagraphs = false,
    this.lineWidth = defaultLineWidth,
  });

  /// Default [lineHeight].
  static const defaultLineHeight = 1.7;

  /// Lowest [lineHeight] offered in the settings.
  static const minLineHeight = 1.4;

  /// Highest [lineHeight] offered in the settings.
  static const maxLineHeight = 2.0;

  /// Default [paragraphSpacing].
  static const defaultParagraphSpacing = 8.0;

  /// Lowest [paragraphSpacing] offered in the settings: none.
  static const minParagraphSpacing = 0.0;

  /// Highest [paragraphSpacing] offered in the settings.
  static const maxParagraphSpacing = 16.0;

  /// Default [lineWidth]: a phone 390 wide at a text scale of 1 (346 / 14).
  static const double defaultLineWidth = phoneLineWidth;

  /// Height of a line of text, a multiple of its font size.
  final double lineHeight;

  /// Space between two paragraphs, in logical pixels at a text scale of 1 (it follows the text scale).
  final double paragraphSpacing;

  /// Cut a long paragraph into shorter ones after the end of a sentence (see [sentenceBreaks]).
  final bool splitLongParagraphs;

  /// How many Chinese characters a line of the content holds where it is shown ([postContentLineWidth]): what is a
  /// short line and what is a long paragraph depends on it.
  final double lineWidth;

  /// This layout with its values in the ranges offered in the settings.
  PostTypography clamped() => PostTypography(
    lineHeight: lineHeight.clamp(minLineHeight, maxLineHeight),
    paragraphSpacing: paragraphSpacing.clamp(minParagraphSpacing, maxParagraphSpacing),
    splitLongParagraphs: splitLongParagraphs,
    lineWidth: math.max<double>(1, lineWidth),
  );

  /// This layout for lines holding [lineWidth] characters.
  PostTypography withLineWidth(double lineWidth) => PostTypography(
    lineHeight: lineHeight,
    paragraphSpacing: paragraphSpacing,
    splitLongParagraphs: splitLongParagraphs,
    lineWidth: lineWidth,
  );

  @override
  bool operator ==(Object other) =>
      other is PostTypography &&
      other.lineHeight == lineHeight &&
      other.paragraphSpacing == paragraphSpacing &&
      other.splitLongParagraphs == splitLongParagraphs &&
      other.lineWidth == lineWidth;

  @override
  int get hashCode => Object.hash(lineHeight, paragraphSpacing, splitLongParagraphs, lineWidth);

  @override
  String toString() =>
      'PostTypography(lineHeight: $lineHeight, paragraphSpacing: $paragraphSpacing, '
      'splitLongParagraphs: $splitLongParagraphs, lineWidth: $lineWidth)';
}

/// How many Chinese characters (body text) a line of a floor's content holds when the floors are [width] wide (the
/// width the thread page gives its list, the safe area left out): the content width (the floor's margins and padding
/// off, at most [appReadingMaxWidth] for the floor and [htmlContentMaxWidth] for its content) over the size of the body
/// text at the text scale of [context]. Not rounded.
double postContentLineWidthIn(BuildContext context, double width) {
  // The floor's margins (6 on a phone, 16 wider: the screen decides, as for the floor) and its padding (16 a side).
  final margin = MediaQuery.sizeOf(context).width < 600 ? 6.0 : 16.0;
  final floor = math.min(width - 2 * margin, appReadingMaxWidth);
  final content = math.min(floor - 32, htmlContentMaxWidth);
  final fontSize = Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14;
  final scaled = MediaQuery.textScalerOf(context).scale(fontSize);
  return math.max<double>(1, content / scaled);
}

/// How many Chinese characters a line of a floor's content holds under [context]: the one [PostLineWidth] above
/// measured (the thread page), or worked out from the screen less its safe area where there is none (the post of a
/// notice).
double postContentLineWidth(BuildContext context) =>
    PostLineWidth.maybeOf(context) ??
    postContentLineWidthIn(context, MediaQuery.sizeOf(context).width - MediaQuery.paddingOf(context).horizontal);

/// How wide the content of a floor is under [context], in logical pixels: the line width [PostLineWidth] measured
/// for the floors (the thread page) times the size of the body text; null without one above. Images in a floor are
/// decoded no wider than that.
double? postContentWidthOf(BuildContext context) {
  final lineWidth = PostLineWidth.maybeOf(context);
  if (lineWidth == null) {
    return null;
  }
  final fontSize = Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14;
  return lineWidth * MediaQuery.textScalerOf(context).scale(fontSize);
}

/// Measures how many characters a line of the floors below holds ([postContentLineWidthIn]) in the width it is given,
/// for every floor at once.
///
/// While a window is dragged or the screen is split, the width changes at every frame: laying every floor kept alive
/// out again whenever a line holds half a character more or less made the frames of the drag several times slower. A
/// new line width is only taken when it differs by half a character or more, and only once the width has stayed the
/// same for [settleDelay]: the floors keep the line width they have meanwhile. A rotation or a new text scale is taken
/// at once.
class PostLineWidth extends StatefulWidget {
  /// Constructor.
  const PostLineWidth({required this.child, super.key});

  /// The floors.
  final Widget child;

  /// How long the width stays the same before a new line width is taken.
  static const settleDelay = Duration(milliseconds: 300);

  /// The line width of the floors under [context]; null without a [PostLineWidth] above.
  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PostLineWidthScope>()?.lineWidth;

  @override
  State<PostLineWidth> createState() => _PostLineWidthState();
}

class _PostLineWidthState extends State<PostLineWidth> {
  double? _applied;
  double? _pending;
  Orientation? _orientation;
  TextScaler? _textScaler;
  Timer? _timer;

  /// Line widths within half a character of each other lay the content out alike.
  static int _step(double lineWidth) => (2 * lineWidth).floor();

  void _offer(double measured, Orientation orientation, TextScaler textScaler) {
    final applied = _applied;
    if (applied == null || orientation != _orientation || textScaler != _textScaler) {
      _timer?.cancel();
      _applied = measured;
      _orientation = orientation;
      _textScaler = textScaler;
      return;
    }
    if (_step(measured) == _step(applied)) {
      // Back where it was (or never left): nothing to take.
      _timer?.cancel();
      _pending = null;
      return;
    }
    _pending = measured;
    _timer?.cancel();
    _timer = Timer(PostLineWidth.settleDelay, () {
      final pending = _pending;
      if (!mounted || pending == null) {
        return;
      }
      setState(() {
        _applied = pending;
        _pending = null;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.hasBoundedWidth ? constraints.maxWidth : MediaQuery.sizeOf(context).width;
      _offer(
        postContentLineWidthIn(context, width),
        MediaQuery.orientationOf(context),
        MediaQuery.textScalerOf(context),
      );
      return _PostLineWidthScope(lineWidth: _applied!, child: widget.child);
    },
  );
}

class _PostLineWidthScope extends InheritedWidget {
  const _PostLineWidthScope({required this.lineWidth, required super.child});

  final double lineWidth;

  @override
  bool updateShouldNotify(_PostLineWidthScope oldWidget) => lineWidth != oldWidget.lineWidth;
}

/// The [PostTypography] of the post content below it.
///
/// The html renderer lays its text out with it where there is one, and as the body text where there is none.
class PostTypographyScope extends InheritedWidget {
  /// Constructor.
  const PostTypographyScope({required this.typography, required super.child, this.postContent = true, super.key});

  /// How the post content below is laid out.
  final PostTypography typography;

  /// The html below is a post's content: shown with the forum's style sheet for posts, its links underlined and only
  /// those out of the forum marked, the player of its video at the end of its message. False for html only laid out
  /// as a post's content is (the rules of a forum, a self introduction), shown as before otherwise.
  final bool postContent;

  /// The [PostTypography] of [context], null outside post content.
  static PostTypography? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PostTypographyScope>()?.typography;

  /// Whether [context] is in a post's content ([postContent]).
  static bool isPostContent(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PostTypographyScope>()?.postContent ?? false;

  @override
  bool updateShouldNotify(PostTypographyScope oldWidget) =>
      typography != oldWidget.typography || postContent != oldWidget.postContent;
}

/// The space between two paragraphs in a rich text: a line break whose empty line is as tall as the spacing (a font
/// of that size at a line height of 1), put right after the line break ending the paragraph before.
///
/// A line break in a span costs nothing more to lay out; a widget for each gap made a floor of many paragraphs four to
/// five times slower to build. The line follows the text scale like the text. The text the rich text holds has the
/// line break more: what the floor's "copy text" offers comes from the html, it is not changed.
///
/// Where a long paragraph is cut (`breaksLine`), it is two line breaks: the first ends the line of the sentence (its
/// small font leaves that line as it is), the second is the gap; without spacing, only the first.
final class ParagraphGapSpan extends TextSpan {
  /// Constructor.
  ParagraphGapSpan(double spacing, {bool breaksLine = false})
    : super(
        text: breaksLine && spacing > 0 ? '\n\n' : '\n',
        style: spacing > 0 ? TextStyle(fontSize: spacing, height: 1) : null,
      );
}

bool _never(InlineSpan span) => false;

/// [spans] (the content of a rich text) laid out as paragraphs with [typography]: a [ParagraphGapSpan] of its
/// paragraph spacing between paragraphs and, when it splits long paragraphs, after the ends of sentences chosen by
/// [sentenceBreaks].
///
/// A paragraph is a line of the html (between two line breaks) with text in it. A gap goes at a single line break
/// between two paragraphs when one of them does not fit on a line ([PostTypography.lineWidth]). Not between a
/// paragraph and an image, a card, a quote or another block (they are not paragraphs, and an image row must not move),
/// nor at a blank line (two line breaks): that line already parts the paragraphs.
///
/// Text in a span [keepsLines] says yes to (preformatted text) is laid out as it is: no gap next to its lines, no cut.
/// Text in a span [keepsWhole] says yes to (a list, a heading) is never cut.
List<InlineSpan> layOutParagraphs(
  List<InlineSpan> spans,
  PostTypography typography, {
  bool Function(InlineSpan span) keepsLines = _never,
  bool Function(InlineSpan span) keepsWhole = _never,
}) {
  final spacing = typography.paragraphSpacing > 0;
  if (!spacing && !typography.splitLongParagraphs) {
    return spans;
  }
  final text = _ParagraphText.of(spans, keepsLines: keepsLines, keepsWhole: keepsWhole);
  final gaps = text.gaps(spacing: spacing, splitLong: typography.splitLongParagraphs, lineWidth: typography.lineWidth);
  if (gaps.isEmpty) {
    return spans;
  }
  return _GapInserter(gaps, typography.paragraphSpacing).insert(spans);
}

/// The text of the spans laid out by [layOutParagraphs], one character per UTF-16 code unit as in
/// [InlineSpan.toPlainText], a placeholder for each widget.
final class _ParagraphText {
  _ParagraphText._(this.text, List<(int, int)> keptLines, List<(int, int)> keptWhole, List<(int, int)> blocks)
    : _keptLines = _Coverage(keptLines, text.length),
      _keptWhole = _Coverage(keptWhole, text.length),
      _blocks = _Coverage(blocks, text.length);

  factory _ParagraphText.of(
    List<InlineSpan> spans, {
    required bool Function(InlineSpan span) keepsLines,
    required bool Function(InlineSpan span) keepsWhole,
  }) {
    final buffer = StringBuffer();
    // Ranges [start, end) of the text in preformatted text, and in lists and headings.
    final keptLines = <(int, int)>[];
    final keptWhole = <(int, int)>[];
    // The placeholders of blocks (a table, a card, a quote, a rule).
    final blocks = <(int, int)>[];

    void visit(InlineSpan span, {required bool lines, required bool whole}) {
      final start = buffer.length;
      final ownLines = !lines && keepsLines(span);
      final ownWhole = !whole && keepsWhole(span);
      switch (span) {
        case TextSpan(:final text, :final children):
          if (text != null) {
            buffer.write(text);
          }
          for (final child in children ?? const <InlineSpan>[]) {
            visit(child, lines: lines || ownLines, whole: whole || ownWhole);
          }
        case PlaceholderSpan():
          if (_isBlock(span)) {
            blocks.add((start, start + 1));
          }
          buffer.write(objectReplacementChar);
        default:
          // Not built by the html renderer: its text counts, it is not cut.
          buffer.write(span.toPlainText(includeSemanticsLabels: false));
          if (!whole && !ownWhole) {
            keptWhole.add((start, buffer.length));
          }
      }
      if (ownLines) {
        keptLines.add((start, buffer.length));
      }
      if (ownWhole) {
        keptWhole.add((start, buffer.length));
      }
    }

    for (final span in spans) {
      visit(span, lines: false, whole: false);
    }
    return _ParagraphText._(buffer.toString(), keptLines, keptWhole, blocks);
  }

  /// Whether [span] is a block laid out on a line of its own (a table, a card, a quote, a rule): a widget with text in
  /// it ([textWidgetSpan]) or a divider. Not an image, a smiley, a link's icon, nor a ruby (on the baseline).
  static bool _isBlock(PlaceholderSpan span) =>
      span is WidgetSpan &&
      span.alignment != PlaceholderAlignment.baseline &&
      (span.child is TextWidgetSpanChild || span.child is Divider);

  final String text;

  /// The text in preformatted text.
  final _Coverage _keptLines;

  /// The text in lists and headings.
  final _Coverage _keptWhole;

  /// The placeholders of blocks.
  final _Coverage _blocks;

  static final _visible = RegExp('[^\\s$objectReplacementChar]');

  /// Offsets of the characters a gap goes before, and whether it also breaks the line there (a cut in a paragraph):
  /// at the line breaks between paragraphs when there is [spacing], after the ends of sentences of long paragraphs
  /// when [splitLong]. A line holds [lineWidth] characters.
  Map<int, bool> gaps({required bool spacing, required bool splitLong, required double lineWidth}) {
    // Lines of the text: [start, end) between line breaks.
    final lines = <(int, int)>[];
    var start = 0;
    while (true) {
      final end = text.indexOf('\n', start);
      if (end < 0) {
        lines.add((start, text.length));
        break;
      }
      lines.add((start, end));
      start = end + 1;
    }

    final contents = [for (final line in lines) text.substring(line.$1, line.$2)];
    final isParagraph = [
      for (final (i, line) in lines.indexed)
        _visible.hasMatch(contents[i]) &&
            // Not a line of preformatted text, nor the line its line break ends.
            !_keptLines.meets(line.$1, line.$2 + 1) &&
            // Not a line holding a block: a table is not always followed by a line break of its own
            // (`text<br><table>…</table>text`), the text after it is on its line.
            !_blocks.meets(line.$1, line.$2),
    ];
    final widths = [for (final content in contents) textWidth(content)];
    final gaps = <int, bool>{};
    for (var i = 1; spacing && i < lines.length; i++) {
      if (isParagraph[i - 1] && isParagraph[i] && (widths[i - 1] > lineWidth || widths[i] > lineWidth)) {
        // Right after the line break, before the first character of the paragraph after it.
        gaps[lines[i].$1] = false;
      }
    }
    if (splitLong) {
      for (final (i, line) in lines.indexed) {
        if (!isParagraph[i] || widths[i] <= longParagraphLines * lineWidth || _keptWhole.meets(line.$1, line.$2)) {
          continue;
        }
        for (final cut in sentenceBreaks(contents[i], lineWidth: lineWidth)) {
          gaps[line.$1 + cut] = true;
        }
      }
    }
    return gaps;
  }
}

/// Which characters of a text some ranges cover, to ask about a range of the text at once.
final class _Coverage {
  _Coverage(List<(int, int)> ranges, int length) : _covered = ranges.isEmpty ? null : Int32List(length + 1) {
    final covered = _covered;
    if (covered == null) {
      return;
    }
    // Ranges nest (a span in a span): how many cover each character is counted, then turned into how many of the
    // characters before each offset are covered.
    final depth = Int32List(length + 1);
    for (final (start, end) in ranges) {
      depth[start] += 1;
      depth[end] -= 1;
    }
    var open = 0;
    for (var i = 0; i < length; i++) {
      open += depth[i];
      covered[i + 1] = covered[i] + (open > 0 ? 1 : 0);
    }
  }

  /// Covered characters before each offset; null when nothing is covered.
  final Int32List? _covered;

  /// Whether a character of [start, end) is covered (an end past the text is the end of the text).
  bool meets(int start, int end) {
    final covered = _covered;
    if (covered == null) {
      return false;
    }
    return covered[math.min(end, covered.length - 1)] - covered[start] > 0;
  }
}

/// Puts a [ParagraphGapSpan] before each of [gaps] (offsets in the text of the spans) into the spans.
final class _GapInserter {
  _GapInserter(this.gaps, this.spacing);

  /// The offsets, and whether the gap breaks the line there.
  final Map<int, bool> gaps;
  final double spacing;

  /// Offset of the next character in the text of the spans.
  int _offset = 0;

  List<InlineSpan> insert(List<InlineSpan> spans) => [for (final span in spans) _insert(span)];

  InlineSpan _insert(InlineSpan span) {
    switch (span) {
      case TextSpan(:final text, :final children):
        List<InlineSpan>? pieces;
        if (text != null && text.isNotEmpty) {
          final start = _offset;
          _offset += text.length;
          // A gap goes after the character before it: in the span whose text holds that character.
          final cuts = [
            for (var i = start + 1; i <= _offset; i++)
              if (gaps.containsKey(i)) i - start,
          ];
          if (cuts.isNotEmpty && span.semanticsLabel == null) {
            pieces = [];
            var from = 0;
            for (final cut in cuts) {
              pieces
                ..add(_piece(span, text.substring(from, cut)))
                ..add(ParagraphGapSpan(spacing, breaksLine: gaps[start + cut]!));
              from = cut;
            }
            if (from < text.length) {
              pieces.add(_piece(span, text.substring(from)));
            }
          }
        }
        final newChildren = children == null ? null : [for (final child in children) _insert(child)];
        final childrenChanged =
            newChildren != null && newChildren.indexed.any((e) => !identical(e.$2, children![e.$1]));
        if (pieces == null && !childrenChanged) {
          return span;
        }
        if (pieces == null) {
          return TextSpan(
            text: text,
            children: newChildren,
            style: span.style,
            recognizer: span.recognizer,
            mouseCursor: span.mouseCursor,
            onEnter: span.onEnter,
            onExit: span.onExit,
            semanticsLabel: span.semanticsLabel,
            semanticsIdentifier: span.semanticsIdentifier,
            locale: span.locale,
            spellOut: span.spellOut,
          );
        }
        // The text cut into pieces: children carrying what the text did (the tap of a link is only taken by the span
        // holding the text, not by its parent), the style on the parent for the children of the span as before.
        return TextSpan(style: span.style, children: [...pieces, ...?newChildren]);
      case PlaceholderSpan():
        _offset += 1;
        return span;
      default:
        _offset += span.toPlainText(includeSemanticsLabels: false).length;
        return span;
    }
  }

  /// [text], a piece of the text of [span], with everything of [span] but its style (inherited from the parent).
  static TextSpan _piece(TextSpan span, String text) => TextSpan(
    text: text,
    recognizer: span.recognizer,
    mouseCursor: span.mouseCursor,
    onEnter: span.onEnter,
    onExit: span.onExit,
    locale: span.locale,
    spellOut: span.spellOut,
  );
}
