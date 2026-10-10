/// The forum's app API, the `tsdmapp` Discuz plugin (stage 1: status, notify, checkin).
///
/// The app keeps every web page path and asks the API first when the forum has it:
///
/// * Polling notifications: when nothing arrived since the last fetch, the three web pages are not fetched (most of
///   the polls). When something did, the pages are fetched as before: they stay the source of what is shown, and
///   fetching the notice page is what marks the notices read on the forum.
/// * Checkin: the API tells "checked in today" and "not open now" plainly; only a real checkin posts the web form.
///
/// A forum without the plugin answers a page that is not JSON; the API is then not asked again for an hour. A forum
/// that switched it off answers `error: off`, treated the same.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/utils/do_checkin.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';

/// The forum clock: now, since the repository clamps `since` to three days ago (a fixed time broke on 2026-10-10).
final int _now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// A `notify` answer as the plugin gives it (1.1.0 on the test forum, names replaced).
Map<String, Object?> _notify({
  List<Map<String, Object?>> notices = const [],
  List<Map<String, Object?>> pms = const [],
  List<Map<String, Object?>> announces = const [],
}) => {
  'ok': 1,
  'api': 1,
  'time': _now,
  'uid': 35,
  'counts': {'notice': notices.length, 'pm': pms.length, 'announce': announces.length},
  'notices': notices,
  'pms': pms,
  'announces': announces,
};

Map<String, Object?> _notice(int dateline, {int isNew = 1}) => {
  'id': 2543,
  'new': isNew,
  'type': 'post',
  'category': 1,
  'authorid': 32,
  'author': 'user2',
  'note': '<a href="home.php?mod=space&uid=32">user2</a> 回复了您的帖子',
  'text': 'user2 回复了您的帖子',
  'dateline': dateline,
  'from_id': 9199032,
  'from_idtype': 'post',
  'from_num': 1,
};

Map<String, Object?> _checkin({required int checked, required int open}) => {
  'ok': 1,
  'api': 1,
  'time': _now,
  'installed': 1,
  'checked_today': checked,
  'can_checkin': checked == 0 && open == 1 ? 1 : 0,
  'window': {'enabled': 1, 'start_hour': 1, 'end_hour': 23, 'open_now': open},
  'day_start': _now - 3600,
  'last_time': checked == 1 ? _now - 60 : 0,
  'days': 3,
  'month_days': 1,
};

/// Answers the API with [api] and every other request with [pages] in order; records the requests.
final class _Forum implements HttpClientAdapter {
  _Forum({this.api, this.pages = const [], this.apiStatus = 200});

  final Object? api;
  final List<String> pages;
  final int apiStatus;
  final requests = <RequestOptions>[];
  var _page = 0;

