import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/repository/red_packet_repository.dart';
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart';
import 'package:tsdm_client/features/red_packet/widgets/red_packet_card.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:universal_html/parsing.dart';

/// Discuz! X5 `hongbao` plugin samples captured with a test account on 2026-09-06 (uids -> 1000+, usernames ->
/// placeholder names, avatars -> example.com, hashes -> XXXXXXXX).
String _data(String name) => File('test/data/$name').readAsStringSync();

// Answers of plugin.php?id=hongbao:* as captured; the sender name is replaced.
const _openDone =
    '{"ok":true,"tid":1264928,"from":"Alice 的紅包","bless":"許哥牛逼","haspw":0,"cond":0,"appoint":0,"splitmode":2, '
    '"unit":"天使币","state":"done","is_sender":0,"mine":{"claimed":0}}';
const _openNone = '{"ok":false,"error":"這裡沒有紅包"}';
const _openGuest = '{"ok":false,"need_login":1,"error":"請先登入"}';
const _recordRefused = '{"ok":false,"error":"開包後才能看大家的手氣"}';
const _grabDone = '{"ok":false,"error":"紅包已被搶光","state":"done"}';
const _dailyOk = '{"ok":true,"amount":5,"unit":"天使币","redirect":""}';
const _dailyAlready = '{"ok":false,"already":1,"amount":5,"error":"今天已經領過囉,明天再來"}';
// A live packet (tid 1265042, random amounts) before and after the test account claimed a share.
const _openLive =
    '{"ok":true,"tid":1265042,"from":"Bob 的紅包","bless":"恭喜發財,大吉大利","haspw":0,"cond":0,"appoint":0,"splitmode":1, '
    '"unit":"天使币","state":"open","is_sender":0,"mine":{"claimed":0}}';
const _grabLive = '{"ok":true,"amount":17,"unit":"天使币","iscat":true,"best":true,"already":false}';
const _grabLiveAgain = '{"ok":true,"amount":17,"unit":"天使币","iscat":false,"best":true,"already":true}';
const _openLiveAfter =
    '{"ok":true,"tid":1265042,"from":"Bob 的紅包","bless":"恭喜發財,大吉大利","haspw":0,"cond":0,"appoint":0,"splitmode":1, '
    '"unit":"天使币","state":"claimed","is_sender":0,"mine":{"claimed":1,"amount":17,"best":1}}';
const _recordLive =
    '{"ok":true,"shares":10,"claimed":1,"unit":"天使币","recs":[{"username":"Alice","time":"9-6 03:45","amount":17,"isbest":1}]}';
const _openEntryHtml =
    '<div class="hb-entry" data-tid="1265042" onclick="hongbaoOpen(this)"><div class="icon"></div><div> '
    '<div class="t1">恭喜發財,大吉大利</div><div class="t2">拼手氣紅包 · 剩 10/10 份 · 點擊領取</div></div> '
    '<div class="claimed-mark" style="display:none">點擊領取</div></div>';
const _dailyScript =
    '(function(){function go(){if(window.hongbaoDailyInit){hongbaoDailyInit({"entry":2,"dateflag":"20260906", '
    '"from":"系統 每日紅包","bless":"今日登入紅包,明天還可以再領","unit":"天使币"});}else{setTimeout(go,50);}}go();})();';

