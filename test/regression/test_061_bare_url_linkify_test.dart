import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:universal_html/parsing.dart';

/// GitHub #24: the reason of a rating notice carries a bare url ("拼图活动https://dwz.date/f4VY") that the forum
/// does not wrap in an anchor, so the app rendered it as plain text.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  List<TextSpan> spansOf(WidgetTester tester) {
    final rich = tester.widgetList<RichText>(find.byType(RichText));
    final out = <TextSpan>[];
    for (final r in rich) {
      r.text.visitChildren((span) {
        if (span is TextSpan) {
          out.add(span);
        }
        return true;
      });
    }
    return out;
  }

  Future<void> pump(WidgetTester tester, String html) async {
    final body = parseHtmlDocument('<html><body>$html</body></html>').body!;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(body: Builder(builder: (context) => munchElement(context, body))),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a bare url in plain text becomes a tappable span, the text around it stays plain', (tester) async {
    await pump(tester, '<div>理由: 拼图活动https://dwz.date/f4VY，谢谢</div>');
    final spans = spansOf(tester);
    final link = spans.where((s) => s.recognizer != null).toList();
    expect(link.map((s) => s.text), ['https://dwz.date/f4VY']);
    expect(link.single.style?.decoration, TextDecoration.underline);
    expect(spans.where((s) => s.recognizer == null).map((s) => s.text).join(), contains('拼图活动'));
    expect(spans.where((s) => s.recognizer == null).map((s) => s.text).join(), contains('，谢谢'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('trailing sentence punctuation is not part of the url', (tester) async {
    await pump(tester, '<div>see (https://example.com/a). done</div>');
    final link = spansOf(tester).where((s) => s.recognizer != null).map((s) => s.text).toList();
    expect(link, ['https://example.com/a']);
  });

  testWidgets('text inside an anchor keeps the anchor recognizer and is not split', (tester) async {
    await pump(tester, '<div><a href="https://example.com/x">open https://example.com/x now</a></div>');
    final spans = spansOf(tester).where((s) => s.recognizer != null).toList();
    expect(spans, hasLength(1));
    expect(spans.single.text, 'open https://example.com/x now');
    expect(spans.single.recognizer, isA<GestureRecognizer>());
  });

  testWidgets('text without a url is a single plain span', (tester) async {
    await pump(tester, '<div>没有网址的一句话</div>');
    final spans = spansOf(tester);
    expect(spans.where((s) => s.recognizer != null), isEmpty);
    expect(spans.map((s) => s.text).join(), contains('没有网址的一句话'));
  });
}
