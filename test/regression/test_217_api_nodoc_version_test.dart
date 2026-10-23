/// The forum's app API, plugin 2.3.0: lean answers (`nodoc=1`) and the plugin version on the settings page.
///
/// Every page asked in the JSON mode (`tsdmapp=json`) now asks for a lean answer as well (`nodoc=1`): plugin 2.3.0
/// then leaves the `document` and `head` blocks out of an answer that carries the page as structured fields (`schema`:
/// the forum page, the thread page, the profile, the homepage) and out of the forum's own message (`error: message`,
/// with `login`), which the app never reads the blocks of. An older plugin ignores the parameter. So an answer with a
/// `schema` (or a message with `login`) is a page whether or not it has a `document` ([tsdmAppAnswerHasStructuredPage]):
/// neither the antitheft interceptor (which took a thread answer without the posts for the hidden challenge) nor the
/// repositories (which took an answer without a `document` for a failed request) may ask the web page for it. An
/// answer without `schema` and without `document` (an older plugin's failed build, the challenge without its document)
/// is still no page.
///
/// The settings page shows the version the plugin last named in a `status` or `notify` answer
/// ([TsdmAppApi.pluginInfo], nothing is asked by the page itself) beside the version the app was written against
/// ([expectedTsdmAppVersion]), with a note when the forum's is older; `nodoc: 1` of a `status` answer is kept too.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/profile/utils/profile_page_api.dart';
import 'package:tsdm_client/features/search/repository/search_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/settings_page.dart';
import 'package:tsdm_client/features/theme/cubit/theme_cubit.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/antitheft_interceptor.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';

const _dir = 'test/data/tsdmapp';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

Map<String, dynamic> _json(String name) => jsonDecode(_raw(name)) as Map<String, dynamic>;

Translations get tr => LocaleSettings.instance.currentTranslations;

/// One answer of the fake forum.
typedef _Answer = ({String body, bool json});

_Answer _html(String body) => (body: body, json: false);

_Answer _api(Object answer) => (body: answer is String ? answer : jsonEncode(answer), json: true);

