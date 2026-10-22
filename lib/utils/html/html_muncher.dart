import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart';
import 'package:tsdm_client/features/red_packet/widgets/red_packet_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
// The style the author gave a post: css, colors in the theme
import 'package:tsdm_client/utils/html/author_style.dart';
import 'package:tsdm_client/utils/html/cloudflare_email.dart';
import 'package:tsdm_client/utils/html/full_width_block.dart';
import 'package:tsdm_client/utils/html/media_card.dart';
import 'package:tsdm_client/utils/html/munch_options.dart';
// Netease card
import 'package:tsdm_client/utils/html/netease_card.dart';
// Newcomer card
import 'package:tsdm_client/utils/html/newcomer_report_card.dart';
// Line height and paragraphs of a post's content
import 'package:tsdm_client/utils/html/post_typography.dart';
// Review (post comment) parser
import 'package:tsdm_client/utils/html/review_parser.dart';
// Table
import 'package:tsdm_client/utils/html/table_width.dart';
import 'package:tsdm_client/utils/html/types.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
// Bounty answer card
import 'package:tsdm_client/widgets/card/bounty_answer_card.dart';
// Bounty card
import 'package:tsdm_client/widgets/card/bounty_card.dart';
// Code card
import 'package:tsdm_client/widgets/card/code_card.dart';
// Locked card
import 'package:tsdm_client/widgets/card/lock_card/locked_card.dart';
// Review card
import 'package:tsdm_client/widgets/card/review_card.dart';
// Spoiler card
import 'package:tsdm_client/widgets/card/spoiler_card.dart';
// Loading
import 'package:tsdm_client/widgets/network_indicator_image.dart';
// THIS CAN BE REMOVED
import 'package:tsdm_client/widgets/quoted_text.dart';
import 'package:tsdm_client/widgets/text_widget_span.dart';
import 'package:universal_html/html.dart' as uh;

/// Use the same span to append line break.
const emptySpan = TextSpan(text: '\n');

/// Whether a link to [url] in the content of a post has a mark before it (`Icons.link`, `Icons.email_outlined`): only
/// a link out of the forum, which the app does not open itself (a browser, the mail app does), and an email address.
///
/// The web page marks no link, it underlines them (`.t_f a`); a post's links are underlined in the app too. Before,
/// every link had the mark: a list of links to threads, a link in the middle of a sentence (`详见>活动总帖<`) read
/// broken by an icon at each. Outside a post (a notice, a message), links are not underlined and keep their marks.
bool postLinkHasMark(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null) {
    return false;
  }
  if (!uri.hasScheme && uri.hasAuthority) {
    // `//www.tsdm39.com/…`: on the scheme of the page.
    return !(Uri.tryParse('https:$trimmed')?.isForumHost ?? false);
  }
  return !uri.isForumOrRelative && uri.scheme.toLowerCase() != 'javascript';
}

/// Called with each element before it is munched, for tests: one throwing there checks that an element the muncher
/// fails on does not take the floor with it.
@visibleForTesting
void Function(uh.Element element)? debugBeforeMunchElement;

/// Step when elevation changes.
const _elevationStep = 0.2;

/// List type composes `<ol>` and `<ul>`
sealed class _ListType {}

/// `<ul>`: a disc before each item.
final class _ListUnordered extends _ListType {}

/// `[list=1]`, `[list=a]`, `[list=A]` (`<ul class="litype_1">` and so on): a number or a letter before each item.
final class _ListOrdered extends _ListType {
  /// Constructor.
  _ListOrdered(this.number, {this.letters = false, this.upperCase = false});

  /// Number in order.
  final int number;

  /// Letters (a, b, c…) instead of numbers.
  final bool letters;

  /// Capital letters.
  final bool upperCase;

  /// The mark of the item [number].
  String get mark {
    if (!letters) {
      return '$number';
    }
    // a…z, aa…az, ba… as a browser counts in letters.
    final buffer = StringBuffer();
    var n = number;
    while (n > 0) {
      n -= 1;
      buffer.write(String.fromCharCode((upperCase ? 0x41 : 0x61) + n % 26));
      n ~/= 26;
    }
    return buffer.toString().split('').reversed.join();
  }

  /// The list at the next item.
  _ListOrdered next() => _ListOrdered(number + 1, letters: letters, upperCase: upperCase);
}

/// `<ol>`: no mark, the forum's style sheet takes it off (`ol { list-style: none }`).
final class _ListUnmarked extends _ListType {}

/// Use an empty span.
// final null = WidgetSpan(child: Container());

/// Munch the html node [rootElement] and its children nodes into a flutter
/// widget.
///
/// Main entry of this package.
Widget munchElement(
  BuildContext context,
  uh.Element rootElement, {
  bool parseLockedWithPurchase = false,
  MunchOptions options = const MunchOptions(),
}) {
  final muncher = _Muncher(context, parseLockedWithPurchase: parseLockedWithPurchase, options: options)
    .._root = rootElement;
  muncher._sheets = AuthorStyleSheets.of(rootElement, postContent: muncher.typography != null);

  // Undo Cloudflare's email obfuscation first, so addresses read and tap like the author wrote them.
  rewriteCloudflareEmails(rootElement);
  final munched = muncher._munch(rootElement);
  if (munched == null) {
    return const SizedBox.shrink();
  }
  // Remove trailing empty spaces.
  while (munched.lastOrNull == emptySpan) {
    munched.removeLast();
  }
  final ret = muncher._layOut(munched);

  // Alignment in this page requires a fixed max width that equals to website
  // page width.
  // Currently is 712.
  return ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: htmlContentMaxWidth),
    child: Text.rich(
      style: const TextStyle(
        // Set line height to none to fix gaps between rows only holding images. May cause unexpected overlap or narrow
        // row spacing between text lines.
        height: kTextHeightNone,
      ),
      TextSpan(children: ret),
    ),
  );
}

/// A background the text is on (`_MunchState.backgroundColorStack`, `_MunchState.blockBackgroundStack`): its `color`
/// as the author gave it (null: a picture, which the app does not show); the length of the color stack when it was
/// pushed (`colors`: a color pushed after it was given in its block); when it was pushed among all the backgrounds
/// (`order`).
typedef _Behind = ({Color? color, int colors, int order});

/// The style part of [_MunchState], see [_MunchState.save].
typedef _MunchStyle = ({
  bool bold,
  bool italic,
  bool underline,
  bool lineThrough,
  bool center,
  TextAlign? textAlign,
  String? tapUrl,
  List<Color> colorStack,
  List<_Behind> backgroundColorStack,
  List<_Behind> blockBackgroundStack,
  List<List<Shadow>> shadowStack,
  List<double> fontSizeStack,
  double? textIndent,
  bool tinyText,
  int? linkDepth,
  int? linkOrder,
  Color? linkColor,
  bool linkUnderline,
  double elevation,
});

/// The whole state of [_Muncher], see [_Muncher._snapshot].
typedef _MunchSnapshot = ({
  _MunchStyle style,
  ({bool atLineStart, bool pendingSpace, bool pendingBreak}) line,
  double? pendingIndent,
  List<_ListType> lists,
  int tableDepth,
  bool inPre,
  bool inDiv,
  bool wrapInWord,
  bool headingBrNodePassed,
});

/// State of [_Muncher].
class _MunchState {
  /// State of munching html document.
  _MunchState();

  /// Use bold font.
  bool bold = false;

  /// Use italic font.
  bool italic = false;

  /// User underline.
  bool underline = false;

  /// Add line strike.
  bool lineThrough = false;

  /// Align span in center.
  bool center = false;

  /// Flag indicating current node's is inside a `<pre>` node or not.
  /// When in a `<pre>`, all text should be treated as raw text.
  bool inPre = false;

  /// Flag indicate current node inside a div or not.
  ///
  /// Make sure one line break when (nested or not) div ended.
  bool inDiv = false;

  /// Nothing has been put on the current line yet: the start of the content, of a block laid out on its own (a
  /// quote, a cell, a centered block…), or right after a line break. White space here is dropped, as the web page
  /// drops the white space at the start of a line. Also set right after a space put on its own for collapsed white
  /// space (before a link), which white space that follows collapses into.
  bool atLineStart = true;

  /// The text put last on the current line ended with collapsible white space (or white space alone followed it):
  /// one space goes before the next text or inline image on this line, none if the line ends first. The web page
  /// collapses such a run, across elements, into one space and drops it at the end of a line.
  bool pendingSpace = false;

  /// A block ended (a paragraph) without a line break of its own: the next content on this line starts a new line,
  /// as after a block of the web page. A block starting there takes this break instead of adding one more; a `<br>`
  /// right after the block is a line of its own after it, a blank line as on the web page.
  bool pendingBreak = false;

  /// Flag indicating has already munched all heading br nodes.
  ///
  /// Use this flag to filter all br node ahead of the real content to avoid
  /// large white space ahead of post text data.
  bool headingBrNodePassed = false;

  /// Text alignment.
  TextAlign? textAlign;

  /// Record the elevation.
  ///
  /// In some nested cards, elevation can be more than 1.
  ///
  /// Default is 0, increase when building in cards.
  double elevation = -_elevationStep;

  /// Number of tables (not the one-row tables that only wrap something) the node being munched is in.
  int tableDepth = 0;

  /// Flag indicating whether we should wrap line in word.
  ///
  /// Default, flutter only wrap line on word boundaries but when we using
  /// in some special case (e.g. url) we want to wrap the line inside words.
  ///
  /// Turn on this flag in such situation.
  ///
  /// THIS OPTION IS NOT IGNORED, prepare for copy content feature.
  bool wrapInWord = false;

  /// Url link to tap.
  ///
  /// [TapGestureRecognizer] not works in nested [TextSpan].
  ///
  /// As a workaround.
  String? tapUrl;

  /// All colors currently used, as the author gave them: they are shown in the theme when the text is put
  /// ([AuthorColors.text]), where what the text is on is known.
  ///
  /// Use as a stack because only the latest font works on font.
  final colorStack = <Color>[];

  /// All background colors of text currently used (`<span style="background-color: …">`), as the author gave them.
  ///
  /// Use as a stack because only the latest font works on font.
  final backgroundColorStack = <_Behind>[];

  /// The backgrounds of the blocks the text is in (`<div style="background-color: …">`, `<table bgcolor="…">`), as the
  /// author gave them; a picture, which the app does not show, has none. What a text color is shown on.
  final blockBackgroundStack = <_Behind>[];

  /// The shadows of the text (`text-shadow`), empty for none.
  final shadowStack = <List<Shadow>>[];

  /// All font sizes currently used.
  ///
  /// Use as a stack because only the latest size works on font.
  final fontSizeStack = <double>[];

  /// The indent of the first line of the blocks (`text-indent`, inherited as css does), in pixels.
  double? textIndent;

  /// The author made the text too small to be seen (`font-size: 0`, `1px`): its text is hidden, as on the web page,
  /// where a size of 0 also takes the white space between inline blocks away. What is in it with a size of its own
  /// shows, so do its images and cards. Before, such text was shown at the smallest size.
  bool tinyText = false;

  /// The indent the next thing put starts with: the first line of a block is still to come ([textIndent]).
  double? pendingIndent;

  /// Length of [colorStack] when the link the text is in started; null out of a link. A color pushed before the link
  /// does not color it (`<font color="red"><a>…</a></font>` is a link in the link's color on the web page: the
  /// forum's style sheet colors every link, `.t_f a`); one pushed in it does.
  int? linkDepth;

  /// The count of backgrounds pushed when the link the text is in started (`_Behind.order`): a background pushed by
  /// then is around the link.
  int? linkOrder;

  /// The color the author gave the link itself (`<a style="color: …">`, `.xg1 a`), the theme's when null.
  Color? linkColor;

  /// The link the text is in is underlined, as on the web page (`.t_f a { text-decoration: underline }`).
  bool linkUnderline = false;

  // TODO: Handle indent level when list type nested.
  /// All munching state of list types.
  ///
  /// Can be nested.
  final listStack = <_ListType>[];

  /// The style in use now, to put back with [restore]. A copy: what is munched meanwhile does not change it.
  ///
  /// Before, the state kept a reference to itself and the restoring was skipped (its check was the wrong way round),
  /// so nothing was ever put back.
  _MunchStyle save() => (
    bold: bold,
    italic: italic,
    underline: underline,
    lineThrough: lineThrough,
    center: center,
    textAlign: textAlign,
    tapUrl: tapUrl,
    colorStack: List.of(colorStack),
    backgroundColorStack: List.of(backgroundColorStack),
    blockBackgroundStack: List.of(blockBackgroundStack),
    shadowStack: List.of(shadowStack),
    fontSizeStack: List.of(fontSizeStack),
    textIndent: textIndent,
    tinyText: tinyText,
    linkDepth: linkDepth,
    linkOrder: linkOrder,
    linkColor: linkColor,
    linkUnderline: linkUnderline,
    elevation: elevation,
  );

  /// Put back the style [saved] by [save].
  void restore(_MunchStyle saved) {
    bold = saved.bold;
    italic = saved.italic;
    underline = saved.underline;
    lineThrough = saved.lineThrough;
    center = saved.center;
    textAlign = saved.textAlign;
    tapUrl = saved.tapUrl;
    colorStack
      ..clear()
      ..addAll(saved.colorStack);
    backgroundColorStack
      ..clear()
      ..addAll(saved.backgroundColorStack);
    blockBackgroundStack
      ..clear()
      ..addAll(saved.blockBackgroundStack);
    shadowStack
      ..clear()
      ..addAll(saved.shadowStack);
    fontSizeStack
      ..clear()
      ..addAll(saved.fontSizeStack);
    textIndent = saved.textIndent;
    tinyText = saved.tinyText;
    linkDepth = saved.linkDepth;
    linkOrder = saved.linkOrder;
    linkColor = saved.linkColor;
    linkUnderline = saved.linkUnderline;
    elevation = saved.elevation;
  }

