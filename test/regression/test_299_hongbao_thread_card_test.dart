/// The forum's app API, plugin 3.5.0: the red packet of a thread of the hongbao plugin (`special.type: hongbao`, thread
/// page `schema: 18`), grabbing a share and withdrawing the rest (`plugin.php?id=hongbao:grab|withdraw`, the plugin
/// 2.6.0 `handle` result with `values`), and the records (`plugin.php?id=hongbao:record`, `type: hongbao_record`,
/// `schema: 19`).
///
/// The app shows the packet as its own card in the first floor ([HongbaoSpecial], [SpecialThreadCard]) in place of the
/// plugin's html (`div.hb-entry`, its style, the envelope `div#hb_mask` and its script, cut by
/// [bodyHtmlWithoutSpecialBlock]); when that cannot be cut cleanly the floor stays as the web page printed it, without
/// the card. Without `special` (an older plugin, no hongbao) nothing changes. On a floor read back offline, or the
/// post of a notice (no reload), the card only shows the packet.
///
/// The fixtures in `test/data/tsdmapp/hongbao/` are answers of the test forum (Discuz X5 with tsdmapp 3.5.0 and
/// hongbao, 2026-11-07): two whole thread pages (first floor only) of an active packet seen by its sender and of a
/// password packet seen by a member, the `special` of every other state seen (`specials.json`: claimed, withdrawn,
/// expired, closed, all taken, appointed, reply needed, no expiry, a guest), the results of real grabs and
/// withdrawals (`results.json`) and the records (`records.json`), with the forum's host, name, accounts, avatars and
/// form hashes scrubbed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/post_comment/models/post_comment.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/special_thread/repository/hongbao_repository.dart';
import 'package:tsdm_client/features/special_thread/widgets/special_thread_card.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/utils/special_block.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';

const _dir = 'test/data/tsdmapp/hongbao';

Map<String, dynamic> _file(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// A whole thread page answer.
Map<String, dynamic> _thread(String name) => _file('thread_$name');

/// The `special` of state [name] (`specials.json`), parsed with its answer's form hash, account and time offset.
HongbaoSpecial _state(String name) {
  final e = _file('specials')[name] as Map<String, dynamic>;
  return ThreadSpecial.fromApi(
        e['special'],
        formHash: e['formhash'] as String,
        viewerUid: e['uid'] as int,
        timeOffset: (e['timeoffset'] as num?) ?? 8,
      )!
      as HongbaoSpecial;
}

/// The raw `special` of state [name].
Map<String, dynamic> _rawState(String name) =>
    jsonDecode(jsonEncode((_file('specials')[name] as Map<String, dynamic>)['special'])) as Map<String, dynamic>;

Map<String, dynamic> _result(String name) => _file('results')[name] as Map<String, dynamic>;

Map<String, dynamic> _records(String name) => _file('records')[name] as Map<String, dynamic>;

/// The forum's wall clock at UTC+8 of unix time [seconds].
DateTime _clock(int seconds) {
  final t = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).add(const Duration(hours: 8));
  return DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);
}

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// A thread page read back from an offline copy.
final class _OfflineThreadBloc extends Fake implements ThreadBloc {
  @override
  ThreadState get state => ThreadState(tid: '1', status: ThreadStatus.success, offlineSavedAt: DateTime(2026, 11, 7));

  @override
  Stream<ThreadState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;
}

/// The forum answering the posts with [answers] in turn (an exception thrown as it is), the records with [records].
final class _FakeForum {
  _FakeForum(this.answers, {this.records});

  final List<Object?> answers;
  final Object? records;
  final posts = <(String, Map<String, String>)>[];
  final gets = <String>[];

