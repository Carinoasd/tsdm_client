import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/repository/auto_checkin_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Auto check-in of many accounts: one at a time, a 429 is retried, an expired session is reported as such.
///
/// A tester with eleven accounts saw four checked in at once get "您需要先登录" and 429 from the forum, and the
/// leftovers were only tried again on the next app start.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 2000);
const _carol = UserLoginInfo(username: 'Carol', uid: 3000);
const _dave = UserLoginInfo(username: 'Dave', uid: 4000);

const _signPage =
    '<html><body><div id="um"><a href="home.php?mod=space&amp;uid=1000">Alice</a></div> '
    '<form id="qiandao" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /></form></body></html>';
const _guestPage =
    '<html><body><form id="lsform" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /> '
    '<input name="username" /></form></body></html>';
const _successXml =
    '<?xml version="1.0" encoding="utf-8"?>\n<root><![CDATA[<div class="c">恭喜你签到成功!获得随机奖励 天使币 10 .</div> '
    '<script type="text/javascript" reload="1">hideWindow("qwindow");</script>]]></root>';
const _needLoginXml =
    '<?xml version="1.0" encoding="utf-8"?>\n<root><![CDATA[您需要先登录才能继续本操作<script type="text/javascript" '
    "reload=\"1\">if(typeof succeedhandle_=='function') {succeedhandle_('member.php?mod=logging&action=login', "
    "'您需要先登录才能继续本操作', {});}</script>]]></root>";

typedef _Answer = (int status, String body, Map<String, List<String>> headers);

/// Answers requests from a script in order; the order itself proves the accounts ran one after another.
final class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.script);

  final List<_Answer> script;
  final requests = <String>[];
  var _next = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add('${options.method} ${options.uri.queryParameters['operation'] ?? 'page'}');
    if (_next >= script.length) {
      fail('unexpected request #${_next + 1}: ${requests.last}');
    }
    final (status, body, headers) = script[_next++];
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        ...headers,
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
  late _ScriptedAdapter adapter;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

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
    for (final u in [_alice, _bob, _carol, _dave]) {
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

  AutoCheckinRepository repo(List<_Answer> script, {List<Duration>? retryDelays}) {
    adapter = _ScriptedAdapter(script);
    return AutoCheckinRepository(
      storageProvider: storage,
      clientFactory: (cookie) => NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
        cookie: cookie,
      ),
      gap: Duration.zero,
      retryDelays: retryDelays ?? const [Duration.zero, Duration.zero],
    );
  }

  Future<AutoCheckinInfo> run(AutoCheckinRepository r, List<UserLoginInfo> users) async {
    final seen = <AutoCheckinInfo>[];
    final sub = r.status.listen(seen.add);
    final result = await r
        .checkinAll(waitingList: users, skippedList: const [], feeling: CheckinFeeling.happy, message: 'hi')
        .run();
    expect(result.isRight(), isTrue, reason: '$result');
    // Status events are delivered asynchronously: let the last ones arrive before reading them.
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    await r.dispose();
    return seen.last;
  }

  test('accounts run one after another, a 429 is retried, an expired session is reported', () async {
    final r = repo([
      // Alice: page, then a successful check-in.
      (200, _signPage, {}),
      (200, _successXml, {}),
      // Bob: rate limited twice on the page, then through.
      (429, 'Too Many Requests', {}),
      (429, 'Too Many Requests', {}),
      (200, _signPage, {}),
      (200, _successXml, {}),
      // Carol: session expired, the login form comes back; no post must follow.
      (200, _guestPage, {}),
      // Dave: the page looks fine, the post says the session is gone.
      (200, _signPage, {}),
      (200, _needLoginXml, {}),
    ]);
    final info = await run(r, [_alice, _bob, _carol, _dave]);

    expect(adapter.requests, [
      'GET page', 'POST qiandao', //
      'GET page', 'GET page', 'GET page', 'POST qiandao', //
      'GET page', //
      'GET page', 'POST qiandao',
    ]);
    expect(info.succeeded.map((e) => e.$1), [_alice, _bob]);
    expect(info.failed.map((e) => e.$1), [_carol, _dave]);
    expect(info.failed.map((e) => e.$2), everyElement(isA<CheckinResultNotAuthorized>()));
    expect(info.running, isEmpty);
    expect(info.waiting, isEmpty);
  });

  test('after the retries are used up the account is reported rate limited, the next account still runs', () async {
    final r = repo([
      (429, 'Too Many Requests', {}),
      (429, 'Too Many Requests', {}),
      (429, 'Too Many Requests', {}),
      (200, _signPage, {}),
      (200, _successXml, {}),
    ]);
    final info = await run(r, [_alice, _bob]);
    expect(adapter.requests, hasLength(5));
    expect(info.failed.single.$1, _alice);
    expect(info.failed.single.$2, isA<CheckinResultWebRequestFailed>().having((e) => e.statusCode, 'status', 429));
    expect(info.succeeded.single.$1, _bob);
  });

  test('a Retry-After header longer than the schedule is honored', () async {
    final r = repo(
      [
        (429, 'Too Many Requests', {'retry-after': ['1']}),
        (200, _signPage, {}),
        (200, _successXml, {}),
      ],
      retryDelays: const [Duration.zero],
    );
    final watch = Stopwatch()..start();
    final info = await run(r, [_alice]);
    expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 1)));
    expect(info.succeeded.single.$1, _alice);
  });
}
