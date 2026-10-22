/// Another member's threads and replies in the app ("TA的主题", `home.php?mod=space&uid=N&do=thread&view=me`).
///
/// The link of a profile or a floor naming a member (by uid and/or by name, `type=thread|reply`) opened their profile,
/// the search by their name or the web page; it now opens the member's page, two tabs as the forum's page has. The
/// account's own list still opens "my threads", and a list naming nobody too. The forum's app API answers another
/// member's list as it answers the own one (plugin 2.4.0, `schema: 9`: `owner` is the member asked with `uid=`, the
/// top-level `uid` the viewer); an older plugin's answer and the web page are parsed as the "my threads" page parses
/// them, with the same parser.
///
/// Fixtures: `mythread_v9_other.json` is the answer of the test forum to `uid=31&type=thread` asked as uid 35 (the
/// contract tool, `fixtures.py --group mythread`; fetched again on 2026-10-23, the same but for `time`).
/// `mythread_v9_other_reply.json` is derived from `mythread_v9_reply.json` of the same tool, which has no reply list of
/// another member: `owner` and `self` rewritten as the plugin README describes `schema: 9` for `uid=` (the source is
/// named in its `_derived_from`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/member_thread/cubit/member_thread_cubit.dart';
import 'package:tsdm_client/features/member_thread/utils/member_thread_url.dart';
import 'package:tsdm_client/features/member_thread/view/member_thread_page.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';

const _dir = 'test/data/tsdmapp';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

Map<String, dynamic> _json(String name) => jsonDecode(_raw(name)) as Map<String, dynamic>;

/// One answer of the fake forum.
typedef _Answer = ({String body, bool json});

_Answer _html(String body) => (body: body, json: false);

_Answer _api(Object answer) => (body: answer is String ? answer : jsonEncode(answer), json: true);

/// A forum answering every request with [answer], recording it; [gate] holds the answers back until completed.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  final FutureOr<_Answer> Function(RequestOptions options) answer;
  final requests = <RequestOptions>[];
  Completer<void>? gate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final a = await answer(options);
    await gate?.future;
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

void _use(_Forum forum) => getIt.registerFactory<NetClientProvider>(
  () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
);

bool _asksLean(RequestOptions o) => o.uri.queryParameters['tsdmapp'] == 'json' && o.uri.queryParameters['nodoc'] == '1';

/// The test forum's lists of uid 31 as uid 35 sees them, by `type` and `page`.
_Answer _member31(RequestOptions o) {
  final reply = o.uri.queryParameters['type'] == 'reply';
  final json = _json(reply ? 'mythread_v9_other_reply.json' : 'mythread_v9_other.json');
  if (o.uri.queryParameters['page'] == '2') {
    json
      ..['page'] = 2
      ..['has_next'] = 0
      ..['threads'] = (json['threads'] as List).take(3).toList();
  }
  return _api(json);
}

/// The session the cubit reads: the account and its generation, changed by the tests.
MemberThreadSession _session = (uid: 35, generation: 1);

MemberThreadCubit _cubit({String? uid = '31', String? username}) =>
    MemberThreadCubit(repository: MyThreadRepository(), uid: uid, username: username, session: () => _session);

/// Wait until [cubit] has no list loading.
Future<MemberThreadState> _settled(MemberThreadCubit cubit) async {
  bool busy(MemberThreadState s) => MemberThreadTab.values.any((t) {
    final l = s.of(t);
    return l.status == MemberThreadStatus.initial ||
        l.status == MemberThreadStatus.loading ||
        l.refreshing ||
        l.loadingMore;
  });
  if (!busy(cubit.state)) {
    return cubit.state;
  }
  return cubit.stream.firstWhere((s) => !busy(s));
}

Future<MemberThreadState> _loadBoth(MemberThreadCubit cubit) async {
  for (final tab in MemberThreadTab.values) {
    unawaited(cubit.load(tab));
  }
  return _settled(cubit);
}

/// A row of a member's list on the web page (`space_thread`), the reply list's thread row followed by its reply.
String _webRow(int tid, {String? reply}) =>
    '''
<tr${reply == null ? '' : ' class="bw0_all"'}>
<td class="icn"><a href="forum.php?mod=viewthread&amp;tid=$tid" target="_blank"></a></td>
<th><a href="forum.php?mod=viewthread&amp;tid=$tid" target="_blank">Synthetic thread $tid</a></th>
<td><a href="forum.php?mod=forumdisplay&amp;fid=4" target="_blank" class="xg1">Test forum</a></td>
<td class="num"><a href="forum.php?mod=viewthread&amp;tid=$tid" class="xi2">3</a><em>45</em></td>
<td class="by"><cite><a href="home.php?mod=space&amp;username=Bob">Bob</a></cite>
<em><a href="forum.php?mod=redirect&amp;tid=$tid&amp;goto=lastpost#lastpost"><span title="2026-10-1 12:00">13 天前</span></a></em></td>
</tr>${reply == null ? '' : '''
<tr><td colspan="5" class="xg1"><a href="forum.php?mod=redirect&amp;goto=findpost&amp;ptid=$tid&amp;pid=${tid}0" target="_blank">$reply</a></td></tr>'''}''';

