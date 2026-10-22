/// The experimental bbcode renderer (「用 App 渲染器显示帖子（实验）」, off by default) against the web page, where the
/// render audit of 851 floors of the forum found it apart:
///
/// * the text of a long `[url]X[/url]`: the forum cuts the url it has escaped for html, in bytes, so a cut in the
///   middle of `&amp;` shows `amp;` on the web page (`rum.php ... amp;fromuid=1202448`);
/// * the empty lines of a block: the forum's spoiler keeps the line break after its head (an empty first line), the
///   web page does not show the line break a block (`[align]`, `[spoiler]`) ends with;
/// * links: underlined in a post as on the web page, in their own color (not a `[color]` around them), a mark only
///   before a link out of the forum or an email address.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode_view.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';

/// The floor of `thread_v14_plain.json` (its html has the message cell) with the bbcode [message].
List<BbNode> _nodes(String message) {
  final json = jsonDecode(File('test/data/tsdmapp/thread_v14_plain.json').readAsStringSync()) as Map<String, dynamic>;
  (json['posts'] as List).cast<Map<String, dynamic>>().first
    ..['message'] = message
    ..['bbcodeoff'] = 0
    ..['smileyoff'] = 1
    ..['attachments'] = const <Object>[]
    ..['customtags'] = const ['spoiler'];
  final decision = decidePostBbcode(threadPageFromApi(json, 1).postList.single);
  expect(decision, isA<PostBbcodeRender>(), reason: '$decision');
  return (decision as PostBbcodeRender).nodes;
}

