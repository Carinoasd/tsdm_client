import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Requests never mix accounts: a request started as A is dropped once B is the current account, its cookies are not
/// saved into B, and switching keeps the current account when the candidate can not be verified.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 2000);
const _carol = UserLoginInfo(username: 'Carol', uid: 3000);

String _authedPage(UserLoginInfo user) =>
    '<html><body><div id="inner_stat"><strong><a href="home.php?mod=space&amp;uid=${user.uid}">${user.username}</a> '
    '</strong></div><input type="hidden" name="formhash" value="XXXXXXXX" /></body></html>';
const _guestPage = '<html><body><div id="messagetext"><p>请先登录后才能继续浏览</p></div></body></html>';

/// Answers every request with [body] after [gate] completes (immediately when null), records requests.
final class _FakeAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Completer<void>? gate;
  String body = _authedPage(_alice);
  String setCookie = 'Ystv_2132_auth=fresh-alice-token; Path=/';

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (gate != null) {
      await gate!.future;
    }
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        'set-cookie': [setCookie],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late _FakeAdapter adapter;
  late CookieProvider current;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    adapter = _FakeAdapter();
    Dio dio() => Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter;
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(() => NetClientProvider.build(dio: dio()))
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: dio()),
        instanceName: ServiceKeys.noCookie,
      );
    await settings.init();
    // Two accounts on the device, Alice is current.
    await storage.saveCookie(username: 'Alice', uid: 1000, cookie: {'.domains': '{"alice":1}', 'Ystv_2132_auth': 'a'});
    await storage.saveCookie(username: 'Bob', uid: 2000, cookie: {'.domains': '{"bob":1}', 'Ystv_2132_auth': 'b'});
    current = CookieProvider(_alice, {'.domains': '{"alice":1}', 'Ystv_2132_auth': 'a'});
    getIt.registerSingleton<CookieProvider>(current);
  });
  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<void> switchTo(UserLoginInfo user) async => expect(await current.loadCookieFromStorage(user), isTrue);

  group('client bound to an account', () {
    test('same account: the request goes through and its cookies are saved', () async {
      final client = getIt.get<NetClientProvider>();
      final result = await client.get('$baseUrl/forum.php').run();
      expect(result.isRight(), isTrue, reason: '$result');
      expect(adapter.requests, hasLength(1));
      // The cookie jar keeps host cookies under a per-host key; the whole map is synced to Alice's row.
      final stored = storage.getCookieByUidSync(1000)!.values.map((v) => '$v').join();
      expect(stored, contains('fresh-alice-token'));
      expect(current.userLoginInfo.uid, 1000);
    });

    test('switch while a request is in flight: the answer is dropped and Bob gets no cookie from it', () async {
      adapter.gate = Completer<void>();
      final client = getIt.get<NetClientProvider>();
      final pending = client.get('$baseUrl/forum.php?mod=viewthread&tid=1').run();
      // Wait until the request reached the network layer.
      while (adapter.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await switchTo(_bob);
      adapter.gate!.complete();

      final result = await pending;
      expect(result.isLeft(), isTrue);
      expect(result.getLeft().toNullable(), isA<IdentityChangedException>());
      expect(current.userLoginInfo.uid, 2000);
      expect(await current.read('.domains'), '{"bob":1}', reason: "Alice's late answer must not write Bob's cookies");
      final bobStored = storage.getCookieByUidSync(2000)!.values.map((v) => '$v').join();
      expect(bobStored, isNot(contains('fresh-alice-token')));
      expect(storage.getCookieByUidSync(1000), containsPair('.domains', '{"alice":1}'));
    });

    test('client built as Alice, used after switching to Bob: nothing is sent', () async {
      final client = getIt.get<NetClientProvider>();
      await switchTo(_bob);
      final result = await client
          .postForm('$baseUrl/forum.php?mod=post&action=reply', data: {'message': 'as Alice', 'formhash': 'XXXXXXXX'})
          .run();
      expect(result.getLeft().toNullable(), isA<IdentityChangedException>());
      expect(adapter.requests, isEmpty, reason: "the reply must not go out with Bob's cookies");

      // A client built after the switch acts as Bob.
      final bobClient = getIt.get<NetClientProvider>();
      final ok = await bobClient.get('$baseUrl/forum.php').run();
      expect(ok.isRight(), isTrue);
      expect(adapter.requests, hasLength(1));
    });

    test('a guest client is dropped once someone logs in', () async {
      current.clearUserInfoAndCookie();
      final guest = getIt.get<NetClientProvider>();
      await switchTo(_alice);
      final result = await guest.get('$baseUrl/forum.php').run();
      expect(result.getLeft().toNullable(), isA<IdentityChangedException>());
    });
  });

  group('switching accounts', () {
    AuthenticationRepository repo() => AuthenticationRepository(
      user: _alice,
      clientFactory: (cookie) =>
          NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter, cookie: cookie),
    );

    test('a candidate without stored cookies fails and keeps the current account', () async {
      final auth = repo();
      final result = await auth.switchUser(_carol).run();
      expect(result.getLeft().toNullable(), isA<LoginInvalidCredentialException>());
      expect(current.userLoginInfo.uid, 1000);
      expect(auth.currentUser?.uid, 1000);
      expect(adapter.requests, isEmpty, reason: 'nothing to verify');
    });

    test('a candidate the server no longer accepts fails and keeps the current account', () async {
      adapter.body = _guestPage;
      final auth = repo();
      final result = await auth.switchUser(_bob).run();
      expect(result.getLeft().toNullable(), isA<SwitchUserNotAuthedException>());
      expect(current.userLoginInfo.uid, 1000, reason: 'Alice stays current');
      expect(await current.read('.domains'), '{"alice":1}');
      expect(auth.currentUser?.uid, 1000);
      expect((await storage.getAllUsers()).map((e) => e.uid), containsAll([1000, 2000]), reason: 'Bob is kept for a new login');
    });

    test('a verified candidate becomes current, the other account stays stored', () async {
      adapter.body = _authedPage(_bob);
      final auth = repo();
      final result = await auth.switchUser(_bob).run();
      expect(result.isRight(), isTrue, reason: '$result');
      expect(current.userLoginInfo.uid, 2000);
      expect(auth.currentUser?.uid, 2000);
      expect((await storage.getAllUsers()).map((e) => e.uid), containsAll([1000, 2000]));
      expect(storage.getCookieByUidSync(1000), containsPair('Ystv_2132_auth', 'a'), reason: "Alice's session is untouched");
    });
  });

  test('removing one account leaves the others', () async {
    expect(await storage.deleteCookieByUid(1000), isTrue);
    expect((await storage.getAllUsers()).map((e) => e.uid), [2000]);
    expect(storage.getCookieByUidSync(2000), containsPair('Ystv_2132_auth', 'b'));
  });
}
