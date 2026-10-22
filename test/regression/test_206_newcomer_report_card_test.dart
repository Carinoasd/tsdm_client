/// The newcomer report thread showed only the values of the report card, one per line, without the field names, and a
/// long value ran off the screen.
///
/// Since the forum moved to the new newcomer report plugin the first post starts with
/// `<div class="rcd-card"><div class="rcd-h">报到详细信息</div><table><tr><th>昵称</th><td class="rcd-v">…</td></tr>…`
/// (the older threadsort template used the same markup with `bd-card` / `bd-h` / `bd-v`). Only the threadsort table
/// `table.cgtl` was recognised; this card went to the generic table builder, which dropped every `th` cell, and both
/// tables sat in a horizontal scroll view where a long value never wrapped. An empty value showed a blank row while
/// the website shows "-".
library;

// HTML fixtures are split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/newcomer_report_card.dart';
import 'package:tsdm_client/utils/html/post_table.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';
import 'package:universal_html/parsing.dart';

const _longHobby =
    '喜欢看动画和读小说，周末会去公园散步拍照，也会自己画一些简单的插画，最近在学习作曲和吉他，希望能在论坛认识更多同好，'
    '一起交流心得、分享资源，顺便提高一下自己的审美和表达能力，长期潜水但是会努力冒泡的';

/// The first post of a newcomer report thread as the report plugin renders it (fake data).
const _rcdPost =
    '<div class="pcbs"><style>.rcd-card{margin:0 0 12px}.rcd-card td.rcd-v:empty::before{content:"-"}</style>'
    '<div class="rcd-card"><div class="rcd-h">报到详细信息</div><table>'
    '<tr><th>昵称</th><td class="rcd-v">Alice</td></tr>'
    '<tr><th>年龄</th><td class="rcd-v">20</td></tr>'
    '<tr><th>性别</th><td class="rcd-v">女</td></tr>'
    '<tr><th>职业</th><td class="rcd-v">学生</td></tr>'
    '<tr><th>来自</th><td class="rcd-v">上海</td></tr>'
    '<tr><th>兴趣爱好</th><td class="rcd-v">$_longHobby</td></tr>'
    '<tr><th>QQ</th><td class="rcd-v"></td></tr>'
    '<tr><th>技能</th><td class="rcd-v">绘画</td></tr>'
    '<tr><th>最想说的话</th><td class="rcd-v">大家好<br />\n请多指教</td></tr>'
    '<tr><th>最喜欢的动漫</th><td class="rcd-v">某部动画</td></tr>'
    '</table></div>'
    '<table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_1">帖子正文</td></tr></table>'
    '</div>';

const List<(String, String)> _rcdPairs = [
  ('昵称', 'Alice'),
  ('年龄', '20'),
  ('性别', '女'),
  ('职业', '学生'),
  ('来自', '上海'),
  ('兴趣爱好', _longHobby),
  ('QQ', ''),
  ('技能', '绘画'),
  ('最想说的话', '大家好\n请多指教'),
  ('最喜欢的动漫', '某部动画'),
];

/// The same card from the older threadsort template, with a `<br>` that has no line break after it.
const _bdPost =
    '<div class="bd-card">\n<div class="bd-h">报到详细信息</div>\n<table>\n'
    '<tr><th>昵称</th><td class="bd-v">Alice</td></tr>\n'
    '<tr><th>兴趣爱好</th><td class="bd-v">  看书<br>听歌  </td></tr>\n'
    '<tr><th>QQ</th><td class="bd-v"></td></tr>\n'
    '</table>\n</div>\n'
    '<table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_2">帖子正文</td></tr></table>';

/// Discuz's own threadsort table.
const _cgtlPost =
    '<table cellspacing="0" cellpadding="0" class="cgtl mbm"><caption>报到详细信息</caption><tbody>'
    '<tr><th valign="top">昵称:</th><td> Alice</td></tr>'
    '<tr><th valign="top">年龄:</th><td>20 </td></tr>'
    '<tr><th valign="top">来自:</th><td>上海</td></tr>'
    '</tbody></table>'
    '<table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_3">帖子正文</td></tr></table>';

const _photoUrl = 'https://example.com/data/attachment/forum/threadsort/photo.jpg';
const _protectedUrl = 'https://example.com/misc.php?mod=stringtopic&string=abc';

