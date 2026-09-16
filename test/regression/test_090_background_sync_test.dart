import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/background_sync/background_sync_bridge_cubit.dart';
import 'package:tsdm_client/features/background_sync/background_sync_tick.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/notification/utils/auto_sync_info.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// GitHub #80: the Android background message service is one more caller of the sync everything else uses. A tick
/// reads the settings from the database, syncs the current account through `NotificationSyncAllRepository`, stores
/// the rows and announces only what is new; the in-app sync running afterwards finds nothing new. What is announced
/// comes from `autoSyncInfoOf`, shared with `NotificationBloc`, so a second notice in the same minute is still news.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

Map<String, String> _jar(String token) => {
  '.index': '["$baseHost"]',
  baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=$token; Path=/;_crt=1"}}',
};

/// Notification times have minute precision: `yyyy-M-d HH:mm`, one hour ago so it is inside the 3-day window.
final DateTime _time = DateTime.now().subtract(const Duration(hours: 1));
final _timeText =
    '${_time.year}-${_time.month}-${_time.day} '
    '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

String _timeTextOf(DateTime time) =>
    '${time.year}-${time.month}-${time.day} '
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// A notice stamped [at] (default one hour ago); a later fetch only returns what is inside its window.
String _notice(int nid, {DateTime? at}) =>
    '<dl class="cl" notice="$nid" id="notice_$nid">\n'
    '<dd class="m avt mbn"><a href="home.php?mod=space&amp;uid=1001"><img src="a.jpg"></a></dd>\n'
    '<dt><a class="d b" href="#">屏蔽</a> <span class="xg1 xw0"><span title="${at == null ? _timeText : _timeTextOf(at)}">1 分钟前</span></span></dt>\n'
    '<dd class="ntc_body" style="color:#000;font-weight:bold;">\n'
    '<a href="home.php?mod=space&uid=1001">Peer</a> 回复了您的帖子 <a href="forum.php?mod=redirect&pid=$nid">T</a></dd>\n'
    '</dl>\n';

String _noticePage(List<String> notices) =>
    '<html><body><div id="um"></div><div id="ct"><div class="mn"><div class="bm bw0"><div class="xld xlda">\n'
    '<div class="nts">${notices.join()}</div></div></div></div></div></body></html>';

String _pmPage(int peerUid, String text) =>
    '<html><body><div id="um"></div><form id="deletepmform"><div>\n'
    '<dl id="pmlist_$peerUid" class="cl newpm">\n'
    '<dd class="m avt"><a href="home.php?mod=space&amp;uid=$peerUid"><img src="a.jpg"></a><div class="newpm_avt"></div></dd> '
    '<dd class="ptm pm_c"><div class="o"></div><a href="home.php?mod=space&uid=$peerUid" class="xw1">Peer</a> 对 '
    '<span class="xi2">您</span> 说 :<br />$text &nbsp; <br /><span class="xg1"><span title="$_timeText">1 小时前</span></span></dd>\n'
    '</dl></div></form></body></html>';

const _emptyPage = '<html><body><div id="um"></div><div class="nts"></div></body></html>';
const _guestPage =
    '<html><body><form id="lsform" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /> '
    '<input name="username" /></form></body></html>';

/// Answers the three notification pages from what the test set last, and counts requests.
final class _Adapter implements HttpClientAdapter {
  String notice = _emptyPage;
  String pm = _emptyPage;
  String bm = _emptyPage;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final q = options.uri.queryParameters;
    final body = switch (q) {
      {'do': 'notice'} => notice,
      {'filter': 'privatepm'} => pm,
      {'filter': 'announcepm'} => bm,
      _ => fail('unexpected request: ${options.uri}'),
    };
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Records what the bridge asks the notification bloc to do.
final class _RecordingNotificationBloc extends NotificationBloc {
  _RecordingNotificationBloc({required super.storageProvider})
    : super(
        notificationRepository: NotificationRepository(),
        infoRepository: NotificationInfoRepository(),
        authRepo: AuthenticationRepository(user: _alice),
      );
  final events = <NotificationEvent>[];

  @override
  void add(NotificationEvent event) => events.add(event);
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late _Adapter adapter;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    adapter = _Adapter();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  NotificationSyncAllRepository repository() => NotificationSyncAllRepository(
    storageProvider: storage,
    notificationRepository: NotificationRepository(storageProvider: storage),
    clientFactory: (cookie) => NetClientProvider.buildNoCookie(
      dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
      cookie: cookie,
    ),
    gap: Duration.zero,
  );

