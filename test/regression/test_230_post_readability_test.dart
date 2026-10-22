/// Post content reads better on a narrow screen (the second phase of the post display work, 2a).
///
/// Posts are often written with few line breaks: what the web page shows as a paragraph of a few lines (712 wide, line
/// height 1.5) was a wall of text on a phone, at the line height of the material body text (1.43), with letter
/// spacing and nothing between paragraphs. Checked here on small samples written after the real posts:
///
/// * the content of a post is laid out at a line height of 1.7, without letter spacing, with a gap of 8 between its
///   paragraphs; the html of anything else (a notice, a message) keeps the body text;
/// * a gap goes at a single line break between two paragraphs when one of them does not fit on a line where it is
///   shown (a phone, a tablet, the text scale), not at a blank line, between short lines (a poem, a list), next to an
///   image row or a block, in a table or in preformatted text; an image row does not move;
/// * the line height and the spacing are settings, saved and applied to the floors at once;
/// * long paragraphs can be cut after the end of a sentence (off by default), never inside quotes, after a decimal
///   point, an ellipsis that goes on, an abbreviation, a title, nor in a list, a heading, a quote, a table or code;
/// * a gap is a line break as tall as the spacing: the text of the floor without the gaps is the text as before (the
///   floor's "copy text" reads the html, not the layout).
library;

// HTML fixtures are split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/widgets/thread_content_layout_dialog.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode_view.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/utils/html/sentence_breaks.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';

/// Paragraphs longer than a line of a phone, each different.
const _long1 = '第一段的文字比较长，一行放不下，写帖子的人很少按回车，于是在手机上就变成了一大块。';
const _long2 = '第二段的文字也比较长，同样一行放不下，段落之间要有一点空白才看得出这是新的一段。';
const _long3 = '第三段的文字还是比较长，空行已经把它和上一段分开了，这里不用再多加一个段距了。';

/// Width of a post's content on a phone 390 wide (the floor card's margins and padding off).
const _phoneWidth = 346.0;

Widget _app(Widget child, {ThemeData? theme, double scale = 1}) => TranslationProvider(
  child: MaterialApp(
    theme: theme,
    home: Scaffold(
      body: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: _phoneWidth, child: child),
            ),
          ),
        ),
      ),
    ),
  ),
);

/// [html] as a post's content laid out with [typography] (none: as the html of a notice).
Widget _post(String html, PostTypography? typography) =>
    typography == null ? MunchedHtml(html) : PostTypographyScope(typography: typography, child: MunchedHtml(html));

Future<void> _pump(
  WidgetTester tester,
  String html, {
  PostTypography? typography = const PostTypography(),
  ThemeData? theme,
  double scale = 1,
}) async {
  await tester.pumpWidget(_app(_post(html, typography), theme: theme, scale: scale));
  await tester.pump();
  expect(tester.takeException(), isNull);
}

/// The outermost rich text of the content.
RenderParagraph _paragraph(WidgetTester tester) => tester.renderObject<RenderParagraph>(
  find.descendant(of: find.byType(MunchedHtml), matching: find.byType(RichText)).first,
);

String _plain(WidgetTester tester) => _paragraph(tester).text.toPlainText(includeSemanticsLabels: false);

/// Top of the character [index] of the content's text, in the content.
double _top(WidgetTester tester, int index) =>
    _paragraph(tester).getBoxesForSelection(TextSelection(baseOffset: index, extentOffset: index + 1)).first.top;

/// Every text span in [span], depth first.
Iterable<TextSpan> _spans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _spans(child);
    }
  }
}

/// The style of the text span holding [text] in the outermost rich text.
TextStyle? _styleOf(WidgetTester tester, String text) =>
    _spans(_paragraph(tester).text).firstWhere((e) => e.text?.contains(text) ?? false).style;

/// The gaps between paragraphs in every rich text on screen.
int _gapCount(WidgetTester tester) => [
  for (final e in find.byType(RichText).evaluate())
    ..._spans((e.widget as RichText).text).whereType<ParagraphGapSpan>(),
].length;

