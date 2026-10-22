/// The style the author gave a post is shown as the web page shows it (the second phase of the post display work: the
/// posts read flat, "like PTT", measured against the web page floor by floor).
///
/// What was wrong, and is checked here on small samples written after the real posts:
///
/// * the `style` of an element was read on a `<span>` only, and only its color and a size of `1` to `7`: the sizes in
///   pixels and points pasted from other pages (`font-size: 12pt`), the weight, the slant, the decoration, the
///   alignment and the indent of a block were dropped; `[size=2]` was the body text and `[size=3]` a pixel larger than
///   the web page's;
/// * the background of a block (`<div style="background-color: pink">`, `<table bgcolor="wheat">`, the blocks of an
///   activity's rules) was not shown at all;
/// * the classes of the forum's style sheet (`.xi1`, `.xw1`…) and the post's own `<style>` (`.Red`, white text with a
///   red glow, was the body text) were not read;
/// * in a dark theme every author color was inverted, readable or not (a yellow became olive);
/// * a link in a `<font color>` took the font's color (the web page colors every link, `.t_f a`), links had no
///   underline and every one of them a mark before it.
///
/// And from the review of the fix (group `the review`): css a post writes can be hostile or broken, every step of it
/// is bounded and fails to no style (a chain of `var()` grew to gigabytes, a thousand rules took seconds, a number of
/// four hundred digits threw); text on a block whose color the app did not take was the theme's dark text on a dark
/// block; dark colors and white text were hidden in a dark theme where they should not, and white text shown where
/// it should be hidden; shadows went over the floor above; a block with a background in a centered one lost the
/// centering.
library;

// HTML fixtures are split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/html/author_style.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/post_table.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/utils/html/types.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:universal_html/parsing.dart';

final _light = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue));
final _dark = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
);

/// [html] as the content of a post ([post]: in a [PostTypographyScope], as a post card shows it).
Future<void> _pump(WidgetTester tester, String html, {bool post = true, ThemeData? theme}) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: theme ?? _light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 400,
              child: post
                  ? PostTypographyScope(typography: const PostTypography(), child: MunchedHtml(html))
                  : MunchedHtml(html),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
}

/// Every text span with its style as it is laid out (merged with the styles of the spans around it), in every rich
/// text, depth first.
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

/// The style [text] is laid out in.
TextStyle _style(WidgetTester tester, String text) =>
    _spans(tester).firstWhere((e) => e.$1.text?.contains(text) ?? false, orElse: () => throw StateError(text)).$2;

/// The rich text holding [text].
RichText _richText(WidgetTester tester, String text) => find
    .byType(RichText)
    .evaluate()
    .map((e) => e.widget as RichText)
    .lastWhere((e) => e.text.toPlainText(includeSemanticsLabels: false).contains(text));

/// The background of the block holding [text], null when it is in none: a block with a background, or the cell of a
/// table with one.
Color? _blockBackground(WidgetTester tester, String text) {
  bool holds(Widget widget) => find
      .descendant(of: find.byWidget(widget), matching: find.byType(RichText))
      .evaluate()
      .any((r) => (r.widget as RichText).text.toPlainText().contains(text));
  final blocks = [
    ...find.byType(PostBlockBackground).evaluate().map((e) => e.widget as PostBlockBackground),
    ...find.byType(PostTableCell).evaluate().map((e) => e.widget as PostTableCell),
  ];
  for (final block in blocks.reversed) {
    switch (block) {
      case PostBlockBackground(:final color) when holds(block):
        return color;
      case PostTableCell(:final background?) when holds(block):
        return background;
    }
  }
  return null;
}

/// [html] as the forum serves a post: in its cell (a `<style>` first in a document would go to its head).
String _inPost(String html) =>
    '<div class="t_fsz"><table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_1">'
    '$html</td></tr></table></div>';

