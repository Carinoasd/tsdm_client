import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  testWidgets('moderation notice is separated from the post body and centered', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: MunchedHtml(
                '<div>正文末尾<div class="modact">本主题由 管理团队 于 3 小时前 添加图章 置顶</div>后续内容</div>',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final notice = find.byWidgetPredicate((w) => w is Text && w.textSpan?.toPlainText() == '本主题由 管理团队 于 3 小时前 添加图章 置顶');
    expect(notice, findsOneWidget);
    expect(tester.widget<Text>(notice).textAlign, TextAlign.center);
    expect(find.byIcon(Icons.manage_history_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