/// The web page of member 1103's list [type] (no `from=space`: the layout the app asks).
String _webPage(String type) =>
    '''
<html><head><script>var discuz_uid = '1000';</script></head><body><div id="wp" class="wp"><div id="ct" class="ct2_a wp cl"><div class="mn pbw">
<div class="tl"><form method="post" autocomplete="off" name="delform" id="delform" action="home.php?mod=space&amp;do=thread&amp;view=all&amp;order=dateline"><table cellspacing="0" cellpadding="0">
<tr class="th"><td class="icn">&nbsp;</td><th>主题</th><td class="frm">版块</td><td class="num">回复</td><td class="by"><cite>最后发表</cite></td></tr>
${type == 'thread' ? _webRow(123) + _webRow(124) : _webRow(125, reply: 'Synthetic reply')}
</table></form></div>
<div class="pgs cl mtm"><div class="pg"><strong>1</strong><a href="home.php?mod=space&amp;uid=1103&amp;do=thread&amp;view=me&amp;type=$type&amp;page=2" class="nxt">下一页</a></div></div>
</div></div></div></body></html>''';

String _bodyOf(String html) => RegExp('<body>(.*)</body>', dotAll: true).firstMatch(html)?.group(1) ?? html;

/// The account in use for the page: [currentUser], its status events sent by the tests.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  int? get effectiveCurrentUid => currentUser?.uid;

  void switchTo(UserLoginInfo user) {
    currentUser = user;
    _controller.add(AuthStatusAuthed(user));
  }

  Future<void> close() => _controller.close();
}

