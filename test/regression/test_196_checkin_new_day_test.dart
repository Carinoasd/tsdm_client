import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/checkin/utils/checkin_day.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/hour_ticker.dart';

/// 2026-10-10 report: a desktop app left open overnight showed the date of yesterday and "checked in" on the
/// homepage at 01:52, while the website offered the check-in form (the account had not checked in that day).
///
/// The check-in of the day before ended in a state ("already checked in") that the status request did not reset at a
/// new day, the date line was only built with the page, and the auto check-in only ran when the app started.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

const _alreadyPage =
    '<html><body><div id="um"><a href="home.php?mod=space&amp;uid=1000">Alice</a></div> '
    '<h1 class="mt">您今天已经签到过了</h1></body></html>';

final class _Pages implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    _alreadyPage,
    200,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=utf-8'],
    },
  );

  @override
  void close({bool force = false}) {}
}

final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  Future<void> close() => _controller.close();
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('day boundaries', () {
    test('before 1:00 the next boundary is check-in opening', () {
      expect(nextCheckinDayBoundary(DateTime(2026, 10, 10, 0, 30)), DateTime(2026, 10, 10, 1, 0, 30));
    });
    test('right after midnight the next boundary is still the opening', () {
      expect(nextCheckinDayBoundary(DateTime(2026, 10, 10, 0, 0, 10)), DateTime(2026, 10, 10, 1, 0, 30));
    });
    test('during the day the next boundary is the next midnight', () {
      expect(nextCheckinDayBoundary(DateTime(2026, 10, 9, 22)), DateTime(2026, 10, 10, 0, 0, 5));
    });
    test('month end', () {
      expect(nextCheckinDayBoundary(DateTime(2026, 10, 31, 23, 59)), DateTime(2026, 11, 1, 0, 0, 5));
    });
  });

  group('auto check-in of a running app', () {
    final morning = DateTime(2026, 10, 10, 1, 0, 30);
    test('not before check-in opens', () => expect(autoCheckinDue(null, DateTime(2026, 10, 10, 0, 40)), isFalse));
    test('ran yesterday: due at opening', () => expect(autoCheckinDue(DateTime(2026, 10, 9, 10, 17), morning), isTrue));
    test('ran today after opening: not again', () {
      expect(autoCheckinDue(DateTime(2026, 10, 10, 1, 0, 31), DateTime(2026, 10, 10, 9)), isFalse);
    });
    test('ran today before opening (got "not open yet"): due', () {
      expect(autoCheckinDue(DateTime(2026, 10, 10, 0, 20), morning), isTrue);
    });
    test('not started in this run: due', () => expect(autoCheckinDue(null, morning), isTrue));
  });

  group('check-in button state at a new day', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;

    setUp(() async {
      TsdmAppApi.markUnavailable();
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _Pages()),
        );
      await settings.init();
      await storage.saveCookie(
        username: _alice.username!,
        uid: _alice.uid!,
        cookie: {'.domains': '{"Alice":1}', 'Ystv_2132_auth': 'alice'},
      );
    });

    tearDown(() async {
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    test('"already checked in" of yesterday is reset when the day changed', () async {
      final auth = _Auth(_alice);
      final bloc = CheckinBloc(
        checkinRepository: CheckinRepository(storageProvider: storage),
        authenticationRepository: auth,
        settingsRepository: settings,
      );
      addTearDown(() async {
        await bloc.close();
        await auth.close();
      });

      bloc.add(const CheckinRequested());
      await bloc.stream.firstWhere((s) => s is CheckinStateFailed);
      expect((bloc.state as CheckinStateFailed).result, isA<CheckinResultAlreadyChecked>());

      // The app kept running into the next day: the record is of yesterday now.
      await storage.updateLastCheckinTime(_alice.uid!, DateTime.now().subtract(const Duration(days: 1))).run();
      bloc.add(const CheckinStatusRequested());
      await bloc.stream.firstWhere((s) => s is CheckinStateInitial);
    });
  });

  testWidgets('the homepage date follows the clock: rebuilt at the next full hour', (tester) async {
    var now = DateTime(2026, 10, 9, 23, 59, 30);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: HourTicker(clock: () => now, builder: (_, t) => Text('${t.month}/${t.day} ${t.hour}h')),
      ),
    );
    expect(find.text('10/9 23h'), findsOneWidget);
    now = DateTime(2026, 10, 10, 0, 0, 1);
    await tester.pump(const Duration(seconds: 31));
    expect(find.text('10/10 0h'), findsOneWidget);
    // The next tick is armed again.
    now = DateTime(2026, 10, 10, 1, 0, 1);
    await tester.pump(const Duration(hours: 1));
    expect(find.text('10/10 1h'), findsOneWidget);
  });
}