String _plain(List<BbNode> nodes) => nodes.map((e) => e is BbText ? e.text : '').join();

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('the text of a long [url]X[/url], as the forum cuts it', () {
    test('cut in its escapes: what is left of one is text, the link goes to the url as written', () {
      const url = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1092066&&fromuid=1202448';
      final link = _nodes('[url]$url[/url]').single as BbLink;
      expect(link.href, url);
      // `…&amp;&amp;fromuid=1202448`: its last 19 bytes start inside the second `&amp;`.
      expect(_plain(link.children), 'https://www.tsdm39.com/forum.php ... amp;fromuid=1202448');

      // The escapes count: 61 characters, 69 bytes escaped, cut.
      const near = 'https://example.com/forum.php?mod=viewthread&tid=12345&page=1';
      expect(near.length, lessThanOrEqualTo(65));
      expect(_plain((_nodes('[url]$near[/url]').single as BbLink).children), contains(' ... '));
      // A short one stays as written.
      const short = 'https://example.com/?a=1&b=2';
      final shown = _nodes('[url]$short[/url]').single as BbLink;
      expect((shown.href, _plain(shown.children)), (short, short));
    });

    test('trimmed as PHP trims: a trailing U+3000 or no-break space stays; a quote goes as %22', () {
      final long = 'https://example.com/${'k' * 60}';
      for (final space in ['\u3000', '\u00a0']) {
        final link = _nodes('[url]$long$space[/url]').single as BbLink;
        expect(link.href, '$long$space');
        expect(_plain(link.children), endsWith('${'k' * (19 - utf8.encode(space).length)}$space'));
      }
      final quoted = _nodes('[url]https://example.com/"q"[/url]').single as BbLink;
      expect(quoted.href, 'https://example.com/%22q%22');
      expect(_plain(quoted.children), 'https://example.com/"q"');
    });

    test('cut in bytes: a character cut in its bytes is the replacement character', () {
      final url = 'https://example.com/${'中' * 30}';
      final link = _nodes('[url]$url[/url]').single as BbLink;
      expect(link.href, url);
      // 32 bytes: the 20 of the host and path, 4 characters; 19 bytes: 1 byte of a character, 6 characters.
      expect(_plain(link.children), 'https://example.com/中中中中 ... �中中中中中中');
    });
  });

  group('the empty lines of a block, as on the web page', () {
    test('a spoiler keeps the line break after its head and drops the one it ends with', () {
      final spoiler = _nodes('[spoiler=t]\r\na\r\n\r\n[/spoiler]').single as BbSpoiler;
      expect(_plain(spoiler.children), '\na\n');
      final tight = _nodes('[spoiler=t]a[/spoiler]').single as BbSpoiler;
      expect(_plain(tight.children), 'a');
    });

    test('an aligned block drops the line break it ends with; one with only that is an empty line', () {
      final nodes = _nodes('[align=center]a\r\n[/align][align=center]\r\n[/align][align=left]\r\nb\r\n\r\n[/align]');
      expect(nodes.whereType<BbAlign>().map((e) => _plain(e.children)), ['a', '\n', '\nb\n']);
    });

    test('a line break after a block in a block, or all a block holds, is kept: one empty line on the web page', () {
      String shape(BbNode node) => switch (node) {
        BbText(:final text) => jsonEncode(text),
        BbAlign(:final children) ||
        BbSpoiler(:final children) ||
        BbQuote(:final children) => '${node.runtimeType}[${children.map(shape).join(',')}]',
        _ => '${node.runtimeType}',
      };
      for (final (bbcode, expected) in [
        // The forum's quote takes the `\r` after it only: `</div><br /></div>`.
        ('[align=center][quote]q[/quote]\r\n[/align]', r'BbAlign[BbQuote["q"],"\n"]'),
        // Two: two empty lines.
        ('[align=center][quote]q[/quote]\r\n\r\n[/align]', r'BbAlign[BbQuote["q"],"\n\n"]'),
        ('[align=center]a[hr]\r\n[/align]', r'BbAlign["a",BbDivider,"\n"]'),
        ('[spoiler=t][code]x[/code]\r\n[/spoiler]', r'BbSpoiler[BbCodeBlock,"\n"]'),
        ('[align=center][align=right]a\r\n[/align]\r\n[/align]', r'BbAlign[BbAlign["a"],"\n"]'),
        ('[spoiler=t]\r\n[/spoiler]', r'BbSpoiler["\n"]'),
        ('[spoiler=t]\r\n\r\n[/spoiler]', r'BbSpoiler["\n\n"]'),
      ]) {
        expect(_nodes(bbcode).map(shape).join(','), expected, reason: bbcode);
      }
    });

    testWidgets('drawn as on the web page: one empty line for it, not two', (tester) async {
      Future<double> height(List<BbNode> nodes) async {
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: PostTypographyScope(typography: const PostTypography(), child: PostBbcodeView(nodes)),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        return tester.getSize(find.byType(PostBbcodeView)).height;
      }

      const quote = BbQuote([BbText('q')]);
      final line = await height(const [BbText('x\ny')]) - await height(const [BbText('x')]);
      expect(line, greaterThan(0));
      final quoteOnly = await height(const [
        BbAlign('center', [quote]),
      ]);
      expect(
        await height(const [
          BbAlign('center', [quote, BbText('\n')]),
        ]),
        quoteOnly + line,
      );
      expect(
        await height(const [
          BbAlign('center', [quote, BbText('\n\n')]),
        ]),
        quoteOnly + 2 * line,
        reason: 'two line breaks after a block: two empty lines',
      );
      expect(
        await height(const [
          BbAlign('center', [BbText('\n')]),
        ]),
        await height(const [
          BbAlign('center', [BbText('x')]),
        ]),
        reason: 'a block of a line break only: one line',
      );
      expect(
        await height(const [
          BbAlign('center', [BbText('\n\n')]),
        ]),
        await height(const [
          BbAlign('center', [BbText('x\ny')]),
        ]),
        reason: 'a block of two line breaks only: two lines',
      );
      final spoiler = _nodes('[spoiler=t]\r\n[/spoiler]').single as BbSpoiler;
      expect(_plain(spoiler.children), '\n', reason: 'one empty line in the spoiler, as the web page');
    });

    test('quotes and free blocks still lose their line breaks at both ends, as the forum takes them', () {
      final quote = _nodes('[quote]\r\n\r\nq\r\n\r\n[/quote]').single as BbQuote;
      expect(_plain(quote.children), 'q');
      final free = _nodes('[free]\r\nf\r\n[/free]').single as BbQuote;
      expect(_plain(free.children), 'f');
    });
  });

  group('links as on the web page', () {
    test('in their own color: a [color] around a link does not color it, one in it does', () {
      final around = _nodes('[color=red][url=https://example.com/]x[/url][/color]').single as BbLink;
      expect((around.children.single as BbText).style.color, isNull);
      final inside = _nodes('[url=https://example.com/][color=red]x[/color][/url]').single as BbLink;
      expect((inside.children.single as BbText).style.color, 'red');
      final bold = _nodes('[b][color=red][url=https://example.com/]x[/url][/color][/b]').single as BbLink;
      expect((bold.children.single as BbText).style.bold, isTrue, reason: 'only the color is the link own');
    });

    const links = [
      BbLink('https://www.tsdm39.com/forum.php?mod=viewthread&tid=1', [BbText('forum')]),
      BbText(' '),
      BbLink('http://tsdm39.com/forum.php', [BbText('bare host')]),
      BbText(' '),
      BbLink('//www.tsdm39.com/forum.php', [BbText('no scheme')]),
      BbText(' '),
      BbLink('forum.php?mod=forumdisplay&fid=2', [BbText('relative')]),
      BbText(' '),
      BbLink('https://example.com/', [BbText('out')]),
      BbText(' '),
      BbLink('mailto:a@example.com', [BbText('mail')]),
    ];

    Future<void> pump(WidgetTester tester, {required bool inPost}) async {
      const view = PostBbcodeView(links);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: inPost ? const PostTypographyScope(typography: PostTypography(), child: view) : view,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    TextStyle? styleOf(WidgetTester tester, String text) {
      TextStyle? found;
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        rich.text.visitChildren((span) {
          if (span is TextSpan && span.text == text) {
            found = span.style;
          }
          return found == null;
        });
      }
      return found;
    }

    testWidgets('in a post: underlined, a mark only before a link out of the forum or an address', (tester) async {
      await pump(tester, inPost: true);
      expect(find.byIcon(Icons.link), findsOneWidget, reason: 'only the link out of the forum');
      expect(find.byIcon(Icons.email_outlined), findsOneWidget);
      final context = tester.element(find.byType(PostBbcodeView));
      for (final text in ['forum', 'bare host', 'no scheme', 'relative', 'out', 'mail']) {
        final style = styleOf(tester, text);
        expect(style?.decoration, TextDecoration.underline, reason: text);
        expect(style?.color, Theme.of(context).colorScheme.primary, reason: text);
      }
    });

    testWidgets('outside a post: marks before every link, no underline, as before', (tester) async {
      await pump(tester, inPost: false);
      expect(find.byIcon(Icons.link), findsNWidgets(5));
      expect(find.byIcon(Icons.email_outlined), findsOneWidget);
      expect(styleOf(tester, 'forum')?.decoration, TextDecoration.none);
    });
  });
}