/// Let futures finish outside the fake zone, then build the frames they caused.
Future<void> _pumpSettled(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Translations get _tr => LocaleSettings.instance.currentTranslations;

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(() {
    TsdmAppApi.reset();
    _session = (uid: 35, generation: 1);
  });

  group("1. the route of a member's list", () {
    test('another member by uid: their page, the threads first; `type=reply` the replies first', () {
      for (final url in [
        'home.php?mod=space&uid=1103&do=thread&view=me',
        'home.php?mod=space&uid=1103&do=thread&view=me&from=space',
        'home.php?mod=space&uid=1103&do=thread&type=thread&view=me',
        '$baseUrl/home.php?mod=space&amp;uid=1103&amp;do=thread&amp;type=thread&amp;view=me'.unescapeHtml()!,
      ]) {
        final route = url.parseUrlToRoute()!;
        expect(route.screenPath, ScreenPaths.memberThread, reason: url);
        expect(route.queryParameters, {'uid': '1103'}, reason: url);
      }
      // The "帖子" link of a floor's profile card.
      final reply = 'https://www.tsdm39.com/home.php?mod=space&uid=1101&do=thread&type=reply&view=me&from=space'
          .parseUrlToRoute()!;
      expect(reply.screenPath, ScreenPaths.memberThread);
      expect(reply.queryParameters, {'uid': '1101', 'tab': 'reply'});
    });

    test('by name only, or by name and uid: the name is passed on, the forum takes it (also digits only)', () {
      final byName = 'home.php?mod=space&username=fixture&do=thread&view=me&type=reply'.parseUrlToRoute()!;
      expect(byName.screenPath, ScreenPaths.memberThread);
      expect(byName.queryParameters, {'username': 'fixture', 'tab': 'reply'});
      final both = 'home.php?mod=space&uid=1103&username=fixture&do=thread&view=me'.parseUrlToRoute()!;
      expect(both.queryParameters, {'uid': '1103', 'username': 'fixture'});
      final digits = 'home.php?mod=space&username=12345&do=thread&view=me'.parseUrlToRoute()!;
      expect(digits.queryParameters, {'username': '12345'});

      // The forum locates the member by `username` first; the app asks as the link said.
      expect(
        memberThreadUrl(MemberThreadTab.reply, username: '名字 a&b'),
        '$baseUrl/home.php?mod=space&username=%E5%90%8D%E5%AD%97+a%26b&do=thread&view=me&type=reply',
      );
      expect(
        memberThreadUrl(MemberThreadTab.thread, uid: '31'),
        '$baseUrl/home.php?mod=space&uid=31&do=thread&view=me&type=thread',
      );
    });

    test('the own list: by uid or by name, the "my threads" page; nobody named: as before; comments: the web', () {
      // The route's redirect.
      expect(memberThreadRedirect({'uid': '35'}, currentUid: 35, currentUsername: 'me'), ScreenPaths.myThread);
      expect(memberThreadRedirect({'uid': '35', 'tab': 'reply'}, currentUid: 35), ScreenPaths.myThread);
      expect(memberThreadRedirect({'username': 'me'}, currentUid: 35, currentUsername: 'me'), ScreenPaths.myThread);
      expect(memberThreadRedirect({'uid': '31'}, currentUid: 35, currentUsername: 'me'), isNull);
      expect(memberThreadRedirect({'username': 'other'}, currentUid: 35, currentUsername: 'me'), isNull);
      // The forum takes the name over the uid.
      expect(memberThreadRedirect({'uid': '35', 'username': 'other'}, currentUid: 35, currentUsername: 'me'), isNull);
      // A guest has no own list.
      expect(memberThreadRedirect({'uid': '35'}), isNull);
      expect(memberThreadRedirect({'username': 'me'}), isNull);

      expect('home.php?mod=space&do=thread&view=me'.parseUrlToRoute()!.screenPath, ScreenPaths.myThread);
      expect(myThreadReplyUrl.parseUrlToRoute()!.screenPath, ScreenPaths.myThread);
      expect('home.php?mod=space&uid=0&do=thread&view=me'.parseUrlToRoute()!.screenPath, ScreenPaths.myThread);
      expect('home.php?mod=space&uid=1103&do=thread&view=me&type=postcomment'.parseUrlToRoute(), isNull);
    });
  });

  group('2. the lists from the fields (schema 9)', () {
    test(
      'both tabs of uid 31 asked lean by uid, the rows as on "my threads", the member as the forum named them',
      () async {
        final forum = _Forum(_member31);
        _use(forum);
        final cubit = _cubit();
        final state = await _loadBoth(cubit);

        expect(state.ownerUid, 31);
        expect(state.ownerName, 'ag_low');
        expect(state.viewerUid, 35);
        expect(state.thread.status, MemberThreadStatus.success);
        expect(state.thread.items, hasLength(20));
        expect(state.thread.items.first.threadID, '9199941', reason: 'a moved thread is the row of its target');
        expect(state.thread.items.first.stateSet, contains(ThreadStateModel.closed));
        expect(state.thread.nextPageUrl, '${memberThreadUrl(MemberThreadTab.thread, uid: '31')}&page=2');
        expect(state.reply.status, MemberThreadStatus.success);
        expect(state.reply.items, hasLength(16));
        expect(state.reply.items.first.quotedMessage, 'TM M7 954975');
        expect(state.reply.items.first.url, '$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=9199341&pid=3925');
        expect(forum.requests, hasLength(2));
        expect(forum.requests.every(_asksLean), isTrue);
        expect(forum.requests.map((e) => e.uri.queryParameters['uid']), everyElement('31'));
        expect(forum.requests.map((e) => e.uri.queryParameters['type']).toSet(), {'thread', 'reply'});

        // The next page, then no more.
        unawaited(cubit.loadMore(MemberThreadTab.thread));
        final more = await _settled(cubit);
        expect(more.thread.items, hasLength(23));
        expect(more.thread.pageNumber, 2);
        expect(more.thread.nextPageUrl, isNull);
        expect(forum.requests.last.uri.queryParameters, containsPair('page', '2'));
        expect(forum.requests.last.uri.queryParameters, containsPair('uid', '31'));
        expect(_asksLean(forum.requests.last), isTrue);
        await cubit.loadMore(MemberThreadTab.thread);
        expect(forum.requests, hasLength(3), reason: 'no next page');

        // A pull to refresh: the first page again, the rows shown meanwhile.
        final refreshing = cubit.stream.firstWhere((s) => s.thread.refreshing);
        unawaited(cubit.load(MemberThreadTab.thread));
        expect((await refreshing).thread.items, hasLength(23));
        final refreshed = await _settled(cubit);
        expect(refreshed.thread.items, hasLength(20));
        expect(refreshed.thread.pageNumber, 1);
        await cubit.close();
      },
    );

    test('by name only: asked by name, the uid learnt from the answer', () async {
      final forum = _Forum(_member31);
      _use(forum);
      final cubit = _cubit(uid: null, username: 'ag_low');
      expect(cubit.state.ownerUid, isNull);
      final state = await _loadBoth(cubit);
      await cubit.close();
      expect(state.ownerUid, 31);
      expect(forum.requests.map((e) => e.uri.queryParameters['username']), everyElement('ag_low'));
      expect(forum.requests.every((e) => !e.uri.queryParameters.containsKey('uid')), isTrue);
    });

    test("the forum's message: a guest is asked to log in; a refusal is shown as the forum said it", () async {
      _use(_Forum((_) => _api(_raw('mythread_v9_guest.json'))));
      var cubit = _cubit();
      var state = await _loadBoth(cubit);
      await cubit.close();
      expect(state.thread.status, MemberThreadStatus.needLogin);
      expect(state.reply.status, MemberThreadStatus.needLogin);

      _use(_Forum((_) => _api({'ok': 0, 'error': 'message', 'message': '指定的空间不存在', 'login': 0, 'uid': 35})));
      cubit = _cubit(uid: '99999');
      state = await _loadBoth(cubit);
      await cubit.close();
      expect(state.thread.status, MemberThreadStatus.notice);
      expect(state.thread.message, '指定的空间不存在');

      // A failed request (an answer without a page): retry.
      _use(_Forum((_) => _api({'ok': 0, 'error': 'internal'})));
      cubit = _cubit();
      state = await _loadBoth(cubit);
      await cubit.close();
      expect(state.thread.status, MemberThreadStatus.failed);
    });
  });

  group('3. an older plugin, or none: the web page parsed as "my threads" parses it', () {
    test('the web page and the 1.6.0 answer carrying it: the rows, the replies, the next page link', () async {
      for (final (label, wrap) in [
        ('the web page', _html),
        ('plugin 1.6.0', (String html) => _api({'ok': 1, 'api': 1, 'type': 'mythread', 'document': _bodyOf(html)})),
      ]) {
        final forum = _Forum((o) => wrap(_webPage(o.uri.queryParameters['type']!)));
        _use(forum);
        final cubit = _cubit(uid: '1103');
        final state = await _loadBoth(cubit);
        await cubit.close();
        expect(state.thread.items.map((e) => e.threadID), ['123', '124'], reason: label);
        expect(state.reply.items.single.quotedMessage, 'Synthetic reply', reason: label);
        expect(state.reply.items.single.url, contains('pid=1250'), reason: label);
        expect(
          state.thread.nextPageUrl,
          '$baseUrl/home.php?mod=space&uid=1103&do=thread&view=me&type=thread&page=2',
          reason: label,
        );
        expect(state.ownerUid, 1103, reason: '$label: the route named it');
        expect(state.ownerName, isNull, reason: '$label: the page does not name the member');
      }
    });

    test('the login prompt of the web page asks to log in', () async {
      _use(
        _Forum(
          (_) => _html(
            '<html><body><div id="wp"><div id="messagelogin"></div> '
            '<div id="messagetext" class="alert_info"><p>请先登录后才能继续浏览</p></div></div></body></html>',
          ),
        ),
      );
      final cubit = _cubit();
      final state = await _loadBoth(cubit);
      await cubit.close();
      expect(state.thread.status, MemberThreadStatus.needLogin);
    });
  });

  group('4. the account fence', () {
    test('an answer that comes back after the account changed is dropped, the list asked again', () async {
      final forum = _Forum(_member31)..gate = Completer<void>();
      _use(forum);
      final cubit = _cubit();
      unawaited(cubit.load(MemberThreadTab.thread));
      await pumpEventQueue();
      expect(forum.requests, hasLength(1));
      // Another account comes into use while the answer is on its way (its answer served to uid 35).
      _session = (uid: 36, generation: 2);
      forum.gate!.complete();
      await pumpEventQueue();
      expect(forum.requests, hasLength(2), reason: 'asked again');
      final state = await cubit.stream.firstWhere((s) => s.thread.status != MemberThreadStatus.loading);
      await cubit.close();
      // The second answer is still the fixture served to uid 35: not taken as the list of uid 36.
      expect(state.thread.status, MemberThreadStatus.failed);
      expect(state.thread.items, isEmpty);
    });

    test('another session of the same account: asked again, then taken', () async {
      final forum = _Forum(_member31)..gate = Completer<void>();
      _use(forum);
      final cubit = _cubit();
      unawaited(cubit.load(MemberThreadTab.reply));
      await pumpEventQueue();
      _session = (uid: 35, generation: 2);
      forum.gate!.complete();
      final state = await _settledTab(cubit, MemberThreadTab.reply);
      await cubit.close();
      expect(forum.requests, hasLength(2));
      expect(state.reply.status, MemberThreadStatus.success);
      expect(state.reply.items, hasLength(16));
    });

    test('a next page answered after the account changed starts over from the first page', () async {
      final forum = _Forum(_member31);
      _use(forum);
      final cubit = _cubit();
      await _loadBoth(cubit);
      forum.gate = Completer<void>();
      unawaited(cubit.loadMore(MemberThreadTab.thread));
      await pumpEventQueue();
      _session = (uid: 35, generation: 3);
      forum.gate!.complete();
      await pumpEventQueue();
      final state = await _settledTab(cubit, MemberThreadTab.thread);
      await cubit.close();
      expect(forum.requests.map((e) => e.uri.queryParameters['page']), [null, null, '2', null]);
      expect(state.thread.items, hasLength(20), reason: 'the first page, not 20 + 3');
      expect(state.thread.pageNumber, 1);
    });

    test('a page served to another account than the one asking is a failure', () async {
      _use(_Forum(_member31));
      _session = (uid: 36, generation: 1);
      final cubit = _cubit();
      final state = await _loadBoth(cubit);
      await cubit.close();
      expect(state.thread.status, MemberThreadStatus.failed);
      expect(state.reply.status, MemberThreadStatus.failed);
    });
  });

  group('5. the page', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;
    late UserBlockRepository blocks;
    late _Auth auth;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings);
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      blocks = UserBlockRepository(storage);
      auth = _Auth(const UserLoginInfo(username: 'viewer', uid: 35));
    });
    tearDown(() async {
      await settingsBloc.close();
      await blocks.dispose();
      await auth.close();
      await settings.dispose();
      await db.close();
    });

    Future<MemberThreadCubit> pump(WidgetTester tester, {MemberThreadTab tab = MemberThreadTab.thread}) async {
      final cubit = _cubit();
      final block = UserBlockCubit(
        repository: blocks,
        currentUid: () => auth.currentUser?.uid,
        authStatus: auth.status,
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => MemberThreadPage(uid: '31', initialTab: tab, cubit: cubit),
          ),
        ],
      );
      addTearDown(() async {
        router.dispose();
        await block.close();
        await cubit.close();
      });
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<UserBlockCubit>.value(value: block),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          ),
        ),
      );
      await _pumpSettled(tester);
      return cubit;
    }

    testWidgets('the title names the member, the rows look as on "my threads", the replies tab first', (tester) async {
      _use(_Forum(_member31));
      await pump(tester, tab: MemberThreadTab.reply);
      expect(find.text(_tr.memberThreadPage.title(name: 'ag_low')), findsOneWidget);
      expect(find.text(_tr.myThreadPage.threadTab.title), findsOneWidget);
      expect(find.text(_tr.myThreadPage.replyTab.title), findsOneWidget);
      expect(find.byType(MyThreadCard), findsWidgets);
      expect(find.text('TM M7 954975'), findsWidgets, reason: 'the reply tab is shown');
    });

    testWidgets('a member blocked on this device: their lists hidden', (tester) async {
      _use(_Forum(_member31));
      await tester.runAsync(() => blocks.block(ownerUid: 35, uid: 31, username: 'ag_low'));
      await pump(tester);
      expect(find.text(_tr.memberThreadPage.blocked), findsOneWidget);
      expect(find.byType(MyThreadCard), findsNothing);
    });

    testWidgets('another account coming into use reloads both lists', (tester) async {
      final forum = _Forum(_member31);
      _use(forum);
      final cubit = await pump(tester);
      expect(forum.requests, hasLength(2));
      expect(cubit.state.viewerUid, 35);
      // The status of the account the lists were asked as (the one replayed to a new listener): nothing asked again.
      auth.switchTo(const UserLoginInfo(username: 'viewer', uid: 35));
      await _pumpSettled(tester);
      expect(forum.requests, hasLength(2));
      _session = (uid: 36, generation: 2);
      auth.switchTo(const UserLoginInfo(username: 'other', uid: 36));
      await _pumpSettled(tester);
      expect(forum.requests, hasLength(4));
      // The fixture is served to uid 35: the lists of uid 36 are not taken from it.
      expect(cubit.state.thread.status, MemberThreadStatus.failed);
    });
  });
}

Future<MemberThreadState> _settledTab(MemberThreadCubit cubit, MemberThreadTab tab) async {
  bool done(MemberThreadState s) =>
      s.of(tab).status != MemberThreadStatus.loading && !s.of(tab).refreshing && !s.of(tab).loadingMore;
  return done(cubit.state) ? cubit.state : cubit.stream.firstWhere(done);
}