/// The text of [span] without the gaps between paragraphs.
String _withoutGaps(InlineSpan span) {
  final buffer = StringBuffer();
  void visit(InlineSpan span) {
    switch (span) {
      case ParagraphGapSpan():
        return;
      case TextSpan(:final text, :final children):
        buffer.write(text ?? '');
        children?.forEach(visit);
      default:
        buffer.write(span.toPlainText(includeSemanticsLabels: false));
    }
  }

  visit(span);
  return buffer.toString();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('the default layout of a post', () {
    testWidgets('line height 1.7 and no letter spacing; other html keeps the body text', (tester) async {
      await _pump(tester, _long1);
      expect(_styleOf(tester, '第一段')?.height, 1.7);
      expect(_styleOf(tester, '第一段')?.letterSpacing, 0);

      await _pump(tester, _long1, typography: null);
      final body = Theme.of(tester.element(find.byType(MunchedHtml))).textTheme.bodyMedium!;
      expect(_styleOf(tester, '第一段')?.height, body.height);
      expect(_styleOf(tester, '第一段')?.letterSpacing, body.letterSpacing);
      expect(_gapCount(tester), 0);
    });

    testWidgets('a gap of 8 between two paragraphs, a line of its own as tall as the gap', (tester) async {
      const html = '$_long1<br />\r\n$_long2';
      await _pump(tester, html);
      expect(_gapCount(tester), 1);
      final text = _plain(tester);
      expect(text, '$_long1\n\n$_long2');
      final lastOfFirst = text.indexOf('。');
      final firstOfSecond = text.indexOf('第二段');
      // One line (14 × 1.7) and the gap.
      expect(_top(tester, firstOfSecond) - _top(tester, lastOfFirst), closeTo(14 * 1.7 + 8, 0.5));
      // The lines of a paragraph are one line apart.
      expect(_top(tester, text.indexOf('第一段') + 30) - _top(tester, text.indexOf('第一段')), closeTo(14 * 1.7, 0.5));

      // Before: one line of the body text (20), nothing between the paragraphs.
      await _pump(tester, html, typography: null);
      final before = _plain(tester);
      expect(before, '$_long1\n$_long2');
      expect(_top(tester, before.indexOf('第二段')) - _top(tester, before.indexOf('。')), closeTo(20, 0.5));
    });

    testWidgets('the gap and the lines follow the text scale', (tester) async {
      await _pump(tester, '$_long1<br />$_long2', scale: 1.5);
      final text = _plain(tester);
      expect(_top(tester, text.indexOf('第二段')) - _top(tester, text.indexOf('。')), closeTo((14 * 1.7 + 8) * 1.5, 0.75));
    });

    testWidgets('no gap at a blank line, between short lines, next to an image row or a block', (tester) async {
      Future<int> gaps(String html) async {
        await _pump(tester, html);
        return _gapCount(tester);
      }

      // A blank line already parts the paragraphs: it is as it was.
      expect(await gaps('$_long1<br />\r\n<br />\r\n$_long3'), 0);
      expect(_plain(tester), '$_long1\n\n$_long3', reason: 'as before');
      // Short lines (a poem, a list of names, a post breaking its lines at every clause) stay together.
      expect(await gaps('她的身子柔若无骨<br />像所有飘忽美好的事物<br />蝉翼、棉花糖与金鱼尾巴'), 0);
      // A short line next to a long one: the long one is a paragraph.
      expect(await gaps('短的一行<br />$_long2'), 1);
      // A quote, a code block, a rule are blocks with room of their own.
      expect(await gaps('$_long1<div class="quote"><blockquote>$_long2</blockquote></div>$_long3'), 0);
      expect(await gaps('$_long1<br /><hr class="l" />$_long3'), 0);
      // Preformatted text keeps its lines; so do the cells of a table.
      expect(await gaps('<pre>$_long1\n$_long2</pre>'), 0);
      expect(
        await gaps('<table><tr><td>$_long1<br />$_long2</td><td>二</td></tr><tr><td>三</td><td>四</td></tr></table>'),
        0,
      );
      // In a spoiler and an aligned block, the paragraphs are parted as in the post.
      expect(
        await gaps(
          '<div class="spoiler"><div class="spoiler_control"><input type="button" class="spoiler_btn" value="展开">'
          '</div><div class="spoiler_content" style="display: none;">$_long1<br />$_long2</div></div>',
        ),
        0,
        reason: 'folded',
      );
      await tester.tap(find.byIcon(Icons.expand_more_outlined));
      await tester.pump();
      expect(_gapCount(tester), 1);
      expect(await gaps('<div align="center">$_long1<br />$_long2</div>'), 1);
    });

    testWidgets('the settings: a taller line, more space, no space at all', (tester) async {
      const html = '$_long1<br />$_long2';
      await _pump(tester, html, typography: const PostTypography(lineHeight: 2, paragraphSpacing: 16));
      var text = _plain(tester);
      expect(_top(tester, text.indexOf('第二段')) - _top(tester, text.indexOf('。')), closeTo(14 * 2 + 16, 0.5));
      expect(_styleOf(tester, '第一段')?.height, 2);

      await _pump(tester, html, typography: const PostTypography(paragraphSpacing: 0));
      text = _plain(tester);
      expect(_gapCount(tester), 0);
      expect(text, '$_long1\n$_long2');
      expect(_top(tester, text.indexOf('第二段')) - _top(tester, text.indexOf('。')), closeTo(14 * 1.7, 0.5));
    });

    testWidgets('a change of the settings lays the content out again at once', (tester) async {
      const html = '$_long1<br />$_long2';
      final notifier = ValueNotifier(const PostTypography());
      addTearDown(notifier.dispose);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder(
            valueListenable: notifier,
            builder: (_, typography, child) => PostTypographyScope(typography: typography, child: child!),
            child: const MunchedHtml(html),
          ),
        ),
      );
      double gap() {
        final text = _plain(tester);
        return _top(tester, text.indexOf('第二段')) - _top(tester, text.indexOf('。'));
      }

      expect(gap(), closeTo(14 * 1.7 + 8, 0.5));
      notifier.value = const PostTypography(lineHeight: 1.4, paragraphSpacing: 12);
      await tester.pump();
      expect(gap(), closeTo(14 * 1.4 + 12, 0.5));
    });

    testWidgets('dark mode: the same layout, the colors of the dark theme', (tester) async {
      await _pump(tester, '$_long1<br />$_long2', theme: ThemeData(brightness: Brightness.dark));
      expect(_gapCount(tester), 1);
      final style = _styleOf(tester, '第一段');
      expect(style?.height, 1.7);
      expect(style?.color, ThemeData(brightness: Brightness.dark).textTheme.bodyMedium?.color);
    });
  });

  group('the length of a line where the content is shown', () {
    testWidgets('a line holds the content width over the size of the text, in halves of a character', (
      tester,
    ) async {
      Future<double> lineWidth(Size size, double scale) async {
        tester.view
          ..devicePixelRatio = 1
          ..physicalSize = size;
        addTearDown(tester.view.reset);
        late double width;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: Builder(
                  builder: (context) {
                    width = postContentLineWidth(context);
                    return const SizedBox();
                  },
                ),
              ),
            ),
          ),
        );
        return width;
      }

      // A phone 390 wide: 390 − 2 × 6 (the floor's margins) − 2 × 16 (its padding) = 346, over 14, in halves.
      expect(await lineWidth(const Size(390, 844), 1), 24.5);
      expect(await lineWidth(const Size(360, 780), 1), 22.5);
      expect(await lineWidth(const Size(390, 844), 0.85), 29);
      expect(await lineWidth(const Size(390, 844), 1.3), 19);
      expect(await lineWidth(const Size(390, 844), 1.5), 16);
      // A tablet or a desktop window: the content is at most 712 wide.
      expect(await lineWidth(const Size(1280, 800), 1), 50.5);
      expect(await lineWidth(const Size(1280, 800), 1.5), 33.5);
      // A pixel more or less does not change it.
      expect(await lineWidth(const Size(391, 844), 1), 24.5);
    });

    testWidgets('a short line and a long paragraph depend on it', (tester) async {
      // About 30 wide each: two lines on a phone, one on a tablet.
      const a = '这一行在手机上放不下，在平板上就能放得下了，所以是短行吗？';
      const b = '第二行也差不多一样长，手机上两行，平板上一行，看在哪里显示。';
      await _pump(tester, '$a<br />$b');
      expect(_gapCount(tester), 1, reason: 'a phone');
      await _pump(tester, '$a<br />$b', typography: const PostTypography().withLineWidth(50));
      expect(_gapCount(tester), 0, reason: 'a tablet: a list of names stays together');

      const s = '月底完成了客户的案子以后，经理邀请我到他珍爱的料亭小酌一番，说是要好好犒劳大家。';
      const long = '$s$s$s$s';
      expect(sentenceBreaks(long), isNotEmpty);
      expect(sentenceBreaks(long, lineWidth: 50), isEmpty, reason: 'four lines on a tablet');
      expect(sentenceBreaks('$long$long', lineWidth: 50), isNotEmpty);
    });
  });

  group('image rows', () {
    late ImageCacheProvider cache;
    const urls = ['https://example.com/a.png', 'https://example.com/b.png', 'https://example.com/c.png'];

    /// A small image, the size of a smiley.
    const small = 'https://example.com/small.png';

    setUp(() {
      cache = ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio(), cookie: CookieProvider.buildEmpty()));
      getIt.registerSingleton<ImageCacheProvider>(cache);
    });
    tearDown(() async {
      await cache.dispose();
      await getIt.reset();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    });

    Future<void> seed(WidgetTester tester) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(390, 2000);
      addTearDown(tester.view.reset);
      for (final url in [...urls, small]) {
        final (w, h) = url == small ? (20, 20) : (300, 120);
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.blue);
        final picture = recorder.endRecording();
        final image = await tester.runAsync(() => picture.toImage(w, h));
        picture.dispose();
        final provider = ResizeImage.resizeIfNeeded(390, null, CachedImageProvider(url));
        final key = await provider.obtainKey(ImageConfiguration.empty);
        PaintingBinding.instance.imageCache.putIfAbsent(
          key,
          () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image!))),
        );
      }
    }

    Rect rect(WidgetTester tester, String url) =>
        tester.getRect(find.byWidgetPredicate((w) => w is NetworkIndicatorImage && w.src == url));

    testWidgets('images on lines of their own and between paragraphs do not move', (tester) async {
      await seed(tester);
      final html =
          '<img src="${urls[0]}" /><br />\r\n<img src="${urls[1]}" /> <br />\r\n$_long1<br />\r\n'
          '<img src="${urls[2]}" /><br />\r\n$_long2';
      final before = <Rect>[];
      final after = <Rect>[];
      for (final (typography, rects) in [(null, before), (const PostTypography(), after)]) {
        await tester.pumpWidget(_app(_post(html, typography)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        rects.addAll(urls.map((url) => rect(tester, url)));
      }
      expect(_gapCount(tester), 0, reason: 'no paragraph next to another one');
      // The image rows stay put and keep their size: no gap, no taller row.
      expect(after[0], before[0]);
      expect(after[1], before[1]);
      expect(after[1].top - after[0].bottom, before[1].top - before[0].bottom);
      expect(after[2].size, before[2].size);
      // Below the text the image moved down by what the taller lines of the paragraph took, nothing more.
      final text = _plain(tester);
      final lines = (after[2].top - after[1].bottom) - (before[2].top - before[1].bottom);
      expect(lines, greaterThan(0));
      expect(text, contains('第一段'));
    });

    testWidgets('a line holding only a small image keeps its height', (tester) async {
      await seed(tester);
      // A smiley on the last line of the post, and one on a line of its own between two paragraphs.
      for (final html in [
        '$_long1<br />\r\n<img src="$small" />',
        '$_long1<br />\r\n<img src="$small" /><br />\r\n$_long2',
      ]) {
        final heights = <double>[];
        for (final typography in [null, const PostTypography()]) {
          await tester.pumpWidget(_app(_post(html, typography)));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final image = tester.getRect(find.byWidgetPredicate((w) => w is NetworkIndicatorImage && w.src == small));
          final text = tester.getRect(find.byType(RichText).first);
          // From the image to the end of the post (the image's line, and what follows).
          heights.add(text.bottom - image.top);
          expect(_gapCount(tester), 0, reason: html);
        }
        // Below the image only the text after it may be taller (1.7 instead of 1.43 a line).
        expect(heights[1], greaterThanOrEqualTo(heights[0]), reason: html);
        if (!html.endsWith(_long2)) {
          expect(heights[1], heights[0], reason: 'the last line, a small image alone');
        }
      }
    });
  });

  group('the text', () {
    testWidgets('without the gaps, the text is the text as before', (tester) async {
      const html = '$_long1<br />\r\n$_long2<br />\r\n<br />\r\n$_long3';
      await _pump(tester, html, typography: null);
      final before = _plain(tester);
      expect(before, '$_long1\n$_long2\n\n$_long3');
      await _pump(tester, html, typography: const PostTypography(splitLongParagraphs: true));
      expect(_gapCount(tester), 1);
      expect(_plain(tester), '$_long1\n\n$_long2\n\n$_long3', reason: 'the gap is a line break');
      expect(_withoutGaps(_paragraph(tester).text), before);

      // A paragraph cut after the end of its sentences is one paragraph without the gaps.
      final long = List.generate(4, (i) => '这是第$i句话，用来把一段文字写得很长很长，长到手机上要好几行才放得下。').join();
      await _pump(tester, long, typography: const PostTypography(splitLongParagraphs: true));
      expect(_gapCount(tester), greaterThan(0));
      expect(_withoutGaps(_paragraph(tester).text), long);
    });
  });

  group('long paragraphs cut after the end of a sentence', () {
    // About 40 wide each.
    const s1 = '月底完成了客户的案子以后，经理邀请我到他珍爱的料亭小酌一番，说是要好好犒劳大家。';
    const s2 = '我本身并不善饮，但是领导的好意着实令人盛情难却，只好硬着头皮跟着一起去了那里。';
    const s3 = '为了少喝些酒，在聊完公司里的大小事以后，我多少有些为之语塞，只能低头吃菜。';
    const s4 = '我并非擅于闲聊攀谈之人，也不想拿他人的家务事作为聊天的话题，只好一直听他说。';
    // Long text without the end of a sentence, about 40 wide.
    const filler = '这一段话用逗号连在一起，没有句末的标点，怎么都不会断开，';

    String pieceAt(String p, int cut) => p.substring(cut, cut + 6);

    test('a long paragraph is cut after the ends of sentences, a short one is not', () {
      expect(textWidth(s1 + s2), lessThan(longParagraphLines * phoneLineWidth));
      expect(sentenceBreaks(s1 + s2), isEmpty);
      const p = s1 + s2 + s3 + s4;
      expect(textWidth(p), greaterThan(longParagraphLines * phoneLineWidth));
      final cuts = sentenceBreaks(p);
      // The first piece is two sentences (one is not wide enough), the rest is long enough to stand alone.
      expect(cuts, [(s1 + s2).length]);
      expect(pieceAt(p, cuts.single), s3.substring(0, 6));
      // The last sentence is never cut off on its own when too short.
      expect(sentenceBreaks('$filler$filler$filler$filler$filler。短的结尾。'), isEmpty);
    });

    test('the cut goes after the closing quote, the white space after the end', () {
      const p = '$filler$filler他说：「我知道了。」接着$filler$filler';
      expect(pieceAt(p, sentenceBreaks(p).single), '接着这一段话');
      // A half width mark after a Chinese character, the space after it.
      const q = '$filler$filler$filler真的好吧! $filler$filler';
      expect(pieceAt(q, sentenceBreaks(q).single), filler.substring(0, 6));
    });

    for (final (name, middle) in [
      ('inside quotes', '他说：「我知道了。你先走吧！我马上就到」然后'),
      ('inside curly quotes', '他说：“我知道了。你先走吧！我马上就到”然后'),
      ('after a title ending with a mark', '我最喜欢《LoveLive!》和《凭你也想讨伐魔王？》这两部'),
      ('after the end of an aside', '（这里说的是第二季。）后来'),
      ('after a decimal point', '一共花了3.5个小时，版本v1.0也'),
      ('between the dots of an ellipsis', '然后...就没有然后了，等等。。。他'),
      ('after an ellipsis the sentence goes on after', '他……走了，就这样'),
      ('in a URL', '地址是 https://www.example.com/forum.php?mod=viewthread&tid=1 这个'),
      ('after an abbreviation or an initial', '和 Mr. Smith 还有 J. K. Rowling 一起'),
      ('after a name ending with a mark in Chinese text', '看了 Love Live! Sunshine 以后'),
      ('before the items of a list on one line', '推荐：FREE！   弹丸论破   魔法科高中的劣等生'),
    ]) {
      test('no cut $name', () {
        final p = '$filler$filler$filler$middle$filler$filler$filler';
        expect(sentenceBreaks(p), isEmpty, reason: middle);
        // The same paragraph with a plain end of a sentence there is cut.
        expect(sentenceBreaks('$filler$filler$filler$middle。$filler$filler$filler'), hasLength(1), reason: middle);
      });
    }

    test('English sentences', () {
      const p =
          'The quick brown fox jumps over the lazy dog near the river bank today. '
          'Mr. Smith and Dr. Jones watched it at 3.5 meters away, e.g. from the bridge. '
          'Then they went home for a cup of tea and a long talk about it all. '
          'Nobody expected the fox to come back the next morning, but it did.';
      // Not after `today.` (too short a piece), `Mr.`, `Dr.`, `3.5` or `e.g.`; not after `all.` (too short a piece).
      expect(sentenceBreaks(p), [p.indexOf('Then')]);
    });

    testWidgets('in a post: off by default, on with the setting', (tester) async {
      const p = s1 + s2 + s3 + s4;
      await _pump(tester, p);
      expect(_gapCount(tester), 0);
      expect(_plain(tester), p);

      await _pump(tester, p, typography: const PostTypography(splitLongParagraphs: true));
      expect(_gapCount(tester), 1);
      final text = _plain(tester);
      expect(text, '$s1$s2\n\n$s3$s4');
      // The piece after the cut starts a line of its own, the gap above it.
      final end = text.indexOf('\n') - 1;
      expect(_top(tester, end + 3) - _top(tester, end), closeTo(14 * 1.7 + 8, 0.5));
      expect(
        _paragraph(tester).getBoxesForSelection(TextSelection(baseOffset: end + 3, extentOffset: end + 4)).first.left,
        closeTo(0, 0.01),
      );

      // Without paragraph spacing the pieces still start a line of their own, nothing between them.
      await _pump(tester, p, typography: const PostTypography(paragraphSpacing: 0, splitLongParagraphs: true));
      expect(_gapCount(tester), 1);
      expect(_plain(tester), '$s1$s2\n$s3$s4');
      final noSpace = _plain(tester).indexOf('\n') - 1;
      expect(_top(tester, noSpace + 2) - _top(tester, noSpace), closeTo(14 * 1.7, 0.5));
    });

    testWidgets('a link cut in two still opens', (tester) async {
      const p = '<a href="https://www.example.com/a">$s1$s2$s3$s4</a>';
      await _pump(tester, p, typography: const PostTypography(splitLongParagraphs: true));
      expect(_gapCount(tester), 1);
      final pieces = _spans(_paragraph(tester).text).where((e) => e.text != null && e.text!.contains('。')).toList();
      expect(pieces.length, greaterThanOrEqualTo(2));
      expect(pieces.map((e) => e.recognizer), everyElement(isNotNull));
    });

    testWidgets('not in a list, a heading, a quote, a table or code', (tester) async {
      const p = s1 + s2 + s3 + s4;
      const split = PostTypography(splitLongParagraphs: true);
      for (final html in [
        '<ul><li>$p</li></ul>',
        '<h3>$p</h3>',
        '<div class="quote"><blockquote>$p</blockquote></div>',
        '<table><tr><td>$p</td><td>二</td></tr><tr><td>三</td><td>四</td></tr></table>',
        '<pre>$p</pre>',
        '<div class="blockcode"><div id="code_1"><ol><li>$p</li></ol></div></div>',
      ]) {
        await _pump(tester, html, typography: split);
        expect(_gapCount(tester), 0, reason: html);
      }
      // A paragraph after the list is cut as usual (and parted from the list).
      await _pump(tester, '<ul><li>一项</li></ul>$p', typography: split);
      expect(_plain(tester), '•  一项\n\n$s1$s2\n\n$s3$s4');
    });
  });

  group('the experimental bbcode renderer', () {
    Future<void> pumpNodes(WidgetTester tester, List<BbNode> nodes, PostTypography typography) async {
      await tester.pumpWidget(
        _app(PostTypographyScope(typography: typography, child: PostBbcodeView(nodes))),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    testWidgets('the same line height and gaps, in an aligned block and a spoiler too', (tester) async {
      const text = BbText('$_long1\n$_long2');
      await pumpNodes(tester, const [text], const PostTypography());
      expect(_gapCount(tester), 1);
      final root = tester.widget<RichText>(find.byType(RichText).first).text;
      // The style of the text, merged down from the spans around it (a span cut by a gap gives it to its pieces).
      TextStyle? styleOf(InlineSpan span, TextStyle? parent) {
        if (span is! TextSpan) {
          return null;
        }
        final style = parent?.merge(span.style) ?? span.style;
        if (span.text?.contains('第一段') ?? false) {
          return style;
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          final found = styleOf(child, style);
          if (found != null) {
            return found;
          }
        }
        return null;
      }

      expect(styleOf(root, null)?.height, 1.7);

      await pumpNodes(tester, const [
        BbAlign('center', [text]),
      ], const PostTypography());
      expect(_gapCount(tester), 1);

      await pumpNodes(tester, const [
        BbSpoiler('展开', [text]),
      ], const PostTypography());
      await tester.tap(find.byIcon(Icons.expand_more_outlined));
      await tester.pump();
      expect(_gapCount(tester), 1);
    });

    testWidgets('long paragraphs are cut, not in a list', (tester) async {
      const p =
          '月底完成了客户的案子以后，经理邀请我到他珍爱的料亭小酌一番，说是要好好犒劳大家。'
          '我本身并不善饮，但是领导的好意着实令人盛情难却，只好硬着头皮跟着一起去了那里。'
          '为了少喝些酒，在聊完公司里的大小事以后，我多少有些为之语塞，只能低头吃菜。'
          '我并非擅于闲聊攀谈之人，也不想拿他人的家务事作为聊天的话题，只好一直听他说。';
      const split = PostTypography(splitLongParagraphs: true);
      await pumpNodes(tester, const [BbText(p)], split);
      expect(_gapCount(tester), 1);
      await pumpNodes(tester, const [
        BbList('', [
          [BbText(p)],
        ]),
      ], split);
      expect(_gapCount(tester), 0);
    });
  });

  group('settings', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      await settings.init();
    });
    tearDown(() async {
      await settings.dispose();
      await db.close();
    });

    test('defaults (also with settings from an older version, without them): line height 1.7, spacing 8, long '
        'paragraphs not cut; the values are saved', () async {
      expect(SettingsKeys.threadContentLineHeight.defaultValue, 1.7);
      expect(SettingsKeys.threadContentParagraphSpacing.defaultValue, 8.0);
      expect(SettingsKeys.threadContentSplitLongParagraphs.defaultValue, isFalse);
      expect(settings.currentSettings.postTypography, const PostTypography());

      await settings.setValue<double>(SettingsKeys.threadContentLineHeight, 2);
      await settings.setValue<double>(SettingsKeys.threadContentParagraphSpacing, 12);
      await settings.setValue(SettingsKeys.threadContentSplitLongParagraphs, true);
      const picked = PostTypography(lineHeight: 2, paragraphSpacing: 12, splitLongParagraphs: true);
      expect(settings.currentSettings.postTypography, picked);

      final restarted = SettingsRepository(storage);
      addTearDown(restarted.dispose);
      await restarted.init();
      expect(restarted.currentSettings.postTypography, picked);
    });

    testWidgets('the dialog previews the values picked and returns them', (tester) async {
      PostTypography? result;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp.router(
            routerConfig: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (context, _) => Scaffold(
                    body: TextButton(
                      onPressed: () async => result = await showDialog<PostTypography>(
                        context: context,
                        builder: (_) => const ThreadContentLayoutDialog(
                          initial: PostTypography(splitLongParagraphs: true),
                          contentScale: 1,
                        ),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // The line of the preview is as long as the dialog is wide: not compared here.
      PostTypography preview() => tester
          .widget<PostTypographyScope>(find.byKey(const ValueKey('thread-content-layout-preview')))
          .typography
          .withLineWidth(PostTypography.defaultLineWidth);
      expect(preview(), const PostTypography(splitLongParagraphs: true));
      expect(_gapCount(tester), 1, reason: 'the preview has two paragraphs');

      final sliders = find.byType(Slider);
      tester.widget<Slider>(sliders.at(0)).onChanged!(2);
      tester.widget<Slider>(sliders.at(1)).onChanged!(14.4);
      await tester.pump();
      expect(preview(), const PostTypography(lineHeight: 2, paragraphSpacing: 14, splitLongParagraphs: true));
      expect(_styleOf(tester, '预览')?.height, 2);

      // Back to the defaults, then a value and OK.
      await tester.tap(find.text(t.general.reset));
      await tester.pump();
      expect(preview(), const PostTypography(splitLongParagraphs: true));
      tester.widget<Slider>(sliders.at(0)).onChanged!(1.4);
      await tester.pump();
      await tester.tap(find.text(t.general.ok));
      await tester.pumpAndSettle();
      expect(result, const PostTypography(lineHeight: 1.4, splitLongParagraphs: true));
    });
  });

  group('the floors of the thread page', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;
    late UserBlockRepository blocks;
    late AuthenticationRepository auth;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
      await settings.init();
      getIt
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        )
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(
            dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _ThreadAdapter(_threadPage),
          ),
        );
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      blocks = UserBlockRepository(storage);
      auth = AuthenticationRepository(user: _alice);
      ThreadAuthorCache.clear();
    });

    tearDown(() async {
      await settingsBloc.close();
      await blocks.dispose();
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    /// The thread page on a phone 390 wide: a line of a floor holds 24.5 characters.
    Future<void> pump(WidgetTester tester) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final info = NotificationInfoRepository();
      final counts = NotificationStateCubit(info);
      final cubit = UserBlockCubit(repository: blocks, currentUid: () => _alice.uid, authStatus: auth.status);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const ThreadPage(
              threadID: '1264975',
              findPostID: null,
              pageNumber: '1',
              overrideReverseOrder: false,
              overrideWithExactOrder: null,
            ),
          ),
        ],
      );
      addTearDown(() async {
        router.dispose();
        await cubit.close();
        await info.dispose();
        await counts.close();
      });
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<AuthenticationRepository>.value(value: auth),
              RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<UserBlockCubit>.value(value: cubit),
                BlocProvider<NotificationBloc>.value(
                  value: _Notifications(const NotificationState(status: NotificationStatus.success)),
                ),
                BlocProvider<NotificationStateCubit>.value(value: counts),
              ],
              child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
            ),
          ),
        ),
      );
      await _settle(tester);
    }

    Finder floor() => find.textContaining('第二段', findRichText: true);

    PostTypography typographyOfFloor(WidgetTester tester) => tester
        .widget<PostTypographyScope>(find.ancestor(of: floor().first, matching: find.byType(PostTypographyScope)))
        .typography;

    testWidgets('a floor is laid out with the settings, and again when they change', (tester) async {
      await pump(tester);
      expect(floor(), findsWidgets);
      expect(typographyOfFloor(tester), const PostTypography());
      expect(_gapCount(tester), 1);

      await tester.runAsync(() => settings.setValue<double>(SettingsKeys.threadContentLineHeight, 2));
      await tester.runAsync(() => settings.setValue(SettingsKeys.threadContentSplitLongParagraphs, true));
      await _settle(tester);
      expect(typographyOfFloor(tester), const PostTypography(lineHeight: 2, splitLongParagraphs: true));
      final paragraph = tester.renderObject<RenderParagraph>(floor().first);
      final style = _spans(paragraph.text).firstWhere((e) => e.text?.contains('第一段') ?? false).style;
      expect(style?.height, 2);

      await tester.runAsync(() => settings.setValue<double>(SettingsKeys.threadContentParagraphSpacing, 0));
      await _settle(tester);
      expect(_gapCount(tester), 0);
    });
  });
}

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

/// A thread page with one floor of two paragraphs (synthetic, grounded in the Discuz template).
const _threadPage =
    '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=1264975" /></head><body>
<div id="postlist"><h1 class="ts"><span id="thread_subject">排版</span></h1><div class="bm">
<div id="post_1"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=1"><em>1</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1000" class="xi2">Alice</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_1">$_long1<br />
$_long2</div></div></div></td>
</tr></tbody></table></div>
</div></div>
</body></html>''';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Notification bloc holding a fixed state; the thread page only reads it.
final class _Notifications extends Fake implements NotificationBloc {
  _Notifications(this.state);

  @override
  void add(NotificationEvent event) {}

  @override
  final NotificationState state;

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// Never answers: avatars are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Serves one thread page for every request.
final class _ThreadAdapter implements HttpClientAdapter {
  _ThreadAdapter(this.page);

  final String page;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.method, 'GET', reason: 'layout tests must never perform a forum write');
    return ResponseBody.fromString(
      page,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
