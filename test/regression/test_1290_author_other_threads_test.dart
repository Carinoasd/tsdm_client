/// "作者的其他主题": the floor's menu opens the author's list ("TA的主题", the member's page), and the member's page
/// offers to limit both lists to the forum of the thread it was opened from ("本版／全部").
///
/// The forum limits another member's lists with `fid` (`source/app/home/child/space/thread.php`: `$vfid`, passed to
/// both the thread and the reply query; its pagination keeps `fid`). Measured on the test forum on 2026-11-17 as uid
/// 35 for uid 31: `type=thread&fid=2` answers 19 threads all in forum 2 (`fid: 2` at the top of the structured
/// answer), `fid=11` 20 all in forum 11, `type=reply&fid=11` one row in forum 11, and the web page's next page link is
/// `…&fid=11&view=me&type=thread&order=dateline&page=2`.
///
/// Fixtures: `test/data/author_threads/floors_api.json` is the test forum's answer to thread 9199196 asked as uid 35
/// (`tsdmapp=json&nodoc=1`), cut to three floors: pid 3406 by uid 31, pid 3408 anonymous, pid 3409 by uid 35 (the
/// viewer); `floors_web.html` the same three floors of the web page. The site's name and address replaced, the
/// `formhash` and `time` set to the fake values of the other fixtures.
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
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart' show AuthStatus;
import 'package:tsdm_client/features/member_thread/cubit/member_thread_cubit.dart';
import 'package:tsdm_client/features/member_thread/utils/member_thread_url.dart';
import 'package:tsdm_client/features/member_thread/view/member_thread_page.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:universal_html/parsing.dart';

String _read(String path) => File(path).readAsStringSync();

/// The floors of the thread, by pid: from the structured answer, or from the web page as the thread page reads each
/// `div#post_PID`.
Map<String, Post> _floors({required bool web}) {
  if (!web) {
    final json = jsonDecode(_read('test/data/author_threads/floors_api.json')) as Map<String, dynamic>;
    return {for (final p in threadPageFromApi(json, 1).postList) p.postID: p};
  }
  final floors = <String, Post>{};
  final document = parseHtmlDocument(_read('test/data/author_threads/floors_web.html'));
  for (final e in document.querySelectorAll('div[id^="post_"]')) {
    final post = RegExp(r'^post_\d+$').hasMatch(e.id) ? Post.fromPostNode(e, 1) : null;
    if (post != null) {
      floors[post.postID] = post;
    }
  }
  return floors;
}

/// The card shows nothing that needs these.
Post _bare(Post post) => post.copyWith(
  author: User(name: post.author.name, uid: post.author.uid, url: post.author.url),
  userBriefProfile: null,
  postMedals: null,
  badge: null,
  secondBadge: null,
  signature: null,
  pokemon: null,
  checkin: null,
);

/// The account in use: [uid] and [name].
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.uid, {this.name});

  final int? uid;
  final String? name;

  @override
  int? get effectiveCurrentUid => uid;

  @override
  UserLoginInfo? get effectiveCurrentUser => uid == null ? null : UserLoginInfo(username: name, uid: uid);

  @override
  UserLoginInfo? get currentUser => effectiveCurrentUser;

  @override
  AuthStatus? get latestStatus => null;

  @override
  Stream<AuthStatus> get status => const Stream.empty();
}

/// The thread page above the floors: a thread of forum `fid`.
final class _ThreadBloc extends ThreadBloc {
  _ThreadBloc(int? fid)
    : _state = ThreadState(tid: '9199196', fid: fid, forumName: 'Forum $fid', status: ThreadStatus.success),
      super(
        tid: '9199196',
        pid: null,
        onlyVisibleUid: null,
        reverseOrder: null,
        exactOrder: null,
        threadRepository: ThreadRepository(),
      );

  final ThreadState _state;

  @override
  ThreadState get state => _state;
}

