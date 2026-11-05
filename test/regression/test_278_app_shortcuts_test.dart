/// The shortcuts of a long press on the app icon (Android): the native `ShortcutsHandler` hands the shortcut id over a
/// method channel, Dart decides by the account in use and navigates.
///
/// 1. the four ids of `shortcuts.xml` are known, anything else is dropped;
/// 2. the search is open to guests, the check-in, the notices and the favorites ask for a login without an account;
/// 3. the channel: the id of a cold start is asked once, a shortcut tapped while the app runs reaches the listener, an
///    unknown id or a missing native side never throws;
/// 4. on the router: a page is pushed above the page on top and not twice, the notices show their tab when the shell is
///    alone and are pushed above another page, the check-in goes home through the quietly closable pages and leaves a
///    dialog alone;
/// 5. the check-in waits for the login check of a cold start (`CheckinBloc` drops a request before the stored session
///    is verified): it starts with the first "authed", gives the login page when the storage knows the session expired
///    (the homepage records a guest page there, no status is emitted for it) or on "not authed", and gives up after
///    the timeout of an offline start.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/shortcuts/models/app_shortcut.dart';
import 'package:tsdm_client/features/shortcuts/repository/app_shortcuts_channel.dart';
import 'package:tsdm_client/features/shortcuts/utils/app_shortcut_action.dart';
import 'package:tsdm_client/features/shortcuts/utils/checkin_when_verified.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('the ids of shortcuts.xml', () {
    expect(AppShortcut.fromId('checkin'), AppShortcut.checkin);
    expect(AppShortcut.fromId('notice'), AppShortcut.notice);
    expect(AppShortcut.fromId('favorite'), AppShortcut.favorite);
    expect(AppShortcut.fromId('search'), AppShortcut.search);
    expect(AppShortcut.fromId('settings'), isNull);
    expect(AppShortcut.fromId(''), isNull);
    expect(AppShortcut.fromId(null), isNull);
  });

  test('what a shortcut does with and without an account', () {
    expect(decideAppShortcut(AppShortcut.checkin, loggedIn: true), isA<AppShortcutCheckin>());
    expect(decideAppShortcut(AppShortcut.notice, loggedIn: true), isA<AppShortcutNotice>());
    expect(
      decideAppShortcut(AppShortcut.favorite, loggedIn: true),
      isA<AppShortcutOpenPage>().having((a) => a.path, 'path', ScreenPaths.favorite),
    );
    expect(
      decideAppShortcut(AppShortcut.search, loggedIn: true),
      isA<AppShortcutOpenPage>().having((a) => a.path, 'path', ScreenPaths.search),
    );
    for (final needsAccount in [AppShortcut.checkin, AppShortcut.notice, AppShortcut.favorite]) {
      expect(decideAppShortcut(needsAccount, loggedIn: false), isA<AppShortcutLogin>(), reason: needsAccount.id);
    }
    expect(
      decideAppShortcut(AppShortcut.search, loggedIn: false),
      isA<AppShortcutOpenPage>().having((a) => a.path, 'path', ScreenPaths.search),
    );
  });

  group('channel', () {
    const channel = MethodChannel(AppShortcutsChannel.name);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<String> asked;
    String? initialId;

    setUp(() {
      asked = [];
      initialId = null;
      messenger.setMockMethodCallHandler(channel, (call) async {
        asked.add(call.method);
        if (call.method == AppShortcutsChannel.getInitialShortcut) {
          final id = initialId;
          initialId = null;
          return id;
        }
        throw MissingPluginException();
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    /// The native side telling [id] while the app runs.
    Future<void> tapped(Object? id, {String method = AppShortcutsChannel.onShortcut}) async {
      final done = Completer<ByteData?>();
      await messenger.handlePlatformMessage(
        AppShortcutsChannel.name,
        channel.codec.encodeMethodCall(MethodCall(method, id)),
        done.complete,
      );
      await done.future;
    }

    test('the shortcut of a cold start is asked once', () async {
      initialId = 'favorite';
      const shortcuts = AppShortcutsChannel();
      expect(await shortcuts.initial(), AppShortcut.favorite);
      expect(await shortcuts.initial(), isNull);
      expect(asked, [AppShortcutsChannel.getInitialShortcut, AppShortcutsChannel.getInitialShortcut]);
    });

    test('an unknown id, a start without a shortcut and a missing native side are nothing', () async {
      const shortcuts = AppShortcutsChannel();
      initialId = 'settings';
      expect(await shortcuts.initial(), isNull);
      expect(await shortcuts.initial(), isNull);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await shortcuts.initial(), isNull);
    });

    test('a shortcut tapped while the app runs reaches the listener', () async {
      const shortcuts = AppShortcutsChannel();
      final got = <AppShortcut>[];
      shortcuts.listen(got.add);
      addTearDown(shortcuts.dispose);
      await tapped('search');
      await tapped('checkin');
      expect(got, [AppShortcut.search, AppShortcut.checkin]);

      // Not a shortcut, not a method of the channel: dropped.
      await tapped('settings');
      await tapped(null);
      await tapped('search', method: 'somethingElse');
      expect(got, [AppShortcut.search, AppShortcut.checkin]);

      shortcuts.dispose();
      await tapped('favorite');
      expect(got, [AppShortcut.search, AppShortcut.checkin]);
    });
  });

  group('on the router', () {
    late GoRouter router;
    late int checkins;

    Future<void> pump(WidgetTester tester, {String initialLocation = ScreenPaths.homepage}) async {
      checkins = 0;
      router = GoRouter(
        initialLocation: initialLocation,
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
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: ScreenPaths.notice,
                    name: ScreenPaths.notice,
                    builder: (_, _) => const Text('notice tab'),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(path: ScreenPaths.rootNotice, name: ScreenPaths.rootNotice, builder: (_, _) => const Text('notice')),
          GoRoute(path: ScreenPaths.login, name: ScreenPaths.login, builder: (_, _) => const Text('login')),
          GoRoute(path: ScreenPaths.search, name: ScreenPaths.search, builder: (_, _) => const Text('search')),
          GoRoute(path: ScreenPaths.favorite, name: ScreenPaths.favorite, builder: (_, _) => const Text('favorite')),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
    }

    Future<void> perform(WidgetTester tester, AppShortcutAction action, {bool hasPopup = false}) async {
      performAppShortcut(router, action, hasPopup: hasPopup, checkin: () => checkins++);
      await tester.pumpAndSettle();
    }

    testWidgets('a page is pushed above the page on top, and not twice', (tester) async {
      await pump(tester);
      await perform(tester, const AppShortcutOpenPage(ScreenPaths.search));
      expect(routerTopLocation(router), ScreenPaths.search);
      expect(find.text('search'), findsOneWidget);
      await perform(tester, const AppShortcutOpenPage(ScreenPaths.search));
      expect(find.text('search'), findsOneWidget);

      // Another page goes above it; the first stays underneath, back returns to it.
      await perform(tester, const AppShortcutOpenPage(ScreenPaths.favorite));
      expect(routerTopLocation(router), ScreenPaths.favorite);
      router.pop();
      await tester.pumpAndSettle();
      expect(routerTopLocation(router), ScreenPaths.search);
    });

    testWidgets('without an account the login page opens, once', (tester) async {
      await pump(tester);
      await perform(tester, const AppShortcutLogin());
      expect(routerTopLocation(router), ScreenPaths.login);
      await perform(tester, const AppShortcutLogin());
      expect(find.text('login'), findsOneWidget);
    });

    testWidgets('the notices: the tab when the shell is alone, a page above another page', (tester) async {
      await pump(tester);
      await perform(tester, const AppShortcutNotice());
      expect(routerTopLocation(router), ScreenPaths.notice);
      expect(find.text('notice tab'), findsOneWidget);
      // Already there: nothing more.
      await perform(tester, const AppShortcutNotice());
      expect(find.text('notice'), findsNothing);

      await perform(tester, const AppShortcutOpenPage(ScreenPaths.search));
      await perform(tester, const AppShortcutNotice());
      expect(routerTopLocation(router), ScreenPaths.rootNotice);
      router.pop();
      await tester.pumpAndSettle();
      expect(routerTopLocation(router), ScreenPaths.search);
    });

    testWidgets('the check-in goes home through the pages that close quietly, then starts', (tester) async {
      await pump(tester);
      // From another tab.
      await perform(tester, const AppShortcutNotice());
      expect(routerTopLocation(router), ScreenPaths.notice);
      await perform(tester, const AppShortcutCheckin());
      expect(routerTopLocation(router), ScreenPaths.homepage);
      expect(checkins, 1);

      // From a page above the shell that may be closed on the app's own (the favorites).
      await perform(tester, const AppShortcutOpenPage(ScreenPaths.favorite));
      await perform(tester, const AppShortcutCheckin());
      expect(routerTopLocation(router), ScreenPaths.homepage);
      expect(checkins, 2);

      // A page that may hold input (the login form here) stays; the check-in still starts.
      await perform(tester, const AppShortcutOpenPage(ScreenPaths.login));
      await perform(tester, const AppShortcutCheckin());
      expect(routerTopLocation(router), ScreenPaths.login);
      expect(checkins, 3);
    });

    testWidgets('with a dialog open nothing is closed, the check-in still starts', (tester) async {
      await pump(tester);
      await perform(tester, const AppShortcutOpenPage(ScreenPaths.favorite));
      await perform(tester, const AppShortcutCheckin(), hasPopup: true);
      expect(routerTopLocation(router), ScreenPaths.favorite);
      expect(checkins, 1);
    });
  });

  group('the check-in waits for the login check', () {
    late StreamController<AuthStatus> status;
    late StreamController<bool> expired;
    late bool verified;
    late int started;

    setUp(() {
      status = StreamController<AuthStatus>.broadcast();
      expired = StreamController<bool>.broadcast();
      verified = false;
      started = 0;
    });
    tearDown(() async {
      await status.close();
      await expired.close();
    });

    Future<ShortcutCheckinOutcome> run({
      Duration timeout = const Duration(seconds: 20),
      Duration grace = const Duration(milliseconds: 40),
    }) => startCheckinWhenVerified(
      verified: () => verified,
      status: status.stream,
      expired: expired.stream,
      start: () => started++,
      timeout: timeout,
      knownExpiryGrace: grace,
    );

    test('a verified session starts right away', () async {
      verified = true;
      expect(await run(), ShortcutCheckinOutcome.started);
      expect(started, 1);
    });

    test('a cold start: the first "authed" starts it, loading states and a live session are not answers', () async {
      final outcome = run();
      status.add(const AuthStatusLoading());
      expired.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(started, 0);
      verified = true;
      status.add(const AuthStatusAuthed(UserLoginInfo(username: 'u', uid: 1)));
      expect(await outcome, ShortcutCheckinOutcome.started);
      expect(started, 1);
    });

    test('an expired session: not started, the login page is for the user', () async {
      // Known from an earlier start: the storage tells it first thing, and it answers after the grace.
      var outcome = run();
      expired.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(started, 0);
      expect(status.hasListener, isTrue);
      expect(await outcome, ShortcutCheckinOutcome.notAuthed);
      expect(started, 0);

      // Found by the homepage's fetch while waiting: no grace.
      outcome = run();
      expired.add(false);
      await Future<void>.delayed(Duration.zero);
      expired.add(true);
      expect(await outcome, ShortcutCheckinOutcome.notAuthed);
      expect(started, 0);

      // Logged out meanwhile.
      outcome = run();
      status.add(const AuthStatusNotAuthed());
      expect(await outcome, ShortcutCheckinOutcome.notAuthed);
      expect(started, 0);
    });

    test('a record of an earlier start may be wrong: a session verified within the grace is checked in', () async {
      final outcome = run();
      expired.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      verified = true;
      status.add(const AuthStatusAuthed(UserLoginInfo(username: 'u', uid: 1)));
      expect(await outcome, ShortcutCheckinOutcome.started);
      expect(started, 1);
    });

    test('a failing stream ends the wait like a timeout', () async {
      final outcome = run();
      expired.addError(StateError('db closed'));
      expect(await outcome, ShortcutCheckinOutcome.timedOut);
      expect(started, 0);
      expect(status.hasListener, isFalse);
    });

    test('the answer ends the wait: nothing listens afterwards', () async {
      final outcome = run();
      status.add(const AuthStatusNotAuthed());
      await outcome;
      expect(status.hasListener, isFalse);
      expect(expired.hasListener, isFalse);
      await run(timeout: const Duration(milliseconds: 20));
      expect(status.hasListener, isFalse);
      expect(expired.hasListener, isFalse);
    });

    test('no answer in time (an offline start): given up', () async {
      expect(await run(timeout: const Duration(milliseconds: 20)), ShortcutCheckinOutcome.timedOut);
      expect(started, 0);
    });

    test('verified meanwhile counts whatever the answer says', () async {
      final outcome = run();
      verified = true;
      status.add(const AuthStatusNotAuthed());
      expect(await outcome, ShortcutCheckinOutcome.started);
      expect(started, 1);
    });
  });
}
