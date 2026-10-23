import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/points/stream.dart';
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';

String _page({bool packet = true}) =>
    '''
<html><head><script>var discuz_uid = '1000';</script></head><body>
<input name="formhash" value="XXXXXXXX">
<p id="balance">${packet ? 10 : 17}</p>
<script src="home.php?mod=spacecp&amp;ac=pm&amp;op=checknewpm&amp;rand=123"></script>
${packet ? '<script>hongbaoDailyInit({"entry":2,"dateflag":"20260925"});</script>' : ''}
</body></html>
''';

final class _Adapter implements HttpClientAdapter {
  final requests = <(String, String, String)>[];
  bool claimed = false;
  bool visitFails = false;
  bool claimFails = false;
  bool reloadFails = false;
  bool reloadMalformed = false;
  int homeCalls = 0;
  Future<void> Function()? onVisit;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream, Future<void>? cancelFuture) async {
    final bytes = await stream?.fold<List<int>>([], (a, b) => a..addAll(b));
    requests.add((options.uri.path, options.method, bytes == null ? '' : utf8.decode(bytes)));
    if (options.uri.path == '/forum.php') {
      homeCalls++;
      if (reloadMalformed && homeCalls > 1) {
        return ResponseBody.fromString(
          '{}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      }
      return ResponseBody.fromString(
        _page(packet: !claimed),
        reloadFails && homeCalls > 1 ? 503 : 200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    if (options.uri.path == '/home.php') {
      expect(options.uri.queryParameters['op'], 'checknewpm');
      await onVisit?.call();
      return ResponseBody.fromString(
        visitFails ? '<html>login required</html>' : '',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/javascript'],
          if (!visitFails) 'set-cookie': ['${cookiePrefix}_creditnotice=0D0D2D0D0D0D0D0D0D1000; Path=/'],
        },
      );
    }
    expect(options.uri.queryParameters['id'], 'hongbao:daily');
    expect(options.method, 'POST');
    claimed = !claimFails;
    return ResponseBody.fromString(
      claimFails ? '{"ok":false,"error":"try later"}' : '{"ok":true,"amount":5}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late CookieProvider cookie;
  late _Adapter adapter;
  late ForumHomeRepository home;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    cookie = CookieProvider(const UserLoginInfo(uid: 1000, username: 'Alice'), {});
    adapter = _Adapter();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(cookie)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      );
    await settings.init();
    home = ForumHomeRepository();
  });
  tearDown(() async {
    await home.dispose();
    await settings.dispose();
    await getIt.reset();
    await db.close();
  });

  test('new setting defaults off, persists and is independent of auto checkin', () async {
    expect(settings.currentSettings.autoDailyRedPacket, isFalse);
    await settings.setValue(SettingsKeys.autoCheckin, false);
    await settings.setValue(SettingsKeys.autoDailyRedPacket, true);
    expect(settings.currentSettings.autoCheckin, isFalse);
    expect(settings.currentSettings.autoDailyRedPacket, isTrue);
    await settings.init();
    expect(settings.currentSettings.autoDailyRedPacket, isTrue);
    // An old database backup has no row for the new key.
    await settings.deleteValue(SettingsKeys.autoDailyRedPacket);
    await settings.init();
    expect(settings.currentSettings.autoDailyRedPacket, isFalse);
    expect(settings.currentSettings.autoCheckin, isFalse);
  });

  test('homepage visits, claims and reloads once; real server credit notice reaches existing stream', () async {
    await settings.setValue(SettingsKeys.autoCheckin, false);
    await settings.setValue(SettingsKeys.autoDailyRedPacket, true);
    final reward = pointsChangesStream.stream.first;
    final replaced = home.pageReplacements.first;
    final result = await home.fetchHomePage().run();
    expect(result.isRight(), isTrue);
    // The page is answered before the rewards (cold start): they run in the background and replace it.
    result.fold((_) => fail('homepage should remain available'), (page) {
      final doc = (page as ForumHomeWebPage).document;
      expect(doc.querySelector('#balance')?.text, '10');
      expect(parseDailyRedPacketConfig(doc), isNotNull);
    });
    await home.dailyRewardsDone;
    expect(await reward.timeout(const Duration(seconds: 3)), '0D0D2D0D0D0D0D0D0D1000');
    final replacement = await replaced;
    expect(identical(replacement.previous, result.toNullable()), isTrue);
    final doc = (replacement.page as ForumHomeWebPage).document;
    expect(doc.querySelector('#balance')?.text, '17');
    expect(parseDailyRedPacketConfig(doc), isNull);
    expect(identical(home.getCache(), replacement.page), isTrue);
    expect(adapter.requests.map((e) => e.$1), ['/forum.php', '/home.php', '/plugin.php', '/forum.php']);
    expect(adapter.requests[2].$3, 'formhash=XXXXXXXX');
    await home.fetchHomePage().run();
    expect(adapter.requests.length, 4);
    await home.fetchHomePage(force: true).run();
    expect(adapter.requests.length, 5);
  });

  test('default-off leaves manual red packet entry and never posts a claim', () async {
    final result = await home.fetchHomePage().run();
    result.fold((_) => fail('homepage failed'), (page) => expect(page.dailyRedPacket, isNotNull));
    expect(adapter.requests.where((e) => e.$2 == 'POST'), isEmpty);
  });

  test('login/error response and failed claim do not break homepage or hide manual entry', () async {
    await settings.setValue(SettingsKeys.autoDailyRedPacket, true);
    adapter
      ..visitFails = true
      ..claimFails = true;
    final result = await home.fetchHomePage().run();
    expect(result.isRight(), isTrue);
    result.fold((_) => fail('homepage failed'), (page) => expect(page.dailyRedPacket, isNotNull));
    await home.dailyRewardsDone;
    expect(adapter.homeCalls, 1);
    expect(home.getCache()?.dailyRedPacket, isNotNull);
  });

  test('failed best-effort reload preserves fetched homepage', () async {
    adapter.reloadFails = true;
    final page = (await home.fetchHomePage().run()).toNullable();
    expect(page, isNotNull);
    await home.dailyRewardsDone;
    expect(home.hasCache(), isTrue);
    expect(identical(home.getCache(), page), isTrue);
  });

  test('unexpected reload response preserves fetched homepage', () async {
    adapter.reloadMalformed = true;
    final page = (await home.fetchHomePage().run()).toNullable();
    expect(page, isNotNull);
    await home.dailyRewardsDone;
    expect(home.hasCache(), isTrue);
    expect(identical(home.getCache(), page), isTrue);
  });

  test('switching accounts during visit does not claim or cache old account page', () async {
    await settings.setValue(SettingsKeys.autoDailyRedPacket, true);
    adapter.onVisit = () => cookie.updateUserInfo(const UserLoginInfo(uid: 1001, username: 'Bob'));
    final replacements = <Object>[];
    final sub = home.pageReplacements.listen(replacements.add);
    addTearDown(sub.cancel);
    // The page is answered before the visit (cold start): it was served to Alice, the account in use then.
    final result = await home.fetchHomePage().run();
    expect(result.toNullable()?.servedUid, 1000);
    await home.dailyRewardsDone;
    expect(adapter.requests.where((e) => e.$2 == 'POST'), isEmpty, reason: 'nothing claimed for Bob or Alice');
    expect(adapter.homeCalls, 1, reason: 'no reload for the previous account');
    expect(replacements, isEmpty);
    expect(home.hasCache(), isFalse, reason: "Alice's page is never handed to Bob");
    expect(home.getCache(), isNull);
  });
}
