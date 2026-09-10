import 'package:collection/collection.dart';
import 'package:dart_bbcode_web_colors/dart_bbcode_web_colors.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart';
import 'package:tsdm_client/features/red_packet/widgets/red_packet_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/html/adaptive_color.dart';
import 'package:tsdm_client/utils/html/cloudflare_email.dart';
import 'package:tsdm_client/utils/html/css_parser.dart';
import 'package:tsdm_client/utils/html/munch_options.dart';
// Netease card
import 'package:tsdm_client/utils/html/netease_card.dart';
// Newcomer card
import 'package:tsdm_client/utils/html/newcomer_report_card.dart';
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
import 'package:universal_html/html.dart' as uh;

/// Use the same span to append line break.
const emptySpan = TextSpan(text: '\n');

/// Step when elevation changes.
const _elevationStep = 0.2;

/// List type composes `<ol>` and `<ul>`
sealed class _ListType {}

/// `<ul>` ordered list tag.
final class _ListUnordered extends _ListType {}

/// `<ol>` ordered list tag.
final class _ListOrdered extends _ListType {
  /// Constructor.
  _ListOrdered(this.number);

  /// Number in order.
  final int number;
}

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
  final muncher = _Muncher(context, parseLockedWithPurchase: parseLockedWithPurchase, options: options);

  // Undo Cloudflare's email obfuscation first, so addresses read and tap like the author wrote them.
  rewriteCloudflareEmails(rootElement);
  final ret = muncher._munch(rootElement);
  if (ret == null) {
    return const SizedBox.shrink();
  }
  // Remove trailing empty spaces.
  while (ret.lastOrNull == emptySpan) {
    ret.removeLast();
  }

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

  /// If true, use [String.trim], if false, use [String.trimLeft].
  bool trimAll = false;

  /// Flag to indicate whether in state of repeated line wrapping.
  bool inRepeatWrapLine = false;

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

  /// All colors currently used.
  ///
  /// Use as a stack because only the latest font works on font.
  final colorStack = <Color>[];

  /// All background colors currently used.
  ///
  /// Use as a stack because only the latest font works on font.
  final backgroundColorStack = <Color>[];

  /// All font sizes currently used.
  ///
  /// Use as a stack because only the latest size works on font.
  final fontSizeStack = <double>[];

  // TODO: Handle indent level when list type nested.
  /// All munching state of list types.
  ///
  /// Can be nested.
  final listStack = <_ListType>[];

  /// An internal field to save field current values.
  _MunchState? _reservedState;

  /// Save current state [_reservedState].
  void save() {
    _reservedState = this;
  }

  /// Restore state from [_reservedState].
  void restore() {
    if (_reservedState != null) {
      return;
    }
    bold = _reservedState!.bold;
    underline = _reservedState!.underline;
    lineThrough = _reservedState!.lineThrough;
    center = _reservedState!.center;
    textAlign = _reservedState!.textAlign;
    colorStack
      ..clear()
      ..addAll(_reservedState!.colorStack);
    fontSizeStack
      ..clear()
      ..addAll(_reservedState!.fontSizeStack);
    elevation = _reservedState!.elevation;

    _reservedState = null;
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
  _Muncher(this.context, {required this.parseLockedWithPurchase, required this.options});

  /// Context to build widget when munching.
  final BuildContext context;

  //////// Configs ////////
  bool parseLockedWithPurchase;

  /// Munch state to use when munching.
  final _MunchState state = _MunchState();

  /// Additional options control injected by caller.
  final MunchOptions options;

  /// Map to store div classes and corresponding munch functions.
  Map<String, List<InlineSpan>? Function(uh.Element)>? _divMap;

  /// Regex to match netease player iframe.
  final _neteasePlayerRe = RegExp(r'//music\.163\.com/outchain/player\?.*id=(?<id>\d+).*');

  List<InlineSpan>? _munch(uh.Element rootElement) {
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
    final nodes = rootElement.nodes.where((node) => node is! uh.Text || node.text!.trim().isNotEmpty).toList();
    if (nodes.length > 1 && nodes.every(_isInlineImage) && spanList.every((span) => span is WidgetSpan)) {
      return [
        WidgetSpan(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: spanList.cast<WidgetSpan>().map((span) => span.child).toList(),
            ),
          ),
        ),
      ];
    }
    return spanList;
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
          // Mark already munched text, all heading br nodes were passed.

          String? text;
          // When inPre is true, current node is inside a `<pre>` node.
          // Should reserve the original style.
          if (state.inPre) {
            text = node.text;
          } else if (state.trimAll) {
            text = node.text?.trim();
          } else {
            text = node.text?.trimLeft();
          }
          // If text is trimmed to empty, maybe it is an '\n' before trimming.
          if (text?.isEmpty ?? true) {
            if (state.trimAll) {
              return null;
            }
            if (state.inRepeatWrapLine) {
              return null;
            }
            state.inRepeatWrapLine = true;
            return null;
          }

          // Attach url to open when `onTap`.
          GestureRecognizer? recognizer;
          if (state.tapUrl != null) {
            recognizer = _buildUrlRecognizer(state.tapUrl!);
          }
          state
            ..headingBrNodePassed = true
            ..inRepeatWrapLine = false;

          // Ignore wrap text;
          // state.wrapInWord ? text?.split('').join('\u200B') : text;

          // TODO: Support text-shadow.
          if (recognizer == null && options.renderUrl && text != null && text.contains('://')) {
            // Bare urls in plain text (the forum does not link them in notices, e.g. the reason of a rating).
            return _linkifySpans(text, _buildTextStyle());
          }
          return [TextSpan(text: text, recognizer: recognizer, style: _buildTextStyle())];
        }

      case uh.Node.ELEMENT_NODE:
        {
          final element = node as uh.Element;
          final localName = element.localName;

          // Skip invisible nodes.
          if (element.attributes['style']?.contains('display: none') ?? false) {
            return null;
          }

          // TODO: Handle <ul> and <li> marker
          // Parse according to element types.
          final span = switch (localName) {
            'img' => _buildImg(node),
            'br' => state.headingBrNodePassed ? [emptySpan] : null,
            'font' => _buildFont(node),
            'strong' => _buildStrong(node),
            'u' => _buildUnderline(node),
            'strike' => _buildLineThrough(node),
            'p' => _buildP(node),
            'span' => _buildSpan(node),
            'blockquote' => _buildBlockQuote(node),
            'div' => _munchDiv(node),
            'a' => _buildA(node),
            'tr' => _buildTr(node),
            'td' => _buildTd(node),
            'h1' => _buildH1(node),
            'h2' => _buildH2(node),
            'h3' => _buildH3(node),
            'h4' => _buildH4(node),
            // Ordered list in web page uses ul tag and has class "litype_1".
            'ul' when !node.classes.contains('litype_1') => _buildUl(node),
            'ol' || 'ul' when node.classes.contains('litype_1') => _buildOl(node),
            'li' => _buildLi(node),
            'code' => _buildCode(node),
            'dl' => _buildDl(node),
            'b' => _buildB(node),
            'i' => _buildI(node),
            'hr' => _buildHr(node),
            'pre' => _buildPre(node),
            'details' => _buildDetails(node),
            'iframe' => _buildIframe(node),
            'table' when node.classes.contains('cgtl') => _buildNewcomerReport(node),
            'table' => _buildTable(node),
            'sup' => _buildSup(node),
            'ignore_js_op' ||
            'table' ||
            'tbody' ||
            'dd' ||
            'marquee' ||
            'nav' ||
            'section' ||
            'fieldset' ||
            'pre' => _munch(node),
            'center' => _munchAligned(node, TextAlign.center, _munch),
            String() => null,
          };
          return span;
        }
    }
    return null;
  }

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
      ];
    }

    return [
      WidgetSpan(
        child: GestureDetector(
          onTap: () async => showImageActionBottomSheet(context: context, imageUrl: url, hrefUrl: hrefUrl),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: imgWidth ?? double.infinity, maxHeight: imgHeight ?? double.infinity),
            child: NetworkIndicatorImage(url),
          ),
        ),
      ),
    ];
  }

  List<InlineSpan>? _buildFont(uh.Element element) {
    // Setup color
    final hasColor = _tryPushColor(element);
    // Setup font size.
    final hasFontSize = _tryPushFontSize(element);
    // Setup background color.
    final hasBackgroundColor = _tryPushBackgroundColor(element);
    // Munch!
    final ret = _munch(element);

    // Restore color
    if (hasColor) {
      state.colorStack.removeLast();
    }
    if (hasFontSize) {
      state.fontSizeStack.removeLast();
    }
    if (hasBackgroundColor) {
      state.backgroundColorStack.removeLast();
    }

    // Restore color.
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
  static TextAlign? _blockAlign(uh.Element element) => switch (element.attributes['align']) {
    'left' => TextAlign.left,
    'center' => TextAlign.center,
    'right' => TextAlign.right,
    _ => null,
  };

  /// Munch [element] with [munch] and lay the result out with [align].
  ///
  /// Alignment requires the whole rendered page to a fixed max width that equals to website page, otherwise the result
  /// differs from the web page for a "center" or "right" alignment.
  ///
  /// Text align only has effect on the [RichText]'s children, not its children's children, so the spans are wrapped
  /// in a full-width [Text.rich] carrying the alignment; `state.textAlign` holds the alignment while munching so
  /// builders creating their own rich text can apply it too.
  List<InlineSpan>? _munchAligned(
    uh.Element element,
    TextAlign align,
    List<InlineSpan>? Function(uh.Element element) munch,
  ) {
    final origAlign = state.textAlign;
    state.textAlign = align;
    final ret = munch(element);
    state.textAlign = origAlign;
    if (ret == null) {
      return null;
    }
    return [
      WidgetSpan(
        child: Row(
          children: [
            Expanded(
              child: Text.rich(TextSpan(children: ret), textAlign: align),
            ),
          ],
        ),
      ),
    ];
  }

  List<InlineSpan>? _buildP(uh.Element element) {
    final align = _blockAlign(element);
    if (align == null) {
      return _munch(element);
    }
    return _munchAligned(element, align, _munch);
  }

  List<InlineSpan>? _buildSpan(uh.Element element) {
    final styleEntries = element.attributes['style']
        ?.split(';')
        .map((e) {
          final x = e.trim().split(':');
          return (x.firstOrNull?.trim(), x.lastOrNull?.trim());
        })
        .whereType<(String, String)>()
        .map((e) => MapEntry(e.$1, e.$2))
        .toList();
    if (styleEntries == null) {
      final ret = _munch(element);
      if (ret == null) {
        return null;
      }
      return [...ret, emptySpan];
    }

    final styleMap = Map.fromEntries(styleEntries);
    final color = styleMap['color'];
    final hasColor = _tryPushColor(element, colorString: color);
    final fontSize = styleMap['font-size'];
    final hasFontSize = _tryPushFontSize(element, fontSizeString: fontSize);
    final hasBackgroundColor = _tryPushBackgroundColor(element);

    final ret = _munch(element);

    if (hasColor) {
      state.colorStack.removeLast();
    }
    if (hasFontSize) {
      state.fontSizeStack.removeLast();
    }
    if (hasBackgroundColor) {
      state.backgroundColorStack.removeLast();
    }
    if (ret == null) {
      return null;
    }

    return [...ret, emptySpan];
  }

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
    state.save();
    final span = element.innerText.isEmpty ? null : TextSpan(children: _munch(element));
    state.restore();
    return [WidgetSpan(child: QuotedText.rich(span)), emptySpan];
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
    };

    // The popup markup of the forum's red packet plugin (envelope animation, password box, buttons) only works with
    // its javascript; it must not leak into the post as text.
    if (element.id == 'hb_mask') {
      return null;
    }

    state.inDiv = true;
    // Find the first munch executor, use `_munch` if none found.
    final executor = _divMap!.entries.firstWhereOrNull((e) => element.classes.contains(e.key))?.value ?? _munch;
    // `[align=center]` is a `<div align="center">` around the aligned content (GitHub #47).
    final align = _blockAlign(element);
    final ret = align == null ? executor(element) : _munchAligned(element, align, executor);
    state.inDiv = origInDiv;

    if (ret != null && ret.isNotEmpty && ret.last != emptySpan) {
      ret.add(emptySpan);
    }
    return ret;
  }

  List<InlineSpan>? _buildModerationNotice(uh.Element element) {
    final content = _munch(element);
    if (content == null) {
      return null;
    }
    final theme = Theme.of(context);
    return [
      emptySpan,
      WidgetSpan(
        child: Padding(
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
    final ret = [WidgetSpan(child: RedPacketCard(entry, elevation: state.elevation)), emptySpan];
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
    final ret = WidgetSpan(
      child: CodeCard(code: text, elevation: state.elevation),
    );
    state.elevation -= _elevationStep;
    return [ret];
  }

  List<InlineSpan>? _buildLockedArea(uh.Element element) {
    final lockedArea = Locked.fromLockDivNode(element, allowWithPurchase: parseLockedWithPurchase);
    if (lockedArea.isNotValid()) {
      return null;
    }

    state
      ..headingBrNodePassed = true
      ..elevation += _elevationStep;
    final ret = [WidgetSpan(child: LockedCard(lockedArea, elevation: state.elevation)), emptySpan];
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
      final (:avatarUrl, :name, :content) = parseReviewElement(row);
      if ((name == null || name.isEmpty) && (content == null || content.isEmpty)) {
        continue;
      }
      spans
        ..add(
          WidgetSpan(
            child: ReviewCard(name: name ?? '', content: content ?? '', avatarUrl: avatarUrl),
          ),
        )
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
    final content = _munch(contentNode);
    state.elevation -= _elevationStep;
    if (content == null) {
      return null;
    }
    while (content.lastOrNull == emptySpan) {
      content.removeLast();
    }
    state.headingBrNodePassed = true;
    final ret = WidgetSpan(
      child: SpoilerCard(
        title: TextSpan(text: title),
        content: TextSpan(children: content),
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
      WidgetSpan(child: BountyCard(price: price, resolved: false)),
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
      WidgetSpan(child: BountyCard(price: price, resolved: true)),
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
      WidgetSpan(
        child: BountyAnswerCard(
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
    state
      ..tapUrl = url.prependHost()
      ..wrapInWord = true;
    final ret = _munch(element);
    state.wrapInWord = false;
    if (ret == null) {
      return null;
    }
    state.tapUrl = null;
    if (hasOnlyImg) {
      // Only a <img> node inside the current <a> node.
      // Do NOT show url prefix.
      return ret;
    }
    final Widget? content;
    if (url.isUserSpaceUrl) {
      if (element.innerText.contains('@')) {
        // Text already has the label, do not add duplicate one.
        content = null;
      } else {
        content = Text(
          '@',
          style: TextStyle(color: Theme.of(context).colorScheme.primary),
          textScaler: .noScaling,
        );
      }
    } else {
      final IconData prefixIcon;
      if (url.startsWith('mailto:')) {
        prefixIcon = Icons.email_outlined;
      } else {
        prefixIcon = Icons.link;
      }

      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(prefixIcon, size: state.fontSizeStack.lastOrNull ?? 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 2),
        ],
      );
    }

    return [
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
    state.trimAll = true;
    final ret = _munch(element);
    state.trimAll = false;
    if (ret == null) {
      return null;
    }
    return ret;
  }

  List<InlineSpan>? _buildTd(uh.Element element) {
    state.trimAll = true;
    final ret = _munch(element);
    state.trimAll = false;
    if (ret == null) {
      return null;
    }

    // Removed trailing '\n' here to fix white space found in tables.
    // Add it back or think in another way if caused other issues.
    return ret;
  }

  List<InlineSpan>? _buildH1(uh.Element element) {
    state.fontSizeStack.add(FontSize.size6.value());
    final ret = _munch(element);
    state.fontSizeStack.removeLast();
    if (ret == null) {
      return null;
    }
    return [emptySpan, ...ret, emptySpan];
  }

  List<InlineSpan>? _buildH2(uh.Element element) {
    state.fontSizeStack.add(FontSize.size5.value());
    final ret = _munch(element);
    state.fontSizeStack.removeLast();
    if (ret == null) {
      return null;
    }
    return [emptySpan, ...ret, emptySpan];
  }

  List<InlineSpan>? _buildH3(uh.Element element) {
    state.fontSizeStack.add(FontSize.size4.value());
    final ret = _munch(element);
    state.fontSizeStack.removeLast();
    if (ret == null) {
      return null;
    }
    return [emptySpan, ...ret, emptySpan];
  }

  List<InlineSpan>? _buildH4(uh.Element element) {
    state.fontSizeStack.add(FontSize.size3.value());
    final ret = _munch(element);
    state.fontSizeStack.removeLast();
    if (ret == null) {
      return null;
    }
    return [emptySpan, ...ret, emptySpan];
  }

  /// Build `<ul>` tag.
  List<InlineSpan>? _buildUl(uh.Element element) {
    state.listStack.add(_ListUnordered());
    final ret = _munch(element);
    state.listStack.removeLast();
    return ret;
  }

  /// Build `<ol>` tag.
  List<InlineSpan>? _buildOl(uh.Element element) {
    state.listStack.add(_ListOrdered(1));
    final ret = _munch(element);
    state.listStack.removeLast();
    return ret;
  }

  /// Build `<li>` tag.
  List<InlineSpan>? _buildLi(uh.Element element) {
    final ret = _munch(element);
    if (ret == null) {
      return null;
    }

    // final String leading
    final leading = switch (state.listStack.lastOrNull) {
      _ListUnordered() => '•  ',
      _ListOrdered(:final number) => () {
        // Pop and push a larger number.
        state.listStack.removeLast();
        state.listStack.add(_ListOrdered(number + 1));
        return '$number. ';
      }(),
      null => () {
        error('failed to detect html list leading type: empty list stack');
        return '•  ';
      }(), // Unreachable but handle it.
    };

    if (!(ret.lastOrNull?.toPlainText().endsWith('\n') ?? false)) {
      // Append a trailing <br> if not have it.
      // This is a render issue on the server side, same bbcode may produce different result, with or without trailing
      // line break.
      return [TextSpan(text: leading), ...ret, emptySpan];
    } else {
      return [TextSpan(text: leading), ...ret];
    }
  }

  /// <code>xxx</code> tags. Mainly for github.com
  List<InlineSpan>? _buildCode(uh.Element element) {
    state.fontSizeStack.add(FontSize.size2.value());
    final ret = _munch(element);
    state.fontSizeStack.removeLast();
    if (ret == null) {
      return null;
    }
    state
      ..headingBrNodePassed = true
      ..elevation += _elevationStep;
    final ret2 = WidgetSpan(
      child: Card(
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

  List<InlineSpan> _buildHr(uh.Element element) {
    return [const WidgetSpan(child: Divider())];
  }

  List<InlineSpan>? _buildPre(uh.Element element) {
    // Avoid reset parent's inPre state.
    final alreadyInPre = state.inPre;
    if (!alreadyInPre) {
      state.inPre = true;
    }
    final ret = _munch(element);
    if (!alreadyInPre) {
      state.inPre = false;
    }
    return ret;
  }

  /// Build a detail card here.
  List<InlineSpan>? _buildDetails(uh.Element element) {
    final summary = element.children.elementAtOrNull(0);
    state.elevation += _elevationStep;
    final dataSpanList = element.children.skip(1).map(_munch).whereType<List<InlineSpan>>().toList();
    state.elevation -= _elevationStep;
    if (summary == null || dataSpanList.isEmpty) {
      return null;
    }

    final summarySpan = _munch(summary);
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
    final ret = WidgetSpan(
      child: SpoilerCard(
        title: TextSpan(children: summarySpan),
        content: TextSpan(children: dataSpanList.flattened.toList()),
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
      return [WidgetSpan(child: NeteaseCard(neteasePlayerId))];
    }
    return null;
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
    final data = element
        .querySelectorRootAll('tbody > tr')
        .map((e) => (e.querySelector('th')?.innerText.trim(), e.querySelector('td')?.innerText.trim()))
        .whereType<(String, String)>()
        .map((e) => NewcomerReportInfo(title: e.$1, data: e.$2))
        .toList();

    return [WidgetSpan(child: NewcomerReportCard(data))];
  }

  List<InlineSpan>? _buildTable(uh.Element element) {
    final allTr = element.querySelectorRootAll('tbody > tr');
    if (allTr.isEmpty) {
      // Impossible
      return null;
    }
    if (allTr.length == 1) {
      // Not a regular table, only something wrapped.
      return _munch(element.querySelectorRootAll('tbody').first);
    }
    final tableRows = <TableRow>[];
    final allTableRowContent = <List<Widget>>[];
    var columnMaxCount = 0;
    for (final tr in allTr) {
      final tableRowContent = <Widget>[];
      final tds = tr.querySelectorRootAll('td');
      for (final td in tds) {
        tableRowContent.add(Text.rich(TextSpan(children: _buildTd(td))));
      }
      if (tds.length > columnMaxCount) {
        columnMaxCount = tds.length;
      }
      allTableRowContent.add(tableRowContent);
    }

    for (final row in allTableRowContent) {
      if (row.length < columnMaxCount) {
        row.addAll(List<Widget>.generate(columnMaxCount - row.length, (_) => sizedBoxEmpty));
      }
    }

    // Some tables do not have the same column width on each row.
    // Fill them.
    //
    // Only a workaround on unbalanced tables.
    //
    // FIXME: Support rowspan and colspan attr.
    tableRows.addAll(allTableRowContent.map((e) => TableRow(children: e)).toList());

    return [
      WidgetSpan(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const MaxIntrinsicColumnWidth(maxWidth: htmlContentMaxWidth),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: tableRows,
            border: TableBorder.all(color: Theme.of(context).colorScheme.surfaceContainer),
          ),
        ),
      ),
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

  /// Try parse color from [element].
  /// When provide [colorString], use that in advance.
  ///
  /// If has valid color, push to stack and return true.
  bool _tryPushColor(uh.Element element, {String? colorString}) {
    // Trim and add alpha value for "#ffafc7".
    // Set to an invalid color value if "color" attribute not found.
    final attr = colorString ?? element.attributes['color'];
    final color = attr.toColor();
    if (color != null) {
      if (Theme.of(context).brightness == Brightness.dark) {
        state.colorStack.add(Color(color).adaptiveDark());
      } else {
        state.colorStack.add(Color(color));
      }
      return true;
    }
    return false;
  }

  bool _tryPushBackgroundColor(uh.Element element) {
    final attr = element.attributes['style'];
    if (attr == null) {
      return false;
    }
    final color = parseCssString(attr)?.backgroundColor;
    if (color != null) {
      if (Theme.of(context).brightness == Brightness.dark) {
        state.backgroundColorStack.add(color.adaptiveDark());
      } else {
        state.backgroundColorStack.add(color);
      }
      return true;
    }
    return false;
  }

  /// Try parse font size from [element].
  /// When provide [fontSizeString], use that in advance.
  ///
  /// If has valid color, push to stack and return true.
  bool _tryPushFontSize(uh.Element element, {String? fontSizeString}) {
    final fontSize = FontSize.fromString(fontSizeString ?? element.attributes['size']);
    if (fontSize.isValid) {
      state.fontSizeStack.add(fontSize.value());
    }
    return fontSize.isValid;
  }

  /// Function to build text style, where you could run it everywhere and don't have to carry all style member logic.
  TextStyle? _buildTextStyle() {
    final color = state.colorStack.lastOrNull ?? (state.tapUrl != null ? Theme.of(context).colorScheme.primary : null);
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: color,
      fontWeight: state.bold ? FontWeight.w600 : null,
      fontSize: state.fontSizeStack.lastOrNull,
      backgroundColor: state.backgroundColorStack.lastOrNull,
      decorationColor: color,
      decoration: TextDecoration.combine([
        if (state.underline) TextDecoration.underline,
        if (state.lineThrough) TextDecoration.lineThrough,
      ]),
      fontStyle: state.italic ? FontStyle.italic : null,
      decorationThickness: 1.5,
    );

    return style;
  }
}
