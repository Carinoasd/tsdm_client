/// With a large system font the cards in a post (spoilers, quotes, code blocks, hidden content, red packets, reviews,
/// bounties, music, tables...) were scaled twice, and tables in a post never wrapped.
///
/// A paragraph lays a widget inside its text (a `WidgetSpan`) out at its width divided by the text scale and paints it
/// scaled up by the text scale (flutter/flutter#126962). The text in the card read the same text scale again: at 1.3
/// it was 1.69 times as large, the cards were crowded and broke lines badly. PR #189 only fixed the newcomer report
/// card.
///
/// A table in a post sat in a horizontal scroll view with every column as wide as its longest cell: a long cell never
/// wrapped and ran off the screen, the reader had to scroll sideways line by line.
library;

// HTML fixtures are split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/poll/cubit/poll_cubit.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/features/red_packet/widgets/red_packet_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/netease_card.dart';
import 'package:tsdm_client/utils/html/newcomer_report_card.dart';
import 'package:tsdm_client/utils/html/post_table.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/card/bounty_answer_card.dart';
import 'package:tsdm_client/widgets/card/bounty_card.dart';
import 'package:tsdm_client/widgets/card/code_card.dart';
import 'package:tsdm_client/widgets/card/lock_card/locked_card.dart';
import 'package:tsdm_client/widgets/card/poll_card.dart';
import 'package:tsdm_client/widgets/card/review_card.dart';
import 'package:tsdm_client/widgets/card/spoiler_card.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';
import 'package:tsdm_client/widgets/quoted_text.dart';
import 'package:universal_html/parsing.dart';

const _avatarUrl = 'https://example.com/uc_server/avatar.png';

/// Every card the post renderer builds, with fake content.
final _cards = <_Card>[
  _Card(
    'spoiler',
    '<div class="spoiler"><div class="spoilerheader"><input type="button" class="spoilerbutton" value="展开看看" /> '
        '（點擊展開 / 收起）</div><div class="spoilerbody" style="display: none;"><table><td>折叠里的内容，展开后才看得到'
        '</td></table></div></div>',
    () => find.byType(SpoilerCard),
    open: _expandSpoiler,
  ),
  _Card(
    'details',
    '<details><summary>摘要标题</summary><div>详情里的内容</div></details>',
    () => find.byType(SpoilerCard),
    open: _expandSpoiler,
  ),
  _Card('quote', '<blockquote>引用别人说过的一段话</blockquote>', () => find.byType(QuotedText)),
  _Card(
    'code block',
    '<div class="blockcode"><div id="code_1"><ol><li>print("hello");</li><li>return 0;</li></ol></div></div>',
    () => find.byType(CodeCard),
  ),
  _Card('inline code', '行内 <code>inline_code()</code> 代码', () => find.byType(Card)),
  _Card(
    'hidden content',
    '<div class="locked">如果您要查看本帖隐藏内容请<a href="forum.php?mod=post&amp;action=reply&amp;fid=1&amp;tid=1">'
        '回复</a></div>',
    () => find.byType(LockedCard),
  ),
  _Card(
    'review',
    '<div class="cm"><div class="pstl"><div class="psta"><a><img src="$_avatarUrl"></a></div>'
        '<div class="psti"><a class="xi2">reviewer</a>&nbsp;&nbsp;点评的内容 <span class="xg1">发表于 2020-1-1</span></div>'
        '</div></div>',
    () => find.byType(ReviewCard),
  ),
  _Card(
    'red packet',
    '<div class="hb-entry" data-tid="1" onclick="hongbaoOpen(this)"><div class="icon"></div><div> '
        '<div class="t1">恭喜发财，大吉大利</div><div class="t2">拼手气红包 · 剩 10/10 份 · 点击领取</div></div></div>',
    () => find.byType(RedPacketCard),
  ),
  _Card('bounty', '<div class="rusld z"><cite>20</cite></div>', () => find.byType(BountyCard)),
  _Card('resolved bounty', '<div class="rsld z"><cite>20</cite></div>', () => find.byType(BountyCard)),
  _Card(
    'bounty best answer',
    '<div class="rwdbst"><h3 class="psth">最佳答案</h3><div class="pstl"><div class="psta"><img src="$_avatarUrl"></div>'
        '<div class="psti"><p class="xi2"><a href="home.php?mod=space&amp;uid=1" class="xw1">answerer</a>'
        '<a href="javascript:;">查看完整内容</a></p><div class="mtn">这是最佳答案的内容</div></div></div></div>',
    () => find.byType(BountyAnswerCard),
  ),
  _Card(
    'moderation notice',
    '<div>正文末尾<div class="modact">本主题由 管理团队 于 3 小时前 添加图章 置顶</div>后续内容</div>',
    () => find.ancestor(of: find.byIcon(Icons.manage_history_outlined), matching: find.byType(Container)).first,
  ),
  _Card(
    'centered text',
    '<div align="center">居中的一行文字</div>',
    () => find.byWidgetPredicate((w) => w is Text && w.textAlign == TextAlign.center),
  ),
  _Card(
    'table',
    '<table><tr><th>名称</th><td>值</td></tr><tr><th>说明</th><td>表格里比较长的一段说明文字，在窄的屏幕上要换行</td></tr></table>',
    () => find.byType(PostTable),
  ),
  _Card(
    'music',
    '<iframe src="https://music.163.com/outchain/player?type=2&amp;id=12345&amp;auto=0&amp;height=66"></iframe>',
    () => find.byType(NeteaseCard),
  ),
  _Card(
    'newcomer report',
    '<div class="rcd-card"><div class="rcd-h">报到详细信息</div><table>'
        '<tr><th>昵称</th><td class="rcd-v">Alice</td></tr><tr><th>兴趣爱好</th><td class="rcd-v">看书</td></tr>'
        '</table></div>',
    () => find.byType(NewcomerReportCard),
  ),
];