  @override
  String toString() {
    return 'MunchState {bold=$bold, underline=$underline, '
        'lineThrough=$lineThrough, color=$colorStack}';
  }
}

/// Munch html nodes into flutter widgets.
final class _Muncher with LoggerMixin {
  /// Constructor.
  _Muncher(this.context, {required this.parseLockedWithPurchase, required this.options})
    : typography = PostTypographyScope.maybeOf(context);

  /// Context to build widget when munching.
  final BuildContext context;

  /// How a post's content is laid out (line height, paragraphs); null for html that is not a post's content (a notice,
  /// a message, a profile), laid out as the body text.
  final PostTypography? typography;

  /// Text spans of preformatted text (`<pre>`): their lines are kept as they are ([layOutParagraphs]).
  final _keptLines = Set<InlineSpan>.identity();

  /// Text spans of list items and headings: never cut into paragraphs ([layOutParagraphs]).
  final _keptWhole = Set<InlineSpan>.identity();

  /// Number of headings the node being munched is in.
  int _headingDepth = 0;

  //////// Configs ////////
  bool parseLockedWithPurchase;

  /// Munch state to use when munching.
  final _MunchState state = _MunchState();

  /// Additional options control injected by caller.
  final MunchOptions options;

  /// The element munched by [munchElement], where the folds a post made itself are looked for ([_folds]).
  uh.Element? _root;

  /// Map to store div classes and corresponding munch functions.
  Map<String, List<InlineSpan>? Function(uh.Element)>? _divMap;

  /// Regex to match netease player iframe.
  final _neteasePlayerRe = RegExp(r'//music\.163\.com/outchain/player\?.*id=(?<id>\d+).*');

  /// The style sheets of the html: the forum's and its own `<style>` ([AuthorStyleSheets.of]).
  AuthorStyleSheets _sheets = AuthorStyleSheets.empty;

  /// [_sheets] matched to the elements of the html.
  late final AuthorStyler _styler = _sheets.styler(_root ?? uh.DivElement());

  /// Count of the backgrounds pushed so far, see `_Behind.order`.
  int _behindCount = 0;

  /// A background of [color] pushed now.
  _Behind _behind(Color? color) => (color: color, colors: state.colorStack.length, order: ++_behindCount);

  /// The style the author gave each element munched, see [_styleOf].
  final _styles = Map<uh.Element, AuthorStyle?>.identity();

  /// The font size around each element munched, before it gave itself a size of its own (a heading, `<small>`): what
  /// a size relative to the text around it (`1.2em`, `80%`) is relative to.
  final _outerFontSizes = Map<uh.Element, double>.identity();

  /// The link being munched ([_buildA]): its own color is the link's ([_MunchState.linkColor]).
  uh.Element? _link;

  /// How the author's colors are shown in the theme.
  late final _colors = AuthorColors(Theme.of(context));

  /// The size of the body text, what the sizes of the web page are scaled to.
  late final double _bodyFontSize = Theme.of(context).textTheme.bodyMedium?.fontSize ?? webPostFontSize;

  /// A css pixel of the web page's text in the app: the app's body text is to the web page's ([webPostFontSize]) as a
  /// size of the web page is to the app's.
  late final double _pixelScale = _bodyFontSize / webPostFontSize;

  /// The font size of the text being munched.
  double get _fontSize => state.fontSizeStack.lastOrNull ?? _bodyFontSize;

  /// [size] of the web page (`[size=3]`, `font-size: 16px`), in the app.
  double _appFontSize(double size) => size * _pixelScale;

  /// The style the author gave [element] (its `style`, the classes of the forum's style sheet, the rules of the html's
  /// `<style>`), null when none.
  ///
  /// A style that cannot be read (a value the parser chokes on) is no style: the element is shown as if it had none.
  AuthorStyle? _styleOf(uh.Element element) => _styles.putIfAbsent(element, () {
    try {
      return _styler.styleOf(element);
    } on Object catch (e, st) {
      error('failed to read the style of <${element.localName}>, leaving it out', e, st);
      return null;
    }
  });

  /// Elements laid out as blocks of their own whose first line takes the indent (`text-indent`).
  static const Set<String> _indentedElements = {
    'div',
    'p',
    'center',
    'td',
    'th',
    'li',
    'dd',
    'dt',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'blockquote',
    'pre',
    ..._plainBlockElements,
  };

  /// Elements whose background is the background of a block ([_munchStyledBlock], tables), not of their text.
  static const Set<String> _blockBackgroundElements = {
    'div',
    'p',
    'center',
    'table',
    'tbody',
    'thead',
    'tfoot',
    'tr',
    'td',
    'th',
    'ul',
    'ol',
    'li',
    'dl',
    'dd',
    'dt',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'blockquote',
    'pre',
    'hr',
    ..._plainBlockElements,
  };

  /// Run [munch], munching what [element] holds, in the style its author gave it ([_styleOf]): the color, size,
  /// weight, style, decoration and shadows of its text, the background of its text when it is in a line. A block
  /// starts its first line with the indent it has ([_MunchState.textIndent]). The background and the alignment of a
  /// block are the block's builder's ([_munchStyledBlock]).
  ///
  /// Taken after what its tag gives it (the size of a heading, the bold of `<b>`, the color of `<font color>`), as the
  /// web page takes the author's css after the tag's defaults and the presentational attributes.
  T _styled<T>(uh.Element element, T Function() munch) {
    final style = _styleOf(element);
    final block = _indentedElements.contains(_nameOf(element));
    if (style == null) {
      if (!block) {
        return munch();
      }
      state.pendingIndent = state.textIndent;
      try {
        return munch();
      } finally {
        state.pendingIndent = null;
      }
    }
    final saved = state.save();
    try {
      _applyStyle(element, style);
    } on Object catch (e, st) {
      // A style the app cannot apply is no style.
      error('failed to apply the style of <${element.localName}>, leaving it out', e, st);
      state.restore(saved);
    }
    if (block) {
      state.pendingIndent = state.textIndent;
    }
    try {
      return munch();
    } finally {
      state.restore(saved);
      if (block) {
        // The first line of the block is over: what follows it in the block around it is no first line.
        state.pendingIndent = null;
      }
    }
  }

  /// Put the [style] of [element] in the state: what its text is shown with.
  void _applyStyle(uh.Element element, AuthorStyle style) {
    // The background first: the element's own color is given on it (see [_buildTextStyle]).
    if (style.background case final background? when !_blockBackgroundElements.contains(_nameOf(element))) {
      state.backgroundColorStack.add(_behind(background));
    }
    if (style.fontSize case final size?) {
      // A size relative to a hidden one is hidden too: it is taken from the size the text really has.
      final outer = state.tinyText ? 0.0 : _outerFontSizes[element] ?? _fontSize;
      final px = size.em ? size.value * outer : _appFontSize(size.value);
      state
        ..tinyText = px <= _appFontSize(_hiddenFontSize)
        ..fontSizeStack.add(px.clamp(_appFontSize(minWebFontSize), _appFontSize(maxWebFontSize)));
    }
    if (style.color case final color?) {
      if (identical(element, _link)) {
        state.linkColor = color;
      } else {
        state.colorStack.add(color);
      }
    }
    if (style.bold case final bold?) {
      state.bold = bold;
    }
    if (style.italic case final italic?) {
      state.italic = italic;
    }
    if (style.underline) {
      state.underline = true;
    }
    if (style.lineThrough) {
      state.lineThrough = true;
    }
    if (style.noDecoration && identical(element, _link)) {
      state.linkUnderline = false;
    }
    if (style.textShadows case final shadows?) {
      final size = _fontSize;
      final color = _textColorNow();
      state.shadowStack.add([for (final s in shadows) s.resolve(size, _pixelScale, color)]);
    }
    if (style.textIndent case final indent?) {
      final px = indent.resolve(_fontSize, pixelScale: _pixelScale);
      state.textIndent = px > 0 ? math.min(px, _maxTextIndent * _fontSize) : null;
    }
  }

  /// Largest first line indent, in font sizes: a larger one (`text-indent: 999px`, to hide the text) would push the
  /// text out of a phone's screen.
  static const _maxTextIndent = 8;

  /// The color of the text munched now, as shown: what a shadow without a color of its own takes (`currentColor`).
  Color _textColorNow() =>
      _buildTextStyle()?.color ??
      Theme.of(context).textTheme.bodyMedium?.color ??
      Theme.of(context).colorScheme.onSurface;

  /// The indent the first line of a block starts with ([_MunchState.pendingIndent]), taken: null when there is none.
  InlineSpan? _takeIndent() {
    final indent = state.pendingIndent;
    if (indent == null || typography == null) {
      return null;
    }
    state.pendingIndent = null;
    return WidgetSpan(child: SizedBox(width: indent));
  }

  List<InlineSpan>? _munch(uh.Element rootElement) => _styled(rootElement, () => _munchContent(rootElement));

  /// A font size of the web page this small (css pixels) hides the text, see [_MunchState.tinyText].
  static const _hiddenFontSize = 1.0;

