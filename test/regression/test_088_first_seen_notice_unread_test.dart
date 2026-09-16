import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// GitHub #79: two devices on one account. Discuz! X5 drops the unread marker of a notice as soon as the notice page
/// is listed once, and every device's sync is such a listing, so the second device used to see every notice the first
/// one had fetched as read. A notice this device sees for the first time inside the window it fetched is unread here,
/// whatever the server rendered; the first fetch on a device (no stored bound) still trusts the server so the history
/// of a fresh install does not turn unread.
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

String _notice(int nid, {required bool unread}) =>
    '<dl class="cl" notice="$nid" id="notice_$nid">\n'
    '<dd class="m avt mbn"><a href="home.php?mod=space&amp;uid=1001"><img src="a.jpg"></a></dd>\n'
    '<dt><a class="d b" href="#">屏蔽</a> <span class="xg1 xw0"><span title="$_timeText">1 分钟前</span></span></dt>\n'
    '<dd class="ntc_body" style="${unread ? 'color:#000;font-weight:bold;' : ''}">\n'
    '<a href="home.php?mod=space&uid=1001">Peer</a> 回复了您的帖子 <a href="forum.php?mod=redirect&pid=$nid">T</a></dd>\n'
    '</dl>\n';

String _noticePage(List<String> notices) =>
    '<html><body><div id="um"></div><div id="ct"><div class="mn"><div class="bm bw0"><div class="xld xlda">\n'
    '<div class="nts">${notices.join()}</div></div></div></div></div></body></html>';

const _emptyPage = '<html><body><div id="um"></div><div class="nts"></div></body></html>';

/// Answers the notice page from a queue (one entry per sync) and the message pages with nothing.
final class _Adapter implements HttpClientAdapter {
  _Adapter(this.noticePages);

  final List<String> noticePages;
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
      {'do': 'notice'} => noticePages.isEmpty ? fail('unexpected notice request') : noticePages.removeAt(0),
      {'filter': 'privatepm'} || {'filter': 'announcepm'} => _emptyPage,
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

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late _Adapter adapter;
  late NotificationInfoRepository infoRepository;
  final published = <NotificationStateInfo>[];

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    infoRepository = NotificationInfoRepository();
    published.clear();
    infoRepository.status.listen(published.add);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      )
      ..registerSingleton<CookieProvider>(CookieProvider(_alice, _jar('alice')));
    await settings.init();
    await storage.saveCookie(username: _alice.username!, uid: _alice.uid!, cookie: _jar('alice'));
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<Map<int, bool?>> storedFlags() async {
    final group = await storage.fetchNotificationSince(uid: _alice.uid!, timestamp: 0).run();
    return {for (final n in group.noticeList) n.nid: n.alreadyRead};
  }

  test(
    'reconcile: first-seen inside the fetched window is unread, the first fetch and stored copies are not touched',
    () {
      NoticeV2 fetched(int id, int t, {required bool read}) =>
          NoticeV2(id: id, timestamp: t, data: 'd', alreadyRead: read);
      NoticeEntity stored(int id, int t, {bool? read}) =>
          NoticeEntity(uid: 1, nid: id, timestamp: t, data: 'd', alreadyRead: read);

      // Another device listed the page first: the server renders the notice read, this device has never shown it.
      final bounded = reconcileNoticeReadState(fetched: [fetched(1, 500, read: true)], stored: [], since: 400);
      expect(bounded.single.alreadyRead, isFalse);
      // No bound stored yet: the history of a fresh install keeps the server's flags.
      final first = reconcileNoticeReadState(
        fetched: [fetched(1, 500, read: true), fetched(2, 500, read: false)],
        stored: [],
      );
      expect(first.map((e) => e.alreadyRead), [true, false]);
      // A copy already stored keeps the local flag, bound or not.
      final kept = reconcileNoticeReadState(
        fetched: [fetched(1, 500, read: false), fetched(2, 500, read: true)],
        stored: [stored(1, 500, read: true), stored(2, 500, read: false)],
        since: 400,
      );
      expect(kept.map((e) => e.alreadyRead), [true, false]);
    },
  );

  test('a notice another device fetched first is still unread on this device after its own sync', () async {
    adapter = _Adapter([
      // First sync of this device, no bound: 11 is new to everyone (bold), 12 was already listed elsewhere.
      _noticePage([_notice(11, unread: true), _notice(12, unread: false)]),
      // Later sync: 13 arrived and the phone listed it a minute ago, so the server renders it read; 11 and 12 come
      // back read as every listed notice does.
      _noticePage([_notice(13, unread: false), _notice(11, unread: false), _notice(12, unread: false)]),
    ]);
    final bloc = NotificationBloc(
      notificationRepository: NotificationRepository(),
      infoRepository: infoRepository,
      authRepo: AuthenticationRepository(user: _alice),
      storageProvider: storage,
    );
    addTearDown(bloc.close);
    Future<void> sync() async {
      final done = bloc.stream.firstWhere((s) => s.status == NotificationStatus.success);
      bloc.add(NotificationUpdateAllRequested());
      await done.timeout(const Duration(seconds: 5));
      await pumpEventQueue();
    }

    await sync();
    expect(await storedFlags(), {11: false, 12: true}, reason: 'first fetch on this device trusts the server');
    expect(published.last.notice, 1);

    // The device now has a bound: everything fetched from here on is inside its own window.
    await storage.updateLastFetchNoticeTime(_alice.uid!, DateTime.now().subtract(const Duration(hours: 6))).run();
    await sync();
    expect(adapter.requests.where((u) => u.queryParameters['do'] == 'notice'), hasLength(2));
    final flags = await storedFlags();
    expect(flags[13], isFalse, reason: 'new to this device: unread although the server rendered it read (#79)');
    expect(flags[11], isFalse, reason: 'stored unread copy keeps its flag');
    expect(flags[12], isTrue, reason: 'stored read copy keeps its flag');
    expect(published.last.notice, 2, reason: 'the badge counts both unread copies');
  });
}
