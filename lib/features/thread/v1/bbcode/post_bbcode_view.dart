import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/int.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/smilies.dart';
import 'package:tsdm_client/features/thread/v1/utils/offline_floor.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/html/author_style.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/utils/html/types.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/widgets/card/code_card.dart';
import 'package:tsdm_client/widgets/card/spoiler_card.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';
import 'package:tsdm_client/widgets/quoted_text.dart';
import 'package:tsdm_client/widgets/text_widget_span.dart';

/// The content of a floor with the experimental app renderer on: the floor's message drawn from its bbcode when
/// [decidePostBbcode] allows it, the rest of the floor's html around it as html; otherwise the floor's html as
/// before ([MunchedHtml] of [Post.data]).
///
/// A floor showing smilies waits for the forum's smilies table ([SmiliesRepository], by the version its answer
/// names) and shows the html until the table is there; without the repository in the tree it keeps the html. A floor
/// read back from an offline copy of its thread only reads the saved table, it never asks the forum for one.
class PostBbcodeBody extends StatefulWidget {
  /// Constructor.
  const PostBbcodeBody(this.post, {super.key});

  /// The floor.
  final Post post;

  @override
  State<PostBbcodeBody> createState() => _PostBbcodeBodyState();
}

class _PostBbcodeBodyState extends State<PostBbcodeBody> with LoggerMixin {
  SmiliesRepository? _smilies;
  PostBbcodeDecision? _decision;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final smilies = context.readOrNull<SmiliesRepository>();
    if (smilies != _smilies) {
      _smilies?.table.removeListener(_onTable);
      _smilies = smilies?..table.addListener(_onTable);
      _decision = null;
    }
  }

  @override
  void didUpdateWidget(PostBbcodeBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.post != widget.post) {
      _decision = null;
    }
  }

  @override
  void dispose() {
    _smilies?.table.removeListener(_onTable);
    super.dispose();
  }

  void _onTable() {
    if (mounted && _decision is PostBbcodeFallback && postBbcodeNeedsSmilies(widget.post)) {
      setState(() => _decision = null);
    }
  }

  PostBbcodeDecision _decide() {
    final post = widget.post;
    SmiliesTable? table;
    final version = post.smiliesVersion;
    if (postBbcodeNeedsSmilies(post) && version != null) {
      // Read back offline: the saved table only, the forum is never asked (the html when it is not there).
      table = isOfflineFloor(context) ? _smilies?.savedTableFor(version) : _smilies?.tableFor(version);
    }
    final decision = decidePostBbcode(post, smilies: table);
    if (decision is PostBbcodeFallback) {
      debug('post ${post.postID} keeps its html: ${decision.reason}');
    }
    return decision;
  }

  @override
  Widget build(BuildContext context) {
    final decision = _decision ??= _decide();
    return switch (decision) {
      PostBbcodeFallback() => MunchedHtml(widget.post.data),
      PostBbcodeRender(:final nodes, :final htmlBefore, :final htmlAfter) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (htmlBefore.isNotEmpty) MunchedHtml(htmlBefore),
          PostBbcodeView(nodes),
          if (htmlAfter.isNotEmpty) MunchedHtml(htmlAfter),
        ],
      ),
    };
  }
}

/// Draws [nodes] (a floor's message read from its bbcode by [decidePostBbcode]) with the widgets and the text style
/// the html renderer uses for the same content: the quote box, the code and spoiler cards, images opening the image
/// sheet, links opening in the app, the font colors adapted to the dark theme.
///
/// Built once and kept until the nodes, the theme, the text scale or the locale change, as [MunchedHtml].
class PostBbcodeView extends StatefulWidget {
  /// Constructor.
  const PostBbcodeView(this.nodes, {super.key});

  /// What to draw.
  final List<BbNode> nodes;

  @override
  State<PostBbcodeView> createState() => _PostBbcodeViewState();
}

class _PostBbcodeViewState extends State<PostBbcodeView> {
  Widget? _content;
  ThemeData? _theme;
  TextScaler? _textScaler;
  Locale? _locale;
  PostTypography? _typography;
  final _recognizers = <GestureRecognizer>[];

