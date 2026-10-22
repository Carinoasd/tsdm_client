/// Post content shows everything the web page shows, in the web page's paragraphs (the first phase of the post
/// display work, measured against the web page floor by floor).
///
/// What was wrong, and is checked here on small samples written after the real posts (names made up):
///
/// * a `<br />` right after `[hr]` only ended the rule's line: the blank line the web page shows there was lost;
/// * an empty paragraph (`<p><br /></p>`, the blank line between the paragraphs of a novel) was taken for the line
///   break before the paragraph, and the blank line was lost; so was the one of a `<br />` right after a paragraph;
/// * a line break at the end of a cell, of an aligned block, added an empty line; what followed the post's content
///   (the attachments) went on in its last line; a blank line went before every heading and moderation notice;
/// * an element the muncher did not know was dropped with everything in it: `<em>`, `<cite>`, `<small>`, `<s>`,
///   `<del>`, `<ruby>`, `<dt>`, `<h5>`, `<th>` outside a table…, and an `<ol>` without the class of `[list=1]`;
/// * a hidden section asking for more points than an int holds (`9999999999999999999`) was dropped;
/// * a table of one row was taken for a wrapper, its cells running together; `colspan` and `rowspan` moved the
///   cells after them into other columns; an aligned block (`[align=center]`) in a cell threw while the table worked
///   out its columns and the whole table was left blank;
/// * players other than netease music's (`<iframe>`, `<embed>`, `<audio>`, `<video>`) were dropped;
/// * a line break was put after every `<span>`, which broke sentences in two;
/// * the time of a comment (点评) was not shown, and its text was cut after three lines;
/// * `<span style="display:none">` (no space) was shown, and so was the forum's jammer text (`<font class="jammer">`,
///   white on the web page).
///
/// And from the review of the fix: an element the muncher fails on must not take the floor with it (a flash player's
/// flashvars written with javascript's `escape()`, `%u4E2D`, threw and the whole floor was a grey block); the folds a
/// post written in html makes itself (a hidden element shown by a click on another) are spoilers, not left hidden; a
/// button, a text box and a choice box show their text as on the web page.
library;

// HTML fixtures are split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/media_card.dart';
import 'package:tsdm_client/utils/html/post_table.dart';
import 'package:tsdm_client/utils/html/review_parser.dart';
import 'package:tsdm_client/widgets/card/lock_card/locked_card.dart';
import 'package:tsdm_client/widgets/card/review_card.dart';
import 'package:tsdm_client/widgets/card/spoiler_card.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:universal_html/parsing.dart';

/// The texts of the real samples the fix changed, see `test_228_munch_whitespace_test.dart`.
const _goldenPath = 'test/data/munch_render_content_x5.json';

/// A widget in the text (a rule, a card, an image).
const _obj = '￼';

Future<void> _pump(WidgetTester tester, String html, {double width = 400}) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: width, child: MunchedHtml(html)),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The text of the content [html] renders to (its outermost rich text).
Future<String> _text(WidgetTester tester, String html) async {
  await _pump(tester, html);
  expect(tester.takeException(), isNull);
  return (find.byType(RichText).evaluate().first.widget as RichText).text.toPlainText(includeSemanticsLabels: false);
}

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
TextStyle? _styleOf(WidgetTester tester, String text) {
  final root = (find.byType(RichText).evaluate().first.widget as RichText).text;
  return _spans(root).firstWhere((e) => e.text?.contains(text) ?? false).style;
}

