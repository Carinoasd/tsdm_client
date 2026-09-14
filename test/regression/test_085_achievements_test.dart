import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/achievements/cubit/achievements_cubit.dart';
import 'package:tsdm_client/features/achievements/models/achievement_page_data.dart';
import 'package:tsdm_client/features/achievements/view/achievements_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

String _fixture(String name) => File('test/data/achievements_${name}_x5.html').readAsStringSync();
String _withContent(String content) => _fixture('empty').replaceAll('<p class="emp">暂无成就</p>', content);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  test('actual page explicitly reports empty; never interprets it as zero progress', () {
    final page = parseAchievementPage(parseHtmlDocument(_fixture('empty')));
    expect(page.recognized, isTrue);
    expect(page.empty, isTrue);
    expect(page.content, '暂无成就');
    expect(page.content, isNot(contains('%')));
  });
  test('actual guest page and unknown layout do not masquerade as an empty list', () {
    final guest = parseAchievementPage(parseHtmlDocument(_fixture('guest')));
    expect(guest.recognized, isFalse);
    expect(guest.empty, isFalse);
    expect(guest.message, contains('尚未登录'));
    expect(parseAchievementPage(parseHtmlDocument('<h2>Other plugin</h2>')).recognized, isFalse);
  });
  test('future content fallback preserves explicit status and ratios without guessing percentages', () {
    // Synthetic contents inside the captured container; not a claim about a populated live X5 schema.
    final page = parseAchievementPage(
      parseHtmlDocument(
        _withContent('''
      <h3>Achievement A</h3><p>已完成</p><button disabled>已领取</button>
      <h3>Achievement B</h3><p>未完成</p><progress value="3" max="10"></progress>
      <h3>Achievement C</h3><p>条件：发帖 20 次</p>
    '''),
      ),
    );
    expect(page.empty, isFalse);
    expect(page.content, contains('已完成\n已领取'));
    expect(page.content, contains('未完成\n3 / 10'));
    expect(page.content, contains('条件：发帖 20 次'));
    expect(page.content, isNot(contains('%')));
  });
  test('fallback is text only: scripts, hidden material and form credentials are excluded', () {
    final page = parseAchievementPage(
      parseHtmlDocument(
        _withContent('''
      <p>Visible</p><script>secret script</script><input value="secret credential">
      <p style="display: none">secret hidden</p><textarea>secret token</textarea>
      <a href="plugin.php?id=tsdmtitle:achi&action=claim">领取</a>
    '''),
      ),
    );
    expect(page.content, 'Visible\n领取');
    expect(page.content, isNot(contains('secret')));
    expect(page.content, isNot(contains('action=claim')));
  });
  test('logged-out users get a login state without any request', () async {
    var requests = 0;
    final cubit = AchievementsCubit(
      currentUid: () => null,
      fetchPage: () async {
        requests++;
        return '';
      },
    );
    await cubit.load();
    expect(requests, 0);
    expect(cubit.state.needLogin, isTrue);
    await cubit.close();
  });
  test('expired login and mismatched identities never expose account content', () async {
    final cubit = AchievementsCubit(currentUid: () => 1000, fetchPage: () async => _fixture('guest'));
    await cubit.load();
    expect(cubit.state.needLogin, isTrue);
    expect(cubit.state.data, isNull);
    await cubit.close();
    final other = AchievementsCubit(currentUid: () => 1001, fetchPage: () async => _fixture('empty'));
    await other.load();
    expect(other.state.failed, isTrue);
    expect(other.state.data, isNull);
    await other.close();
  });
  test('account A to B to A drops an old response even though the final UID matches', () async {
    var uid = 1000;
    final old = Completer<String>();
    final cubit = AchievementsCubit(currentUid: () => uid, fetchPage: () => old.future);
    final pending = cubit.load();
    uid = 1001;
    cubit.invalidate();
    uid = 1000;
    cubit.invalidate();
    old.complete(_fixture('empty'));
    await pending;
    expect(cubit.state.data, isNull);
    await cubit.close();
  });
  test('later refresh wins over a slow old request', () async {
    final old = Completer<String>();
    var requests = 0;
    final cubit = AchievementsCubit(
      currentUid: () => 1000,
      fetchPage: () => ++requests == 1 ? old.future : Future.value(_fixture('empty')),
    );
    final first = cubit.load();
    await cubit.load();
    old.complete(_withContent('<p>stale</p>'));
    await first;
    expect(cubit.state.data!.empty, isTrue);
    await cubit.close();
  });
  testWidgets('network retry and real empty state remain usable at phone width', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var requests = 0;
    final cubit = AchievementsCubit(
      currentUid: () => 1000,
      fetchPage: () async {
        if (++requests == 1) throw const HttpException('offline');
        return _fixture('empty');
      },
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: AchievementsPage(controller: cubit)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.general.retry));
    await tester.pumpAndSettle();
    expect(find.text(t.achievementsPage.empty), findsOneWidget);
    expect(find.text(t.achievementsPage.openBrowser), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await cubit.close();
  });
}
