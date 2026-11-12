/// A list in a list of a post starts further in, a step a level, as the web page indents each list in a post
/// (`.t_f ul { margin-left: 14px }`, `.t_f li { margin-left: 2em }`).
///
/// Before, the items of every level started at the same place: `[list][*]a[list][*]b[/list][/list]` read as two items
/// of one list. The outermost list stays where the text is, as before; an item of a nested list starts its first
/// line with a gap of two of its text sizes a level (a line of the text that wraps goes back to the start).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// The text [html] renders to, and the widths of the gaps put in its outermost rich text.
Future<(String, List<double>)> _render(WidgetTester tester, String html) async {
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
  final rich = find.byType(RichText).first;
  final text = (rich.evaluate().first.widget as RichText).text.toPlainText(includeSemanticsLabels: false);
  final gaps = find
      .descendant(of: rich, matching: find.byType(SizedBox))
      .evaluate()
      .map((e) => (e.widget as SizedBox).width)
      .whereType<double>()
      .where((e) => e > 0)
      .toList();
  return (text, gaps);
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  testWidgets('a list not in a list starts where the text is, as before', (tester) async {
    final (text, gaps) = await _render(tester, '<ul><li>a</li><li>b</li></ul>');
    expect(text, contains('•  a'));
    expect(text, contains('•  b'));
    expect(gaps, isEmpty);
  });

  testWidgets('each level of lists in a list starts a step further in', (tester) async {
    final (text, gaps) = await _render(
      tester,
      '<ul><li>a<ul><li>b<ul class="litype_1"><li>c</li></ul></li><li>d</li></ul></li><li>e</li></ul>',
    );
    // The marks and the text are as before, each item on a line of its own.
    final lines = text.split('\n').map((e) => e.replaceAll('￼', '')).where((e) => e.isNotEmpty).toList();
    expect(lines, ['•  a', '•  b', '1. c', '•  d', '•  e']);
    // b and d one step in, c two steps in; a and e none.
    expect(gaps, hasLength(3));
    final step = gaps.reduce((a, b) => a < b ? a : b);
    expect(step, greaterThan(0));
    expect(gaps, [step, step * 2, step]);
  });

  testWidgets('an <ol> in a list: no mark, the step all the same', (tester) async {
    final (text, gaps) = await _render(tester, '<ul class="litype_1"><li>a<ol><li>b</li></ol></li></ul>');
    expect(text.replaceAll('￼', ''), contains('1. a\nb'));
    expect(gaps, hasLength(1));
  });
}
