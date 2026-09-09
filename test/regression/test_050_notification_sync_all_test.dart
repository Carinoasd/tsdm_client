import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_sync_all_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Sync the notifications of every account saved on this device with one button (issue #10): accounts run one after
/// another with their own cookie, rows land in the per-uid tables through the same reconcile as the normal sync, the
/// current account and its unread badge are the only things published, an expired session and a 429 are reported
/// per account without stopping the others.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 2000);
const _carol = UserLoginInfo(username: 'Carol', uid: 3000);

/// Cookie row in the format the persistent cookie jar reads back: the auth cookie is sent with every request.
Map<String, String> _jar(String token) => {
  '.index': '["$baseHost"]',
  baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=$token; Path=/;_crt=1"}}',
};

/// Notification times have minute precision: `yyyy-M-d HH:mm`, one hour ago so it is inside the 3-day window.
final DateTime _time = DateTime.now().subtract(const Duration(hours: 1));
final _timeText =
    '${_time.year}-${_time.month}-${_time.day} '
    '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';
final int _timestamp = _timeText.parseToDateTimeUtc8()!.millisecondsSinceEpoch ~/ 1000;

String _noticePage(int nid, {required bool unread}) =>
    '<html><body><div id="um"></div><div id="ct"><div class="mn"><div class="bm bw0"><div class="xld xlda">\n'
    '<div class="nts"><dl class="cl" notice="$nid" id="notice_$nid">\n'
    '<dd class="m avt mbn"><a href="home.php?mod=space&amp;uid=1001"><img src="a.jpg"></a></dd>\n'
    '<dt><a class="d b" href="#">屏蔽</a> <span class="xg1 xw0"><span title="$_timeText">1 分钟前</span></span></dt>\n'
    '<dd class="ntc_body" style="${unread ? 'color:#000;font-weight:bold;' : ''}">\n'
    '<a href="home.php?mod=space&uid=1001">Peer</a> 回复了您的帖子 <a href="forum.php?mod=redirect&pid=1">T</a></dd>\n'
    '</dl></div></div></div></div></div></body></html>';

String _pmPage(int peerUid, String text, {required bool unread}) =>
    '<html><body><div id="um"></div><form id="deletepmform"><div>\n'
    '<dl id="pmlist_$peerUid" class="cl${unread ? ' newpm' : ''}">\n'
    '<dd class="m avt"><a href="home.php?mod=space&amp;uid=$peerUid"><img src="a.jpg"></a>'
    '${unread ? '<div class="newpm_avt"></div>' : ''}</dd>'
    '<dd class="ptm pm_c"><div class="o"></div><a href="home.php?mod=space&uid=$peerUid" class="xw1">Peer</a> 对 '
    '<span class="xi2">您</span> 说 :<br />$text &nbsp; <br /><span class="xg1"><span title="$_timeText">1 小时前</span></span></dd>\n'
    '</dl></div></form></body></html>';

String _bmPage(int pmid, String text) =>
    '<html><body><div id="um"></div><form id="deletepmform"><div>\n'
    '<dl id="gpmlist_$pmid" class="cl newpm"><dd class="m avt"><div class="newpm_avt"></div></dd>\n'
    '<dd class="ptm"><span class="xg1"><span title="$_timeText">1 小时前</span></span><br />$text</dd>\n'
    '</dl></div></form></body></html>';

const _emptyPage = '<html><body><div id="um"></div><div class="nts"></div></body></html>';
const _guestPage =
    '<html><body><form id="lsform" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /> '
    '<input name="username" /></form></body></html>';

typedef _Answer = (int status, String body, Map<String, List<String>> headers);

_Answer _ok(String body) => (200, body, {});

/// Answers each of the three notification pages from its own queue, in order, and records every request with the
/// cookie it carried. One account fetches every page once, so the queues advance one account at a time.
final class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter({required this.notice, required this.pm, required this.bm});

  final List<_Answer> notice;
  final List<_Answer> pm;
  final List<_Answer> bm;

  /// `(page kind, cookie header)` in arrival order.
  final requests = <(String, String?)>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final q = options.uri.queryParameters;
    final (kind, queue) = switch (q) {
      {'do': 'notice'} => ('notice', notice),
      {'filter': 'privatepm'} => ('pm', pm),
      {'filter': 'announcepm'} => ('bm', bm),
      _ => fail('unexpected request: ${options.uri}'),
    };
    requests.add((kind, options.headers['cookie'] as String?));
    if (queue.isEmpty) {
      fail('unexpected $kind request #${requests.length}');
    }
    final (status, body, headers) = queue.removeAt(0);
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
  late CookieProvider current;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    Dio dio() => Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter;
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(() => NetClientProvider.build(dio: dio()));
    await settings.init();
    // Three accounts on the device, Alice is current: only she is in the global cookie provider.
    for (final u in [_alice, _bob, _carol]) {
      await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: _jar(u.username!.toLowerCase()));
    }
    current = CookieProvider(_alice, _jar('alice'));
    getIt.registerSingleton<CookieProvider>(current);
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  NotificationSyncAllRepository repo() => NotificationSyncAllRepository(
    storageProvider: storage,
    notificationRepository: NotificationRepository(),
    clientFactory: (cookie) => NetClientProvider.buildNoCookie(
      dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
      cookie: cookie,
    ),
    gap: Duration.zero,
  );

  Future<NotificationSyncAllInfo> run(NotificationSyncAllRepository r, List<UserLoginInfo> users) async {
    final result = await r.syncAll(accounts: users).run();
    expect(result.isRight(), isTrue, reason: '$result');
    await r.dispose();
    return result.getOrElse((_) => throw StateError('unreachable'));
  }

  /// Bob has one unread notice, one unread conversation and one broadcast; Alice one unread notice; Carol's session
  /// is gone.
  _ScriptedAdapter threeAccounts() => _ScriptedAdapter(
    notice: [_ok(_noticePage(11, unread: true)), _ok(_noticePage(1984, unread: true)), _ok(_guestPage)],
    pm: [_ok(_emptyPage), _ok(_pmPage(3001, 'hello there', unread: true)), _ok(_guestPage)],
    bm: [_ok(_emptyPage), _ok(_bmPage(77, 'Broadcast text')), _ok(_guestPage)],
  );

  test(
    'accounts run one after another with their own cookie, rows land per uid, the current account is untouched',
    () async {
      adapter = threeAccounts();
      final before = DateTime.now();
      final info = await run(repo(), [_alice, _bob, _carol]);

      // Strict account order, three pages each, each with that account's auth cookie.
      expect(adapter.requests, hasLength(9));
      for (final (i, token) in ['alice', 'bob', 'carol'].indexed) {
        final slice = adapter.requests.sublist(i * 3, i * 3 + 3);
        expect(slice.map((e) => e.$1), unorderedEquals(['notice', 'pm', 'bm']), reason: 'account #$i pages');
        expect(slice.map((e) => e.$2), everyElement('Ystv_2132_auth=$token'), reason: 'account #$i cookie');
      }

      expect(info.waiting, isEmpty);
      expect(info.running, isEmpty);
      expect(info.finished.map((e) => e.$1), [_alice, _bob, _carol]);
      expect(
        info.finished[0].$2,
        isA<NotificationSyncResultSuccess>()
            .having((e) => (e.newNotice, e.newPersonalMessage, e.newBroadcastMessage), 'new', (1, 0, 0))
            .having((e) => (e.unreadNotice, e.unreadPersonalMessage, e.unreadBroadcastMessage), 'unread', (1, 0, 0)),
      );
      expect(
        info.finished[1].$2,
        isA<NotificationSyncResultSuccess>()
            .having((e) => (e.newNotice, e.newPersonalMessage, e.newBroadcastMessage), 'new', (1, 1, 1))
            .having((e) => (e.unreadNotice, e.unreadPersonalMessage, e.unreadBroadcastMessage), 'unread', (1, 1, 1)),
      );
      expect(info.finished[2].$2, isA<NotificationSyncResultNotAuthorized>());

      // Bob's rows with the server unread flags, under Bob's uid.
      final bobStored = await storage.fetchNotificationSince(uid: _bob.uid!, timestamp: 0).run();
      expect(bobStored.noticeList.single, isA<NoticeEntity>().having((e) => e.nid, 'nid', 1984));
      expect(bobStored.noticeList.single.alreadyRead, isFalse);
      expect(bobStored.noticeList.single.timestamp, _timestamp);
      final pm = bobStored.personalMessageList.single;
      expect(
        (pm.peerUid, pm.peerUsername, pm.data, pm.sender, pm.alreadyRead),
        (3001, 'Peer', 'hello there', false, false),
      );
      final bm = bobStored.broadcastMessageList.single;
      expect((bm.pmid, bm.data, bm.alreadyRead), (77, 'Broadcast text', false));
      final bobLastFetch = (await storage.fetchLastFetchNoticeTime(_bob.uid!).run()).getOrElse((_) => null);
      expect(bobLastFetch, isNotNull);
      expect(
        bobLastFetch!.isBefore(DateTime(before.year, before.month, before.day, before.hour, before.minute)),
        isFalse,
      );

      // Alice got her own rows, Carol nothing.
      final aliceStored = await storage.fetchNotificationSince(uid: _alice.uid!, timestamp: 0).run();
      expect(aliceStored.noticeList.map((e) => e.nid), [11]);
      final carolStored = await storage.fetchNotificationSince(uid: _carol.uid!, timestamp: 0).run();
      expect(carolStored.noticeList, isEmpty);
      expect((await storage.fetchLastFetchNoticeTime(_carol.uid!).run()).getOrElse((_) => null), isNull);

      // The global cookie provider and the stored cookies did not move.
      expect(current.userLoginInfo, _alice);
      expect(await current.read(baseHost), contains('Ystv_2132_auth=alice'));
      expect('${storage.getCookieByUidSync(_alice.uid!)![baseHost]}', contains('Ystv_2132_auth=alice'));
      expect('${storage.getCookieByUidSync(_bob.uid!)![baseHost]}', contains('Ystv_2132_auth=bob'));
    },
  );

  test('a stored read copy stays read when listed again unread: the same reconcile as the normal sync', () async {
    await storage
        .saveNotification(
          uid: _bob.uid!,
          notificationGroup: NotificationGroup(
            noticeList: [NoticeEntity(uid: _bob.uid!, nid: 1984, timestamp: _timestamp, data: 'n', alreadyRead: true)],
            personalMessageList: [
              PersonalMessageEntity(
                uid: _bob.uid!,
                timestamp: _timestamp,
                data: 'hello there',
                peerUid: 3001,
                peerUsername: 'Peer',
                sender: false,
                alreadyRead: true,
              ),
            ],
            broadcastMessageList: [],
          ),
        )
        .run();
    adapter = _ScriptedAdapter(
      notice: [_ok(_noticePage(1984, unread: true))],
      pm: [_ok(_pmPage(3001, 'hello there', unread: true))],
      bm: [_ok(_bmPage(77, 'Broadcast text'))],
    );
    final info = await run(repo(), [_bob]);
    expect(
      info.finished.single.$2,
      isA<NotificationSyncResultSuccess>()
          .having((e) => (e.newNotice, e.newPersonalMessage, e.newBroadcastMessage), 'new', (0, 0, 1))
          .having((e) => (e.unreadNotice, e.unreadPersonalMessage, e.unreadBroadcastMessage), 'unread', (0, 0, 1)),
    );
    final stored = await storage.fetchNotificationSince(uid: _bob.uid!, timestamp: 0).run();
    expect(stored.noticeList.single.alreadyRead, isTrue);
    expect(stored.personalMessageList.single.alreadyRead, isTrue);
    expect(stored.broadcastMessageList.single.alreadyRead, isFalse);
  });

  test('a 429 without Retry-After is reported as rate limited, the next account still runs', () async {
    adapter = _ScriptedAdapter(
      notice: [(429, 'Too Many Requests', {}), _ok(_noticePage(1984, unread: true))],
      pm: [_ok(_emptyPage), _ok(_emptyPage)],
      bm: [_ok(_emptyPage), _ok(_emptyPage)],
    );
    final info = await run(repo(), [_alice, _bob]);
    expect(adapter.requests, hasLength(6));
    expect(info.finished[0].$1, _alice);
    expect(info.finished[0].$2, isA<NotificationSyncResultRateLimited>());
    expect(info.finished[1].$1, _bob);
    expect(info.finished[1].$2, isA<NotificationSyncResultSuccess>().having((e) => e.newNotice, 'newNotice', 1));
    expect((await storage.fetchLastFetchNoticeTime(_alice.uid!).run()).getOrElse((_) => null), isNull);
  });

  test('a 429 with Retry-After is retried once after that wait', () async {
    adapter = _ScriptedAdapter(
      notice: [
        (
          429,
          'Too Many Requests',
          {
            'retry-after': ['1'],
          },
        ),
        _ok(_noticePage(11, unread: true)),
      ],
      pm: [_ok(_emptyPage), _ok(_emptyPage)],
      bm: [_ok(_emptyPage), _ok(_emptyPage)],
    );
    final watch = Stopwatch()..start();
    final info = await run(repo(), [_alice]);
    expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 1)));
    expect(adapter.requests, hasLength(6));
    expect(info.finished.single.$2, isA<NotificationSyncResultSuccess>());
  });

  group('NotificationSyncAllCubit', () {
    late NotificationInfoRepository infoRepository;
    late List<NotificationStateInfo> published;

    setUp(() {
      infoRepository = NotificationInfoRepository();
      published = [];
      infoRepository.status.listen(published.add);
    });

    tearDown(() async => infoRepository.dispose());

    NotificationSyncAllCubit cubit(UserLoginInfo? user) => NotificationSyncAllCubit(
      repository: repo(),
      storageProvider: storage,
      authenticationRepository: AuthenticationRepository(user: user),
      infoRepository: infoRepository,
    );

    test('publishes exactly the current user recount from storage, never other accounts', () async {
      adapter = threeAccounts();
      final c = cubit(_alice);
      final states = <NotificationSyncAllState>[];
      c.stream.listen(states.add);
      await c.start();
      await Future<void>.delayed(Duration.zero);

      expect(states.first, isA<NotificationSyncAllStatePreparing>());
      expect(states.whereType<NotificationSyncAllStateRunning>(), isNotEmpty);
      expect(states.last, isA<NotificationSyncAllStateFinished>());
      final finished = states.last as NotificationSyncAllStateFinished;
      expect(finished.results.map((e) => e.$1), [_alice, _bob, _carol]);
      // Alice: one unread notice. Bob's 1/1/1 must not leak into the badge.
      expect(published, [const NotificationStateInfo(notice: 1, personalMessage: 0, broadcastMessage: 0)]);
      expect(c.isRunning, isFalse);
      await c.close();
    });

    test('publishes nothing without a current user, a second start while running is ignored', () async {
      adapter = threeAccounts();
      final c = cubit(null);
      final first = c.start();
      await Future<void>.delayed(Duration.zero);
      expect(c.isRunning, isTrue);
      await c.start();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(adapter.requests, hasLength(9), reason: 'the second start must not run the accounts again');
      expect(published, isEmpty);
      expect(c.state, isA<NotificationSyncAllStateFinished>());
      await c.close();
    });
  });

  group('NotificationRepository', () {
    test('fetchNotificationV2 still emits Loading then Success on the stream', () async {
      adapter = _ScriptedAdapter(
        notice: [_ok(_noticePage(11, unread: true))],
        pm: [_ok(_emptyPage)],
        bm: [_ok(_emptyPage)],
      );
      final r = NotificationRepository();
      final events = <NotificationInfoState>[];
      r.status.listen(events.add);
      final result = await r.fetchNotificationV2(uid: _alice.uid!).run();
      expect(result.isRight(), isTrue, reason: '$result');
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(2));
      expect(events[0], isA<NotificationInfoStateLoading>());
      expect(
        events[1],
        isA<NotificationInfoStateSuccess>().having((e) => e.uid, 'uid', _alice.uid).having(
          (e) => e.info.noticeList.map((n) => n.id),
          'notice ids',
          [11],
        ),
      );
      expect(adapter.requests.map((e) => e.$2), everyElement('Ystv_2132_auth=alice'));
      await r.dispose();
    });

    test('fetchNotificationV2 still emits Loading then Failure on the stream', () async {
      adapter = _ScriptedAdapter(notice: [(500, 'boom', {})], pm: [_ok(_emptyPage)], bm: [_ok(_emptyPage)]);
      final r = NotificationRepository();
      final events = <NotificationInfoState>[];
      r.status.listen(events.add);
      final result = await r.fetchNotificationV2(uid: _alice.uid!).run();
      expect(result.isLeft(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(events.map((e) => e.runtimeType), [NotificationInfoStateLoading, NotificationInfoStateFailure]);
      await r.dispose();
    });
  });

  test('NotificationBloc rebuilds its lists from storage on request without fetching', () async {
    adapter = _ScriptedAdapter(notice: [], pm: [], bm: []);
    await storage
        .saveNotification(
          uid: _alice.uid!,
          notificationGroup: NotificationGroup(
            noticeList: [
              NoticeEntity(uid: _alice.uid!, nid: 1, timestamp: 100, data: 'a', alreadyRead: false),
              NoticeEntity(uid: _alice.uid!, nid: 2, timestamp: 200, data: 'b', alreadyRead: true),
            ],
            personalMessageList: [],
            broadcastMessageList: [
              BroadcastMessageEntity(uid: _alice.uid!, timestamp: 100, data: 'c', pmid: 5),
            ],
          ),
        )
        .run();
    final bloc = NotificationBloc(
      notificationRepository: NotificationRepository(),
      infoRepository: NotificationInfoRepository(),
      authRepo: AuthenticationRepository(user: _alice),
      storageProvider: storage,
    );
    final done = bloc.stream.firstWhere((s) => s.status == NotificationStatus.success);
    bloc.add(NotificationReloadFromStorageRequested());
    final state = await done.timeout(const Duration(seconds: 5));
    // Newest first, read flags as stored.
    expect(state.noticeList.map((e) => (e.id, e.alreadyRead)), [(2, true), (1, false)]);
    expect(state.broadcastMessageList.map((e) => (e.pmid, e.alreadyRead)), [(5, false)]);
    expect(adapter.requests, isEmpty);
    await bloc.close();
  });
}
