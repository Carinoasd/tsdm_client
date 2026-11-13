/// A forum's app API plugin older than 3.5.0 ([tsdmAppMinimumVersion]) is treated as missing: its actions are not
/// used and every caller takes its web page path.
///
/// The forum ran plugin 3.5.0 for a long time; the special handling of the plugins before it was dropped. A `status`
/// or `notify` answer naming an older version (or a `notify` naming none, before 1.9.0) is dropped, the API is not
/// asked for an hour, and after that only `status` and `notify` are asked until one names a supported version. What
/// the app reads of the version (the reply window asked as a post form, the previews of the list rows) needs 3.5.0.
/// Pages asked in the JSON mode name no version and are not covered here: their readers keep telling an older
/// plugin's answer from its fields.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';

final int _now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

Map<String, Object?> _status(String version) => {
  'ok': 1,
  'api': 1,
  'version': version,
  'time': _now,
  'uid': 31,
  'formhash': 'f1f2f3f4',
  'actions': ['status', 'notify', 'checkin', 'seen'],
  'nodoc': 1,
  'preview': 1,
};

/// A `notify` answer with nothing new; [version] null is a plugin before 1.9.0 (no version, no lists).
Map<String, Object?> _notify(String? version) => {
  'ok': 1,
  'api': 1,
  'version': ?version,
  'time': _now,
  'uid': 31,
  if (version != null) 'formhash': 'f1f2f3f4',
  if (version != null) 'timeoffset': 8,
  'counts': {'notice': 0, 'pm': 0, 'announce': 0},
  'notices': <Object?>[],
  'pms': <Object?>[],
  'announces': <Object?>[],
};

const _page = '<html><body><div id="um"><a href="home.php?mod=space&amp;uid=31">user1</a></div></body></html>';

/// Answers each action of the API with [answers] (by action) and every other request with [_page].
final class _Forum implements HttpClientAdapter {
  final answers = <String, Object>{};
  final requests = <RequestOptions>[];

  List<String> get actions => [
    for (final r in requests)
      if (r.uri.queryParameters['id'] == 'tsdmapp:api') r.uri.queryParameters['action']!,
  ];