  void _reset() {
    _content = null;
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    final typography = PostTypographyScope.maybeOf(context);
    if (theme != _theme || textScaler != _textScaler || locale != _locale || typography != _typography) {
      _theme = theme;
      _textScaler = textScaler;
      _locale = locale;
      _typography = typography;
      _reset();
    }
  }

  @override
  void didUpdateWidget(PostBbcodeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodes != widget.nodes) {
      _reset();
    }
  }

  @override
  void dispose() {
    _reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _content ??= ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: htmlContentMaxWidth),
    child: Text.rich(
      style: const TextStyle(height: kTextHeightNone),
      TextSpan(children: _SpanBuilder(context, _recognizers, _typography).buildContent(widget.nodes)),
    ),
  );
}

/// Step of the card elevation per nesting level, as the html renderer.
const _elevationStep = 0.2;

final class _SpanBuilder {
  _SpanBuilder(this.context, this.recognizers, this.typography);

  final BuildContext context;
  final List<GestureRecognizer> recognizers;

  /// Line height and paragraphs of a post's content, as the html renderer; null outside a post.
  final PostTypography? typography;

  /// Spans of lists: never cut into paragraphs ([layOutParagraphs]).
  final _lists = Set<InlineSpan>.identity();

  /// [nodes] as the content of a rich text of its own (the post, a spoiler, an aligned block): in paragraphs as the
  /// html renderer lays out a post's content ([layOutParagraphs]).
  List<InlineSpan> buildContent(List<BbNode> nodes) {
    final spans = build(nodes);
    final typography = this.typography;
    return typography == null ? spans : layOutParagraphs(spans, typography, keepsWhole: _lists.contains);
  }

  double _elevation = -_elevationStep;

  static const _lineBreak = TextSpan(text: '\n');

  List<InlineSpan> build(List<BbNode> nodes, {String? link}) {
    final out = <InlineSpan>[];
    var atLineStart = true;
    for (final node in nodes) {
      if (node.isBlock) {
        if (!atLineStart) {
          out.add(_lineBreak);
        }
        out
          ..add(_block(node))
          ..add(_lineBreak);
        atLineStart = true;
        continue;
      }
      final spans = _inline(node, link: link);
      if (spans.isEmpty) {
        continue;
      }
      out.addAll(spans);
      atLineStart = node is BbText && node.text.endsWith('\n');
    }
    while (out.isNotEmpty && identical(out.last, _lineBreak)) {
      out.removeLast();
    }
    return out;
  }

  List<InlineSpan> _inline(BbNode node, {String? link}) => switch (node) {
    BbText(:final text, :final style) =>
      text.isEmpty
          ? const []
          : [
              TextSpan(
                text: text,
                style: _style(style, link: link),
                recognizer: _recognizer(link),
              ),
            ],
    BbSmiley(:final smiley) => [_image(smiley.url, link: link)],
    BbImage(:final url, :final width, :final height) => [_image(url, width: width, height: height, link: link)],
    BbAttachment(:final attachment) => _attachment(attachment, link: link),
    BbLink(:final href, :final children, :final auto) => _link(href, children, auto: auto),
    BbQuote() || BbCodeBlock() || BbSpoiler() || BbList() || BbAlign() || BbDivider() => [_block(node)],
  };

  InlineSpan _block(BbNode node) {
    switch (node) {
      case BbQuote(:final children):
        return textWidgetSpan(QuotedText.rich(TextSpan(children: build(children))));
      case BbCodeBlock(:final code):
        _elevation += _elevationStep;
        final span = textWidgetSpan(CodeCard(code: code, elevation: _elevation));
        _elevation -= _elevationStep;
        return span;
      case BbSpoiler(:final title, :final children):
        _elevation += _elevationStep;
        final elevation = _elevation;
        final content = buildContent(children);
        _elevation -= _elevationStep;
        return textWidgetSpan(
          SpoilerCard(
            title: TextSpan(text: title),
            content: TextSpan(children: content),
            elevation: elevation,
          ),
        );
      case BbList(:final type, :final items):
        final spans = <InlineSpan>[];
        for (final (index, item) in items.indexed) {
          final leading = switch (type) {
            '1' => '${index + 1}. ',
            'a' => '${String.fromCharCode(0x61 + index % 26)}. ',
            'A' => '${String.fromCharCode(0x41 + index % 26)}. ',
            _ => '•  ',
          };
          spans
            ..add(TextSpan(text: leading, style: _style(const BbStyle())))
            ..addAll(build(item));
          if (index < items.length - 1) {
            spans.add(_lineBreak);
          }
        }
        final list = TextSpan(children: spans);
        _lists.add(list);
        return list;
      case BbAlign(:final align, :final children):
        final textAlign = switch (align) {
          'center' => TextAlign.center,
          'right' => TextAlign.right,
          _ => TextAlign.left,
        };
        return textWidgetSpan(
          Row(
            children: [
              Expanded(
                child: Text.rich(TextSpan(children: buildContent(children)), textAlign: textAlign),
              ),
            ],
          ),
        );
      case BbDivider():
        return const WidgetSpan(child: Divider());
      case BbText() || BbSmiley() || BbImage() || BbAttachment() || BbLink():
        return TextSpan(children: _inline(node));
    }
  }

