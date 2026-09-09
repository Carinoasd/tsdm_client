import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/checkin/bloc/auto_checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/repository/auto_checkin_repository.dart';
import 'package:tsdm_client/features/checkin/utils/checkin_day.dart';
import 'package:tsdm_client/features/multi_user/view/manage_account_page.dart';
import 'package:tsdm_client/features/notification/bloc/notification_sync_all_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
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

/// Issue #9: the manage accounts page tells for every account whether it checked in today, from the last check-in
/// time saved per account, and why an account did not when the auto check-in of this run failed for it.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);

const _signPage =
    '<html><body><div id="um"><a href="home.php?mod=space&amp;uid=1000">Alice</a></div> '
    '<form id="qiandao" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /></form></body></html>';
const _guestPage =
    '<html><body><form id="lsform" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /> '
    '<input name="username" /></form></body></html>';

/// Bob's sign page: he already checked in today from somewhere else.
const _alreadyPage =
    '<html><body><div id="um"><a href="home.php?mod=space&amp;uid=1001">Bob</a></div> '
    '<h1 class="mt">您今天已经签到过了</h1></body></html>';
const _successXml =
    '<?xml version="1.0" encoding="utf-8"?>\n<root><![CDATA[<div class="c">恭喜你签到成功!获得随机奖励 天使币 10 .</div> '
    '<script type="text/javascript" reload="1">hideWindow("qwindow");</script>]]></root>';

