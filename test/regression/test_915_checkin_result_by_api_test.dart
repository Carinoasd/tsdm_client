/// The outcome of a checkin is the forum's app API read again after the post, not the words of the answer.
///
/// The check-in plugin (dsu_paulsign) answers the post with its own float window: the plugin's write result is a
/// `page` without a language key (`write_by_key/checkin_post*.json`, the test forum's real answers), so the app read
/// "签到成功", "已经签到", "签到时间还未开始" in it, and a change of the plugin's words or template made a checkin
/// that happened look failed (and tried again by the auto checkin), or the reverse. Now `checkin` of the forum's app
/// API is asked again right after the post (waiting for its "too soon" answer: the plugin takes one call per action
/// and account every few seconds, and `checkin` was asked just before) and its `checked_today` decides; the words only
/// tell why it did not check in. Without the API (no plugin, an older one, no checkin plugin, a failed read) the words
/// decide as before.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/utils/do_checkin.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';

const _dir = 'test/data/tsdmapp/write_by_key';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// The `checkin` answer before the post: open, not checked in today, with the form hash.
Map<String, dynamic> get _before => {
  ..._fixture('checkin_after'),
  'checked_today': 0,
  'can_checkin': 1,
  'last_time': 1699900000,
};

/// The `checkin` answer after the post, as the test forum gave it: checked in today.
Map<String, dynamic> get _checked => _fixture('checkin_after');

/// The `checkin` answer after the post: not checked in today, the window [open] or closed.
Map<String, dynamic> _notChecked({bool open = true}) => {
  ..._before,
  'can_checkin': open ? 1 : 0,
  'window': {...(_before['window'] as Map<String, dynamic>), 'open_now': open ? 1 : 0},
};

/// The plugin's write result of the post with the float window's text replaced by [text].
Map<String, dynamic> _postWith(String text) {
  final post = _fixture('checkin_post');
  final document = (post['document'] as String).replaceFirstMapped(
    RegExp('(<div class="c" id="dsu_ps_msg">)[^<]*'),
    (m) => '${m[1]}\n$text ',
  );
  return {...post, 'document': document};
}

typedef _Answer = ({Object body, int status});

/// A forum answering `checkin` with [before] until the form was posted, then with the answers of [after] in turn
/// (the last one repeated), and the post with [post].
final class _Forum implements HttpClientAdapter {
  _Forum({required this.before, required this.after, required this.post});

  final _Answer before;
  final List<_Answer> after;
  final Object post;
  final requests = <RequestOptions>[];
  var _afterIndex = 0;

  bool get _posted => requests.any((e) => e.method == 'POST');

