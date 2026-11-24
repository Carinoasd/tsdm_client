/// The source line of a quote (who wrote it and when, a link to the post quoted) is the quote's meta line: not
/// underlined as the other links of a post are, in the html and the BBCode renderers.
///
/// 1. html: the forum's source line (`<blockquote><font size="2"><a href="…goto=findpost…">`) has no underline; a
///    findpost link the author put in the quoted text, a link in the quote and a link after it keep theirs, also
///    after a nested quote;
/// 2. BBCode: the findpost link of a quote has no underline; a link after the quote keeps its underline.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode_view.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:universal_html/parsing.dart';

const _source = 'forum.php?mod=redirect&amp;goto=findpost&amp;pid=1&amp;ptid=2';

/// The decoration of the text span holding [text] (the innermost one with a style).
TextDecoration? _decorationOf(WidgetTester tester, String text) {
  TextDecoration? found;
  var hits = 0;
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    void visit(InlineSpan span, TextStyle? inherited) {
      if (span is! TextSpan) {
        return;
      }
      final style = inherited?.merge(span.style) ?? span.style;
      if (span.text != null && span.text!.contains(text)) {
        found = style?.decoration;
        hits++;
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, style);
      }
    }

    visit(rich.text, null);
  }
  expect(hits, 1, reason: '"$text" shown once');
  return found;
}

bool _underlined(TextDecoration? d) => d != null && d.contains(TextDecoration.underline);

Widget _post(Widget child) => TranslationProvider(
  child: MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: Builder(
          builder: (context) =>
              PostTypographyScope(typography: const PostTypography().withLineWidth(360), child: child),
        ),
      ),
    ),
  ),
);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  testWidgets('1. html: the source line of a quote is not underlined, other links are', (tester) async {
    final html = [
      '<div class="quote"><blockquote><font size="2"><a href="$_source" target="_blank">',
      '<font color="#999999">Alice posted at 2026-11-24 10:15</font></a></font><br />',
      'quoted words <a href="$_source">findpost in the text</a> and <a href="forum.php?mod=viewthread&amp;tid=3">',
      'a thread in the quote</a>',
      '<div class="quote"><blockquote><font size="2"><a href="$_source"><font color="#999999">',
      'Bob posted at 2026-11-23 09:00</font></a></font><br />nested</blockquote></div>',
      '</blockquote></div><br />reply text <a href="forum.php?mod=viewthread&amp;tid=4">a thread after it</a>',
    ].join();
    final body = parseHtmlDocument('<html><body>$html</body></html>').body!;
    await tester.pumpWidget(_post(Builder(builder: (context) => munchElement(context, body))));
    await tester.pump();

    expect(_underlined(_decorationOf(tester, 'Alice posted at')), isFalse);
    expect(_underlined(_decorationOf(tester, 'Bob posted at')), isFalse, reason: 'nested quote');
    expect(_underlined(_decorationOf(tester, 'findpost in the text')), isTrue, reason: 'not the source line');
    expect(_underlined(_decorationOf(tester, 'a thread in the quote')), isTrue);
    expect(_underlined(_decorationOf(tester, 'a thread after it')), isTrue, reason: 'the quote depth is back to 0');
    expect(tester.takeException(), isNull);
  });

  testWidgets('2. BBCode: the findpost link of a quote is not underlined, a link after it is', (tester) async {
    const nodes = <BbNode>[
      BbQuote([
        BbLink('https://www.tsdm39.com/forum.php?mod=redirect&goto=findpost&pid=1&ptid=2', [
          BbText('Carol posted at 2026-11-22 08:00'),
        ]),
        BbText('\nquoted words'),
      ]),
      BbText('\nreply '),
      BbLink('https://www.tsdm39.com/forum.php?mod=viewthread&tid=5', [BbText('a thread after the quote')]),
    ];
    await tester.pumpWidget(_post(const PostBbcodeView(nodes)));
    await tester.pump();

    expect(_underlined(_decorationOf(tester, 'Carol posted at')), isFalse);
    expect(_underlined(_decorationOf(tester, 'a thread after the quote')), isTrue);
    expect(tester.takeException(), isNull);
  });
}
