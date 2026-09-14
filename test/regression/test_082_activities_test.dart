import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/activities/models/forum_activity.dart';
import 'package:tsdm_client/features/activities/view/activities_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

void main() {
  test('captured X5 activity description preserves order without subforums or moderators', () {
    final document = parseHtmlDocument(File('test/data/activities_home_x5.html').readAsStringSync());
    final before = document.documentElement?.outerHtml;
    final activities = parseForumActivities(document);
    expect(activities, hasLength(17));
    expect(activities.first.title, '生化危机');
    expect(activities.last.title, '帖子背景征集活动');
    expect(activities.first.url, contains('tid=906393'));
    expect(activities.any((a) => a.title == '宠物中心' || a.title == 'TR83'), isFalse);
    expect(document.documentElement?.outerHtml, before, reason: 'Shared homepage document must remain unchanged');
  });

  test('relative thread/forum/plugin links resolve; unsafe schemes are ignored', () {
    final result = parseForumActivities(
      parseHtmlDocument('''
      <table><tr><td><h2><a>活動專區</a></h2><p class="xg2">
      <a href="forum.php?mod=viewthread&amp;tid=1">Thread</a>
      <a href="/forum.php?mod=forumdisplay&amp;fid=2">Forum</a>
      <a href="plugin.php?id=pokemon:pokemon">Plugin</a>
      <a href="javascript:alert(1)">Unsafe</a><a href="https://user:pass@example.com">Unsafe</a>
      </p><p>版主: <a href="home.php?uid=1">Excluded</a></p></td></tr></table>
    '''),
    );
    expect(result.map((a) => a.title), ['Thread', 'Forum', 'Plugin']);
    expect(result.every((a) => a.url.startsWith('https://www.tsdm39.com/')), isTrue);
  });

  test('missing section and empty description return an empty list', () {
    expect(parseForumActivities(parseHtmlDocument('<h2><a>其他</a></h2>')), isEmpty);
    expect(parseForumActivities(parseHtmlDocument('<div><h2><a>活动专区</a></h2><p class="xg2"></p></div>')), isEmpty);
  });

  testWidgets('loading, failure retry, empty state and refresh are usable', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    var calls = 0;
    final first = Completer<uh.Document>();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: ActivitiesPage(
            loadDocument: () {
              calls++;
              return calls == 1 ? first.future : Future.value(parseHtmlDocument('<html></html>'));
            },
          ),
        ),
      ),
    );
    expect(find.byType(CenteredCircularIndicator), findsOneWidget);
    first.completeError(const HttpException('offline'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton).first);
    await tester.pumpAndSettle();
    expect(find.text(t.activitiesPage.empty), findsOneWidget);
    await tester.tap(find.byTooltip(t.activitiesPage.refresh));
    await tester.pumpAndSettle();
    expect(calls, 3);
  });
}
