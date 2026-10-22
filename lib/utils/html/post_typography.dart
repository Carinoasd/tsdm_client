import 'package:flutter/widgets.dart';
import 'package:tsdm_client/utils/html/sentence_breaks.dart';

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

  /// Height of a line of text, a multiple of its font size.
  final double lineHeight;

  /// Space between two paragraphs, in logical pixels at a text scale of 1 (it follows the text scale).
  final double paragraphSpacing;

  /// Cut a long paragraph into shorter ones after the end of a sentence (see [sentenceBreaks]).
  final bool splitLongParagraphs;

  @override
  bool operator ==(Object other) =>
      other is PostTypography &&
      other.lineHeight == lineHeight &&
      other.paragraphSpacing == paragraphSpacing &&
      other.splitLongParagraphs == splitLongParagraphs;

  @override
  int get hashCode => Object.hash(lineHeight, paragraphSpacing, splitLongParagraphs);

  @override
  String toString() =>
      'PostTypography(lineHeight: $lineHeight, paragraphSpacing: $paragraphSpacing, '
      'splitLongParagraphs: $splitLongParagraphs)';
}

/// The [PostTypography] of the post content below it.
///
/// The html renderer lays its text out with it where there is one, and as the body text where there is none.
class PostTypographyScope extends InheritedWidget {
  /// Constructor.
  const PostTypographyScope({required this.typography, required super.child, super.key});

  /// How the post content below is laid out.
  final PostTypography typography;

  /// The [PostTypography] of [context], null outside post content.
  static PostTypography? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PostTypographyScope>()?.typography;

  @override
  bool updateShouldNotify(PostTypographyScope oldWidget) => typography != oldWidget.typography;
}

/// The space between two paragraphs in a rich text: an empty line [height] tall.
///
/// It takes the whole width of the line it is in, so it is a line of its own: the text after it starts the next
/// line. A placeholder adds nothing to the text that is selected and copied, so a gap does not add a line break to
/// it either.
class ParagraphGap extends LeafRenderObjectWidget {
  /// Constructor.
  const ParagraphGap(this.height, {super.key});

  /// Height of the gap, before the text scale (the paragraph scales its placeholders).
  final double height;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderParagraphGap(height);

  @override
  void updateRenderObject(BuildContext context, RenderParagraphGap renderObject) => renderObject.height = height;
}

/// The render object of a [ParagraphGap].
class RenderParagraphGap extends RenderBox {
  /// Constructor.
  RenderParagraphGap(this._height);

  /// Height of the gap.
  double get height => _height;
  double _height;

  set height(double value) {
    if (value == _height) {
      return;
    }
    _height = value;
    markNeedsLayout();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(constraints.hasBoundedWidth ? constraints.maxWidth : 0, _height));

  @override
  void performLayout() => size = computeDryLayout(constraints);

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  @override
  double computeMinIntrinsicHeight(double width) => _height;

  @override
  double computeMaxIntrinsicHeight(double width) => _height;
}

/// A rich text of [span], laid out as [Text.rich] would lay it out with [style], where a line holding only a
/// [ParagraphGap] is as tall as the gap.
///
/// A line is never shorter than the font of the paragraph itself (the style of the rich text): a line with nothing
/// but a gap of 8 was as tall as an empty line of text (about 19 on a phone). Here the paragraph's own font is tiny,
/// and the text gets its style back from a span around it: the text, the empty lines (two line breaks) and the image
/// rows are laid out as before.
class ParagraphGapText extends StatelessWidget {
  /// Constructor.
  const ParagraphGapText(this.span, {this.style, this.textAlign, super.key});

  /// The text.
  final InlineSpan span;

  /// The style of the text, merged with the [DefaultTextStyle] as [Text.rich] does.
  final TextStyle? style;

  /// How the lines are aligned.
  final TextAlign? textAlign;

  /// The font of the paragraph: what a line holding nothing but placeholders is at least as tall as.
  static const _paragraphStyle = TextStyle(fontSize: 1, height: 1);

  @override
  Widget build(BuildContext context) {
    final defaultStyle = DefaultTextStyle.of(context).style;
    final textStyle = style == null || style!.inherit ? defaultStyle.merge(style) : style;
    return Text.rich(
      TextSpan(style: textStyle, children: [span]),
      style: _paragraphStyle,
      textAlign: textAlign,
    );
  }
}

bool _never(InlineSpan span) => false;

/// A paragraph wider than this ([textWidth]: about a line of a phone 390 wide) is long: a single line break next to
/// one is the end of a paragraph, and gets the paragraph spacing. A single line break between two short lines (a
/// poem, a list of names, a post that breaks its lines at every clause) keeps them together.
@visibleForTesting
const shortLineWidth = 24.0;

/// [spans] (the content of a rich text) laid out as paragraphs with [typography]: a [ParagraphGap] of its paragraph
/// spacing between paragraphs and, when it splits long paragraphs, after the ends of sentences chosen by
/// [sentenceBreaks]. The text itself is not changed: the gaps are placeholders, which add nothing to the text that is
/// copied.
///
/// A paragraph is a line of the html (between two line breaks) with text in it. A gap goes at a single line break
/// between two paragraphs when one of them is long ([shortLineWidth]). Not between a paragraph and an image, a card,
/// a quote or another block (they are not paragraphs, and an image row must not move), nor at a blank line (two line
/// breaks): that line already parts the paragraphs.
///
/// Text in a span [keepsLines] says yes to (preformatted text) is laid out as it is: no gap next to its lines, no cut.
/// Text in a span [keepsWhole] says yes to (a list item, a heading) is never cut.
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
  final gaps = text.gaps(spacing: spacing, splitLong: typography.splitLongParagraphs);
  if (gaps.isEmpty) {
    return spans;
  }
  return _GapInserter(gaps, typography.paragraphSpacing).insert(spans);
}

