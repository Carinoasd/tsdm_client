import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/home/widgets/widgets.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/features/profile/models/secondary_title.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/utils/daily_red_packet_record.dart';
import 'package:tsdm_client/features/red_packet/widgets/daily_red_packet_button.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Navigation refinement of 2026-09-27:
///
/// * the side navigation (drawer on large windows, rail on medium ones) has the same four tabs as the phone bar since
///   the navigation rework of 2026-10-23 (it had nine entries in two groups before; the pages it opened are entries of
///   the "me" tab now);
/// * the notifications entry shows the real unread count by the rules of the app bar notice icon;
/// * the homepage greeting always shows a daily red packet entry with an honest state and submits at most once;
/// * the title badge of the greeting is its natural 184px on wide layouts and 160 to 184px on phones.
///
/// Synthetic accounts and answers only: no network, nothing is claimed, no login.
Translations get tr => LocaleSettings.instance.currentTranslations;

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

/// The four tabs of every navigation since the navigation rework of 2026-10-23.
const _tabPaths = <String>[ScreenPaths.homepage, ScreenPaths.topic, ScreenPaths.notice, ScreenPaths.me];

enum _Layout { phone, tablet, desktop }

const _config = DailyRedPacketConfig(entry: 2, dateFlag: '20260927', from: 'System', bless: 'Hi', unit: 'coins');

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('side navigation', () {
    late HomeCubit cubit;
    late GoRouter router;
    late DateTime now;

    setUp(() {
      now = DateTime(2026, 9, 27, 12);
      HomeTabDoubleTapDetector.clock = () => now;
    });

    tearDown(() => HomeTabDoubleTapDetector.clock = DateTime.now);

    String? location() => routerTopLocation(router);

    Future<void> pumpHome(
      WidgetTester tester,
      _Layout layout, {
      AuthenticationRepository? auth,
      NotificationStateCubit? notice,
    }) async {
      cubit = HomeCubit();
      router = GoRouter(
        initialLocation: ScreenPaths.homepage,
        routes: [
          ShellRoute(
            builder: (context, state, child) => switch (layout) {
              _Layout.phone => Scaffold(body: child, bottomNavigationBar: const HomeNavigationBar()),
              _Layout.tablet => Scaffold(
                body: Row(
                  children: [
                    const HomeNavigationRail(),
                    Expanded(child: child),
                  ],
                ),
              ),
              // Same constraint as HomePage puts on the drawer.
              _Layout.desktop => Scaffold(
                body: Row(
                  children: [
                    const SizedBox(width: 250, child: HomeNavigationDrawer()),
                    Expanded(child: child),
                  ],
                ),
              ),
            },
            routes: [
              for (final path in _tabPaths)
                GoRoute(
                  path: path,
                  name: path,
                  pageBuilder: (context, state) => NoTransitionPage(child: Center(child: Text('tab $path'))),
                ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      addTearDown(cubit.close);
      Widget app = BlocProvider<HomeCubit>.value(
        value: cubit,
        child: MaterialApp.router(routerConfig: router),
      );
      if (notice != null) {
        app = BlocProvider<NotificationStateCubit>.value(value: notice, child: app);
      }
      if (auth != null) {
        app = RepositoryProvider<AuthenticationRepository>.value(value: auth, child: app);
      }
      await tester.pumpWidget(TranslationProvider(child: app));
      await tester.pump();
    }

    /// Labels of the four entries in display order.
    List<String> labels() => [
      tr.navigation.homepage,
      tr.navigation.topics,
      tr.navigation.notice,
      tr.navigation.me,
    ];

    int drawerSelected(WidgetTester tester) =>
        tester.widget<NavigationDrawer>(find.byType(NavigationDrawer)).selectedIndex!;

    testWidgets('drawer: the four tabs in order, no "more" group', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpHome(tester, _Layout.desktop);

      expect(tr.navigation.topics, 'Forums');
      final drawer = find.byType(HomeNavigationDrawer);
      var previous = double.negativeInfinity;
      for (final label in labels()) {
        final text = find.descendant(of: drawer, matching: find.text(label));
        expect(text, findsOneWidget, reason: label);
        final y = tester.getTopLeft(text).dy;
        expect(y, greaterThan(previous), reason: '$label comes after the previous entry');
        previous = y;
      }
      expect(find.descendant(of: drawer, matching: find.byType(NavigationDrawerDestination)), findsNWidgets(4));
      expect(find.descendant(of: drawer, matching: find.text(tr.navigation.settings)), findsNothing);
      expect(drawerSelected(tester), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('drawer: every entry is a tab, selected at its index, the tab of the cubit follows', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final auth = AuthenticationRepository(user: _alice);
      addTearDown(auth.dispose);
      await pumpHome(tester, _Layout.desktop, auth: auth);

      for (final (i, tab) in HomeTab.values.indexed.toList().reversed) {
        now = now.add(const Duration(seconds: 1));
        await tester.tap(find.text(labels()[i]));
        await tester.pumpAndSettle();
        expect(location(), _tabPaths[i], reason: tab.name);
        expect(find.text('tab ${_tabPaths[i]}'), findsOneWidget);
        expect(cubit.state.tab, tab);
        expect(drawerSelected(tester), i);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('notifications without an account: the tab, which asks for a login itself', (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final auth = AuthenticationRepository();
      addTearDown(auth.dispose);
      await pumpHome(tester, _Layout.desktop, auth: auth);

      await tester.tap(find.text(tr.navigation.notice));
      await tester.pumpAndSettle();
      expect(location(), ScreenPaths.notice);
      expect(cubit.state.tab, HomeTab.notice);
    });

    testWidgets('rail: four entries, no overflow in a short window with 2x text, the "me" entry switches', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(700, 400)
        ..devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpHome(tester, _Layout.tablet);

      expect(tester.takeException(), isNull, reason: 'no vertical overflow');
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations, hasLength(4));
      expect(rail.selectedIndex, 0);

      final me = find.byIcon(Icons.person_outline);
      await tester.dragUntilVisible(me, find.byType(HomeNavigationRail), const Offset(0, -80));
      await tester.pumpAndSettle();
      await tester.tap(me);
      await tester.pumpAndSettle();
      expect(location(), ScreenPaths.me);
      expect(tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex, 3);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: the bottom bar has the four tabs and switches them', (tester) async {
      tester.view
        ..physicalSize = const Size(390, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpHome(tester, _Layout.phone);

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations, hasLength(4));
      expect(find.text(tr.navigation.settings), findsNothing);

      await tester.tap(find.text(tr.navigation.topics));
      await tester.pumpAndSettle();
      expect(location(), ScreenPaths.topic);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1);
      now = now.add(const Duration(seconds: 1));
      await tester.tap(find.text(tr.navigation.me));
      await tester.pumpAndSettle();
      expect(location(), ScreenPaths.me);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 3);
      expect(tester.takeException(), isNull);
    });

    group('unread count on the notifications entry', () {
      late AppDatabase db;
      late SettingsRepository settings;

      setUp(() async {
        db = AppDatabase(NativeDatabase.memory());
        final storage = StorageProvider(db, {}, {});
        settings = SettingsRepository(storage);
        getIt
          ..registerSingleton<StorageProvider>(storage)
          ..registerSingleton<SettingsRepository>(settings);
        await settings.init();
      });

      tearDown(() async {
        await getIt.reset();
        await settings.dispose();
        await db.close();
      });

      Future<NotificationStateCubit> unread(int notice, int pm, int broadcast) async {
        final info = NotificationInfoRepository();
        final cubit = NotificationStateCubit(info)
          ..setAll(noticeCount: notice, personalMessageCount: pm, broadcastMessageCount: broadcast);
        addTearDown(() async {
          await cubit.close();
          await info.dispose();
        });
        return cubit;
      }

      Finder countIn(int count) =>
          find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.text('$count'));

      Future<void> pumpDesktop(
        WidgetTester tester, {
        required UserLoginInfo? user,
        required bool hint,
        int notices = 2,
        int messages = 1,
      }) async {
        // The database is only used from the real zone: drift timers left in the fake zone never run.
        await tester.runAsync(() => settings.setValue(SettingsKeys.showUnreadInfoHint, hint));
        expect(settings.currentSettings.showUnreadInfoHint, hint);
        tester.view
          ..physicalSize = const Size(1280, 800)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final auth = AuthenticationRepository(user: user);
        addTearDown(auth.dispose);
        await pumpHome(tester, _Layout.desktop, auth: auth, notice: await unread(notices, messages, 0));
      }

      /// Let the drawer show a new state of the cubit. A cubit emits on a broadcast stream, so `BlocBuilder` hears it
      /// in a microtask. `pump()` without a scheduled frame only flushes microtasks at its end: the listener marks the
      /// builder dirty and schedules a frame then, which the next `pump()` draws.
      Future<void> showState(WidgetTester tester) async {
        await tester.pump();
        await tester.pump();
      }

      testWidgets('the real total of the notification state, with an account and the hint on', (tester) async {
        await pumpDesktop(tester, user: _alice, hint: true);
        expect(countIn(3), findsOneWidget);
        expect(find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.byType(Badge)), findsOneWidget);

        // Follows the state: read notices lower the count, nothing unread hides the badge.
        final notice = BlocProvider.of<NotificationStateCubit>(tester.element(find.byType(HomeNavigationDrawer)))
          ..decreaseNotice(2);
        expect(notice.state.total, 1);
        await showState(tester);
        expect(countIn(1), findsOneWidget);
        expect(countIn(3), findsNothing, reason: 'the old count is gone');
        expect(find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.byType(Badge)), findsOneWidget);
        notice.decreasePersonalMessage();
        expect(notice.state.total, 0);
        await showState(tester);
        expect(find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.byType(Badge)), findsNothing);
        expect(countIn(1), findsNothing);
      });

      testWidgets('no badge when the unread hint setting is off', (tester) async {
        await pumpDesktop(tester, user: _alice, hint: false);
        expect(find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.byType(Badge)), findsNothing);
        expect(countIn(3), findsNothing);
      });

      testWidgets('no badge without an account', (tester) async {
        await pumpDesktop(tester, user: null, hint: true);
        expect(find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.byType(Badge)), findsNothing);
      });

      testWidgets('no badge when nothing is unread', (tester) async {
        await pumpDesktop(tester, user: _alice, hint: true, notices: 0, messages: 0);
        expect(find.descendant(of: find.byType(HomeNavigationDrawer), matching: find.byType(Badge)), findsNothing);
        expect(countIn(0), findsNothing, reason: 'no "0" badge');
      });
    });
  });

  group('daily red packet entry', () {
    Future<void> pumpEntry(WidgetTester tester, Widget entry) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(body: Center(child: entry)),
          ),
        ),
      );
      await tester.pump();
    }

    Finder filledButtons() => find.byWidgetPredicate((w) => w is FilledButton);

    bool enabled(WidgetTester tester, Finder button) => tester.widget<ButtonStyleButton>(button).onPressed != null;

    Future<void> dispose(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    }

    testWidgets('claimable: a double tap sends one request, then the claimed state never submits again', (
      tester,
    ) async {
      final calls = <String>[];
      final answer = Completer<Either<AppException, DailyRedPacketResult>>();
      AsyncEither<DailyRedPacketResult> claim(String hash) {
        calls.add(hash);
        return TaskEither(() => answer.future);
      }

      await pumpEntry(
        tester,
        DailyRedPacketEntry(uid: 1000, config: _config, formHash: 'hash', onCheck: () {}, claim: claim),
      );
      final button = find.ancestor(of: find.text(tr.redPacket.daily.tooltip), matching: filledButtons());
      expect(button, findsOneWidget);
      expect(enabled(tester, button), isTrue);

      await tester.tap(button);
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      expect(calls, ['hash'], reason: 'one request for two quick taps');
      expect(enabled(tester, filledButtons()), isFalse, reason: 'disabled while the request runs');

      answer.complete(const Right(DailyRedPacketResult(ok: true, amount: '5', unit: 'coins')));
      await tester.pump();
      await tester.pump();
      final claimed = find.ancestor(of: find.text(tr.redPacket.daily.claimedToday), matching: filledButtons());
      expect(claimed, findsOneWidget);
      expect(enabled(tester, claimed), isFalse);

      await tester.tap(claimed, warnIfMissed: false);
      await tester.pump();
      expect(calls, hasLength(1));

      // Another account on the same page starts a new button: nothing of the claim above carries over.
      await pumpEntry(
        tester,
        DailyRedPacketEntry(uid: 2000, config: _config, formHash: 'hash', onCheck: () {}, claim: claim),
      );
      expect(find.text(tr.redPacket.daily.claimedToday), findsNothing, reason: 'another account claimed nothing');
      expect(
        enabled(tester, find.ancestor(of: find.text(tr.redPacket.daily.tooltip), matching: filledButtons())),
        isTrue,
      );
      expect(calls, hasLength(1));
      await dispose(tester);
    });

    testWidgets('"already claimed" from the server is the claimed state too', (tester) async {
      var calls = 0;
      await pumpEntry(
        tester,
        DailyRedPacketEntry(
          uid: 1000,
          config: _config,
          formHash: 'hash',
          onCheck: () {},
          claim: (_) {
            calls++;
            return TaskEither.right(const DailyRedPacketResult(ok: false, already: true));
          },
        ),
      );
      await tester.tap(find.text(tr.redPacket.daily.tooltip));
      await tester.pump();
      await tester.pump();
      expect(calls, 1);
      expect(find.text(tr.redPacket.daily.claimedToday), findsOneWidget);
      await dispose(tester);
    });

    testWidgets('a failed request keeps the packet claimable and records nothing', (tester) async {
      var calls = 0;
      await pumpEntry(
        tester,
        DailyRedPacketEntry(
          uid: 1000,
          config: _config,
          formHash: 'hash',
          onCheck: () {},
          claim: (_) {
            calls++;
            return TaskEither.left(HttpRequestFailedException(500));
          },
        ),
      );
      await tester.tap(find.text(tr.redPacket.daily.tooltip));
      await tester.pump();
      await tester.pump();
      expect(calls, 1);
      expect(find.text(tr.redPacket.daily.claimedToday), findsNothing);
      final button = find.ancestor(of: find.text(tr.redPacket.daily.tooltip), matching: filledButtons());
      expect(enabled(tester, button), isTrue, reason: 'the user can try again');
      await dispose(tester);
    });

    testWidgets('no packet on the homepage: "none now" with a packet check, never "claimed"', (tester) async {
      var refreshes = 0;
      await pumpEntry(
        tester,
        DailyRedPacketEntry(uid: 1000, config: null, formHash: 'hash', onCheck: () => refreshes++),
      );
      expect(find.text(tr.redPacket.daily.unavailable), findsOneWidget);
      expect(find.text(tr.redPacket.daily.claimedToday), findsNothing);
      expect(find.text(tr.redPacket.daily.tooltip), findsNothing, reason: 'nothing claimable is made up');
      await tester.tap(find.text(tr.redPacket.daily.unavailable));
      await tester.pump();
      expect(refreshes, 1);

      // A packet without a form hash cannot be claimed either.
      await pumpEntry(tester, DailyRedPacketEntry(uid: 1000, config: _config, formHash: '', onCheck: () {}));
      expect(find.text(tr.redPacket.daily.unavailable), findsOneWidget);
      await dispose(tester);
    });

    /// Claims [packet] on the entry, then shows the entry as the homepage does after a reload, which no longer offers
    /// the claimed packet. [onCheck] is the packet check of the "none now" button.
    Future<void> claimThenReloadWithoutPacket(
      WidgetTester tester,
      DailyRedPacketConfig packet,
      VoidCallback onCheck,
    ) async {
      await pumpEntry(
        tester,
        DailyRedPacketEntry(
          uid: 1000,
          config: packet,
          formHash: 'hash',
          onCheck: onCheck,
          claim: (_) => TaskEither.right(const DailyRedPacketResult(ok: true, amount: '5', unit: 'coins')),
        ),
      );
      await tester.tap(find.text(tr.redPacket.daily.tooltip));
      await tester.pump();
      await tester.pump();
      expect(find.text(tr.redPacket.daily.claimedToday), findsOneWidget);

      await pumpEntry(tester, DailyRedPacketEntry(uid: 1000, config: null, formHash: null, onCheck: onCheck));
    }

    // The claim record is the packet's `dateflag`, compared with the real calendar day (the entry has no clock to
    // inject), so both days are spelled out here instead of leaning on whatever day the suite happens to run: a fixed
    // "claimed" day would silently flip the expectation on the day the calendar reaches it.
    testWidgets('a reloaded page without a packet after a claim of an earlier day: none to claim, never "claimed"', (
      tester,
    ) async {
      // An explicit past day, not "yesterday": the test reads the same whenever it runs.
      var refreshes = 0;
      const earlier = DailyRedPacketConfig(entry: 2, dateFlag: '20200101', from: 'System', bless: 'Hi', unit: 'coins');
      await claimThenReloadWithoutPacket(tester, earlier, () => refreshes++);

      // That claim is not today's: the record says nothing about the packet of today, so the hint says it may be
      // claimed already and a tap checks the packet again.
      expect(find.text(tr.redPacket.daily.claimedToday), findsNothing);
      expect(find.byKey(const ValueKey('dailyRedPacket-recorded')), findsNothing);
      expect(find.text(tr.redPacket.daily.unavailable), findsOneWidget);
      expect(find.byTooltip(tr.redPacket.daily.unavailableHint), findsOneWidget);
      await tester.tap(find.text(tr.redPacket.daily.unavailable));
      await tester.pump();
      expect(refreshes, 1);
      await dispose(tester);
    });

    testWidgets('a reloaded page without a packet after a claim of today: "claimed", from the app\'s record', (
      tester,
    ) async {
      // Today's day is worked out here from the real clock, the one the entry compares with.
      var refreshes = 0;
      final today = DailyRedPacketConfig(
        entry: 2,
        dateFlag: dailyRedPacketDateFlag(DateTime.now()),
        from: 'System',
        bless: 'Hi',
        unit: 'coins',
      );
      await claimThenReloadWithoutPacket(tester, today, () => refreshes++);

      // Once claimed the page looks like a day without a packet; the app's own record keeps saying "claimed" for the
      // rest of that day, and says it is the record (the website is not asked).
      expect(find.byKey(const ValueKey('dailyRedPacket-recorded')), findsOneWidget);
      expect(find.text(tr.redPacket.daily.claimedToday), findsOneWidget);
      expect(find.byTooltip(tr.redPacket.daily.claimedRecordedHint), findsOneWidget);
      expect(find.text(tr.redPacket.daily.unavailable), findsNothing);
      expect(refreshes, 0);
      await dispose(tester);
    });

    testWidgets('without an account: says a login is needed', (tester) async {
      await pumpEntry(tester, DailyRedPacketEntry(uid: null, config: _config, formHash: 'hash', onCheck: () {}));
      expect(find.text(tr.redPacket.daily.needLogin), findsOneWidget);
      expect(find.text(tr.redPacket.daily.tooltip), findsNothing);
      await dispose(tester);
    });
  });

  group('greeting title badge', () {
    late StreamController<AuthStatus> auth;
    late CurrentTitleCubit cubit;
    late List<Completer<Either<AppException, List<SecondaryTitle>>>> pending;

    setUp(() {
      auth = StreamController<AuthStatus>.broadcast(sync: true);
      pending = [];
      cubit = CurrentTitleCubit(
        currentUid: () => _alice.uid,
        authStatus: auth.stream,
        fetchTitles: () => TaskEither(() {
          final completer = Completer<Either<AppException, List<SecondaryTitle>>>();
          pending.add(completer);
          return completer.future;
        }),
      );
      auth.add(const AuthStatusAuthed(_alice));
    });

    tearDown(() async {
      await cubit.close();
      await auth.close();
    });

    /// The greeting header in a [window], padded as in the card; [compact] for phones, [scale] for the text.
    Future<void> pumpHeader(
      WidgetTester tester, {
      required Size window,
      required bool compact,
      double scale = 1,
    }) async {
      tester.view
        ..physicalSize = window
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Page padding 12 and card padding 16 (phones) or 24 (wide) on each side, as on the homepage.
      final padding = compact ? 28.0 : 36.0;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: BlocProvider.value(
                value: cubit,
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(horizontal: padding, vertical: 16),
                  child: HomeGreetingHeader(
                    greeting: const Text('Good evening, Alice with a rather long name', key: ValueKey('greeting')),
                    uid: _alice.uid,
                    compact: compact,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    /// The title is read: the real badge widget. The workaround url is drawn without the image cache, so the box of the
    /// badge is measured without network or database.
    Future<void> completeTitle(WidgetTester tester) async {
      pending.single.complete(
        Right([SecondaryTitle(id: 1, name: 'T', imageUrl: tmpImpellerWorkaroundUrls.first, activated: true)]),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('desktop: the natural 184px wide, complete 184:100 box, beside the greeting', (tester) async {
      await pumpHeader(tester, window: const Size(1000, 600), compact: false);
      final expected = Size(184, SecondaryTitleBadge.heightFor(184));
      expect(tester.getSize(find.byType(SecondaryTitlePlaceholder)), expected, reason: 'room kept while loading');

      await completeTitle(tester);
      final badge = find.byType(SecondaryTitleBadge);
      expect(badge, findsOneWidget);
      expect(tester.getSize(badge), expected);
      expect(tester.getSize(badge).width / tester.getSize(badge).height, closeTo(184 / 100, 0.01));
      final greeting = tester.getRect(find.byKey(const ValueKey('greeting')));
      expect(tester.getRect(badge).left, greaterThan(greeting.right), reason: 'beside the greeting');
      expect(tester.getRect(badge).right, lessThanOrEqualTo(1000 - 36));
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone 412: 160 to 184px beside the greeting', (tester) async {
      await pumpHeader(tester, window: const Size(412, 800), compact: true);
      await completeTitle(tester);
      final size = tester.getSize(find.byType(SecondaryTitleBadge));
      expect(size.width, inInclusiveRange(160, 184));
      expect(size.height, closeTo(SecondaryTitleBadge.heightFor(size.width), 0.01));
      final greeting = tester.getRect(find.byKey(const ValueKey('greeting')));
      expect(tester.getRect(find.byType(SecondaryTitleBadge)).left, greaterThan(greeting.right));
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone 320 with 2x text: 160px below the greeting, nothing overflows', (tester) async {
      await pumpHeader(tester, window: const Size(320, 640), compact: true, scale: 2);
      await completeTitle(tester);
      expect(tester.takeException(), isNull);
      final badge = tester.getRect(find.byType(SecondaryTitleBadge));
      expect(badge.width, 160);
      expect(badge.height, closeTo(SecondaryTitleBadge.heightFor(160), 0.01));
      final greeting = tester.getRect(find.byKey(const ValueKey('greeting')));
      expect(badge.top, greaterThanOrEqualTo(greeting.bottom), reason: 'wrapped below the greeting');
      expect(badge.right, lessThanOrEqualTo(320 - 28));
      expect(badge.left, greeting.left, reason: 'the badge starts under the greeting, which keeps the whole width');
      expect(find.text('Good evening, Alice with a rather long name'), findsOneWidget);
    });
  });
}
