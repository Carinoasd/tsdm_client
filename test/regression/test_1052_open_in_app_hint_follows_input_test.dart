// "Open in app": once the field had said "unsupported URL" (an open tapped too early, a deep link the app does not
// know), a valid forum link pasted afterwards still showed it, while tapping "open" opened the link. The text under
// the field was only worked out when the form was checked, never as the input changed.
//
// The hint and the button use the same check of the input; after the first check the hint follows every change of
// the input and of the kind of input. Before it, typing shows no error.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/open_in_app/view/open_in_app_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

const _thread = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=123';

Finder get _field => find.byType(TextFormField);

Finder get _unsupported => find.text(tr.openInAppPage.url.unsupportedUrl);

void main() {
  final opened = <String>[];

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(useConsoleLogs: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(opened.clear);

  Future<void> pumpPage(WidgetTester tester, {String? initialUrl, bool autoOpen = false}) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: ScreenPaths.openInApp,
          name: ScreenPaths.openInApp,
          builder: (context, state) => OpenInAppPage(initialUrl: initialUrl, autoOpen: autoOpen),
        ),
        GoRoute(
          path: ScreenPaths.threadV1,
          name: ScreenPaths.threadV1,
          builder: (context, state) {
            opened.add(state.uri.toString());
            return const Scaffold(body: Text('thread'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
    unawaited(router.pushNamed(ScreenPaths.openInApp));
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, String text) async {
    await tester.enterText(_field, text);
    await tester.pump();
  }

  Future<void> tapOpen(WidgetTester tester) async {
    await tester.tap(find.text(tr.openInAppPage.open));
    await tester.pumpAndSettle();
  }

  testWidgets('a valid link entered after the error clears it, and opens', (tester) async {
    await pumpPage(tester);
    await tapOpen(tester);
    expect(_unsupported, findsOneWidget);

    await enter(tester, _thread);
    expect(_unsupported, findsNothing);

    await tapOpen(tester);
    expect(opened, hasLength(1));
    expect(opened.single, contains('tid=123'));
  });

  testWidgets('after the first check the hint follows every change', (tester) async {
    await pumpPage(tester);
    await enter(tester, 'not a link');
    await tapOpen(tester);
    expect(_unsupported, findsOneWidget);

    await enter(tester, _thread);
    expect(_unsupported, findsNothing);
    await enter(tester, 'https://example.com/a');
    expect(_unsupported, findsOneWidget);
    await enter(tester, '  $_thread  ');
    expect(_unsupported, findsNothing);
    expect(opened, isEmpty);
  });

  testWidgets('no error while typing before the first check', (tester) async {
    await pumpPage(tester);
    await enter(tester, 'h');
    await enter(tester, 'htt');
    expect(_unsupported, findsNothing);
  });

  testWidgets('switching the kind of input checks the input again', (tester) async {
    await pumpPage(tester);
    await enter(tester, 'abc');
    await tapOpen(tester);
    expect(_unsupported, findsOneWidget);

    await tester.tap(find.text(tr.openInAppPage.tid.title));
    await tester.pump();
    expect(_unsupported, findsNothing);
    expect(find.text(tr.openInAppPage.tid.invalidTid), findsOneWidget);

    await enter(tester, '123');
    expect(find.text(tr.openInAppPage.tid.invalidTid), findsNothing);
    await tapOpen(tester);
    expect(opened.single, contains('tid=123'));
  });

  testWidgets('a deep link the app does not know, edited into a valid one', (tester) async {
    await pumpPage(tester, initialUrl: 'https://example.com/a', autoOpen: true);
    await tester.pumpAndSettle();
    expect(_unsupported, findsOneWidget);
    expect(opened, isEmpty);

    await enter(tester, _thread);
    expect(_unsupported, findsNothing);
    await tapOpen(tester);
    expect(opened, hasLength(1));
  });
}