/// A forum answering every request with [answer] and recording it.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  _Forum.always(_Answer answer) : this((_) => answer);

  final _Answer Function(RequestOptions options) answer;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final a = answer(options);
    return ResponseBody.fromString(
      a.body,
      200,
      headers: {
        Headers.contentTypeHeader: [if (a.json) 'application/json; charset=utf-8' else 'text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A client of [forum], with the interceptors of the app (the antitheft one among them).
NetClientProvider _client(_Forum forum) =>
    NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

void _use(_Forum forum) => getIt.registerFactory<NetClientProvider>(() => _client(forum));

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

bool _asksJson(RequestOptions r) => r.uri.queryParameters['tsdmapp'] == 'json';

bool _asksLean(RequestOptions r) => r.uri.queryParameters['nodoc'] == '1';

/// A GET of [url], as the interceptor sees it.
RequestOptions _get(String url) => RequestOptions(path: url);

const _thread = '$baseUrl/forum.php?mod=viewthread&tid=9199345';

/// The plugin's `status` answer of [version], with `nodoc: 1` when [nodoc] (plugin 2.3.0).
Map<String, Object?> _status(String version, {bool nodoc = false}) => {
  'ok': 1,
  'api': 1,
  'version': version,
  'time': 1792000000,
  'uid': 35,
  'formhash': 'a1b2c3d4',
  'actions': ['status', 'notify', 'checkin'],
  if (nodoc) 'nodoc': 1,
};

/// The plugin's `notify` answer of [version] (1.9.0 names it; an older one does not: [version] null).
Map<String, Object?> _notify(String? version) => {
  'ok': 1,
  'api': 1,
  'version': ?version,
  'time': 1792000000,
  'uid': 35,
  if (version != null) 'formhash': 'a1b2c3d4',
  if (version != null) 'timeoffset': 8,
  'counts': {'notice': 0, 'pm': 0, 'announce': 0},
  'pm_last': 0,
  'notices': <Object?>[],
  'pms': <Object?>[],
  'announces': <Object?>[],
};

/// Every image request fails at once: images are not part of these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// A few frames with real time in between, for the database.
Future<void> _settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

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
  tearDown(() async {
    if (getIt.isRegistered<NetClientProvider>()) {
      await getIt.unregister<NetClientProvider>();
    }
  });

  group('E. nodoc=1 goes with the JSON mode', () {
    test('withTsdmAppJson adds both parameters, once, before the fragment; never without the JSON mode', () {
      expect(withTsdmAppJson(_thread), '$_thread&tsdmapp=json&nodoc=1');
      expect(withTsdmAppJson('$baseUrl/forum.php'), '$baseUrl/forum.php?tsdmapp=json&nodoc=1');
      expect(withTsdmAppJson('$baseUrl/forum.php#top'), '$baseUrl/forum.php?tsdmapp=json&nodoc=1#top');
      // Already in the JSON mode: as it is, the parameters once.
      final once = withTsdmAppJson(withTsdmAppJson(_thread));
      expect('tsdmapp=json'.allMatches(once), hasLength(1));
      expect('nodoc=1'.allMatches(once), hasLength(1));
      // An AJAX url is not asked in the JSON mode, so not lean either.
      const ajax = '$baseUrl/misc.php?mod=getatuser&inajax=1';
      expect(withTsdmAppJson(ajax), ajax);
      expect(Uri.parse(withTsdmAppJson(ajax)).queryParameters, isNot(contains('nodoc')));
      // The map of the pages that build their url from parameters carries both.
      expect(tsdmAppJsonQueryParameters, {'tsdmapp': 'json', 'nodoc': '1'});
      // An action of the API is not a page: no JSON mode, no nodoc.
      expect(Uri.parse(TsdmAppApi.url('status')).queryParameters.keys, isNot(contains('nodoc')));
      expect(Uri.parse(TsdmAppApi.url('status')).queryParameters.keys, isNot(contains('tsdmapp')));
    });

    test('the forum page and the search, whose urls are built from parameters, ask lean too', () async {
      final forum = _Forum.always(_api(_json('forum_v2_fid2_guest.json')));
      _use(forum);
      _right(await ForumRepository().fetchForum(fid: '2', filterState: const FilterState()).run());
      expect(forum.requests.single.uri.queryParameters, containsPair('tsdmapp', 'json'));
      expect(forum.requests.single.uri.queryParameters, containsPair('nodoc', '1'));
      await getIt.unregister<NetClientProvider>();

      final search = _Forum.always(_html('<html><body><div id="ct"></div></body></html>'));
      _use(search);
      try {
        await SearchRepository().searchWithParameters(keyword: 'x', fid: '0', uid: '0', pageNumber: 1).run();
      } on Object {
        // Only the request is of interest here.
      }
      expect(search.requests, isNotEmpty);
      expect(search.requests.first.uri.queryParameters, containsPair('tsdmapp', 'json'));
      expect(search.requests.first.uri.queryParameters, containsPair('nodoc', '1'));
    });

    test('the web page the interceptor asks for a hidden challenge carries neither parameter', () async {
      // An older plugin's `unknown` answer with its (post-less) document: the challenge, asked as the web page.
      final forum = _Forum(
        (o) => _asksJson(o)
            ? _api({'ok': 0, 'error': 'unknown', 'formhash': 'abcd1234', 'document': '<div id="wp"></div>'})
            : _html('<html><body><div id="postlist">web</div></body></html>'),
      );
      _use(forum);
      final doc = _right(await ThreadRepository().fetchThread(tid: '9199345').run());
      expect(doc.querySelector('div#postlist')?.text, 'web');
      expect(forum.requests.map(_asksJson), [true, false]);
      expect(forum.requests.map(_asksLean), [true, false]);
      expect(
        forum.requests[1].uri.queryParameters,
        Map.of(forum.requests[0].uri.queryParameters)
          ..remove('tsdmapp')
          ..remove('nodoc'),
      );
    });
  });

  group('E. an answer with a schema (or a message with login) is a page without a document', () {
    test('tsdmAppAnswerWithoutPage: the structured answers and the messages of the fixtures, without document', () {
      for (final name in [
        'forum_v2_fid2_guest',
        'forum_v2_fid26_denied',
        'thread_v3_plain_guest',
        'thread_v3_denied_guest',
        'profile_v4_username',
        'profile_v4_guest',
      ]) {
        final json = _json('$name.json');
        expect(json, isNot(contains('document')), reason: '$name is a lean answer');
        expect(tsdmAppAnswerHasStructuredPage(json), isTrue, reason: name);
        expect(tsdmAppAnswerWithoutPage(json), isFalse, reason: '$name as a map');
        expect(tsdmAppAnswerWithoutPage(_raw('$name.json')), isFalse, reason: '$name as text');
        expect(tsdmAppAnswerWithoutContent(json), isFalse, reason: name);
      }
    });

    test('tsdmAppAnswerWithoutPage: without schema and without document is still no page, as before', () {
      for (final answer in [
        {'ok': 0, 'error': 'internal'},
        {'ok': 0, 'error': 'unknown', 'formhash': 'abcd1234'},
        {
          'ok': 1,
          'type': 'thread',
          'thread': {'tid': 1},
        },
        // The forum's message of plugin 2.1.0 names no `login`; its document is always there, and without one it is
        // nothing the app can show.
        {'ok': 0, 'error': 'message', 'message': 'x'},
      ]) {
        expect(tsdmAppAnswerHasStructuredPage(answer), isFalse, reason: '$answer');
        expect(tsdmAppAnswerWithoutPage(answer), isTrue, reason: '$answer');
        expect(tsdmAppAnswerWithoutPage(jsonEncode(answer)), isTrue, reason: '$answer as text');
      }
      // With a document, a page as ever; and no document at all is no page.
      expect(tsdmAppAnswerWithoutPage({'ok': 1, 'document': '<div id="postlist"></div>'}), isFalse);
      expect(tsdmAppAnswerWithoutPage(null), isTrue);
      expect(tsdmAppAnswerWithoutPage(''), isTrue);
      // The challenge (`unknown`, a document without posts) has no content; the thread cache a guest is served has.
      expect(tsdmAppAnswerWithoutContent({'ok': 0, 'error': 'unknown', 'document': '<div id="wp"></div>'}), isTrue);
      expect(
        tsdmAppAnswerWithoutContent({'ok': 0, 'error': 'unknown', 'document': '<div id="postlist">x</div>'}),
        isFalse,
      );
    });

    test('the antitheft interceptor does not take a lean structured answer for the hidden challenge', () {
      final get = _get(withTsdmAppJson(_thread));
      for (final name in ['thread_v3_plain_guest', 'thread_v3_denied_guest', 'thread_v3_denied']) {
        expect(AntitheftInterceptor.hidesChallenge(get, _json('$name.json')), isFalse, reason: name);
        expect(AntitheftInterceptor.hidesChallenge(get, _raw('$name.json')), isFalse, reason: '$name as text');
      }
      // As before: the challenge's answer (no posts), a failed build, and an `unknown` without any document.
      for (final answer in [
        {'ok': 0, 'error': 'unknown', 'formhash': 'abcd1234', 'document': '<div id="wp"></div>'},
        {'ok': 0, 'error': 'internal'},
        {'ok': 0, 'error': 'unknown', 'formhash': 'abcd1234'},
      ]) {
        expect(AntitheftInterceptor.hidesChallenge(get, answer), isTrue, reason: '$answer');
        expect(AntitheftInterceptor.hidesChallenge(get, jsonEncode(answer)), isTrue, reason: '$answer as text');
      }
    });

    test(
      'the thread page: built from the lean answer through the client, one request, the web page never asked',
      () async {
        final forum = _Forum.always(_api(_raw('thread_v3_plain_guest.json')));
        _use(forum);
        final page = _right(await ThreadRepository().fetchThreadPage(tid: '9199345').run());
        expect(page.postList, isNotEmpty);
        expect(page.tid, '9199345');
        expect(forum.requests, hasLength(1), reason: 'no web page asked for the challenge');
        expect(_asksJson(forum.requests.single), isTrue);
        expect(_asksLean(forum.requests.single), isTrue);
        await getIt.unregister<NetClientProvider>();

        // The forum's message with `login`, no schema, no document: a page too.
        final denied = _Forum.always(_api(_raw('thread_v3_denied_guest.json')));
        _use(denied);
        final message = _right(await ThreadRepository().fetchThreadPage(tid: '9199345').run());
        expect(message.needLogin, isTrue);
        expect(message.postList, isEmpty);
        expect(denied.requests, hasLength(1));
      },
    );

    test('the forum page and the profile: built from the lean answer, one request each', () async {
      final forum = _Forum.always(_api(_raw('forum_v2_fid2_guest.json')));
      _use(forum);
      final board = _right(await ForumRepository().fetchForum(fid: '2', filterState: const FilterState()).run());
      expect(board.normalThreadList, isNotEmpty);
      expect(forum.requests, hasLength(1));
      await getIt.unregister<NetClientProvider>();

      final deniedForum = _Forum.always(_api(_raw('forum_v2_fid26_denied.json')));
      _use(deniedForum);
      final denied = _right(await ForumRepository().fetchForum(fid: '26', filterState: const FilterState()).run());
      expect(denied.havePermission, isFalse);
      expect(denied.permissionDeniedMessage, isNotNull);
      expect(deniedForum.requests, hasLength(1));
      await getIt.unregister<NetClientProvider>();

      final profile = _Forum.always(_api(_raw('profile_v4_username.json')));
      _use(profile);
      final page = _right(await ProfileRepository().fetchProfile(username: 'ag_mid').run());
      expect(page, isA<ProfileApiPage>());
      expect(_right(await buildProfilePage(page).run()).uid, '33');
      expect(profile.requests, hasLength(1));
      expect(_asksLean(profile.requests.single), isTrue);
      await getIt.unregister<NetClientProvider>();

      final guest = _Forum.always(_api(_raw('profile_v4_guest.json')));
      _use(guest);
      final guestPage = _right(await ProfileRepository().fetchProfile(uid: '32').run());
      expect(guestPage, isA<ProfileApiPage>());
      expect(guestPage.loggedIn, isFalse);
      expect(guest.requests, hasLength(1));
    });

    test('an old answer without schema and without document is still a failed request', () async {
      final forum = _Forum.always(_api({'ok': 0, 'error': 'internal'}));
      _use(forum);
      final thread = await ThreadRepository().fetchThreadPage(tid: '9199345').run();
      expect(thread.getLeft().toNullable(), isA<HttpRequestFailedException>());
      // The interceptor asked the web page once for it (the plugin may have hidden the challenge), as before.
      expect(forum.requests.map(_asksJson), [true, false]);
      await getIt.unregister<NetClientProvider>();

      final board = _Forum.always(_api({'ok': 0, 'error': 'internal'}));
      _use(board);
      final page = await ForumRepository().fetchForum(fid: '2', filterState: const FilterState()).run();
      expect(page.getLeft().toNullable(), isA<HttpRequestFailedException>());
      expect(board.requests, hasLength(1));
      await getIt.unregister<NetClientProvider>();

      final profile = _Forum.always(_api({'ok': 0, 'error': 'internal'}));
      _use(profile);
      final me = await ProfileRepository().fetchProfile(uid: '35').run();
      expect(me.getLeft().toNullable(), isA<HttpRequestFailedException>());
    });
  });

  group("E. the forum's message answered without its blocks", () {
    test('tsdmAppPageDocument rebuilds the 提示信息 page the parsers read: text, prompt, class, account', () {
      final denied = {'ok': 0, 'error': 'message', 'message': '抱歉，<b>您</b>没有权限', 'login': 0, 'uid': 35};
      for (final data in [denied, jsonEncode(denied)]) {
        final doc = tsdmAppPageDocument(data);
        expect(doc.querySelector('div#messagetext > p')?.text, '抱歉，<b>您</b>没有权限', reason: 'escaped, not html');
        expect(doc.querySelector('div#messagetext')?.classes, contains('alert_error'));
        expect(doc.querySelector('div#messagelogin'), isNull);
        expect(parseLoggedUidFromDocument(doc), 35, reason: 'the discuz_uid of the 2.2.x head');
        expect(doc.querySelector('div#wp.wp div#ct'), isNotNull);
      }
      final login = {'ok': 0, 'error': 'message', 'message': '您需要先登录才能继续本操作', 'login': 1, 'uid': 0};
      final doc = tsdmAppPageDocument(login);
      expect(doc.querySelector('div#messagetext > p')?.text, '您需要先登录才能继续本操作');
      expect(doc.querySelector('div#messagetext')?.classes, contains('alert_info'));
      expect(doc.querySelector('div#messagelogin'), isNotNull);
      expect(parseLoggedUidFromDocument(doc), isNull, reason: 'a guest');
      expect(doc.querySelector('form#lsform'), isNull, reason: 'the 2.2.x blocks had no header either');
      // Only the message: a structured answer without blocks is no page to rebuild, an answer with blocks is its blocks.
      expect(tsdmAppPageDocument(_json('thread_v3_plain_guest.json')).querySelector('div#messagetext'), isNull);
      expect(tsdmAppPageDocument({...login, 'document': '<p id="given">x</p>'}).querySelector('p#given'), isNotNull);
      expect(tsdmAppPageHtml(login), contains('messagelogin'));
    });

    test('fetchThread: the message as the page, a lean structured answer a failure, its blocks when given', () async {
      final lean = _Forum.always(_api(_raw('thread_v3_plain_guest.json')));
      _use(lean);
      final structured = await ThreadRepository().fetchThread(tid: '9199345').run();
      expect(structured.getLeft().toNullable(), isA<HttpRequestFailedException>(), reason: 'nothing to parse');
      expect(lean.requests, hasLength(1), reason: 'not the challenge: no web page asked');
      await getIt.unregister<NetClientProvider>();

      _use(_Forum.always(_api(_raw('thread_v3_plain.json'))));
      final withBlocks = _right(await ThreadRepository().fetchThread(tid: '9199345').run());
      expect(withBlocks.querySelector('div#wp'), isNotNull, reason: 'the garbage document the fixture keeps');
      await getIt.unregister<NetClientProvider>();

      final denied = _Forum.always(_api(_raw('thread_v3_denied_guest.json')));
      _use(denied);
      final message = _right(await ThreadRepository().fetchThread(tid: '9199345').run());
      expect(message.querySelector('div#messagelogin'), isNotNull);
      expect(message.querySelector('div#messagetext > p')?.text, isNotEmpty);
      expect(denied.requests, hasLength(1));
    });
  });

  group('I. the plugin version', () {
    test('expected version, and the order of versions', () {
      expect(expectedTsdmAppVersion, '3.1.0');
      expect(compareTsdmAppVersions('2.2.0', '2.3.0'), lessThan(0));
      expect(compareTsdmAppVersions('2.3.0', '2.3.0'), 0);
      expect(compareTsdmAppVersions('2.3', '2.3.0'), 0);
      expect(compareTsdmAppVersions('2.3.1', '2.3.0'), greaterThan(0));
      expect(compareTsdmAppVersions('2.10.0', '2.3.0'), greaterThan(0), reason: 'parts as numbers, not text');
      expect(compareTsdmAppVersions('3.0.0', '2.9.9'), greaterThan(0));
      expect(compareTsdmAppVersions('1.9.0', '2.0.0'), lessThan(0));
      expect(compareTsdmAppVersions('2.3.0-beta', '2.3.0'), 0, reason: 'a suffix is not an order');
      expect(compareTsdmAppVersions('', '2.3.0'), lessThan(0));
    });

    test('TsdmAppPluginInfo.fromAnswer: version, api, nodoc; nothing without a version', () {
      final info = TsdmAppPluginInfo.fromAnswer(_status('3.1.0', nodoc: true))!;
      expect(info.version, '3.1.0');
      expect(info.api, 1);
      expect(info.nodoc, isTrue);
      expect(info.olderThanExpected, isFalse);
      final older = TsdmAppPluginInfo.fromAnswer(_status('2.2.0'))!;
      expect(older.nodoc, isFalse);
      expect(older.olderThanExpected, isTrue);
      expect(
        TsdmAppPluginInfo.fromAnswer(_status('2.3.0', nodoc: true))!.olderThanExpected,
        isTrue,
        reason: 'lean, but no list pages',
      );
      expect(
        TsdmAppPluginInfo.fromAnswer(_status('2.5.0', nodoc: true))!.olderThanExpected,
        isTrue,
        reason: 'every page as structured fields, but not the results of the writes',
      );
      expect(
        TsdmAppPluginInfo.fromAnswer(_status('2.6.0', nodoc: true))!.olderThanExpected,
        isTrue,
        reason: 'the results of the writes, but not the bbcode of the floors',
      );
      expect(
        TsdmAppPluginInfo.fromAnswer(_status('2.7.0', nodoc: true))!.olderThanExpected,
        isTrue,
        reason: 'the bbcode of the floors, but not the special blocks of the threads',
      );
      expect(
        TsdmAppPluginInfo.fromAnswer(_status('2.8.0', nodoc: true))!.olderThanExpected,
        isTrue,
        reason: 'the special blocks of the threads, but not the favorite forums panel of the homepage',
      );
      expect(
        TsdmAppPluginInfo.fromAnswer(_status('2.8.1', nodoc: true))!.olderThanExpected,
        isTrue,
        reason: 'the favorite forums panel, but not the description html of the forums (the activities page)',
      );
      expect(
        TsdmAppPluginInfo.fromAnswer(_status('2.8.4', nodoc: true))!.olderThanExpected,
        isTrue,
        reason: 'the description html of the forums, but not the post forms',
      );
      expect(
        TsdmAppPluginInfo.fromAnswer(_status('3.0.0', nodoc: true))!.olderThanExpected,
        isTrue,
        reason: 'the small forms, but not the previews of the list rows',
      );
      expect(TsdmAppPluginInfo.fromAnswer(_notify(null)), isNull);
      expect(TsdmAppPluginInfo.fromAnswer({'ok': 0, 'error': 'login'}), isNull);
      expect(TsdmAppPluginInfo.fromAnswer({'ok': 1, 'version': ''}), isNull);
      expect(TsdmAppPluginInfo.fromAnswer({'ok': 1, 'version': 7}), isNull);
      expect(info, TsdmAppPluginInfo.fromAnswer(_status('3.1.0', nodoc: true)));
      expect(info, isNot(older));
    });

    test('what a same-version answer leaves out stays known: api, nodoc', () async {
      final answers = <String, Object>{};
      final client = _client(_Forum((o) => _api(answers[o.uri.queryParameters['action']]!)));
      answers['status'] = _status('2.3.0', nodoc: true);
      expect(await TsdmAppApi.ask(client, 'status'), isNotNull);
      answers['notify'] = {'ok': 1, 'version': '2.3.0', 'time': 1792000000, 'uid': 35, 'notices': <Object?>[]};
      expect(await TsdmAppApi.ask(client, 'notify', {'since': '0'}), isNotNull);
      expect(
        TsdmAppApi.pluginInfo.value,
        const TsdmAppPluginInfo(version: '2.3.0', api: 1, nodoc: true, preview: false),
      );
      // Another version: what it leaves out is not known of it.
      answers['notify'] = {'ok': 1, 'version': '2.6.0', 'time': 1792000000, 'uid': 35, 'notices': <Object?>[]};
      expect(await TsdmAppApi.ask(client, 'notify', {'since': '0'}), isNotNull);
      expect(TsdmAppApi.pluginInfo.value, const TsdmAppPluginInfo(version: '2.6.0', api: null, nodoc: false));
      answers['status'] = {..._status('2.6.0', nodoc: true), 'api': 2};
      expect(await TsdmAppApi.ask(client, 'status'), isNotNull);
      expect(
        TsdmAppApi.pluginInfo.value,
        const TsdmAppPluginInfo(version: '2.6.0', api: 2, nodoc: true, preview: false),
      );
    });

    test(
      'kept from the status and notify answers, not from a message or an answer without one; reset forgets',
      () async {
        expect(TsdmAppApi.pluginInfo.value, isNull);
        final answers = <String, Object>{};
        final forum = _Forum((o) => _api(answers[o.uri.queryParameters['action']]!));
        final client = _client(forum);
        final seen = <TsdmAppPluginInfo?>[];
        void listen() => seen.add(TsdmAppApi.pluginInfo.value);
        TsdmAppApi.pluginInfo.addListener(listen);
        addTearDown(() => TsdmAppApi.pluginInfo.removeListener(listen));

        // An older plugin's notify names no version: nothing known yet.
        answers['notify'] = _notify(null);
        expect(await TsdmAppApi.ask(client, 'notify', {'since': '0'}), isNotNull);
        expect(TsdmAppApi.pluginInfo.value, isNull);

        answers['status'] = _status('2.2.0');
        expect(await TsdmAppApi.ask(client, 'status'), isNotNull);
        expect(
          TsdmAppApi.pluginInfo.value,
          const TsdmAppPluginInfo(version: '2.2.0', api: 1, nodoc: false, preview: false),
        );
        expect(TsdmAppApi.pluginInfo.value!.olderThanExpected, isTrue);

        // The same again tells the listeners nothing.
        expect(await TsdmAppApi.ask(client, 'status'), isNotNull);
        expect(seen, hasLength(1));

        // Upgraded: notify names the new version; status says it takes nodoc.
        answers['notify'] = _notify('3.1.0');
        expect(await TsdmAppApi.ask(client, 'notify', {'since': '0'}), isNotNull);
        expect(TsdmAppApi.pluginInfo.value, const TsdmAppPluginInfo(version: '3.1.0', api: 1, nodoc: false));
        answers['status'] = _status('3.1.0', nodoc: true);
        expect(await TsdmAppApi.ask(client, 'status'), isNotNull);
        expect(
          TsdmAppApi.pluginInfo.value,
          const TsdmAppPluginInfo(version: '3.1.0', api: 1, nodoc: true, preview: false),
        );
        expect(TsdmAppApi.pluginInfo.value!.olderThanExpected, isFalse);

        // notify never names nodoc: what status said of the same version holds, and the listeners hear nothing.
        expect(await TsdmAppApi.ask(client, 'notify', {'since': '0'}), isNotNull);
        expect(
          TsdmAppApi.pluginInfo.value,
          const TsdmAppPluginInfo(version: '3.1.0', api: 1, nodoc: true, preview: false),
        );
        expect(seen, hasLength(3));

        // The session expired: the message names no version, what was known stays.
        answers['notify'] = {'ok': 0, 'error': 'login'};
        expect(await TsdmAppApi.ask(client, 'notify', {'since': '0'}), isNotNull);
        expect(
          TsdmAppApi.pluginInfo.value,
          const TsdmAppPluginInfo(version: '3.1.0', api: 1, nodoc: true, preview: false),
        );

        // The one action that writes names it as well; another version, so nodoc is not carried over.
        answers['seen'] = {'ok': 1, 'api': 1, 'version': '2.3.1', 'time': 1792000000, 'uid': 35};
        expect(await TsdmAppApi.post(client, 'seen', {'formhash': 'a1b2c3d4', 'notice': '1'}), isNotNull);
        expect(TsdmAppApi.pluginInfo.value, const TsdmAppPluginInfo(version: '2.3.1', api: 1, nodoc: false));
        expect(seen, hasLength(4));

        TsdmAppApi.reset();
        expect(TsdmAppApi.pluginInfo.value, isNull);
      },
    );
  });

  group('I. the settings row', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<AppDatabase>(db)
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });

    tearDown(() async {
      await settingsBloc.close();
      await settings.dispose();
      await db.close();
    });

    testWidgets('unknown, older, same and newer plugin versions, from the stored value, no request', (tester) async {
      tester.view
        ..physicalSize = const Size(384, 792)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = ThemeCubit();
      addTearDown(theme.close);
      final forum = _Forum.always(_api(_status('2.3.0', nodoc: true)));
      _use(forum);

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<SettingsBloc>.value(value: settingsBloc),
            BlocProvider<ThemeCubit>.value(value: theme),
          ],
          child: TranslationProvider(child: const MaterialApp(home: SettingsPage())),
        ),
      );
      await _settle(tester);

      final t = tr.settingsPage.advancedSection.forumApi;
      final row = find.byKey(const ValueKey('settings-forum-api'));
      final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(row, 200, scrollable: list);
      await tester.pumpAndSettle();
      expect(find.descendant(of: row, matching: find.text(t.title)), findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.text(t.notDetected(expected: expectedTsdmAppVersion)),
        ),
        findsOneWidget,
        reason: 'nothing seen yet',
      );
      expect(find.descendant(of: row, matching: find.textContaining(t.olderNote)), findsNothing);
      expect(forum.requests, isEmpty, reason: 'the settings page asks the forum nothing');

      // An older plugin: the versions and the note.
      TsdmAppApi.pluginInfo.value = const TsdmAppPluginInfo(version: '2.2.0', api: 1, nodoc: false);
      await tester.pumpAndSettle();
      final olderLine = t.detected(seen: '2.2.0', expected: expectedTsdmAppVersion);
      expect(find.descendant(of: row, matching: find.text('$olderLine\n${t.olderNote}')), findsOneWidget);
      expect(tester.widget<ListTile>(row).isThreeLine, isTrue);

      // The expected plugin: no note.
      TsdmAppApi.pluginInfo.value = const TsdmAppPluginInfo(version: '3.1.0', api: 1, nodoc: true);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: row,
          matching: find.text(t.detected(seen: '3.1.0', expected: expectedTsdmAppVersion)),
        ),
        findsOneWidget,
      );
      expect(find.descendant(of: row, matching: find.textContaining(t.olderNote)), findsNothing);
      expect(tester.widget<ListTile>(row).isThreeLine, isFalse);

      // A newer plugin: no note either.
      TsdmAppApi.pluginInfo.value = const TsdmAppPluginInfo(version: '3.10.0', api: 1, nodoc: true);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: row,
          matching: find.text(t.detected(seen: '3.10.0', expected: expectedTsdmAppVersion)),
        ),
        findsOneWidget,
      );
      expect(find.descendant(of: row, matching: find.textContaining(t.olderNote)), findsNothing);

      // Forgotten (reset, as after the user asks to check the API again): back to unknown.
      TsdmAppApi.reset();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: row,
          matching: find.text(t.notDetected(expected: expectedTsdmAppVersion)),
        ),
        findsOneWidget,
      );
      expect(forum.requests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