  /// The API actions asked, in order, with `POST` for the post.
  List<String> get trail => [
    for (final r in requests) r.method == 'POST' ? 'POST' : '${r.uri.queryParameters['action']}',
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final posted = _posted;
    requests.add(options);
    final q = options.uri.queryParameters;
    final _Answer answer;
    if (options.method == 'POST') {
      answer = (body: post, status: 200);
    } else if (q['id'] == 'tsdmapp:api' && q['action'] == 'checkin') {
      answer = posted ? after[_afterIndex < after.length - 1 ? _afterIndex++ : _afterIndex] : before;
    } else {
      fail('unexpected request ${options.method} ${options.uri}');
    }
    final body = answer.body;
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      answer.status,
      headers: {
        Headers.contentTypeHeader: [
          if (body is String) 'text/xml; charset=utf-8' else 'application/json; charset=utf-8',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

_Answer _ok(Map<String, dynamic> json) => (body: json, status: 200);

Future<CheckinResult> _run(_Forum forum) => doCheckin(
  NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
  CheckinFeeling.happy,
  'hi',
).run();

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(TsdmAppApi.reset);

  group('the API answers: its state after the post decides', () {
    test('the real answers: checked in after the post, the words kept for the user', () async {
      final forum = _Forum(before: _ok(_before), after: [_ok(_checked)], post: _fixture('checkin_post'));
      final result = await _run(forum);
      expect(result, isA<CheckinResultSuccess>().having((e) => e.message, 'message', contains('签到成功')));
      expect(forum.trail, ['checkin', 'POST', 'checkin']);
    });

    test('checked in although the words say nothing known: a success', () async {
      for (final text in ['打卡完成，获得天使币 10', 'Checked in. +10', '']) {
        final forum = _Forum(before: _ok(_before), after: [_ok(_checked)], post: _postWith(text));
        expect(await _run(forum), isA<CheckinResultSuccess>(), reason: text);
      }
    });

    test('not checked in although the words say "签到成功": never a success', () async {
      final forum = _Forum(before: _ok(_before), after: [_ok(_notChecked())], post: _fixture('checkin_post'));
      expect(await _run(forum), isA<CheckinResultOtherError>());
    });

    test('the day turned while the answer was waited for: the checkin recorded since the post is the one', () async {
      // Posted at 23:59:5x: the answer after the wait is of the next day, the checkin of the post is `last_time`.
      final nextDay = {..._notChecked(), 'time': 1700000012, 'last_time': 1700000003};
      final forum = _Forum(before: _ok(_before), after: [_ok(nextDay)], post: _postWith('打卡完成'));
      expect(await _run(forum), isA<CheckinResultSuccess>());
      // A checkin of the day before the post is not the one.
      final older = {...nextDay, 'last_time': 1699999990};
      final none = _Forum(before: _ok(_before), after: [_ok(older)], post: _postWith('打卡完成'));
      expect(await _run(none), isA<CheckinResultOtherError>());
    });

    test('"too soon" after the post is waited for, then the state decides', () async {
      final forum = _Forum(
        before: _ok(_before),
        after: [
          (body: {'ok': 0, 'error': 'busy', 'retry_after': 0}, status: 429),
          _ok(_checked),
        ],
        post: _postWith('打卡完成'),
      );
      expect(await _run(forum), isA<CheckinResultSuccess>());
      expect(forum.trail, ['checkin', 'POST', 'checkin', 'checkin']);
    });

    test('checked in, the words saying it was done already: done elsewhere meanwhile', () async {
      final forum = _Forum(before: _ok(_before), after: [_ok(_checked)], post: _fixture('checkin_post_again'));
      expect(await _run(forum), isA<CheckinResultAlreadyChecked>());
    });

    test('not checked in: the words tell why, the closed window when they do not', () async {
      for (final (text, after, expected) in [
        ('已经过了签到时间段', _notChecked(open: false), isA<CheckinResultLateInTime>()),
        ('签到时间还未开始', _notChecked(open: false), isA<CheckinResultEarlyInTime>()),
        ('打卡未开放', _notChecked(open: false), isA<CheckinResultEarlyInTime>()),
        ('您需要先登录才能继续本操作', _notChecked(), isA<CheckinResultNotAuthorized>()),
        ('出了点问题', _notChecked(), isA<CheckinResultOtherError>().having((e) => e.message, 'message', '出了点问题')),
      ]) {
        final forum = _Forum(before: _ok(_before), after: [_ok(after)], post: _postWith(text));
        expect(await _run(forum), expected, reason: text);
      }
    });

    test('the API says the session expired after the post: not logged in', () async {
      final forum = _Forum(
        before: _ok(_before),
        after: [
          _ok({'ok': 0, 'error': 'login'}),
        ],
        post: _postWith('打卡完成'),
      );
      expect(await _run(forum), isA<CheckinResultNotAuthorized>());
    });
  });

  group('the API does not tell after the post: the words decide, as before', () {
    test('no checkin plugin, a failed read: the words of the real answers', () async {
      for (final (label, after) in <(String, _Answer)>[
        ('no checkin plugin', _ok({'ok': 1, 'api': 1, 'time': 1700000000, 'installed': 0})),
        ('an older answer without the state', _ok({'ok': 1, 'api': 1, 'time': 1700000000, 'installed': 1})),
        ('busy for too long', (body: {'ok': 0, 'error': 'busy', 'retry_after': 30}, status: 429)),
      ]) {
        final ok = _Forum(before: _ok(_before), after: [after], post: _fixture('checkin_post'));
        expect(await _run(ok), isA<CheckinResultSuccess>(), reason: label);
        final again = _Forum(before: _ok(_before), after: [after], post: _fixture('checkin_post_again'));
        expect(await _run(again), isA<CheckinResultAlreadyChecked>(), reason: label);
        final unknown = _Forum(before: _ok(_before), after: [after], post: _postWith('打卡完成'));
        expect(await _run(unknown), isA<CheckinResultOtherError>(), reason: label);
      }
    });
  });
}