/// Serves canned answers by request path and records every request with its form body.
final class _FakeAdapter implements HttpClientAdapter {
  final requests = <(Uri uri, String method, String body)>[];
  final answers = <bool Function(Uri uri, String method), (String body, String contentType)>{};

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    var body = '';
    if (requestStream != null) {
      final bytes = await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      body = utf8.decode(bytes);
    }
    requests.add((options.uri, options.method, body));
    final answer = answers.entries.where((e) => e.key(options.uri, options.method)).firstOrNull?.value;
    if (answer == null) {
      return ResponseBody.fromString('not found', 404);
    }
    return ResponseBody.fromString(
      answer.$1,
      200,
      headers: {
        Headers.contentTypeHeader: [answer.$2],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('red packet entry in a post on X5', () {
    test('entry fields', () {
      final body = parseHtmlDocument(_data('red_packet_post_x5.html'));
      final entry = parseRedPacketEntry(body.querySelector('div.hb-entry')!);
      expect(entry, isNotNull);
      expect(entry!.tid, '1264928');
      expect(entry.bless, '許哥牛逼');
      expect(entry.statusText, '均分紅包 · 剩 0/25 份 · 已被搶光');
      expect(entry.claimed, isTrue);
      expect(parseRedPacketEntry(parseHtmlDocument('<div class="hb-entry"></div>').querySelector('div')!), isNull);

      // An open packet carries the same mark element hidden with display:none; only the class means claimed.
      final open = parseRedPacketEntry(parseHtmlDocument(_openEntryHtml).querySelector('div.hb-entry')!);
      expect(open!.tid, '1265042');
      expect(open.bless, '恭喜發財,大吉大利');
      expect(open.statusText, '拼手氣紅包 · 剩 10/10 份 · 點擊領取');
      expect(open.claimed, isFalse);
    });

    testWidgets('the post body renders the card, the post text and none of the plugin popup', (tester) async {
      final pcbs = parseHtmlDocument(_data('red_packet_post_x5.html')).querySelector('div.pcbs')!;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: Builder(builder: (context) => munchElement(context, pcbs))),
            ),
          ),
        ),
      );
      expect(find.byType(RedPacketCard), findsOneWidget);
      expect(find.text('許哥牛逼'), findsOneWidget);
      expect(find.text('均分紅包 · 剩 0/25 份 · 已被搶光'), findsOneWidget);
      expect(find.textContaining('RT，測試一下', findRichText: true), findsOneWidget, reason: 'the real post text');
      for (final leaked in ['已存入你的帳戶', '手 氣 爆 發', '看看大家的手氣', '今日不再顯示', '輸入口令', 'hb-entry{']) {
        expect(find.textContaining(leaked, findRichText: true), findsNothing, reason: '"$leaked" is popup markup');
      }
    });
  });

  group('red packet api answers', () {
    test('open', () {
      final done = RedPacketOpenResult.fromJson(jsonDecode(_openDone) as Map<String, dynamic>);
      expect(done.info, isNotNull);
      expect(done.info!.tid, '1264928');
      expect(done.info!.from, 'Alice 的紅包');
      expect(done.info!.bless, '許哥牛逼');
      expect(done.info!.hasPassword, isFalse);
      expect(done.info!.isRandom, isFalse);
      expect(done.info!.unit, '天使币');
      expect(done.info!.state, RedPacketState.done);
      expect(done.info!.isSender, isFalse);
      expect(done.info!.claimed, isFalse);

      final none = RedPacketOpenResult.fromJson(jsonDecode(_openNone) as Map<String, dynamic>);
      expect(none.info, isNull);
      expect(none.error, '這裡沒有紅包');
      expect(none.needLogin, isFalse);

      final guest = RedPacketOpenResult.fromJson(jsonDecode(_openGuest) as Map<String, dynamic>);
      expect(guest.info, isNull);
      expect(guest.needLogin, isTrue);

      final claimed = RedPacketOpenResult.fromJson({
        'ok': true,
        'tid': 1,
        'from': 'Bob 的紅包',
        'bless': 'hi',
        'haspw': 1,
        'splitmode': 1,
        'unit': '天使币',
        'state': 'open',
        'is_sender': 0,
        'mine': {'claimed': 1, 'amount': 12.0, 'best': 1},
      });
      expect(claimed.info!.hasPassword, isTrue);
      expect(claimed.info!.isRandom, isTrue);
      expect(claimed.info!.claimed, isTrue);
      expect(claimed.info!.claimedAmount, '12');
      expect(claimed.info!.claimedBest, isTrue);
    });

    test('a live packet before and after claiming', () {
      final before = RedPacketOpenResult.fromJson(jsonDecode(_openLive) as Map<String, dynamic>).info!;
      expect(before.state, RedPacketState.open);
      expect(before.isRandom, isTrue);
      expect(before.hasPassword, isFalse);
      expect(before.claimed, isFalse);

      final grab = RedPacketGrabResult.fromJson(jsonDecode(_grabLive) as Map<String, dynamic>);
      expect(grab.ok, isTrue);
      expect(grab.amount, '17');
      expect(grab.unit, '天使币');
      expect(grab.best, isTrue);
      expect(grab.isCat, isTrue);
      expect(grab.already, isFalse);

      // Claiming again answers ok with the same amount and already=true.
      final again = RedPacketGrabResult.fromJson(jsonDecode(_grabLiveAgain) as Map<String, dynamic>);
      expect(again.ok, isTrue);
      expect(again.already, isTrue);
      expect(again.amount, '17');

      // After claiming the state is "claimed" rather than "open".
      final after = RedPacketOpenResult.fromJson(jsonDecode(_openLiveAfter) as Map<String, dynamic>).info!;
      expect(after.state, RedPacketState.claimed);
      expect(after.claimed, isTrue);
      expect(after.claimedAmount, '17');
      expect(after.claimedBest, isTrue);

      final records = RedPacketRecordsResult.fromJson(jsonDecode(_recordLive) as Map<String, dynamic>);
      expect(records.error, isNull);
      expect(records.shares, 10);
      expect(records.claimed, 1);
      expect(records.records.single.username, 'Alice');
      expect(records.records.single.time, '9-6 03:45');
      expect(records.records.single.amount, '17');
      expect(records.records.single.isBest, isTrue);
    });

    test('grab, record and daily', () {
      final done = RedPacketGrabResult.fromJson(jsonDecode(_grabDone) as Map<String, dynamic>);
      expect(done.ok, isFalse);
      expect(done.allTaken, isTrue);
      expect(done.error, '紅包已被搶光');
      final ok = RedPacketGrabResult.fromJson({'ok': true, 'amount': 3, 'iscat': 0, 'best': 1});
      expect(ok.ok, isTrue);
      expect(ok.amount, '3');
      expect(ok.best, isTrue);
      expect(RedPacketGrabResult.fromJson({'ok': false, 'state': 'badpw', 'error': 'x'}).badPassword, isTrue);
      expect(RedPacketGrabResult.fromJson({'ok': false, 'state': 'needreply'}).needReply, isTrue);

      final refused = RedPacketRecordsResult.fromJson(jsonDecode(_recordRefused) as Map<String, dynamic>);
      expect(refused.error, '開包後才能看大家的手氣');
      expect(refused.records, isEmpty);
      final records = RedPacketRecordsResult.fromJson({
        'ok': true,
        'claimed': 2,
        'shares': 25,
        'unit': '天使币',
        'recs': [
          {'username': 'Alice', 'time': '2026-09-06 02:39', 'amount': 4, 'isbest': 1},
          {'username': 'Bob', 'time': '2026-09-06 02:40', 'amount': 4, 'isbest': 0},
        ],
      });
      expect(records.error, isNull);
      expect(records.claimed, 2);
      expect(records.shares, 25);
      expect(records.records.map((e) => e.username), ['Alice', 'Bob']);
      expect(records.records.first.isBest, isTrue);
      expect(records.records.first.amount, '4');

      final daily = DailyRedPacketResult.fromJson(jsonDecode(_dailyOk) as Map<String, dynamic>);
      expect(daily.ok, isTrue);
      expect(daily.amount, '5');
      expect(daily.unit, '天使币');
      final already = DailyRedPacketResult.fromJson(jsonDecode(_dailyAlready) as Map<String, dynamic>);
      expect(already.ok, isFalse);
      expect(already.already, isTrue);
      expect(already.error, contains('今天已經領過'));
    });

    test('daily config and form hash in the homepage', () {
      final document = parseHtmlDocument(
        '<html><body><div id="um"><a href="member.php?mod=logging&amp;action=logout&amp;formhash=XXXXXXXX">退出</a> '
        '</div><script>window.hongbaoDailyInit=function(cfg){};</script><script>$_dailyScript</script></body></html>',
      );
      final config = parseDailyRedPacketConfig(document);
      expect(config, isNotNull);
      expect(config!.entry, 2);
      expect(config.dateFlag, '20260906');
      expect(config.from, '系統 每日紅包');
      expect(config.bless, '今日登入紅包,明天還可以再領');
      expect(config.unit, '天使币');
      expect(parseFormHash(document), 'XXXXXXXX');

      final claimedPage = parseHtmlDocument(
        '<html><body><script>window.hongbaoDailyInit=function(cfg){};</script>'
        '<input type="hidden" name="formhash" value="YYYYYYYY" /></body></html>',
      );
      expect(parseDailyRedPacketConfig(claimedPage), isNull, reason: 'no init call once claimed');
      expect(parseFormHash(claimedPage), 'YYYYYYYY');
      expect(parseFormHash(parseHtmlDocument('<html><body></body></html>')), isNull);
    });

    test('non json bodies are rejected', () {
      expect(decodeJsonObject('<!DOCTYPE html><html>System Error</html>'), isNull);
      expect(decodeJsonObject('[1,2]'), isNull);
      expect(decodeJsonObject('{"ok":true}'), {'ok': true});
      expect(decodeJsonObject({'ok': 1}), {'ok': 1});
    });
  });

  group('RedPacketRepository on X5', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late _FakeAdapter adapter;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      adapter = _FakeAdapter();
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
        );
      await settings.init();
    });
    tearDown(() async {
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    test('open answers json', () async {
      adapter.answers[(uri, method) => method == 'GET'] = (_openDone, 'application/json; charset=utf-8');
      final result = await const RedPacketRepository().open('1264928').run();
      expect(result.toNullable()?.info?.state, RedPacketState.done);
      final (uri, _, _) = adapter.requests.single;
      expect(uri.path, '/plugin.php');
      expect(uri.queryParameters, containsPair('id', 'hongbao:open'));
      expect(uri.queryParameters, containsPair('tid', '1264928'));
    });

    test('grab and daily post the form hash', () async {
      adapter.answers[(uri, method) => uri.queryParameters['id'] == 'hongbao:grab'] = (_grabDone, 'text/html');
      adapter.answers[(uri, method) => uri.queryParameters['id'] == 'hongbao:daily'] = (_dailyOk, 'application/json');
      const repo = RedPacketRepository();

      final grab = await repo.grab(tid: '1264928', formHash: 'XXXXXXXX', password: 'pw').run();
      expect(grab.toNullable()?.allTaken, isTrue, reason: 'json in a text/html body is still parsed');
      final (_, grabMethod, grabBody) = adapter.requests[0];
      expect(grabMethod, 'POST');
      expect(Uri.splitQueryString(grabBody), {'tid': '1264928', 'formhash': 'XXXXXXXX', 'password': 'pw'});

      final daily = await repo.claimDaily(formHash: 'XXXXXXXX').run();
      expect(daily.toNullable()?.ok, isTrue);
      expect(daily.toNullable()?.amount, '5');
      final (_, dailyMethod, dailyBody) = adapter.requests[1];
      expect(dailyMethod, 'POST');
      expect(Uri.splitQueryString(dailyBody), {'formhash': 'XXXXXXXX'});
    });

    test('an html error page is a failure', () async {
      adapter.answers[(uri, method) => true] = ('<!DOCTYPE html><html><body>Discuz! System Error</body></html>', 'text/html');
      final result = await const RedPacketRepository().claimDaily(formHash: 'bad').run();
      expect(result.isLeft(), isTrue);
    });
  });
}