/// The colors of [c] as 0–255 channels.
(int, int, int) _rgb(Color c) => ((c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round());

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('the style attribute', () {
    testWidgets('color, weight, slant and decoration', (tester) async {
      await _pump(
        tester,
        '<span style="color: rgb(255, 0, 0); font-weight: bold; font-style: italic">红粗斜</span>'
        '<b><span style="font-weight: normal">不粗</span></b>'
        '<span style="text-decoration: underline">底线</span>'
        '<span style="text-decoration-line: line-through">删除</span>'
        '<font color="blue"><span style="color:#00ff00">绿胜过蓝</span></font>',
      );
      final red = _style(tester, '红粗斜');
      expect(red.color, const Color(0xFFFF0000));
      expect(red.fontWeight, FontWeight.w600);
      expect(red.fontStyle, FontStyle.italic);
      expect(_style(tester, '不粗').fontWeight, isNot(FontWeight.w600), reason: 'the author unbolds what <b> bolds');
      expect(_style(tester, '底线').decoration, TextDecoration.underline);
      expect(_style(tester, '删除').decoration, TextDecoration.lineThrough);
      expect(_style(tester, '绿胜过蓝').color, const Color(0xFF00FF00), reason: 'the style over the attribute');
    });

    testWidgets('font sizes in pixels, points, multiples and keywords, at the ratio of the web page', (tester) async {
      await _pump(
        tester,
        '<span style="font-size: 16px">像素</span>'
        '<span style="font-size: 12pt">点数</span>'
        '<font size="5"><span style="font-size: 50%">一半</span><span style="font-size: 1.5em">倍数</span></font>'
        '<span style="font-size: x-large">关键字</span>'
        '<span style="font-size: 200px">太大</span>'
        '<span style="font-size: 2px">太小</span>'
        '<span style="font-size: calc(1vw + 2px)">不认得</span>',
      );
      expect(_style(tester, '像素').fontSize, 16);
      expect(_style(tester, '点数').fontSize, 16);
      expect(_style(tester, '一半').fontSize, 12, reason: 'of the size around it: [size=5], 24');
      expect(_style(tester, '倍数').fontSize, 36);
      expect(_style(tester, '关键字').fontSize, 24);
      expect(_style(tester, '太大').fontSize, maxWebFontSize);
      expect(_style(tester, '太小').fontSize, minWebFontSize);
      expect(_style(tester, '不认得').fontSize, 14, reason: 'the body text');
    });

    testWidgets('the sizes follow the body text of the app', (tester) async {
      final big = _light.copyWith(textTheme: _light.textTheme.copyWith(bodyMedium: const TextStyle(fontSize: 28)));
      await _pump(tester, '<font size="2">二号</font><span style="font-size: 16px">十六</span>正文', theme: big);
      expect(_style(tester, '二号').fontSize, 26);
      expect(_style(tester, '十六').fontSize, 32);
      expect(_style(tester, '正文').fontSize, 28);
    });

    testWidgets('line height and font family are not taken', (tester) async {
      await _pump(tester, '<p style="line-height: 30px; font-family: 楷体">段落</p>');
      final style = _style(tester, '段落');
      expect(style.height, PostTypography.defaultLineHeight, reason: "the reader's setting");
      expect(style.fontFamily, isNot('楷体'));
    });

    testWidgets('values that cannot be read are left out, the rest is taken', (tester) async {
      await _pump(
        tester,
        '<span style="color: notacolor; font-size: big; text-shadow: 1px; font-weight: 700;; ;:x">还在</span>',
      );
      final style = _style(tester, '还在');
      expect(style.fontWeight, FontWeight.w600);
      expect(style.fontSize, 14);
      expect(style.shadows, isNull);
    });
  });

  group('the size of <font size>', () {
    test('as a browser reads it', () {
      expect([for (var i = 1; i <= 7; i++) FontSize.fromString('$i').value()], [10, 13, 16, 18, 24, 32, 48]);
      expect(FontSize.fromString('+1'), FontSize.size4);
      expect(FontSize.fromString('-2'), FontSize.size1);
      expect(FontSize.fromString('9'), FontSize.size7);
      expect(FontSize.fromString('0'), FontSize.size1);
      expect(FontSize.fromString(' 3 '), FontSize.size3);
      expect(FontSize.fromString('12px'), FontSize.size7);
      expect(FontSize.fromString('big').isValid, isFalse);
      expect(FontSize.fromString(null).isValid, isFalse);
    });

    testWidgets('[size=2] is smaller than the body text, as on the web page', (tester) async {
      await _pump(tester, '<font size="2">小</font><font size="3">中</font>正文');
      expect(_style(tester, '小').fontSize, 13);
      expect(_style(tester, '中').fontSize, 16);
    });
  });

  group('backgrounds', () {
    testWidgets('of text in a line, of a block as a block', (tester) async {
      await _pump(
        tester,
        '前面<span style="background-color: #ffff00">黄底</span>后面'
        '<div style="background-color: pink">粉色的块</div>'
        '<div style="background: #fff url(x.png) repeat">图上的块</div>'
        '<span style="background: white">白底</span>',
      );
      expect(_style(tester, '黄底').backgroundColor, const Color(0xFFFFFF00));
      expect(_style(tester, '后面').backgroundColor, isNull);
      expect(_blockBackground(tester, '粉色的块'), const Color(0xFFFFC0CB));
      expect(_style(tester, '粉色的块').backgroundColor, isNull, reason: 'the block, not each line');
      // White is the web page's own background: nothing to see there.
      expect(_blockBackground(tester, '图上的块'), isNull);
      expect(_style(tester, '白底').backgroundColor, isNull);
    });

    testWidgets('of a table, its rows and its cells', (tester) async {
      await _pump(
        tester,
        '<table class="t_table" bgcolor=" Wheat"><tr><td>甲</td><td>乙</td></tr>'
        '<tr bgcolor="#99CCFF"><td>丙</td><td bgcolor="pink">丁</td></tr></table>',
      );
      // The table's under the whole table, the row's under its cells, the cell's under its text.
      final table = tester.widget<PostTable>(find.byType(PostTable));
      expect(table.background, const Color(0xFFF5DEB3));
      expect(table.rowBackgrounds, [null, const Color(0xFF99CCFF)]);
      expect(_blockBackground(tester, '丁'), const Color(0xFFFFC0CB));
      expect(_blockBackground(tester, '丙'), isNull);
    });

    testWidgets('of a table that only wraps something', (tester) async {
      await _pump(tester, '前<table bgcolor="#ffe0b3"><tr><td>包起来的内容</td></tr></table>后');
      expect(_blockBackground(tester, '包起来的内容'), const Color(0xFFFFE0B3));
      expect(find.byType(PostTable), findsNothing);
      expect(_richText(tester, '后').text.toPlainText(), contains('后'));
    });
  });

  group('alignment and indent of a block', () {
    testWidgets('text-align', (tester) async {
      await _pump(
        tester,
        '<div style="text-align: center">置中</div>'
        '<p style="text-align:right">靠右</p>'
        '<div align="center" style="text-align: left">样式胜过属性</div>'
        '<table><tr><td align="center">格一</td><td style="text-align: right">格二</td></tr></table>',
      );
      expect(_richText(tester, '置中').textAlign, TextAlign.center);
      expect(_richText(tester, '靠右').textAlign, TextAlign.right);
      expect(_richText(tester, '样式胜过属性').textAlign, isNot(TextAlign.center));
      expect(_richText(tester, '格一').textAlign, TextAlign.center);
      expect(_richText(tester, '格二').textAlign, TextAlign.right);
    });

    testWidgets('text-align left of every pasted paragraph is no block of its own', (tester) async {
      await _pump(tester, '<p style="text-align: left">一</p><p style="text-align: left">二</p>');
      expect(find.byType(RichText), findsOneWidget);
    });

    testWidgets('text-indent: the first line of a block, in a post', (tester) async {
      const html = '<p style="text-indent: 2em">首行缩进<br />第二行不缩</p><p style="text-indent: 2em">又一段</p>';
      await _pump(tester, html);
      final root = find.byType(RichText).evaluate().first.widget as RichText;
      final indents = <double>[];
      final texts = <String>[];
      root.text.visitChildren((span) {
        if (span is WidgetSpan && span.child is SizedBox) {
          indents.add((span.child as SizedBox).width!);
          texts.add('');
        } else if (span is TextSpan && span.text != null && texts.isNotEmpty && texts.last.isEmpty) {
          texts.last = span.text!.trim();
        }
        return true;
      });
      expect(indents, [28, 28], reason: '2em of 14');
      expect(texts, ['首行缩进', '又一段']);

      await _pump(tester, html, post: false);
      var widgets = 0;
      (find.byType(RichText).evaluate().first.widget as RichText).text.visitChildren((span) {
        widgets += span is WidgetSpan ? 1 : 0;
        return true;
      });
      expect(widgets, 0, reason: 'not a post: no paragraph layout');
    });
  });

  group("the classes of the forum's style sheet", () {
    testWidgets('colors, weight, size', (tester) async {
      await _pump(
        tester,
        '<span class="xi1">橙红</span><span class="xw1">加粗</span><span class="xs1">小字</span>'
        '<span class="xg1">灰字<a href="forum.php?mod=viewthread&amp;tid=1">灰链</a></span>',
      );
      expect(_style(tester, '橙红').color, const Color(0xFFF26C4F));
      expect(_style(tester, '加粗').fontWeight, FontWeight.w600);
      expect(_style(tester, '小字').fontSize, 12);
      expect(_style(tester, '灰字').color, const Color(0xFF999999));
      expect(_style(tester, '灰链').color, const Color(0xFF999999));
    });

    testWidgets('the mark of a list item in the color and size of its text', (tester) async {
      await _pump(tester, '<font color="DarkSlateBlue" size="4"><ul><li>条目</li></ul></font>');
      final mark = _style(tester, '•');
      expect(mark.color, const Color(0xFF483D8B));
      expect(mark.fontSize, 18);
    });

    testWidgets('a cell is at the size of the post, not of a <font> around the table', (tester) async {
      await _pump(
        tester,
        '<font size="5">外面<table><tr><td>格子</td><td><font size="2">小格</font></td></tr></table></font>',
      );
      expect(_style(tester, '外面').fontSize, 24);
      expect(_style(tester, '格子').fontSize, 14);
      expect(_style(tester, '小格').fontSize, 13);
    });
  });

  group("the post's own <style>", () {
    testWidgets('class, tag, id, tag with class, ancestors', (tester) async {
      await _pump(
        tester,
        _inPost(
          '<style>\n/* 活动帖 */\n'
          '.Red { text-shadow: 0 0 6px #FF0000, 3px 0 6px #FF0000; color: #fff; font-size: 20px; }\n'
          'b { color: #800080 }\n'
          '#tsdm { color: #0000ff }\n'
          'span.big { font-size: 24px }\n'
          '.box i { color: #00aa00 }\n'
          '.card .meta .label span { color: #d6bec8 }\n'
          '</style>'
          '<span class="Red">序章</span><b>粗体</b><span id="tsdm">编号</span><span class="big">大字</span>'
          '<div class="box"><i>框里</i></div><i>框外</i>'
          '<div class="card"><div class="meta"><b class="label"><span>三层祖先</span></b></div></div>',
        ),
      );
      final red = _style(tester, '序章');
      expect(red.color, const Color(0xFFFFFFFF));
      expect(red.fontSize, 20);
      expect(red.shadows, [
        const Shadow(color: Color(0xFFFF0000), blurRadius: 6),
        const Shadow(color: Color(0xFFFF0000), offset: Offset(3, 0), blurRadius: 6),
      ]);
      expect(_style(tester, '粗体').color, const Color(0xFF800080));
      expect(_style(tester, '编号').color, const Color(0xFF0000FF));
      expect(_style(tester, '大字').fontSize, 24);
      expect(_style(tester, '框里').color, const Color(0xFF00AA00));
      expect(_style(tester, '框外').color, isNot(const Color(0xFF00AA00)));
      expect(_style(tester, '三层祖先').color, const Color(0xFFD6BEC8), reason: 'up to three ancestors');
      expect(find.textContaining('text-shadow', findRichText: true), findsNothing, reason: 'the style is not text');
    });

    testWidgets('the cascade: specificity, order, the style attribute, !important', (tester) async {
      await _pump(
        tester,
        _inPost(
          '<style>'
          '#a { color: #0000ff } .c { color: #ff0000 }'
          '.d { color: #ff0000 } .d { color: #00ff00 }'
          '.e { color: #ff0000 !important }'
          '</style>'
          '<span id="a" class="c">编号胜过类别</span><span class="d">后面的胜</span>'
          '<span class="c" style="color: #00ff00">属性胜过样式表</span>'
          '<span class="e" style="color: #00ff00">重要胜过属性</span>',
        ),
      );
      expect(_style(tester, '编号胜过类别').color, const Color(0xFF0000FF));
      expect(_style(tester, '后面的胜').color, const Color(0xFF00FF00));
      expect(_style(tester, '属性胜过样式表').color, const Color(0xFF00FF00));
      expect(_style(tester, '重要胜过属性').color, const Color(0xFFFF0000));
    });

    testWidgets('custom properties; what is not understood is left out', (tester) async {
      await _pump(
        tester,
        _inPost(
          '<style>'
          '.wrap { --ink: #123456; --paper: var(--ink); }'
          '.wrap span { color: var(--ink) }'
          '.wrap u { color: var(--missing) }'
          '.wrap s { color: var(--missing, #654321) }'
          '@media (max-width: 600px) { .wrap span { color: #ff0000 } }'
          '@keyframes spin { from { color: red } to { color: blue } }'
          '.wrap > b, .wrap:hover b, * { color: #ff0000 }'
          '.v .w .x .y .z { color: #ff0000 } [title] { color: #ff0000 } .wrap::before { color: #ff0000 }'
          '.good, .wrap >> bad { font-weight: bold }'
          '</style>'
          '<div class="wrap"><span>变量</span><u>缺变量</u><s>备用值</s><b>不支持</b>'
          '<div class="v"><div class="w"><div class="x"><div class="y"><i class="z">五层</i></div></div></div></div>'
          '<i title="t">属性</i></div>'
          '<em class="good">列表里认得的</em>',
        ),
      );
      expect(_style(tester, '变量').color, const Color(0xFF123456));
      expect(_style(tester, '缺变量').color, isNot(const Color(0xFFFF0000)));
      expect(_style(tester, '备用值').color, const Color(0xFF654321));
      for (final text in ['不支持', '五层', '属性']) {
        expect(_style(tester, text).color, isNot(const Color(0xFFFF0000)), reason: text);
      }
      expect(_style(tester, '列表里认得的').fontWeight, FontWeight.w600);
    });

    testWidgets('a broken or huge style sheet does not take the floor with it, nor its time', (tester) async {
      final huge = StringBuffer('<style>');
      for (var i = 0; i < 20000; i++) {
        huge.write('.c$i span { color: #${(i % 0xFFFFFF).toRadixString(16).padLeft(6, '0')} } ');
      }
      huge.write('.late { color: #ff0000 } .open { color: </style>');
      final watch = Stopwatch()..start();
      await _pump(tester, _inPost('$huge<span class="late">内容还在</span><span class="c1">x</span>'));
      watch.stop();
      expect(huge.length, greaterThan(maxStyleSheetLength * 4));
      expect(_style(tester, '内容还在').color, isNot(const Color(0xFFFF0000)), reason: 'past the length read');
      expect(watch.elapsedMilliseconds, lessThan(5000));

      await _pump(
        tester,
        _inPost('<style>.a { color: red; .b { { } } }}} .c{color:</style><span class="a">没有坏</span>'),
      );
      expect(find.textContaining('没有坏', findRichText: true), findsOneWidget);
    });

    test('parsing on its own', () {
      final sheets = AuthorStyleSheets.parse('.a{color:red}.a b{font-weight:bold}');
      expect(sheets, isNotNull);
      expect(parseCssDeclarations('color: red; background: url("a;b.png") #fff; x').map((e) => e.property), [
        'color',
        'background',
      ]);
      expect(parseCssDeclarations('color: red !important').single.important, isTrue);
    });
  });

  group('css values', () {
    test('colors', () {
      expect(parseCssColor('#abc'), const Color(0xFFAABBCC));
      expect(parseCssColor('#AABBCC80'), const Color(0x80AABBCC));
      expect(parseCssColor('rgb(1, 2, 3)'), const Color(0xFF010203));
      expect(parseCssColor('rgba(255, 0, 0, 0.5)'), const Color(0x80FF0000));
      expect(parseCssColor('rgb(0 0 255 / 50%)'), const Color(0x800000FF));
      expect(parseCssColor('rgb(100%, 0%, 0%)'), const Color(0xFFFF0000));
      expect(parseCssColor('hsl(120, 100%, 25%)'), const Color(0xFF008000));
      expect(parseCssColor(' Silver '), const Color(0xFFC0C0C0));
      expect(parseCssColor('transparent')!.a, 0);
      for (final value in ['currentColor', 'inherit', 'url(x)', '#12', 'rgb(1,2)', 'linear-gradient(red, blue)']) {
        expect(parseCssColor(value), isNull, reason: value);
      }
    });

    test('color attributes, as a browser reads them', () {
      expect(parseLegacyColor('#8ac9b'), const Color(0xFF8AC9B0), reason: 'a digit short');
      expect(parseLegacyColor('#ff00'), const Color(0xFFFF0000));
      expect(parseLegacyColor('8b0000'), const Color(0xFF8B0000));
      expect(parseLegacyColor('#abc'), const Color(0xFFAABBCC));
      expect(parseLegacyColor(' DeepSkyBlue '), const Color(0xFF00BFFF));
      expect(parseLegacyColor('#zz0000'), const Color(0xFF000000));
      expect(parseLegacyColor('#123456789abc'), const Color(0xFF12569A), reason: 'each part cut to two digits');
      expect(parseLegacyColor(''), isNull);
      expect(parseLegacyColor('transparent'), isNull);
    });

    testWidgets('a <font color> of five or four digits is the color the web page shows', (tester) async {
      await _pump(tester, '<font color="#8ac9b">五位</font><font color="#ff00">四位</font>');
      expect(_style(tester, '五位').color, const Color(0xFF8AC9B0));
      expect(_style(tester, '四位').color, const Color(0xFFFF0000));
    });

    test('font sizes and lengths', () {
      expect(parseCssFontSize('10.5pt'), const CssLength.px(14));
      expect(parseCssFontSize('120%'), const CssLength.em(1.2));
      expect(parseCssFontSize('small'), const CssLength.px(13));
      expect(parseCssFontSize('larger'), const CssLength.em(1.2));
      expect(parseCssFontSize('1rem'), const CssLength.px(16));
      expect(parseCssFontSize('-1px'), isNull);
      expect(parseCssFontSize('8vw'), isNull);
      expect(parseCssLength('0'), const CssLength.px(0));
      expect(parseCssLength('12'), isNull, reason: 'a number without a unit is no length');
    });

    test('text shadows', () {
      expect(parseCssTextShadows('none'), isEmpty);
      final shadows = parseCssTextShadows('rgb(255, 56, 56) 2px 0px 4px, 0-3px 6px #FF0000, 0.1em 0 0.1em')!;
      expect(shadows, hasLength(3));
      expect(shadows[0].color, const Color(0xFFFF3838));
      expect(shadows[1].dy, const CssLength.px(-3));
      expect(shadows[2].color, isNull, reason: 'the color of the text');
      expect(shadows[2].dx, const CssLength.em(0.1));
      expect(parseCssTextShadows('1px'), isNull);
      expect(parseCssTextShadows(List.filled(20, '1px 1px red').join(',')), hasLength(6));
    });
  });

  group('colors in a dark theme', () {
    testWidgets('a light theme shows the colors as given', (tester) async {
      await _pump(
        tester,
        '<font color="#000080">深蓝</font><font color="yellow">黄色</font>'
        '<div style="background-color: pink"><font color="#ff0000">粉底红字</font></div>',
      );
      expect(_style(tester, '深蓝').color, const Color(0xFF000080));
      expect(_style(tester, '黄色').color, const Color(0xFFFFFF00));
      expect(_blockBackground(tester, '粉底红字'), const Color(0xFFFFC0CB));
      expect(_style(tester, '粉底红字').color, const Color(0xFFFF0000));
    });

    testWidgets('text reads on what it is on, in its hue; backgrounds are dark in theirs', (tester) async {
      await _pump(
        tester,
        '<font color="#000080">深蓝</font><font color="yellow">黄色</font><font color="#ff0000">红色</font>'
        '<div style="background-color: pink"><font color="#ff0000">粉底红字</font>粉底正文</div>'
        '<span style="background-color: #ffff00"><font color="#000000">黄底黑字</font></span>',
        theme: _dark,
      );
      final surface = _dark.colorScheme.surfaceContainerLow;
      final navy = _style(tester, '深蓝').color!;
      expect(contrastRatio(navy, surface), greaterThanOrEqualTo(readableContrast));
      final (r, g, b) = _rgb(navy);
      expect(b, greaterThan(r), reason: 'still blue');
      expect(b, greaterThan(g));
      expect(_style(tester, '黄色').color, const Color(0xFFFFFF00), reason: 'readable already: kept, not inverted');
      final red = _style(tester, '红色').color!;
      expect(contrastRatio(red, surface), greaterThanOrEqualTo(readableContrast));
      expect(_rgb(red).$1, greaterThan(_rgb(red).$2), reason: 'still red');

      final pink = _blockBackground(tester, '粉底红字')!;
      expect(relativeLuminance(pink), lessThan(0.08), reason: 'a dark background');
      expect(_rgb(pink).$1, greaterThan(_rgb(pink).$2), reason: 'still pink');
      expect(contrastRatio(_style(tester, '粉底红字').color!, pink), greaterThanOrEqualTo(readableContrast));

      final yellow = _style(tester, '黄底黑字').backgroundColor!;
      expect(relativeLuminance(yellow), lessThan(0.15));
      expect(contrastRatio(_style(tester, '黄底黑字').color!, yellow), greaterThanOrEqualTo(readableContrast));
    });

    testWidgets('text hidden in the color of its background stays hidden', (tester) async {
      await _pump(
        tester,
        '<span style="background-color: #000000; color: #000000">藏起来的答案</span>',
        theme: _dark,
      );
      final style = _style(tester, '藏起来的答案');
      expect(contrastRatio(style.color!, style.backgroundColor!), lessThan(camouflageContrast));
    });

    test('the rules on their own', () {
      for (final color in [Colors.black, Colors.red, Colors.blue, const Color(0xFF808000), const Color(0xFF336699)]) {
        for (final on in [const Color(0xFF1D1B20), Colors.white, const Color(0xFF49303B)]) {
          expect(
            contrastRatio(readableInk(color, on), on),
            greaterThanOrEqualTo(readableContrast),
            reason: '$color $on',
          );
        }
      }
      expect(darkBackground(const Color(0xFF49303B)), const Color(0xFF49303B), reason: 'dark already');
      expect(relativeLuminance(darkBackground(Colors.white)), lessThan(relativeLuminance(darkBackground(Colors.pink))));
    });
  });

  group('links', () {
    testWidgets('underlined in the theme link color, not in the color of a <font> around them', (tester) async {
      await _pump(
        tester,
        '<font color="red"><a href="forum.php?mod=viewthread&amp;tid=1">字体包住的链接</a></font>'
        '<a href="forum.php?mod=viewthread&amp;tid=2"><font color="red">链接里的红字</font></a>'
        '<a href="home.php?mod=space&amp;uid=1" style="text-decoration: none; color: #333333">不加底线</a>',
      );
      final primary = _light.colorScheme.primary;
      final outside = _style(tester, '字体包住的链接');
      expect(outside.color, primary);
      expect(outside.decoration, TextDecoration.underline);
      final inside = _style(tester, '链接里的红字');
      expect(inside.color, const Color(0xFFFF0000));
      expect(inside.decoration, TextDecoration.underline);
      expect(inside.decorationColor, primary, reason: "the underline is the link's");
      final plain = _style(tester, '不加底线');
      expect(plain.color, const Color(0xFF333333));
      expect(plain.decoration, isNot(TextDecoration.underline));
    });

    testWidgets('a mark only before a link out of the forum and an email address', (tester) async {
      await _pump(
        tester,
        '<a href="forum.php?mod=viewthread&amp;tid=1">论坛的帖子</a>'
        '<a href="https://www.tsdm39.com/forum.php?mod=forumdisplay&amp;fid=8">论坛的版块</a>'
        '<a href="javascript:;">脚本</a>',
      );
      expect(find.byIcon(Icons.link), findsNothing);
      await _pump(tester, '<a href="https://pan.baidu.com/s/1">网盘</a><a href="mailto:a@example.com">信箱</a>');
      expect(find.byIcon(Icons.link), findsOneWidget);
      expect(find.byIcon(Icons.email_outlined), findsOneWidget);
      expect(postLinkHasMark('https://example.com/'), isTrue);
      expect(postLinkHasMark('//example.com/'), isTrue);
      expect(postLinkHasMark('forum.php?mod=viewthread&tid=1'), isFalse);
      expect(postLinkHasMark('http://tsdm39.com/home.php'), isFalse);
    });

    testWidgets('outside a post (a notice, a message): marked, not underlined, as before', (tester) async {
      await _pump(tester, '<a href="forum.php?mod=viewthread&amp;tid=1">通知里的链接</a>', post: false);
      expect(find.byIcon(Icons.link), findsOneWidget);
      expect(_style(tester, '通知里的链接').decoration, isNot(TextDecoration.underline));
    });
  });

  group('the review', () {
    String varChain(int levels) {
      final css = StringBuffer('.a { --v0: x; }');
      for (var i = 1; i <= levels; i++) {
        final ref = 'var(--v${i - 1})';
        css.write('.a { --v$i: ${List.filled(256 ~/ ref.length, ref).join()}; }');
      }
      return '$css span { color: var(--v$levels); } .a { color: var(--v$levels) }';
    }

    testWidgets('a chain of var() is bounded: no style, no time', (tester) async {
      for (final levels in [5, 6, 7]) {
        final watch = Stopwatch()..start();
        await _pump(tester, _inPost('<style>${varChain(levels)}</style>${List.filled(100, '<span>字</span>').join()}'));
        watch.stop();
        expect(watch.elapsedMilliseconds, lessThan(2000), reason: '$levels levels');
        expect(_style(tester, '字').color, isNot(const Color(0xFF000000)));
      }
      final declarations = parseCssDeclarations(
        'color: var(--a); font-weight: bold',
        variables: {
          '--a': List.filled(32, 'var(--b)').join(),
          '--b': List.filled(32, 'var(--c)').join(),
          '--c': List.filled(32, 'var(--d)').join(),
          '--d': 'xxxxxxxx',
        },
      );
      expect(declarations.map((e) => e.property), ['font-weight'], reason: 'the value grew too long: left out');
      final sheets = AuthorStyleSheets.parse(varChain(7))!;
      final root = parseHtmlDocument('<div class="a"><span>t</span></div>').body!;
      expect(sheets.styler(root).styleOf(root.querySelector('span')!), isNull);
    });

    testWidgets('a thousand rules with ancestors on a long, deep floor take no time', (tester) async {
      // As many rules as are taken, the one that matches first.
      final css = StringBuffer('<style>.hit span { color: #00ff00 } ');
      for (var i = 0; i < 512; i++) {
        css.write('.c$i span { color: #ff0000 } .c$i .x .y span { color: #ff0000 } ');
      }
      css.write('</style>');
      for (final (count, depth) in [(3000, 20), (2000, 30)]) {
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

    testWidgets('comments not closed, braces, parentheses: read in one go', (tester) async {
      final watch = Stopwatch()..start();
      for (final css in [
        List.filled(30000, '/*').join(),
        List.filled(60000, '{').join(),
        'a{${List.filled(60000, ';').join()}}',
        'a{color:${List.filled(60000, '(').join()}}',
        '${List.filled(30000, 'a ').join()}{color:red}',
      ]) {
        AuthorStyleSheets.parse(css, budget: const Duration(seconds: 1));
      }
      expect(watch.elapsedMilliseconds, lessThan(2000));
    });

    testWidgets('numbers too large or no numbers: no style, the text is there', (tester) async {
      final huge = List.filled(400, '9').join();
      for (final html in [
        '前文<span style="color: rgb(1e400, 0, 0)">被吃掉的字</span>后文',
        '<style>td { color: hsl(1e400, 50%, 50%) }</style>整楼文字',
        '<style>body { color: rgb(1e999, 0, 0) }</style>整楼文字',
        '<span style="color: rgba(0, 0, 0, NaN); font-size: ${huge}px; text-indent: ${huge}em">大数</span>',
        '<span style="text-shadow: ${huge}px 0 0 red">影子文字</span>',
      ]) {
        await _pump(tester, _inPost(html));
        expect(find.byType(ErrorWidget), findsNothing, reason: html);
      }
      expect(parseCssColor('rgb(1e400, 0, 0)'), isNull);
      expect(parseCssColor('hsl(1e400, 50%, 50%)'), isNull);
      expect(parseCssColor('rgba(0, 0, 0, 1e400)'), isNull);
      expect(parseCssTextShadows('${huge}px 0 0 red'), isNull);
      expect(parseCssLength('${huge}px'), isNull);
    });

    testWidgets('shadows stay by their text, the content paints around its own box', (tester) async {
      await _pump(tester, _inPost('<span style="text-shadow: 0 -100px 0 red, 5em 0 3em blue">影子</span>'));
      expect(_style(tester, '影子').shadows, [
        const Shadow(color: Color(0xFFFF0000), offset: Offset(0, -14)),
        const Shadow(color: Color(0xFF0000FF), offset: Offset(14, 0), blurRadius: 14),
      ]);
      final clip = tester.widget<ClipRect>(find.byWidgetPredicate((w) => w is ClipRect && w.clipper != null));
      expect(clip.clipper!.getClip(const Size(100, 50)), const Rect.fromLTRB(-8, -8, 108, 58));
    });

    testWidgets('text on a background its color was not given on reads, in a light theme too', (tester) async {
      await _pump(
        tester,
        _inPost(
          '<div style="background: #222222"><p>深底默认字</p></div>'
          '<font color="#333333"><div style="background-color: #000000">外面给的颜色</div></font>'
          '<div style="background: #112233"><a href="forum.php?mod=viewthread&amp;tid=1">深底链接</a></div>'
          '<div style="background: #222222"><font color="#444444">块里给的颜色</font></div>',
        ),
      );
      for (final (text, block) in [('深底默认字', 0xFF222222), ('外面给的颜色', 0xFF000000), ('深底链接', 0xFF112233)]) {
        expect(
          contrastRatio(_style(tester, text).color!, Color(block)),
          greaterThanOrEqualTo(readableContrast),
          reason: text,
        );
      }
      expect(_style(tester, '块里给的颜色').color, const Color(0xFF444444), reason: "the author's, as the web page");
      // The background of a piece of text goes with its color, whichever is around the other.
      await _pump(
        tester,
        _inPost(
          '<font color="white"><font style="background-color: orange">橙底白字</font></font>'
          '<span style="background-color: #000"><font color="#000">黑底黑字</font></span>',
        ),
      );
      expect(_style(tester, '橙底白字').color, const Color(0xFFFFFFFF));
      expect(_style(tester, '黑底黑字').color, const Color(0xFF000000));
    });

    testWidgets('headings, items, lists, terms, quotes and preformatted text have their background', (tester) async {
      await _pump(
        tester,
        _inPost(
          '<h2 style="background: #cc0000; color: #fff">红底标题</h2>'
          '<ul style="background: #ffe0b3"><li>清单</li><li style="background: #333333; color: #fff">深底条目</li></ul>'
          '<dl><dt style="background: pink">名词</dt><dd style="background: wheat">解释</dd></dl>'
          '<blockquote style="background: #000; color: #fff">黑底引言</blockquote>'
          '<pre style="background: #eeeeee">预排</pre>',
        ),
      );
      expect(_blockBackground(tester, '红底标题'), const Color(0xFFCC0000));
      expect(_blockBackground(tester, '深底条目'), const Color(0xFF333333));
      expect(_blockBackground(tester, '清单'), const Color(0xFFFFE0B3));
      expect(_blockBackground(tester, '名词'), const Color(0xFFFFC0CB));
      expect(_blockBackground(tester, '解释'), const Color(0xFFF5DEB3));
      expect(_blockBackground(tester, '黑底引言'), const Color(0xFF000000));
      expect(_blockBackground(tester, '预排'), const Color(0xFFEEEEEE));
      final mark = _spans(tester).firstWhere((e) => e.$1.text == '•  ' && (e.$2.color == const Color(0xFFFFFFFF)));
      expect(mark.$2.color, const Color(0xFFFFFFFF), reason: "the mark in the item's color, on its background");
    });

    testWidgets('dark: colored text on a gray of its lightness is seen, a white answer hidden', (tester) async {
      await _pump(
        tester,
        _inPost(
          '<table><tr><td bgcolor="#808080"><font color="red">红字灰底</font></td><td>x</td></tr>'
          '<tr><td bgcolor="silver"><font color="orange">橙字银底</font></td><td>y</td></tr></table>'
          '答案是：<font color="#ffffff">白字答案</font>'
          '<div style="background: #fff"><font color="#fefefe">白块白字</font></div>'
          '<span style="background-color: #000; color: #000">黑底黑字</span>',
        ),
        theme: _dark,
      );
      final surface = _dark.colorScheme.surfaceContainerLow;
      for (final text in ['红字灰底', '橙字银底']) {
        final block = _blockBackground(tester, text)!;
        expect(contrastRatio(_style(tester, text).color!, block), greaterThanOrEqualTo(readableContrast), reason: text);
      }
      expect(_style(tester, '白字答案').color, surface, reason: 'hidden on the page as on the web page');
      expect(_style(tester, '白块白字').color, surface, reason: 'the same in a block painted white');
      final black = _style(tester, '黑底黑字');
      expect(contrastRatio(black.color!, black.backgroundColor!), lessThan(camouflageContrast));
      expect(isCamouflaged(const Color(0xFFFF0000), const Color(0xFF808080)), isFalse);
      expect(isCamouflaged(const Color(0xFF7F7F7F), const Color(0xFF808080)), isTrue);
    });

    testWidgets('light: a white answer stays as given', (tester) async {
      await _pump(tester, _inPost('答案是：<font color="#ffffff">白字答案</font>'));
      expect(_style(tester, '白字答案').color, const Color(0xFFFFFFFF));
    });

    testWidgets('a block with a background in a centered block is centered too', (tester) async {
      for (final (html, text) in [
        ('<div align="center"><div style="background-color: pink">居中粉底</div></div>', '居中粉底'),
        ('<center><table bgcolor="wheat"><tr><td>居中麦底</td></tr></table></center>', '居中麦底'),
        ('<table style="text-align: center"><tr><td>表格置中</td><td>二</td></tr></table>', '表格置中'),
      ]) {
        await _pump(tester, _inPost(html));
        expect(_richText(tester, text).textAlign, TextAlign.center, reason: html);
      }
      // The cells of a table in a centered block stay aligned left, as on the web page.
      await _pump(tester, _inPost('<div align="center"><table><tr><td>块里的表格</td><td>二</td></tr></table></div>'));
      expect(_richText(tester, '块里的表格').textAlign, isNot(TextAlign.center));
    });

    testWidgets('justified paragraphs keep their paragraph spacing; tiny text is hidden', (tester) async {
      final long = List.filled(20, '这是一段很长的小说文字').join();
      await _pump(tester, _inPost(List.filled(3, '<p style="text-align: justify">$long</p>').join()));
      expect(find.byType(RichText), findsOneWidget);
      await _pump(
        tester,
        _inPost(
          '正文<span style="font-size: 0">零号字</span><span style="font-size: 1px">一像素</span><b style="font-size: 0.05em">小</b>',
        ),
      );
      expect(find.textContaining('零号字', findRichText: true), findsNothing);
      expect(find.textContaining('一像素', findRichText: true), findsNothing);
      expect(find.textContaining('正文', findRichText: true), findsOneWidget);
    });

    testWidgets('one-cell tables: the cell over the table; nested blocks are not narrowed again and again', (
      tester,
    ) async {
      await _pump(tester, _inPost('<table bgcolor="wheat"><tr><td bgcolor="pink">格子胜过表格</td></tr></table>'));
      expect(_blockBackground(tester, '格子胜过表格'), const Color(0xFFFFC0CB));
      await _pump(
        tester,
        _inPost(
          '<div style="background: #ffe0b3"><div style="background: pink"><div style="background: wheat">三层</div></div></div>',
        ),
      );
      final paddings = find
          .byType(PostBlockBackground)
          .evaluate()
          .map((e) => (e.widget as PostBlockBackground).padding)
          .toList();
      expect(paddings, [
        PostBlockBackground.defaultPadding,
        PostBlockBackground.nestedPadding,
        PostBlockBackground.nestedPadding,
      ]);
    });

    testWidgets('font-size 0 hides the text of the element, not what has a size of its own, nor images', (
      tester,
    ) async {
      String text() => find.byType(RichText).evaluate().map((e) => (e.widget as RichText).text.toPlainText()).join('|');
      // Inline blocks without the white space between them: the parent at 0, the children sized.
      await _pump(
        tester,
        _inPost(
          '前<div style="font-size:0"><span style="font-size:14px">子一</span> '
          '<span style="font-size:14px">子二</span></div>后',
        ),
      );
      expect(text(), allOf(contains('子一'), contains('子二'), isNot(contains('子一 子二'))));
      expect(_style(tester, '子一').fontSize, 14);
      // The same with class rules.
      await _pump(
        tester,
        _inPost(
          '<style>.row{font-size:0}.row .cell{font-size:16px}</style>'
          '前<div class="row"><span class="cell">格一</span><span class="cell">格二</span></div>后',
        ),
      );
      expect(text(), allOf(contains('格一'), contains('格二')));
      expect(_style(tester, '格一').fontSize, 16);
      // An image link whose text is hidden: the image shows (the spans are read without building the image, which
      // needs the image cache).
      Future<int> images(String html) async {
        var count = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: PostTypographyScope(
              typography: const PostTypography(),
              child: Builder(
                builder: (context) {
                  final rendered = munchElement(context, parseHtmlDocument(_inPost(html)).body!);
                  ((rendered as ConstrainedBox).child! as Text).textSpan!.visitChildren((span) {
                    if (span is WidgetSpan && span.child is GestureDetector) {
                      count++;
                    }
                    return true;
                  });
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        return count;
      }

      const image = '<img src="https://example.com/a.png" width="10" height="10">';
      expect(await images('前<a href="forum.php?mod=viewthread&amp;tid=1" style="font-size:0">$image</a>后'), 1);
      expect(await images('前<a href="forum.php?mod=viewthread&amp;tid=1">$image</a>后'), 1);
      // Text of its own at 0, and what is relative to it: hidden.
      await _pump(tester, _inPost('前<span style="font-size:0">干扰码<b style="font-size:2em">相对</b></span>后'));
      expect(text(), allOf(contains('前'), contains('后'), isNot(contains('干扰码')), isNot(contains('相对'))));
    });

    testWidgets('a forum link without its scheme has no mark', (tester) async {
      expect(postLinkHasMark('//www.tsdm39.com/forum.php?mod=viewthread&tid=1'), isFalse);
      expect(postLinkHasMark('//example.com/'), isTrue);
    });
  });
}