/// The text of every cell of the table, by row and column: a place a cell spans beyond its first is empty.
List<List<String>> _cells(WidgetTester tester) {
  final table = tester.widget<PostTable>(find.byType(PostTable));
  final cells = table.children.cast<PostTableCell>();
  final columns = cells.fold(
    0,
    (count, cell) => count > cell.column + cell.columnSpan ? count : cell.column + cell.columnSpan,
  );
  final grid = [for (var y = 0; y < table.rowCount; y++) List.filled(columns, '')];
  for (final cell in cells) {
    grid[cell.row][cell.column] = switch (cell.child) {
      final Text text => text.textSpan?.toPlainText() ?? text.data ?? '',
      _ => '',
    };
  }
  return grid;
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('the rhythm of the paragraphs', () {
    testWidgets('a <br> after a rule is a blank line, as on the web page', (tester) async {
      expect(await _text(tester, '标题<br />\r\n<hr class="l" /><br />\r\n正文'), '标题\n$_obj\n\n正文');
      // Without a line break around it, the rule still has its own line.
      expect(await _text(tester, '一<hr class="l" />二'), '一\n$_obj\n二');
      expect(await _text(tester, '<p>一</p><hr class="l" />二'), '一\n$_obj\n二');
      // At the start of the post, the line break after it counts too.
      expect(await _text(tester, '<hr class="l" /><br />正文'), '$_obj\n\n正文');
      expect(find.byType(Divider), findsOneWidget);
    });

    testWidgets('an empty paragraph, a line break after a paragraph: a blank line', (tester) async {
      expect(await _text(tester, '<p>第一段</p><p><br></p><p>第二段</p>'), '第一段\n\n第二段');
      expect(
        await _text(tester, '甲<p style="line-height:30px;text-indent:2em;text-align:left"><br></p>乙'),
        '甲\n\n乙',
      );
      expect(await _text(tester, '甲<p><br><br></p>乙'), '甲\n\n\n乙');
      expect(await _text(tester, '甲<div><br /></div>乙'), '甲\n\n乙');
      // The line break inside an inline element at its start is the same.
      expect(await _text(tester, '甲<p><font color="red"><br>乙</font></p>'), '甲\n\n乙');
      // A paragraph after a line break: no blank line more than before.
      expect(await _text(tester, '甲<br /><p><br /></p>乙'), '甲\n\n乙');
      // A line break right after a paragraph is a blank line, as on the web page, after an aligned one too.
      expect(await _text(tester, '<p>one</p><br />\r\ntwo'), 'one\n\ntwo');
      expect(await _text(tester, '<p>one</p><br />\r\n<br />\r\ntwo'), 'one\n\n\ntwo');
      expect(await _text(tester, '<p align="center">one</p><br />two'), '$_obj\n\ntwo');
      expect(await _text(tester, '<center>one</center><br />two'), '$_obj\n\ntwo');
      expect(await _text(tester, '<p>one</p>two<p>three</p>'), 'one\ntwo\nthree');
    });

    testWidgets("what follows the post's content starts a line, without a blank line", (tester) async {
      const content =
          '<div class="t_fsz"><table cellspacing="0" cellpadding="0"><tr><td class="t_f">正文末尾</td></tr></table>';
      expect(
        await _text(
          tester,
          '$content<div class="attach_nopermission"><div><h3><strong>本帖子中包含更多资源</strong></h3></div></div></div>',
        ),
        '正文末尾\n本帖子中包含更多资源',
      );
      expect(
        await _text(tester, '$content<div class="modact"><a href="forum.php">本主题由 管理团队 于 昨天 下沉</a></div></div>'),
        '正文末尾\n$_obj',
      );
    });

    testWidgets('a <span> is inline: no line break after it', (tester) async {
      expect(await _text(tester, '甲<span>乙</span>丙'), '甲乙丙');
      expect(await _text(tester, '<span style="color: red">红</span>字<span style="font-size: 12px">小</span>'), '红字小');
      expect(await _text(tester, 'Alice 对 <span class="xi2">您</span> 说'), 'Alice 对 您 说');
    });
  });

  group('elements that were dropped', () {
    testWidgets('an element the muncher does not know shows its content', (tester) async {
      // On the forum `em` and `cite` are not italic (`em, cite, i { font-style: normal }`, only `.t_f i` is).
      expect(
        await _text(tester, '<em>强调</em>与<cite>引用</cite>和<label>标签</label><abbr>缩写</abbr><o:p>文档</o:p>'),
        '强调与引用和标签缩写文档',
      );
      expect(_styleOf(tester, '强调')?.fontStyle, isNot(FontStyle.italic));
      // A heading is a line of its own, a blank line before it only where the content had one.
      expect(await _text(tester, '<h5>五级</h5><h6>六级</h6>正文'), '五级\n六级\n正文');
      expect(await _text(tester, '前文<h5>五级</h5>正文'), '前文\n五级\n正文');
      expect(await _text(tester, '<section>一节</section><article>一篇</article>后'), '一节\n一篇\n后');
    });

    testWidgets('what the web page does not show stays hidden', (tester) async {
      expect(
        await _text(
          tester,
          '<style>.a { color: red; }</style>正文<script>var a = 1;</script><noembed>无插件</noembed>'
          '<noframes>无框架</noframes><form><input type="hidden" value="v" /><button>表单按钮</button>表单</form>'
          '<span style="display:none">干扰码</span><font class="jammer">: `+ d! q)</font>'
          '<em style="visibility:hidden">看不见</em><div hidden>隐藏</div>结尾',
        ),
        '正文结尾',
      );
    });

    testWidgets('a button, a text box and a choice box show their text, as on the web page', (tester) async {
      expect(
        await _text(
          tester,
          '按<button type="button"><b>提交</b></button>，写<textarea>第一行\n第二行</textarea>，'
          '选<select><option>甲</option><option selected>乙</option></select>，再选<select><option>丙</option></select>',
        ),
        '按提交，写第一行\n第二行，选乙，再选丙',
      );
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('a fold the post makes itself is a spoiler titled by what shows it', (tester) async {
      // A hidden element shown by a click on another (`getElementById`, `$`), as posts written in html make them.
      await _pump(
        tester,
        '<div onclick="obj=document.getElementById(\'game\').style; obj.display=(obj.display==\'none\')?\'block\':\'none\';">'
        '<a style="cursor:pointer;"><font size="+2">▼ 开始游戏</font></a></div>'
        '<div id="game" class="game" style="display:none;clear:both;">游戏内容<br />第二行</div>'
        '<div onclick="javascript:document.getElementById(\'c310\').style.display=\'\'"><button type="submit">'
        '<b>优秀合集曲包</b></button><span>（点击展开/合上）</span></div><div id="c310" style="display: none; ">曲包内容</div>'
        '<a href="javascript:;" onclick="\$(\'c311\').style.display=\'\'">第三个</a><div id="c311" style="display:none">'
        '第三个内容</div>后文',
      );
      expect(tester.takeException(), isNull);
      final cards = tester.widgetList<SpoilerCard>(find.byType(SpoilerCard)).toList();
      expect(cards.map((e) => e.title.toPlainText()), ['▼ 开始游戏', '优秀合集曲包（点击展开/合上）', '第三个']);
      expect(cards.first.content.toPlainText(), '游戏内容\n第二行');
      // The elements that showed them are their titles now, not shown again; the folds are closed.
      expect(find.textContaining('开始游戏', findRichText: true), findsOneWidget);
      expect(find.textContaining('游戏内容', findRichText: true), findsNothing);
      expect(find.textContaining('后文', findRichText: true), findsOneWidget);
      await tester.tap(find.byIcon(Icons.expand_more_outlined).first);
      await tester.pump();
      expect(find.textContaining('游戏内容', findRichText: true), findsOneWidget);

      // Hidden and no fold: no id (the jammer text), the forum's popups, nothing shows it.
      await _pump(
        tester,
        '前<span style="display:none">干扰</span><div class="tip tip_4" id="aimg_1_menu" style="display: none">提示</div>'
        '<span onclick="\$(\'aimg_1_menu\')">图</span><div id="lonely" style="display:none">没人显示</div>后',
      );
      expect(find.byType(SpoilerCard), findsNothing);
      expect((find.byType(RichText).evaluate().first.widget as RichText).text.toPlainText(), '前图后');
    });

    testWidgets('strike-through, small text', (tester) async {
      expect(await _text(tester, '<s>划掉</s><del>删除</del><strike>旧的</strike>新的'), '划掉删除旧的新的');
      for (final text in ['划掉', '删除', '旧的']) {
        expect(_styleOf(tester, text)?.decoration?.contains(TextDecoration.lineThrough), isTrue, reason: text);
      }
      expect(_styleOf(tester, '新的')?.decoration?.contains(TextDecoration.lineThrough), isNot(isTrue));

      expect(await _text(tester, '正文<small>小字</small>'), '正文小字');
      final body = _styleOf(tester, '正文')!.fontSize!;
      expect(_styleOf(tester, '小字')!.fontSize, closeTo(body * 5 / 6, 0.01));
    });

    testWidgets('an <ol> without a class is shown, without marks as on the web page', (tester) async {
      expect(
        await _text(tester, '规则：<ol>\r\n<li>只能占一层楼</li><br>\r\n<li>禁止<b>马甲</b></li></ol>以上'),
        '规则：\n只能占一层楼\n\n禁止马甲\n以上',
      );
      // `[list=1]`, `[list=a]`, `[list=A]` and `[list]` keep their marks.
      expect(await _text(tester, '<ul type="1" class="litype_1"><li>一<li>二</ul>'), '1. 一\n2. 二');
      expect(await _text(tester, '<ul type="a" class="litype_2"><li>一<li>二</ul>'), 'a. 一\nb. 二');
      expect(await _text(tester, '<ul type="A" class="litype_3"><li>一<li>二</ul>'), 'A. 一\nB. 二');
      expect(await _text(tester, '<ul><li>一<li>二</ul>'), '•  一\n•  二');
    });

    testWidgets('a term of a definition list goes before its definition', (tester) async {
      expect(
        await _text(
          tester,
          '<dl>\r\n<dt>活动类型:</dt>\r\n<dd><strong>测试活动</strong></dd>\r\n<dt>已报名人数:</dt>\r\n'
          '<dd>\r\n<em>3</em> 人\r\n</dd>\r\n<dt>备注:</dt>\r\n</dl>结尾',
        ),
        '活动类型: 测试活动\n已报名人数: 3 人\n备注:\n结尾',
      );
    });

    testWidgets('ruby: the base, its ruby text above it', (tester) async {
      expect(await _text(tester, '还有<ruby>一<rp>(</rp><rt>亿</rt><rp>)</rp></ruby>点点问题'), '还有$_obj点点问题');
      final column = tester.widget<Column>(
        find.ancestor(of: find.text('亿'), matching: find.byType(Column)).first,
      );
      expect(column.verticalDirection, VerticalDirection.up);
      // The base first (the reading order), laid out below its ruby text.
      final base = tester.getRect(find.text('一', findRichText: true).last);
      final ruby = tester.getRect(find.text('亿'));
      expect(ruby.bottom, lessThanOrEqualTo(base.top + 0.5));
      expect(find.text('(', findRichText: true), findsNothing);
      final rubySize = tester.widget<Text>(find.text('亿')).style!.fontSize!;
      expect(rubySize, closeTo(_styleOf(tester, '还有')!.fontSize! / 2, 0.01));
    });
  });

  group('an element the muncher fails on', () {
    tearDown(() => debugBeforeMunchElement = null);

    testWidgets('shows what it holds; the rest of the floor is there', (tester) async {
      for (final failing in ['strong', 'table', 'li', 'div']) {
        debugBeforeMunchElement = (e) {
          if (e.localName == failing) {
            throw ArgumentError('failing on <$failing>');
          }
        };
        await _pump(
          tester,
          '<p>开头</p><strong>粗体<i>斜体</i></strong><ul><li>项目</li></ul>'
          '<div class="quote"><blockquote>引用</blockquote></div><table><tr><td>格一</td><td>格二</td></tr></table>结尾',
        );
        expect(tester.takeException(), isNull, reason: failing);
        expect(find.byType(ErrorWidget), findsNothing, reason: failing);
        final all = find.byType(RichText).evaluate().map((e) => (e.widget as RichText).text.toPlainText()).join('|');
        for (final text in ['开头', '粗体', '斜体', '项目', '引用', '格一', '格二', '结尾']) {
          expect(all, contains(text), reason: '<$failing>: $text');
        }
      }
    });

    testWidgets("a flash player's flashvars that cannot be decoded", (tester) async {
      // Javascript's `escape()` (`%u4E2D`), a percent sign of its own (`50%off`), a broken escape (`%zz`): url
      // decoding threw, in the muncher, and the whole floor was a grey block.
      const post =
          '<div class="t_fsz"><table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_1">'
          '第一段<br /><embed src="http://a.example.com/dewplayer.swf" width="200" height="20" '
          'flashvars="son=http://a.example.com/%u4E2D%u6587.mp3&autostart=1" type="application/x-shockwave-flash">'
          '<br />最后一段</td></tr></table></div>';
      expect(await _text(tester, post), '第一段\n$_obj\n最后一段');
      PostMedia of(String html) => PostMedia.of(parseHtmlDocument(html).body!.children.first);
      expect(
        of('<embed src="http://a.example.com/p.swf" flashvars="son=http://a.example.com/%u4E2D%u6587.mp3">').url,
        Uri.parse('http://a.example.com/%E4%B8%AD%E6%96%87.mp3'),
      );
      expect(
        of('<object><param name="flashvars" value="file=http://a.example.com/50%off.mp3"></object>').url,
        Uri.parse('http://a.example.com/50%25off.mp3'),
      );
      // Not an address of its own: the player's.
      expect(
        of('<embed src="https://a.example.com/p.swf" flashvars="son=%zz">').url,
        Uri.parse('https://a.example.com/p.swf'),
      );
    });
  });

  group('hidden sections', () {
    testWidgets('more points than an int holds', (tester) async {
      const html = '<div class="locked">游客，本帖隐藏的内容需要积分高于 9999999999999999999 才可浏览，您当前积分为 0</div>后文';
      await _pump(tester, html);
      expect(tester.takeException(), isNull);
      final card = tester.widget<LockedCard>(find.byType(LockedCard));
      expect(card.locked.lockedWithPoints, isTrue);
      expect(card.locked.requiredPoints, BigInt.parse('9999999999999999999'));
      expect(find.textContaining('9999999999999999999'), findsOneWidget);
      expect(find.textContaining('后文', findRichText: true), findsOneWidget);

      final element = parseHtmlDocument(
        '<div class="locked">本帖隐藏的内容需要积分高于 99999999999999999999999999999 才可浏览，您当前积分为 -7692</div>',
      ).querySelector('div.locked')!;
      final locked = Locked.fromLockDivNode(element);
      expect(locked.requiredPoints, BigInt.parse('99999999999999999999999999999'));
      expect(locked.points, BigInt.from(-7692));
    });

    testWidgets('a notice of no known kind is shown as the forum wrote it', (tester) async {
      const html = '<div class="locked">本帖为密码帖 ，请输入密码 <input type="password" name="pw" /> <button>提交</button></div>';
      await _pump(tester, html);
      expect(tester.takeException(), isNull);
      final card = tester.widget<LockedCard>(find.byType(LockedCard));
      expect(card.locked.lockedWithUnknown, isTrue);
      expect(card.locked.unknownText, '本帖为密码帖 ，请输入密码');
      expect(find.text('本帖为密码帖 ，请输入密码'), findsOneWidget);
      // Read for the post card's own purchase locks, an unknown notice is not one.
      final element = parseHtmlDocument(html).querySelector('div.locked')!;
      expect(Locked.fromLockDivNode(element).isValid(), isFalse);
      expect(Locked.fromLockDivNode(element, allowUnknown: true).isValid(), isTrue);

      // What is not the notice: what is hidden, the controls of a form and their labels, the purchase button.
      String notice(String html) =>
          Locked.fromLockDivNode(parseHtmlDocument(html).querySelector('div.locked')!, allowUnknown: true).unknownText!;
      expect(
        notice(
          '<div class="locked">提示<noscript>NS</noscript><template>TPL</template><label>记住</label>'
          '<span style="visibility:hidden">隐</span><span hidden>藏</span><select><option>项</option></select>文字</div>',
        ),
        '提示文字',
      );
      expect(
        notice(
          '<div class="locked"><a href="forum.php?mod=misc&amp;action=pay&amp;tid=1" class="viewpay">购买</a>'
          '本帖隐藏的内容需要支付 <strong>5 天使币</strong> 才可浏览</div>',
        ),
        '本帖隐藏的内容需要支付 5 天使币 才可浏览',
      );
    });
  });

  group('tables', () {
    testWidgets('a table of one row is a table; the wrapper around a post is not', (tester) async {
      await _pump(
        tester,
        '<table cellspacing="0" class="t_table" style="width:98%"><tr><td><strong>系列原图</strong></td>'
        '<td> 系列代码</td><th>传送装置</th></tr></table>',
      );
      expect(tester.takeException(), isNull);
      expect(_cells(tester), [
        ['系列原图', '系列代码', '传送装置'],
      ]);
      expect(
        await _text(tester, '<table cellspacing="0" cellpadding="0"><tr><td class="t_f">正文</td></tr></table>'),
        '正文',
      );
      expect(find.byType(PostTable), findsNothing);
      // A caption is a line above its table.
      await _pump(tester, '<table><caption>标题</caption><tr><td>甲</td><td>乙</td></tr></table>');
      expect(_cells(tester), [
        ['甲', '乙'],
      ]);
      expect(await _text(tester, '<table><caption>标题</caption><tr><td>甲</td><td>乙</td></tr></table>后'), '标题\n$_obj后');
      expect(await _text(tester, '<table><caption>标题</caption><tr><td>只一格</td></tr></table>后'), '标题\n只一格\n后');
    });

    testWidgets('a cell spanning columns or rows leaves the others in their columns', (tester) async {
      await _pump(
        tester,
        '<table><tr><td colspan="2">合并</td><td>C</td></tr><tr><td>a</td><td>b</td><td>c</td></tr>'
        '<tr><td rowspan="2">左</td><td>右上</td><td>x</td></tr><tr><td>右下</td><td>y</td></tr></table>',
      );
      expect(tester.takeException(), isNull);
      expect(_cells(tester), [
        ['合并', '', 'C'],
        ['a', 'b', 'c'],
        ['左', '右上', 'x'],
        ['', '右下', 'y'],
      ]);
    });

    testWidgets('a line break at the end of a cell adds no empty line', (tester) async {
      await _pump(tester, '<table><tr><td>甲<br /></td><td><div>乙</div></td></tr><tr><td>丙</td><td>丁</td></tr></table>');
      expect(_cells(tester), [
        ['甲', '乙'],
        ['丙', '丁'],
      ]);
    });

    // The cell of a table is asked how tall its content is in an unbounded width while the table works out its
    // columns; in a spoiler (its header is a row) that reaches the cards in the spoiler. A card filling its width with
    // a row and an expanded child threw there, and the whole table was left blank (a real post: a quote in the
    // spoiler of an activity's rules, about 2400 characters gone).
    const inSpoiler = {
      'quote': '<div class="quote"><blockquote>引用的答题格式</blockquote></div>',
      'hidden section': '<div class="locked">游客，如果您要查看本帖隐藏内容请<a href="forum.php?mod=post">回复</a></div>',
      'code block': '<div class="blockcode"><div id="code_1"><ol><li>编号：</li><li>答案：</li></ol></div></div>',
      'spoiler':
          '<div class="spoiler"><div class="spoilerheader"><input type="button" class="spoilerbutton" '
          'value="内层" /></div><div class="spoilerbody" style="display: none;"><table><td>内层内容</td></table>'
          '</div></div>',
      'moderation notice': '<div class="modact"><a href="forum.php">本主题由 管理员 于 昨天 关闭</a></div>',
      'aligned block': '<div align="center">居中的标题</div>',
    };
    for (final MapEntry(key: name, value: card) in inSpoiler.entries) {
      testWidgets('in a spoiler in a cell, $name: the table is laid out, not left blank', (tester) async {
        await _pump(
          tester,
          '<table class="t_table"><tr><td>第一格<div class="spoiler"><div class="spoilerheader"><input type="button" '
          'class="spoilerbutton" value="作答格式" /></div><div class="spoilerbody" style="display: none;"><table><td>'
          '格式：$card结尾</td></table></div></div></td></tr><tr><td>第二格</td></tr></table>',
        );
        expect(tester.takeException(), isNull);
        while (find.byIcon(Icons.expand_more_outlined).evaluate().isNotEmpty) {
          await tester.tap(find.byIcon(Icons.expand_more_outlined).first);
          await tester.pump();
          expect(tester.takeException(), isNull, reason: name);
        }
        expect(find.byType(PostTableScrollView), findsOneWidget);
        expect(find.textContaining('结尾', findRichText: true), findsWidgets);
        expect(find.textContaining('第二格', findRichText: true), findsWidgets);
        expect(tester.getSize(find.byType(PostTable)).height, greaterThan(100));
      });
    }

    testWidgets('an aligned block in a cell keeps its alignment', (tester) async {
      await _pump(
        tester,
        '<table class="t_table"><tr><td><div align="center">居中的标题</div>正文</td></tr><tr><td>第二格</td></tr></table>',
      );
      expect(tester.takeException(), isNull);
      final centered = tester.widget<Text>(
        find.byWidgetPredicate((w) => w is Text && (w.textSpan?.toPlainText().contains('居中的标题') ?? false)),
      );
      expect(centered.textAlign, TextAlign.center);
    });
  });

  group('players', () {
    PostMedia mediaOf(String html) => PostMedia.of(parseHtmlDocument(html).body!.children.first);

    test('the site, the address, only http(s)', () {
      final bilibili = mediaOf(
        '<iframe style="width:640px;height:480px;" src="//player.bilibili.com/player.html?aid=1&page=1"></iframe>',
      );
      expect(bilibili.url.toString(), 'https://player.bilibili.com/player.html?aid=1&page=1');
      expect(bilibili.site, 'Bilibili');
      expect(bilibili.kind, PostMediaKind.video);

      final audio = mediaOf('<audio controls><source src="https://od.example.net/s/a.mp3">不支持</audio>');
      expect(audio.url.toString(), 'https://od.example.net/s/a.mp3');
      expect(audio.kind, PostMediaKind.audio);
      expect(audio.site, 'od.example.net');

      // A flash player of a sound file: the file, the player opens nowhere any more.
      final flash = mediaOf(
        '<embed type="application/x-shockwave-flash" src="https://www.example.com//img/dewplayer.swf" '
        'flashvars="son=https://media.example.org/song.mp3&autoplay=1">',
      );
      expect(flash.url.toString(), 'https://media.example.org/song.mp3');
      expect(flash.kind, PostMediaKind.audio);

      // A frame loaded later; a path on the forum; what a browser reads as `javascript:`.
      expect(
        mediaOf('<iframe src="about:blank" data-src="https://www.youtube.com/embed/x"></iframe>').url,
        Uri.parse('https://www.youtube.com/embed/x'),
      );
      expect(
        mediaOf('<iframe src="/plugin.php?id=x"></iframe>').url,
        Uri.parse('https://www.tsdm39.com/plugin.php?id=x'),
      );
      expect(mediaOf('<iframe src="java\tscript:alert(1)"></iframe>').url, isNull);
      expect(mediaOf('<iframe src="\u0001 javascript:alert(1)"></iframe>').url, isNull);

      final unsafe = mediaOf('<iframe src="javascript:alert(1)"></iframe>');
      expect(unsafe.url, isNull);
      expect(unsafe.site, isNull);
      expect(mediaOf('<video></video>').url, isNull);
    });

    test("the player of the forum's [media] and [flash], made by a script", () {
      final flash = PostMedia.ofScript(
        'detectPlayer("swf_u2n", "swf", "http://www.example.com/widget/1_2/multiPlayer.swf", "550", "400");',
      )!;
      expect(flash.url.toString(), 'http://www.example.com/widget/1_2/multiPlayer.swf');
      expect(flash.kind, PostMediaKind.video);
      expect(
        PostMedia.ofScript('detectPlayer("x", "mp3", "https://example.com/a.mp3", "400", "30");')!.kind,
        PostMediaKind.audio,
      );

      final video = PostMedia.ofScript(
        "document.getElementById('flv_NHr').innerHTML=(detectHtml5Support() ? \"<iframe "
        "src='https://player.youku.com/embed/XMjM4' border='0' scrolling='no'></iframe>\" : AC_FL_RunContent('width', "
        "'750', 'height', '600', 'src', 'https://player.youku.com/player.php/sid/XMjM4/v.swf', 'quality', 'high'));",
      )!;
      expect(video.url.toString(), 'https://player.youku.com/embed/XMjM4');
      expect(video.site, 'Youku');

      expect(PostMedia.ofScript("replyreload += ',' + 1;"), isNull);
      // A script of the post's own that only mentions the forum's function.
      expect(PostMedia.ofScript('var detectHtml5Support = 1; x("src", "https://evil.example.com/");'), isNull);
      // A player script whose address cannot be read: a player without one.
      expect(PostMedia.ofScript("document.write(AC_FL_RunContent('width', '550'));")?.url, isNull);
      expect(PostMedia.ofScript("document.write(AC_FL_RunContent('width', '550'));"), isNotNull);
      expect(PostMedia.ofScript('(function(){})();'), isNull);
    });

    testWidgets('a card in place of the player, the text inside the player not shown', (tester) async {
      expect(
        await _text(
          tester,
          '听歌<audio controls controlsList="nodownload"><source src="https://od.example.net/s/a.mp3">'
          '您的浏览器不支持该音频播放</audio><br />看片 <iframe src="//player.bilibili.com/player.html?aid=1"></iframe>',
        ),
        '听歌$_obj\n看片 $_obj',
      );
      expect(find.byType(PostMediaCard), findsNWidgets(2));
      expect(find.textContaining('影音：Bilibili', findRichText: true), findsOneWidget);
      expect(find.textContaining('影音：od.example.net', findRichText: true), findsOneWidget);
      expect(find.textContaining('不支持', findRichText: true), findsNothing);
      // Tappable only with an http(s) address.
      expect(find.descendant(of: find.byType(PostMediaCard), matching: find.byType(InkWell)), findsNWidgets(2));
      await _pump(tester, '<iframe src="javascript:alert(1)"></iframe>');
      expect(find.byType(PostMediaCard), findsOneWidget);
      expect(find.descendant(of: find.byType(PostMediaCard), matching: find.byType(InkWell)), findsNothing);

      // `[media]`: the player is made by a script on the web page.
      expect(
        await _text(
          tester,
          '1.PV<br /><ignore_js_op><span id="flv_NHr"></span><script type="text/javascript" reload="1">'
          "document.getElementById('flv_NHr').innerHTML=(detectHtml5Support() ? \"<iframe "
          "src='https://player.youku.com/embed/XMjM4'></iframe>\" : AC_FL_RunContent('src', 'https://x/v.swf'));"
          '</script></ignore_js_op><br />2.',
        ),
        '1.PV\n$_obj\n2.',
      );
      expect(find.textContaining('影音：Youku', findRichText: true), findsOneWidget);
      // `[flash]`: the script puts the player above the link to open it, in the place the forum leaves for it.
      expect(
        await _text(
          tester,
          '标题<br /><ignore_js_op><div id="swf_a" class="media"><div id="swf_a_container" class="media_container"></div>'
          '<div id="swf_a_tips" class="media_tips"><a href="http://www.example.com/p.swf" target="_blank">'
          '如果无法播放，请点击此处在新窗口打开</a></div></div><script type="text/javascript">'
          'detectPlayer("swf_a", "swf", "http://www.example.com/p.swf", "550", "400");</script></ignore_js_op>',
        ),
        '标题\n$_obj\n$_obj如果无法播放，请点击此处在新窗口打开',
      );
      expect(find.byType(PostMediaCard), findsOneWidget);
    });
  });

  group('comments', () {
    const html = '''
<div id="comment_1" class="cm">
<h3 class="psth xs1"><span class="icon_ring vm"></span>点评</h3>
<div class="pstl xs1 cl">
<div class="psta vm">
<a href="home.php?mod=space&amp;uid=2" c="1"><img data-src="https://example.com/a.gif" class="_avt user_avatar"></a>
<a href="home.php?mod=space&amp;uid=2" class="xi2 xw1">某版主</a>
</div>
<div class="psti">
第一行很长的点评。第二句。第三句。第四句。第五句。第六句。第七句。第八句。第九句。第十句。第十一句。第十二句。第十三句。第十四句。第十五句。第十六句。第十七句。第十八句。第十九句。第二十句。&nbsp;
<span class="xg1">
发表于 2021-10-1 18:04</span>
</div>
</div>
</div>''';

    test('the time is read as the web page prints it', () {
      final review = parseReviewElement(parseHtmlDocument(html).querySelector('div.pstl')!);
      expect(review.name, '某版主');
      expect(review.time, '发表于 2021-10-1 18:04');
      expect(review.content, startsWith('第一行很长的点评。'));
      expect(review.content, isNot(contains('发表于')));
    });

    testWidgets('the card shows the time and all of the text', (tester) async {
      // Laid out, not painted: the avatar is not loaded.
      await tester.pumpWidget(
        TranslationProvider(
          child: const MaterialApp(
            home: Scaffold(
              body: Offstage(child: SizedBox(width: 300, child: MunchedHtml(html))),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ReviewCard, skipOffstage: false), findsOneWidget);
      expect(find.text('发表于 2021-10-1 18:04', skipOffstage: false), findsOneWidget);
      final content = tester.widget<Text>(find.textContaining('第二十句', skipOffstage: false));
      expect(content.maxLines, isNull);
      expect(content.overflow, isNull);
    });
  });

  test('the real samples: nothing the fix changed lost any text, but what the web page hides', () {
    final samples =
        (jsonDecode(File(_goldenPath).readAsStringSync()) as Map<String, dynamic>)['samples'] as Map<String, dynamic>;
    // The text of a sample without white space, the marks of the rich texts in the record and widgets.
    String letters(String text) => text.replaceAll(RegExp('[\\s«»@$_obj]+'), '');
    bool inOrder(String part, String whole) {
      final letters = whole.runes.toList();
      var i = 0;
      for (final ch in part.runes) {
        while (i < letters.length && letters[i] != ch) {
          i++;
        }
        if (i == letters.length) {
          return false;
        }
        i++;
      }
      return true;
    }

    // What the web page hides (`<span style="display:none">`, written without the space), which was shown.
    const hidden = {
      'test/data/tsdmapp/thread_v14_jammer.json#4990': ['4 D" e* B9 w\$ ~\u00a0\u00a0e0 @4 T2 n'],
      'test/data/tsdmapp/thread_v14_jammer.json#4997': [
        '+ u% a% T& h" M* P',
        ': `+ d! q) S( ^6 @( ]2 B',
        '; Q; Q" z9 h/ m\' @2 J9 g, i',
      ],
    };
    for (final MapEntry(key: id, value: record) in samples.entries) {
      final {'before': String before, 'after': String after} = record as Map<String, dynamic>;
      expect(before, isNot(after), reason: id);
      var expected = before;
      for (final text in hidden[id] ?? const <String>[]) {
        expect(expected, contains(text), reason: id);
        expected = expected.replaceFirst(text, '');
      }
      expect(inOrder(letters(expected), letters(after)), isTrue, reason: '$id: text lost');
    }
    expect(samples.length, 45);
  });
}