  late final repository = HongbaoRepository(
    post: (url, fields) async {
      posts.add((url, fields));
      final answer = answers.removeAt(0);
      if (answer is Exception) {
        throw answer;
      }
      return answer;
    },
    get: (url) async {
      gets.add(url);
      return records;
    },
  );
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('A. the red packet of the thread page', () {
    test('every field of an active packet seen by its sender; the floor without the plugin html', () {
      final json = _thread('sender_active');
      expect(json['schema'], 18);
      final page = threadPageFromApi(json, 1);
      final p = page.special! as HongbaoSpecial;
      expect(p.tid, 9202754);
      expect(p.packetId, 100);
      expect(p.senderUid, 1031);
      expect(p.senderName, '发包人甲');
      expect(p.senderAvatar, 'https://forum.test/data/avatar/custom.gif');
      expect(p.blessing, 'APP回帖57875');
      expect(p.even, isFalse);
      expect(p.credit?.title, '威望');
      expect(p.shares, 2);
      expect(p.claimedShares, 1);
      expect(p.remainShares, 1);
      expect(p.needReply, isTrue);
      expect(p.replied, isTrue);
      expect(p.hasPassword, isFalse);
      expect(p.appoint, isFalse);
      expect(p.appointed, isNull);
      expect(p.time, _clock(1794057891));
      expect(p.expireTime, _clock(1794144291));
      expect(p.expired, isFalse);
      expect(p.status, HongbaoStatus.active);
      expect(p.isSender, isTrue);
      expect(p.mine, isNull);
      expect(p.canGrab, isTrue);
      expect(p.why, '');
      expect(p.grabUrl, '$baseUrl/plugin.php?id=hongbao:grab');
      expect(p.passwordField, '');
      expect(p.canViewRecords, isTrue);
      expect(p.recordsUrl, '$baseUrl/plugin.php?id=hongbao:record&tid=9202754');
      expect(p.canWithdraw, isTrue);
      expect(p.withdrawUrl, '$baseUrl/plugin.php?id=hongbao:withdraw');
      expect(p.formHash, 'f1f2f3f4');
      expect(p.viewerUid, 1031);

      final first = page.postList.first;
      expect(first.special, same(page.special));
      final original = ((json['posts'] as List).first as Map<String, dynamic>)['body_html'] as String;
      expect(original, contains('hb-entry'));
      for (final gone in ['hb-entry', 'hb_mask', 'hongbaoOpen', 'hbpopin']) {
        expect(first.data, isNot(contains(gone)), reason: gone);
      }
      expect(first.data, contains('<td class="t_f" id="postmessage_11166">APP回帖57875（tsdmapp 3.5.0 驗收用的紅包帖）</td>'));
      expect(first.data, contains('id="post_rate_div_11166"'), reason: 'the rest of the floor stays');
      expect(SpecialThreadCard.aboveContent(p), isTrue);
    });

    test('a password packet seen by a member: the password field, the form sent', () {
      final p = threadPageFromApi(_thread('password_active'), 1).special! as HongbaoSpecial;
      expect(p.hasPassword, isTrue);
      expect(p.passwordField, 'password');
      expect(p.canGrab, isTrue);
      expect(p.canWithdraw, isFalse);
      expect(p.withdrawRequest(), isNull);
      expect(p.canViewRecords, isFalse);
      final request = p.grabRequest(password: 'pw123')!;
      expect(request.method, SpecialRequestMethod.post);
      expect(request.url, '$baseUrl/plugin.php?id=hongbao:grab');
      expect(request.fields, {'tid': '9202761', 'formhash': 'f1f2f3f4', 'password': 'pw123'});
      expect(request.viewerUid, 1033);
      expect(threadPageFromApi(_thread('password_active'), 1).postList.first.data, isNot(contains('hb-entry')));
    });

    test('the sender withdraws: tid and form hash only', () {
      final p = threadPageFromApi(_thread('sender_active'), 1).special! as HongbaoSpecial;
      expect(p.grabRequest()!.fields, {'tid': '9202754', 'formhash': 'f1f2f3f4'});
      final w = p.withdrawRequest()!;
      expect(w.url, '$baseUrl/plugin.php?id=hongbao:withdraw');
      expect(w.fields, {'tid': '9202754', 'formhash': 'f1f2f3f4'});
    });

    test('every state seen: status, why, the account share, what may be done', () {
      final claimed = _state('claimed_best');
      expect(claimed.status, HongbaoStatus.done);
      expect(claimed.why, 'claimed');
      expect(claimed.mine?.amount, 1);
      expect(claimed.mine?.best, isTrue);
      expect(claimed.mine?.time, _clock(1794057859));
      expect(claimed.canGrab, isFalse);
      expect(claimed.grabRequest(), isNull);
      expect(claimed.canViewRecords, isTrue);
      expect(claimed.recordsUrl, '$baseUrl/plugin.php?id=hongbao:record&tid=9202752');
      expect(claimed.tid, 9202752, reason: 'from the records url when there is no form');

      final expected = <String, (HongbaoStatus, String)>{
        'sender_withdrawn': (HongbaoStatus.withdrawn, 'withdrawn'),
        'appointed_done': (HongbaoStatus.done, 'done'),
        'needreply': (HongbaoStatus.active, 'needreply'),
        'appoint': (HongbaoStatus.done, 'appoint'),
        'withdrawn': (HongbaoStatus.withdrawn, 'withdrawn'),
        'expired': (HongbaoStatus.expired, 'expired'),
        'closed': (HongbaoStatus.closed, 'closed'),
        'no_expire_done': (HongbaoStatus.done, 'done'),
        'guest': (HongbaoStatus.active, 'login'),
        'claimed_password': (HongbaoStatus.active, 'claimed'),
        'done': (HongbaoStatus.done, 'done'),
      };
      for (final MapEntry(key: name, value: (status, why)) in expected.entries) {
        final p = _state(name);
        expect(p.status, status, reason: name);
        expect(p.why, why, reason: name);
        expect(p.canGrab, isFalse, reason: name);
        expect(p.canWithdraw, isFalse, reason: name);
      }
      expect(_state('sender_password').canGrab, isTrue, reason: 'the forum lets a sender grab here');
      expect(_state('sender_password').canWithdraw, isTrue);
      expect(_state('needreply').replied, isFalse);
      expect(_state('needreply').even, isTrue);
      expect(_state('appoint').appointed, isFalse);
      expect(_state('appointed_done').appointed, isTrue);
      expect(_state('expired').expired, isTrue);
      expect(_state('no_expire_done').expireTime, isNull);
      expect(_state('guest').viewerUid, isNull);
      expect(_state('guest').mine, isNull);
      expect(_state('guest').canViewRecords, isFalse);
      expect(_state('withdrawn').remainShares, 0);
    });

    test('a form elsewhere, of another module, another thread or an unknown password field is not offered', () {
      HongbaoSpecial parse(Map<String, dynamic> raw) =>
          ThreadSpecial.fromApi(raw, formHash: 'f1f2f3f4', viewerUid: 1031)! as HongbaoSpecial;
      final base = _rawState('sender_password');
      expect(parse(base).canGrab, isTrue);
      for (final action in [
        'https://example.com/plugin.php?id=hongbao:grab',
        'plugin.php?id=hongbao:withdraw',
        'forum.php?mod=misc&action=grab',
        'plugin.php?id=hongbao:grab#x',
        'plugin.php?id=hongbao:grab&tid=1',
      ]) {
        final raw = _rawState('sender_password');
        (raw['grab'] as Map<String, dynamic>)['action'] = action;
        expect(parse(raw).canGrab, isFalse, reason: action);
        expect(parse(raw).grabRequest(), isNull, reason: action);
      }
      final otherField = _rawState('sender_password');
      (otherField['grab'] as Map<String, dynamic>)['password'] = 'pw';
      expect(parse(otherField).canGrab, isFalse);
      final get = _rawState('sender_password');
      (get['withdraw'] as Map<String, dynamic>)['method'] = 'GET';
      expect(parse(get).canWithdraw, isFalse);
      final foreignRecords = _rawState('claimed_best')
        ..['records_url'] = 'https://example.com/plugin.php?id=hongbao:record&tid=9202752';
      expect(
        (ThreadSpecial.fromApi(foreignRecords, formHash: 'f1f2f3f4', viewerUid: 1031)! as HongbaoSpecial).recordsUrl,
        isNull,
      );
      expect(parse(base).grabRequest()!.fields['password'], '', reason: 'the field is sent, empty, when none typed');
      final noHash = ThreadSpecial.fromApi(_rawState('sender_password'), viewerUid: 1035)! as HongbaoSpecial;
      expect(noHash.canGrab, isFalse, reason: 'no button that would send nothing');
      expect(noHash.canWithdraw, isFalse);
      expect(noHash.grabRequest(), isNull);
      // A state the app does not know: no block, the floor as printed.
      expect(ThreadSpecial.fromApi(_rawState('sender_password')..['status'] = 'paused', formHash: 'f1f2f3f4'), isNull);
      expect(ThreadSpecial.fromApi(_rawState('sender_password')..remove('status'), formHash: 'f1f2f3f4'), isNull);
    });

    test('an older plugin (no hongbao special): the floor as the forum printed it', () {
      final json = _thread('sender_active')
        ..['schema'] = 15
        ..['special'] = null;
      final page = threadPageFromApi(json, 1);
      expect(page.special, isNull);
      expect(page.postList.first.special, isNull);
      expect(page.postList.first.data, contains('hb-entry'));
      // A type the app does not know is no block either.
      expect(ThreadSpecial.fromApi({'type': 'hongbao2'}), isNull);
    });

    test('the plugin html that cannot be cut cleanly: the floor as printed, without the card', () {
      final json = _thread('sender_active');
      final first = (json['posts'] as List).first as Map<String, dynamic>;
      // The envelope left open: the parser takes the content into it.
      first['body_html'] = (first['body_html'] as String).replaceFirst(
        '<div class="mask" id="hb_mask">',
        '<div class="mask" id="hb_mask"><div>',
      );
      final page = threadPageFromApi(json, 1);
      expect(page.postList.first.special, isNull);
      expect(page.postList.first.data, splitPostComments(first['body_html'] as String, '${first['pid']}').data);
      expect(page.postList.first.data, contains('hb-entry'));

      // A cut that leaves the envelope behind (its id renamed): no card either.
      final renamed = _thread('sender_active');
      final renamedFirst = (renamed['posts'] as List).first as Map<String, dynamic>;
      renamedFirst['body_html'] = (renamedFirst['body_html'] as String).replaceFirst(
        'class="mask" id="hb_mask"',
        'class="mask2" id="hb_mask"',
      );
      expect(threadPageFromApi(renamed, 1).postList.first.special, isNull);
      expect(
        threadPageFromApi(renamed, 1).postList.first.data,
        splitPostComments(renamedFirst['body_html'] as String, '${renamedFirst['pid']}').data,
      );

      // The packet of another thread is none of this page.
      final other = _thread('sender_active');
      (other['thread'] as Map<String, dynamic>)['tid'] = 9202999;
      expect(threadPageFromApi(other, 1).special, isNull);
      expect(threadPageFromApi(other, 1).postList.first.special, isNull);

      // Another type's cut leaves the red packet html alone.
      final poll = ThreadSpecial.fromApi({'type': 'poll'})!;
      final body = ((_thread('sender_active')['posts'] as List).first as Map<String, dynamic>)['body_html'] as String;
      expect(bodyHtmlWithoutSpecialBlock(body, poll, pid: '11166'), body);
    });
  });

