import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/background_sync/background_sync_bridge_cubit.dart';
import 'package:tsdm_client/features/background_sync/background_sync_controller.dart';
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

  /// When set, the notice page is answered only once this completes: the fetch is "in flight" meanwhile.
  Completer<void>? holdNotice;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final q = options.uri.queryParameters;
    if (q['do'] == 'notice' && holdNotice != null) {
      await holdNotice!.future;
    }
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

PersonalMessageV2 _pm(int peer, int t, String data, {bool read = false}) => PersonalMessageV2(
  timestamp: t,
  data: data,
  peerUid: peer,
  peerUsername: 'peer$peer',
  sender: false,
  alreadyRead: read,
);

NoticeV2 _notice7(int t) => NoticeV2(id: 7, timestamp: t, data: 'n7');

NotificationV2 _fetched({List<NoticeV2> notices = const [], List<PersonalMessageV2> pms = const []}) =>
    NotificationV2(status: 0, noticeList: notices, personalMessageList: pms, broadcastMessageList: const []);

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

  group('settings changed while the fetch is in flight (PR #83 review)', () {
    Future<Future<BackgroundSyncOutcome>> inFlight() async {
      await loggedIn();
      adapter
        ..pm = _pmPage(1001, 'for Alice')
        ..holdNotice = Completer<void>();
      final tick = backgroundSyncTick(storage: storage, repository: repository());
      while (adapter.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return tick;
    }

    test('the account switched: stored for the old account, announced for nobody', () async {
      final tick = await inFlight();
      // The app switches to Bob; Alice stays on the device.
      await settings.setValue(SettingsKeys.loginUid, 1002);
      adapter.holdNotice!.complete();
      expect(
        await tick,
        isA<BackgroundSyncStale>().having((e) => e.reason, 'reason', 'account switched during the fetch'),
      );
      final stored = await storage.fetchNotificationSince(uid: _alice.uid!, timestamp: 0).run();
      expect(stored.personalMessageList.map((e) => e.data), ['for Alice'], reason: 'kept, like sync all does');
    });

    test('auto sync set to never: not announced; switched off: the service ends', () async {
      var tick = await inFlight();
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 0);
      adapter.holdNotice!.complete();
      expect(await tick, isA<BackgroundSyncStale>());
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 60);
      adapter.requests.clear();
      tick = await inFlight();
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, false);
      adapter.holdNotice!.complete();
      expect(await tick, isA<BackgroundSyncDisabled>());
    });
  });

  group('network settings of the service isolate (PR #83 review)', () {
    test('the client is built from the settings as they are now, proxy included', () async {
      await loggedIn();
      // A local "proxy": with a proxy set, the client sends the whole URL to it instead of resolving the host.
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final seen = <String>[];
      proxy.listen((req) {
        seen.add(req.uri.toString());
        req.response
          ..statusCode = 200
          ..write('ok');
        unawaited(req.response.close());
      });
      // The app sets a proxy after the service started: the isolate's snapshot is from before.
      final app = StorageProvider(db, {}, {});
      await app.saveBool(SettingsKeys.netClientUseProxy.name, value: true);
      await app.saveString(SettingsKeys.netClientProxy.name, '127.0.0.1:${proxy.port}');
      expect(settings.currentSettings.netClientUseProxy, isFalse, reason: 'stale snapshot');
      var asked = 0;
      await refreshBackgroundNetworkSettings(settings: settings, updateProxy: () async => asked++);
      expect(settings.currentSettings.netClientUseProxy, isTrue);
      expect(asked, 0, reason: 'a proxy typed in by hand needs no platform call');
      final viaProxy = await settings.buildDefaultDio(nativeHttp: false).get<String>('http://tsdm-probe.invalid/ping');
      expect(viaProxy.data, 'ok');
      expect(seen, ['http://tsdm-probe.invalid/ping']);

      await app.saveBool(SettingsKeys.useDetectedProxyWhenStartup.name, value: true);
      await refreshBackgroundNetworkSettings(settings: settings, updateProxy: () async => asked++);
      expect(asked, 1, reason: 'following the system proxy: the platform is asked before the fetch');

      // Proxy switched off in the app: the next client goes direct (the server sees a plain path).
      await app.saveBool(SettingsKeys.netClientUseProxy.name, value: false);
      await refreshBackgroundNetworkSettings(settings: settings, updateProxy: () async => asked++);
      expect(asked, 1);
      seen.clear();
      final direct = await settings
          .buildDefaultDio(nativeHttp: false)
          .get<String>('http://127.0.0.1:${proxy.port}/direct');
      expect(direct.data, 'ok');
      expect(seen, ['/direct']);
    });

    test('a proxy that cannot be read skips the fetch instead of going direct', () async {
      await loggedIn();
      adapter.pm = _pmPage(1001, 'hi');
      final outcome = await backgroundSyncTick(
        storage: storage,
        repository: repository(),
        prepareNetwork: () async => throw StateError('no platform'),
      );
      expect(outcome, isA<BackgroundSyncSkipped>().having((e) => e.reason, 'reason', contains('no platform')));
      expect(adapter.requests, isEmpty);
    });
  });

  group('account removed while the fetch is in flight (PR #83 review)', () {
    test('rows are dropped and nothing is announced, even though the service cache still knows the account', () async {
      await loggedIn();
      final repo = repository();
      addTearDown(repo.dispose);
      adapter
        ..notice = _noticePage([_notice(11)])
        ..holdNotice = Completer<void>();
      final tick = backgroundSyncTick(storage: storage, repository: repo);
      // Wait until the fetch started, then remove the account the way the app does: through its own provider on
      // the same database, which the service's cookie cache never sees.
      while (adapter.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final app = StorageProvider(db, {}, {});
      expect(await app.deleteCookieByUid(_alice.uid!), isTrue);
      expect(storage.getCookieByUidSync(_alice.uid!), isNotNull, reason: 'the service cache is stale on purpose');
      adapter.holdNotice!.complete();

      final done = await tick as BackgroundSyncDone;
      expect(done.result, isA<NotificationSyncResultNotAuthorized>());
      expect(done.latest, isNull);
      final stored = await storage.fetchNotificationSince(uid: _alice.uid!, timestamp: 0).run();
      expect(stored.noticeList, isEmpty, reason: 'nothing of a removed account is kept');
    });
  });

  group('BackgroundSyncController', () {
    late List<String> calls;
    late bool running;
    late bool startResult;
    late bool stopResult;
    Exception? startError;
    Exception? stopError;
    Completer<void>? holdStop;
    Completer<void>? holdStart;

    BackgroundSyncController controller() => BackgroundSyncController(
      configure: ({required autoStartOnBoot}) async => calls.add('configure:$autoStartOnBoot'),
      start: () async {
        calls.add('start');
        await holdStart?.future;
        if (startError != null) {
          throw startError!;
        }
        running = startResult;
        return startResult;
      },
      stop: () async {
        calls.add('stop');
        // The real stop polls the plugin until the service is gone; meanwhile it still reports running.
        await holdStop?.future;
        if (stopError != null) {
          throw stopError!;
        }
        if (!stopResult) {
          // The wait ran out and the plugin still reports the service.
          return false;
        }
        running = false;
        return true;
      },
      isRunning: () async => running,
      notifySettingsChanged: () => calls.add('notify'),
    );

    setUp(() {
      calls = [];
      running = false;
      startResult = true;
      stopResult = true;
      startError = null;
      stopError = null;
      holdStop = null;
      holdStart = null;
    });

    test('an interval restored after never starts the stopped service again', () async {
      final c = controller();
      expect(await c.apply(enabled: true, intervalSeconds: 0), BackgroundSyncApplyResult.stopped);
      expect(calls, ['configure:false', 'stop']);
      calls.clear();
      expect(await c.apply(enabled: true, intervalSeconds: 60), BackgroundSyncApplyResult.running);
      expect(calls, ['configure:true', 'start', 'notify']);
    });

    test('a running service is only told to read the settings again', () async {
      running = true;
      expect(await controller().apply(enabled: true, intervalSeconds: 120), BackgroundSyncApplyResult.running);
      expect(calls, ['configure:true', 'notify']);
    });

    test('switching off stops the service and its boot start', () async {
      running = true;
      expect(await controller().apply(enabled: false, intervalSeconds: 60), BackgroundSyncApplyResult.stopped);
      expect(calls, ['configure:false', 'stop']);
    });

    test('a start that fails or throws reports failed instead of pretending', () async {
      startResult = false;
      expect(await controller().apply(enabled: true, intervalSeconds: 60), BackgroundSyncApplyResult.failed);
      startError = Exception('plugin unavailable');
      expect(await controller().apply(enabled: true, intervalSeconds: 60), BackgroundSyncApplyResult.failed);
    });

    test(
      'switched off and on again while the stop is in flight, the service ends up running (PR #83 review)',
      () async {
        running = true;
        holdStop = Completer<void>();
        final c = controller();
        final off = c.apply(enabled: false, intervalSeconds: 60);
        // Let the stop start, then ask for the service back while the plugin still reports it running.
        await Future<void>.delayed(Duration.zero);
        expect(calls, ['configure:false', 'stop']);
        final on = c.apply(enabled: true, intervalSeconds: 60);
        await Future<void>.delayed(Duration.zero);
        expect(calls, ['configure:false', 'stop'], reason: 'the on request waits for the stop to finish');
        holdStop!.complete();
        expect(await off, BackgroundSyncApplyResult.superseded);
        expect(await on, BackgroundSyncApplyResult.running);
        expect(running, isTrue, reason: 'the switch shows on, so the service must run');
        expect(calls, ['configure:false', 'stop', 'configure:true', 'start', 'notify']);
      },
    );

    test('of a burst of changes only the latest one runs and reports', () async {
      running = true;
      holdStop = Completer<void>();
      final c = controller();
      final first = c.apply(enabled: false, intervalSeconds: 60);
      await Future<void>.delayed(Duration.zero);
      final on = c.apply(enabled: true, intervalSeconds: 60);
      final last = c.apply(enabled: false, intervalSeconds: 60);
      holdStop!.complete();
      expect(await Future.wait([first, on, last]), [
        BackgroundSyncApplyResult.superseded,
        BackgroundSyncApplyResult.superseded,
        BackgroundSyncApplyResult.stopped,
      ]);
      expect(running, isFalse);
      expect(calls, ['configure:false', 'stop', 'configure:false', 'stop'], reason: 'the middle "on" never started');
    });

    test(
      'a stop whose wait ran out is not "stopped", and the next start waits for the real stop (PR #83 review)',
      () async {
        running = true;
        stopResult = false;
        final c = controller();
        expect(await c.apply(enabled: false, intervalSeconds: 60), BackgroundSyncApplyResult.stopping);
        expect(c.stopPending, isTrue);
        expect(running, isTrue, reason: 'the old instance is still on its way out');
        // The app asks for the service back while the plugin still reports the old instance.
        stopResult = true;
        holdStop = Completer<void>();
        final on = c.apply(enabled: true, intervalSeconds: 60);
        await Future<void>.delayed(Duration.zero);
        expect(calls, [
          'configure:false',
          'stop',
          'configure:true',
          'stop',
        ], reason: 'no start before the stop is confirmed');
        // The old instance is gone now.
        holdStop!.complete();
        expect(await on, BackgroundSyncApplyResult.running);
        expect(c.stopPending, isFalse);
        expect(running, isTrue);
        expect(calls, ['configure:false', 'stop', 'configure:true', 'stop', 'start', 'notify']);
      },
    );

    test('an old instance that never goes away refuses the start instead of reporting running', () async {
      running = true;
      stopResult = false;
      final c = controller();
      expect(await c.apply(enabled: false, intervalSeconds: 60), BackgroundSyncApplyResult.stopping);
      expect(await c.apply(enabled: true, intervalSeconds: 60), BackgroundSyncApplyResult.failed);
      expect(calls, isNot(contains('start')));
      expect(calls, isNot(contains('notify')), reason: 'the dying instance is not told anything');
      expect(c.stopPending, isTrue);
      // The old stop completes later: the switch was rolled back on `failed`, so off and stopped agree.
      running = false;
    });

    test('a stop call that throws leaves the stop pending', () async {
      running = true;
      stopError = Exception('plugin unavailable');
      final c = controller();
      expect(await c.apply(enabled: false, intervalSeconds: 60), BackgroundSyncApplyResult.stopping);
      expect(c.stopPending, isTrue);
      stopError = null;
      expect(await c.apply(enabled: true, intervalSeconds: 60), BackgroundSyncApplyResult.running);
      expect(calls, ['configure:false', 'stop', 'configure:true', 'stop', 'start', 'notify']);
      expect(running, isTrue);
    });

    test('a start that fails after a newer change was asked for does not report the failure', () async {
      startResult = false;
      holdStart = Completer<void>();
      final c = controller();
      final on = c.apply(enabled: true, intervalSeconds: 60);
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['configure:true', 'start'], reason: 'the start is in flight');
      final off = c.apply(enabled: false, intervalSeconds: 60);
      holdStart!.complete();
      expect(await on, BackgroundSyncApplyResult.superseded, reason: 'the off request answers, no rollback');
      expect(await off, BackgroundSyncApplyResult.stopped);
      expect(running, isFalse);
      expect(calls, ['configure:true', 'start', 'configure:false', 'stop']);
    });
  });

  group('one controller for the whole app (PR #83 review)', () {
    late List<String> calls;
    late bool running;
    late bool startResult;
    late bool stopResult;
    Completer<void>? holdStop;
    Completer<void>? holdStart;

    setUp(() {
      calls = [];
      running = true;
      startResult = true;
      stopResult = true;
      holdStop = null;
      holdStart = null;
      getIt.registerSingleton(
        BackgroundSyncController(
          configure: ({required autoStartOnBoot}) async => calls.add('configure:$autoStartOnBoot'),
          start: () async {
            calls.add('start');
            await holdStart?.future;
            running = startResult;
            return startResult;
          },
          stop: () async {
            calls.add('stop');
            await holdStop?.future;
            if (!stopResult) {
              return false;
            }
            running = false;
            return true;
          },
          isRunning: () async => running,
          notifySettingsChanged: () => calls.add('notify'),
        ),
      );
    });

    /// What a settings page does on the switch: write the setting, then apply through the app-wide controller.
    Future<BackgroundSyncApplyResult> page({required bool enable}) async {
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, enable);
      return getIt.get<BackgroundSyncController>().applySettings(settings);
    }

    test('settings opened from the toolbar, switched off, left, opened again and switched on', () async {
      await loggedIn();
      // First page: the stop gives up waiting, the service is still reported running.
      stopResult = false;
      expect(await page(enable: false), BackgroundSyncApplyResult.stopping);
      // The page is gone; a new page looks the controller up and asks for the service back.
      stopResult = true;
      holdStop = Completer<void>();
      final on = page(enable: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, ['configure:false', 'stop', 'configure:true', 'stop'], reason: 'confirms the stop first');
      holdStop!.complete();
      expect(await on, BackgroundSyncApplyResult.running);
      expect(running, isTrue);
      expect(settings.currentSettings.enableBackgroundMessageService, isTrue);
    });

    test('a late failure of an earlier page does not roll back what a later page set', () async {
      await loggedIn();
      running = false;
      startResult = false;
      holdStart = Completer<void>();
      final first = page(enable: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, ['configure:true', 'start'], reason: 'the start is in flight');
      // Another page switches off and on again meanwhile; the second start will succeed. (Each toggle writes the
      // setting first and applies what is stored then, so the two are sequenced here as taps are.)
      final controller = getIt.get<BackgroundSyncController>();
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, false);
      final off = controller.applySettings(settings);
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, true);
      final on = controller.applySettings(settings);
      startResult = true;
      holdStart!.complete();
      expect(await first, BackgroundSyncApplyResult.superseded, reason: "its failure is nobody's answer");
      expect(await off, BackgroundSyncApplyResult.superseded);
      expect(await on, BackgroundSyncApplyResult.running);
      expect(running, isTrue);
      expect(settings.currentSettings.enableBackgroundMessageService, isTrue, reason: 'not rolled back');
    });

    test('a failed start rolls the switch back, from the boot as well as from the page', () async {
      await loggedIn();
      running = false;
      startResult = false;
      expect(await getIt.get<BackgroundSyncController>().applySettings(settings), BackgroundSyncApplyResult.failed);
      expect(settings.currentSettings.enableBackgroundMessageService, isFalse);
      expect(await storage.getBool(SettingsKeys.enableBackgroundMessageService.name), isFalse);
    });
  });

  group('two syncs storing the same conversation (PR #83 review)', () {
    const uid = 1000;

    Future<PersistedNotification> persist(StorageProvider via, NotificationV2 fetched) =>
        persistFetchedNotification(storage: via, uid: uid, fetched: fetched, since: 0);

    Future<PersonalMessageEntity> conversation(StorageProvider via, int peer) async =>
        (await via.fetchNotificationSince(uid: uid, timestamp: 0).run()).personalMessageList.singleWhere(
          (e) => e.peerUid == peer,
        );

    test('the response sent first arrives last: its older copy is neither news nor stored', () async {
      final newer = await persist(storage, _fetched(pms: [_pm(2000, 200, 'new')]));
      expect(newer.fresh.personalMessageList.map((e) => e.data), ['new']);
      // The other isolate's sync, sent earlier, answered later.
      final other = StorageProvider(db, {}, {});
      final older = await persist(other, _fetched(pms: [_pm(2000, 100, 'old')], notices: [_notice7(100)]));
      expect(older.fresh.personalMessageList, isEmpty);
      final stored = await conversation(storage, 2000);
      expect((stored.timestamp, stored.data), (200, 'new'));
    });

    test('the same minute with another last message is news and replaces the stored one', () async {
      await persist(storage, _fetched(pms: [_pm(2000, 100, 'first')]));
      final again = await persist(storage, _fetched(pms: [_pm(2000, 100, 'second')]));
      expect(again.fresh.personalMessageList.map((e) => e.data), ['second']);
      expect((await conversation(storage, 2000)).data, 'second');
    });

    test('an older unread copy does not make a conversation read in the app unread again', () async {
      await persist(storage, _fetched(pms: [_pm(2000, 200, 'new')], notices: [_notice7(200)]));
      await storage.markPersonalMessageAsRead(uid: uid, peerUid: 2000, read: true).run();
      await storage.markNoticeAsRead(uid: uid, nid: 7, read: true).run();
      final older = await persist(
        StorageProvider(db, {}, {}),
        _fetched(pms: [_pm(2000, 100, 'old')], notices: [_notice7(100)]),
      );
      expect(older.fresh.personalMessageList, isEmpty);
      expect(older.fresh.noticeList, isEmpty);
      expect(older.unread, NotificationStateInfo.empty);
      final pm = await conversation(storage, 2000);
      expect((pm.timestamp, pm.data, pm.alreadyRead), (200, 'new', true));
      final notice = (await storage.fetchNotificationSince(uid: uid, timestamp: 0).run()).noticeList.single;
      expect((notice.timestamp, notice.alreadyRead), (200, true));
    });

    test('the row itself refuses an older copy, whatever writes it', () async {
      await persist(storage, _fetched(pms: [_pm(2000, 200, 'new')]));
      await storage
          .saveNotification(
            uid: uid,
            notificationGroup: const NotificationGroup(
              noticeList: [],
              broadcastMessageList: [],
              personalMessageList: [
                PersonalMessageEntity(
                  uid: uid,
                  timestamp: 100,
                  data: 'old',
                  peerUid: 2000,
                  peerUsername: 'peer2000',
                  sender: false,
                  alreadyRead: false,
                ),
              ],
            ),
          )
          .run();
      expect((await conversation(storage, 2000)).data, 'new');
    });

    test('two connections: the second sync waits for the first and reads what it stored', () async {
      // The service opens the same file from its own isolate: two sqlite connections, not one shared executor.
      final dir = await Directory.systemTemp.createTemp('tsdm_sync');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/main.db');
      AppDatabase open() => AppDatabase(NativeDatabase(file, setup: (db) => db.execute('PRAGMA busy_timeout = 5000')));
      final app = open();
      final appStorage = StorageProvider(app, {}, {});
      await appStorage.saveInt('warm-up', 1);
      final service = open();
      final serviceStorage = StorageProvider(service, {}, {});
      addTearDown(app.close);
      addTearDown(service.close);

      final hold = Completer<void>();
      final appSync = appStorage.exclusively(() async {
        await persist(appStorage, _fetched(pms: [_pm(2000, 200, 'new')]));
        await hold.future;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      var serviceDone = false;
      final serviceSync = persist(serviceStorage, _fetched(pms: [_pm(2000, 100, 'old')])).whenComplete(() {
        serviceDone = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(serviceDone, isFalse, reason: 'blocked until the app sync committed');
      hold.complete();
      await appSync;
      final result = await serviceSync;
      expect(result.fresh.personalMessageList, isEmpty, reason: 'read after the commit: the stored copy is newer');
      expect((await conversation(serviceStorage, 2000)).data, 'new');
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