/// Answers requests from a script in order, each after [delay]; records when every request arrived.
final class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.script, {this.delay = Duration.zero});

  final List<(int, String)> script;
  final Duration delay;
  final arrived = <DateTime>[];
  var _next = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_next >= script.length) {
      fail('unexpected request #${_next + 1}: ${options.uri}');
    }
    arrived.add(DateTime.now());
    final (status, body) = script[_next++];
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Never answers: avatars are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
    for (final u in [_alice, _bob]) {
      await storage.saveCookie(
        username: u.username!,
        uid: u.uid!,
        cookie: {'.domains': '{"${u.username}":1}', 'Ystv_2132_auth': u.username!.toLowerCase()},
      );
    }
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  group('isCheckedInToday', () {
    final now = DateTime(2026, 9, 9, 8, 30);

    test('never checked in', () => expect(isCheckedInToday(null, now: now), isFalse));
    test('same instant', () => expect(isCheckedInToday(now, now: now), isTrue));
    test('midnight of today', () => expect(isCheckedInToday(DateTime(2026, 9, 9), now: now), isTrue));
    test('later today', () => expect(isCheckedInToday(DateTime(2026, 9, 9, 23, 59, 59), now: now), isTrue));
    test('one second before today', () {
      expect(isCheckedInToday(DateTime(2026, 9, 8, 23, 59, 59), now: now), isFalse);
    });
    test('month boundary', () {
      expect(isCheckedInToday(DateTime(2026, 8, 31, 23, 59), now: DateTime(2026, 9, 1, 0, 1)), isFalse);
    });
    test('year boundary', () {
      expect(isCheckedInToday(DateTime(2025, 12, 31, 23, 59), now: DateTime(2026, 1, 1, 0, 1)), isFalse);
    });
    test('another day of the same month with a smaller day number', () {
      // The old inline comparison only looked at "now.day > last.day"; the day of month is not enough on its own.
      expect(isCheckedInToday(DateTime(2026, 8, 20), now: DateTime(2026, 9, 5)), isFalse);
    });
    test('a check-in on a later day than now (clock moved back) is not today', () {
      expect(isCheckedInToday(DateTime(2026, 9, 10), now: now), isFalse);
    });
  });

  test('allUsersWithTimeStream emits the accounts with their last check-in and again after an update', () async {
    final seen = <List<(UserLoginInfo, DateTime?)>>[];
    final sub = storage.allUsersWithTimeStream().listen(seen.add);
    // The first emission is the current table.
    while (seen.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(seen.last.map((e) => (e.$1.uid, e.$2)), [(1000, null), (1001, null)]);

    final now = DateTime(2026, 9, 9, 8, 30);
    await storage.updateLastCheckinTime(1000, now).run();
    while (seen.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await sub.cancel();
    final alice = seen.last.singleWhere((e) => e.$1.uid == 1000);
    expect(alice.$2, now);
    expect(seen.last.singleWhere((e) => e.$1.uid == 1001).$2, isNull);
  });

  // One adapter for the whole run: every account gets its own client, the script continues across them.
  AutoCheckinRepository repoWith(_ScriptedAdapter adapter) {
    return AutoCheckinRepository(
      storageProvider: storage,
      clientFactory: (cookie) => NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
        cookie: cookie,
      ),
      gap: Duration.zero,
      retryDelays: const [Duration.zero],
    );
  }

  AutoCheckinRepository repo(List<(int, String)> script) => repoWith(_ScriptedAdapter(script));

  test('the repository records the check-in time of an account as soon as it succeeded', () async {
    final r = repo([
      // Alice succeeds, Bob's session is gone.
      (200, _signPage),
      (200, _successXml),
      (200, _guestPage),
    ]);
    final seen = <AutoCheckinInfo>[];
    final sub = r.status.listen(seen.add);
    final result = await r
        .checkinAll(waitingList: [_alice, _bob], skippedList: const [], feeling: CheckinFeeling.happy, message: 'hi')
        .run();
    expect(result.isRight(), isTrue, reason: '$result');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    await r.dispose();
    expect(seen.last.succeeded.map((e) => e.$1.uid), [1000]);
    expect(seen.last.failed.map((e) => (e.$1.uid, e.$2.runtimeType.toString())), [
      (1001, 'CheckinResultNotAuthorized'),
    ]);

    final times = {for (final (u, t) in await storage.getAllUsersWithTime()) u.uid: t};
    expect(times[1000], isNotNull, reason: 'the repository itself writes the time, not only the bloc');
    expect(isCheckedInToday(times[1000]), isTrue);
    expect(times[1001], isNull, reason: 'a failed account keeps no check-in time');
  });

  test('the time of an account stays the moment it checked in when the batch ends later', () async {
    // Alice succeeds, Bob already checked in elsewhere today; every answer takes a while so the batch ends well after
    // Alice finished (across midnight in the real case).
    final adapter = _ScriptedAdapter([
      (200, _signPage),
      (200, _successXml),
      (200, _alreadyPage),
    ], delay: const Duration(milliseconds: 40));
    final bloc = AutoCheckinBloc(
      autoCheckinRepository: repoWith(adapter),
      settingsRepository: settings,
      storageProvider: storage,
    )..add(const AutoCheckinStartRequested());
    final finished =
        await bloc.stream.firstWhere((s) => s is AutoCheckinStateFinished).timeout(const Duration(seconds: 10))
            as AutoCheckinStateFinished;
    await bloc.close();
    expect(finished.succeeded.map((e) => e.$1.uid), [1000]);
    expect(finished.failed.map((e) => (e.$1.uid, e.$2.runtimeType.toString())), [
      (1001, 'CheckinResultAlreadyChecked'),
    ]);

    final times = {for (final (u, t) in await storage.getAllUsersWithTime()) u.uid: t};
    expect(adapter.arrived, hasLength(3));
    final bobStarted = adapter.arrived[2];
    expect(
      times[1000]!.isAfter(bobStarted),
      isFalse,
      reason: 'Alice checked in before Bob started; the bloc used to stamp her with the batch end',
    );
    expect(times[1001], isNotNull, reason: '"already checked in" is recorded as checked in today');
    expect(times[1001]!.isBefore(times[1000]!), isFalse);
  });

  testWidgets('the manage accounts page shows who checked in today and why the others did not', (tester) async {
    getIt.registerSingleton<ImageCacheProvider>(
      ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
    );
    final auth = AuthenticationRepository(user: _alice);
    // Built and run inside runAsync: a bloc created in the test's fake-async zone would never process its events
    // while a real future is awaited, and a wait inside runAsync can not be interrupted by the test timeout.
    final bloc = (await tester.runAsync(() async {
      final bloc = AutoCheckinBloc(
        autoCheckinRepository: repo([
          (200, _signPage),
          (200, _successXml),
          (200, _guestPage),
        ]),
        settingsRepository: settings,
        storageProvider: storage,
      )..add(const AutoCheckinStartRequested());
      await bloc.stream.firstWhere((s) => s is AutoCheckinStateFinished).timeout(const Duration(seconds: 10));
      return bloc;
    }))!;
    addTearDown(() async {
      await bloc.close();
      await auth.dispose();
      await getIt.get<ImageCacheProvider>().dispose();
    });
    expect(bloc.state, isA<AutoCheckinStateFinished>());

    await tester.runAsync(() async {
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: BlocProvider<AutoCheckinBloc>.value(
              value: bloc,
              // The sync-all button in the app bar reads this cubit; a fresh, idle one is enough here.
              child: BlocProvider<NotificationSyncAllCubit>(
                create: (_) => NotificationSyncAllCubit(
                  repository: NotificationSyncAllRepository(
                    storageProvider: storage,
                    notificationRepository: NotificationRepository(),
                  ),
                  storageProvider: storage,
                  authenticationRepository: auth,
                  infoRepository: NotificationInfoRepository(),
                ),
                child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: const ManageAccountPage()),
              ),
            ),
          ),
        ),
      );
      // Let the storage stream deliver the accounts.
      for (var i = 0; i < 50 && find.text('Alice').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Checked in today'), findsOneWidget);
    expect(find.text('Not checked in today'), findsOneWidget);
    // Bob's session expired: the reason comes from the auto check-in result of this run.
    expect(find.text(tester.element(find.text('Bob')).t.profilePage.checkin.failedNotAuthorized), findsOneWidget);
    expect(find.text('Online'), findsOneWidget, reason: 'the online chip stays in the trailing slot');

    // Dispose the tree here and let the stream close timers fire before the framework checks for pending timers.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
