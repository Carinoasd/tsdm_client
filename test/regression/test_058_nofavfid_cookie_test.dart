import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Discuz! sets `Ystv_2132_nofavfid=1` for a year when a session first lists the forum index while the account has
/// no favorite forums, and then skips the "我收藏的版块" panel for that session; only the session that adds a favorite
/// gets the cookie cleared. A favorite added in the browser therefore stayed invisible to the app until a new login
/// (issue #1, verified live on 2026-09-09). The app must never keep or send that flag.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('stripServerFlagCookies', () {
    test('drops the flag at any depth of the persisted jar and keeps everything else', () {
      final out = stripServerFlagCookies({
        'www.tsdm39.com':
            '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=a; Path=/","Ystv_2132_nofavfid":"Ystv_2132_nofavfid=1; Path=/"}}',
        '.index': '["www.tsdm39.com"]',
        '.domains': '{}',
        'Ystv_2132_nofavfid': '1',
      });
      expect(out.keys, unorderedEquals(['www.tsdm39.com', '.index', '.domains']));
      expect(out['www.tsdm39.com'], contains('Ystv_2132_auth=a'));
      expect(out['www.tsdm39.com'], isNot(contains('nofavfid')));
      expect(out['.index'], '["www.tsdm39.com"]');
    });

    test('a value that is not JSON is kept as it is', () {
      expect(stripServerFlagCookies({'k': 'not json _nofavfid'}), {'k': 'not json _nofavfid'});
    });
  });

  group('the client', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
      await settings.init();
    });
    tearDown(() async {
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    test('never stores nor sends the nofavfid flag, the auth cookie still round-trips', () async {
      final adapter = _Adapter();
      final cookie = CookieProvider(const UserLoginInfo(username: 'Alice', uid: 1000), {});
      final client = NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
        cookie: cookie,
      );
      await client.get('$baseUrl/forum.php').run();
      await client.get('$baseUrl/forum.php').run();
      expect(adapter.cookieHeaders, hasLength(2));
      expect(adapter.cookieHeaders.last, contains('Ystv_2132_auth=a'));
      expect(adapter.cookieHeaders.last, isNot(contains('nofavfid')));
      final stored = storage.getCookieByUidSync(1000);
      expect(stored, isNotNull);
      expect('$stored', contains('Ystv_2132_auth'));
      expect('$stored', isNot(contains('nofavfid')));
    });

    test('a row persisted by an older version is cleaned when loaded', () async {
      await storage.saveCookie(
        username: 'Alice',
        uid: 1000,
        cookie: {
          'www.tsdm39.com':
              '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=a; Path=/","Ystv_2132_nofavfid":"Ystv_2132_nofavfid=1; Path=/"}}',
        },
      );
      final cookie = CookieProvider.buildEmpty();
      expect(await cookie.loadCookieFromStorage(const UserLoginInfo(username: 'Alice', uid: 1000)), isTrue);
      expect(await cookie.read('www.tsdm39.com'), contains('Ystv_2132_auth=a'));
      expect(await cookie.read('www.tsdm39.com'), isNot(contains('nofavfid')));
    });
  });
}

final class _Adapter implements HttpClientAdapter {
  final cookieHeaders = <String>[];
  var _calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    cookieHeaders.add('${options.headers['cookie'] ?? ''}');
    _calls++;
    return ResponseBody.fromString(
      '<html><body><div id="um"></div></body></html>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        if (_calls == 1)
          'set-cookie': ['Ystv_2132_auth=a; Path=/; HttpOnly', 'Ystv_2132_nofavfid=1; Path=/; Max-Age=31536000'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