  group('B. the results of grabbing and withdrawing', () {
    test('grabbed: the amount, the unit, the luckiest; grabbed before', () {
      final success = hongbaoOutcomeOf(_result('g_success'), withdraw: false) as HongbaoGrabbed;
      expect((success.amount, success.unit, success.best, success.already), ('2', '威望', true, false));
      final password = hongbaoOutcomeOf(_result('g_pw_success'), withdraw: false) as HongbaoGrabbed;
      expect((password.amount, password.already), ('1', false));
      final already = hongbaoOutcomeOf(_result('g_already'), withdraw: false) as HongbaoGrabbed;
      expect((already.amount, already.best, already.already), ('1', true, true));
    });

    test('refused: the forum words, the reason, whether the page is read again', () {
      final cases = <String, (String, String, bool)>{
        'g_badpw': ('口令錯誤,再試試', 'badpw', false),
        'g_done': ('紅包已被搶光', 'done', true),
        'g_needreply': ('需先在本主題回覆後才能搶', 'needreply', false),
        'g_withdrawn': ('紅包已被撤回', 'withdrawn', true),
        'g_withdrawn2': ('紅包已被撤回', 'withdrawn', true),
        'g_guest': ('請先登入再領取', 'login', false),
        'g_noformhash': ('請求已過期,請重新整理頁面', 'formhash', true),
      };
      for (final MapEntry(key: name, value: (message, reason, reloads)) in cases.entries) {
        final r = hongbaoOutcomeOf(_result(name), withdraw: false) as HongbaoRefused;
        expect(r.message, message, reason: name);
        expect(r.reason, reason, reason: name);
        expect(r.reloads, reloads, reason: name);
        expect(r.badPassword, reason == 'badpw', reason: name);
      }
    });

    test('withdrawn: the refund; ended, not the sender', () {
      expect((hongbaoOutcomeOf(_result('w_success'), withdraw: true) as HongbaoWithdrawn).refunded, '1');
      final ended = hongbaoOutcomeOf(_result('w_ended'), withdraw: true) as HongbaoRefused;
      expect((ended.message, ended.reason, ended.reloads), ('紅包已結束,無法撤回', 'ended', true));
      final notSender = hongbaoOutcomeOf(_result('w_notsender'), withdraw: true) as HongbaoRefused;
      expect((notSender.message, notSender.reason, notSender.reloads), ('只有發送者能撤回這個紅包', 'notsender', false));
    });

    test('anything else tells nothing', () {
      expect(hongbaoOutcomeOf(_result('g_success'), withdraw: true), isA<HongbaoUnknown>(), reason: 'another handler');
      expect(hongbaoOutcomeOf(_result('w_success'), withdraw: false), isA<HongbaoUnknown>());
      expect(hongbaoOutcomeOf('<html>System Error</html>', withdraw: false), isA<HongbaoUnknown>());
      expect(hongbaoOutcomeOf(null, withdraw: false), isA<HongbaoUnknown>());
      final page = _result('g_success')
        ..['kind'] = 'page'
        ..['document'] = '{"ok":1}';
      expect(hongbaoOutcomeOf(page, withdraw: false), isA<HongbaoUnknown>());
    });

    test('the repository posts the form once; a failed request tells nothing', () async {
      final p = threadPageFromApi(_thread('password_active'), 1).special! as HongbaoSpecial;
      final forum = _FakeForum([_result('g_pw_success'), Exception('down')]);
      final request = p.grabRequest(password: 'pw123')!;
      expect(await forum.repository.submit(request, withdraw: false), isA<HongbaoGrabbed>());
      expect(forum.posts.single, ('$baseUrl/plugin.php?id=hongbao:grab', request.fields));
      expect(await forum.repository.submit(request, withdraw: false), isA<HongbaoUnknown>());
      expect(forum.posts, hasLength(2));
    });
  });

