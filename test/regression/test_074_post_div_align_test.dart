import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// GitHub #47: `[align=center]` in a post is `<div align="center">` on the page, which the muncher rendered
/// left-aligned (only `<p align>` was aligned).
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  Future<void> pumpHtml(WidgetTester tester, String html) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SizedBox(width: 360, child: MunchedHtml(html))),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Rich texts carrying [align] whose content contains [text].
  Finder alignedText(TextAlign align, String text) => find.byWidgetPredicate(
    (w) => w is Text && w.textAlign == align && (w.textSpan?.toPlainText().contains(text) ?? false),
  );

  testWidgets('a real post: centered title, image and subtitle, left rules', (tester) async {
    // The image is dropped here: rendering it needs the image cache; it sits in the same aligned rich text as its
    // neighbours, so the alignment of the text proves the block's.
    final html = File('test/data/post_div_align_x5.html').readAsStringSync().replaceAll(RegExp('<img[^>]*>'), '');
    await pumpHtml(tester, html);

    expect(alignedText(TextAlign.center, '欢迎参与《葬送的芙莉莲》第二期活动'), findsOneWidget);
    expect(alignedText(TextAlign.center, '本期的主题是头也不回'), findsOneWidget);
    // The rules below the centered blocks keep the default alignment.
    expect(alignedText(TextAlign.center, '活动时间'), findsNothing);
    expect(alignedText(TextAlign.center, '请务必按照答题格式回答题目'), findsNothing);
    expect(find.textContaining('活动时间'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('div, p and center blocks align; the alignment does not leak out of the block', (tester) async {
    await pumpHtml(
      tester,
      [
        '<div align="right">右对齐</div>',
        '<p align="center">段落居中</p>',
        '<center>老式居中</center>',
        '<div align="center"><div>嵌套的<strong>内容</strong></div></div>',
        '后面的正文',
      ].join(),
    );
    expect(alignedText(TextAlign.right, '右对齐'), findsOneWidget);
    expect(alignedText(TextAlign.center, '段落居中'), findsOneWidget);
    expect(alignedText(TextAlign.center, '老式居中'), findsOneWidget);
    expect(alignedText(TextAlign.center, '嵌套的内容'), findsOneWidget);
    expect(alignedText(TextAlign.center, '后面的正文'), findsNothing);
    expect(alignedText(TextAlign.right, '后面的正文'), findsNothing);
    expect(find.textContaining('后面的正文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