/// The text of the spans laid out by [layOutParagraphs], one character per UTF-16 code unit as in
/// [InlineSpan.toPlainText], a placeholder for each widget.
final class _ParagraphText {
  _ParagraphText._(this.text, this.keptLines, this.keptWhole);

  factory _ParagraphText.of(
    List<InlineSpan> spans, {
    required bool Function(InlineSpan span) keepsLines,
    required bool Function(InlineSpan span) keepsWhole,
  }) {
    final buffer = StringBuffer();
    final keptLines = <bool>[];
    final keptWhole = <bool>[];
    void add(String s, {required bool lines, required bool whole}) {
      buffer.write(s);
      for (var i = 0; i < s.length; i++) {
        keptLines.add(lines);
        keptWhole.add(whole);
      }
    }

    void visit(InlineSpan span, {required bool lines, required bool whole}) {
      final spanLines = lines || keepsLines(span);
      final spanWhole = whole || keepsWhole(span);
      switch (span) {
        case TextSpan(:final text, :final children):
          if (text != null) {
            add(text, lines: spanLines, whole: spanWhole);
          }
          for (final child in children ?? const <InlineSpan>[]) {
            visit(child, lines: spanLines, whole: spanWhole);
          }
        case PlaceholderSpan():
          add(objectReplacementChar, lines: spanLines, whole: spanWhole);
        default:
          // Not built by the html renderer: its text counts, it is not cut.
          add(span.toPlainText(includeSemanticsLabels: false), lines: spanLines, whole: true);
      }
    }

    for (final span in spans) {
      visit(span, lines: false, whole: false);
    }
    return _ParagraphText._(buffer.toString(), keptLines, keptWhole);
  }

  final String text;

  /// Each character is in preformatted text.
  final List<bool> keptLines;

  /// Each character is in a list item or a heading.
  final List<bool> keptWhole;

  static final _visible = RegExp(r'[^\s￼]');

  /// Offsets of the characters a gap goes before: at the line breaks between paragraphs when there is [spacing], after
  /// the ends of sentences of long paragraphs when [splitLong] (without spacing, the gap is only a line break).
  Set<int> gaps({required bool spacing, required bool splitLong}) {
    // Lines of the text: [start, end) between line breaks.
    final lines = <(int, int)>[];
    var start = 0;
    for (var i = 0; i <= text.length; i++) {
      if (i == text.length || text[i] == '\n') {
        lines.add((start, i));
        start = i + 1;
      }
    }
    bool any(List<bool> flags, (int, int) line) {
      for (var i = line.$1; i < line.$2; i++) {
        if (flags[i]) {
          return true;
        }
      }
      return false;
    }

    final isParagraph = [
      for (final line in lines)
        _visible.hasMatch(text.substring(line.$1, line.$2)) && !any(keptLines, line) && !_hasNewlineInKept(line),
    ];
    final widths = [for (final line in lines) textWidth(text.substring(line.$1, line.$2))];
    final gaps = <int>{};
    for (var i = 1; spacing && i < lines.length; i++) {
      if (isParagraph[i - 1] && isParagraph[i] && (widths[i - 1] > shortLineWidth || widths[i] > shortLineWidth)) {
        // Before the first character of the paragraph after the line break.
        gaps.add(lines[i].$1);
      }
    }
    if (splitLong) {
      for (final (i, line) in lines.indexed) {
        if (!isParagraph[i] || widths[i] <= longParagraphWidth || any(keptWhole, line)) {
          continue;
        }
        for (final cut in sentenceBreaks(text.substring(line.$1, line.$2))) {
          gaps.add(line.$1 + cut);
        }
      }
    }
    return gaps;
  }

  /// The line break ending [line] is preformatted text: the line is part of a `<pre>`.
  bool _hasNewlineInKept((int, int) line) => line.$2 < text.length && keptLines[line.$2];
}

/// Puts a [ParagraphGap] before each of [gaps] (offsets in the text of the spans) into the spans.
final class _GapInserter {
  _GapInserter(this.gaps, this.height);

  final Set<int> gaps;
  final double height;

  /// Offset of the next character in the text of the spans.
  int _offset = 0;

  List<InlineSpan> insert(List<InlineSpan> spans) => [for (final span in spans) _insert(span)];

  /// The font of the gap's line is tiny: the line is as tall as the gap, not as a line of text with nothing in it.
  WidgetSpan _gap() => WidgetSpan(style: _gapStyle, child: ParagraphGap(height));

  static const _gapStyle = TextStyle(fontSize: 1, height: 1);

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
              if (gaps.contains(i)) i - start,
          ];
          if (cuts.isNotEmpty && span.semanticsLabel == null) {
            pieces = [];
            var from = 0;
            for (final cut in cuts) {
              pieces
                ..add(_piece(span, text.substring(from, cut)))
                ..add(_gap());
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

/// Whether [span] is a gap [layOutParagraphs] put in.
@visibleForTesting
bool isParagraphGap(InlineSpan span) => span is WidgetSpan && span.child is ParagraphGap;