  group('C. the records', () {
    test('who grabbed what and when, oldest first; refused with the forum words', () {
      final ok = hongbaoRecordsOf(_records('rec_ok_9202752')) as HongbaoRecords;
      expect(ok.shares, 3);
      expect(ok.credit?.title, '威望');
      expect(ok.records.map((e) => (e.uid, e.username, e.amount, e.best)), [
        (1031, '发包人甲', 1, true),
        (1037, '领取人乙', 1, false),
        (1038, '领取人丙', 1, false),
      ]);
      expect(ok.records.first.avatar, 'https://forum.test/data/avatar/custom.gif');
      expect(ok.records.first.time, _clock(1794057859));
      final sender = hongbaoRecordsOf(_records('rec_sender_pw')) as HongbaoRecords;
      expect(sender.records.single.username, '领取人甲');

      expect((hongbaoRecordsOf(_records('rec_denied')) as HongbaoRecordsRefused).message, '開包後才能看大家的手氣');
      expect((hongbaoRecordsOf(_records('rec_guest')) as HongbaoRecordsRefused).message, '請先登入');
      expect(hongbaoRecordsOf('<html></html>'), isA<HongbaoRecordsFailed>());
      expect(hongbaoRecordsOf(_records('rec_ok_9202752')..['schema'] = 18), isA<HongbaoRecordsFailed>());
    });

    test('the repository reads the records url', () async {
      final forum = _FakeForum(const [], records: _records('rec_ok_9202752'));
      final outcome = await forum.repository.records('$baseUrl/plugin.php?id=hongbao:record&tid=9202752');
      expect(outcome, isA<HongbaoRecords>());
      expect(forum.gets, ['$baseUrl/plugin.php?id=hongbao:record&tid=9202752']);
    });
  });