  /// What [rootElement] holds, munched.
  List<InlineSpan>? _munchContent(uh.Element rootElement) {
    final spanList = <InlineSpan>[];

    for (final node in rootElement.nodes) {
      final subSpanList = munchNode(node);
      if (subSpanList != null) {
        spanList.addAll(subSpanList);
      }
    }
    if (spanList.isEmpty) {
      // Not intend to happen.
      return null;
    }
    // A banner can be cut into adjacent linked images. Keep an image-only
    // strip together and scale the whole strip to the available width (#36).
    // Explicit breaks and mixed text retain their normal wrapping behavior.
    // The space the white space between the slices collapses to is not kept: the slices stay side by side.
    final nodes = rootElement.nodes.where((node) => node is! uh.Text || node.text!.trim().isNotEmpty).toList();
    if (nodes.length > 1 &&
        nodes.every(_isInlineImage) &&
        spanList.every((span) => span is WidgetSpan || _isBlankTextSpan(span))) {
      return [
        WidgetSpan(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: spanList.whereType<WidgetSpan>().map((span) => span.child).toList(),
            ),
          ),
        ),
      ];
    }
    return spanList;
  }

  /// A span of nothing but white space, without children.
  static bool _isBlankTextSpan(InlineSpan span) =>
      span is TextSpan && span.children == null && (span.text?.trim().isEmpty ?? true);

  /// Elements laid out inline as one piece (an image, a code card, a superscript…): the space collapsed before them
  /// goes before them, as before a text.
  static const _atomicInlineElements = {'img', 'sup', 'code', 'iframe', 'embed', 'object', 'video', 'audio', 'ruby'};

  /// Whether [spans] end the line: their text ends with a line break.
  static bool _endsLine(List<InlineSpan> spans) => switch (spans.lastOrNull) {
    final TextSpan span => span.toPlainText(includeSemanticsLabels: false).endsWith('\n'),
    _ => false,
  };

  /// Whether [spans] start with a line break.
  static bool _startsLine(List<InlineSpan> spans) => switch (spans.firstOrNull) {
    final TextSpan span => span.toPlainText(includeSemanticsLabels: false).startsWith('\n'),
    _ => false,
  };

  /// Elements that place the line break a block before them left ([_MunchState.pendingBreak]) themselves: before
  /// what they put first, or by starting a line of their own.
  static const _breakHandlingElements = <String>{
    'p',
    'div',
    'center',
    'dd',
    'a',
    'li',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'hr',
    'dt',
    ..._plainBlockElements,
  };

  /// Blocks of the web page with nothing of their own to show: each starts a line of its own and ends its line, as a
  /// `<div>` does.
  static const _plainBlockElements = {
    'section',
    'article',
    'aside',
    'header',
    'footer',
    'main',
    'nav',
    'figure',
    'figcaption',
    'address',
    'caption',
    'fieldset',
    'legend',
    'hgroup',
    'summary',
  };

  /// What the web page does not show: scripts, styles, a form (a template's form, the poll's, is shown by the app's own
  /// card) and its fields, ruby parentheses (the ruby text is shown above its base), what is there for browsers
  /// without plugins or frames, and other things a browser never shows as text. A button, a text box and a choice
  /// box out of a form are shown as their text ([_buildElement]).
  static const _invisibleElements = {
    'script',
    'style',
    'noscript',
    'noembed',
    'noframes',
    'template',
    'head',
    'title',
    'meta',
    'link',
    'base',
    'form',
    'input',
    'option',
    'optgroup',
    'datalist',
    'rp',
    'param',
    'source',
    'track',
    'colgroup',
    'col',
    'map',
    'area',
    'canvas',
    'svg',
    'math',
    'dialog',
  };

  /// The text of a text node [raw] as the web page shows it at the current place of the line, null when it shows
  /// nothing there.
  ///
  /// White space is collapsed as HTML does it (`white-space: normal`): a run of spaces, tabs and line breaks (only
  /// these, a no-break space or an ideographic space is text) is one space, across elements; the space is dropped at
  /// the start of a line ([_MunchState.atLineStart]) and, kept as [_MunchState.pendingSpace] until the next text or
  /// inline image, at its end.
  String? _collapseText(String raw) {
    final text = raw.replaceAll(_htmlWhiteSpaceRe, ' ');
    final leading = text.startsWith(' ');
    final trailing = text.length > (leading ? 1 : 0) && text.endsWith(' ');
    final core = text.substring(leading ? 1 : 0, trailing ? text.length - 1 : text.length);
    if (core.isEmpty) {
      if (leading && !state.atLineStart) {
        state.pendingSpace = true;
      }
      return null;
    }
    final space = (leading || state.pendingSpace) && !state.atLineStart;
    state
      ..pendingSpace = trailing
      ..atLineStart = false;
    return space ? ' $core' : core;
  }

  /// Start a new line: what the content munched next puts first starts the line (a heading, a list item after its
  /// mark).
  void _startLine() {
    state
      ..atLineStart = true
      ..pendingSpace = false;
  }

  /// A line break was put: a new line starts, and the break a block left is taken.
  void _lineBroken() {
    _startLine();
    state.pendingBreak = false;
  }

  /// The state of the line, to put back when an element puts nothing after all.
  ({bool atLineStart, bool pendingSpace, bool pendingBreak}) _lineState() =>
      (atLineStart: state.atLineStart, pendingSpace: state.pendingSpace, pendingBreak: state.pendingBreak);

  void _restoreLine(({bool atLineStart, bool pendingSpace, bool pendingBreak}) line) {
    state
      ..atLineStart = line.atLineStart
      ..pendingSpace = line.pendingSpace
      ..pendingBreak = line.pendingBreak;
  }

  /// Run [munch] for content laid out in a rich text of its own (a quote, a spoiler, a cell, a centered block…): its
  /// first line starts with it and the white space at its end is dropped. The line around it is left as it was.
  T _munchOwnBlock<T>(T Function() munch) {
    final line = _lineState();
    _lineBroken();
    final ret = munch();
    _restoreLine(line);
    return ret;
  }

  /// Munch the block element [element] of the web page with [munch]: it starts a line of its own (a line break goes
  /// before it when the line holds something, or a block before it left one), its first line drops the white space
  /// it starts with. When it does not end its line itself and [deferBreak], what follows starts a new line
  /// ([_MunchState.pendingBreak]): a paragraph's text, unlike a `<div>`'s, does not end with a line break. Nothing
  /// changes when it puts nothing.
  List<InlineSpan>? _munchBlock(uh.Element element, List<InlineSpan>? Function() munch, {required bool deferBreak}) {
    final line = _lineState();
    final breakBefore = !state.atLineStart || state.pendingBreak;
    _lineBroken();
    final ret = munch();
    if (ret == null || ret.isEmpty) {
      _restoreLine(line);
      return ret;
    }
    if (deferBreak && !_endsLine(ret)) {
      _startLine();
      state.pendingBreak = true;
    }
    // A line break at its start is a line of the block, not the break before it: `<p><br /></p>` after a line is a
    // blank line on the web page (the empty paragraph between the paragraphs of a novel), it was taken for the break
    // before the paragraph and the blank line was lost.
    return breakBefore && (!_startsLine(ret) || (_firstIsLineBreak(element) ?? false)) ? [emptySpan, ...ret] : ret;
  }

  /// [spans], ending their line: a line break after them unless they end with one. Null or empty stays so.
  static List<InlineSpan>? _endingLine(List<InlineSpan>? spans) =>
      spans == null || spans.isEmpty || _endsLine(spans) ? spans : [...spans, emptySpan];

  /// Inline elements whose content [_firstIsLineBreak] looks into.
  static const _inlineElements = {
    'span',
    'font',
    'strong',
    'b',
    'i',
    'u',
    'em',
    'a',
    's',
    'strike',
    'del',
    'ins',
    'small',
    'big',
    'sub',
    'sup',
    'label',
    'cite',
  };

  /// The name of [element] to munch it by: its local name, the whole name of an element with a prefix. The parser
  /// gives `<o:p>` of a document pasted from Word the local name `p`, which is no paragraph on the web page.
  static String _nameOf(uh.Element element) {
    final tagName = element.tagName;
    return tagName.contains(':') ? tagName.toLowerCase() : element.localName;
  }

  /// Whether [element] is not shown on the web page: hidden by its style (`display: none`, also written without the
  /// space: the jammer text some posts hide in `<span style="display:none">` was shown; `visibility: hidden`), by the
  /// `hidden` attribute, or the forum's jammer text (`<font class="jammer">`, which the style sheet paints white in a
  /// small size on the white page).
  static bool _isHidden(uh.Element element) =>
      element.attributes.containsKey('hidden') ||
      element.classes.contains('jammer') ||
      _hiddenStyleRe.hasMatch(element.attributes['style'] ?? '');

  static final _hiddenStyleRe = RegExp(
    r'(^|;)\s*(display\s*:\s*none|visibility\s*:\s*hidden)\b',
    caseSensitive: false,
  );

  /// The state of the muncher, to put back with [_restore] when munching an element failed half way.
  _MunchSnapshot _snapshot() => (
    style: state.save(),
    line: _lineState(),
    pendingIndent: state.pendingIndent,
    lists: List.of(state.listStack),
    tableDepth: state.tableDepth,
    inPre: state.inPre,
    inDiv: state.inDiv,
    wrapInWord: state.wrapInWord,
    headingBrNodePassed: state.headingBrNodePassed,
  );

  void _restore(_MunchSnapshot snapshot) {
    state
      ..restore(snapshot.style)
      ..listStack.clear()
      ..listStack.addAll(snapshot.lists)
      ..tableDepth = snapshot.tableDepth
      ..inPre = snapshot.inPre
      ..inDiv = snapshot.inDiv
      ..wrapInWord = snapshot.wrapInWord
      ..headingBrNodePassed = snapshot.headingBrNodePassed
      ..pendingIndent = snapshot.pendingIndent;
    _restoreLine(snapshot.line);
  }

  /// The folds the post made itself, by the id of the hidden element: the element whose click shows it, its title.
  ///
  /// Posts written in html make folds of their own: an element with an id hidden by its style, shown by a click on
  /// another element (`<div onclick="document.getElementById('c1').style.display=…">▼ 展开</div>`, `$('c1')` too).
  /// Hidden like any hidden element, what they held could not be seen at all. The forum's popups (`.tip`, `*_menu`)
  /// and elements without an id (the jammer text) stay hidden.
  late final Map<String, ({uh.Element target, uh.Element title})> _folds = () {
    final root = _root;
    final folds = <String, ({uh.Element target, uh.Element title})>{};
    if (root == null) {
      return folds;
    }
    final hidden = <String, uh.Element>{};
    for (final e in root.querySelectorAll('[id]')) {
      if (_isHidden(e) && _canFold(e)) {
        hidden.putIfAbsent(e.id, () => e);
      }
    }
    if (hidden.isEmpty) {
      return folds;
    }
    for (final title in root.querySelectorAll('[onclick], a[href]')) {
      final code = '${title.attributes['onclick'] ?? ''} ${title.attributes['href'] ?? ''}';
      for (final match in _foldTargetRe.allMatches(code)) {
        final id = match.namedGroup('id')!;
        final target = hidden[id];
        // A title holding its fold is shown, it shows the fold too.
        if (target != null && !folds.containsKey(id) && !_holds(title, target)) {
          folds[id] = (target: target, title: title);
        }
      }
    }
    return folds;
  }();

  /// The titles of [_folds].
  late final Set<uh.Element> _foldTitles = {for (final fold in _folds.values) fold.title};

  static final _foldTargetRe = RegExp(r'''(?:getElementById|\$)\(\s*['"](?<id>[^'"]+)['"]\s*\)''');

  /// Whether the hidden [element] can be a fold of the post: it is none of the forum's popups.
  static bool _canFold(uh.Element element) =>
      element.id.isNotEmpty && !element.id.endsWith('_menu') && !element.classes.contains('tip');

  static bool _holds(uh.Element ancestor, uh.Element element) {
    for (uh.Node? node = element; node != null; node = node.parentNode) {
      if (identical(node, ancestor)) {
        return true;
      }
    }
    return false;
  }

  bool _isFoldTitle(uh.Element element) => element.attributes.isNotEmpty && _foldTitles.contains(element);

  /// A fold the post made itself ([_folds]), as a spoiler whose title is the text of the element that showed it; null
  /// for a hidden element that is no fold.
  List<InlineSpan>? _buildFold(uh.Element element) {
    final fold = element.id.isEmpty ? null : _folds[element.id];
    if (fold == null || !identical(fold.target, element)) {
      return null;
    }
    final title = fold.title;
    return _munchBlock(element, deferBreak: false, () {
      state.elevation += _elevationStep;
      final elevation = state.elevation;
      final content = _munchOwnBlock(() => _munch(element));
      state.elevation -= _elevationStep;
      if (content == null) {
        return null;
      }
      while (content.lastOrNull == emptySpan) {
        content.removeLast();
      }
      state.headingBrNodePassed = true;
      final text = _visibleText(title);
      return [
        textWidgetSpan(
          SpoilerCard(
            title: TextSpan(text: text.isEmpty ? context.t.spoilerCard.title : text),
            content: TextSpan(children: _layOut(content)),
            elevation: elevation,
          ),
        ),
        emptySpan,
      ];
    });
  }

  /// The text [element] shows, white space collapsed: what is hidden in it left out.
  static String _visibleText(uh.Element element) {
    final buffer = StringBuffer();
    void visit(uh.Node node) {
      for (final child in node.nodes) {
        if (child is uh.Element) {
          if (_isHidden(child) || _invisibleElements.contains(_nameOf(child))) {
            continue;
          }
          if (child.localName == 'br') {
            buffer.write(' ');
            continue;
          }
          visit(child);
        } else if (child.nodeType == uh.Node.TEXT_NODE) {
          buffer.write(child.text ?? '');
        }
      }
    }

    visit(element);
    return buffer.toString().replaceAll(_htmlWhiteSpaceRe, ' ').trim();
  }

  /// Whether the first thing [node] shows is a line break (`<br>`, also inside inline elements): true; something else:
  /// false; nothing: null.
  static bool? _firstIsLineBreak(uh.Node node) {
    for (final child in node.nodes) {
      if (child is uh.Element) {
        final name = _nameOf(child);
        if (name == 'br') {
          return true;
        }
        if (_invisibleElements.contains(name) || _isHidden(child)) {
          continue;
        }
        if (!_inlineElements.contains(name)) {
          return false;
        }
        final first = _firstIsLineBreak(child);
        if (first != null) {
          return first;
        }
      } else if (child.nodeType == uh.Node.TEXT_NODE) {
        if ((child.text ?? '').replaceAll(_htmlWhiteSpaceRe, '').isNotEmpty) {
          return false;
        }
      }
    }
    return null;
  }

  bool _isInlineImage(uh.Node node) =>
      node is uh.Element &&
      (node.localName == 'img' ||
          (node.localName == 'a' && node.nodes.length == 1 && node.children.singleOrNull?.localName == 'img'));

  /// Munch a [node] and its children.
  List<InlineSpan>? munchNode(uh.Node? node) {
    if (node == null) {
      // Reach end.
      return null;
    }
    switch (node.nodeType) {
      // Text node does not have children.
      case uh.Node.TEXT_NODE:
        {
          if (state.tinyText) {
            // Too small to be seen: neither the text nor its white space.
            return null;
          }
          // Mark already munched text, all heading br nodes were passed.

          String? text;
          // When inPre is true, current node is inside a `<pre>` node.
          // Should reserve the original style.
          if (state.inPre) {
            text = node.text;
            if (text != null && text.isNotEmpty) {
              state
                ..atLineStart = text.endsWith('\n')
                ..pendingSpace = false;
            }
          } else {
            text = _collapseText(node.text ?? '');
          }
          if (text == null || text.isEmpty) {
            return null;
          }
          // The first line of a block starts with its indent, after the line break a paragraph before it left.
          final indent = _takeIndent();
          final breakFirst = state.pendingBreak && indent != null;
          if (state.pendingBreak && !breakFirst) {
            // The first text after a paragraph starts a new line.
            text = '\n$text';
          }
          state.pendingBreak = false;

          // Attach url to open when `onTap`.
          GestureRecognizer? recognizer;
          if (state.tapUrl != null) {
            recognizer = _buildUrlRecognizer(state.tapUrl!);
          }
          state.headingBrNodePassed = true;

          // Ignore wrap text;
          // state.wrapInWord ? text?.split('').join('\u200B') : text;

          // TODO: Support text-shadow.
          List<InlineSpan> spans;
          final style = _buildTextStyle();
          if (recognizer == null && options.renderUrl && text.contains('://')) {
            // Bare urls in plain text (the forum does not link them in notices, e.g. the reason of a rating).
            spans = _linkifySpans(text, style);
          } else {
            spans = [TextSpan(text: text, recognizer: recognizer, style: style)];
          }
          if (indent != null) {
            spans = [if (breakFirst) TextSpan(text: '\n', style: style), indent, ...spans];
          }
          if (typography != null) {
            if (state.inPre) {
              _keptLines.addAll(spans);
            }
            if (state.listStack.isNotEmpty || _headingDepth > 0) {
              _keptWhole.addAll(spans);
            }
          }
          return spans;
        }

      case uh.Node.ELEMENT_NODE:
        {
          final element = node as uh.Element;
          final localName = _nameOf(element);

          // Skip invisible nodes, but a fold the post made itself (shown by a click on another element) and the
          // element shown as its title.
          if (_isHidden(element)) {
            return _buildFold(element);
          }
          if (_isFoldTitle(element)) {
            return null;
          }

          // A space collapsed before an element laid out as one piece goes before it ([_atomicInlineElements]).
          final spaceBefore = state.pendingSpace && !state.atLineStart && _atomicInlineElements.contains(localName);
          final spaceStyle = spaceBefore ? _buildTextStyle() : null;
          final breakBefore = state.pendingBreak && !_breakHandlingElements.contains(localName);

          // Parse according to element types. A piece of html the muncher cannot make sense of must not take the whole
          // floor with it (the error would leave a grey block in place of all of the floor's content): what it held is
          // munched as it is instead, the state of the muncher put back as it was before the element.
          // An element laid out as one piece at the start of a block's first line is indented as a whole, not the text
          // in it.
          final atomicIndentWidth = _atomicInlineElements.contains(localName) ? state.pendingIndent : null;
          final atomicIndent = atomicIndentWidth == null ? null : _takeIndent();
          final snapshot = _snapshot();
          _outerFontSizes[node] = _fontSize;
          List<InlineSpan>? span;
          try {
            debugBeforeMunchElement?.call(node);
            span = _buildElement(node, localName);
          } on Object catch (e, st) {
            error('failed to munch <$localName>, munching what it holds instead', e, st);
            _restore(snapshot);
            try {
              span = _munch(node);
            } on Object catch (e, st) {
              error('failed to munch what <$localName> holds, leaving it out', e, st);
              _restore(snapshot);
              span = null;
            }
          }
          if (localName == 'br') {
            // The first line of the block is over.
            state.pendingIndent = null;
          }
          if (span == null || span.isEmpty) {
            if (atomicIndent != null) {
              // Nothing put: the indent is still for what comes first.
              state.pendingIndent = atomicIndentWidth;
            }
            return span;
          }
          var ret = span;
          if (_atomicInlineElements.contains(localName)) {
            if (spaceBefore && state.pendingSpace) {
              ret = [TextSpan(text: ' ', style: spaceStyle), ...span];
            }
            if (atomicIndent != null) {
              ret = [atomicIndent, ...ret];
            }
            state
              ..atLineStart = false
              ..pendingSpace = false;
          }
          if (breakBefore && state.pendingBreak) {
            // Nothing in it took the break a paragraph before it left (a card, an image). A line break right after
            // the paragraph is a line of its own: the break goes before it, a blank line as on the web page.
            if (!_startsLine(ret) || localName == 'br') {
              ret = [emptySpan, ...ret];
            }
            state.pendingBreak = false;
          }
          if (_endsLine(ret)) {
            _lineBroken();
          }
          return ret;
        }
    }
    return null;
  }

  /// [node], an element named [localName] ([_nameOf]), by its kind.
  List<InlineSpan>? _buildElement(uh.Element node, String localName) => switch (localName) {
    'img' => _buildImg(node),
    'br' => state.headingBrNodePassed ? [emptySpan] : null,
    'font' => _buildFont(node),
    'strong' => _buildStrong(node),
    'u' || 'ins' => _buildUnderline(node),
    'strike' || 's' || 'del' => _buildLineThrough(node),
    'p' => _buildP(node),
    'span' => _buildSpan(node),
    'blockquote' => _buildBlockQuote(node),
    'div' => _munchDiv(node),
    'a' => _buildA(node),
    'tr' => _buildTr(node),
    'td' => _buildTd(node),
    'th' => _buildTh(node),
    'h1' => _buildH1(node),
    'h2' => _buildH2(node),
    'h3' => _buildH3(node),
    'h4' => _buildH4(node),
    'h5' => _munchHeading(node, FontSize.size2.value()),
    'h6' => _munchHeading(node, FontSize.size1.value()),
    'ul' || 'ol' => _buildList(node),
    'li' => _buildLi(node),
    'code' => _buildCode(node),
    'dl' => _buildDl(node),
    'b' => _buildB(node),
    'i' => _buildI(node),
    'hr' => _buildHr(node),
    'pre' => _buildPre(node),
    'details' => _buildDetails(node),
    'iframe' => _buildIframe(node),
    'embed' || 'object' || 'video' || 'audio' => _buildMedia(node),
    'script' => _buildScriptPlayer(node),
    // The text a button, a text box (as written, its lines kept) and a choice box (the option chosen) show on the
    // web page; nothing to press or type in here.
    'button' => _munch(node),
    'textarea' => _buildPre(node),
    'select' => _buildSelect(node),
    'table' when node.classes.contains('cgtl') => _buildNewcomerReport(node),
    'table' => _buildTable(node),
    'sup' => _buildSup(node),
    'dt' => _buildDt(node),
    'dd' => _buildDd(node),
    'small' => _munchScaled(node, _smallerFontScale),
    'big' => _munchScaled(node, _largerFontScale),
    'ruby' => _buildRuby(node),
    'center' => _munchBlock(
      node,
      () => _munchStyledBlock(node, _munch, defaultAlign: TextAlign.center),
      deferBreak: true,
    ),
    String() when _plainBlockElements.contains(localName) => _munchBlock(
      node,
      deferBreak: false,
      () => _endingLine(_munchStyledBlock(node, _munch)),
    ),
    String() when _invisibleElements.contains(localName) => null,
    // Anything else (`<em>`, `<cite>`, `<label>`, `<abbr>`, `<o:p>` of a pasted Word document, `<marquee>`,
    // the forum's `<ignore_js_op>`, an element the muncher does not know yet) shows its content as the web
    // page does. Before, an element the muncher did not know was dropped with all its text.
    String() => _munch(node),
  };

  List<InlineSpan>? _buildImg(uh.Element element) {
    // Discuz X5 lazy loads some images with `data-src` and attachment images only have the `file` attribute, the
    // latter one is handled in `imageUrl()`.
    final dataSrc = element.attributes['data-src'];
    final url = (dataSrc != null && dataSrc.isNotEmpty) ? dataSrc.prependHost() : element.imageUrl();
    if (url == null) {
      return null;
    }
    state.headingBrNodePassed = true;
    final hrefUrl = state.tapUrl;
    final imgWidth = element.attributes['width']?.parseToInt()?.toDouble();
    final imgHeight = element.attributes['height']?.parseToInt()?.toDouble();

    // Show a button instead of the original image.
    if (tmpImpellerWorkaroundUrls.contains(url)) {
      return [
        WidgetSpan(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 24, minWidth: 24, maxHeight: 24, minHeight: 24),
            // Usually in a quote card: its tooltip follows the text scale there too.
            child: OverlayTextScale(
              child: IconButton(
                icon: Icon(Icons.navigate_before_outlined, color: Theme.of(context).colorScheme.tertiary),
                // Constrains size to fit line height.
                constraints: const BoxConstraints(maxWidth: 24, minWidth: 24, maxHeight: 24, minHeight: 24),
                padding: EdgeInsets.zero,
                tooltip: context.t.workaroundRedirect,
                onPressed: hrefUrl != null ? () async => context.dispatchAsUrl(hrefUrl) : null,
              ),
            ),
          ),
        ),
      ];
    }

    final Widget image = GestureDetector(
      onTap: () async => showImageActionBottomSheet(context: context, imageUrl: url, hrefUrl: hrefUrl),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: imgWidth ?? double.infinity, maxHeight: imgHeight ?? double.infinity),
        child: NetworkIndicatorImage(url),
      ),
    );
    // A table narrowed to the screen keeps it at least a thumbnail (see [PostTableImage]).
    return [WidgetSpan(child: state.tableDepth > 0 ? PostTableImage(child: image) : image)];
  }

  /// `<font>`: the color and the size of its attributes; its `style` ([_styled]) over them. Its `face` is not taken:
  /// the app has none of the fonts posts name.
  List<InlineSpan>? _buildFont(uh.Element element) {
    final hasColor = _tryPushColor(element);
    final hasFontSize = _tryPushFontSize(element);
    final ret = _munch(element);
    if (hasColor) {
      state.colorStack.removeLast();
    }
    if (hasFontSize) {
      state.fontSizeStack.removeLast();
    }
    return ret;
  }

  List<InlineSpan>? _buildStrong(uh.Element element) {
    final origBold = state.bold;
    state.bold = true;
    final ret = _munch(element);
    state.bold = origBold;
    return ret;
  }

  List<InlineSpan>? _buildUnderline(uh.Element element) {
    final origUnderline = state.underline;
    state.underline = true;
    final ret = _munch(element);
    state.underline = origUnderline;
    return ret;
  }

  List<InlineSpan>? _buildLineThrough(uh.Element element) {
    final origThrough = state.lineThrough;
    state.lineThrough = true;
    final ret = _munch(element);
    state.lineThrough = origThrough;
    return ret;
  }

  /// Text alignment carried by the `align` attribute of a block element.
  ///
  /// `[align=center]` in a post becomes `<div align="center">` (`<p align="center">` in some templates), the same
  /// attribute the web page reads to align that block.
  static TextAlign? _blockAlign(uh.Element element) => switch (element.attributes['align']?.trim().toLowerCase()) {
    'left' => TextAlign.left,
    'center' => TextAlign.center,
    'right' => TextAlign.right,
    _ => null,
  };

  /// The background the author gave the block [element] with [style]: its style's (`background-color`, a color in
  /// `background`), else its `bgcolor` (a table, a row, a cell: `[table=98%,pink]`). Its color is null when it is a
  /// picture (`background: url(…)`, a gradient), which the app does not show. Null when it has none.
  ({Color? color})? _blockBackgroundOf(uh.Element element, AuthorStyle? style) {
    if (style?.background case final color?) {
      return (color: color);
    }
    if (parseLegacyColor(element.attributes['bgcolor']) case final color?) {
      return (color: color);
    }
    if ((style?.backgroundPicture ?? false) || (element.attributes['background']?.trim().isNotEmpty ?? false)) {
      return (color: null);
    }
    return null;
  }

  /// The alignment the style of [element] gives its lines, a justified one as one aligned left (see
  /// [_munchStyledBlock]).
  TextAlign? _styleAlign(uh.Element element) => switch (_styleOf(element)?.textAlign) {
    TextAlign.justify => TextAlign.left,
    final align => align,
  };

  /// Munch the block [element] with [munch]: its lines aligned as its style or its `align` attribute say
  /// ([defaultAlign] otherwise: `<center>`), on the background its author gave it ([_blockBackgroundOf]).
  List<InlineSpan>? _munchStyledBlock(
    uh.Element element,
    List<InlineSpan>? Function(uh.Element element) munch, {
    TextAlign? defaultAlign,
  }) {
    final style = _styleOf(element);
    // A justified block is laid out as a block aligned left: a block of its own would lose the paragraph spacing
    // around it, for lines that hardly move on a phone.
    final styleAlign = _styleAlign(element);
    final TextAlign? align;
    if (styleAlign != null) {
      // The alignment the block has already (`text-align: left` on every paragraph pasted from Word) is not a block
      // of its own.
      align = styleAlign == (state.textAlign ?? TextAlign.left) ? null : styleAlign;
    } else {
      align = _blockAlign(element) ?? defaultAlign;
    }
    return _munchAligned(element, align, munch, background: _blockBackgroundOf(element, style));
  }

  /// Munch [element] with [munch] and lay the result out with [align], on [background].
  ///
  /// Alignment requires the whole rendered page to a fixed max width that equals to website page, otherwise the result
  /// differs from the web page for a "center" or "right" alignment.
  ///
  /// Text align only has effect on the [RichText]'s children, not its children's children, so the spans are wrapped
  /// in a full-width [Text.rich] carrying the alignment; `state.textAlign` holds the alignment while munching so
  /// builders creating their own rich text can apply it too.
  ///
  /// A block with a background is a [PostBlockBackground] of the whole width, its text in it. Before, the background
  /// of a block (`<div style="background-color: pink">`, `<table bgcolor="wheat">`, the blocks of an activity's rules)
  /// was not shown at all. Without an alignment and a background shown (a picture, the white of the page), the
  /// content stays in the lines around it.
  List<InlineSpan>? _munchAligned(
    uh.Element element,
    TextAlign? align,
    List<InlineSpan>? Function(uh.Element element) munch, {
    ({Color? color})? background,
  }) {
    final shown = background?.color == null ? null : _colors.background(background!.color!);
    // A block with a background in another one: the outer block has the space around the text already.
    final nested = state.blockBackgroundStack.any((e) => e.color != null && _colors.background(e.color!) != null);
    if (background != null) {
      // What the text is on: its colors are shown on it ([AuthorColors.text]).
      state.blockBackgroundStack.add(_behind(background.color));
    }
    final origAlign = state.textAlign;
    try {
      if (align == null && shown == null) {
        return munch(element);
      }
      state.textAlign = align ?? origAlign;
      final ret = _munchOwnBlock(() => munch(element));
      if (ret == null) {
        return null;
      }
      // The block takes the whole width: what follows starts a line.
      _startLine();
      // The line break its content ends with (`[align=center]text<br />[/align]`) ends its last line, it does not add
      // an empty line below it.
      final content = _withoutTrailingLineBreak(ret)!;
      // A block with a background in an aligned one is aligned too.
      Widget block = Text.rich(TextSpan(children: _layOut(content)), textAlign: align ?? origAlign);
      if (shown != null) {
        block = PostBlockBackground(
          color: shown,
          padding: nested ? PostBlockBackground.nestedPadding : PostBlockBackground.defaultPadding,
          child: block,
        );
      }
      return [textWidgetSpan(FullWidthBlock(child: block))];
    } finally {
      state.textAlign = origAlign;
      if (background != null) {
        state.blockBackgroundStack.removeLast();
      }
    }
  }

  /// `<p>`, a block of the web page ([_munchBlock]): a line of its own, and what follows starts a new line. A `<br>`
  /// right after it is a blank line, as on the web page (`[p]…[/p]` then a line break). Before, that `<br>` only took
  /// the paragraph's break, and an aligned paragraph's: the blank line was lost.
  List<InlineSpan>? _buildP(uh.Element element) =>
      _munchBlock(element, () => _munchStyledBlock(element, _munch), deferBreak: true);

  /// A `<span>` is inline: what follows goes on in the same line. Before, a line break was put after every span, which
  /// broke sentences in two (`<span>` around a word, the pasted text of another page). Its style is taken as any
  /// element's ([_styled]): before, only its color and a size of `1` to `7` were.
  List<InlineSpan>? _buildSpan(uh.Element element) => _munch(element);

  List<InlineSpan> _buildBlockQuote(uh.Element element) {
    // Try isolate the munch state inside quoted message.
    // Bug is that when the original quoted message "truncated" at unclosed
    // tags like "foo[s]bar...", the unclosed tag will affect all
    // following contents in current post, that is, all texts are marked with
    // line through.
    // This is unfixable after rendered into html because we do not know whether
    // a whole decoration tag (e.g. <strike>) contains the all following post
    // messages is user added or caused by the bug above. Here just try to save
    // and restore munch state to avoid potential issued about "styles inside
    // quoted blocks  affects outside main content".
    final style = state.save();
    final content = element.innerText.isEmpty ? null : _munchOwnBlock(() => _munchStyledBlock(element, _munch));
    state.restore(style);
    // A trailing line break inside the quote ends a line that is as tall as the line before it: when that line holds
    // a nested quote, every level doubled the height and left a blank block (#158). The website shows no such line.
    while (content != null &&
        (content.lastOrNull == emptySpan ||
            (content.lastOrNull is TextSpan &&
                (content.last as TextSpan).children == null &&
                ((content.last as TextSpan).text?.trim().isEmpty ?? false)))) {
      content.removeLast();
    }
    final span = content == null ? null : TextSpan(children: content);
    return [textWidgetSpan(QuotedText.rich(span)), emptySpan];
  }

  List<InlineSpan>? _munchDiv(uh.Element element) {
    final origInDiv = state.inDiv;
    _divMap ??= {
      'blockcode': _buildBlockCode,
      'locked': _buildLockedArea,
      'cm': _buildReview,
      'spoiler': _buildSpoiler,
      'rusld': _buildUnresolvedBounty,
      'rsld': _buildResolvedBounty,
      'rwdbst': _buildBountyBestAnswer,
      'hb-entry': _buildRedPacketEntry,
      'modact': _buildModerationNotice,
      'rcd-card': _buildNewcomerReportDiv,
      'bd-card': _buildNewcomerReportDiv,
    };

    if (element.classes.contains('media_container')) {
      return _buildMediaContainer(element);
    }

    // The popup markup of the forum's red packet plugin (envelope animation, password box, buttons) only works with
    // its javascript; it must not leak into the post as text.
    if (element.id == 'hb_mask') {
      return null;
    }

    // A block of the web page ([_munchBlock]): it starts a line of its own and ends its line.
    return _munchBlock(element, deferBreak: false, () {
      state.inDiv = true;
      // Find the first munch executor, use `_munch` if none found.
      final executor = _divMap!.entries.firstWhereOrNull((e) => element.classes.contains(e.key))?.value ?? _munch;
      // `[align=center]` is a `<div align="center">` around the aligned content (GitHub #47).
      final ret = _munchStyledBlock(element, executor);
      state.inDiv = origInDiv;

      if (ret != null && ret.isNotEmpty && ret.last != emptySpan) {
        ret.add(emptySpan);
      }
      return ret;
    });
  }

  List<InlineSpan>? _buildModerationNotice(uh.Element element) {
    final content = _munchOwnBlock(() => _munch(element));
    if (content == null) {
      return null;
    }
    final theme = Theme.of(context);
    // A block ([_munchDiv]): the line break before it goes there only when the line before it holds something.
    return [
      textWidgetSpan(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.manage_history_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
                sizedBoxW8H8,
                Expanded(
                  child: Text.rich(
                    TextSpan(children: content),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      emptySpan,
    ];
  }

  /// The red packet entry of the forum's `hongbao` plugin, `<div class="hb-entry" data-tid="...">` at the top of a
  /// post body, rendered as a [RedPacketCard] which talks to the plugin api when tapped.
  List<InlineSpan>? _buildRedPacketEntry(uh.Element element) {
    final entry = parseRedPacketEntry(element);
    if (entry == null) {
      return null;
    }
    state
      ..headingBrNodePassed = true
      ..elevation += _elevationStep;
    final ret = [textWidgetSpan(RedPacketCard(entry, elevation: state.elevation)), emptySpan];
    state.elevation -= _elevationStep;
    return ret;
  }

  List<InlineSpan>? _buildBlockCode(uh.Element element) {
    // Usually each line in the block code is ended with `<br>` tag, but rarely it does not.
    // To ensure each line is wrapped correctly, extract each line (contents in each `<div>`) and manually place them.
    //
    // Some code blocks do not have line number prefix, use the raw content inside if so.
    final liNodes = element.querySelectorAll('div ol li');
    final text = liNodes.isNotEmpty ? liNodes.map((e) => e.innerText.trimRight()).join('\n') : element.innerText.trim();
    state
      ..headingBrNodePassed = true
      ..elevation += _elevationStep;
    final ret = textWidgetSpan(CodeCard(code: text, elevation: state.elevation));
    state.elevation -= _elevationStep;
    return [ret];
  }

  List<InlineSpan>? _buildLockedArea(uh.Element element) {
    // A block of no known kind still shows the forum's notice: the reader sees something is hidden there.
    final lockedArea = Locked.fromLockDivNode(element, allowWithPurchase: parseLockedWithPurchase, allowUnknown: true);
    if (lockedArea.isNotValid()) {
      return null;
    }

    state
      ..headingBrNodePassed = true
      ..elevation += _elevationStep;
    final ret = [textWidgetSpan(LockedCard(lockedArea, elevation: state.elevation)), emptySpan];
    state.elevation -= _elevationStep;
    return ret;
  }

  List<InlineSpan>? _buildReview(uh.Element element) {
    final rows = element.querySelectorAll('div.pstl').toList();
    if (rows.isEmpty && element.querySelector('div.psti') != null) {
      rows.add(element);
    }
    final spans = <InlineSpan>[];
    for (final row in rows) {
      final (:avatarUrl, :name, :content, :time) = parseReviewElement(row);
      if ((name == null || name.isEmpty) && (content == null || content.isEmpty)) {
        continue;
      }
      spans
        ..add(textWidgetSpan(ReviewCard(name: name ?? '', content: content ?? '', avatarUrl: avatarUrl, time: time)))
        ..add(emptySpan);
    }
    return spans.isEmpty ? null : spans;
  }

  /// Discuz! X5 wraps the spoiler body in `<table><td>...</td></table>`; return that single cell so the one-cell
  /// table is not rendered as a table. Anything else is returned as is.
  static uh.Element _unwrapSpoilerBody(uh.Element body) {
    final children = body.children;
    if (children.length == 1 && children.first.localName == 'table') {
      final cells = children.first.querySelectorAll('td');
      if (cells.length == 1) {
        return cells.first;
      }
    }
    return body;
  }

  /// Spoiler is a button with an area of contents.
  /// Button is used to control the visibility of contents.
  List<InlineSpan>? _buildSpoiler(uh.Element element) {
    // Two generations of markup share the outer `div.spoiler`. The old forum rendered `div.spoiler_control` /
    // `input.spoiler_btn` / `div.spoiler_content`; Discuz! X5 renders `div.spoilerheader` / `input.spoilerbutton` /
    // `div.spoilerbody` and wraps the body in a one-cell table, which is unwrapped so the card holds the text alone.
    final title =
        element.querySelector('div.spoiler_control > input.spoiler_btn')?.attributes['value'] ??
        element.querySelector('div.spoilerheader > input.spoilerbutton')?.attributes['value'];
    final body = element.querySelector('div.spoiler_content') ?? element.querySelector('div.spoilerbody');
    if (title == null || body == null) {
      return null;
    }
    final contentNode = _unwrapSpoilerBody(body);
    state.elevation += _elevationStep;
    final elevation = state.elevation;
    final content = _munchOwnBlock(() => _munch(contentNode));
    state.elevation -= _elevationStep;
    if (content == null) {
      return null;
    }
    while (content.lastOrNull == emptySpan) {
      content.removeLast();
    }
    state.headingBrNodePassed = true;
    final ret = textWidgetSpan(
      SpoilerCard(
        title: TextSpan(text: title),
        content: TextSpan(children: _layOut(content)),
        elevation: elevation,
      ),
    );
    return [ret, emptySpan];
  }

  /// Build for the thread bounty info area.
  ///
  /// The bounty is processing, not resolved.
  ///
  /// ```html
  /// <div class="rusld z">
  ///   <cite>${price}<cite>
  /// </div>
  List<InlineSpan>? _buildUnresolvedBounty(uh.Element element) {
    final price = element.querySelector('cite')?.innerText ?? '';
    return [
      textWidgetSpan(BountyCard(price: price, resolved: false)),
      // Ensure an empty line space between post content.
      const TextSpan(text: '\n\n'),
    ];
  }

  /// Build for the thread bounty info area.
  ///
  /// The bounty is resolved.
  ///
  /// ```html
  /// <div class="rsld z">
  ///   <cite>${price}<cite>
  /// </div>
  /// ```
  List<InlineSpan>? _buildResolvedBounty(uh.Element element) {
    final price = element.querySelector('cite')?.innerText ?? '';
    return [
      textWidgetSpan(BountyCard(price: price, resolved: true)),
      // Ensure an empty line space between post content.
      const TextSpan(text: '\n\n'),
    ];
  }

  /// Build for the best answer of bounty area.
  ///
  /// This answer only occurs with already resolved bounty.
  ///
  /// * `USER_AVATAR_URL`: Avatar url of the answered user.
  /// * `USER_SPACE_URL`: Profile url of the answered user.
  /// * `USERNAME`: Username of the answered user.
  /// * `PTID`: Thread id of the answer.
  /// * `PID`: Post id of the answer.
  /// * `USER_ANSWER`: Answer content.
  ///
  /// ```html
  /// <div class="rwdbst">
  ///    <h3 class="psth">最佳答案</h3>
  ///    <div class="pstl">
  ///      <div class="psta">
  ///        <img src="${USER_AVATAR_URL">
  ///      </div>
  ///      <div class="psti">
  ///        <p class="xi2">
  ///          <a href="${USER_SPACE_URL}" class="xw1">${USERNAME}</a>
  ///          <a href="javascript:;" onclick="window.open('forum.php?mod=redirect&amp;goto=findpost&amp;ptid=${PTID}&amp;pid=${PID}')">查看完整内容</a></p>
  ///        <div class="mtn">${USER_ANSWER}</div>
  ///      </div>
  ///    </div>
  ///  </div>
  /// ```
  List<InlineSpan>? _buildBountyBestAnswer(uh.Element element) {
    final userAvatarUrl = element.querySelector('div.pstl > div.psta > img')?.imageUrl();
    final userInfoNode = element.querySelector('div.pstl > div.psti > p.xi2 > a');
    final username = userInfoNode?.innerText.trim();
    final userSpaceUrl = userInfoNode?.attributes['href'];
    final answer = element.querySelector('div.pstl > div.psti > div.mtn')?.innerText.trim();
    if (userAvatarUrl == null || username == null || userSpaceUrl == null || answer == null) {
      error(
        'failed to parse bounty answer: '
        'avatar=$userAvatarUrl, username=$username, '
        'userSpaceUrl=$userSpaceUrl, answer=$answer',
      );
      return null;
    }

    return [
      textWidgetSpan(
        BountyAnswerCard(
          userAvatarUrl: userAvatarUrl,
          username: username,
          userSpaceUrl: userSpaceUrl,
          answer: answer,
        ),
      ),
    ];
  }

  /// Gesture recognizer that opens [url] on tap (desktop) or long-press cancel (mobile) and shows its info on
  /// long press / secondary tap.
  GestureRecognizer _buildUrlRecognizer(String url) {
    if (isMobile) {
      return LongPressGestureRecognizer()
        ..onLongPressCancel = () async {
          await _openUrl(url);
        }
        ..onLongPress = () async {
          await _showUrlInfo(url);
        };
    }
    // Desktop or web.
    return TapGestureRecognizer()
      ..onTapDown = (_) async {
        await _openUrl(url);
      }
      ..onSecondaryTap = () async {
        await _showUrlInfo(url);
      };
  }

  /// Split [text] into plain spans and tappable spans for every bare `http(s)://` url in it (GitHub #24).
  ///
  /// Trailing punctuation that is not part of a url (closing brackets, full-width punctuation, quotes) stays plain
  /// text; urls that are not inside an anchor are the only ones reaching here because anchors set `tapUrl`.
  List<InlineSpan> _linkifySpans(String text, TextStyle? style) {
    final spans = <InlineSpan>[];
    var last = 0;
    for (final match in _bareUrlRe.allMatches(text)) {
      var url = match.group(0)!;
      // Strip the punctuation a sentence appends to the url.
      while (url.isNotEmpty && _urlTrailingPunctuation.contains(url[url.length - 1])) {
        url = url.substring(0, url.length - 1);
      }
      if (url.length <= 'https://'.length) {
        continue;
      }
      final start = match.start;
      final end = start + url.length;
      if (start > last) {
        spans.add(TextSpan(text: text.substring(last, start), style: style));
      }
      spans.add(
        TextSpan(
          text: url,
          recognizer: _buildUrlRecognizer(url),
          style: (style ?? const TextStyle()).copyWith(
            color: Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
        ),
      );
      last = end;
    }
    if (last == 0) {
      return [TextSpan(text: text, style: style)];
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: style));
    }
    return spans;
  }

  static final _bareUrlRe = RegExp(r'https?://[^\s<>"\u3000-\u303f\uff00-\uffef]+');
  static const _urlTrailingPunctuation = '.,;:!?)]}\'"';

  /// Open a tapped [url].
  ///
  /// An email address is shown first (copy, or hand to the mail app) instead of being launched, see
  /// [showEmailBottomSheet]. Everything else is reported through [MunchOptions.onUrlLaunched] before navigating: the
  /// pushed page pops much later, if ever.
  Future<void> _openUrl(String url) async {
    options.onUrlLaunched?.call();
    if (url.startsWith('mailto:')) {
      await showEmailBottomSheet(context: context, address: url.substring('mailto:'.length));
      return;
    }
    await context.dispatchAsUrl(url);
  }

  /// Show what a [url] is: the email sheet for an address, the url info sheet for the rest.
  Future<void> _showUrlInfo(String url) async {
    if (url.startsWith('mailto:')) {
      await showEmailBottomSheet(context: context, address: url.substring('mailto:'.length));
      return;
    }
    await showUrlInfoBottomSheet(context: context, url: url);
  }

  /// Whether a link to [url] has a mark before it ([postLinkHasMark] in a post's content).
  bool _marksLink(String url) => typography == null || postLinkHasMark(url);

  List<InlineSpan>? _buildA(uh.Element element) {
    if (!element.attributes.containsKey('href') || !options.renderUrl) {
      return _munch(element);
    }

    final url = element.attributes['href']!;
    // Flag indicating only has <img> inside the <a> node.
    // <a href="xxx"><img src="xxx"></a>
    //
    // If true, do not show outside.
    final hasOnlyImg =
        element.childNodes.length == 1 &&
        element.childNodes[0].nodeType == uh.Node.ELEMENT_NODE &&
        (element.childNodes[0] as uh.Element).tagName == 'IMG';
    // The space collapsed before the link goes before its mark, outside the link; white space at the start of the
    // link collapses into it. So does the line break a paragraph before it left.
    final line = _lineState();
    final breakBefore = state.pendingBreak;
    final spaceBefore = state.pendingSpace && !state.atLineStart;
    final space = spaceBefore ? TextSpan(text: ' ', style: _buildTextStyle()) : null;
    final outerLink = _link;
    _link = element;
    state
      ..atLineStart = state.atLineStart || spaceBefore
      ..pendingSpace = false
      ..pendingBreak = false
      ..tapUrl = url.prependHost()
      ..wrapInWord = true
      // The link in its own color, not in the color of a `<font>` around it; underlined in a post as on the web page.
      ..linkDepth = state.colorStack.length
      ..linkOrder = _behindCount
      ..linkColor = null
      ..linkUnderline = typography != null;
    final List<InlineSpan>? ret;
    try {
      ret = _munch(element);
    } finally {
      _link = outerLink;
      state
        ..wrapInWord = false
        // An empty link must not turn what follows into a link.
        ..tapUrl = null
        ..linkDepth = null
        ..linkOrder = null
        ..linkColor = null
        ..linkUnderline = false;
    }
    if (ret == null) {
      // Nothing put: the space or the line break is still owed, and white space in the link is one more space.
      final spaceInside = state.pendingSpace;
      _restoreLine(line);
      state.pendingSpace = state.pendingSpace || (spaceInside && !state.atLineStart);
      return null;
    }
    if (hasOnlyImg) {
      // Only a <img> node inside the current <a> node.
      // Do NOT show url prefix.
      return [if (breakBefore) emptySpan, ?space, ...ret];
    }
    final Widget? content;
    if (url.isUserSpaceUrl) {
      if (element.innerText.contains('@')) {
        // Text already has the label, do not add duplicate one.
        content = null;
      } else {
        // Scaled once by the span it is in, like a card (see [textWidgetSpan]) but without a MediaQuery for every link.
        content = Text(
          '@',
          style: TextStyle(color: Theme.of(context).colorScheme.primary),
          textScaler: .noScaling,
        );
      }
    } else if (_marksLink(url)) {
      final IconData prefixIcon;
      if (url.startsWith('mailto:')) {
        prefixIcon = Icons.email_outlined;
      } else {
        prefixIcon = Icons.link;
      }

      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(prefixIcon, size: _fontSize, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 2),
        ],
      );
    } else {
      content = null;
    }

    return [
      if (breakBefore) emptySpan,
      ?space,
      TextSpan(
        children: [
          if (content != null)
            WidgetSpan(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () async => _openUrl(url),
                  child: content,
                ),
              ),
            ),
          ...ret,
        ],
      ),
    ];
  }

  List<InlineSpan>? _buildTr(uh.Element element) {
    final ret = _munch(element);
    if (ret == null) {
      return null;
    }
    return ret;
  }

  /// A table cell, a block of the web page ([_munchBlock]): its content starts a line and ends its line, the white
  /// space at its start and end is dropped. Before, every text in a cell was trimmed on both ends, which also dropped
  /// the space between two words of the cell where one of them is in an element (`<strong>A</strong> B`, `<a>here</a>
  /// to`); a post's content is the cell of a one-row table.
  ///
  /// A cell of a table drawn as one is laid out on its own and the line break it ends with is dropped there
  /// ([_withoutTrailingLineBreak]). The cell of a table that only wraps something (the post's content) is in the line
  /// of what is around it: what follows it (the attachments, the notice of hidden attachments) starts a line. Before,
  /// the line was only taken to start there, and what followed went on in the cell's last line.
  List<InlineSpan>? _buildTd(uh.Element element) =>
      _munchBlock(element, deferBreak: false, () => _endingLine(_munch(element)));

  /// A header cell in a table: a cell in bold.
  List<InlineSpan>? _buildTh(uh.Element element) {
    final origBold = state.bold;
    state.bold = true;
    final ret = _buildTd(element);
    state.bold = origBold;
    return ret;
  }

  List<InlineSpan>? _buildH1(uh.Element element) => _munchHeading(element, FontSize.size6.value());

  List<InlineSpan>? _buildH2(uh.Element element) => _munchHeading(element, FontSize.size5.value());

  List<InlineSpan>? _buildH3(uh.Element element) {
    // The heading of the rate log at the end of a rated post, skipped with the rate log in `_buildDl`: the post card
    // shows the rates on its own.
    //
    // <h3 class="psth xs1"><span class="icon_ring vm"></span>评分</h3>
    // <dl id="ratelog_POST_ID" class="rate">...</dl>
    final next = element.nextElementSibling;
    if (element.classes.contains('psth') && next?.localName == 'dl' && (next?.id.startsWith('ratelog_') ?? false)) {
      return null;
    }
    return _munchHeading(element, FontSize.size4.value());
  }

  /// A heading in [fontSize] (of the web page, see [_appFontSize]): a line of its own, ended by a line break, after one
  /// when the line before it holds something or a paragraph before it left its break. Before, a line break always went
  /// before it: at the start of a line (after a `<br>`, after another heading) that was a blank line the web page does
  /// not show.
  List<InlineSpan>? _munchHeading(uh.Element element, double fontSize) {
    final line = _lineState();
    final breakBefore = !state.atLineStart || state.pendingBreak;
    state.fontSizeStack.add(_appFontSize(fontSize));
    _lineBroken();
    _headingDepth += 1;
    final List<InlineSpan>? ret;
    try {
      ret = _munchStyledBlock(element, _munch);
    } finally {
      _headingDepth -= 1;
    }
    state.fontSizeStack.removeLast();
    if (ret == null) {
      _restoreLine(line);
      return null;
    }
    return [if (breakBefore) emptySpan, ...ret, emptySpan];
  }

  List<InlineSpan>? _buildH4(uh.Element element) => _munchHeading(element, FontSize.size3.value());

  /// `<ul>` and `<ol>`, a block of the web page ([_munchBlock]) whose items each start a line.
  ///
  /// The marks are the web page's. The forum's style sheet takes the marks off every list (`ol, ul { list-style:
  /// none }`) and puts a disc back before the items of an `<ul>` in a post (`.t_f ul li`), numbers before those of
  /// `[list=1]` (`ul.litype_1`) and letters before those of `[list=a]` and `[list=A]` (`ul.litype_2`, `ul.litype_3`):
  /// an `<ol>` (written in the html of a post) has no mark. Before, an `<ol>` without the class of `[list=1]` was
  /// dropped with all its items, and the letters were discs.
  List<InlineSpan>? _buildList(uh.Element element) {
    final classes = element.classes;
    final _ListType type;
    if (element.localName == 'ol') {
      type = _ListUnmarked();
    } else if (classes.contains('litype_1')) {
      type = _ListOrdered(1);
    } else if (classes.contains('litype_2')) {
      type = _ListOrdered(1, letters: true);
    } else if (classes.contains('litype_3')) {
      type = _ListOrdered(1, letters: true, upperCase: true);
    } else {
      type = _ListUnordered();
    }
    return _munchBlock(element, deferBreak: false, () {
      state.listStack.add(type);
      final ret = _munchStyledBlock(element, _munch);
      state.listStack.removeLast();
      return ret;
    });
  }

  /// Build `<li>` tag.
  List<InlineSpan>? _buildLi(uh.Element element) {
    // The item's text follows its mark at the start of a line; the break a paragraph before it left goes before the
    // mark.
    final line = _lineState();
    final breakBefore = state.pendingBreak;
    state.pendingBreak = false;
    _startLine();
    // The item with its mark before it, the mark in the color and size of the item's text as the web page draws it;
    // on the item's background when it has one.
    List<InlineSpan>? munchItem(uh.Element item) => _styled(item, () {
      final content = _munchContent(item);
      if (content == null) {
        return null;
      }
      final leading = switch (state.listStack.lastOrNull) {
        _ListUnordered() => '•  ',
        final _ListOrdered list => () {
          // Pop and push a larger number.
          state.listStack
            ..removeLast()
            ..add(list.next());
          return '${list.mark}. ';
        }(),
        _ListUnmarked() => '',
        null => () {
          error('failed to detect html list leading type: empty list stack');
          return '•  ';
        }(), // Unreachable but handle it.
      };
      return [if (leading.isNotEmpty) TextSpan(text: leading, style: _buildTextStyle()), ...content];
    });

    final ret = _munchStyledBlock(element, munchItem);
    if (ret == null) {
      _restoreLine(line);
      return null;
    }
    if (!(ret.lastOrNull?.toPlainText().endsWith('\n') ?? false)) {
      // Append a trailing <br> if not have it.
      // This is a render issue on the server side, same bbcode may produce different result, with or without trailing
      // line break.
      return [if (breakBefore) emptySpan, ...ret, emptySpan];
    } else {
      return [if (breakBefore) emptySpan, ...ret];
    }
  }

  /// <code>xxx</code> tags. Mainly for github.com
  List<InlineSpan>? _buildCode(uh.Element element) {
    state.fontSizeStack.add(_appFontSize(FontSize.size2.value()));
    final ret = _munchOwnBlock(() => _munch(element));
    state.fontSizeStack.removeLast();
    if (ret == null) {
      return null;
    }
    state
      ..headingBrNodePassed = true
      ..elevation += _elevationStep;
    final ret2 = textWidgetSpan(
      Card(
        elevation: state.elevation,
        color: Theme.of(context).colorScheme.onSecondary,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(5))),
        margin: EdgeInsets.zero,
        child: Text.rich(TextSpan(children: ret)),
      ),
    );
    state.elevation -= _elevationStep;
    return [ret2];
  }

  List<InlineSpan>? _buildDl(uh.Element element) {
    // Skip rate log area.
    if (element.id.startsWith('ratelog_')) {
      return null;
    }
    return _munch(element);
  }

  /// `<dt>`, the term of a definition list (the field names of an activity's details, of goods): a line of its own,
  /// its definition (`<dd>`) beside it in the same line, as the forum's style sheet floats the term to its left
  /// (`活动类型: 测试活动`). Before, the term was dropped: the values were left without their names.
  List<InlineSpan>? _buildDt(uh.Element element) {
    final definitionFollows = element.nextElementSibling?.localName == 'dd';
    return _munchBlock(element, deferBreak: false, () {
      final ret = _munchStyledBlock(element, _munch);
      return definitionFollows ? ret : _endingLine(ret);
    });
  }

  /// `<dd>`, a block of its own on the web page (the fields of an activity or goods block, an attachment's name and
  /// size): a line of its own ([_munchBlock]), or the rest of the line of its term ([_buildDt]). Before, the line ended
  /// only when its text ended with the template's line break, kept as text, which the web page collapses.
  List<InlineSpan>? _buildDd(uh.Element element) {
    if (element.previousElementSibling?.localName == 'dt' && !state.atLineStart) {
      // Beside its term, after a space: its first line, a paragraph too (an attachment's name beside its icon), is
      // the rest of the term's line.
      final spaceStyle = _buildTextStyle();
      _startLine();
      final ret = _munch(element);
      if (ret == null || ret.isEmpty) {
        // Nothing to put beside the term: its line ends.
        _lineBroken();
        return [emptySpan];
      }
      return _endingLine([TextSpan(text: ' ', style: spaceStyle), ...ret]);
    }
    return _munchBlock(element, deferBreak: false, () => _endingLine(_munchStyledBlock(element, _munch)));
  }

  List<InlineSpan>? _buildB(uh.Element element) {
    final origBold = state.bold;
    state.bold = true;
    final ret = _munch(element);
    state.bold = origBold;
    if (ret == null) {
      return null;
    }
    return ret;
  }

  List<InlineSpan>? _buildI(uh.Element element) {
    // Ignore thread last modified info element.
    // This kind of node is specially handled.
    if (element.classes.contains('pstatus')) {
      return null;
    }
    final origItalic = state.italic;
    state.italic = true;
    final ret = _munch(element);
    state.italic = origItalic;
    if (ret == null) {
      return null;
    }
    return ret;
  }

  /// `<hr>`, a block of the web page: a line of its own, which it ends. A `<br>` right after it is a blank line, as on
  /// the web page (`[hr]` then a line break, the usual way to separate the parts of a post). Before, the rule's line
  /// only ended when something followed it, and that `<br>` ended it instead of leaving a blank line.
  List<InlineSpan> _buildHr(uh.Element element) {
    final breakBefore = !state.atLineStart || state.pendingBreak;
    _lineBroken();
    state.headingBrNodePassed = true;
    return [if (breakBefore) emptySpan, const WidgetSpan(child: Divider()), emptySpan];
  }

  List<InlineSpan>? _buildPre(uh.Element element) {
    // Avoid reset parent's inPre state.
    final alreadyInPre = state.inPre;
    if (!alreadyInPre) {
      state.inPre = true;
    }
    final ret = _munchStyledBlock(element, _munch);
    if (!alreadyInPre) {
      state.inPre = false;
    }
    return ret;
  }

  /// Build a detail card here.
  List<InlineSpan>? _buildDetails(uh.Element element) {
    final summary = element.children.elementAtOrNull(0);
    state.elevation += _elevationStep;
    final dataSpanList = _munchOwnBlock(
      () => element.children.skip(1).map(_munch).whereType<List<InlineSpan>>().toList(),
    );
    state.elevation -= _elevationStep;
    if (summary == null || dataSpanList.isEmpty) {
      return null;
    }

    final summarySpan = _munchOwnBlock(() => _munch(summary));
    if (summarySpan == null) {
      return null;
    }

    // Trim all trailing whitespace in card.
    final ch = dataSpanList.lastOrNull;
    if (ch != null) {
      while (ch.lastOrNull == emptySpan ||
          ((ch.lastOrNull is TextSpan) && ((ch.last as TextSpan).text?.trim().isEmpty ?? false))) {
        ch.removeLast();
      }
      dataSpanList.last = ch;
    }
    state.elevation += _elevationStep;
    final ret = textWidgetSpan(
      SpoilerCard(
        title: TextSpan(children: summarySpan),
        content: TextSpan(children: _layOut(dataSpanList.flattened.toList())),
        elevation: state.elevation,
      ),
    );
    state.elevation -= _elevationStep;

    return [ret, emptySpan];
  }

  List<InlineSpan>? _buildIframe(uh.Element element) {
    final neteasePlayerId = _neteasePlayerRe.firstMatch(element.attributes['src'] ?? '')?.namedGroup('id');
    if (neteasePlayerId != null) {
      // Recognized netease player iframe.
      return [textWidgetSpan(NeteaseCard(neteasePlayerId))];
    }
    return _buildMedia(element);
  }

  /// An embedded player (`<iframe>` other than netease music's, `<embed>`, `<object>`, `<video>`, `<audio>`): a card
  /// naming the site, opening the player in the browser ([PostMediaCard]). Before, the player was left out and the
  /// reader did not know there was anything there. What a player holds (`<source>`, the text for browsers without
  /// players) is not shown.
  List<InlineSpan> _buildMedia(uh.Element element) {
    state.headingBrNodePassed = true;
    return [textWidgetSpan(PostMediaCard(PostMedia.of(element)))];
  }

  /// A script, which is not shown, unless it is the one the forum's `[media]` and `[flash]` make their player with on
  /// the web page ([PostMedia.ofScript]): the card of that player.
  List<InlineSpan>? _buildScriptPlayer(uh.Element element) {
    final code = element.text ?? '';
    final target = PostMedia.scriptPlayerTarget(code);
    final previous = element.previousElementSibling;
    if (target != null && previous?.id == target && previous?.querySelector('div.media_container') != null) {
      // Shown where the web page puts the player, see [_buildMediaContainer].
      return null;
    }
    final media = PostMedia.ofScript(code);
    if (media == null) {
      return null;
    }
    state.headingBrNodePassed = true;
    return [textWidgetSpan(PostMediaCard(media))];
  }

  /// The place of the player of `[media]` (`div.media_container`, filled by the script after its `div.media` on the
  /// web page, above the link to open it in a new window): the card of the player there, a line of its own.
  List<InlineSpan>? _buildMediaContainer(uh.Element element) {
    final holder = element.parent;
    final script = holder?.nextElementSibling;
    if (holder == null || script == null || script.localName != 'script') {
      return null;
    }
    final code = script.text ?? '';
    if (PostMedia.scriptPlayerTarget(code) != holder.id) {
      return null;
    }
    final media = PostMedia.ofScript(code);
    if (media == null) {
      return null;
    }
    state.headingBrNodePassed = true;
    return _munchBlock(element, deferBreak: false, () => [textWidgetSpan(PostMediaCard(media)), emptySpan]);
  }

  /// A choice box: the option it shows (the one chosen, or the first one) as text.
  List<InlineSpan>? _buildSelect(uh.Element element) {
    final options = element.querySelectorAll('option');
    final chosen = options.firstWhereOrNull((e) => e.attributes.containsKey('selected')) ?? options.firstOrNull;
    final text = chosen == null ? null : _collapseText(chosen.text ?? '');
    if (text == null) {
      return null;
    }
    state.headingBrNodePassed = true;
    return [TextSpan(text: text, style: _buildTextStyle())];
  }

  /// `<small>` and `<big>`: the content at [scale] times the size of the text around it, as a browser does.
  List<InlineSpan>? _munchScaled(uh.Element element, double scale) {
    final size = state.fontSizeStack.lastOrNull ?? Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14;
    state.fontSizeStack.add(size * scale);
    final ret = _munch(element);
    state.fontSizeStack.removeLast();
    return ret;
  }

  /// Size of the text in `<small>` to the text around it: a browser's `font-size: smaller`.
  static const double _smallerFontScale = 5 / 6;

  /// Size of the text in `<big>` to the text around it: a browser's `font-size: larger`.
  static const _largerFontScale = 1.2;

  /// Size of a ruby text (`<rt>`) to its base: a browser's.
  static const _rubyTextScale = 0.5;

  /// [nodes] munched one after the other.
  List<InlineSpan> _munchNodes(Iterable<uh.Node> nodes) => [for (final node in nodes) ...?munchNode(node)];

  /// `<ruby>`: each base with its ruby text (`<rt>`) above it in a small size, as the web page shows it; the
  /// parentheses for browsers without ruby (`<rp>`) are not shown. The base and its ruby text are one piece in the
  /// line, the base on the line's baseline. Before, the whole ruby was dropped, its base too.
  List<InlineSpan>? _buildRuby(uh.Element element) {
    final spans = <InlineSpan>[];
    var base = <uh.Node>[];
    void put(String annotation) {
      final baseSpans = _munchOwnBlock(() => _munchNodes(base));
      base = [];
      if (annotation.isEmpty) {
        spans.addAll(baseSpans);
        return;
      }
      final style = _buildTextStyle();
      final size = (style?.fontSize ?? 14) * _rubyTextScale;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: TextWidgetSpanChild(
            Column(
              mainAxisSize: MainAxisSize.min,
              // The base first (the reading order), laid out at the bottom: the ruby text is above it.
              verticalDirection: VerticalDirection.up,
              children: [
                Text.rich(TextSpan(children: baseSpans)),
                Text(annotation, style: style?.copyWith(fontSize: size)),
              ],
            ),
          ),
        ),
      );
    }

    for (final node in element.nodes) {
      if (node is uh.Element) {
        switch (node.localName) {
          case 'rt' || 'rtc':
            put(node.innerText.replaceAll(_htmlWhiteSpaceRe, ' ').trim());
          case 'rp':
            break;
          case 'rb':
            base.addAll(node.nodes);
          default:
            base.add(node);
        }
      } else {
        base.add(node);
      }
    }
    if (base.isNotEmpty) {
      spans.addAll(_munchNodes(base));
    }
    state.headingBrNodePassed = true;
    return spans.isEmpty ? null : spans;
  }

  List<InlineSpan>? _buildNewcomerReport(uh.Element element) {
    // <table cellspacing="0" cellpadding="0" class="cgtl mbm">
    // <caption>报到详细信息</caption>
    // <tbody>
    //   <tr>
    //     <th valign="top">昵称:</th>
    //     <td> USER_NICKNAME</td>
    //   </tr>
    //
    //   ...
    //
    // </tbody>
    // </table>
    return _newcomerReportSpan(_parseNewcomerReportRows(element));
  }

  /// The card of the forum's newcomer report plugin at the top of the first post of a report thread.
  ///
  /// ```html
  /// <div class="rcd-card">
  ///   <div class="rcd-h">报到详细信息</div>
  ///   <table>
  ///     <tr><th>昵称</th><td class="rcd-v">USER_NICKNAME</td></tr>
  ///     <tr><th>兴趣爱好</th><td class="rcd-v">LINE_1<br />
  ///     LINE_2</td></tr>
  ///     <tr><th>QQ</th><td class="rcd-v"></td></tr>
  ///     ...
  ///   </table>
  /// </div>
  /// ```
  ///
  /// The threadsort template before the plugin rendered the same markup with `bd-card`, `bd-h` and `bd-v`.
  List<InlineSpan>? _buildNewcomerReportDiv(uh.Element element) {
    final table = element.children.firstWhereOrNull((e) => e.localName == 'table');
    final data = table == null ? const <NewcomerReportInfo>[] : _parseNewcomerReportRows(table);
    if (data.isEmpty) {
      return _munch(element);
    }
    final title = element.children
        .firstWhereOrNull((e) => e.classes.contains('rcd-h') || e.classes.contains('bd-h'))
        ?.innerText
        .trim();
    state.headingBrNodePassed = true;
    return _newcomerReportSpan(data, title: title);
  }

  /// The [NewcomerReportCard] of [data] in the post, scaled once with the post (see [textWidgetSpan]): at 1.3 its text
  /// would be 1.69 and the field names would break on a phone screen.
  static List<InlineSpan> _newcomerReportSpan(List<NewcomerReportInfo> data, {String? title}) => [
    textWidgetSpan(NewcomerReportCard(data, title: title)),
  ];

  /// Field names (`th`) and values (`td`) in the rows of a newcomer report [table], rows without either are skipped.
  ///
  /// A value with images (an image field of a threadsort, `<img onload="thumbImg(this)">`) keeps its spans: the
  /// images have no text and the value is not empty.
  List<NewcomerReportInfo> _parseNewcomerReportRows(uh.Element table) => [
    for (final tr in table.querySelectorRootAll('tbody > tr'))
      if ((tr.querySelector('th'), tr.querySelector('td')) case (final th?, final td?))
        NewcomerReportInfo(
          title: _plainCellText(th),
          data: _plainCellText(td),
          richData: td.querySelector('img') == null
              ? null
              : _withoutTrailingLineBreak(_munchOwnBlock(() => _buildTd(td))),
        ),
  ];

  /// White space that HTML collapses, which is not `\s`: no-break spaces inside a line are kept.
  static final _htmlWhiteSpaceRe = RegExp('[ \t\n\r\f]+');

  /// Text in a table [cell] as the website shows it: runs of white space are one space, `<br>` breaks the line, and
  /// the white space around each line is trimmed.
  static String _plainCellText(uh.Element cell) {
    final buffer = StringBuffer();
    void visit(uh.Node node) {
      for (final child in node.nodes) {
        if (child is uh.Element) {
          if (child.localName == 'br') {
            buffer.write('\n');
          } else {
            visit(child);
          }
        } else if (child.nodeType == uh.Node.TEXT_NODE) {
          buffer.write((child.text ?? '').replaceAll(_htmlWhiteSpaceRe, ' '));
        }
      }
    }

    visit(cell);
    return buffer.toString().split('\n').map((e) => e.trim()).join('\n').trim();
  }

  /// A table, in the style its author gave it ([_styled]): its text in the table's color and size.
  List<InlineSpan>? _buildTable(uh.Element element) => _styled(element, () => _buildTableContent(element));

  List<InlineSpan>? _buildTableContent(uh.Element element) {
    // Rows in `<thead>`, `<tbody>` and `<tfoot>` in document order. The parser moves rows written directly in
    // `<table>` into a `<tbody>`.
    final allTr = element.children
        .where((e) => const {'thead', 'tbody', 'tfoot'}.contains(e.localName))
        .expand((e) => e.children.where((tr) => tr.localName == 'tr'))
        .toList();
    // The caption, a line of its own above the table.
    final captionElement = element.children.firstWhereOrNull((e) => e.localName == 'caption');
    final caption = captionElement == null
        ? null
        : _munchBlock(captionElement, deferBreak: false, () => _endingLine(_munch(captionElement)));
    if (caption != null && _endsLine(caption)) {
      _lineBroken();
    }
    if (allTr.isEmpty) {
      return caption;
    }
    List<uh.Element> cellsOf(uh.Element tr) =>
        tr.children.where((e) => e.localName == 'td' || e.localName == 'th').toList();
    if (allTr.length == 1 && cellsOf(allTr.single).length <= 1) {
      // Not a regular table, only something wrapped: the content of a post, the body of a spoiler. A background of
      // the table, its row or its cell (`<table bgcolor="#ffe0b3"><tr><td>…`) is the background of a block, as the
      // alignment of its cell.
      final tr = allTr.single;
      final cell = cellsOf(tr).firstOrNull;
      // The innermost color is the one seen: the cell's over the row's over the table's.
      final backgrounds = [
        if (cell != null) _blockBackgroundOf(cell, _styleOf(cell)),
        _blockBackgroundOf(tr, _styleOf(tr)),
        _blockBackgroundOf(element, _styleOf(element)),
      ].nonNulls;
      final background = backgrounds.firstWhereOrNull((e) => e.color != null) ?? backgrounds.firstOrNull;
      final align =
          (cell == null ? null : _styleAlign(cell) ?? _blockAlign(cell)) ?? _styleAlign(tr) ?? _styleAlign(element);
      if (background == null && align == null) {
        final content = _munch(tr.parent!);
        return caption == null ? content : [...caption, ...?content];
      }
      final content = _munchAligned(element, align, (_) => _munch(tr.parent!), background: background);
      if (content == null || content.isEmpty) {
        return caption;
      }
      if (!_endsLine(content)) {
        content.add(emptySpan);
      }
      _lineBroken();
      return [...?caption, ...content];
    }
    // A table of one row with cells side by side (`[table]` with one `[tr]`, a row of headers or of links) is a
    // table on the web page, drawn as one. Before, it was taken for a wrapper like the one around a post and its cells
    // ran together in one line.

    // The cells by row and column. A cell spanning columns (`colspan`) or rows (`rowspan`) takes its first place, the
    // other places it spans are left empty, so the cells after it stay in their columns. The cell is not drawn across
    // them: a [Table] has no spanning cells.
    final grid = <List<Widget>>[];
    // The background of each row: its own, else the table's (`[table=98%,pink]`), which shows around the cells.
    final rowBackgrounds = <Color?>[];
    final tableBackground = _blockBackgroundOf(element, _styleOf(element));
    // The last row each column is taken until by a cell spanning rows above.
    final takenUntil = <int, int>{};
    state.tableDepth += 1;
    if (tableBackground != null) {
      state.blockBackgroundStack.add(_behind(tableBackground.color));
    }
    for (final (y, tr) in allTr.indexed) {
      final row = <Widget>[];
      final rowBackground = _blockBackgroundOf(tr, _styleOf(tr));
      rowBackgrounds.add(
        switch (rowBackground ?? tableBackground) {
          (color: final Color color) => _colors.background(color),
          _ => null,
        },
      );
      if (rowBackground != null) {
        state.blockBackgroundStack.add(_behind(rowBackground.color));
      }
      void skipTaken() {
        while ((takenUntil[row.length] ?? -1) >= y) {
          row.add(sizedBoxEmpty);
        }
      }

      // The style of the row: its text in the row's color and size.
      _styled(tr, () {
        for (final cell in cellsOf(tr)) {
          skipTaken();
          final colspan = (cell.attributes['colspan']?.trim().parseToInt() ?? 1).clamp(1, _maxTableSpan);
          final rowspanAttr = cell.attributes['rowspan']?.trim().parseToInt() ?? 1;
          // `rowspan="0"`: to the last row.
          final rowspan = (rowspanAttr == 0 ? allTr.length - y : rowspanAttr).clamp(1, allTr.length - y);
          final cellStyle = _styleOf(cell);
          final cellBackground = _blockBackgroundOf(cell, cellStyle);
          if (cellBackground != null) {
            state.blockBackgroundStack.add(_behind(cellBackground.color));
          }
          // Header cells (`th`) are cells too, in bold, in their place in the row. The line break a cell's content
          // ends with (a `<br>`, a block at its end) ends its last line, it does not add an empty line below it.
          final List<InlineSpan>? content;
          try {
            content = _withoutTrailingLineBreak(
              _munchOwnBlock(() => cell.localName == 'th' ? _buildTh(cell) : _buildTd(cell)),
            );
          } finally {
            if (cellBackground != null) {
              state.blockBackgroundStack.removeLast();
            }
          }
          for (var x = row.length; x < row.length + colspan; x++) {
            if (rowspan > 1) {
              takenUntil[x] = y + rowspan - 1;
            }
          }
          // Aligned as the web page aligns the cell: its style, its `align`, its row's, its table's. Not as the block
          // around the table (`[align=center]`): the web page leaves the cells of a centered table aligned left.
          final align =
              _styleAlign(cell) ?? _blockAlign(cell) ?? _styleAlign(tr) ?? _blockAlign(tr) ?? _styleAlign(element);
          row
            ..add(_tableCell(Text.rich(TextSpan(children: content), textAlign: align), content, cellBackground))
            ..addAll(List<Widget>.filled(colspan - 1, sizedBoxEmpty));
        }
      });
      if (rowBackground != null) {
        state.blockBackgroundStack.removeLast();
      }
      // Places at the end of the row taken by cells above.
      final lastTaken = takenUntil.entries.where((e) => e.value >= y).map((e) => e.key).maxOrNull;
      while (lastTaken != null && row.length <= lastTaken) {
        row.add(sizedBoxEmpty);
      }
      grid.add(row);
    }
    if (tableBackground != null) {
      state.blockBackgroundStack.removeLast();
    }
    state.tableDepth -= 1;
    // The table takes its own lines: what follows starts a line.
    _startLine();

    // Some tables do not have the same column width on each row.
    // Fill them.
    final columnMaxCount = grid.map((e) => e.length).max;
    if (columnMaxCount == 0) {
      return caption;
    }
    for (final row in grid) {
      if (row.length < columnMaxCount) {
        row.addAll(List<Widget>.generate(columnMaxCount - row.length, (_) => sizedBoxEmpty));
      }
    }

    // Fits the width of the post when it can, its long cells wrapping; scrolls sideways only when it cannot.
    return [
      ...?caption,
      textWidgetSpan(
        PostTableScrollView(
          child: Table(
            defaultColumnWidth: const PostTableColumnWidth(),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              for (final (y, row) in grid.indexed)
                TableRow(
                  decoration: rowBackgrounds[y] == null ? null : BoxDecoration(color: rowBackgrounds[y]),
                  children: row,
                ),
            ],
            // Lines that can be seen between the cells, as on the web page: the cells of a row ran together in the
            // color of the background (a row of headers read as one word).
            border: TableBorder.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
        ),
      ),
    ];
  }

  /// [text], the content of a cell made of [spans], on the cell's [background] when it has one shown: as tall as its
  /// row when it is only text (a widget in it might not tell its height before it is laid out), behind its text
  /// otherwise.
  Widget _tableCell(Widget text, List<InlineSpan>? spans, ({Color? color})? background) {
    final color = background?.color;
    final shown = color == null ? null : _colors.background(color);
    if (shown == null) {
      return text;
    }
    final onlyText = !(spans ?? const <InlineSpan>[]).any(_holdsWidget);
    return TableCell(
      verticalAlignment: onlyText ? TableCellVerticalAlignment.intrinsicHeight : TableCellVerticalAlignment.middle,
      child: PostBlockBackground(
        color: shown,
        padding: const EdgeInsets.all(4),
        child: onlyText
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [text],
              )
            : text,
      ),
    );
  }

  /// Whether [span] holds a widget.
  static bool _holdsWidget(InlineSpan span) => switch (span) {
    PlaceholderSpan() => true,
    TextSpan(:final children?) => children.any(_holdsWidget),
    _ => false,
  };

  /// Most columns or rows a cell of a table is taken to span: a typo in the html (`colspan="200"`) does not make a
  /// table of hundreds of empty columns.
  static const _maxTableSpan = 32;

  /// [spans] without the line break they end with, if they do: the end of a cell, of a block laid out on its own, is
  /// the end of its last line, a line break there does not add an empty line below it as it does in a rich text.
  static List<InlineSpan>? _withoutTrailingLineBreak(List<InlineSpan>? spans) {
    if (spans == null || spans.isEmpty) {
      return spans;
    }
    final last = spans.last;
    if (last is! TextSpan) {
      return spans;
    }
    final children = last.children;
    if (children != null && children.isNotEmpty) {
      final trimmed = _withoutTrailingLineBreak(children);
      if (identical(trimmed, children)) {
        return spans;
      }
      return [
        ...spans.take(spans.length - 1),
        TextSpan(text: last.text, children: trimmed, style: last.style, recognizer: last.recognizer),
      ];
    }
    final text = last.text;
    if (text == null || !text.endsWith('\n')) {
      return spans;
    }
    final rest = text.substring(0, text.length - 1);
    return [
      ...spans.take(spans.length - 1),
      if (rest.isNotEmpty) TextSpan(text: rest, style: last.style, recognizer: last.recognizer),
    ];
  }

  List<InlineSpan> _buildSup(uh.Element element) {
    return [
      TextSpan(
        text: element.innerText,
        style: _buildTextStyle()?.copyWith(fontFeatures: [const FontFeature.superscripts()]),
      ),
    ];
  }

  /*                Setup Functions                      */

  /// The color of the `color` attribute of [element] (`<font color="red">`), as the author gave it: pushed to the stack,
  /// true; none, false. It is shown in the theme when the text is put ([AuthorColors.text]).
  bool _tryPushColor(uh.Element element) {
    final color = parseLegacyColor(element.attributes['color']);
    if (color == null) {
      return false;
    }
    state.colorStack.add(color);
    return true;
  }

  /// The size of the `size` attribute of [element] (`<font size="3">`, see [FontSize]): pushed to the stack, true;
  /// none, false.
  bool _tryPushFontSize(uh.Element element) {
    final fontSize = FontSize.fromString(element.attributes['size']);
    if (fontSize.isValid) {
      state.fontSizeStack.add(_appFontSize(fontSize.value()));
    }
    return fontSize.isValid;
  }

  /// [spans], the content of a rich text of a post (the post, a spoiler, an aligned block), laid out in paragraphs with
  /// [typography] ([layOutParagraphs]). Not in a table, whose cells keep their lines together, nor outside a post.
  List<InlineSpan> _layOut(List<InlineSpan> spans) {
    final typography = this.typography;
    if (typography == null || state.tableDepth > 0) {
      return spans;
    }
    return layOutParagraphs(spans, typography, keepsLines: _keptLines.contains, keepsWhole: _keptWhole.contains);
  }

  /// Function to build text style, where you could run it everywhere and don't have to carry all style member logic.
  ///
  /// The colors the author gave are shown in the theme on what the text is on ([AuthorColors]): as given in a light
  /// theme, readable in a dark one. A link is in its own color (the theme's, or the one the author gave the link), a
  /// `<font color>` around it does not color it; text in it colored by the author keeps that color, the link's
  /// underline the link's.
  TextStyle? _buildTextStyle() {
    final theme = Theme.of(context);
    final linkDepth = state.linkDepth;
    final inLink = linkDepth != null;
    final ownColor = !inLink || state.colorStack.length > linkDepth ? state.colorStack.lastOrNull : null;
    // What the text is on: the nearest background, of the text or of the block it is in.
    final inline = state.backgroundColorStack.lastOrNull;
    final block = state.blockBackgroundStack.lastOrNull;
    final nearest = inline == null || (block != null && block.order > inline.order) ? block : inline;
    final pictureBehind = nearest != null && nearest.color == null;
    // On a picture: on the color painted under it, if any.
    final under = pictureBehind ? state.blockBackgroundStack.lastWhereOrNull((e) => e.color != null)?.color : null;
    // A color given in the block of the background (pushed after it) was chosen for it; one given around the block,
    // or the theme's, was not, and is made readable on it. The background of a piece of text is the author's for
    // whatever color the text has: `[color=white][backcolor=orange]` nests either way round.
    final onText = nearest != null && identical(nearest, inline);
    final ownInside = nearest != null && (onText || state.colorStack.length > nearest.colors);
    final linkInside = nearest != null && (onText || (state.linkOrder ?? -1) >= nearest.order);
    final ink = theme.textTheme.bodyMedium?.color ?? theme.colorScheme.onSurface;
    Color? shown(Color? authored, {required bool inside, required Color? fallback}) {
      if (nearest == null) {
        return authored == null ? fallback : _colors.text(authored);
      }
      final background = nearest.color;
      if (background == null) {
        return authored == null ? fallback : _colors.text(authored, on: under, pictureBehind: true);
      }
      if (authored != null && inside) {
        return _colors.text(authored, on: background);
      }
      return _colors.onBackground(authored ?? fallback ?? ink, background) ??
          (authored == null ? fallback : _colors.text(authored, on: background));
    }

    final primary = theme.colorScheme.primary;
    final color = ownColor != null
        ? shown(ownColor, inside: ownInside, fallback: null)
        : shown(inLink ? state.linkColor : null, inside: linkInside, fallback: inLink ? primary : null);
    final linkUnderline = inLink && state.linkUnderline;
    final decorationColor = linkUnderline && !state.underline && !state.lineThrough
        ? shown(state.linkColor, inside: linkInside, fallback: primary)
        : color;
    // Empty for `text-shadow: none`: none, not the shadows around.
    final shadows = state.shadowStack.lastOrNull;
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: color,
      // A post's content: its line height, no letter spacing (as the web page; it spread Chinese text apart).
      height: typography?.lineHeight,
      letterSpacing: typography == null ? null : 0,
      fontWeight: state.bold ? FontWeight.w600 : null,
      fontSize: state.fontSizeStack.lastOrNull,
      backgroundColor: inline?.color == null ? null : _colors.background(inline!.color!),
      decorationColor: decorationColor,
      decoration: TextDecoration.combine([
        if (state.underline || linkUnderline) TextDecoration.underline,
        if (state.lineThrough) TextDecoration.lineThrough,
      ]),
      fontStyle: state.italic ? FontStyle.italic : null,
      decorationThickness: state.underline || state.lineThrough || !linkUnderline ? 1.5 : 1,
      shadows: shadows,
    );

    return style;
  }
}
