import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/thread/v1/utils/post_export.dart';
import 'package:tsdm_client/shared/models/models.dart';

String _md(String html) => postHtmlToText(html, format: PostExportFormat.markdown);
String _txt(String html) => postHtmlToText(html, format: PostExportFormat.plainText);
String _fixture(String name) => File('test/data/$name').readAsStringSync();

Post _post(int floor, String data, {String author = 'alice', bool hot = false, String? pid}) => Post(
  postID: pid ?? '${700000 + floor}',
  postFloor: hot ? null : floor,
  author: User(name: author, url: 'u'),
  publishTime: DateTime(2026, 10, 23, 8, 5),
  data: data,
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: 1,
  isDraft: false,
  packetAllTaken: false,
  hot: hot,
  hotFloor: hot ? floor : null,
);

void main() {
  group('inline markup', () {
    test('bold, italic, strike, code and links as Markdown', () {
      const html =
          '<b>bold</b> and <i>it</i> <s>gone</s> <code>x = 1</code> '
          '<a href="https://example.com/a_b">site</a>';
      expect(_md(html), '**bold** and *it* ~~gone~~ `x = 1` [site](https://example.com/a_b)');
    });

    test('plain text keeps the words and prints the link target', () {
      const html =
          '<b>bold</b> <a href="https://example.com/x">site</a> <a href="https://example.com/y">https://example.com/y</a>';
      expect(_txt(html), 'bold site (https://example.com/x) https://example.com/y');
    });

    test('nested emphasis is one pair, a space moved outside', () {
      expect(_md('<b><b>a</b> <i>b</i></b>'), '**a *b***');
      expect(_md('a<b> b </b>c'), 'a **b** c');
    });

    test('a relative link is made absolute, a script link is no link', () {
      final md = _md('<a href="forum.php?mod=viewthread&amp;tid=9">t</a><a href="javascript:void(0)">js</a>');
      expect(md, startsWith('[t](http'));
      expect(md, contains('forum.php?mod=viewthread&tid=9)'));
      expect(md, endsWith('js'));
    });

    test('markup characters in the text are escaped in Markdown only', () {
      expect(_md('2*3 = a_b and _x_ [1]'), r'2\*3 = a_b and \_x\_ \[1\]');
      expect(_txt('2*3 = a_b'), '2*3 = a_b');
      expect(_md('- not a list<br># not a heading'), startsWith(r'\- not a list'));
      expect(_md('- not a list<br># not a heading'), contains(r'\# not a heading'));
    });

    test('white space collapses as on the page and a line break stays', () {
      expect(_txt('a  \n  b<br>\n  c'), 'a b\nc');
      expect(_md('a<br>b'), 'a  \nb');
    });
  });

  group('images and smileys', () {
    test('a smiley is its name', () {
      expect(_md('x<img src="static/image/smiley/a/1.gif" smilieid="3" alt=":lol:">'), 'x[lol]');
      expect(_txt('<img src="https://h.test/s/kiss.png" smilieid="4" alt="">'), '[kiss]');
      expect(_txt('<img smilieid="4" alt="">'), '[$exportSmileyFallback]');
    });

    test('a picture is an image in Markdown and a mark with its address in plain text', () {
      const html = '<img src="https://h.test/p.png" alt="">';
      expect(_md(html), '![](https://h.test/p.png)');
      expect(_txt(html), '$exportImageMark https://h.test/p.png');
    });

    test('the picture is wanted at full size and the link around it is dropped', () {
      const html =
          '<a href="https://h.test/big.png"><img src="https://h.test/s.png" zoomfile="https://h.test/big.png"></a>';
      expect(_md(html), '![](https://h.test/big.png)');
    });
  });

  group('blocks', () {
    test('quote, code, headings, rules', () {
      const html =
          '<div class="quote"><blockquote>said<br />more</blockquote></div>reply '
          '<h2>Title</h2><pre>a\n  b</pre><hr>end';
      expect(_md(html), '> said  \n> more\n\nreply\n\n## Title\n\n```\na\n  b\n```\n\n---\n\nend');
      expect(_txt(html), '> said\n> more\n\nreply\n\nTitle\n\n    a\n      b\n\n---\n\nend');
    });

    test('a code block of the forum is its lines, without the copy label', () {
      const html =
          '<div class="blockcode"><div id="code_1"><ol><li>int a = 1;<li>  b();</ol></div> '
          '<em onclick="copycode()">复制代码</em></div>';
      expect(_md(html), '```\nint a = 1;\n  b();\n```');
    });

    test('lists keep their order, numbers and nesting', () {
      const html = '<ul><li>a</li><li>b<ol><li>x</li><li>y</li></ol></li></ul>';
      expect(_md(html), '- a\n- b\n  1. x\n  2. y');
    });

    test('a table is a grid, a table of one cell is not', () {
      const grid =
          '<table><tr><th>h1</th><th>h2</th></tr><tr><td>a|b</td><td>c<br>d</td></tr><tr><td colspan="2">e</td></tr></table>';
      expect(_md(grid), '| h1 | h2 |\n| --- | --- |\n| a\\|b | c<br>d |\n| e |  |');
      expect(_txt(grid), 'h1 | h2\na|b | c d\ne |');
      const wrapper = '<table><tr><td class="t_f">just text<br>here</td></tr></table>';
      expect(_txt(wrapper), 'just text\nhere');
    });
  });

  group('folds and hidden content', () {
    test('the spoiler of the forum, nested ones included, is marked and quoted', () {
      final md = _md(_fixture('spoiler_post_x5.html'));
      expect(md, contains('$exportFoldMark 测试折叠A\n> 内容A：这一行应该被折叠'));
      expect(md, contains('$exportFoldMark 测试折叠B\n> 内容B：这一行也应该被折叠'));
      expect(md, isNot(contains('点击展开')));
    });

    test('nested spoilers of a post', () {
      final txt = _txt(_fixture('render_regression/floors/h05-blocks.html'));
      expect(txt, contains('$exportFoldMark 体学向给\n> 来才强将干'));
      expect(txt, contains('> $exportFoldMark 她被体七\n> > 系性好平目'));
    });

    test('a fold the post made itself keeps its title and marks its content', () {
      final txt = _txt(_fixture('render_regression/floors/h05-blocks.html'));
      expect(txt, contains('想界前命这解外'));
      expect(txt, contains('$exportFoldMark\n> 以他低用口据具许被\n> 门质动'));
    });

    test('the content a reply unlocks is marked', () {
      expect(
        _txt('<div class="locked">本帖隐藏的内容需要回复才可以浏览</div>'),
        '$exportHiddenMark 本帖隐藏的内容需要回复才可以浏览',
      );
      expect(
        _md('<div class="showhide"><h4>本帖隐藏的内容</h4>secret</div>'),
        '$exportHiddenMark\n> #### 本帖隐藏的内容\n>\n> secret',
      );
    });

    test('what the page does not show is not exported', () {
      expect(_txt('a<script>alert(1)</script><span style="display:none">x</span><font class="jammer">j</font>b'), 'ab');
      expect(_txt('<i class="pstatus"> 本帖最后由 a 于 2001-1-1 编辑 </i>body'), 'body');
    });
  });

  group('fixtures', () {
    final floors = Directory('test/data/render_regression/floors').listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    test('every floor of the render fixtures converts in both formats without markup left over', () {
      expect(floors, isNotEmpty);
      for (final f in floors) {
        final html = f.readAsStringSync();
        for (final format in PostExportFormat.values) {
          final text = postHtmlToText(html, format: format);
          expect(text, isNot(matches(RegExp(r'</?(div|table|tr|td|font|span)\b'))), reason: f.path);
          expect(text, isNot(matches(RegExp(r'^\n|\s$'))), reason: f.path);
        }
      }
    });

    test('a floor with images and links keeps both', () {
      final md = _md(_fixture('render_regression/floors/c005.html'));
      expect(md, contains('![](https://example.com/render/img-1-640x360.png)'));
      expect(md, contains('](https://www.gvqq93.net/'));
      expect(md, isNot(contains('本帖最后由')));
    });
  });

  group('whole thread', () {
    final posts = [
      _post(1, 'first <b>floor</b>', author: 'op_user'),
      _post(2, 'second', author: 'bob'),
      _post(2, 'second', author: 'bob', hot: true, pid: '700002'),
      _post(3, 'third<br>line'),
    ];

    test('Markdown has the title, the link and a heading with floor, author and time for each floor', () {
      final md = buildThreadExport(
        title: 'A *title*',
        posts: posts,
        format: PostExportFormat.markdown,
        url: 'https://h.test/t',
      );
      expect(
        md,
        '# A \\*title\\*\n\n<https://h.test/t>\n\n'
        '---\n\n## #1 · op_user · 2026-10-23 08:05\n\nfirst **floor**\n\n'
        '---\n\n## #2 · bob · 2026-10-23 08:05\n\nsecond\n\n'
        '---\n\n## #3 · alice · 2026-10-23 08:05\n\nthird  \nline\n',
      );
    });

    test('plain text has the same parts without markup', () {
      final txt = buildThreadExport(title: 'A title', posts: posts, format: PostExportFormat.plainText);
      final rule = '-' * 40;
      expect(
        txt,
        'A title\n\n$rule\n#1  op_user  2026-10-23 08:05\n\nfirst floor\n\n'
        '$rule\n#2  bob  2026-10-23 08:05\n\nsecond\n\n'
        '$rule\n#3  alice  2026-10-23 08:05\n\nthird\nline\n',
      );
    });

    test('a floor met twice, and the copy a hot reply makes, are written once', () {
      final txt = buildThreadExport(
        title: 't',
        posts: [...posts, ...posts],
        format: PostExportFormat.plainText,
      );
      expect('#2  bob'.allMatches(txt), hasLength(1));
      expect('#1  op_user'.allMatches(txt), hasLength(1));
    });

    test('file names are made of the title and the thread id', () {
      expect(threadExportFileName(title: 'Title', tid: '12', format: PostExportFormat.markdown), 'Title-12.md');
      expect(threadExportFileName(title: 'a/b:c*d?', tid: '12', format: PostExportFormat.plainText), 'a_b_c_d_-12.txt');
      expect(threadExportFileName(title: '  ... ', tid: '7', format: PostExportFormat.markdown), 'thread-7.md');
      expect(threadExportFileName(title: '字' * 100, tid: '7', format: PostExportFormat.markdown), '${'字' * 60}-7.md');
    });
  });
}
