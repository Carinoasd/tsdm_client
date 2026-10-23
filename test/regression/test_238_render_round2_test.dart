/// What the second comparison of the post display with the web page found (96 more threads, 745 floors: the boards of
/// drawings and of the art shop, links to videos, the rules of the forums), fixed:
///
/// 1. a link to a video of bilibili was only a link: the web page shows the player of the forum's `videohub` plugin at
///    the end of the floor's message, for the first video the message links where it can be seen. The app shows the
///    card of a player there ([PostMediaCard], opening the video outside the app), also with the experimental
///    renderer;
/// 2. the experimental renderer made `[img]/img01/…[/img]` (a path on the forum's site) `http:///img01/…`, a broken
///    image: it keeps the floor's html (the forum prints the path on its image host);
/// 3. a table scrolling sideways looked whole at the edge of the screen: it fades out at an edge it scrolls past;
/// 4. a block whose background is a picture (`background="…"`, `background-image`) was shown on the color given beside
///    the picture, white text written for a dark picture on a light block: the picture hides the color, the block has
///    no background the app shows, its text is made readable;
/// 5. a cell holding only a line break (`<td><br></td>`, the blank rows of a gallery) was lower than a line;
/// 6. the post's style sheet: `display: block` and `none`, `:nth-child()`, `:nth-of-type()` (and their first, last
///    forms), the child combinator `>` were not read;
/// 7. the rules of a forum and a self introduction were in the body text: laid out as a post is now, not shown as one;
/// 9. a serif font the author named (仿宋, 楷体, 宋体, 华文中宋, 明體, Georgia…) is shown in the system's serif font;
/// 10. a `<font size>` in a `<pre>` was the size of one outside: a browser sizes it from its monospace font (13px for
///    medium, not 16px).
library;

// HTML fixtures are split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode_view.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/html/author_style.dart';
import 'package:tsdm_client/utils/html/media_card.dart';
import 'package:tsdm_client/utils/html/post_table.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:tsdm_client/widgets/post_layout_html.dart';
import 'package:universal_html/parsing.dart';

import 'render_regression/harness.dart' show registerFloorServices, seedImages;

final _light = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue));
final _dark = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
);

/// The surface a post's text is on in [theme]: its card.
Color _surface(ThemeData theme) => theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow;

