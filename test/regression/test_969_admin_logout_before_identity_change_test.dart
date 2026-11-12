/// The admin token is ended before the account in use changes (`AuthenticationRepository.beforeIdentityChange`, set to
/// `AdminRepository.logoutBeforeIdentityChange` by the app): run while the cookie and the settings still name the
/// account the token belongs to (the forum ends a token only for its own account), for a switch and a removal; not
/// for a switch that does not happen or one to the account in use; only forgotten (nothing sent) when a logout finds
/// the forum's session gone already.
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);

String _loggedPage(UserLoginInfo user) =>
    '<div id="inner_stat"><strong><a href="home.php?uid=${user.uid}">${user.username}</a></strong></div>';

Map<String, String> _cookieOf(UserLoginInfo user) => {
  '.domains': '{"${user.username}":1}',
  'Ystv_2132_auth': user.username!.toLowerCase(),
};

/// Answers every request with [body].
final class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter(this.body);

  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    body,
    200,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=utf-8'],
    },
  );

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
    TsdmAppApi.markUnavailable();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
  });

  tearDown(() async {
    AuthenticationRepository.beforeIdentityChange = null;
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  test('run as the account in use, before a switch and before a removal; never for a switch refused', () async {
    for (final u in [_alice, _bob]) {
      await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: _cookieOf(u));
    }
    await settings.setValue<int>(SettingsKeys.loginUid, 1000);
    await settings.setValue<String>(SettingsKeys.loginUsername, 'Alice');
    getIt.registerSingleton<CookieProvider>(CookieProvider(_alice, _cookieOf(_alice)));

    // What the admin logout would send as: the account in use (the settings) and the cookie's account.
    final seen = <(int, int?, bool)>[];
    AuthenticationRepository.beforeIdentityChange = ({required canSend}) async =>
        seen.add((currentLoginUid(), getIt.get<CookieProvider>().userLoginInfo.uid, canSend));

    var page = _loggedPage(_alice);
    final auth = AuthenticationRepository(
      user: _alice,
      clientFactory: (cookie) => NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _FixedAdapter(page),
        cookie: cookie,
      ),
    );
    addTearDown(auth.dispose);

    // The saved login of Bob answers as Alice: no switch, nothing ended.
    final refused = await auth.switchUser(_bob).run();
    expect(refused.isLeft(), isTrue);
    expect(seen, isEmpty);

    // The account in use again: what is bound to it stays.
    final same = await auth.switchUser(_alice).run();
    expect(same.isRight(), isTrue, reason: '$same');
    expect(seen, isEmpty);

    page = _loggedPage(_bob);
    final switched = await auth.switchUser(_bob).run();
    expect(switched.isRight(), isTrue, reason: '$switched');
    expect(seen, [(1000, 1000, true)]);
    expect(currentLoginUid(), 1001);

    final forgot = await auth.forgetCurrentUser().run();
    expect(forgot.isRight(), isTrue, reason: '$forgot');
    expect(seen, [(1000, 1000, true), (1001, 1001, true)]);
  });

  test('a hook that fails changes nothing', () async {
    await storage.saveCookie(username: 'Alice', uid: 1000, cookie: _cookieOf(_alice));
    await settings.setValue<int>(SettingsKeys.loginUid, 1000);
    await settings.setValue<String>(SettingsKeys.loginUsername, 'Alice');
    getIt.registerSingleton<CookieProvider>(CookieProvider(_alice, _cookieOf(_alice)));
    AuthenticationRepository.beforeIdentityChange = ({required canSend}) async => throw Exception('no network');
    final auth = AuthenticationRepository(
      user: _alice,
      clientFactory: (cookie) => NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _FixedAdapter(_loggedPage(_alice)),
        cookie: cookie,
      ),
    );
    addTearDown(auth.dispose);
    final forgot = await auth.forgetCurrentUser().run();
    expect(forgot.isRight(), isTrue, reason: '$forgot');
    expect(auth.currentUser, isNull);
  });

  test('a logout finding the session gone already only forgets, sends nothing', () async {
    await storage.saveCookie(username: 'Alice', uid: 1000, cookie: _cookieOf(_alice));
    await settings.setValue<int>(SettingsKeys.loginUid, 1000);
    await settings.setValue<String>(SettingsKeys.loginUsername, 'Alice');
    getIt.registerSingleton<CookieProvider>(CookieProvider(_alice, _cookieOf(_alice)));
    final seen = <bool>[];
    AuthenticationRepository.beforeIdentityChange = ({required canSend}) async => seen.add(canSend);
    final auth = AuthenticationRepository(
      user: _alice,
      clientFactory: (cookie) => NetClientProvider.buildNoCookie(
        // The guest's page: the login form, no user.
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _FixedAdapter('<form id="lsform"></form>'),
        cookie: cookie,
      ),
    );
    addTearDown(auth.dispose);
    final out = await auth.logout().run();
    expect(out.isRight(), isTrue, reason: '$out');
    expect(seen, [false]);
  });
}
