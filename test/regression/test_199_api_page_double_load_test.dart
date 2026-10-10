/// 1.34.0 report: the medal centre and the title shop loaded slowly, now and then showing "the forum gives no list
/// it can read".
///
/// The pages loaded once when opened and again on the authentication status, which the status stream replays to a
/// new listener: two calls of the same app API action at once. The API takes one call per action and account every
/// few seconds and answered the second "too soon" (HTTP 429); the page waited, and when the wait ran into another
/// call it fell back to the web page, which the card layout of the forum's new plugins does not parse.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/utils/account_changes.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';

final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.user) {
    _subject.add(user == null ? const AuthStatusNotAuthed() : AuthStatusAuthed(user!));
  }

  UserLoginInfo? user;
  final _subject = BehaviorSubject<AuthStatus>();

  @override
  Stream<AuthStatus> get status => _subject.asBroadcastStream();

  @override
  int? get effectiveCurrentUid => user?.uid;

  void emit(AuthStatus s, {UserLoginInfo? to}) {
    user = to ?? user;
    _subject.add(s);
  }

  Future<void> close() => _subject.close();
}

final class _Forum implements HttpClientAdapter {
  _Forum(this.answers);

  final List<(int, Object)> answers;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final (status, body) = answers[calls++];
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  setUp(TsdmAppApi.reset);

  const alice = UserLoginInfo(username: 'Alice', uid: 1000);
  const bob = UserLoginInfo(username: 'Bob', uid: 1001);

  test('the replayed status of the account the page loaded for does not reload it', () async {
    final auth = _Auth(alice);
    addTearDown(auth.close);
    var changed = 0;
    var clearing = 0;
    final sub = listenAccountChanges(auth, onLoggingIn: () => clearing++, onChanged: () => changed++);
    addTearDown(sub.cancel);
    await pumpEventQueue();
    expect(changed, 0, reason: 'only the replay arrived');

    auth.emit(const AuthStatusAuthed(alice));
    await pumpEventQueue();
    expect(changed, 0, reason: 'the same account again');

    auth.emit(const AuthStatusLoading());
    await pumpEventQueue();
    expect(clearing, 1);
    auth.emit(const AuthStatusAuthed(bob), to: bob);
    await pumpEventQueue();
    expect(changed, 1, reason: 'switched to another account');

    auth.emit(const AuthStatusNotAuthed(), to: const UserLoginInfo(username: null, uid: null));
    await pumpEventQueue();
    expect(changed, 2, reason: 'logged out');
  });

  test('a login of the same account ending reloads (the page was cleared when it started)', () async {
    final auth = _Auth(alice);
    addTearDown(auth.close);
    var changed = 0;
    final sub = listenAccountChanges(auth, onLoggingIn: () {}, onChanged: () => changed++);
    addTearDown(sub.cancel);
    await pumpEventQueue();
    auth
      ..emit(const AuthStatusLoading())
      ..emit(const AuthStatusAuthed(alice));
    await pumpEventQueue();
    expect(changed, 1);
  });

  test('askWaiting waits twice for answers "too soon" before giving up', () async {
    final busy = (429, {'ok': 0, 'error': 'busy', 'retry_after': 0});
    final forum = _Forum([
      busy,
      busy,
      (200, {'ok': 1, 'installed': 1}),
    ]);
    final client = NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);
    expect((await TsdmAppApi.askWaiting(client, 'medals'))?['ok'], 1);
    expect(forum.calls, 3);

    final always = _Forum([busy, busy, busy]);
    final client2 = NetClientProvider.buildNoCookie(
      dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = always,
    );
    expect(await TsdmAppApi.askWaiting(client2, 'medals'), isNull);
    expect(always.calls, 3);
    expect(TsdmAppApi.knownUnavailable, isFalse, reason: 'busy is not a missing plugin');
  });
}
