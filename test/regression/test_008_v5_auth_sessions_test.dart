import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

void main() {
  const alice = UserLoginInfo(username: 'Alice', uid: 1);
  const bob = UserLoginInfo(username: 'Bob', uid: 2);
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late CookieProvider current;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    current = CookieProvider(alice, {'marker': 'Alice'});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<CookieProvider>(current)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
    await settings.setValue<String>(SettingsKeys.loginUsername, 'Alice');
    await settings.setValue<int>(SettingsKeys.loginUid, 1);
    await storage.saveCookie(username: 'Alice', uid: 1, cookie: {'marker': 'Alice'});
    await storage.saveCookie(username: 'Bob', uid: 2, cookie: {'marker': 'Bob'});
  });
  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  NetClientProvider client(CookieProvider cookie, String body, {int status = 200}) {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(Response<String>(requestOptions: options, data: body, statusCode: status));
          },
        ),
      );
    return NetClientProvider.buildNoCookie(dio: dio, cookie: cookie);
  }

  for (final scenario in [
    (name: 'guest response', status: 200, body: '<div>Please log in</div>', success: false),
    (
      name: 'wrong uid',
      status: 200,
      body: '<div id="inner_stat"><strong><a href="home.php?uid=3">Other</a></strong></div>',
      success: false,
    ),
    (name: 'server error', status: 503, body: '<div>Unavailable</div>', success: false),
    (
      name: 'verified account',
      status: 200,
      body: '<div id="inner_stat"><strong><a href="home.php?uid=2">Bob</a></strong></div>',
      success: true,
    ),
  ]) {
    test('switch account: ${scenario.name}', () async {
      final repo = AuthenticationRepository(
        user: alice,
        clientFactory: (cookie) {
          expect(identical(cookie, current), isFalse);
          return client(cookie, scenario.body, status: scenario.status);
        },
      );
      addTearDown(repo.dispose);
      final result = await repo.switchUser(bob).run();
      expect(result.isRight(), scenario.success);
      expect(repo.currentUser?.uid, scenario.success ? 2 : 1);
      expect(settings.currentSettings.loginUid, scenario.success ? 2 : 1);
      expect(await current.read('marker'), scenario.success ? 'Bob' : 'Alice');
    });
  }

  for (final success in [false, true]) {
    test('password login ${success ? 'commits the new session' : 'keeps the current account on failure'}', () async {
      final repo = AuthenticationRepository(
        user: alice,
        clientFactory: (cookie) {
          final dio = Dio()
            ..interceptors.add(
              InterceptorsWrapper(
                onRequest: (options, handler) async {
                  final String response;
                  if (options.method == 'POST') {
                    expect((options.data as Map)['formhash'], 'newhash');
                    expect(await cookie.read('marker'), 'new-session');
                    response = success
                        ? "succeedhandle_login('url', 'ok', {'username':'Bob','uid':'2'});"
                        : "errorhandle_login('密码有误', {});";
                  } else {
                    await cookie.write('marker', 'new-session');
                    response = '<div id="layer_login_login"><input name="formhash" value="newhash"></div>';
                  }
                  handler.resolve(Response<String>(requestOptions: options, data: response, statusCode: 200));
                },
              ),
            );
          return NetClientProvider.buildNoCookie(dio: dio, cookie: cookie);
        },
      );
      addTearDown(repo.dispose);
      final result = await repo
          .loginWithPassword(
            const UserCredential(
              loginField: LoginField.username,
              loginFieldValue: 'Bob',
              password: 'test',
              tsdmVerify: '',
            ),
          )
          .run();
      expect(result.isRight(), success);
      expect(repo.currentUser?.uid, success ? 2 : 1);
      expect(settings.currentSettings.loginUid, success ? 2 : 1);
      expect(await current.read('marker'), success ? 'new-session' : 'Alice');
    });
  }
}
