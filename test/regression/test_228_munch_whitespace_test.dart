/// The html muncher collapses white space where the web page does, and only there.
///
/// Before, every text node was trimmed at its start (and at both ends inside a table cell, which a post's content
/// is: the cell of a one-row table): the space between two words of which one is in an element was lost
/// (`<strong>A</strong> B` read "AB", `<a>here</a> to` "hereto", "@甲@乙" for two mentions, "我在2026-09-25完成签到"),
/// while a line break of the html source kept at the end of a text node broke the line where the web page shows a
/// space. A no-break space or an ideographic space at the start of a text node (a paragraph's indent) was dropped as
/// well, although HTML never collapses them.
///
/// HTML's rules (`white-space: normal`) are applied to the lines the muncher lays out: a run of spaces, tabs and line
/// breaks is one space, across elements; none at the start of a line (of the content, of a quote, a cell, a heading,
/// after a line break) nor at its end. `<pre>` is left as it is. A `<div>`, a `<p>` and a `<dd>`, blocks of the web
/// page, start a line of their own, and a paragraph's line ends with it (a `<br>` right after it took that break, so
/// `</p><br />` gave no blank line more than before; it is a blank line since, as on the web page, see test 229): the
/// line breaks the source's own line breaks gave by chance before (a text then a block, the fields of an activity
/// block) are now where the web page breaks the line.
///
/// Every real sample the repository holds (the post bodies, signatures and forum rules of the plugin's answers, the
/// post bodies, notices and private messages of the web pages under `test/data`) is rendered, and its text compared
/// with `test/data/munch_whitespace_x5.json`: the text the muncher gave before the fix, and the text it gives now
/// where they differ. For each sample that changed, the test also checks that nothing but white space changed and
/// that no blank line was added. The list of the differences and why the new text is the web page's is in the
/// change's description.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:universal_html/parsing.dart';

/// The recorded texts: `before` and `after` of a sample that changed, the one text of a sample that did not.
const _goldenPath = 'test/data/munch_whitespace_x5.json';

/// The texts a later fix changed (the content the web page shows, `test_229_render_content_test.dart`): `before`, the
/// text recorded here, and `after`, the text the muncher gives now.
const _laterGoldenPath = 'test/data/munch_render_content_x5.json';

/// The texts the style the author gave a post changed after that (`test_231_post_author_styles_test.dart`): `before`,
/// the text the fixes above give, and `after`, the text the muncher gives now.
const _styleGoldenPath = 'test/data/munch_author_styles_x5.json';

/// The texts the third phase changed after that (`test_233_post_tables_test.dart`): `before`, the text the style of
/// the author gives, and `after`, the text the muncher gives now.
const _tablesGoldenPath = 'test/data/munch_tables_x5.json';

