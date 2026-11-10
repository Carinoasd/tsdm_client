import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:universal_html/parsing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  testWidgets('the moderation notice of the first floor is a tappable block and prints once', (tester) async {
    const html =
        '<div class="modact"><a href="forum.php?mod=misc&amp;action=viewthreadmod&amp;tid=9202963">'
        '本主题由 管理团队 于 刚刚 设置高亮</a></div><p>body</p>';
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => munchElement(context, parseHtmlDocument(html).body!)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('设置高亮', findRichText: true), findsOneWidget);
    expect(find.byIcon(Icons.manage_history_outlined), findsOneWidget);
    expect(find.descendant(of: find.byType(Material), matching: find.byType(InkWell)), findsWidgets);
  });
}
