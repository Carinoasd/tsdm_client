import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/notification/utils/fetch_bound.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// GitHub #71: the lower bound of the next notification fetch comes from the forum's clock (the `Date` header of
/// the answer), not from the device. A device clock that runs ahead used to store a bound the forum had not reached
/// yet, and every message stamped in between was skipped by the next inclusive fetch.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

/// A logged-in notice page with nothing in it: the fetch succeeds with empty lists.
const _page = '<html><body><div id="um"></div><div class="nts"></div></body></html>';

Map<String, String> _jar(String token) => {
  '.index': '["$baseHost"]',
  baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=$token; Path=/;_crt=1"}}',
};

/// Answers every notification page with [_page]. With [serverTime] set, each answer carries a `Date` header that
/// starts there and moves one second forward per request, so the earliest one is the first request's.
final class _Adapter implements HttpClientAdapter {
  /// Forum clock of the next answer; null sends no `Date` header.
  DateTime? serverTime;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final index = requests.length;
    requests.add(options.uri);
    final date = serverTime?.add(Duration(seconds: index));
    return ResponseBody.fromString(
      _page,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        if (date != null) 'date': [HttpDate.format(date)],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('nextFetchBound', () {
    test('the forum clock wins over a device clock that runs ahead', () {
      final device = DateTime(2026, 9, 15, 10, 5, 30);
      final forum = DateTime(2026, 9, 15, 10, 0, 20).toUtc();
      final bound = nextFetchBound(startedAt: device, serverTime: forum);
      expect(bound, DateTime(2026, 9, 15, 9, 59));
      expect(bound.isBefore(device.truncateToMinute()), isTrue, reason: 'the device minute would skip 09:59-10:05');
    });

    test('a UTC header is truncated in local time and keeps one minute of margin', () {
      final bound = nextFetchBound(startedAt: DateTime.now(), serverTime: DateTime.utc(2026, 9, 15, 7, 30, 45));
      expect(bound.toUtc(), DateTime.utc(2026, 9, 15, 7, 29));
      expect(bound.isUtc, isFalse);
    });

    test('without a forum clock the device minute is used as before', () {
      final device = DateTime(2026, 9, 15, 10, 5, 30);
      expect(nextFetchBound(startedAt: device), DateTime(2026, 9, 15, 10, 5));
    });

    test('serverTimeOf reads the Date header and rejects a missing or broken one', () {
      expect(
        serverTimeOf(
          Headers.fromMap({
            'date': ['Tue, 15 Sep 2026 07:30:45 GMT'],
          }),
        ),
        DateTime.utc(2026, 9, 15, 7, 30, 45),
      );
      expect(serverTimeOf(Headers()), isNull);
      expect(
        serverTimeOf(
          Headers.fromMap({
            'date': ['yesterday'],
          }),
        ),
        isNull,
      );
    });

    test('earliestOf ignores unknown clocks', () {
      final a = DateTime.utc(2026, 9, 15, 7, 30);
      final b = a.add(const Duration(seconds: 2));
      expect(earliestOf([null, b, a]), a);
      expect(earliestOf([null, null]), isNull);
      expect(earliestOf(const []), isNull);
    });
  });

  group('stored bound', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late _Adapter adapter;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      adapter = _Adapter();
      Dio dio() => Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter;
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(() => NetClientProvider.build(dio: dio()))
        ..registerSingleton<CookieProvider>(CookieProvider(_alice, _jar('alice')));
      await settings.init();
      await storage.saveCookie(username: _alice.username!, uid: _alice.uid!, cookie: _jar('alice'));
    });

    tearDown(() async {
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    Future<DateTime?> stored() async =>
        (await storage.fetchLastFetchNoticeTime(_alice.uid!).run()).getOrElse((_) => null);

    test('the repository reports the earliest Date of the three pages, null without the header', () async {
      final forum = DateTime.utc(2026, 9, 15, 7, 30, 45);
      adapter.serverTime = forum;
      final client = NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
        cookie: CookieProvider.buildEmpty(),
      );
      final withDate = await NotificationRepository().fetchNotificationWith(client).run();
      expect(withDate.isRight(), isTrue, reason: '$withDate');
      expect(withDate.getOrElse((_) => throw StateError('unreachable')).serverTime, forum);
      expect(adapter.requests, hasLength(3));

      adapter.serverTime = null;
      final withoutDate = await NotificationRepository().fetchNotificationWith(client).run();
      expect(withoutDate.getOrElse((_) => throw StateError('unreachable')).serverTime, isNull);
    });

    Future<void> oneAutoFetch(AutoNotificationCubit auto) async {
      final pending = auto.stream.firstWhere((s) => s is AutoNoticeStatePending);
      auto.start(const Duration(seconds: 1));
      await pending.timeout(const Duration(seconds: 5));
      await auto.stream.firstWhere((s) => s is AutoNoticeStateTicking).timeout(const Duration(seconds: 5));
    }

    test('one auto fetch stores the forum clock minus one minute when the device clock runs ahead', () async {
      // The forum answers five minutes behind this device.
      final forum = DateTime.now().subtract(const Duration(minutes: 5));
      adapter.serverTime = forum;
      final auto = AutoNotificationCubit(
        authenticationRepository: AuthenticationRepository(user: _alice),
        notificationRepository: NotificationRepository(),
        storageProvider: storage,
      );
      await oneAutoFetch(auto);
      auto.stop();
      await auto.close();
      final bound = await stored();
      expect(bound, forum.truncateToMinute().subtract(const Duration(minutes: 1)));
      expect(
        bound!.isBefore(DateTime.now().truncateToMinute().subtract(const Duration(minutes: 3))),
        isTrue,
        reason: 'the device minute would have skipped everything the forum stamps in the next five minutes',
      );
    });

    test('one auto fetch without a Date header stores the device minute as before', () async {
      final auto = AutoNotificationCubit(
        authenticationRepository: AuthenticationRepository(user: _alice),
        notificationRepository: NotificationRepository(),
        storageProvider: storage,
      );
      final before = DateTime.now().truncateToMinute();
      await oneAutoFetch(auto);
      auto.stop();
      await auto.close();
      final bound = await stored();
      expect(bound, isNotNull);
      expect(bound!.isBefore(before), isFalse);
      expect(bound.isAfter(DateTime.now()), isFalse);
      expect(bound.second, 0);
    });

    test('the sync of all accounts stores the same forum-based bound', () async {
      final forum = DateTime.now().subtract(const Duration(minutes: 5));
      adapter.serverTime = forum;
      final repo = NotificationSyncAllRepository(
        storageProvider: storage,
        notificationRepository: NotificationRepository(),
        clientFactory: (cookie) => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
          cookie: cookie,
        ),
        gap: Duration.zero,
      );
      final result = await repo.syncAll(accounts: [_alice]).run();
      expect(result.isRight(), isTrue, reason: '$result');
      await repo.dispose();
      expect(await stored(), forum.truncateToMinute().subtract(const Duration(minutes: 1)));
    });
  });
}