final class _Card {
  _Card(this.name, this.html, this.finder, {this.open});

  final String name;
  final String html;
  final Finder Function() finder;

  /// Brings the content of the card on screen, e.g. expands a spoiler.
  final Future<void> Function(WidgetTester tester)? open;
}

Future<void> _expandSpoiler(WidgetTester tester) async {
  await tester.tap(find.byType(OutlinedButton));
  await tester.pumpAndSettle();
}

/// Answers the music page with a song.
final class _MusicPageAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '<html><body><em class="f-ff2">Song</em><p class="des s-fc4"><span title="Singer">Singer</span></p></body></html>',
    200,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=utf-8'],
    },
  );

  @override
  void close({bool force = false}) {}
}

/// How large the glyphs of [paragraph] end up on the screen relative to its font size: the scale of everything it is
/// painted through times its own text scale.
double _effectiveScale(RenderParagraph paragraph) {
  final left = paragraph.localToGlobal(Offset.zero);
  final right = paragraph.localToGlobal(Offset(paragraph.size.width, 0));
  return (right - left).distance / paragraph.size.width * paragraph.textScaler.scale(14) / 14;
}

/// Every piece of text on the screen with something in it. Icons are not text, they never follow the text scale.
List<RenderParagraph> _paragraphs(WidgetTester tester) {
  final icons = tester
      .renderObjectList<RenderParagraph>(find.descendant(of: find.byType(Icon), matching: find.byType(RichText)))
      .toSet();
  return tester
      .renderObjectList<RenderParagraph>(find.byType(RichText))
      .where((e) => !icons.contains(e) && e.size.width > 0.5 && e.text.toPlainText().trim().isNotEmpty)
      .toList();
}

Rect _globalRect(RenderBox box) =>
    Rect.fromPoints(box.localToGlobal(Offset.zero), box.localToGlobal(box.size.bottomRight(Offset.zero)));

/// Puts an image of [width] x [height] for [provider] in the image cache, the test does not load it from the network.
Future<void> _seed(WidgetTester tester, ImageProvider provider, {int width = 40, int height = 40}) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = Colors.blue);
  final picture = recorder.endRecording();
  final image = await tester.runAsync(() => picture.toImage(width, height));
  picture.dispose();
  final key = await provider.obtainKey(ImageConfiguration.empty);
  PaintingBinding.instance.imageCache.putIfAbsent(
    key,
    () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image!))),
  );
}

/// An image in the post on a screen of [screenWidth]: decoded at the width of the screen.
Future<void> _seedPostImage(WidgetTester tester, String url, double screenWidth, {int width = 40, int height = 40}) =>
    _seed(
      tester,
      ResizeImage.resizeIfNeeded(screenWidth.toInt(), null, CachedImageProvider(url)),
      width: width,
      height: height,
    );

Future<void> _seedAvatars(WidgetTester tester) async {
  for (final name in ['reviewer', 'answerer']) {
    await _seed(
      tester,
      CachedImageProvider(_avatarUrl, fallbackImageUrl: noAvatarUrl, usage: ImageUsageInfoUserAvatar(name)),
    );
  }
}

/// The horizontal scroll positions of the tables on the screen.
List<ScrollPosition> _horizontalScrolls(WidgetTester tester) => tester
    .stateList<ScrollableState>(find.ancestor(of: find.byType(PostTable), matching: find.byType(Scrollable)))
    .map((e) => e.position)
    .where((e) => e.axis == Axis.horizontal)
    .toList();

/// Whether the text of [paragraph] is laid out on one line: as wide as it is unwrapped.
bool _oneLine(RenderParagraph paragraph) =>
    paragraph.getMaxIntrinsicWidth(double.infinity) <= paragraph.size.width + 0.01;

/// How many lines the text of [paragraph] is laid out on.
int _lines(RenderParagraph paragraph) =>
    (paragraph.size.height / paragraph.getFullHeightForCaret(const TextPosition(offset: 0))).round();

/// The text on the screen that contains [text].
RenderParagraph _paragraphOf(WidgetTester tester, String text) => tester.renderObject<RenderParagraph>(
  find.descendant(of: find.textContaining(text), matching: find.byType(RichText)),
);

/// The text in the table on the screen that is exactly one of [texts].
Iterable<RenderParagraph> _cellsOf(WidgetTester tester, Set<String> texts) => tester
    .renderObjectList<RenderParagraph>(find.descendant(of: find.byType(PostTable), matching: find.byType(RichText)))
    .where((e) => texts.contains(e.text.toPlainText()));

/// The width each column of the table on the screen is laid out at, in the table, its padding included.
List<double> _columnWidths(WidgetTester tester) =>
    tester.renderObject<RenderPostTable>(find.byType(PostTable)).debugColumnWidths;

/// The width each column of the table on the screen has as wide as its cells, its padding included.
List<double> _naturalWidths(WidgetTester tester) => [
  for (final column in tester.renderObject<RenderPostTable>(find.byType(PostTable)).debugColumns) column.max,
];

