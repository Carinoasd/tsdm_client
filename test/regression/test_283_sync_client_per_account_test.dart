/// The cross-device sync asks the forum with a client of the account it syncs, built at each call.
///
/// A `NetClientProvider` is bound to the account it was built for: once the global cookie names another account (a
/// login on a fresh install, a switch), its requests and answers are dropped (`IdentityChangedException`). The sync
/// built one client at the start, so on a fresh install every pull and push after the login was dropped
/// ("sync: pull failed: no answer") until the app was started again; the same after a switch of account.
///
/// Now `TsdmAppSyncApi` builds the client at each call, for the account the call is of: a call after the login goes
/// out as the account, and a call of an account the global cookie no longer names is dropped instead of going out as
/// the other account.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// A forum answering every `sync` call with an empty document, recording the calls that reached it.
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
const _low2 = UserLoginInfo(username: 'ag_low2', uid: 35);
const _mid = UserLoginInfo(username: 'ag_mid', uid: 33);

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

  /// The app's client of the account ([TsdmAppSyncApi.clientOf]), on the test forum.
  NetClientProvider clientOf(int uid) =>
      TsdmAppSyncApi.clientOf(uid, dio: Dio(BaseOptions(baseUrl: _baseUrl))..httpClientAdapter = forum);

  test('the client built once at the start, as the guest: dropped once an account logged in (the bug)', () async {
    // The guest's client, as the cookie had no account when the app started.
    final once = NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: _baseUrl))..httpClientAdapter = forum);
    final api = TsdmAppSyncApi((_) => once);

    // The login on a fresh install: the global cookie names the account now.
    await cookie.updateUserInfo(_low2);

    expect(await api.pull(35), isA<SyncPullFailed>(), reason: "the guest client is another account's now");
    expect(forum.requests, isEmpty, reason: 'the dropped call never reached the forum');
  });

  test('a client built at each call for the account synced: the call after the login goes out', () async {
    final built = <int>[];
    final api = TsdmAppSyncApi((uid) {
      built.add(uid);
      return clientOf(uid);
    });

    await cookie.updateUserInfo(_low2);
    expect(await api.pull(35), isA<SyncPulled>());
    expect(await api.push(35, data: '{}', baseUpdated: 0, formhash: 'abcd1234'), isA<SyncPushed>());
    expect(built, [35, 35]);
    expect(forum.requests, hasLength(2));

    // A switch to another account, then a run of it: the same.
    await cookie.updateUserInfo(_mid);
    expect(await api.pull(33), isA<SyncPulled>());
    expect(built, [35, 35, 33]);
    expect(forum.requests, hasLength(3));
  });

  test('a call of an account the cookie no longer names is dropped, never sent as the other account', () async {
    final api = TsdmAppSyncApi(clientOf);
    await cookie.updateUserInfo(_low2);
    expect(await api.pull(35), isA<SyncPulled>());

    // Switched to ag_mid while a run of ag_low2 goes on: its calls must not go out with ag_mid's cookie.
    await cookie.updateUserInfo(_mid);
    expect(await api.pull(35), isA<SyncPullFailed>());
    expect(await api.push(35, data: '{}', baseUpdated: 0, formhash: 'abcd1234'), isA<SyncPushFailed>());
    expect(forum.requests, hasLength(1), reason: 'only the call made as the account in use reached the forum');
  });
}