  group('D. the card', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc bloc;

    setUp(() async {
      await LocaleSettings.setLocale(AppLocale.zhTw);
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });
    tearDown(() async {
      await bloc.close();
      await getIt.reset();
      await settings.dispose();
      await db.close();
      await LocaleSettings.setLocale(AppLocale.en);
    });

    Future<void> pump(WidgetTester tester, Widget child, {HongbaoRepository? repository}) async {
      Widget app = MaterialApp(
        scaffoldMessengerKey: snackbarKey,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );
      if (repository != null) {
        app = RepositoryProvider<HongbaoRepository>.value(value: repository, child: app);
      }
      await tester.pumpWidget(
        BlocProvider<SettingsBloc>.value(
          value: bloc,
          child: TranslationProvider(child: app),
        ),
      );
      await tester.pump();
    }

    // The images of the cards are asked of an offline client: let their failure land before the test ends.
    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('the packet: sender, blessing, split, shares, conditions, expiry, state; no total amount', (
      tester,
    ) async {
      final tr = t.specialThread.hongbao;
      final p = threadPageFromApi(_thread('sender_active'), 1).special!;
      await pump(tester, SpecialThreadCard(p, pid: '11166', onReload: () {}));
      expect(find.text(tr.title), findsOneWidget);
      expect(find.text('发包人甲'), findsOneWidget);
      expect(find.text('APP回帖57875'), findsOneWidget);
      expect(find.text(tr.status.active), findsOneWidget);
      expect(find.text(tr.lucky), findsOneWidget);
      expect(find.text(tr.shares(claimed: 1, shares: 2)), findsOneWidget);
      expect(find.text(tr.needReply), findsOneWidget);
      expect(find.text(tr.password), findsNothing);
      expect(find.text(tr.expireAt(time: _clock(1794144291).yyyyMMDDHHMM())), findsOneWidget);
      expect(find.text(tr.grab), findsOneWidget);
      expect(find.text(tr.records), findsOneWidget);
      expect(find.text(tr.withdraw), findsOneWidget);

      await pump(tester, SpecialThreadCard(_state('claimed_best'), pid: '1', onReload: () {}));
      expect(find.text(tr.mine(amount: 1, credit: ' 威望')), findsOneWidget);
      expect(find.text(tr.best), findsOneWidget);
      expect(find.text(tr.status.done), findsOneWidget);
      expect(find.text(tr.why.claimed), findsNothing, reason: 'the share says it');
      expect(find.text(tr.grab), findsNothing);

      await pump(tester, SpecialThreadCard(_state('no_expire_done'), pid: '1', onReload: () {}));
      expect(find.text(tr.noExpire), findsOneWidget);
      expect(find.text(tr.even), findsOneWidget);

      for (final (name, status, why) in [
        ('needreply', tr.status.active, tr.why.needreply),
        ('appoint', tr.status.done, tr.why.appoint),
        ('guest', tr.status.active, tr.why.login),
      ]) {
        await pump(tester, SpecialThreadCard(_state(name), pid: '1', onReload: () {}));
        expect(find.text(status), findsOneWidget, reason: name);
        expect(find.text(why), findsOneWidget, reason: name);
        expect(find.text(tr.grab), findsNothing, reason: name);
      }
      for (final (name, status) in [
        ('withdrawn', tr.status.withdrawn),
        ('expired', tr.status.expired),
        ('closed', tr.status.closed),
      ]) {
        await pump(tester, SpecialThreadCard(_state(name), pid: '1', onReload: () {}));
        expect(find.text(status), findsOneWidget, reason: name);
      }
      await pump(tester, SpecialThreadCard(_state('appoint'), pid: '1', onReload: () {}));
      expect(find.text(tr.appoint), findsOneWidget);

      // What the test forum cannot show (a sender may not grab, red packets turned off): the plugin's keys as given.
      for (final (why, text) in [('self', tr.why.self), ('disabled', tr.why.disabled)]) {
        final raw = _rawState('sender_password')
          ..['can_grab'] = 0
          ..['why'] = why
          ..['grab'] = null;
        final p = ThreadSpecial.fromApi(raw, formHash: 'f1f2f3f4', viewerUid: 1035)! as HongbaoSpecial;
        expect(p.canGrab, isFalse, reason: why);
        await pump(tester, SpecialThreadCard(p, pid: '1', onReload: () {}));
        expect(find.text(text), findsOneWidget, reason: why);
        expect(find.text(tr.grab), findsNothing, reason: why);
        expect(find.text(tr.withdraw), findsOneWidget, reason: 'the sender still withdraws');
      }
      await finish(tester);
    });

    testWidgets('grabbing: the form sent once, the amount told, the page read again', (tester) async {
      final tr = t.specialThread.hongbao;
      final forum = _FakeForum([_result('g_success')]);
      var reloads = 0;
      final p = threadPageFromApi(_thread('sender_active'), 1).special!;
      await pump(
        tester,
        SpecialThreadCard(p, pid: '11166', onReload: () => reloads++),
        repository: forum.repository,
      );
      await tester.tap(find.text(tr.grab));
      await tester.pumpAndSettle();
      expect(forum.posts.single.$2, {'tid': '9202754', 'formhash': 'f1f2f3f4'});
      expect(find.text('${tr.grabbed(amount: '2', unit: '威望')} · ${tr.best}'), findsOneWidget);
      expect(reloads, 1);
      await finish(tester);
    });

    testWidgets('a password packet: asked first, a wrong one asked again with the forum words', (tester) async {
      final tr = t.specialThread.hongbao;
      final forum = _FakeForum([_result('g_badpw'), _result('g_pw_success')]);
      var reloads = 0;
      final p = threadPageFromApi(_thread('password_active'), 1).special!;
      await pump(
        tester,
        SpecialThreadCard(p, pid: '1', onReload: () => reloads++),
        repository: forum.repository,
      );
      await tester.tap(find.text(tr.grab));
      await tester.pumpAndSettle();
      expect(find.text(tr.passwordTitle), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'wrong');
      await tester.tap(find.widgetWithText(FilledButton, tr.grab).last);
      await tester.pumpAndSettle();
      expect(forum.posts.first.$2['password'], 'wrong');
      expect(find.text(tr.passwordTitle), findsOneWidget, reason: 'asked again');
      expect(find.text('口令錯誤,再試試'), findsOneWidget);
      expect(reloads, 0);
      await tester.enterText(find.byType(TextField), 'pw123');
      await tester.tap(find.widgetWithText(FilledButton, tr.grab).last);
      await tester.pumpAndSettle();
      expect(forum.posts.last.$2, {'tid': '9202761', 'formhash': 'f1f2f3f4', 'password': 'pw123'});
      expect(find.text(tr.passwordTitle), findsNothing);
      expect(reloads, 1);

      // Cancelled: nothing sent.
      final idle = _FakeForum([]);
      await pump(
        tester,
        SpecialThreadCard(p, pid: '1', onReload: () => reloads++),
        repository: idle.repository,
      );
      await tester.tap(find.text(tr.grab));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      expect(idle.posts, isEmpty);
      await finish(tester);
    });

    testWidgets('refused: a changed packet reads the page again, another refusal stays in the card', (tester) async {
      final tr = t.specialThread.hongbao;
      var reloads = 0;
      final p = threadPageFromApi(_thread('sender_active'), 1).special!;
      final done = _FakeForum([_result('g_done')]);
      await pump(
        tester,
        SpecialThreadCard(p, pid: '1', onReload: () => reloads++),
        repository: done.repository,
      );
      await tester.tap(find.text(tr.grab));
      await tester.pumpAndSettle();
      expect(find.text('紅包已被搶光'), findsOneWidget);
      expect(reloads, 1);

      final needReply = _FakeForum([_result('g_needreply')]);
      await pump(
        tester,
        SpecialThreadCard(p, pid: '1', onReload: () => reloads++),
        repository: needReply.repository,
      );
      await tester.tap(find.text(tr.grab));
      await tester.pumpAndSettle();
      expect(find.text('需先在本主題回覆後才能搶'), findsOneWidget);
      expect(reloads, 1);

      snackbarKey.currentState!.clearSnackBars();
      await tester.pumpAndSettle();
      // The page read again (a new packet) clears the refusal.
      final next = threadPageFromApi(_thread('sender_active'), 1).special!;
      await pump(
        tester,
        SpecialThreadCard(next, pid: '1', onReload: () => reloads++),
        repository: needReply.repository,
      );
      expect(find.text('需先在本主題回覆後才能搶'), findsNothing);

      final unknown = _FakeForum(['<html></html>']);
      await pump(
        tester,
        SpecialThreadCard(p, pid: '1', onReload: () => reloads++),
        repository: unknown.repository,
      );
      await tester.tap(find.text(tr.grab));
      await tester.pumpAndSettle();
      expect(find.text(t.specialThread.unknown), findsOneWidget);
      expect(reloads, 2);
      await finish(tester);
    });

    testWidgets('withdrawing: asked first, the refund told, the page read again', (tester) async {
      final tr = t.specialThread.hongbao;
      final forum = _FakeForum([_result('w_success')]);
      var reloads = 0;
      final p = threadPageFromApi(_thread('sender_active'), 1).special!;
      await pump(
        tester,
        SpecialThreadCard(p, pid: '1', onReload: () => reloads++),
        repository: forum.repository,
      );
      await tester.tap(find.text(tr.withdraw));
      await tester.pumpAndSettle();
      expect(find.text(tr.withdrawConfirmTitle), findsOneWidget);
      expect(forum.posts, isEmpty);
      await tester.tap(find.text(t.general.ok));
      await tester.pumpAndSettle();
      expect(forum.posts.single.$1, '$baseUrl/plugin.php?id=hongbao:withdraw');
      expect(find.text(tr.withdrawn(amount: '1', unit: '威望')), findsOneWidget);
      expect(reloads, 1);
      await finish(tester);
    });

    testWidgets('the records: names, amounts, the luckiest; the forum refusal', (tester) async {
      final tr = t.specialThread.hongbao;
      final forum = _FakeForum(const [], records: _records('rec_ok_9202752'));
      await pump(
        tester,
        SpecialThreadCard(_state('claimed_best'), pid: '1', onReload: () {}),
        repository: forum.repository,
      );
      await tester.tap(find.text(tr.records));
      await tester.pumpAndSettle();
      expect(forum.gets, ['$baseUrl/plugin.php?id=hongbao:record&tid=9202752']);
      expect(find.text('领取人乙'), findsOneWidget);
      expect(find.text('领取人丙'), findsOneWidget);
      expect(find.text('1 威望'), findsNWidgets(3));
      expect(find.text(_clock(1794057859).yyyyMMDDHHMM()), findsNWidgets(3));

      await finish(tester);
      final refusing = _FakeForum(const [], records: _records('rec_denied'));
      await pump(
        tester,
        SpecialThreadCard(_state('claimed_best'), pid: '1', onReload: () {}),
        repository: refusing.repository,
      );
      await tester.tap(find.text(tr.records));
      await tester.pumpAndSettle();
      expect(find.text('開包後才能看大家的手氣'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('offline copies and the post of a notice: the packet only, no action', (tester) async {
      final tr = t.specialThread.hongbao;
      final p = threadPageFromApi(_thread('sender_active'), 1).special!;
      await pump(
        tester,
        BlocProvider<ThreadBloc>.value(
          value: _OfflineThreadBloc(),
          child: SpecialThreadCard(p, pid: '1', onReload: () {}),
        ),
      );
      expect(find.text('APP回帖57875'), findsOneWidget);
      expect(find.text(tr.grab), findsNothing);
      expect(find.text(tr.records), findsNothing);
      expect(find.text(tr.withdraw), findsNothing);

      await pump(tester, SpecialThreadCard(p, pid: '1'));
      expect(find.text('APP回帖57875'), findsOneWidget);
      expect(find.text(tr.grab), findsNothing);
      expect(find.text(tr.records), findsNothing);
      expect(find.text(tr.withdraw), findsNothing);
      await finish(tester);
    });
  });
}