/// No network.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The fake forum of the member's lists: every request recorded, answered with the test forum's list of uid 31 as
/// uid 35 sees it; [gate] holds the answers back until completed.
final class _Forum implements HttpClientAdapter {
  final requests = <Uri>[];
  Completer<void>? gate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final gate = this.gate;
    if (gate != null) {
      await gate.future;
    }
    final reply = options.uri.queryParameters['type'] == 'reply';
    final json =
        jsonDecode(_read('test/data/tsdmapp/${reply ? 'mythread_v9_other_reply.json' : 'mythread_v9_other.json'}'))
            as Map<String, dynamic>;
    return ResponseBody.fromString(
      jsonEncode(json),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void _use(_Forum forum) => getIt.registerFactory<NetClientProvider>(
  () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
);

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

/// Let futures finish outside the fake zone, then build the frames they caused.
Future<void> _pumpSettled(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

MemberThreadCubit _cubit({int? fid}) => MemberThreadCubit(
  repository: MyThreadRepository(),
  uid: '31',
  fid: fid,
  session: () => (uid: 35, generation: 1),
);

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
  setUp(TsdmAppApi.reset);

  group('1. the link of the lists', () {
    test('the forum filter is the `fid` of the page, left out without a forum', () {
      expect(
        memberThreadUrl(MemberThreadTab.thread, uid: '31', fid: 11),
        '$baseUrl/home.php?mod=space&uid=31&do=thread&view=me&type=thread&fid=11',
      );
      expect(
        memberThreadUrl(MemberThreadTab.reply, uid: '31', fid: 11),
        '$baseUrl/home.php?mod=space&uid=31&do=thread&view=me&type=reply&fid=11',
      );
      for (final fid in [null, 0, -1]) {
        expect(
          memberThreadUrl(MemberThreadTab.thread, uid: '31', fid: fid),
          '$baseUrl/home.php?mod=space&uid=31&do=thread&view=me&type=thread',
        );
      }
      // The next page keeps the forum.
      expect(
        Uri.parse(tsdmAppListPageUrl(memberThreadUrl(MemberThreadTab.thread, uid: '31', fid: 11), 2)).queryParameters,
        containsPair('fid', '11'),
      );
    });

    test('the query of the route: the uid, else the name; the tab; the forum above 0', () {
      expect(memberThreadQuery(uid: 31, username: 'ag_low', fid: 11), {'uid': '31', 'fid': '11'});
      expect(memberThreadQuery(username: 'ag_low', tab: 'reply'), {'username': 'ag_low', 'tab': 'reply'});
      expect(memberThreadQuery(uid: 0, username: 'ag_low', fid: 0), {'username': 'ag_low'});
    });

    test('the account in use: by the uid, by the name as the forum compares names without one', () {
      expect(isAccountMember(uid: 35, username: 'x', accountUid: 35, accountName: 'ag_low2'), isTrue);
      expect(isAccountMember(uid: 31, username: 'ag_low2', accountUid: 35, accountName: 'ag_low2'), isFalse);
      expect(isAccountMember(uid: null, username: 'ＡＧ_low2 ', accountUid: 35, accountName: 'ag_low2'), isTrue);
      expect(isAccountMember(uid: null, username: 'ag_low', accountUid: 35, accountName: 'ag_low2'), isFalse);
      expect(isAccountMember(uid: null, username: '', accountUid: 35, accountName: 'ag_low2'), isFalse);
      expect(isAccountMember(uid: 31, username: 'ag_low', accountUid: null, accountName: null), isFalse);
    });
  });

  group('2. the lists limited to the forum', () {
    late _Forum forum;

    setUp(() {
      forum = _Forum();
      _use(forum);
    });

    test('all of it first; this forum asks both lists again with `fid`, all of it again without', () async {
      final cubit = _cubit(fid: 11);
      addTearDown(cubit.close);
      for (final tab in MemberThreadTab.values) {
        unawaited(cubit.load(tab));
      }
      await _settled(cubit);
      expect(cubit.state.forumOnly, isFalse);
      expect(forum.requests.map((e) => e.queryParameters['fid']), [null, null]);

      forum.requests.clear();
      final switching = cubit.setForumOnly(forumOnly: true);
      // The rows of all of it go at once.
      expect(cubit.state.thread.items, isEmpty);
      expect(cubit.state.forumOnly, isTrue);
      await switching;
      expect(forum.requests, hasLength(2));
      expect(forum.requests.map((e) => e.queryParameters['type']).toSet(), {'thread', 'reply'});
      expect(forum.requests.map((e) => e.queryParameters['fid']), ['11', '11']);
      expect(cubit.state.thread.status, MemberThreadStatus.success);
      expect(cubit.state.thread.nextPageUrl, contains('fid=11'));

      forum.requests.clear();
      await cubit.loadMore(MemberThreadTab.thread);
      expect(forum.requests.single.queryParameters, containsPair('fid', '11'));
      expect(forum.requests.single.queryParameters, containsPair('page', '2'));

      forum.requests.clear();
      await cubit.reloadAll();
      expect(cubit.state.forumOnly, isTrue, reason: 'another account keeps the choice');
      expect(forum.requests.map((e) => e.queryParameters['fid']), ['11', '11']);

      forum.requests.clear();
      await cubit.setForumOnly(forumOnly: false);
      expect(forum.requests.map((e) => e.queryParameters['fid']), [null, null]);
      // The same choice again asks nothing.
      forum.requests.clear();
      await cubit.setForumOnly(forumOnly: false);
      expect(forum.requests, isEmpty);
    });

    test('an answer of all of it still on its way after switching is dropped', () async {
      final cubit = _cubit(fid: 11);
      addTearDown(cubit.close);
      final gate = forum.gate = Completer<void>();
      for (final tab in MemberThreadTab.values) {
        unawaited(cubit.load(tab));
      }
      await Future<void>.delayed(Duration.zero);
      final switching = cubit.setForumOnly(forumOnly: true);
      gate.complete();
      await switching;
      await _settled(cubit);
      expect(forum.requests.map((e) => e.queryParameters['fid']), [null, null, '11', '11']);
      expect(cubit.state.forumOnly, isTrue);
      expect(cubit.state.thread.status, MemberThreadStatus.success);
      expect(cubit.state.thread.nextPageUrl, contains('fid=11'), reason: 'the rows are those asked with the forum');
    });

    test('nothing to limit to without a forum', () async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await cubit.setForumOnly(forumOnly: true);
      expect(cubit.state.forumOnly, isFalse);
      expect(forum.requests, isEmpty);
    });
  });

  group('3. on screen', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
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

    /// [child] on the first page of a router, the routes of the member's list recorded in [opened].
    Future<void> pump(
      WidgetTester tester,
      Widget child, {
      required _Auth auth,
      List<Map<String, String>>? opened,
    }) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(body: SingleChildScrollView(child: child)),
          ),
          GoRoute(
            path: ScreenPaths.memberThread,
            name: ScreenPaths.memberThread,
            builder: (_, state) {
              opened?.add(state.uri.queryParameters);
              return const SizedBox();
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        RepositoryProvider<AuthenticationRepository>.value(
          value: auth,
          child: BlocProvider<SettingsBloc>.value(
            value: settingsBloc,
            child: TranslationProvider(child: MaterialApp.router(routerConfig: router)),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byWidgetPredicate((w) => w is PopupMenuButton));
      await tester.pumpAndSettle();
    }

    final label = find.text('作者的其他主题');

    for (final web in [false, true]) {
      final source = web ? 'the web page' : 'the structured answer';

      testWidgets("another member's floor of $source: the menu opens their list with the thread's forum", (
        tester,
      ) async {
        final opened = <Map<String, String>>[];
        final bloc = _ThreadBloc(12);
        addTearDown(bloc.close);
        await pump(
          tester,
          BlocProvider<ThreadBloc>.value(
            value: bloc,
            child: PostCard(_bare(_floors(web: web)['3406']!)),
          ),
          auth: _Auth(35, name: 'ag_low2'),
          opened: opened,
        );
        await openMenu(tester);
        expect(label, findsOneWidget);
        // Next to the author filter of the floor.
        final items = tester.widgetList<PopupMenuItem<Object?>>(find.byWidgetPredicate((w) => w is PopupMenuItem));
        final names = [for (final item in items) item.value?.toString()];
        expect(
          names.indexWhere((e) => e?.endsWith('authorThreads') ?? false),
          names.indexOf(
                names.firstWhere(
                  (e) => e?.endsWith('viewTheAuthor') ?? false,
                ),
              ) +
              1,
        );
        await tester.tap(label);
        await tester.pumpAndSettle();
        expect(opened, [
          {'uid': '31', 'fid': '12'},
        ]);
      });

      testWidgets('the anonymous floor and the own floor of $source: not in the menu', (tester) async {
        final floors = _floors(web: web);
        // The web page names the anonymous floor without a link (`div.authi` reads "匿名"): no uid, or no floor at all
        // where the page's parser leaves it out.
        expect(floors['3408']?.author.uid, isNull, reason: 'the anonymous floor names no uid');
        expect(floors['3409']?.author.uid, '35');
        for (final pid in ['3408', '3409']) {
          final floor = floors[pid];
          if (floor == null) {
            continue;
          }
          await pump(tester, PostCard(_bare(floor)), auth: _Auth(35, name: 'ag_low2'));
          await openMenu(tester);
          expect(label, findsNothing, reason: 'pid $pid');
          await tester.pumpWidget(const SizedBox());
        }
      });
    }

    testWidgets('outside a thread page (a notice): the list of all of it, no forum', (tester) async {
      final opened = <Map<String, String>>[];
      await pump(tester, PostCard(_bare(_floors(web: false)['3406']!)), auth: _Auth(35), opened: opened);
      await openMenu(tester);
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(opened, [
        {'uid': '31'},
      ]);
    });

    testWidgets('a guest: offered as well', (tester) async {
      await pump(tester, PostCard(_bare(_floors(web: true)['3409']!)), auth: _Auth(null));
      await openMenu(tester);
      expect(label, findsOneWidget);
    });

    testWidgets('the page: "this forum / all" only when opened with a forum; this forum asks with `fid`', (
      tester,
    ) async {
      final forum = _Forum();
      _use(forum);
      for (final fid in [null, 11]) {
        forum.requests.clear();
        final cubit = _cubit(fid: fid);
        addTearDown(cubit.close);
        await pump(
          tester,
          SizedBox(
            height: 600,
            child: MemberThreadPage(uid: '31', fid: fid, cubit: cubit),
          ),
          auth: _Auth(35),
        );
        await _pumpSettled(tester);
        final scope = find.byKey(const ValueKey('member-thread-scope'));
        if (fid == null) {
          expect(scope, findsNothing);
          await tester.pumpWidget(const SizedBox());
          continue;
        }
        expect(scope, findsOneWidget);
        expect(forum.requests.map((e) => e.queryParameters['fid']), [null, null]);
        forum.requests.clear();
        await tester.tap(find.descendant(of: scope, matching: find.text('本版')));
        await _pumpSettled(tester);
        expect(cubit.state.forumOnly, isTrue);
        expect(forum.requests.map((e) => e.queryParameters['fid']), ['11', '11']);
        await tester.pumpWidget(const SizedBox());
      }
    });
  });
}
