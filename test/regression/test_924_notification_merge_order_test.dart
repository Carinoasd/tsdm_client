/// The notifications of the bloc newest first: the fetched ones and the stored ones are put together sorted by time.
///
/// They were put together as they came, the fetched ones before the stored ones, taken to be newer. A stored one can
/// be newer (a broadcast message carries the time it was written, not when it came, #154; the bound of a fetch reaches
/// back a margin). The notification page sorts what it shows, the search page showed the lists in the bloc's order.
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
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

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
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

  test('a stored notice newer than the fetched one comes first', () async {
    // Stored before, newer than the notice the forum answers now.
    final newer = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await storage
        .saveNotification(
          uid: _alice.uid!,
          notificationGroup: NotificationGroup(
            noticeList: [NoticeEntity(uid: _alice.uid!, nid: 5, timestamp: newer, data: 'stored', alreadyRead: true)],
            personalMessageList: const [],
            broadcastMessageList: const [],
          ),
        )
        .run();
    adapter = _Adapter([
      _noticePage([_notice(11, unread: true)]),
    ]);
    final bloc = NotificationBloc(
      notificationRepository: NotificationRepository(),
      infoRepository: NotificationInfoRepository(),
      authRepo: AuthenticationRepository(user: _alice),
      storageProvider: storage,
    );
    addTearDown(bloc.close);
    final done = bloc.stream.firstWhere((s) => s.status == NotificationStatus.success);
    bloc.add(const NotificationUpdateAllRequested());
    final state = await done.timeout(const Duration(seconds: 5));

    expect(state.noticeList.map((e) => e.id), [5, 11], reason: 'the fetched notice used to come first');
    final times = state.noticeList.map((e) => e.timestamp).toList();
    expect(times.first, greaterThan(times.last));
  });
}