/// Every real piece of html the app munches that the repository holds, by a name telling where it is from; the same
/// html once.
Map<String, String> _samples() {
  final samples = <String, String>{};
  final seen = <String>{};
  void add(String id, String html) {
    if (html.trim().isEmpty || !seen.add(html)) {
      return;
    }
    samples[id] = html;
  }

  final files = Directory('test/data').listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final path = file.path.replaceAll(r'\', '/');
    if (path.endsWith('.html')) {
      final raw = file.readAsStringSync();
      final document = parseHtmlDocument(raw);
      // Post bodies: the `div.pcb` the thread page munches, or a captured message cell.
      final bodies = document.querySelectorAll('div.pcb');
      if (bodies.isNotEmpty) {
        for (final (i, e) in bodies.indexed) {
          add('$path#pcb$i', e.innerHtml ?? '');
        }
      } else {
        final messages = document.querySelectorAll('[id^="postmessage_"]');
        for (final e in messages) {
          add('$path#${e.id}', e.outerHtml ?? '');
        }
        if (messages.isEmpty && raw.contains('postmessage_')) {
          // A bare `<td class="t_f">`: the parser drops the cell, the body holds its content.
          add('$path#body', document.body?.innerHtml ?? '');
        }
      }
      // Notices, private messages.
      for (final (i, e) in document.querySelectorAll('dd.ntc_body').indexed) {
        add('$path#notice$i', e.innerHtml ?? '');
      }
      for (final (i, e) in document.querySelectorAll('div.pmd, dd.ptm').indexed) {
        add('$path#pm$i', e.innerHtml ?? '');
      }
    } else if (path.endsWith('.json')) {
      final Object? json;
      try {
        json = jsonDecode(file.readAsStringSync());
      } on FormatException {
        continue;
      }
      if (json is! Map<String, dynamic> ||
          path == _goldenPath ||
          path == _laterGoldenPath ||
          path == _styleGoldenPath ||
          path == _tablesGoldenPath) {
        continue;
      }
      if (json['posts'] case final List<dynamic> posts) {
        for (final p in posts.whereType<Map<String, dynamic>>()) {
          final pid = p['pid'];
          if (p['body_html'] case final String body) {
            add('$path#$pid', body);
          }
          if (p['signature_html'] case final String signature) {
            add('$path#$pid/sig', signature);
          }
        }
      }
      if (json['forum'] case {'rules': final String rules}) {
        add('$path#rules', rules);
      }
      if (json['messages'] case final List<dynamic> messages) {
        for (final (i, m) in messages.whereType<Map<String, dynamic>>().indexed) {
          if (m['message_html'] case final String html) {
            add('$path#message$i', html);
          }
        }
      }
      if (json['user'] case {'signature_html': final String signature}) {
        add('$path#usersig', signature);
      }
      if (json['special'] case final Map<String, dynamic> special) {
        for (final key in ['affirmpoint_html', 'negapoint_html']) {
          if (special[key] case final String html) {
            add('$path#$key', html);
          }
        }
        if (special['result'] case {'umpirepoint_html': final String html}) {
          add('$path#umpirepoint', html);
        }
      }
    }
  }
  return samples;
}

/// [html] with each image in place of an underlined mark: an inline piece as an image is, without the image cache.
String _withoutImages(String html) => html.replaceAll(RegExp(r'<img\b[^>]*>', caseSensitive: false), '<u>[img]</u>');

/// Whether [text] is an icon's glyph (a private use character): the card's icons are no part of the content.
bool _isIcon(String text) =>
    text.runes.length == 1 &&
    ((text.runes.single >= 0xE000 && text.runes.single <= 0xF8FF) || text.runes.single >= 0xF0000);

/// An email address (the samples of the address protection have some): recorded as `<email>`.
final _email = RegExp(r'[\w.+-]+@[\w-]+(\.[\w-]+)+');

/// The text of everything [html] renders to, rich text by rich text in the tree's order, `«…»` each (a widget in
/// the text is U+FFFC, an email address `<email>`).
Future<String> _transcript(WidgetTester tester, String id, String html) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 400,
              child: KeyedSubtree(key: ValueKey(id), child: MunchedHtml(html)),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final error = tester.takeException();
  final buffer = StringBuffer();
  if (error != null) {
    buffer.writeln('!! ${error.runtimeType}');
  }
  for (final e in find.byType(RichText, skipOffstage: false).evaluate()) {
    final text = (e.widget as RichText).text.toPlainText(includeSemanticsLabels: false);
    if (!_isIcon(text)) {
      buffer.writeln('«${text.replaceAll(_email, '<email>')}»');
    }
  }
  return buffer.toString();
}

/// The text of the content [html] renders to (its outermost rich text).
Future<String> _text(WidgetTester tester, String html) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 400, child: MunchedHtml(html)),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
  return (find.byType(RichText).evaluate().first.widget as RichText).text.toPlainText(includeSemanticsLabels: false);
}

/// All white space, HTML's and Unicode's (a no-break space, an ideographic space).
final _anyWhiteSpace = RegExp(r'\s+');