  /// Alice is logged in with the service switched on and auto sync every minute.
  Future<void> loggedIn() async {
    await storage.saveCookie(username: _alice.username!, uid: _alice.uid!, cookie: _jar('alice'));
    await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
    await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 60);
    await settings.setValue(SettingsKeys.enableBackgroundMessageService, true);
  }

  group('backgroundSyncTick', () {
    test('the switch is off by default and a tick then asks the service to stop', () async {
      expect(SettingsKeys.enableBackgroundMessageService.defaultValue, isFalse);
      final read = await readBackgroundSyncSettings(storage);
      expect(read.enabled, isFalse);
      expect(await backgroundSyncTick(storage: storage, repository: repository()), isA<BackgroundSyncDisabled>());
      expect(adapter.requests, isEmpty);
    });

    test('auto sync set to never, or nobody logged in, fetches nothing', () async {
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, true);
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 0);
      expect(
        await backgroundSyncTick(storage: storage, repository: repository()),
        isA<BackgroundSyncSkipped>().having((e) => e.reason, 'reason', 'auto sync is off'),
      );
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 60);
      expect(
        await backgroundSyncTick(storage: storage, repository: repository()),
        isA<BackgroundSyncSkipped>().having((e) => e.reason, 'reason', 'not logged in'),
      );
      expect(adapter.requests, isEmpty);
    });

    test('a new notice is stored and announced once; a second one in the same minute is news too', () async {
      await loggedIn();
      final repo = repository();
      addTearDown(repo.dispose);
      adapter.notice = _noticePage([_notice(11)]);

      final first = await backgroundSyncTick(storage: storage, repository: repo);
      expect(first, isA<BackgroundSyncDone>());
      final done = first as BackgroundSyncDone;
      expect(done.uid, _alice.uid);
      expect(done.result, isA<NotificationSyncResultSuccess>().having((e) => e.newNotice, 'newNotice', 1));
      expect(done.latest, isA<NotificationAutoSyncInfoNotice>().having((e) => e.notice, 'notice', 1));
      final stored = await storage.fetchNotificationSince(uid: _alice.uid!, timestamp: 0).run();
      expect(stored.noticeList.map((e) => e.nid), [11]);
      expect(
        (await storage.fetchLastFetchNoticeTime(_alice.uid!).run()).getOrElse((_) => null),
        isNotNull,
        reason: 'the bound moves like the in-app sync does',
      );

      // The same page again: the row is known, nothing to announce.
      final again = await backgroundSyncTick(storage: storage, repository: repo) as BackgroundSyncDone;
      expect(again.latest, isNull);

      // One more notice, stamped inside the window of the next fetch: still news (a dedup on the newest timestamp
      // alone missed a second notice in the same minute, PR #80 review).
      adapter.notice = _noticePage([_notice(12, at: DateTime.now().add(const Duration(minutes: 1))), _notice(11)]);
      final more = await backgroundSyncTick(storage: storage, repository: repo) as BackgroundSyncDone;
      expect(more.latest, isA<NotificationAutoSyncInfoNotice>().having((e) => e.notice, 'notice', 1));
      expect(adapter.requests.where((u) => u.queryParameters['do'] == 'notice'), hasLength(3));
    });

    test('a private message wins the announcement and the in-app sync after it finds nothing new', () async {
      await loggedIn();
      final repo = repository();
      addTearDown(repo.dispose);
      adapter
        ..notice = _noticePage([_notice(11)])
        ..pm = _pmPage(3001, 'hello there');
      final done = await backgroundSyncTick(storage: storage, repository: repo) as BackgroundSyncDone;
      expect(
        done.latest,
        isA<NotificationAutoSyncInfoPm>()
            .having((e) => e.user, 'user', 'Peer')
            .having((e) => e.msg, 'msg', contains('hello there'))
            .having((e) => (e.notice, e.personalMessage), 'counts', (1, 1)),
      );
      // The in-app path on the same storage: same rows, nothing fresh, no second push.
      final stored = await storage.fetchNotificationSince(uid: _alice.uid!, timestamp: 0).run();
      final refetched = await NotificationRepository()
          .fetchNotificationWith(
            NetClientProvider.buildNoCookie(
              dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
              cookie: CookieProvider.buildEmpty(),
            ),
          )
          .run();
      final fresh = freshNotifications(
        fetched: refetched.getOrElse((_) => throw StateError('unreachable')).info,
        stored: stored,
      );
      expect(fresh.noticeList, isEmpty);
      expect(fresh.personalMessageList, isEmpty);
      expect(autoSyncInfoOf(fresh), isNull);
    });

    test('an expired session announces nothing', () async {
      await loggedIn();
      final repo = repository();
      addTearDown(repo.dispose);
      adapter
        ..notice = _guestPage
        ..pm = _guestPage
        ..bm = _guestPage;
      final done = await backgroundSyncTick(storage: storage, repository: repo) as BackgroundSyncDone;
      expect(done.result, isA<NotificationSyncResultNotAuthorized>());
      expect(done.latest, isNull);
    });

    test('an account that logged in after the service started is picked up', () async {
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, true);
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 60);
      // The storage was created before Alice logged in: its cookie cache does not know her yet.
      await storage.saveCookie(username: _alice.username!, uid: _alice.uid!, cookie: _jar('alice'));
      final late = StorageProvider(db, {}, {});
      expect(late.getCookieByUidSync(_alice.uid!), isNull);
      await late.refreshCookieCache();
      expect(late.getCookieByUidSync(_alice.uid!), isNotNull);
    });
  });

  group('what is announced', () {
    test('the body from translations is the body the widget tree would build', () async {
      final tr = await AppLocale.zhTw.build();
      const info = NotificationAutoSyncInfoPm(
        user: 'Peer',
        msg: 'hello',
        notice: 1,
        personalMessage: 2,
        broadcastMessage: 0,
        timestamp: 0,
      );
      final body = localNotificationBodyOf(tr, info);
      expect(body, contains('Peer'));
      expect(body, contains('hello'));
      expect(
        body,
        tr.localNotification.notice.detail.pm(noticeCount: 1, pmCount: 2, bmCount: 0, user: 'Peer', msg: 'hello'),
      );
    });

    test('autoSyncInfoOf prefers a private message, then a broadcast, then a notice, and truncates', () {
      final long = 'x' * 60;
      final notice = NoticeV2(id: 1, timestamp: 1, data: '<p>$long</p>');
      final pm = PersonalMessageV2(
        timestamp: 1,
        data: long,
        peerUid: 2,
        peerUsername: 'Bob',
        sender: false,
        alreadyRead: false,
      );
      final bm = BroadcastMessageV2(timestamp: 1, data: long, pmid: 3);
      const empty = NotificationV2(status: 0, noticeList: [], personalMessageList: [], broadcastMessageList: []);
      expect(autoSyncInfoOf(empty), isNull);
      expect(
        autoSyncInfoOf(empty.copyWith(noticeList: [notice], personalMessageList: [pm], broadcastMessageList: [bm])),
        isA<NotificationAutoSyncInfoPm>().having((e) => e.msg, 'truncated', 'x' * 40 + '...'),
      );
      expect(
        autoSyncInfoOf(empty.copyWith(noticeList: [notice], broadcastMessageList: [bm])),
        isA<NotificationAutoSyncInfoBm>(),
      );
      expect(
        autoSyncInfoOf(empty.copyWith(noticeList: [notice])),
        isA<NotificationAutoSyncInfoNotice>().having((e) => e.msg, 'text without tags', 'x' * 40 + '...'),
      );
    });
  });

  group('BackgroundSyncBridgeCubit', () {
    test('a synced event for the current account updates the badge and reloads the page', () async {
      final events = StreamController<Map<String, dynamic>?>.broadcast();
      addTearDown(events.close);
      final infoRepository = NotificationInfoRepository();
      final published = <NotificationStateInfo>[];
      infoRepository.status.listen(published.add);
      final bloc = _RecordingNotificationBloc(storageProvider: storage);
      addTearDown(bloc.close);
      final cubit = BackgroundSyncBridgeCubit(
        events: events.stream,
        notificationBloc: bloc,
        infoRepository: infoRepository,
        currentUid: () => _alice.uid,
      )..start();
      addTearDown(cubit.close);

      events.add({'uid': 2000, 'notice': 9, 'personalMessage': 9, 'broadcastMessage': 9});
      await pumpEventQueue();
      expect(bloc.events, isEmpty, reason: 'another account: nothing to show');
      expect(published, isEmpty);
      expect(cubit.state, 0);

      events.add({'uid': _alice.uid, 'notice': 2, 'personalMessage': 1, 'broadcastMessage': 0});
      await pumpEventQueue();
      expect(bloc.events, [isA<NotificationReloadFromStorageRequested>()]);
      expect(published, [const NotificationStateInfo(notice: 2, personalMessage: 1, broadcastMessage: 0)]);
      expect(cubit.state, 1);
    });
  });
}