  List<RequestOptions> get apiRequests => requests.where((e) => e.uri.queryParameters['id'] == 'tsdmapp:api').toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.queryParameters['id'] == 'tsdmapp:api') {
      final type = api is String ? 'text/html; charset=utf-8' : 'application/json; charset=utf-8';
      final body = switch (api) {
        final String s => s,
        null => throw DioException.connectionError(requestOptions: options, reason: 'offline'),
        final Object o => jsonEncode(o),
      };
      return ResponseBody.fromString(
        body,
        apiStatus,
        headers: {
          Headers.contentTypeHeader: [type],
        },
      );
    }
    if (_page >= pages.length) {
      fail('unexpected page request: ${options.method} ${options.uri}');
    }
    return ResponseBody.fromString(
      pages[_page++],
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

NetClientProvider _client(_Forum forum) =>
    NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

const _pluginMissing = '<html><body><div id="messagetext"><p>插件不存在或已关闭</p></div></body></html>';
const _noticePage = '<html><body><div id="um"><a href="home.php?mod=space&amp;uid=35">user1</a></div></body></html>';
const _emptyPage = '<html><body></body></html>';

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(getIt.reset);
  setUp(TsdmAppApi.reset);

  group('notify gate', () {
    final since = _now - 60;

    test('nothing since the last fetch: no page, the forum clock', () {
      final gate = notifyGateOf(_notify(notices: [_notice(since - 600)]), since: since);
      expect(gate, isA<TsdmAppNothingNew>());
      expect((gate as TsdmAppNothingNew).serverTime, DateTime.fromMillisecondsSinceEpoch(_now * 1000, isUtc: true));
    });

    test('a notice or a message since then: fetch the pages', () {
      expect(notifyGateOf(_notify(notices: [_notice(since)]), since: since), isA<TsdmAppFetchPages>());
      expect(
        notifyGateOf(
          _notify(
            pms: [
              {'plid': 1, 'lastdateline': since + 5},
            ],
          ),
          since: since,
        ),
        isA<TsdmAppFetchPages>(),
      );
    });

    test('an unread broadcast message whatever its time (written earlier, delivered later, #154)', () {
      final gate = notifyGateOf(
        _notify(
          announces: [
            {'id': 4, 'new': 1, 'dateline': since - 7200, 'text': 'x'},
          ],
        ),
        since: since,
      );
      expect(gate, isA<TsdmAppFetchPages>());
    });

    test('not logged in, no answer or an unknown shape', () {
      expect(notifyGateOf({'ok': 0, 'error': 'login'}, since: since), isA<TsdmAppNotLoggedIn>());
      expect(notifyGateOf(null, since: since), isA<TsdmAppFetchPages>());
      expect(notifyGateOf({'ok': 1, 'time': _now}, since: since), isA<TsdmAppFetchPages>());
      expect(notifyGateOf({'ok': 0, 'error': 'busy'}, since: since), isA<TsdmAppFetchPages>());
    });
  });

  group('asking the API', () {
    test('a forum without the plugin is not asked again for an hour', () async {
      final forum = _Forum(api: _pluginMissing);
      expect(await TsdmAppApi.ask(_client(forum), 'status'), isNull);
      expect(TsdmAppApi.knownUnavailable, isTrue);
      expect(await TsdmAppApi.ask(_client(forum), 'status'), isNull);
      expect(forum.apiRequests, hasLength(1));
    });

    test('a forum that switched it off is treated the same', () async {
      final forum = _Forum(api: {'ok': 0, 'error': 'off'});
      expect(await TsdmAppApi.ask(_client(forum), 'notify'), isNull);
      expect(TsdmAppApi.knownUnavailable, isTrue);
    });

    test('too fast (429) or offline: no answer this time, asked again next time', () async {
      final busy = _Forum(api: {'ok': 0, 'error': 'busy', 'retry_after': 3}, apiStatus: 429);
      expect(await TsdmAppApi.ask(_client(busy), 'notify'), isNull);
      expect(TsdmAppApi.knownUnavailable, isFalse);
      expect(await TsdmAppApi.ask(_client(_Forum()), 'notify'), isNull);
      expect(TsdmAppApi.knownUnavailable, isFalse);
    });

    test('an action an older plugin does not have is not "missing"', () async {
      expect(await TsdmAppApi.ask(_client(_Forum(api: {'ok': 0, 'error': 'action'})), 'notify'), isNull);
      expect(TsdmAppApi.knownUnavailable, isFalse);
    });

    test('the url of an action', () {
      expect(TsdmAppApi.url('notify', {'since': '5'}), '$baseUrl/plugin.php?id=tsdmapp%3Aapi&action=notify&since=5');
    });
  });

  group('polling notifications', () {
    test('nothing new: one small request instead of three pages', () async {
      final forum = _Forum(api: _notify());
      final result = await NotificationRepository().fetchNotificationWith(_client(forum), timestamp: _now - 60).run();
      final value = result.getOrElse((e) => fail('$e'));
      expect(value.info.noticeList, isEmpty);
      expect(value.serverTime, DateTime.fromMillisecondsSinceEpoch(_now * 1000, isUtc: true));
      expect(forum.requests, hasLength(1));
      expect(forum.apiRequests.single.uri.queryParameters['since'], '${_now - 60}');
    });

    test('something new: the pages are fetched as before', () async {
      final forum = _Forum(
        api: _notify(notices: [_notice(_now - 10)]),
        pages: [_noticePage, _emptyPage, _emptyPage],
      );
      final result = await NotificationRepository().fetchNotificationWith(_client(forum), timestamp: _now - 60).run();
      expect(result.isRight(), isTrue);
      expect(forum.requests, hasLength(4));
    });

    test('an expired session told by the API', () async {
      final forum = _Forum(api: {'ok': 0, 'error': 'login'});
      final result = await NotificationRepository().fetchNotificationWith(_client(forum), timestamp: _now - 60).run();
      expect(result.isLeft(), isTrue);
      expect(forum.requests, hasLength(1));
    });

    test('the first fetch (no timestamp) reads the pages without asking', () async {
      final forum = _Forum(api: _notify(), pages: [_noticePage, _emptyPage, _emptyPage]);
      await NotificationRepository().fetchNotificationWith(_client(forum)).run();
      expect(forum.apiRequests, isEmpty);
    });
  });

  group('checkin', () {
    Future<(CheckinResult, _Forum)> checkin(_Forum forum) async =>
        (await doCheckin(_client(forum), CheckinFeeling.happy, 'hi').run(), forum);

    test('checked in today: nothing else is requested', () async {
      final (result, forum) = await checkin(_Forum(api: _checkin(checked: 1, open: 1)));
      expect(result, isA<CheckinResultAlreadyChecked>());
      expect(forum.requests, hasLength(1));
    });

    test('not open now (before 1:00): not recorded as done, nothing posted', () async {
      final (result, forum) = await checkin(_Forum(api: _checkin(checked: 0, open: 0)));
      expect(result, isA<CheckinResultEarlyInTime>());
      expect(forum.requests, hasLength(1));
    });

    test('open and not checked in: the web form checks in', () async {
      const page =
          '<html><body><div id="um">user1</div><form id="qiandao" method="post"> '
          '<input type="hidden" name="formhash" value="XXXXXXXX" /></form></body></html>';
      const success =
          '<?xml version="1.0" encoding="utf-8"?>\n<root><![CDATA[<div class="c">恭喜你签到成功!获得随机奖励 天使币 10 .</div>]]></root>';
      final (result, forum) = await checkin(_Forum(api: _checkin(checked: 0, open: 1), pages: [page, success]));
      expect(result, isA<CheckinResultSuccess>());
      expect(forum.requests.last.method, 'POST');
    });

    test('an expired session told by the API', () async {
      final (result, _) = await checkin(_Forum(api: {'ok': 0, 'error': 'login'}));
      expect(result, isA<CheckinResultNotAuthorized>());
    });

    test('a forum without the checkin plugin: the web page decides', () async {
      const already = '<html><body><div id="um">user1</div><h1 class="mt">您今天已经签到过了</h1></body></html>';
      final (result, forum) = await checkin(
        _Forum(
          api: {'ok': 1, 'api': 1, 'time': _now, 'installed': 0},
          pages: [already],
        ),
      );
      expect(result, isA<CheckinResultAlreadyChecked>());
      expect(forum.requests, hasLength(2));
    });
  });
}
