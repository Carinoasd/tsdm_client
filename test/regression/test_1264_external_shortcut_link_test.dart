/// `tsdm://shortcut/checkin` checked in at once: on iOS the scheme is registered for the widget, so any web page or
/// app could open it and check the account in. Now only the app's own shortcuts do something on their own: the quick
/// actions and the widget's taps (its links signed with a key of the App Group) are handed to Dart as the shortcut's
/// id, as Android hands its launcher shortcuts and widget over; any other `tsdm://` link is handed over as the link,
/// and the check-in it asks for only goes back to the homepage ([decideAppShortcut] `external`). The other shortcuts
/// only open a page either way.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/shortcuts/models/app_shortcut.dart';
import 'package:tsdm_client/features/shortcuts/repository/app_shortcuts_channel.dart';
import 'package:tsdm_client/features/shortcuts/utils/app_shortcut_action.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("an id is the app's own shortcut, a link one from outside", () {
    for (final shortcut in AppShortcut.values) {
      expect(AppShortcut.requestOf(shortcut.id), (shortcut: shortcut, external: false));
      expect(AppShortcut.requestOf(shortcut.link), (shortcut: shortcut, external: true));
      expect(AppShortcut.requestOf('${shortcut.link}?key=anything'), (shortcut: shortcut, external: true));
    }
    expect(AppShortcut.requestOf('tsdm:checkin'), isNull);
    expect(AppShortcut.requestOf('unknown'), isNull);
  });

  test('the check-in of a link from outside only goes home', () {
    for (final loggedIn in [true, false]) {
      expect(decideAppShortcut(AppShortcut.checkin, loggedIn: loggedIn, external: true), isA<AppShortcutHome>());
    }
    expect(decideAppShortcut(AppShortcut.checkin, loggedIn: true), isA<AppShortcutCheckin>());
    // The rest open a page as before.
    expect(decideAppShortcut(AppShortcut.notice, loggedIn: true, external: true), isA<AppShortcutNotice>());
    expect(decideAppShortcut(AppShortcut.favorite, loggedIn: false, external: true), isA<AppShortcutLogin>());
    expect(
      decideAppShortcut(AppShortcut.search, loggedIn: true, external: true),
      isA<AppShortcutOpenPage>().having((e) => e.path, 'path', ScreenPaths.search),
    );
  });

  testWidgets('going home goes where the check-in goes, and starts none', (tester) async {
    Future<(String?, int)> run(AppShortcutAction action) async {
      final router = GoRouter(
        initialLocation: ScreenPaths.homepage,
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, _, navigator) => navigator,
            branches: [
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: ScreenPaths.homepage,
                    name: ScreenPaths.homepage,
                    builder: (_, _) => const Text('home'),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(path: ScreenPaths.search, name: ScreenPaths.search, builder: (_, _) => const Text('search')),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(key: UniqueKey(), routerConfig: router));
      unawaited(router.pushNamed(ScreenPaths.search));
      await tester.pumpAndSettle();
      var checkins = 0;
      performAppShortcut(router, action, hasPopup: false, checkin: () => checkins++);
      await tester.pumpAndSettle();
      return (routerTopLocation(router), checkins);
    }

    final (checkinTop, checkins) = await run(const AppShortcutCheckin());
    final (homeTop, none) = await run(const AppShortcutHome());
    expect(homeTop, checkinTop);
    expect(checkins, 1);
    expect(none, 0);
  });

  group('the channel tells where a shortcut came from', () {
    const channel = MethodChannel(AppShortcutsChannel.name);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('a cold start', () async {
      for (final (value, external) in [('checkin', false), ('tsdm://shortcut/checkin', true)]) {
        messenger.setMockMethodCallHandler(channel, (_) async => value);
        expect(await const AppShortcutsChannel().initialRequest(), (shortcut: AppShortcut.checkin, external: external));
      }
    });

    test('while the app runs', () async {
      const shortcuts = AppShortcutsChannel();
      final got = <AppShortcutRequest>[];
      shortcuts.listenRequests(got.add);
      addTearDown(shortcuts.dispose);
      const codec = StandardMethodCodec();
      for (final value in ['checkin', 'tsdm://shortcut/checkin']) {
        await messenger.handlePlatformMessage(
          AppShortcutsChannel.name,
          codec.encodeMethodCall(MethodCall(AppShortcutsChannel.onShortcut, value)),
          (_) {},
        );
      }
      expect(got, [(shortcut: AppShortcut.checkin, external: false), (shortcut: AppShortcut.checkin, external: true)]);
    });
  });

  group('iOS', () {
    String read(String path) => File(path).readAsStringSync();

    test('the bridge hands the id over only for a quick action or a signed link of the widget', () {
      final bridge = read('ios/Runner/HomeWidgetBridge.swift');
      expect(bridge, contains('HomeWidgetLinkKey.signs(url)'));
      expect(bridge, contains('let link = own ? url.lastPathComponent : url.absoluteString'));
      expect(bridge, contains('return open(url, trusted: true)'));
      expect(bridge, contains('HomeWidgetLinkKey.ensure()'));
      // A link opened from outside (the scene's and the application's url events) is not trusted.
      expect(RegExp(r'open\(context\.url\)').hasMatch(bridge), isTrue);
      expect(bridge, isNot(contains('open(context.url, trusted: true)')));
    });

    test('the widget opens its links signed', () {
      final widget = read('ios/TsdmWidget/TsdmWidget.swift');
      expect(widget, contains('HomeWidgetLinkKey.signed(HomeWidgetLink.checkin)'));
      expect(widget, contains('.widgetURL(HomeWidgetLinkKey.signed('));
      expect(RegExp(r'Link\(destination: HomeWidgetLink\.').hasMatch(widget), isFalse);
      // The key lives with the state both targets compile.
      expect(read('ios/TsdmWidget/HomeWidgetState.swift'), contains('enum HomeWidgetLinkKey'));
    });

    test('no desktop platform registers the scheme', () {
      for (final dir in ['macos', 'windows', 'linux']) {
        for (final file in Directory(dir).listSync(recursive: true).whereType<File>()) {
          if (!RegExp(r'\.(plist|cc|cpp|h|txt|desktop|swift|xml|json|cmake)$').hasMatch(file.path)) {
            continue;
          }
          final text = file.readAsStringSync();
          expect(text, isNot(contains('tsdm://')), reason: file.path);
          expect(text, isNot(contains('<string>tsdm</string>')), reason: file.path);
          expect(text, isNot(contains('x-scheme-handler/tsdm')), reason: file.path);
        }
      }
    });
  });
}