/// The lines holding nothing but white space.
int _blankLines(String text) => RegExp('\n[  　]*(?=\n)').allMatches(text).length;

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('the rules', () {
    testWidgets('a space between an element and a word is kept', (tester) async {
      expect(await _text(tester, '<strong>A</strong> B'), 'A B');
      expect(await _text(tester, 'A <strong>B</strong>'), 'A B');
      expect(await _text(tester, 'see <a>here</a> to go'), 'see here to go');
      // A link's mark goes before it; the space before the link stays outside it, one only.
      expect(await _text(tester, 'see <a href="https://example.com/">here</a> to go'), 'see ￼here to go');
      expect(await _text(tester, 'a <a href="https://example.com/"> b</a>'), 'a ￼b');
      expect(
        await _text(
          tester,
          '<a href="home.php?mod=space&amp;uid=1">@甲</a> <a href="home.php?mod=space&amp;uid=2">@乙</a> 来看',
        ),
        '@甲 @乙 来看',
      );
    });

    testWidgets("a post's content, the cell of a one-row table: the same", (tester) async {
      const html =
          '<div class="t_fsz"><table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_1">\r\n'
          '我在 <font color="red">2026-09-25 01:06</font> 完成签到<br />\r\n'
          '<strong>粗體</strong> <font color="red">紅字</font> <font size="5">大字</font><br />\r\n'
          '</td></tr></table></div>';
      expect(await _text(tester, html), '我在 2026-09-25 01:06 完成签到\n粗體 紅字 大字');
    });

    testWidgets('a run of white space is one space, across elements; none at the start or end of a line', (
      tester,
    ) async {
      expect(await _text(tester, 'a  \r\n <b> b</b>\t c'), 'a b c');
      expect(await _text(tester, 'x<br />\r\n   next'), 'x\nnext');
      expect(await _text(tester, 'x \r\n<br />y'), 'x\ny');
      expect(await _text(tester, '\r\n  first'), 'first');
      // A line break of the source is a space, not a line break.
      expect(await _text(tester, 'one\r\ntwo'), 'one two');
    });

    testWidgets('a no-break space and an ideographic space are text; <pre> stays as written', (tester) async {
      expect(
        await _text(tester, 'x<br />\r\n&nbsp;&nbsp;段落一<br />\r\n　　段落二'),
        'x\n  段落一\n　　段落二',
      );
      expect(await _text(tester, '<pre>a  b\n c</pre>'), 'a  b\n c');
    });

    testWidgets('a quote, a heading, a list item and an aligned block start their lines', (tester) async {
      expect(await _text(tester, 'text <h2> 标题 </h2>'), 'text\n标题');
      expect(await _text(tester, '<ul>\r\n<li> 一</li>\r\n<li>二 </li>\r\n</ul>'), '•  一\n•  二');
      await _text(tester, 'before <div class="quote"><blockquote>  quoted  </blockquote></div> after');
      expect(find.text('quoted', findRichText: true), findsOneWidget);
      await _text(tester, 'before <div align="center">  centered  </div>');
      expect(find.text('centered', findRichText: true), findsOneWidget);
    });

    testWidgets('a block starts a line of its own; a paragraph ends its line', (
      tester,
    ) async {
      // The line break of the source before a block, or at the end of a paragraph, was a line break before: the
      // block's own line now, as on the web page.
      expect(await _text(tester, 'abc\r\n<div>block</div>tail'), 'abc\nblock\ntail');
      expect(await _text(tester, '<p>one\r\n</p><p>two\r\n</p>three'), 'one\ntwo\nthree');
      expect(await _text(tester, '<p>one</p>\r\n<p>two</p>'), 'one\ntwo');
      expect(await _text(tester, '<table><tr><td>abc\r\n<div>block</div>tail</td></tr></table>'), 'abc\nblock\ntail');
      // `[p]` then a line: no blank line more than before then. The `<br>` right after the paragraph is a blank line
      // since, as on the web page (test 229).
      expect(await _text(tester, '<p>one</p><br />\r\n<br />\r\ntwo'), 'one\n\n\ntwo');
      expect(await _text(tester, 'x<br />\r\n<div>block</div><br />\r\ny'), 'x\nblock\n\ny');
      // After a paragraph: a link (its mark), a list item (its mark) on a new line.
      expect(await _text(tester, '<p>one</p><a href="https://example.com/">link</a>'), 'one\n\uFFFClink');
      expect(await _text(tester, '<p>one</p><ul><li>item</li></ul>'), 'one\n•  item');
      // An empty paragraph changes nothing.
      expect(await _text(tester, 'text <p></p>after'), 'text after');
    });

    testWidgets('an empty link, in a quote or not, does not turn what follows into a link', (tester) async {
      Iterable<TextSpan> spans(InlineSpan span) sync* {
        if (span is TextSpan) {
          yield span;
          for (final child in span.children ?? const <InlineSpan>[]) {
            yield* spans(child);
          }
        }
      }

      expect(await _text(tester, 'x<a href="https://example.com/"> </a>y'), 'x y');
      for (final html in [
        '<a href="https://example.com/"></a>after',
        '<div class="quote"><blockquote>quoted<a href="https://example.com/"></a></blockquote></div>after',
      ]) {
        await _text(tester, html);
        final root = (find.byType(RichText).evaluate().first.widget as RichText).text;
        final after = spans(root).firstWhere((e) => e.text?.contains('after') ?? false);
        expect(after.recognizer, isNull, reason: html);
      }
    });

    testWidgets('<dd> ends its line', (tester) async {
      // The terms (`<dt>`) were dropped then; they are shown since, each before its definition (test 229).
      expect(
        await _text(tester, '<dl>\r\n<dt>类型:</dt>\r\n<dd>活动</dd>\r\n<dt>地点:</dt>\r\n<dd>\r\n某地\r\n</dd>\r\n</dl>'),
        '类型: 活动\n地点: 某地',
      );
    });
  });

  testWidgets('the real samples: what changed, and nothing else', (tester) async {
    final samples = _samples();
    final dump = Platform.environment['MUNCH_WHITESPACE_DUMP'];
    if (dump != null) {
      // Recording: the texts of every sample with the muncher of this tree.
      final texts = <String, String>{};
      for (final MapEntry(key: id, value: html) in samples.entries) {
        texts[id] = await _transcript(tester, id, _withoutImages(html));
      }
      File(dump).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(texts));
      return;
    }

    final golden =
        (jsonDecode(File(_goldenPath).readAsStringSync()) as Map<String, dynamic>)['samples'] as Map<String, dynamic>;
    final later =
        (jsonDecode(File(_laterGoldenPath).readAsStringSync()) as Map<String, dynamic>)['samples']
            as Map<String, dynamic>;
    final styled =
        (jsonDecode(File(_styleGoldenPath).readAsStringSync()) as Map<String, dynamic>)['samples']
            as Map<String, dynamic>;
    final tables =
        (jsonDecode(File(_tablesGoldenPath).readAsStringSync()) as Map<String, dynamic>)['samples']
            as Map<String, dynamic>;
    expect(samples.keys.toSet(), golden.keys.toSet(), reason: 'a sample added or gone: record the texts again');
    expect(samples.length, greaterThanOrEqualTo(250));
    var changed = 0;
    for (final MapEntry(key: id, value: html) in samples.entries) {
      final text = await _transcript(tester, id, _withoutImages(html));
      // The text a later fix changed: it starts from the text recorded here; the style of the author, from that.
      final laterFix = later[id] as Map<String, dynamic>?;
      final styleFix = styled[id] as Map<String, dynamic>?;
      final tablesFix = tables[id] as Map<String, dynamic>?;
      String now(String recorded) {
        var text = recorded;
        if (laterFix != null) {
          expect(laterFix['before'], text, reason: '$id: the later fix starts from the text recorded here');
          text = laterFix['after'] as String;
        }
        if (styleFix != null) {
          expect(styleFix['before'], text, reason: '$id: the style of the author starts from the text of the fixes');
          text = styleFix['after'] as String;
        }
        if (tablesFix != null) {
          expect(tablesFix['before'], text, reason: '$id: the third phase starts from the text of the style');
          text = tablesFix['after'] as String;
        }
        return text;
      }

      switch (golden[id]) {
        case final String same:
          expect(text, now(same), reason: '$id: did not change with the fix');
        case {'before': final String before, 'after': final String after}:
          changed++;
          expect(text, now(after), reason: id);
          expect(before, isNot(after), reason: id);
          expect(after.replaceAll(_anyWhiteSpace, ''), before.replaceAll(_anyWhiteSpace, ''), reason: '$id: text');
          expect(_blankLines(after), lessThanOrEqualTo(_blankLines(before)), reason: '$id: a blank line added');
        default:
          fail('$id: bad record');
      }
    }
    expect(changed, 63);
  });
}