  List<RequestOptions> get pages => requests.where((e) => e.uri.queryParameters['id'] != 'tsdmapp:api').toList();

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancel) async {
    requests.add(options);
    final q = options.uri.queryParameters;
    if (q['id'] == 'tsdmapp:api') {
      final answer = answers[q['action']] ?? {'ok': 0, 'error': 'action'};
      return ResponseBody.fromString(
        jsonEncode(answer),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json; charset=utf-8'],
        },
      );
    }
    return ResponseBody.fromString(
      _page,
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

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(getIt.reset);
  setUp(TsdmAppApi.reset);

  test('the minimum and the expected version', () {
    expect(tsdmAppMinimumVersion, '3.5.0');
    expect(expectedTsdmAppVersion, '3.9.0');
    expect(compareTsdmAppVersions(expectedTsdmAppVersion, tsdmAppMinimumVersion), greaterThan(0));
  });

  for (final version in ['3.4.0', '2.9.0', '1.9.0']) {
    test('status of plugin $version: dropped, treated as missing, the version still shown', () async {
      final forum = _Forum()..answers['status'] = _status(version);
      final client = _client(forum);
      expect(await TsdmAppApi.ask(client, 'status'), isNull);
      expect(TsdmAppApi.knownTooOld, isTrue);
      expect(TsdmAppApi.knownUnavailable, isTrue);
      expect(TsdmAppApi.pluginInfo.value?.version, version, reason: 'the settings page names it');
      expect(TsdmAppApi.pluginInfo.value?.olderThanExpected, isTrue);
      expect(TsdmAppApi.knowsPostForm, isFalse, reason: 'the reply window is asked as the forum gives it');
      expect(TsdmAppApi.knowsPreview, isFalse, reason: 'its status says preview: 1, but it is not used');
      // Nothing more is asked or posted of it for the hour.
      forum.answers['checkin'] = {'ok': 1, 'installed': 1};
      expect(await TsdmAppApi.ask(client, 'checkin'), isNull);
      expect(await TsdmAppApi.ask(client, 'notify'), isNull);
      expect(await TsdmAppApi.post(client, 'seen', {'formhash': 'f1f2f3f4', 'notice': '1'}), isNull);
      expect(forum.actions, ['status']);
    });
  }

  test('notify of a plugin before 1.9.0 (no version): dropped, treated as missing', () async {
    final forum = _Forum()..answers['notify'] = _notify(null);
    expect(await TsdmAppApi.ask(_client(forum), 'notify', {'since': '0'}), isNull);
    expect(TsdmAppApi.knownTooOld, isTrue);
    expect(TsdmAppApi.knownUnavailable, isTrue);
  });

  test('notify of plugin 3.4.0: the notification fetch reads the three pages, as without the plugin', () async {
    final forum = _Forum()..answers['notify'] = _notify('3.4.0');
    final result = await NotificationRepository().fetchNotificationWith(_client(forum), timestamp: _now - 60).run();
    expect(result.isRight(), isTrue);
    expect(forum.actions, ['notify'], reason: 'no pmlist, no seen');
    expect(forum.pages, hasLength(3), reason: 'the notice, private message and broadcast message pages');
    expect(TsdmAppApi.knownTooOld, isTrue);
  });

  test('3.5.0 and later: used', () async {
    for (final version in ['3.5.0', '3.8.0', '3.9.0', '3.10.0']) {
      TsdmAppApi.reset();
      final forum = _Forum()
        ..answers['status'] = _status(version)
        ..answers['notify'] = _notify(version);
      final client = _client(forum);
      expect(await TsdmAppApi.ask(client, 'status'), isNotNull, reason: version);
      expect(await TsdmAppApi.ask(client, 'notify', {'since': '0'}), isNotNull, reason: version);
      expect(TsdmAppApi.knownTooOld, isFalse, reason: version);
      expect(TsdmAppApi.knowsPostForm, isTrue, reason: version);
      expect(TsdmAppApi.knowsPreview, isTrue, reason: version);
    }
  });

  test('after the hour only status and notify are asked, until one names a supported version', () async {
    final forum = _Forum()
      ..answers['status'] = _status('3.4.0')
      ..answers['checkin'] = {'ok': 1, 'installed': 1};
    final client = _client(forum);
    expect(await TsdmAppApi.ask(client, 'status'), isNull);
    TsdmAppApi.expireUnavailable();
    expect(await TsdmAppApi.ask(client, 'checkin'), isNull, reason: 'still the old plugin as far as known');
    expect(await TsdmAppApi.post(client, 'seen', {'formhash': 'f1f2f3f4', 'notice': '1'}), isNull);
    expect(forum.actions, ['status']);

    // Upgraded meanwhile.
    forum.answers['notify'] = _notify('3.9.0');
    expect(await TsdmAppApi.ask(client, 'notify', {'since': '0'}), isNotNull);
    expect(TsdmAppApi.knownTooOld, isFalse);
    expect(await TsdmAppApi.ask(client, 'checkin'), isNotNull);
    expect(forum.actions, ['status', 'notify', 'checkin']);
  });

  test('a version named by another action tells nothing of the minimum', () async {
    final forum = _Forum()
      // The smilies table names the plugin `plugin_version`; the batch rate plugin names its own `version`.
      ..answers['smilies'] = {'ok': 1, 'api': 1, 'plugin_version': '2.7.0', 'version': 'abc', 'smilies': <Object>[]}
      ..answers['batchrate'] = {'ok': 1, 'type': 'batchrate', 'supported': 1, 'version': '1.3.2'}
      ..answers['checkin'] = {'ok': 1, 'installed': 1, 'version': '1.0.0'};
    final client = _client(forum);
    for (final action in ['smilies', 'batchrate', 'checkin']) {
      expect(await TsdmAppApi.ask(client, action), isNotNull, reason: action);
    }
    expect(TsdmAppApi.knownTooOld, isFalse);
    expect(TsdmAppApi.knownUnavailable, isFalse);
  });

  test('the sync of plugin 3.4.0 is told unsupported, nothing asked', () async {
    final forum = _Forum()
      ..answers['status'] = _status('3.4.0')
      ..answers['sync'] = {'ok': 1, 'supported': 1, 'uid': 31, 'updated': 0, 'formhash': 'f1f2f3f4'};
    final client = _client(forum);
    expect(await TsdmAppApi.ask(client, 'status'), isNull);
    expect(await TsdmAppSyncApi((_) => client).pull(31), isA<SyncUnsupported>());
    expect(forum.actions, ['status']);
  });

  test('a version that is not a number tells nothing of the minimum', () async {
    for (final version in ['dev', 'v3.9.0']) {
      TsdmAppApi.reset();
      final forum = _Forum()..answers['status'] = _status(version);
      expect(await TsdmAppApi.ask(_client(forum), 'status'), isNotNull, reason: version);
      expect(TsdmAppApi.knownTooOld, isFalse, reason: version);
      expect(TsdmAppApi.knownUnavailable, isFalse, reason: version);
    }
  });

  test('a message names no version: not taken for an old plugin', () async {
    final forum = _Forum()
      ..answers['status'] = {'ok': 0, 'error': 'login'}
      ..answers['notify'] = {'ok': 0, 'error': 'login'};
    final client = _client(forum);
    expect(await TsdmAppApi.ask(client, 'status'), isNotNull);
    expect(await TsdmAppApi.ask(client, 'notify'), isNotNull);
    expect(TsdmAppApi.knownTooOld, isFalse);
    expect(TsdmAppApi.knownUnavailable, isFalse);
  });
}
