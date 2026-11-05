/// The cross-device sync asks the forum as the account in use at each call.
///
/// A `NetClientProvider` is bound to the account it was built for: once the global cookie names another account (a
/// login on a fresh install, a switch), its requests and answers are dropped (`IdentityChangedException`). The sync
/// built one client at the start, so on a fresh install every pull and push after the login was dropped
/// ("sync: pull failed: no answer") until the app was started again; the same after a switch of account.
///
/// Now `TsdmAppSyncApi` builds the client at each call.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// A forum answering every `sync` call with an empty document of the account named by the request's cookie.
final class _Forum implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancel) async {
    requests.add(options);
    if (options.uri.path != '/plugin.php' || options.uri.queryParameters['action'] != 'sync') {
      return ResponseBody.fromString('unexpected', 404);
    }
    final body = jsonEncode({
      'ok': 1,
      'api': 1,
      'uid': 35,
      'formhash': 'abcd1234',
      'supported': 1,
      'max_bytes': 65536,
      'updated': 0,
      'data': null,
    });
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _baseUrl = 'https://www.example.test';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  late AppDatabase db;
  late CookieProvider cookie;
  late _Forum forum;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    final settings = SettingsRepository(storage);
    cookie = CookieProvider.buildEmpty();
    forum = _Forum();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(cookie)
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver());
    await settings.init();
    addTearDown(() async {
      await settings.dispose();
      await getIt.reset();
      await db.close();
    });
  });

  NetClientProvider client() =>
      NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: _baseUrl))..httpClientAdapter = forum);

  test('a client built as the guest is dropped once an account logged in: the start-built client of before', () async {
    final once = client();
    final api = TsdmAppSyncApi(() => once);
    expect(await api.pull(), isA<SyncPulled>(), reason: 'as the guest the call goes out');

    // The login on a fresh install: the global cookie names the account now.
    await cookie.updateUserInfo(const UserLoginInfo(username: 'ag_low2', uid: 35));

    expect(await api.pull(), isA<SyncPullFailed>(), reason: 'the guest client is another account\'s now');
    expect(forum.requests, hasLength(1), reason: 'the dropped call never reached the forum');
  });

  test('the api builds its client at each call, so the call after a login goes out as the account', () async {
    var built = 0;
    final api = TsdmAppSyncApi(() {
      built++;
      return client();
    });
    expect(await api.pull(), isA<SyncPulled>());

    await cookie.updateUserInfo(const UserLoginInfo(username: 'ag_low2', uid: 35));

    expect(await api.pull(), isA<SyncPulled>(), reason: 'a fresh client of the account in use');
    expect(await api.push(data: '{}', baseUpdated: 0, formhash: 'abcd1234'), isA<SyncPushed>());
    expect(built, 3);
    expect(forum.requests, hasLength(3));

    // A switch to another account: the same.
    await cookie.updateUserInfo(const UserLoginInfo(username: 'ag_mid', uid: 33));
    expect(await api.pull(), isA<SyncPulled>());
    expect(forum.requests, hasLength(4));
  });
}
