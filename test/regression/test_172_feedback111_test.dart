/// Feedback on preview 110 (PR #135) and issue #139.
///
/// 1. In landscape the expanded reply editor was narrower than the page (the Material 3 default of 640dp), so the
///    collapsed bar showed beside it as a second reply box; the sheet now spans the page. The grip above the editor
///    is gone: the collapse button is the one control closing it (#139).
/// 2. The homepage greeting shows "checked in" once this app recorded a check-in of the account today, and "claimed"
///    once it recorded a claim of the daily red packet today, instead of "check in" / "none" until the next attempt.
/// 3. The two badges of a floor author (user group, secondary title) are the same height, in the floor and in the
///    author dialog.
/// 4. Second round: a landscape phone is not a wide window, the homepage keeps its phone layout on Android and iOS at
///    any width; the theme mode switch of the settings page sits in one line with its title.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/checkin/widgets/checkin_button.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/view/homepage_page.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/utils/daily_red_packet_record.dart';
import 'package:tsdm_client/features/red_packet/widgets/daily_red_packet_button.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/settings_page.dart';
import 'package:tsdm_client/features/settings/widgets/support_development_dialog.dart';
import 'package:tsdm_client/features/theme/cubit/theme_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);

/// Authentication repository whose account the test sets.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  int? get effectiveCurrentUid => currentUser?.uid;

  Future<void> close() => _controller.close();
}

/// No network at all.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// A page like the thread page: the reply bar is the last child of the body column.
class _Host extends StatelessWidget {
  const _Host(this.controller);

  final ReplyBarController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: false,
    body: Column(
      children: [
        const Expanded(child: Center(child: Text('thread page'))),
        ReplyBar(controller: controller, replyType: ReplyTypes.thread),
      ],
    ),
  );
}

Translations get tr => LocaleSettings.instance.currentTranslations;