  List<InlineSpan> _link(String href, List<BbNode> children, {required bool auto}) {
    final content = build(children, link: href);
    if (auto) {
      return [
        TextSpan(
          children: [
            for (final span in content)
              if (span is TextSpan)
                TextSpan(
                  text: span.text,
                  recognizer: span.recognizer,
                  style: (span.style ?? const TextStyle()).copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                )
              else
                span,
          ],
        ),
      ];
    }
    // Only an image in the link: no mark before it, as the html renderer.
    if (children.length == 1 && (children.single is BbImage || children.single is BbSmiley)) {
      return content;
    }
    final colorScheme = Theme.of(context).colorScheme;
    final Widget? mark;
    if (href.isUserSpaceUrl) {
      final text = children.whereType<BbText>().map((e) => e.text).join();
      mark = text.contains('@')
          ? null
          : Text(
              '@',
              style: TextStyle(color: colorScheme.primary),
              textScaler: TextScaler.noScaling,
            );
    } else if (typography == null || postLinkHasMark(href)) {
      // Only a link out of the forum is marked in a post, as the html renderer marks them.
      mark = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(href.startsWith('mailto:') ? Icons.email_outlined : Icons.link, size: 18, color: colorScheme.primary),
          const SizedBox(width: 2),
        ],
      );
    } else {
      mark = null;
    }
    return [
      TextSpan(
        children: [
          if (mark != null)
            WidgetSpan(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(onTap: () async => _openUrl(href), child: mark),
              ),
            ),
          ...content,
        ],
      ),
    ];
  }

  InlineSpan _image(String url, {int? width, int? height, String? link}) {
    if (tmpImpellerWorkaroundUrls.contains(url)) {
      // The "back to the quoted floor" arrow of old quotes, the same button the html renderer shows for it.
      return WidgetSpan(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 24, minWidth: 24, maxHeight: 24, minHeight: 24),
          child: OverlayTextScale(
            child: IconButton(
              icon: Icon(Icons.navigate_before_outlined, color: Theme.of(context).colorScheme.tertiary),
              constraints: const BoxConstraints(maxWidth: 24, minWidth: 24, maxHeight: 24, minHeight: 24),
              padding: EdgeInsets.zero,
              tooltip: context.t.workaroundRedirect,
              onPressed: link != null ? () async => context.dispatchAsUrl(link) : null,
            ),
          ),
        ),
      );
    }
    return _networkImage(url, width: width, height: height, link: link);
  }

  InlineSpan _networkImage(String url, {int? width, int? height, String? link}) => WidgetSpan(
    child: GestureDetector(
      onTap: () async => showImageActionBottomSheet(context: context, imageUrl: url, hrefUrl: link),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width?.toDouble() ?? double.infinity,
          maxHeight: height?.toDouble() ?? double.infinity,
        ),
        child: NetworkIndicatorImage(url),
      ),
    ),
  );

  List<InlineSpan> _attachment(PostAttachment attachment, {String? link}) {
    final tr = context.t.postCard.bbcode;
    if (attachment.locked || (attachment.isImage ? attachment.url : attachment.download).isEmpty) {
      return [_placeholder(Icons.lock_outline, '${attachment.filename}\n${tr.attachmentLocked}')];
    }
    if (attachment.isImage) {
      return [_image(attachment.url, width: attachment.width > 0 ? attachment.width : null, link: link)];
    }
    final colorScheme = Theme.of(context).colorScheme;
    final download = attachment.download;
    return [
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Icon(Icons.attach_file_outlined, size: 18, color: colorScheme.primary),
      ),
      TextSpan(
        text: attachment.filename,
        style: _style(const BbStyle(), link: download),
        recognizer: _recognizer(download),
      ),
      TextSpan(
        text: ' (${attachment.filesize.withSizeHint()})',
        style: _style(const BbStyle())?.copyWith(color: colorScheme.outline),
      ),
    ];
  }

  /// Something not shown: an icon and a line, nothing fetched.
  InlineSpan _placeholder(IconData icon, String text) {
    final colorScheme = Theme.of(context).colorScheme;
    return textWidgetSpan(
      Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: colorScheme.outline),
            const SizedBox(width: 8),
            Flexible(
              child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.outline)),
            ),
          ],
        ),
      ),
    );
  }

  /// The text style of [style], as the html renderer builds it for the same `<font>`, `<strong>`…
  ///
  /// The colors are shown in the theme as the html renderer shows them ([AuthorColors]): as given in a light theme,
  /// readable in a dark one; a link in a post is underlined, its underline in the theme's link color.
  TextStyle? _style(BbStyle style, {String? link}) {
    final theme = Theme.of(context);
    final colors = _colors ??= AuthorColors(theme);
    // `[backcolor]` is a background in css on the web page, `[color]` the color attribute of a `<font>`.
    final background = style.backgroundColor == null ? null : parseCssColor(style.backgroundColor!);
    final authored = parseLegacyColor(style.color);
    final color = authored != null
        ? colors.text(authored, on: background)
        : (link != null ? theme.colorScheme.primary : null);
    final size = FontSize.fromString(style.size);
    final bodySize = theme.textTheme.bodyMedium?.fontSize ?? webPostFontSize;
    final linkUnderline = link != null && typography != null;
    return theme.textTheme.bodyMedium?.copyWith(
      color: color,
      height: typography?.lineHeight,
      letterSpacing: typography == null ? null : 0,
      fontWeight: style.bold ? FontWeight.w600 : null,
      fontSize: size.isValid ? size.value() * bodySize / webPostFontSize : null,
      backgroundColor: background == null ? null : colors.background(background),
      decorationColor: linkUnderline && !style.underline && !style.strike ? theme.colorScheme.primary : color,
      decoration: TextDecoration.combine([
        if (style.underline || linkUnderline) TextDecoration.underline,
        if (style.strike) TextDecoration.lineThrough,
      ]),
      fontStyle: style.italic ? FontStyle.italic : null,
      decorationThickness: style.underline || style.strike || !linkUnderline ? 1.5 : 1,
    );
  }

  /// How the author's colors are shown in the theme, see [_style].
  AuthorColors? _colors;

  /// Open [url] as a link of the html renderer does: a tap on desktop, the end of a press on mobile, its info on a
  /// long press or a secondary tap.
  GestureRecognizer? _recognizer(String? url) {
    if (url == null) {
      return null;
    }
    final GestureRecognizer recognizer;
    if (isMobile) {
      recognizer = LongPressGestureRecognizer()
        ..onLongPressCancel = () async {
          await _openUrl(url);
        }
        ..onLongPress = () async {
          await _showUrlInfo(url);
        };
    } else {
      recognizer = TapGestureRecognizer()
        ..onTapDown = (_) async {
          await _openUrl(url);
        }
        ..onSecondaryTap = () async {
          await _showUrlInfo(url);
        };
    }
    recognizers.add(recognizer);
    return recognizer;
  }

  Future<void> _openUrl(String url) async {
    if (url.startsWith('mailto:')) {
      await showEmailBottomSheet(context: context, address: url.substring('mailto:'.length));
      return;
    }
    await context.dispatchAsUrl(url);
  }

  Future<void> _showUrlInfo(String url) async {
    if (url.startsWith('mailto:')) {
      await showEmailBottomSheet(context: context, address: url.substring('mailto:'.length));
      return;
    }
    await showUrlInfoBottomSheet(context: context, url: url);
  }
}