/// A threadsort table with an image field (`<img onload="thumbImg(this)">`), a protected field shown as an image
/// (`<image>`, which the parser turns into `<img>`) and an empty field.
const _cgtlImagePost =
    '<table cellspacing="0" cellpadding="0" class="cgtl mbm"><caption>资料</caption><tbody>'
    '<tr><th>照片:</th><td><img src="$_photoUrl" onload="thumbImg(this)" width="120" border="0"> </td></tr>'
    '<tr><th>电话:</th><td>号码 <image src="$_protectedUrl"> </td></tr>'
    '<tr><th>备注:</th><td>-</td></tr>'
    '</tbody></table>'
    '<table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_4">帖子正文</td></tr></table>';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  Future<void> pump(WidgetTester tester, String html, {double width = 400, double textScale = 1}) async {
    tester.view.physicalSize = Size(width, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final body = parseHtmlDocument('<html><body>$html</body></html>').body!;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Builder(builder: (context) => munchElement(context, body)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<(String, String)> pairsOf(WidgetTester tester) =>
      tester.widget<NewcomerReportCard>(find.byType(NewcomerReportCard)).data.map((e) => (e.title, e.data)).toList();

  Finder inCard(Finder finder) => find.descendant(of: find.byType(NewcomerReportCard), matching: finder);

  /// Plain text of every span in the post outside the report card.
  String postText(WidgetTester tester) {
    final buffer = StringBuffer();
    tester.widget<RichText>(find.byType(RichText).first).text.visitChildren((span) {
      if (span is TextSpan) {
        buffer.write(span.text ?? '');
      }
      return true;
    });
    return buffer.toString();
  }

  testWidgets('the report plugin card shows every field name next to its value, in order', (tester) async {
    await pump(tester, _rcdPost);
    expect(find.byType(NewcomerReportCard), findsOneWidget);
    expect(pairsOf(tester), _rcdPairs);
    for (final (title, value) in _rcdPairs) {
      expect(inCard(find.text(title)), findsOneWidget, reason: 'field name "$title"');
      if (value.isNotEmpty) {
        expect(inCard(find.text(value)), findsOneWidget, reason: 'value of "$title"');
      }
    }
    // The website shows "-" for an empty value.
    expect(inCard(find.text('-')), findsOneWidget);
    // The header of the card is the one the forum renders.
    expect(inCard(find.text('报到详细信息')), findsOneWidget);
    // The values are not repeated as a bare table outside the card, the post text still follows.
    expect(find.byType(Table), findsOneWidget);
    expect(postText(tester), isNot(contains('Alice')));
    expect(postText(tester), contains('帖子正文'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long value wraps inside the card on a 320 px screen with large text', (tester) async {
    await pump(tester, _rcdPost, width: 320, textScale: 1.3);
    expect(tester.takeException(), isNull);
    expect(inCard(find.byType(SingleChildScrollView)), findsNothing, reason: 'no horizontal scrolling');

    final card = tester.getRect(find.byType(NewcomerReportCard));
    // The post text is laid out in 320 - 2 * 16; inline widgets may sit a fraction of a pixel off its left edge.
    expect(card.width, lessThanOrEqualTo(320 - 2 * 16));
    expect(card.right, lessThan(320 - 15));

    final hobby = inCard(find.text(_longHobby));
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: hobby, matching: find.byType(RichText)),
    );
    final rect = tester.getRect(hobby);
    expect(rect.right, lessThanOrEqualTo(card.right), reason: 'the value stays inside the card');
    expect(rect.width, greaterThan(card.width / 3), reason: 'the value column takes the rest of the row');
    // Wrapped onto several lines, nothing cut off at the edge.
    final lineHeight = paragraph.getFullHeightForCaret(const TextPosition(offset: 0));
    expect(paragraph.size.height, greaterThan(lineHeight * 3));
    expect(paragraph.getMinIntrinsicWidth(double.infinity), lessThanOrEqualTo(paragraph.size.width));

    // The field names line up in one column left of the values.
    final titleLefts = [for (final (title, _) in _rcdPairs) tester.getRect(inCard(find.text(title))).left];
    expect(titleLefts.toSet(), hasLength(1));
    for (final (title, _) in _rcdPairs) {
      expect(tester.getRect(inCard(find.text(title))).right, lessThanOrEqualTo(rect.left), reason: title);
    }
  });

  testWidgets('the card of the older threadsort template is recognised too', (tester) async {
    await pump(tester, _bdPost);
    expect(pairsOf(tester), [('昵称', 'Alice'), ('兴趣爱好', '看书\n听歌'), ('QQ', '')]);
    expect(inCard(find.text('-')), findsOneWidget);
    expect(postText(tester), contains('帖子正文'));
    expect(tester.takeException(), isNull);
  });

  testWidgets("Discuz's threadsort table still becomes the card", (tester) async {
    await pump(tester, _cgtlPost);
    expect(pairsOf(tester), [('昵称:', 'Alice'), ('年龄:', '20'), ('来自:', '上海')]);
    expect(postText(tester), contains('帖子正文'));
    expect(tester.takeException(), isNull);
  });

  /// Whether the text of [finder] is laid out on one line: as wide as it is unwrapped.
  bool oneLine(WidgetTester tester, Finder finder) {
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: finder, matching: find.byType(RichText)),
    );
    return paragraph.getMaxIntrinsicWidth(double.infinity) <= paragraph.size.width + 0.01;
  }

  testWidgets('the card is scaled once by the text scale, like the text of the post', (tester) async {
    await pump(tester, _rcdPost);
    final nameWidth = tester.getRect(inCard(find.text('昵称'))).width;
    final titleWidth = tester.getRect(inCard(find.text('报到详细信息'))).width;
    await pump(tester, _rcdPost, textScale: 1.3);
    // The inline card is already scaled by the post's paragraph; its own text scaled again made it 1.69 times.
    expect(tester.getRect(inCard(find.text('昵称'))).width / nameWidth, closeTo(1.3, 0.01));
    expect(tester.getRect(inCard(find.text('报到详细信息'))).width / titleWidth, closeTo(1.3, 0.01));
    expect(tester.takeException(), isNull);
  });

  // The website never wraps a field name. The app's text scale goes up to 1.5, a 360 px screen is the common narrow one.
  for (final (width, scale) in const [
    (320.0, 1.3),
    (360.0, 1.15),
    (360.0, 1.5),
    (393.0, 1.3),
    (411.0, 1.3),
  ]) {
    testWidgets('field names are not broken on a $width px screen at text scale $scale', (tester) async {
      await pump(tester, _rcdPost, width: width, textScale: scale);
      expect(tester.takeException(), isNull);
      for (final (title, _) in _rcdPairs) {
        expect(oneLine(tester, inCard(find.text(title))), isTrue, reason: title);
      }
      expect(oneLine(tester, inCard(find.text('报到详细信息'))), isTrue, reason: 'card title');
      final card = tester.getRect(find.byType(NewcomerReportCard));
      expect(card.right, lessThan(width - 15));
      // The values keep a usable column.
      final value = tester.getRect(inCard(find.text(_longHobby)));
      expect(value.width, greaterThan(card.width / 3));
    });
  }

  // A 320 px screen at the largest text scales (the thread content scale goes above the app's 1.5) has no room for
  // the longest name next to the values: it wraps, but it does not fall apart one character a line.
  for (final scale in const [1.5, 2.0]) {
    testWidgets('at text scale $scale on a 320 px screen a long field name takes two lines at most', (tester) async {
      await pump(tester, _rcdPost, width: 320, textScale: scale);
      expect(tester.takeException(), isNull);
      for (final (title, _) in _rcdPairs) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: inCard(find.text(title)), matching: find.byType(RichText)),
        );
        final lineHeight = paragraph.getFullHeightForCaret(const TextPosition(offset: 0));
        expect(paragraph.size.height, lessThan(lineHeight * 2.5), reason: title);
      }
      expect(tester.getRect(find.byType(NewcomerReportCard)).right, lessThan(320 - 15));
    });
  }

  group('a threadsort value with images', () {
    late ImageCacheProvider cache;
    setUp(() {
      cache = ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio(), cookie: CookieProvider.buildEmpty()));
      getIt.registerSingleton<ImageCacheProvider>(cache);
    });
    tearDown(() async {
      await cache.dispose();
      await getIt.reset();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });

    /// Puts the images in the image cache, the test does not load them from the network.
    Future<void> seedImages(WidgetTester tester) async {
      for (final url in [_photoUrl, _protectedUrl]) {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 120, 90), Paint()..color = Colors.blue);
        final picture = recorder.endRecording();
        final image = await tester.runAsync(() => picture.toImage(120, 90));
        picture.dispose();
        // Images in the post are decoded at the width of the 400 px test screen.
        final provider = ResizeImage.resizeIfNeeded(400, null, CachedImageProvider(url));
        final key = await provider.obtainKey(ImageConfiguration.empty);
        PaintingBinding.instance.imageCache.putIfAbsent(
          key,
          () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image!))),
        );
      }
    }

    testWidgets('shows the images in the card instead of "-"', (tester) async {
      await seedImages(tester);
      await pump(tester, _cgtlImagePost);
      expect(tester.takeException(), isNull);
      final card = find.byType(NewcomerReportCard);
      expect(card, findsOneWidget);
      // The image field and the protected field (text drawn as an image) keep their images.
      for (final url in [_photoUrl, _protectedUrl]) {
        expect(
          inCard(find.byWidgetPredicate((w) => w is NetworkIndicatorImage && w.src == url)),
          findsOneWidget,
          reason: url,
        );
      }
      // Text next to an image is kept too.
      expect(inCard(find.textContaining('号码', findRichText: true)), findsOneWidget);
      // Only the field the forum left empty shows "-", the image fields do not.
      expect(inCard(find.text('-')), findsOneWidget);
      final photo = tester.getRect(
        inCard(find.byWidgetPredicate((w) => w is NetworkIndicatorImage && w.src == _photoUrl)),
      );
      expect(photo.width, greaterThan(0));
      expect(photo.right, lessThanOrEqualTo(tester.getRect(card).right));
      expect(postText(tester), contains('帖子正文'));
    });
  });

  group('rate log', () {
    /// A rated post: Discuz renders the rate log at the end of `div.pcb`, after the post and its comments.
    const ratedPost =
        '$_rcdPost\n<div id="comment_1" class="cm">\n</div>\n'
        '<h3 class="psth xs1"><span class="icon_ring vm"></span>评分</h3>\n'
        '<dl id="ratelog_1" class="rate"><dd style="margin:0"><table class="ratl">'
        '<tr><th class="xw1">参与人数 <span class="xi1">1</span></th><th class="xw1">天然</th></tr>'
        '</table></dd></dl>';

    testWidgets('the heading of the rate log does not end the post text', (tester) async {
      await pump(tester, ratedPost);
      expect(postText(tester), contains('帖子正文'));
      expect(postText(tester), isNot(contains('评分')));
      expect(postText(tester), isNot(contains('参与人数')));
      expect(postText(tester).trimRight(), endsWith('帖子正文'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('other headings in the post are kept', (tester) async {
      await pump(tester, '<h3>标题</h3><div>正文</div><h3 class="psth xs1">评分</h3><div>不是评分记录</div>');
      expect(postText(tester), contains('标题'));
      expect(postText(tester), contains('评分'));
      expect(postText(tester), contains('不是评分记录'));
    });
  });

  group('generic tables', () {
    List<TextSpan> cellSpans(WidgetTester tester) {
      final out = <TextSpan>[];
      for (final rich in tester.widgetList<RichText>(
        find.descendant(of: find.byType(PostTable), matching: find.byType(RichText)),
      )) {
        rich.text.visitChildren((span) {
          if (span is TextSpan && (span.text?.trim().isNotEmpty ?? false)) {
            out.add(span);
          }
          return true;
        });
      }
      return out;
    }

    testWidgets('header cells are kept, in row order and bold', (tester) async {
      await pump(
        tester,
        '<table><tr><th>名称</th><td>值一</td></tr><tr><th>类型</th><td>值二</td></tr><tr><td>甲</td><td>乙</td></tr></table>',
      );
      final spans = cellSpans(tester);
      expect(spans.map((e) => e.text!.trim()), ['名称', '值一', '类型', '值二', '甲', '乙']);
      expect(spans.firstWhere((e) => e.text == '名称').style?.fontWeight, FontWeight.w600);
      expect(spans.firstWhere((e) => e.text == '值一').style?.fontWeight, isNot(FontWeight.w600));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a header row in thead is kept above the body rows', (tester) async {
      await pump(
        tester,
        '<table><thead><tr><th>名称</th><th>数量</th></tr></thead>'
        '<tbody><tr><td>苹果</td><td>3</td></tr><tr><td>梨</td><td>5</td></tr></tbody></table>',
      );
      expect(cellSpans(tester).map((e) => e.text!.trim()), ['名称', '数量', '苹果', '3', '梨', '5']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a table of plain cells is unchanged', (tester) async {
      await pump(tester, '<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>');
      expect(cellSpans(tester).map((e) => e.text!.trim()), ['a', 'b', 'c', 'd']);
      expect(find.byType(NewcomerReportCard), findsNothing);
    });
  });
}
