import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/medal_center/view/medal_title_hub_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// Testers found the title shop only behind avatar > profile > menu > my titles > shop. The medal & title hub links
/// the medal centre, the own titles and the title shop through their existing routes; nothing is bought or switched on
/// the hub itself.
void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  Future<GoRouter> pump(WidgetTester tester) async {
    GoRoute stub(String path) => GoRoute(
      path: path,
      name: path,
      builder: (_, _) => Scaffold(body: Text('page $path')),
    );
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const MedalTitleHubPage()),
        stub(ScreenPaths.medalCenter),
        stub(ScreenPaths.switchTitle),
        stub(ScreenPaths.titleShop),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('the hub links the medal centre, my titles and the title shop', (tester) async {
    final router = await pump(tester);
    expect(find.text(tr.medalTitleHub.title), findsOneWidget);
    expect(find.text(tr.medalTitleHub.currentTitle), findsOneWidget);
    // Each destination by its title alone, no line of description under it.
    for (final tile in tester.widgetList<ListTile>(find.byType(ListTile))) {
      expect(tile.subtitle, isNull);
    }

    for (final (label, path) in [
      (tr.medalCenter.title, ScreenPaths.medalCenter),
      (tr.myTitlesPage.title, ScreenPaths.switchTitle),
      (tr.titleShop.title, ScreenPaths.titleShop),
    ]) {
      await tester.tap(find.widgetWithText(ListTile, label));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, path);
      expect(find.text('page $path'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow and large text: every entry stays reachable without overflow', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 560);
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pump(tester);
    await tester.scrollUntilVisible(find.widgetWithText(ListTile, tr.titleShop.title), 100);
    expect(find.widgetWithText(ListTile, tr.titleShop.title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Translations get tr => LocaleSettings.instance.currentTranslations;
