import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/medal_center/cubit/medal_center_cubit.dart';
import 'package:tsdm_client/features/medal_center/models/medal_catalog.dart';
import 'package:tsdm_client/features/medal_center/view/medal_center_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:universal_html/parsing.dart';

String _fixture(String name) => File('test/data/medal_${name}_x5.html').readAsStringSync();
MedalCatalog _parse(String name) => parseMedalCatalog(parseHtmlDocument(_fixture(name)));

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  test('actual catalogue keeps categories, methods, images and all currency prices', () {
    final catalog = _parse('catalog');
    expect(catalog.supported, isTrue);
    expect(catalog.medals, hasLength(40));
    expect(catalog.categories.take(3).map((c) => c.name), ['全部', '永久徽章', '特殊申请']);
    final permanent = catalog.medals.firstWhere((m) => m.id == '519');
    expect(permanent.name, '【永久】SABER');
    expect(permanent.method, '积分购买');
    expect(permanent.imageUrl, startsWith('https://www.tsdm39.com/static/image/'));
    expect(permanent.details.join('\n'), contains('天使币:3000\n宣传:50'));
    expect(permanent.accountStatus, '未达到领取条件');
    final limited = catalog.medals.firstWhere((m) => m.id == '593');
    expect(limited.details.join('\n'), contains('有效期：30 天'));
    final manual = catalog.medals.firstWhere((m) => m.id == '6');
    expect(manual.method, '人工审核');
    expect(manual.details.join('\n'), contains('威望 ≥ 5'));
    expect(manual.details.join('\n'), contains('主题数 ≥ 1'));
    expect(catalog.medals.firstWhere((m) => m.id == '3').method, '管理员颁发');
  });
  test('actual pagination and category pages preserve server destinations', () {
    final first = _parse('guest');
    expect(first.page, 1);
    expect(first.previousUrl, isNull);
    expect(first.nextUrl, contains('page=2'));
    final second = _parse('page2');
    expect(second.page, 2);
    expect(second.previousUrl, isNotNull);
    expect(second.nextUrl, contains('page=3'));
    final category = _parse('category2');
    expect(category.medals, isNotEmpty);
    if (category.nextUrl != null) expect(category.nextUrl, contains('typeid=2'));
  });
  test('all navigation rejects transactions, unexpected schemes, origins and parameters', () {
    for (final url in [
      'javascript:alert(1)',
      'data:text/html,hello',
      'https://evil.example/plugin.php?id=dsu_medalCenter:memcp',
      '$medalCenterUrl&action=apply&medalid=519',
      '$medalCenterUrl&formhash=secret',
      '$medalCenterUrl&page=-1',
    ]) {
      expect(medalCatalogUrl(url), isNull, reason: url);
    }
    expect(medalCatalogUrl('/plugin.php?id=dsu_medalCenter:memcp&typeid=2&page=3'), '$medalCenterUrl&typeid=2&page=3');
  });
  test('missing method or price remains missing; permission and empty layouts are distinct', () {
    final missing = parseMedalCatalog(
      parseHtmlDocument('''
      <ul class="mdl"><li class="pns"><img id="mc_medal1"><p class="mtn">Medal</p></li></ul>
      <div id="mc_medal1_menu"><p class="desc">Description</p></div>
    '''),
    );
    expect(missing.medals.single.method, isEmpty);
    expect(missing.medals.single.details, isEmpty);
    expect(missing.medals.single.imageUrl, isNull);
    expect(parseMedalCatalog(parseHtmlDocument('<ul class="mdl"><p class="emp">暂无勋章</p></ul>')).medals, isEmpty);
    final denied = parseMedalCatalog(parseHtmlDocument('<div id="messagetext">没有权限</div>'));
    expect(denied.supported, isFalse);
    expect(denied.message, '没有权限');
  });
  test('only GET is possible; unsafe navigation is rejected before transport', () async {
    final requests = <String>[];
    final cubit = MedalCenterCubit(
      currentUid: () => null,
      fetchPage: (url) async {
        requests.add(url);
        return _fixture(url.contains('page=2') ? 'page2' : 'guest');
      },
    );
    await cubit.load();
    await cubit.load(cubit.state.catalog!.nextUrl);
    expect(cubit.state.catalog!.page, 2);
    await cubit.load('$medalCenterUrl&action=apply&medalid=519');
    expect(requests, hasLength(2));
    await cubit.close();
  });
  test('account switch clears eligibility and drops in-flight old-account responses', () async {
    var uid = 1000;
    final response = Completer<String>();
    final cubit = MedalCenterCubit(currentUid: () => uid, fetchPage: (_) => response.future);
    final load = cubit.load();
    uid = 1001;
    cubit.invalidate();
    response.complete(_fixture('catalog'));
    await load;
    expect(cubit.state.catalog, isNull);
    await cubit.close();
  });
  test('expired session never displays old account conditions', () async {
    final cubit = MedalCenterCubit(currentUid: () => 1000, fetchPage: (_) async => _fixture('guest'));
    await cubit.load();
    expect(cubit.state.needLogin, isTrue);
    expect(cubit.state.catalog, isNull);
    await cubit.close();
  });
  testWidgets('loading, retry and empty list work at phone width', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var calls = 0;
    final first = Completer<String>();
    final cubit = MedalCenterCubit(
      currentUid: () => null,
      fetchPage: (_) {
        calls++;
        return calls == 1 ? first.future : Future.value('<ul class="mdl"></ul>');
      },
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: MedalCenterPage(controller: cubit)),
      ),
    );
    expect(find.byType(CenteredCircularIndicator), findsOneWidget);
    first.completeError(const HttpException('offline'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.general.retry));
    await tester.pumpAndSettle();
    expect(find.text(t.medalCenter.empty), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await cubit.close();
  });
  testWidgets('a failed image does not hide the medal name, method or expanded details', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    final cubit = MedalCenterCubit(currentUid: () => null, fetchPage: (_) async => _fixture('guest'));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MedalCenterPage(controller: cubit, imageBuilder: (_) => const Icon(Icons.broken_image_outlined)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final title = cubit.state.catalog!.medals.first.name;
    expect(find.text(title), findsOneWidget);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    // The browser fallback remains in the app bar after per-medal action buttons were added.
    final openBrowser = find.descendant(
      of: find.byType(AppBar),
      matching: find.widgetWithIcon(IconButton, Icons.open_in_browser_outlined),
    );
    expect(openBrowser, findsOneWidget);
    final browserButton = tester.widget<IconButton>(openBrowser);
    expect(browserButton.tooltip, t.medalCenter.openBrowser);
    expect(browserButton.onPressed, isNotNull);
    expect(find.byIcon(Icons.broken_image_outlined), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await cubit.close();
  });
}