/// Checks that nothing overflows and that [card] and every piece of text lie inside the post on a screen of [width].
void _expectFits(WidgetTester tester, Finder card, double width) {
  expect(tester.takeException(), isNull, reason: 'nothing overflows');
  final rect = tester.getRect(card.first);
  // The post is laid out in width - 2 * 16; inline widgets may sit a fraction of a pixel off its edges.
  expect(rect.left, greaterThan(15));
  expect(rect.right, lessThan(width - 15));
  for (final paragraph in _paragraphs(tester)) {
    final text = _globalRect(paragraph);
    expect(text.left, greaterThan(15), reason: paragraph.text.toPlainText());
    expect(text.right, lessThan(width - 15), reason: paragraph.text.toPlainText());
  }
}

/// Long-presses [button] and checks the text of its tooltip is [scale] times as large as its font.
///
/// The tooltip is painted in the overlay, outside the card the button is in, it is not scaled with the card.
Future<void> _expectTooltipScale(WidgetTester tester, Finder button, double scale) async {
  final message = tester.widget<Tooltip>(find.ancestor(of: button, matching: find.byType(Tooltip)).first).message!;
  await tester.longPress(button);
  await tester.pump(const Duration(milliseconds: 300));
  final text = tester.renderObject<RenderParagraph>(
    find.descendant(of: find.text(message), matching: find.byType(RichText)),
  );
  expect(_effectiveScale(text), closeTo(scale, 0.01), reason: message);
  // The tooltip hides again by itself.
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
  expect(find.text(message), findsNothing);
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  late ImageCacheProvider cache;
  setUp(() {
    cache = ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio(), cookie: CookieProvider.buildEmpty()));
    getIt
      ..registerSingleton<ImageCacheProvider>(cache)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(
          dio: Dio()..httpClientAdapter = _MusicPageAdapter(),
          cookie: CookieProvider.buildEmpty(),
        ),
        instanceName: ServiceKeys.noCookie,
      );
  });
  tearDown(() async {
    await cache.dispose();
    await getIt.reset();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<void> pumpWidget(WidgetTester tester, Widget child, {required double width, required double textScale}) async {
    tester.view.physicalSize = Size(width, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(padding: const EdgeInsets.symmetric(horizontal: 16), child: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pump(WidgetTester tester, String html, {double width = 360, double textScale = 1}) async {
    final body = parseHtmlDocument('<html><body>$html</body></html>').body!;
    await pumpWidget(
      tester,
      Builder(builder: (context) => munchElement(context, body)),
      width: width,
      textScale: textScale,
    );
  }

  for (final card in _cards) {
    group(card.name, () {
      testWidgets('is scaled once at text scale 1.3, like the text of the post', (tester) async {
        await _seedAvatars(tester);
        await pump(tester, card.html, textScale: 1.3);
        await card.open?.call(tester);
        expect(card.finder(), findsWidgets);
        final paragraphs = _paragraphs(tester);
        expect(paragraphs.length, greaterThan(1));
        for (final paragraph in paragraphs) {
          expect(_effectiveScale(paragraph), closeTo(1.3, 0.01), reason: paragraph.text.toPlainText());
        }
        expect(tester.takeException(), isNull);
      });

      for (final scale in const [1.3, 2.0]) {
        testWidgets('fits a 320 px screen at text scale $scale', (tester) async {
          await _seedAvatars(tester);
          await pump(tester, card.html, width: 320, textScale: scale);
          await card.open?.call(tester);
          _expectFits(tester, card.finder(), 320);
        });
      }
    });
  }

  group('buttons in a scaled card still work', () {
    testWidgets('the spoiler opens and closes', (tester) async {
      await pump(tester, _cards.first.html, textScale: 1.3);
      expect(find.textContaining('折叠里的内容', findRichText: true), findsNothing);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      expect(find.textContaining('折叠里的内容', findRichText: true), findsOneWidget);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      expect(find.textContaining('折叠里的内容', findRichText: true), findsNothing);
    });

    testWidgets('the code block copies its code', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pump(tester, _cards.firstWhere((e) => e.name == 'code block').html, textScale: 2);
      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pumpAndSettle();
      expect(copied, 'print("hello");\nreturn 0;');
    });

    // A tooltip is painted in the overlay, outside the scaled card, but reads the text scale where its button is: in a
    // card it must get the text scale of the post back instead of staying at 1.0.
    testWidgets('the copy button of a code block shows its tooltip at the text scale, in a quote too', (tester) async {
      final code = _cards.firstWhere((e) => e.name == 'code block').html;
      // The code block in the quote is a card in a card, two spans deep.
      await pump(tester, '$code<blockquote>引用里的代码$code</blockquote>', textScale: 1.3);
      final icons = find.byIcon(Icons.copy_outlined);
      expect(icons, findsNWidgets(2));
      final inQuote = find.descendant(of: find.byType(QuotedText), matching: icons);
      expect(inQuote, findsOneWidget);
      expect(find.descendant(of: find.byType(QuotedText), matching: icons.first), findsNothing);
      for (final icon in [icons.first, inQuote]) {
        // The button itself is scaled once, with the card.
        expect(_globalRect(tester.renderObject<RenderBox>(icon)).width, closeTo(24 * 1.3, 0.01));
        await _expectTooltipScale(tester, icon, 1.3);
      }
    });

    testWidgets('the button to the quoted post shows its tooltip at the text scale', (tester) async {
      // Discuz links a quote to the quoted post with this image, the App shows a button instead (see
      // tmpImpellerWorkaroundUrls).
      const back =
          '<a href="forum.php?mod=redirect&amp;goto=findpost&amp;pid=1&amp;ptid=1">'
          '<img src="static/image/common/back.gif"></a>';
      await pump(tester, '<blockquote>某人 发表于 2020-1-1 12:00 $back<br>引用的内容</blockquote>$back', textScale: 1.3);
      final buttons = find.byIcon(Icons.navigate_before_outlined);
      expect(buttons, findsNWidgets(2));
      final inQuote = find.descendant(of: find.byType(QuotedText), matching: buttons);
      expect(inQuote, findsOneWidget);
      await _expectTooltipScale(tester, inQuote, 1.3);
      // The same button in the text of the post, not in a card.
      expect(find.descendant(of: find.byType(QuotedText), matching: buttons.last), findsNothing);
      await _expectTooltipScale(tester, buttons.last, 1.3);
    });
  });

  group('the purchase card under a floor', () {
    // Of the hidden content, a floor only shows the purchase card under the post (see Post.locked), not in the post
    // text; its underlined count of buyers is a widget inside its text.
    LockedCard purchaseCard() {
      final doc = parseHtmlDocument(File('test/data/locked_purchase_x5.html').readAsStringSync());
      final locked = Post.buildListFromThreadDataNode(doc.querySelector('div#postlist'), 1).single.locked.single;
      expect(locked.lockedWithPurchase, isTrue);
      return LockedCard(locked);
    }

    testWidgets('is scaled once at text scale 1.3, the underlined count too', (tester) async {
      await pumpWidget(tester, purchaseCard(), width: 360, textScale: 1.3);
      final paragraphs = _paragraphs(tester);
      expect(paragraphs.map((e) => e.text.toPlainText()), contains('10'));
      for (final paragraph in paragraphs) {
        expect(_effectiveScale(paragraph), closeTo(1.3, 0.01), reason: paragraph.text.toPlainText());
      }
      expect(tester.takeException(), isNull);
    });

    for (final scale in const [1.3, 2.0]) {
      testWidgets('fits a 320 px screen at text scale $scale', (tester) async {
        await pumpWidget(tester, purchaseCard(), width: 320, textScale: scale);
        _expectFits(tester, find.byType(LockedCard), 320);
      });
    }
  });

  group('the poll card under the first floor', () {
    // Not inside the post text: it is laid out in the floor like the text of the post and needs nothing.
    Future<void> pumpPoll(WidgetTester tester, {required double width, required double textScale}) async {
      await LocaleSettings.setLocale(AppLocale.en);
      final html = File('test/data/poll_multiple_x5.html').readAsStringSync();
      final repo = PollRepository(getPage: (_) async => html, postForm: (_, _) async => '');
      final cubit = PollCubit(url: 'poll', currentUid: () => 1000, repository: () => repo);
      addTearDown(cubit.close);
      await pumpWidget(
        tester,
        PollCard('1', controller: cubit),
        width: width,
        textScale: textScale,
      );
      expect(_paragraphs(tester).length, greaterThan(3), reason: 'the poll is shown');
    }

    testWidgets('is scaled once', (tester) async {
      await pumpPoll(tester, width: 360, textScale: 1.3);
      for (final paragraph in _paragraphs(tester)) {
        expect(_effectiveScale(paragraph), closeTo(1.3, 0.01), reason: paragraph.text.toPlainText());
      }
      await tester.pumpWidget(const SizedBox());
    });

    for (final scale in const [1.3, 2.0]) {
      testWidgets('fits a 320 px screen at text scale $scale', (tester) async {
        await pumpPoll(tester, width: 320, textScale: scale);
        _expectFits(tester, find.byType(PollCard), 320);
        await tester.pumpWidget(const SizedBox());
      });
    }
  });

  group('tables', () {
    const longText =
        '这是表格里一段很长的说明文字，在手机的屏幕上一行放不下，以前整个表格只能左右滑动，现在要在屏幕里面自动换行，'
        '读的人不用再一行一行地左右滑动来看完。';
    const longTable =
        '<table><tr><th>名称</th><td>说明</td></tr>'
        '<tr><td>第一项</td><td>$longText</td></tr>'
        '<tr><td>第二项</td><td>短的说明</td></tr></table>';

    for (final scale in const [1.0, 1.3]) {
      testWidgets('a long cell of a two column table wraps inside a 360 px screen at text scale $scale', (
        tester,
      ) async {
        await pump(tester, longTable, textScale: scale);
        expect(tester.takeException(), isNull);
        final scrolls = _horizontalScrolls(tester);
        expect(scrolls, everyElement(predicate<ScrollPosition>((e) => e.maxScrollExtent == 0)), reason: 'no scrolling');
        final table = tester.getRect(find.byType(PostTable));
        expect(table.right, lessThan(360 - 15));

        final long = tester.renderObject<RenderParagraph>(
          find.descendant(of: find.textContaining('很长的说明文字'), matching: find.byType(RichText)),
        );
        final lineHeight = long.getFullHeightForCaret(const TextPosition(offset: 0));
        expect(long.size.height, greaterThan(lineHeight * 2), reason: 'wrapped onto several lines');
        expect(_globalRect(long).right, lessThanOrEqualTo(table.right + 0.01));
        // The short cells keep their line, the long column takes the room.
        for (final text in ['名称', '第一项', '第二项', '短的说明']) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: find.text(text), matching: find.byType(RichText)),
          );
          expect(_oneLine(paragraph), isTrue, reason: text);
        }
        expect(_globalRect(long).width, greaterThan(table.width / 2));
      });
    }

    testWidgets('a table that fits keeps its own width', (tester) async {
      await pump(tester, '<table><tr><td>甲</td><td>乙</td></tr><tr><td>丙</td><td>丁</td></tr></table>');
      expect(tester.getRect(find.byType(PostTable)).width, lessThan(100), reason: 'not stretched to the screen');
      expect(_horizontalScrolls(tester), everyElement(predicate<ScrollPosition>((e) => e.maxScrollExtent == 0)));
    });

    testWidgets('a table with ten columns still scrolls sideways', (tester) async {
      final row = [for (var i = 1; i <= 10; i++) '<td>第$i列的内容</td>'].join();
      await pump(tester, '<table><tr>$row</tr><tr>$row</tr></table>', textScale: 1.3);
      expect(tester.takeException(), isNull);
      final scroll = _horizontalScrolls(tester).single;
      expect(scroll.maxScrollExtent, greaterThan(0));
      // Every cell keeps its text on one line instead of being squeezed.
      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.descendant(of: find.byType(PostTable), matching: find.byType(RichText)),
      )) {
        expect(_oneLine(paragraph), isTrue, reason: paragraph.text.toPlainText());
      }
      // And it can be dragged through the scaled card.
      await tester.dragFrom(tester.getTopLeft(find.byType(PostTable)) + const Offset(40, 10), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(scroll.pixels, greaterThan(0));
    });

    // At its comfortable widths (long text in four characters a line, the short cells and the word on one line) this
    // table is wider than a 320 px screen at text scale 2 leaves for it. A browser narrows a table further before it
    // lets it overflow: it is laid out at its tight widths and fits. It used to scroll, the long cell as wide as the
    // screen, the other columns past it.
    testWidgets('a table too wide at its comfortable widths is narrowed further before it scrolls', (tester) async {
      await pump(
        tester,
        '<table><tr><th>名称</th><td>$longText</td><td>unbreakable</td></tr>'
        '<tr><td>甲</td><td>乙</td><td>丙</td></tr></table>',
        width: 320,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(_horizontalScrolls(tester).single.maxScrollExtent, 0);
      for (final paragraph in _paragraphs(tester)) {
        expect(_globalRect(paragraph).right, lessThan(320 - 15), reason: paragraph.text.toPlainText());
      }
      expect(_lines(_paragraphOf(tester, '很长的说明文字')), greaterThan(1));
      expect(_oneLine(_paragraphOf(tester, '名称')), isTrue);
    });

    testWidgets('a table of images and text still shows the images', (tester) async {
      const small = 'https://example.com/data/attachment/forum/small.png';
      await _seedPostImage(tester, small, 360, width: 48, height: 32);
      await pump(
        tester,
        '<table><tr><td><img src="$small"></td><td>$longText</td></tr><tr><td>图片</td><td>文字</td></tr></table>',
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);
      final image = tester.getRect(find.byType(NetworkIndicatorImage));
      // The image keeps its size, scaled with the text of the post.
      expect(image.width, closeTo(48 * 1.3, 0.5));
      expect(image.height, closeTo(32 * 1.3, 0.5));
      expect(tester.getRect(find.byType(PostTable)).right, lessThan(360 - 15));
      expect(_horizontalScrolls(tester).single.maxScrollExtent, 0);
    });

    testWidgets('a wide image beside a long text is narrowed to a thumbnail, the text wraps', (tester) async {
      const wide = 'https://example.com/data/attachment/forum/wide.png';
      await _seedPostImage(tester, wide, 360, width: 300, height: 100);
      await pump(
        tester,
        '<table><tr><td><img src="$wide"></td><td>$longText</td></tr><tr><td>封面</td><td>简介</td></tr></table>',
      );
      expect(tester.takeException(), isNull);
      expect(_horizontalScrolls(tester).single.maxScrollExtent, 0);
      final image = tester.getRect(find.byType(NetworkIndicatorImage));
      expect(image.width, inInclusiveRange(120, 300 - 1));
      expect(image.height, closeTo(image.width / 3, 0.5), reason: 'keeps its aspect ratio');
      final long = find.descendant(of: find.textContaining('很长的说明文字'), matching: find.byType(RichText));
      expect(_globalRect(tester.renderObject<RenderParagraph>(long)).right, lessThan(360 - 15));
    });

    // On the web page three images of 300 px side by side fit the desktop page; on a phone they used to make the table
    // scroll by twice the screen. They are thumbnails now, in the width of their cells, as the browser narrows an image
    // to its cell.
    testWidgets('wide images side by side are narrowed to thumbnails, their aspect ratio kept', (tester) async {
      final urls = [for (var i = 1; i <= 3; i++) 'https://example.com/data/attachment/forum/wide$i.png'];
      for (final url in urls) {
        await _seedPostImage(tester, url, 360, width: 300, height: 100);
      }
      final images = urls.map((e) => '<td><img src="$e"></td>').join();
      await pump(tester, '<table><tr>$images</tr><tr><td>左</td><td>中</td><td>右</td></tr></table>');
      expect(tester.takeException(), isNull);
      expect(find.byType(NetworkIndicatorImage), findsNWidgets(3));
      expect(_horizontalScrolls(tester).single.maxScrollExtent, 0);
      for (final image in tester.widgetList<NetworkIndicatorImage>(find.byType(NetworkIndicatorImage))) {
        final rect = tester.getRect(find.byWidget(image));
        expect(rect.width, inInclusiveRange(PostTable.tightImageWidth, PostTableImage.minWidth), reason: image.src);
        expect(rect.height, closeTo(rect.width / 3, 0.5), reason: 'keeps its aspect ratio');
        expect(rect.right, lessThan(360 - 15));
      }
    });

    testWidgets('a table of more wide images than fit as thumbnails scrolls, each a thumbnail, not nothing', (
      tester,
    ) async {
      final urls = [for (var i = 1; i <= 6; i++) 'https://example.com/data/attachment/forum/wide$i.png'];
      for (final url in urls) {
        await _seedPostImage(tester, url, 360, width: 300, height: 100);
      }
      final images = urls.map((e) => '<td><img src="$e"></td>').join();
      await pump(tester, '<table><tr>$images</tr></table>');
      expect(tester.takeException(), isNull);
      expect(_horizontalScrolls(tester).single.maxScrollExtent, greaterThan(0));
      for (final image in tester.widgetList<NetworkIndicatorImage>(find.byType(NetworkIndicatorImage))) {
        final rect = tester.getRect(find.byWidget(image));
        expect(rect.width, closeTo(PostTableImage.minWidth, 0.5), reason: image.src);
        expect(rect.height, closeTo(rect.width / 3, 0.5));
      }
    });

    testWidgets('a table inside a table fits too', (tester) async {
      await pump(
        tester,
        '<table><tr><td>外层</td><td><table><tr><td>内层</td><td>$longText</td></tr><tr><td>甲</td><td>乙</td></tr>'
        '</table></td></tr><tr><td>外层二</td><td>外层的值</td></tr></table>',
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(PostTable), findsNWidgets(2));
      final long = find.descendant(of: find.textContaining('很长的说明文字'), matching: find.byType(RichText));
      expect(_globalRect(tester.renderObject<RenderParagraph>(long)).right, lessThan(360 - 15));
      for (final paragraph in _paragraphs(tester)) {
        expect(_effectiveScale(paragraph), closeTo(1.3, 0.01), reason: paragraph.text.toPlainText());
      }
    });

    // A table narrowed to the screen used to be shrunk by the table itself, one column after the other: the first long
    // column gave up most of the room, down to its minimum, while the later ones kept theirs. Which column a text was
    // in decided how many lines it got.
    group('every long column', () {
      // The room a table has: a post is laid out in the width of the screen - 2 * 16, a table in it is in a span scaled
      // by the text scale.
      double room(double scale) => (360 - 32) / scale;

      testWidgets('two equally long columns get the same width', (tester) async {
        final twin = '那是${longText.substring(2)}';
        await pump(tester, '<table><tr><th>说明一</th><th>说明二</th></tr><tr><td>$longText</td><td>$twin</td></tr></table>');
        expect(tester.takeException(), isNull);
        expect(_horizontalScrolls(tester).single.maxScrollExtent, 0);
        final widths = _columnWidths(tester);
        expect(widths[0], closeTo(widths[1], 0.5));
        // The lines between and around the cells take their own width.
        expect(widths[0] + widths[1] + 3 * PostTable.borderWidth, closeTo(room(1), 0.5));
        expect(_lines(_paragraphOf(tester, '这是表格里')), _lines(_paragraphOf(tester, '那是表格里')));
      });

      testWidgets('long columns keep the same share of their natural width, in either order', (tester) async {
        // Long enough not to reach its comfortable width beside the longer one.
        const medium = '中等长度的说明文字，大约二十五个字左右的样子而已';
        final layouts = <List<double>>[];
        for (final cells in const [
          [longText, medium],
          [medium, longText],
        ]) {
          await pump(
            tester,
            '<table><tr><th>甲</th><th>乙</th></tr><tr><td>${cells[0]}</td><td>${cells[1]}</td></tr></table>',
          );
          expect(tester.takeException(), isNull);
          expect(_horizontalScrolls(tester).single.maxScrollExtent, 0);
          final widths = _columnWidths(tester);
          final natural = _naturalWidths(tester);
          // Neither is at its minimum.
          expect(widths[0] / natural[0], closeTo(widths[1] / natural[1], 0.001));
          layouts.add(widths);
        }
        // Swapped, the columns swap their widths.
        expect(
          layouts[1].reversed,
          pairwiseCompare<double, double>(layouts[0], (a, b) => (a - b).abs() < 0.01, 'same'),
        );
      });

      // A typical resource table: a long title first, a long note on the download last, short columns between them.
      const title = '【某字幕组】某某某某番剧名称第二季 第01-12话 全集 简繁内封 1080P';
      const resourceTable =
          '<table><tr><th>名称</th><th>集数</th><th>字幕组</th><th>格式</th><th>下载</th></tr>'
          '<tr><td>$title</td><td>12</td><td>某某字幕组</td><td>MKV</td><td>百度网盘 提取码 abcd 失效请回复</td></tr>'
          '<tr><td>【某字幕组】某某某某番剧名称第一季 第13-24话 全集 简繁内封 720P</td><td>12</td><td>某某字幕组</td>'
          '<td>MP4</td><td>磁力链接 见楼下 失效请回复</td></tr></table>';
      const shortCells = {'名称', '集数', '字幕组', '格式', '下载', '12', '某某字幕组', 'MKV', 'MP4'};

      // At text scale 1 it fits at its comfortable widths: the short cells keep their line, the long title and the
      // note give up the room, the title the most it can keep. Each cell has 4 px around its text as on the web page
      // (`.t_table td`), which the five columns and their lines take from the 328 px of the post: the title has two
      // or three lines more than it had without them.
      testWidgets('the long title of a resource table stays readable at text scale 1.0', (tester) async {
        await pump(tester, resourceTable);
        expect(tester.takeException(), isNull);
        expect(_horizontalScrolls(tester).single.maxScrollExtent, 0);
        final widths = _columnWidths(tester);
        // The title, the longest, is not squeezed to leave the room to the shorter note on the download.
        expect(widths[0], greaterThanOrEqualTo(widths.reduce(math.max) - 0.01));
        expect(_lines(_paragraphOf(tester, '第01-12话')), lessThanOrEqualTo(8));
        final shorts = _cellsOf(tester, shortCells).toList();
        expect(shorts, hasLength(11));
        for (final paragraph in shorts) {
          expect(_oneLine(paragraph), isTrue, reason: paragraph.text.toPlainText());
        }
      });

      // At text scale 1.3 it does not fit at its comfortable widths; it used to scroll, the title as wide as the
      // screen. Narrowed further, as a browser narrows it, every column of it is on the screen.
      testWidgets('a resource table at text scale 1.3 is narrowed to the screen rather than scrolling', (tester) async {
        await pump(tester, resourceTable, textScale: 1.3);
        expect(tester.takeException(), isNull);
        expect(_horizontalScrolls(tester).single.maxScrollExtent, 0);
        for (final paragraph in _paragraphs(tester)) {
          expect(_globalRect(paragraph).right, lessThan(360 - 15), reason: paragraph.text.toPlainText());
        }
        final widths = _columnWidths(tester);
        final columns = tester.renderObject<RenderPostTable>(find.byType(PostTable)).debugColumns;
        for (final (x, width) in widths.indexed) {
          expect(width, greaterThanOrEqualTo(columns[x].tight - 0.01));
          expect(columns[x].tight, greaterThanOrEqualTo(math.min(columns[x].max, PostTable.tightColumnWidth)));
        }
        // The cells narrower than a tight column keep their line.
        for (final paragraph in _cellsOf(tester, const {'12', '名称', '集数', '格式', '下载'})) {
          expect(_oneLine(paragraph), isTrue, reason: paragraph.text.toPlainText());
        }
      });

      // Too many columns to fit even at their tight widths: it scrolls, at its comfortable widths. It used to scroll
      // with each long column as wide as the screen, three screens wide; a browser lays it out at its narrowest. It is
      // as narrow as it is comfortable to read: each long column in four characters a line, the short cells on
      // one line. Squeezed more it would scroll all the same, only taller.
      testWidgets('a table that scrolls is laid out at its comfortable widths', (tester) async {
        const second = '另一段同样很长的说明文字，在手机的屏幕上一行同样放不下，以前整个表格只能左右滑动，现在要在屏幕里面自动换行。';
        const third = '第三段也是很长的说明文字，在手机的屏幕上一行还是放不下，以前整个表格只能左右滑动，现在要在屏幕里面自动换行。';
        final shorts = [for (var i = 1; i <= 6; i++) '<td>短栏$i</td>'].join();
        await pump(
          tester,
          '<table><tr><td>$longText</td><td>$second</td><td>$third</td>$shorts</tr>'
          '<tr><td>甲</td><td>乙</td><td>丙</td>$shorts</tr></table>',
        );
        expect(tester.takeException(), isNull);
        final scroll = _horizontalScrolls(tester).single;
        expect(scroll.maxScrollExtent, greaterThan(0));
        final widths = _columnWidths(tester);
        for (final width in widths.take(3)) {
          expect(width, closeTo(PostTable.minColumnWidth + 2 * PostTable.cellPadding, 0.01));
        }
        for (final text in ['这是表格里', '另一段', '第三段']) {
          expect(_lines(_paragraphOf(tester, text)), greaterThan(1), reason: text);
        }
        final shortCells = _cellsOf(tester, {for (var i = 1; i <= 6; i++) '短栏$i'}).toList();
        expect(shortCells, hasLength(12));
        for (final paragraph in shortCells) {
          expect(_oneLine(paragraph), isTrue, reason: paragraph.text.toPlainText());
        }
        // It scrolls by what does not fit, not by screens.
        expect(scroll.maxScrollExtent, lessThan(room(1)));
      });

      testWidgets('a wide image left or right of a long text gets the same width', (tester) async {
        const wide = 'https://example.com/data/attachment/forum/wide.png';
        await _seedPostImage(tester, wide, 360, width: 300, height: 100);
        const image = '<td><img src="$wide"></td>';
        const text = '<td>$longText</td>';
        final layouts = <({Size image, double text, int lines})>[];
        for (final html in const [
          '<table><tr>$image$text</tr><tr><td>封面</td><td>简介</td></tr></table>',
          '<table><tr>$text$image</tr><tr><td>简介</td><td>封面</td></tr></table>',
        ]) {
          await pump(tester, html);
          expect(tester.takeException(), isNull);
          expect(_horizontalScrolls(tester).single.maxScrollExtent, 0);
          final paragraph = _paragraphOf(tester, '很长的说明文字');
          layouts.add((
            image: tester.getSize(find.byType(NetworkIndicatorImage)),
            text: paragraph.size.width,
            lines: _lines(paragraph),
          ));
        }
        expect(layouts[1].image.width, closeTo(layouts[0].image.width, 0.01));
        expect(layouts[1].image.height, closeTo(layouts[0].image.height, 0.01));
        expect(layouts[1].text, closeTo(layouts[0].text, 0.01));
        expect(layouts[1].lines, layouts[0].lines);
        // The long text gives up its room first, the image is a thumbnail.
        expect(layouts[0].image.width, closeTo(PostTableImage.minWidth, 0.01));
      });

      // The screen is turned: the post is laid out in another width, the table is not built again. A table whose cells
      // did not change is only laid out again at other constraints: it takes the widths of each width, wherever it was
      // laid out before.
      testWidgets('a table laid out in another width, its cells unchanged, takes the widths of that width', (
        tester,
      ) async {
        const medium = '中等长度的说明文字，大约二十五个字左右的样子而已';
        final body = parseHtmlDocument(
          '<html><body><table><tr><td>$longText</td><td>$medium</td><td>unbroken</td></tr>'
          '<tr><td>甲</td><td>乙</td><td>丙</td></tr></table></body></html>',
        ).body!;
        final width = ValueNotifier<double>(120);
        addTearDown(width.dispose);
        await pumpWidget(
          tester,
          ValueListenableBuilder<double>(
            valueListenable: width,
            builder: (context, postWidth, child) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: postWidth, child: child),
            ),
            child: Builder(builder: (context) => munchElement(context, body)),
          ),
          width: 800,
          textScale: 1,
        );
        // Too narrow even for the tight widths: it scrolls at its comfortable widths.
        final scroll = _horizontalScrolls(tester).single;
        expect(scroll.maxScrollExtent, greaterThan(0));
        final scrolling = _columnWidths(tester);
        // Narrowed to the width it fits at its tight widths.
        width.value = 200;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(scroll.maxScrollExtent, 0);
        final tight = _columnWidths(tester);
        expect(tight.reduce((a, b) => a + b) + 4 * PostTable.borderWidth, closeTo(200, 0.01));
        // Wide enough for its comfortable widths: the long columns keep the same share of their natural width.
        width.value = 500;
        await tester.pumpAndSettle();
        expect(scroll.maxScrollExtent, 0);
        final narrowed = _columnWidths(tester);
        final natural = _naturalWidths(tester);
        expect(narrowed[0] / natural[0], closeTo(narrowed[1] / natural[1], 0.001));
        expect(narrowed.reduce((a, b) => a + b) + 4 * PostTable.borderWidth, closeTo(500, 0.01));
        // Back at each width, the same widths again.
        for (final (postWidth, widths) in [(120.0, scrolling), (200.0, tight)]) {
          width.value = postWidth;
          await tester.pumpAndSettle();
          expect(
            _columnWidths(tester),
            pairwiseCompare<double, double>(widths, (a, b) => (a - b).abs() < 0.01, 'same'),
            reason: '$postWidth',
          );
        }
      });
    });

    testWidgets('a table with a single row is only what it wraps', (tester) async {
      await pump(tester, '<table><tr><td>只是包着的文字</td></tr></table>');
      expect(find.byType(PostTable), findsNothing);
      expect(find.textContaining('只是包着的文字', findRichText: true), findsOneWidget);
    });
  });
  // An empty column (natural and minimum width 0) next to columns at a width equal to the sum of the minimum widths:
  // rounding made the room look a hair larger than the deficit and left only the empty column to share it, a division
  // by zero that gave a NaN width (found by fuzzing the narrowing with arbitrary doubles).
  group('column widths never come out invalid', () {
    test('an empty column at exactly the comfortable widths', () {
      final widths = debugPostTableColumnWidths(const [
        (tight: 0, min: 0, max: 0, percent: null, fixed: null),
        (tight: 50, min: 64, max: 68.69369669260027, percent: null, fixed: null),
        (tight: 50, min: 64, max: 68.3283919057836, percent: null, fixed: null),
        (tight: 50, min: 64, max: 100.79388212963129, percent: null, fixed: null),
      ], 192);
      expect(widths.any((e) => e.isNaN || e.isInfinite), isFalse, reason: '$widths');
      expect(widths, [0, 64, 64, 64]);
    });

    test('arbitrary columns at any width', () {
      final random = math.Random(207);
      for (var i = 0; i < 20000; i++) {
        final columns = [
          for (var c = 0; c < 1 + random.nextInt(7); c++)
            if (random.nextInt(5) == 0)
              (tight: 0.0, min: 0.0, max: 0.0, percent: null, fixed: null)
            else
              () {
                final tight = 20 + random.nextDouble() * 100;
                final min = tight + random.nextDouble() * 60;
                final max = min + random.nextDouble() * 700;
                return (
                  tight: tight,
                  min: min,
                  max: max,
                  percent: random.nextInt(4) == 0 ? random.nextDouble() * 0.8 : null,
                  fixed: random.nextInt(4) == 0 ? max : null,
                );
              }(),
        ];
        double sum(double Function(PostTableColumn e) of) => columns.fold<double>(0, (sum, e) => sum + of(e));
        final tight = sum((e) => e.tight);
        final width = switch (random.nextInt(4)) {
          0 => tight,
          1 => sum((e) => e.min),
          2 => random.nextDouble() * sum((e) => e.max) * 1.5,
          _ => tight + random.nextDouble() * (sum((e) => e.max) - tight),
        };
        final widths = debugPostTableColumnWidths(columns, width);
        final reason = '$columns @ $width -> $widths';
        expect(widths.any((e) => e.isNaN || e.isInfinite || e < 0), isFalse, reason: reason);
        // The table is as wide as it was given, no wider: what it lays out is what the screen has.
        if (columns.any((e) => e.max > 0)) {
          expect(widths.fold<double>(0, (sum, e) => sum + e), closeTo(width, 1e-6), reason: reason);
        }
        if (width >= tight) {
          for (var x = 0; x < columns.length; x++) {
            expect(widths[x], greaterThanOrEqualTo(columns[x].tight - 1e-6), reason: reason);
          }
        }
      }
    });
  });
}