Future<void> _settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  group('1. reply editor', () {
    Future<void> pumpHost(WidgetTester tester, {required Size size, required EdgeInsets padding}) async {
      final controller = ReplyBarController();
      final auth = _Auth(_alice);
      // Open for replies, as a loaded thread tells its bar.
      final bloc = ReplyBloc(replyRepository: const ReplyRepository())..add(const ReplyThreadClosed(closed: false));
      addTearDown(() async {
        await bloc.close();
        await auth.close();
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        RepositoryProvider<AuthenticationRepository>.value(
          value: auth,
          child: BlocProvider<ReplyBloc>.value(
            value: bloc,
            child: TranslationProvider(
              child: MediaQuery(
                data: MediaQueryData(size: size, padding: padding, viewPadding: padding),
                child: MaterialApp(home: _Host(controller)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reply-bar-field')), findsOneWidget);
    }

    Finder grip() => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byWidgetPredicate((w) => w is SizedBox && w.width == 32 && w.height == 4),
    );

    for (final (name, size, padding) in [
      ('phone landscape with a cutout', const Size(792, 384), const EdgeInsets.only(left: 40, right: 40)),
      ('phone portrait', const Size(384, 792), const EdgeInsets.only(top: 40)),
      ('wide window', const Size(1400, 800), EdgeInsets.zero),
    ]) {
      testWidgets('$name: the editor spans the page like the bar, no grip above it', (tester) async {
        await pumpHost(tester, size: size, padding: padding);
        await tester.tap(find.byKey(const ValueKey('reply-bar-field')));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.unfold_less), findsOneWidget, reason: 'the editor is showing');
        final sheet = tester.getRect(find.byType(BottomSheet));
        expect((sheet.left, sheet.right), (0, size.width), reason: 'no strip of the collapsed bar beside the sheet');
        expect(grip(), findsNothing, reason: 'the collapse button is the one control closing the editor (#139)');
        // The editor and its buttons keep out of the side insets.
        final collapse = tester.getRect(find.byIcon(Icons.unfold_less));
        expect(collapse.left, greaterThanOrEqualTo(padding.left));
        expect(collapse.right, lessThanOrEqualTo(size.width - padding.right));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the collapse button still closes the editor and the bar is back', (tester) async {
      await pumpHost(tester, size: const Size(792, 384), padding: const EdgeInsets.only(left: 40, right: 40));
      await tester.tap(find.byKey(const ValueKey('reply-bar-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.unfold_less));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(const ValueKey('reply-bar-field')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('2. homepage check-in state', () {
    late _Auth auth;
    late CheckinBloc bloc;

    setUp(() async {
      auth = _Auth(_alice);
      for (final u in [_alice, _bob]) {
        await storage.saveCookie(
          username: u.username!,
          uid: u.uid!,
          cookie: {'.domains': '{"${u.username}":1}', '${cookiePrefix}_auth': u.username!.toLowerCase()},
        );
      }
      bloc = CheckinBloc(
        checkinRepository: CheckinRepository(storageProvider: storage),
        authenticationRepository: auth,
        settingsRepository: settings,
      );
    });

    tearDown(() async {
      await bloc.close();
      await auth.close();
    });

    Future<void> pumpButton(WidgetTester tester) async {
      await tester.pumpWidget(
        BlocProvider<CheckinBloc>.value(
          value: bloc,
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => CheckinButton(enableSnackBar: true, label: context.t.homepage.welcome.checkin),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Finder labeled(String text) =>
        find.ancestor(of: find.text(text), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));

    testWidgets('a check-in recorded today shows "checked in", disabled', (tester) async {
      await storage.updateLastCheckinTime(_alice.uid!, DateTime.now()).run();
      await pumpButton(tester);
      expect(labeled(tr.homepage.welcome.checkin), findsOneWidget, reason: 'nothing known before asking');

      bloc.add(const CheckinStatusRequested());
      await _settle(tester);
      expect(bloc.state, isA<CheckinStateChecked>());
      expect(labeled(tr.homepage.welcome.checkedIn), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(labeled(tr.homepage.welcome.checkedIn)).onPressed, isNull);
      expect(labeled(tr.homepage.welcome.checkin), findsNothing);
    });

    testWidgets('a check-in of yesterday, or none, keeps the check-in button', (tester) async {
      await storage.updateLastCheckinTime(_alice.uid!, DateTime.now().subtract(const Duration(days: 1))).run();
      await pumpButton(tester);
      bloc.add(const CheckinStatusRequested());
      await _settle(tester);
      expect(bloc.state, isA<CheckinStateInitial>());
      final button = labeled(tr.homepage.welcome.checkin);
      expect(button, findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(button).onPressed, isNotNull, reason: 'a tap asks the forum');
    });

    testWidgets('the record of one account is not shown for another', (tester) async {
      await storage.updateLastCheckinTime(_alice.uid!, DateTime.now()).run();
      await pumpButton(tester);
      bloc.add(const CheckinStatusRequested());
      await _settle(tester);
      expect(bloc.state, isA<CheckinStateChecked>());

      auth.currentUser = _bob;
      bloc.add(const CheckinStatusRequested());
      await _settle(tester);
      expect(bloc.state, isA<CheckinStateInitial>(), reason: 'Bob has no record');
      expect(labeled(tr.homepage.welcome.checkin), findsOneWidget);

      auth.currentUser = null;
      bloc.add(const CheckinStatusRequested());
      await _settle(tester);
      expect(bloc.state, isA<CheckinStateNeedLogin>());
    });
  });

  group('2. homepage daily red packet record', () {
    const config = DailyRedPacketConfig(entry: 2, dateFlag: '20260928', from: '', bless: '', unit: 'coins');
    final today = dailyRedPacketDateFlag(DateTime.now());

    Future<void> pumpEntry(
      WidgetTester tester, {
      required int? uid,
      DailyRedPacketConfig? packet,
      DailyRedPacketClaim? claim,
    }) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: DailyRedPacketEntry(
                uid: uid,
                config: packet,
                formHash: 'XXXXXXXX',
                onCheck: () {},
                claim: claim,
              ),
            ),
          ),
        ),
      );
      await _settle(tester, rounds: 3);
    }

    test('the date flag is the local calendar day, like the forum writes it', () {
      expect(dailyRedPacketDateFlag(DateTime(2026, 9, 28)), '20260928');
      expect(dailyRedPacketDateFlag(DateTime(2026, 1, 5)), '20260105');
      expect(dailyRedPacketClaimedToday('20260928', now: DateTime(2026, 9, 28, 23, 59)), isTrue);
      expect(dailyRedPacketClaimedToday('20260928', now: DateTime(2026, 9, 29)), isFalse);
      expect(dailyRedPacketClaimedToday(null, now: DateTime(2026, 9, 28)), isFalse);
      expect(dailyRedPacketClaimKey(1000), 'dailyRedPacketClaimed.1000');
    });

    testWidgets('no packet on the page and a claim recorded today: "claimed"', (tester) async {
      await storage.saveString(dailyRedPacketClaimKey(_alice.uid!), today);
      await pumpEntry(tester, uid: _alice.uid);
      expect(find.byKey(const ValueKey('dailyRedPacket-recorded')), findsOneWidget);
      expect(find.text(tr.redPacket.daily.claimedToday), findsOneWidget);
      expect(find.text(tr.redPacket.daily.unavailable), findsNothing);
    });

    testWidgets('a record of another day, or of another account, keeps "none now"', (tester) async {
      await storage.saveString(dailyRedPacketClaimKey(_alice.uid!), '20200101');
      await storage.saveString(dailyRedPacketClaimKey(_bob.uid!), today);
      await pumpEntry(tester, uid: _alice.uid);
      expect(find.text(tr.redPacket.daily.unavailable), findsOneWidget);
      expect(find.byKey(const ValueKey('dailyRedPacket-recorded')), findsNothing);
    });

    testWidgets('a packet on the page wins over the record', (tester) async {
      await storage.saveString(dailyRedPacketClaimKey(_alice.uid!), today);
      await pumpEntry(tester, uid: _alice.uid, packet: config);
      expect(find.text(tr.redPacket.daily.tooltip), findsOneWidget, reason: 'claimable');
      expect(find.byKey(const ValueKey('dailyRedPacket-recorded')), findsNothing);
    });

    testWidgets('a claim of this run is recorded for the account', (tester) async {
      var claims = 0;
      await pumpEntry(
        tester,
        uid: _alice.uid,
        packet: config,
        claim: (formHash) => AsyncEither(() async {
          claims++;
          return const Right(DailyRedPacketResult(ok: true, amount: '3', unit: 'coins'));
        }),
      );
      await tester.tap(find.text(tr.redPacket.daily.tooltip));
      await _settle(tester, rounds: 3);
      expect(claims, 1);
      expect(find.text(tr.redPacket.daily.claimedToday), findsOneWidget);
      expect(await storage.getString(dailyRedPacketClaimKey(_alice.uid!)), '20260928');
      expect(await storage.getString(dailyRedPacketClaimKey(_bob.uid!)), isNull);
    });

    testWidgets('"already claimed" from the server is recorded too', (tester) async {
      await pumpEntry(
        tester,
        uid: _alice.uid,
        packet: config,
        claim: (formHash) =>
            AsyncEither(() async => const Right(DailyRedPacketResult(ok: false, already: true, error: 'done'))),
      );
      await tester.tap(find.text(tr.redPacket.daily.tooltip));
      await _settle(tester, rounds: 3);
      expect(await storage.getString(dailyRedPacketClaimKey(_alice.uid!)), '20260928');
    });

    testWidgets('a failed claim records nothing', (tester) async {
      await pumpEntry(
        tester,
        uid: _alice.uid,
        packet: config,
        claim: (formHash) => AsyncEither(() async => const Right(DailyRedPacketResult(ok: false, error: 'nope'))),
      );
      await tester.tap(find.text(tr.redPacket.daily.tooltip));
      await _settle(tester, rounds: 3);
      expect(await storage.getString(dailyRedPacketClaimKey(_alice.uid!)), isNull);
      expect(find.text(tr.redPacket.daily.tooltip), findsOneWidget, reason: 'still claimable');
    });
  });

  group('3. author badges', () {
    test('the floor shows both badges the same height', () {
      expect(postAuthorSecondBadgeWidth(360), SecondaryTitleBadge.widthFor(authorBadgeHeight));
      expect(SecondaryTitleBadge.heightFor(postAuthorSecondBadgeWidth(360)), closeTo(authorBadgeHeight, 0.001));
      expect(postAuthorSecondBadgeWidth(40), 40, reason: 'a narrow floor never overflows');
      expect(SecondaryTitleBadge.widthFor(100), 184);
      expect(SecondaryTitleBadge.widthFor(50), 92);
    });
  });

  group('4. second round', () {
    // The settings page reads the database schema version and the image cache (debug section, avatar row); the
    // image cache is disposed by the getIt reset of the file.
    late SettingsBloc settingsBloc;
    late ThemeCubit theme;

    setUp(() {
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      theme = ThemeCubit();
      getIt
        ..registerSingleton<AppDatabase>(db)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
    });

    tearDown(() async {
      await settingsBloc.close();
      await theme.close();
    });

    test('phones keep the compact homepage at any width, desktop windows grow', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        for (final width in [360.0, 792.0, 1280.0, 1600.0]) {
          expect(homeLayoutFor(width, platform), HomeLayout.compact, reason: '$platform $width');
        }
      }
      for (final platform in [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
        expect(homeLayoutFor(500, platform), HomeLayout.compact, reason: '$platform narrow');
        expect(homeLayoutFor(700, platform), HomeLayout.medium, reason: '$platform medium');
        expect(homeLayoutFor(1280, platform), HomeLayout.wide, reason: '$platform wide');
      }
    });

    testWidgets('the greeting card of a landscape phone: compact, all four actions on one row, no overflow', (
      tester,
    ) async {
      final auth = _Auth(_alice);
      final checkin = CheckinBloc(
        checkinRepository: CheckinRepository(storageProvider: storage),
        authenticationRepository: auth,
        settingsRepository: settings,
      );
      addTearDown(() async {
        await checkin.close();
        await auth.close();
      });
      const size = Size(792, 384);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        BlocProvider<CheckinBloc>.value(
          value: checkin,
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: HomeGreetingCard(
                    username: 'Alice',
                    uid: _alice.uid,
                    forumStatus: const ForumStatus.empty(),
                    dailyRedPacket: null,
                    formHash: 'XXXXXXXX',
                    compact: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester, rounds: 3);
      final checkinRect = tester.getRect(find.text(tr.homepage.welcome.checkin));
      final packetRect = tester.getRect(find.text(tr.redPacket.daily.unavailable));
      final activitiesRect = tester.getRect(find.text(tr.activitiesPage.title));
      final medalsRect = tester.getRect(find.text(tr.medalTitleHub.title));
      expect(checkinRect.top, closeTo(packetRect.top, 1), reason: 'check-in and red packet on one row');
      expect(activitiesRect.top, closeTo(packetRect.top, 1), reason: 'activities on the same row (feedback 113)');
      expect(medalsRect.top, closeTo(packetRect.top, 1), reason: 'medals and titles on the same row');
      expect(medalsRect.right, lessThanOrEqualTo(size.width), reason: 'inside the card');
      expect(tester.getRect(find.byType(HomeGreetingCard)).height, lessThan(200), reason: 'one row of actions');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the greeting card of a portrait phone keeps two rows of actions', (tester) async {
      final auth = _Auth(_alice);
      final checkin = CheckinBloc(
        checkinRepository: CheckinRepository(storageProvider: storage),
        authenticationRepository: auth,
        settingsRepository: settings,
      );
      addTearDown(() async {
        await checkin.close();
        await auth.close();
      });
      tester.view.physicalSize = const Size(384, 792);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        BlocProvider<CheckinBloc>.value(
          value: checkin,
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: HomeGreetingCard(
                    username: 'Alice',
                    uid: _alice.uid,
                    forumStatus: const ForumStatus.empty(),
                    dailyRedPacket: null,
                    formHash: 'XXXXXXXX',
                    compact: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester, rounds: 3);
      final packetRect = tester.getRect(find.text(tr.redPacket.daily.unavailable));
      final activitiesRect = tester.getRect(find.text(tr.activitiesPage.title));
      expect(tester.getRect(find.text(tr.homepage.welcome.checkin)).top, closeTo(packetRect.top, 1));
      expect(activitiesRect.top, greaterThan(packetRect.bottom), reason: 'the entries wrap below on a portrait phone');
      expect(tester.takeException(), isNull);
    });

    Future<void> pumpSettings(WidgetTester tester, double width, double scale) async {
      tester.view.physicalSize = Size(width, 792);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(() {
        tester.view.reset();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<SettingsBloc>.value(value: settingsBloc),
            BlocProvider<ThemeCubit>.value(value: theme),
          ],
          child: TranslationProvider(child: const MaterialApp(home: SettingsPage())),
        ),
      );
      await _settle(tester, rounds: 3);
    }

    testWidgets('384dp phone: the theme mode switch is in one line with its title', (tester) async {
      await pumpSettings(tester, 384, 1);
      final title = tester.getRect(find.text(tr.settingsPage.appearanceSection.themeMode.title));
      final switcher = tester.getRect(find.byType(SegmentedButton<int>));
      expect(switcher.left, greaterThan(title.right), reason: 'at the end of the row, not below the text');
      expect(switcher.top, lessThan(title.bottom + 8), reason: 'in the same row');
      expect(switcher.right, lessThanOrEqualTo(384), reason: 'inside the window');
      expect(tester.takeException(), isNull);
    });

    // Feedback on 1.29.1: on a 360dp phone the title was squeezed into one character per line.
    for (final (width, scale) in [(320.0, 1.0), (360.0, 1.0), (384.0, 2.0), (360.0, 2.0)]) {
      testWidgets('${width}dp, ${scale}x text: the theme mode title stays on one line, the switch in the window', (
        tester,
      ) async {
        await pumpSettings(tester, width, scale);
        final titleFinder = find.text(tr.settingsPage.appearanceSection.themeMode.title);
        final title = tester.getRect(titleFinder);
        final lineHeight = tester.widget<Text>(titleFinder).style?.fontSize ?? 16;
        expect(title.height, lessThan(lineHeight * scale * 2), reason: 'one line, not one character per line');
        final switcher = tester.getRect(find.byType(SegmentedButton<int>));
        expect(switcher.right, lessThanOrEqualTo(width), reason: 'inside the window');
        expect(
          switcher.left >= title.right || switcher.top >= title.bottom,
          isTrue,
          reason: 'beside the text when it fits, below it otherwise; never over it',
        );
        expect(tester.takeException(), isNull);
      });
    }

    // The phone of the report is 360dp wide with a slightly larger system font; the test font is narrower than the
    // real one, so 320dp at 1.15x stands in for it.
    for (final (width, scale) in [(360.0, 1.0), (320.0, 1.15)]) {
      testWidgets('${width}dp, ${scale}x text: activities and medals share one row under check-in and red packet', (
        tester,
      ) async {
        final auth = _Auth(_alice);
        final checkin = CheckinBloc(
          checkinRepository: CheckinRepository(storageProvider: storage),
          authenticationRepository: auth,
          settingsRepository: settings,
        );
        addTearDown(() async {
          await checkin.close();
          await auth.close();
        });
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(() {
          tester.view.reset();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        await tester.pumpWidget(
          BlocProvider<CheckinBloc>.value(
            value: checkin,
            child: TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: HomeGreetingCard(
                      username: 'Alice',
                      uid: _alice.uid,
                      forumStatus: const ForumStatus.empty(),
                      dailyRedPacket: null,
                      formHash: 'XXXXXXXX',
                      compact: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await _settle(tester, rounds: 3);
        final packet = tester.getRect(find.text(tr.redPacket.daily.unavailable));
        final activities = tester.getRect(find.text(tr.activitiesPage.title));
        final medals = tester.getRect(find.text(tr.medalTitleHub.title));
        expect(activities.top, greaterThan(packet.bottom), reason: 'second row');
        expect(medals.center.dy, closeTo(activities.center.dy, 1), reason: 'the two entries on one row');
        expect(medals.right, lessThanOrEqualTo(width));
        expect(tester.takeException(), isNull);
      });
    }

    for (final width in [320.0, 360.0]) {
      testWidgets('${width}dp phone: the support dialog title and the GitHub button stay on one line', (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          TranslationProvider(
            child: const MaterialApp(home: Scaffold(body: SupportDevelopmentDialog())),
          ),
        );
        await _settle(tester, rounds: 3);
        final titleFinder = find.text(tr.aboutPage.supportDevelopment);
        final title = tester.getRect(titleFinder);
        final titleStyle = DefaultTextStyle.of(tester.element(titleFinder)).style;
        expect(title.height, lessThan((titleStyle.fontSize ?? 24) * 2), reason: 'the title is one line');
        final action = tester.getRect(find.text(tr.aboutPage.featureRequestAction));
        expect(action.height, lessThan(32), reason: 'the GitHub button label is one line');
        expect(tester.takeException(), isNull);
      });
    }
  });
}