/// [html] as the content of a post card ([post]), or html outside a post.
Future<void> _pump(WidgetTester tester, String html, {bool post = true, ThemeData? theme, Key? boundary}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = const Size(390, 2000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: theme ?? _light,
        themeAnimationDuration: Duration.zero,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: RepaintBoundary(
                key: boundary,
                child: post
                    ? PostTypographyScope(typography: const PostTypography(), child: MunchedHtml(html))
                    : MunchedHtml(html),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
}

/// [html] as the forum serves a floor: in its message cell.
String _inPost(String html) =>
    '<div class="t_fsz"><table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_1">'
    '$html</td></tr></table></div>';

/// Every text span with its style as it is laid out, in every rich text, depth first.
Iterable<(TextSpan, TextStyle)> _spans(WidgetTester tester) sync* {
  Iterable<(TextSpan, TextStyle)> visit(InlineSpan span, TextStyle style) sync* {
    if (span is TextSpan) {
      final own = style.merge(span.style);
      yield (span, own);
      for (final child in span.children ?? const <InlineSpan>[]) {
        yield* visit(child, own);
      }
    }
  }

  for (final e in find.byType(RichText).evaluate()) {
    yield* visit((e.widget as RichText).text, const TextStyle());
  }
}

/// The span showing [text] and its style.
(TextSpan, TextStyle) _span(WidgetTester tester, String text) =>
    _spans(tester).firstWhere((e) => e.$1.text?.contains(text) ?? false, orElse: () => throw StateError(text));

TextStyle _style(WidgetTester tester, String text) => _span(tester, text).$2;

/// The text of the rich text showing [text] as written: the gaps between paragraphs left out, a widget as U+FFFC.
String _raw(WidgetTester tester, String text) {
  String plain(InlineSpan span) {
    final buffer = StringBuffer();
    void visit(InlineSpan s) {
      if (s is ParagraphGapSpan) {
        return;
      }
      if (s is TextSpan) {
        buffer.write(s.text ?? '');
        (s.children ?? const <InlineSpan>[]).forEach(visit);
      } else if (s is PlaceholderSpan) {
        buffer.write('\uFFFC');
      }
    }

    visit(span);
    return buffer.toString();
  }

  return find
      .byType(RichText)
      .evaluate()
      .map((e) => plain((e.widget as RichText).text))
      .lastWhere((e) => e.contains(text));
}

/// Whether any rich text shows [text].
bool _shows(WidgetTester tester, String text) => find
    .byType(RichText)
    .evaluate()
    .any((e) => (e.widget as RichText).text.toPlainText(includeSemanticsLabels: false).contains(text));

/// The background of the block holding [text], null when it is in none.
Color? _blockBackground(WidgetTester tester, String text) {
  bool holds(Widget widget) => find
      .descendant(of: find.byWidget(widget), matching: find.byType(RichText))
      .evaluate()
      .any((r) => (r.widget as RichText).text.toPlainText().contains(text));
  final blocks = [
    ...find.byType(PostTable).evaluate().map((e) => e.widget as PostTable),
    ...find.byType(PostBlockBackground).evaluate().map((e) => e.widget as PostBlockBackground),
    ...find.byType(PostTableCell).evaluate().map((e) => e.widget as PostTableCell),
  ];
  for (final block in blocks.reversed) {
    switch (block) {
      case PostBlockBackground(:final color) when holds(block):
        return color;
      case PostTableCell(:final background?) when holds(block):
        return background;
      case PostTable(:final background?) when holds(block):
        return background;
    }
  }
  return null;
}

/// The players shown.
List<PostMedia> _players(WidgetTester tester) =>
    find.byType(PostMediaCard).evaluate().map((e) => (e.widget as PostMediaCard).media).toList();

/// The video of bilibili the message [html] (a message cell's content) links, as the videohub plugin finds it.
String? _video(String html) {
  final cell = parseHtmlDocument('<table><tr><td id="postmessage_1">$html</td></tr></table>').querySelector('td')!;
  return PostMedia.bilibiliVideoOf(cell)?.url?.toString();
}

/// A floor of the forum's app API (`thread_v14_plain.json`) with the bbcode [message] and its html [messageHtml].
Post _apiFloor(String message, String messageHtml) {
  final json = jsonDecode(File('test/data/tsdmapp/thread_v14_plain.json').readAsStringSync()) as Map<String, dynamic>;
  final floor = (json['posts'] as List).cast<Map<String, dynamic>>().first;
  final pid = floor['pid'];
  floor
    ..['message'] = message
    ..['bbcodeoff'] = 0
    ..['smileyoff'] = 1
    ..['parseurloff'] = 0
    ..['attachments'] = <Object>[]
    ..['body_html'] =
        '<div class="t_fsz"><table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_$pid">'
        '$messageHtml</td></tr></table></div>';
  return threadPageFromApi(json, 1).postList.single;
}

/// The rgba of the pixel at [at] of [image].
Future<(int, int, int, int)> _pixel(WidgetTester tester, ui.Image image, Offset at) async {
  final data = (await tester.runAsync(() => image.toByteData()))!;
  final i = (at.dy.round() * image.width + at.dx.round()) * 4;
  return (data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2), data.getUint8(i + 3));
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('1. the player of a video of bilibili', () {
    const video = 'https://www.bilibili.com/video/BV1xx411c7mD';

    testWidgets('at the end of the message, for the first video it links, once', (tester) async {
      await _pump(
        tester,
        _inPost(
          '看<a href="$video?p=2&amp;spm_id_from=333">这个</a>和'
          '<a href="https://www.bilibili.com/video/BV1yy411c7mE">那个</a>。<br />最后一行',
        ),
      );
      final players = _players(tester);
      expect(players, hasLength(1));
      expect(players.single.url.toString(), '$video/?p=2');
      expect(players.single.site, 'Bilibili');
      expect(players.single.kind, PostMediaKind.video);
      // The last thing of the message, on a line of its own after its last line.
      // A line of its own after the last line, no empty line between.
      expect(_raw(tester, '最后一行'), endsWith('最后一行\n\uFFFC'));
    });

    testWidgets('a url in the text too, its punctuation left out', (tester) async {
      await _pump(tester, _inPost('视频：https://m.bilibili.com/video/BV1xx411c7mD。好看'));
      expect(_players(tester).single.url.toString(), '$video/?p=1');
    });

    testWidgets('not in a quote, code, a hidden or locked block, a closed spoiler, a form, hidden text', (
      tester,
    ) async {
      await _pump(
        tester,
        _inPost(
          '<div class="quote"><blockquote><a href="https://www.bilibili.com/video/BV1aa411c7mD">引用</a>'
          '</blockquote></div>'
          '<div class="blockcode"><code>https://www.bilibili.com/video/BV1bb411c7mD</code></div>'
          '<div class="locked">https://www.bilibili.com/video/BV1cc411c7mD</div>'
          '<div class="showhide">https://www.bilibili.com/video/BV1dd411c7mD</div>'
          '<span style="display:none">https://www.bilibili.com/video/BV1ee411c7mD</span>'
          '<div class="spoiler"><div class="spoilerheader"><input type="button" value="展开" /></div>'
          '<div class="spoilerbody" style="display: none;">https://www.bilibili.com/video/BV1ff411c7mD</div></div>'
          '<style>.gone { display: none }</style><p class="gone">https://www.bilibili.com/video/BV1gg411c7mD</p>'
          '<textarea>https://www.bilibili.com/video/BV1hh411c7mD</textarea>'
          '<a href="javascript:;">https://www.bilibili.com/video/BV1jj411c7mD</a>'
          '最后<a href="https://www.bilibili.com/video/BV1kk411c7mD">看得见的</a>',
        ),
      );
      expect(_players(tester).single.url.toString(), 'https://www.bilibili.com/video/BV1kk411c7mD/?p=1');
    });

    test('the addresses the plugin takes', () {
      for (final (html, expected) in [
        ('<a href="$video">a</a>', '$video/?p=1'),
        ('<a href="$video/">a</a>', '$video/?p=1'),
        ('<a href="http://bilibili.com/video/BV1xx411c7mD">a</a>', '$video/?p=1'),
        ('<a href="https://m.bilibili.com/video/BV1xx411c7mD?p=3#reply">a</a>', '$video/?p=3'),
        ('<a href="HTTPS://WWW.BILIBILI.COM/video/BV1xx411c7mD">a</a>', '$video/?p=1'),
        ('<a href="$video?P=2">a</a>', '$video/?p=1'),
        ('<a href="https://www.bilibili.com:443/video/BV1xx411c7mD">a</a>', '$video/?p=1'),
        // Not taken.
        ('<a href="https://space.bilibili.com/video/BV1xx411c7mD">a</a>', null),
        ('<a href="https://b23.tv/BV1xx411c7mD">a</a>', null),
        ('<a href="https://www.bilibili.com/video/av170001">a</a>', null),
        ('<a href="https://www.bilibili.com/video/BV1xx411c7m">a</a>', null),
        ('<a href="https://www.bilibili.com/video/BV1xx411c70D">a</a>', null),
        ('<a href="$video/index.html">a</a>', null),
        ('<a href="$video?p=2&amp;p=3">a</a>', null),
        ('<a href="$video?p=0">a</a>', null),
        ('<a href="$video?p=65536">a</a>', null),
        ('<a href="$video?p=x">a</a>', null),
        ('<a href="https://www.bilibili.com:8080/video/BV1xx411c7mD">a</a>', null),
        ('<a href="https://u:p@www.bilibili.com/video/BV1xx411c7mD">a</a>', null),
        ('<a href="//www.bilibili.com/video/BV1xx411c7mD">a</a>', null),
        ('<a href=" $video">a</a>', null),
        ('<a href="ftp://www.bilibili.com/video/BV1xx411c7mD">a</a>', null),
        ('<a href="$video?q=${List.filled(2100, 'x').join()}">a</a>', null),
        ('<a href="$video?p=%zz">a</a>', null),
        (video, '$video/?p=1'),
        ('（$video）', '$video/?p=1'),
        ('$video!', '$video/?p=1'),
        ('<blockquote>$video</blockquote>', null),
        ('<pre>$video</pre>', null),
        ('<div hidden>$video</div><span aria-hidden="true">$video</span>', null),
        ('<button>$video</button>', null),
      ]) {
        expect(_video(html), expected, reason: html);
      }
    });

    testWidgets('only in the message of a post', (tester) async {
      // Outside a post (a notice, a message).
      await _pump(tester, _inPost('<a href="$video">视频</a>'), post: false);
      expect(_players(tester), isEmpty);
      // Laid out as a post, not one (the rules of a forum).
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: PostTypographyScope(
                typography: const PostTypography(),
                postContent: false,
                child: MunchedHtml(_inPost('<a href="$video">视频</a>')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(_players(tester), isEmpty);
      // A post: only its message, not what follows it (a signature, the html after the message).
      await _pump(
        tester,
        '<div class="t_fsz"><table><tr><td id="postmessage_1">没有影片</td></tr></table></div>'
        '<div class="sign"><a href="$video">签名里的影片</a></div>',
      );
      expect(_players(tester), isEmpty);
    });

    testWidgets('a tap opens the video outside the app, at its https address', (tester) async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      await _pump(tester, _inPost('<a href="http://bilibili.com/video/BV1xx411c7mD?p=2">视频</a>'));
      await tester.tap(find.byType(PostMediaCard));
      await tester.pump();
      final launch = calls.singleWhere((e) => e.method == 'launch');
      expect((launch.arguments as Map)['url'], '$video/?p=2');
      expect((launch.arguments as Map)['useWebView'], isFalse);
      expect((launch.arguments as Map)['useSafariVC'], isFalse);
    });

    testWidgets('the experimental renderer shows it too, at the end of the message', (tester) async {
      final post = _apiFloor(
        '看看[url=$video?p=2]这个视频[/url]，好看\n下一行',
        '看看<a href="$video?p=2" target="_blank">这个视频</a>，好看<br />\r\n下一行',
      );
      final decision = decidePostBbcode(post);
      expect(decision, isA<PostBbcodeRender>());
      final nodes = (decision as PostBbcodeRender).nodes;
      expect(nodes.last, isA<BbVideo>());
      expect((nodes.last as BbVideo).media.url.toString(), '$video/?p=2');
      expect(nodes.whereType<BbVideo>(), hasLength(1));
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: PostTypographyScope(typography: const PostTypography(), child: PostBbcodeView(nodes)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(_players(tester).single.url.toString(), '$video/?p=2');
      expect(_raw(tester, '下一行'), endsWith('下一行\n\uFFFC'));
      // Without a video, no player.
      final none = decidePostBbcode(_apiFloor('没有视频', '没有视频')) as PostBbcodeRender;
      expect(none.nodes.whereType<BbVideo>(), isEmpty);
    });
  });

  group('2. the experimental renderer and a path on the forum', () {
    test('[img]/path[/img] keeps the html, other images are drawn', () {
      final relative = decidePostBbcode(
        _apiFloor('[img]/img01/medal/a.gif[/img]', '<img src="https://img.tsdm39.com/img01/medal/a.gif" />'),
      );
      expect(relative, isA<PostBbcodeFallback>());
      expect((relative as PostBbcodeFallback).reason, 'img-relative');
      for (final (bbcode, url) in [
        ('[img]https://example.com/a.png[/img]', 'https://example.com/a.png'),
        ('[img]static/image/common/a.gif[/img]', 'https://www.tsdm39.com/static/image/common/a.gif'),
        ('[img]example.com/a.png[/img]', 'http://example.com/a.png'),
      ]) {
        final decision = decidePostBbcode(_apiFloor(bbcode, '<img src="$url" />'));
        expect(decision, isA<PostBbcodeRender>(), reason: bbcode);
        expect(((decision as PostBbcodeRender).nodes.single as BbImage).url, url, reason: bbcode);
      }
    });
  });

  group('3. a table scrolling sideways', () {
    /// A table of [columns] columns on a black background, its text in black: nine are too many for a phone.
    String table(int columns) {
      final row =
          '<tr>${[for (var i = 1; i <= columns; i++) '<td><font color="#000000">第$i列</font></td>'].join()}</tr>';
      return 'x<br /><table bgcolor="#000000">$row$row</table>';
    }

    Future<(ui.Image, Rect)> shot(WidgetTester tester, GlobalKey key) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      final image = (await tester.runAsync(boundary.toImage))!;
      addTearDown(image.dispose);
      final view = tester.renderObject<RenderBox>(find.byType(PostTableScrollView));
      final rect = (boundary.globalToLocal(view.localToGlobal(Offset.zero))) & view.size;
      return (image, rect);
    }

    /// How light the pixel is over the white of the page: 0 black, 255 white.
    Future<int> light(WidgetTester tester, ui.Image image, Offset at) async {
      final (r, g, b, a) = await _pixel(tester, image, at);
      // Premultiplied: what is not painted is the page under it.
      return ((r + g + b) ~/ 3 + 255 - a).clamp(0, 255);
    }

    testWidgets('fades out at the edge it scrolls further past, not at its end', (tester) async {
      final key = GlobalKey();
      await _pump(tester, _inPost(table(9)), boundary: key);
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: find.byType(PostTableScrollView), matching: find.byType(Scrollable)),
          )
          .position;
      expect(position.maxScrollExtent, greaterThan(0));

      var (image, rect) = await shot(tester, key);
      final y = rect.center.dy;
      // At its start: the right edge fades, the left one does not; inside, the table as it is.
      expect(await light(tester, image, Offset(rect.right - 4, y)), greaterThan(150));
      expect(await light(tester, image, Offset(rect.left + 8, y)), lessThan(60));
      expect(await light(tester, image, Offset(rect.center.dx, y)), lessThan(60));

      // At its end: the left edge fades, the right one is the table's.
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      (image, rect) = await shot(tester, key);
      expect(await light(tester, image, Offset(rect.left + 4, y)), greaterThan(150));
      expect(await light(tester, image, Offset(rect.right - 8, y)), lessThan(60));
    });

    testWidgets('a table that fits does not fade', (tester) async {
      await _pump(tester, _inPost(table(1)));
      expect(tester.layers.whereType<ShaderMaskLayer>(), isEmpty);
      await _pump(tester, _inPost(table(9)));
      expect(tester.layers.whereType<ShaderMaskLayer>(), hasLength(1));
    });

    testWidgets('what is under the fade is still tapped', (tester) async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      final columns = [for (var i = 1; i <= 5; i++) '<td>第$i列</td>'].join();
      await _pump(
        tester,
        _inPost(
          'x<br /><table><tr>$columns<td><iframe src="https://player.example.com/v/1"></iframe></td>$columns'
          '</tr></table>',
        ),
      );
      final view = tester.getRect(find.byType(PostTableScrollView));
      // The card in the fade at the right edge, the table going on past it.
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: find.byType(PostTableScrollView), matching: find.byType(Scrollable)),
          )
          .position;
      position.jumpTo(position.pixels + tester.getRect(find.byType(PostMediaCard)).left - (view.right - 10));
      await tester.pump();
      final card = tester.getRect(find.byType(PostMediaCard));
      expect(card.left, moreOrLessEquals(view.right - 10, epsilon: 0.5));
      expect(position.maxScrollExtent - position.pixels, greaterThan(PostTableScrollView.fadeWidth));
      await tester.tapAt(Offset(view.right - 4, card.center.dy));
      await tester.pump();
      expect(calls.where((e) => e.method == 'launch'), hasLength(1));
    });
  });

  group('4. text on a background picture', () {
    const white = Color(0xFFFFFFFF);

    for (final (name, html) in [
      (
        'a row with a picture in a table with a color',
        '<table bgcolor="#ffe0b3"><tr background="https://example.com/dark.jpg"><td>'
            '<span style="color: white">白字</span></td></tr></table>',
      ),
      (
        'a picture and a color in one background',
        '<div style="background: #ffe0b3 url(https://example.com/dark.jpg)"><span style="color: white">白字</span></div>',
      ),
      (
        'a background attribute beside a bgcolor',
        '<table bgcolor="#ffe0b3" background="https://example.com/dark.jpg"><tr><td>a</td><td>'
            '<font color="white">白字</font></td></tr></table>',
      ),
      (
        'a light cell over the picture of its own table',
        '<table background="https://example.com/dark.jpg"><tr><td style="background-color: rgba(255, 255, 255, 0.6)">'
            '<span style="color: white">白字</span></td></tr></table>',
      ),
      (
        'a light color the picture around shows through',
        '<div style="background: url(https://example.com/dark.jpg)"><div style="background-color: rgba(255, 251, 242, 0.8)">'
            '<span style="color: white; text-shadow: 0 0 4px red">白字</span></div></div>',
      ),
    ]) {
      testWidgets('$name: no background, the text readable', (tester) async {
        await _pump(tester, _inPost(html));
        expect(_blockBackground(tester, '白字'), isNull);
        final color = _style(tester, '白字').color!;
        expect(contrastRatio(color, _surface(_light)), greaterThanOrEqualTo(readableContrast));

        // A dark theme as before: the light text reads on the dark card, it is not hidden.
        await _pump(tester, _inPost(html), theme: _dark);
        expect(_blockBackground(tester, '白字'), isNull);
        final dark = _style(tester, '白字').color!;
        expect(contrastRatio(dark, _surface(_dark)), greaterThanOrEqualTo(readableContrast));
      });
    }

    testWidgets('a color without a picture stays as the author gave it', (tester) async {
      await _pump(
        tester,
        _inPost(
          '<div style="background-color: #ffe0b3"><span style="color: white">浅底白字</span></div>'
          '<table background="https://example.com/a.jpg" style="background: pink"><tr><td>a</td><td>'
          '<span style="color: white">粉底白字</span></td></tr></table>',
        ),
      );
      expect(_blockBackground(tester, '浅底白字'), const Color(0xFFFFE0B3));
      expect(_style(tester, '浅底白字').color, white);
      // `background: pink` takes the picture of the attribute away.
      expect(_blockBackground(tester, '粉底白字'), const Color(0xFFFFC0CB));
    });
  });

  group('5. a cell holding a line break', () {
    testWidgets('is a line high, as a cell of text', (tester) async {
      await _pump(
        tester,
        _inPost(
          'x<br /><table><tr><td>甲</td></tr><tr><td><br />\n</td></tr><tr><td></td></tr>'
          '<tr><td><br /><br /></td></tr><tr><td>乙</td></tr></table>',
        ),
      );
      final table = tester.renderObject<RenderPostTable>(find.byType(PostTable));
      final heights = <double>[];
      for (
        var child = table.firstChild;
        child != null;
        child = (child.parentData! as PostTableParentData).nextSibling
      ) {
        heights.add((child.parentData! as PostTableParentData).rect.height);
      }
      expect(heights, hasLength(5));
      final text = heights[0];
      expect(heights[1], moreOrLessEquals(text, epsilon: 0.5), reason: '<td><br></td>');
      expect(heights[2], lessThan(text), reason: 'an empty cell is no line');
      expect(heights[3], greaterThan(text * 1.4), reason: 'two line breaks, two lines');
      expect(heights[4], moreOrLessEquals(text, epsilon: 0.5));
    });
  });

  group("6. the post's style sheet", () {
    testWidgets('display: block puts an element of a line on lines of its own', (tester) async {
      addTearDown(await registerFloorServices());
      final html = _inPost(
        '<style>.t small, .t .big, .t a, .t img { display: block } .t .flex { display: flex }'
        ' .t .ib { display: inline-block }</style>'
        '<div class="t">前<small>小标题</small>后<span class="big"><b>大字</b></span>尾'
        '<a href="https://example.com/">链接块</a>连<span class="flex">弹性</span>行<span class="ib">内块</span>末'
        '<span style="display: block">行内样式</span>完<img src="https://example.com/a-10x10.png" />图后'
        '</div>',
      );
      await seedImages(tester, html);
      await _pump(tester, html);
      expect(_raw(tester, '小标题'), contains('前\n小标题\n后\n大字\n尾\n'));
      // The link out of the forum has its mark before it.
      expect(_raw(tester, '小标题'), contains('尾\n\uFFFC链接块\n连\n弹性\n行内块末\n行内样式\n完\n\uFFFC\n图后'));
      // What it is otherwise is kept: bold, a link.
      expect(_style(tester, '大字').fontWeight, FontWeight.w600);
      final link = _spans(tester).where((e) => e.$1.text?.contains('链接块') ?? false);
      expect(link.single.$1.recognizer, isNotNull);
    });

    testWidgets('a heading ending with a block is followed by no empty line', (tester) async {
      await _pump(
        tester,
        _inPost('<style>h1 span { display: block }</style><h1>金主<span>模板</span></h1><div>正文</div>'),
      );
      expect(
        find
            .byType(RichText)
            .evaluate()
            .map((e) => (e.widget as RichText).text.toPlainText(includeSemanticsLabels: false))
            .any((e) => e.contains('金主\n模板\n正文')),
        isTrue,
      );
    });

    testWidgets('display: none from the style sheet hides, its own style can show it again', (tester) async {
      await _pump(
        tester,
        _inPost(
          '<style>.secret { display: none } .box > .secret2 { display:none }</style>'
          '可见<span class="secret">藏起来</span><span class="secret" style="display: inline">又出现</span>'
          '<div class="box"><b class="secret2">子藏</b><i><b class="secret2">孙见</b></i></div>',
        ),
      );
      expect(_shows(tester, '可见'), isTrue);
      expect(_shows(tester, '藏起来'), isFalse);
      expect(_shows(tester, '又出现'), isTrue);
      expect(_shows(tester, '子藏'), isFalse);
      expect(_shows(tester, '孙见'), isTrue);
    });

    testWidgets('hidden by the style sheet but shown by it on what the app does not see: stays shown', (tester) async {
      await _pump(
        tester,
        _inPost(
          '<style>.c { display: none } #t:checked + .c { display: block } .s span { display: none }'
          ' .s:hover span { display: inline } .gone { display: none } .gone2 { display: none } [data-x] .other {'
          ' display: block }</style>'
          '<input type="checkbox" id="t" /><div class="c">勾选后显示</div><div class="s">悬停<span>悬停显示</span></div>'
          '<div class="gone">一直藏着</div><div class="gone2">也藏着</div>',
        ),
      );
      expect(_shows(tester, '勾选后显示'), isTrue);
      expect(_shows(tester, '悬停显示'), isTrue);
      expect(_shows(tester, '一直藏着'), isFalse);
      expect(_shows(tester, '也藏着'), isFalse);
    });

    testWidgets(':nth-child(), :nth-of-type() and their first and last forms', (tester) async {
      await _pump(
        tester,
        _inPost(
          '<style>'
          '.z span:nth-child(odd) { color: #ff0000 } .z span:nth-child(even) { color: #0000ff }'
          '.y p:nth-of-type(2n+1) { font-weight: bold } .y p:nth-child(2) { font-style: italic }'
          '.x i:nth-child(-n+2) { color: #00ff00 } .x i:nth-child(n+4) { color: #ff00ff }'
          '.w b:first-child { color: #123456 } .w b:last-child { color: #654321 }'
          '.v em:last-of-type { color: #abcdef } .v em:first-of-type { color: #fedcba }'
          '.u s:nth-last-child(2) { color: #111111 } .u s:nth-child(3) { color: #222222 }'
          '</style>'
          '<div class="z"><span>一</span><span>二</span><span>三</span></div>'
          '<div class="y"><span>插</span><p>一段</p><p>二段</p><p>三段</p></div>'
          '<div class="x"><i>甲</i><i>乙</i><i>丙</i><i>丁</i><i>戊</i></div>'
          '<div class="w"><b>首</b><b>中</b><b>尾</b></div>'
          '<div class="v"><em>头</em><u>间</u><em>末</em><u>后</u></div>'
          '<div class="u"><s>壹</s><s>贰</s><s>叁</s></div>',
        ),
      );
      expect(_style(tester, '一').color, const Color(0xFFFF0000));
      expect(_style(tester, '二').color, const Color(0xFF0000FF));
      expect(_style(tester, '三').color, const Color(0xFFFF0000));
      expect(_style(tester, '一段').fontWeight, FontWeight.w600);
      expect(_style(tester, '一段').fontStyle, FontStyle.italic);
      expect(_style(tester, '二段').fontWeight, isNot(FontWeight.w600));
      expect(_style(tester, '三段').fontWeight, FontWeight.w600);
      expect(_style(tester, '甲').color, const Color(0xFF00FF00));
      expect(_style(tester, '乙').color, const Color(0xFF00FF00));
      expect(_style(tester, '丙').color, isNot(anyOf(const Color(0xFF00FF00), const Color(0xFFFF00FF))));
      expect(_style(tester, '丁').color, const Color(0xFFFF00FF));
      expect(_style(tester, '戊').color, const Color(0xFFFF00FF));
      expect(_style(tester, '首').color, const Color(0xFF123456));
      expect(_style(tester, '中').color, isNot(anyOf(const Color(0xFF123456), const Color(0xFF654321))));
      expect(_style(tester, '尾').color, const Color(0xFF654321));
      expect(_style(tester, '头').color, const Color(0xFFFEDCBA));
      expect(_style(tester, '末').color, const Color(0xFFABCDEF));
      expect(_style(tester, '贰').color, const Color(0xFF111111));
      expect(_style(tester, '叁').color, const Color(0xFF222222));
    });

    testWidgets('the child combinator, the ancestors tried further up when the nearest is not one', (tester) async {
      await _pump(
        tester,
        _inPost(
          '<style>.a > .b { color: #ff0000 } .a>.c .d { color: #0000ff } .rule:nth-of-type(even) > span { '
          'background-color: #faf6f2 } .q:nth-child(foo), .q2 { color: #00ff00 } .x > > .y, .x >> .y, > .y {'
          ' color: #ff00ff }</style>'
          '<div class="a"><span class="b">子</span><div><span class="b">孙</span></div>'
          '<div class="c"><div class="c"><span class="d">深</span></div></div></div>'
          '<div class="rules"><div class="rule"><span>第一条</span></div><div class="rule"><span>第二条</span></div></div>'
          '<i class="q2">认得</i><div class="x"><div><i class="y">不认得</i></div></div>',
        ),
      );
      expect(_style(tester, '子').color, const Color(0xFFFF0000));
      expect(_style(tester, '孙').color, isNot(const Color(0xFFFF0000)));
      expect(_style(tester, '深').color, const Color(0xFF0000FF));
      expect(_style(tester, '第一条').backgroundColor, isNull);
      expect(_style(tester, '第二条').backgroundColor, const Color(0xFFFAF6F2));
      expect(_style(tester, '认得').color, const Color(0xFF00FF00));
      expect(_style(tester, '不认得').color, isNot(const Color(0xFFFF00FF)));
    });

    testWidgets('hostile style sheets of these selectors take no time and no floor', (tester) async {
      final css = StringBuffer('<style>.hit span { color: #00ff00 } ');
      for (var i = 0; i < 256; i++) {
        css.write(
          '.c$i > .x > .x > span:nth-child(2n+$i) { color: #ff0000 } .c$i .x > .x span:nth-last-of-type(-n+$i) '
          '{ color: #ff0000; display: none } .x:nth-child(${i}n) > .x .c$i { display: block } ',
        );
      }
      css.write('.x:nth-child(99999999999) { color: #ff0000 } .x:nth-child(1 of .x) { color: #ff0000 }</style>');
      for (final (count, depth) in [(3000, 20), (2000, 60)]) {
        final body = StringBuffer(css)..write('<div class="hit">');
        for (var i = 0; i < count ~/ depth; i++) {
          body.write('${List.filled(depth, '<span class="x">').join()}字${List.filled(depth, '</span>').join()}');
        }
        body.write('</div>');
        final watch = Stopwatch()..start();
        await _pump(tester, _inPost(body.toString()));
        watch.stop();
        expect(watch.elapsedMilliseconds, lessThan(3000), reason: '$count spans, $depth deep');
        expect(_style(tester, '字').color, const Color(0xFF00FF00));
      }
    });
  });

  group('7. the rules of a forum, a self introduction', () {
    const html =
        '<p>第一段的文字比较长，一行放不下，在手机上会排成好几行，读起来要有行距才不累，这是版规常见的写法，后面还有。</p>'
        '<p>第二段也是很长的一段文字，同样一行放不下，两段之间要有段距，不然整片黏在一起，像一堵文字墙。</p>'
        '<em>强调</em><a href="forum.php?mod=viewthread&amp;tid=1">站内链接</a>';

    testWidgets("laid out as a post: the reader's line height and paragraphs", (tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: _light,
            home: Scaffold(
              body: SizedBox(
                width: 346,
                child: PostLayoutHtml(
                  parseHtmlDocument('<html><body>$html</body></html>').body!,
                  typography: const PostTypography(lineHeight: 1.8, paragraphSpacing: 12),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(_style(tester, '第一段').height, 1.8);
      expect(_style(tester, '第一段').letterSpacing, 0);
      final root = find.byType(RichText).evaluate().map((e) => (e.widget as RichText).text).first;
      var gaps = 0;
      root.visitChildren((span) {
        if (span is ParagraphGapSpan) {
          gaps++;
          expect(span.style?.fontSize, 12);
        }
        return true;
      });
      expect(gaps, greaterThan(0));
      // Not shown as a post otherwise: the post's style sheet (`em` in gray) and its link look stay out.
      expect(_style(tester, '强调').color, isNot(const Color(0xFF666666)));
      expect(_style(tester, '站内链接').decoration, isNot(TextDecoration.underline));
      expect(find.byIcon(Icons.link), findsOneWidget);
    });

    testWidgets('before: the body text, without paragraphs', (tester) async {
      await _pump(tester, html, post: false);
      expect(_style(tester, '第一段').height, isNot(1.8));
    });
  });

  group('9. serif fonts', () {
    testWidgets("a serif font the author names is the system serif, another font the app's", (tester) async {
      await _pump(
        tester,
        _inPost(
          '<font face="仿宋">仿宋字</font><font face="楷体_GB2312">楷体字</font><font face="宋体">宋体字</font>'
          '<font face="华文中宋">中宋字</font><font face="新細明體">明體字</font>'
          '<span style="font-family: Georgia, \'Times New Roman\', serif">西文衬线</span>'
          '<span style="font-family: \'Noto Serif SC\'">思源衬线</span>'
          '<font face="微软雅黑">雅黑字</font><span style="font-family: \'Microsoft YaHei\', serif">首选雅黑</span>'
          '<span style="font-family: sans-serif">无衬线</span>'
          '<font face="宋体">外层<font face="黑体">内层黑体</font>回到</font>'
          '<style>.song { font-family: SimSun }</style><span class="song">样式表宋体</span>'
          // A `<pre>` is in its monospace font, not in the font named around it.
          '<font face="宋体"><pre>等宽代码</pre></font>',
        ),
      );
      for (final text in ['仿宋字', '楷体字', '宋体字', '中宋字', '明體字', '西文衬线', '思源衬线', '外层', '回到', '样式表宋体']) {
        expect(_style(tester, text).fontFamily, serifFontFamily, reason: text);
        expect(_style(tester, text).fontFamilyFallback, serifFontFamilyFallback, reason: text);
      }
      for (final text in ['雅黑字', '首选雅黑', '无衬线', '内层黑体', '等宽代码']) {
        expect(_style(tester, text).fontFamily, isNot(serifFontFamily), reason: text);
      }
    });
  });

  group('10. <font size> in <pre>', () {
    testWidgets('sized from the monospace font of a browser, until another font is named', (tester) async {
      await _pump(
        tester,
        _inPost(
          '<font size="5">外面大字</font>'
          '<pre><font size="5">等宽大字</font>\n<font size="3">等宽中字</font>\n'
          '<font face="黑体"><font size="5">先换字体</font></font>\n'
          '<font size="5">还是等宽<font face="黑体">后换字体</font></font>\n'
          '<font size="5" face="黑体">同一个标签</font></pre>'
          '<pre style="font-family: 宋体"><font size="5">整段换字体</font></pre>'
          '<font size="5"><pre>外层字号</pre></font>',
        ),
      );
      // The theme's body text is the web page's 14px.
      final scale = (_light.textTheme.bodyMedium?.fontSize ?? 14) / webPostFontSize;
      expect(_style(tester, '外面大字').fontSize, 24 * scale);
      expect(_style(tester, '等宽大字').fontSize, 24 * 13 / 16 * scale);
      expect(_style(tester, '等宽中字').fontSize, 13 * scale);
      expect(_style(tester, '先换字体').fontSize, 24 * scale);
      expect(_style(tester, '还是等宽').fontSize, 24 * 13 / 16 * scale);
      expect(_style(tester, '后换字体').fontSize, 24 * scale);
      expect(_style(tester, '同一个标签').fontSize, 24 * scale);
      expect(_style(tester, '整段换字体').fontSize, 24 * scale);
      // A `<font size>` around the `<pre>` is sized in its font too.
      expect(_style(tester, '外层字号').fontSize, 24 * 13 / 16 * scale);
    });
  });
}
