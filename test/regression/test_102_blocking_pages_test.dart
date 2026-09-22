import 'dart:async';
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
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/blocking/widgets/block_aware_post.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/widgets/widgets.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/notice_card_v2.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';

/// The local block on the real cards and pages the other widget tests do not open: the forum and search result rows,
/// the homepage pinned rows, the menu of one notice (and what its entries start), and the thread page (its visit
/// history, quotes of blocked posts, and a block list that can not be read).
///
/// All pages are synthetic (grounded in the Discuz templates), no real account or network.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

/// Blocked by Alice in these tests.
const _bob = 1001;

/// Not blocked.
const _carol = 1002;

const _tid = '1264975';

/// Authentication with a fixed current account.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  int? get effectiveCurrentUid => currentUser?.uid;

  Future<void> close() => _controller.close();
}

/// Notification bloc holding a fixed state; the cards only send it events.
final class _Notifications extends Fake implements NotificationBloc {
  final events = <NotificationEvent>[];

  @override
  void add(NotificationEvent event) => events.add(event);

  @override
  NotificationState get state => const NotificationState(status: NotificationStatus.success);

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// Storage whose block list rows can not be read while [failing] is set.
final class _FlakyStorage extends StorageProvider {
  _FlakyStorage(AppDatabase db) : super(db, {}, {});

  bool failing = true;

  @override
  Future<List<String>?> getStringList(String key) async {
    if (failing && key.startsWith(UserBlockRepository.keyPrefix)) {
      throw StateError('database is locked');
    }
    return super.getStringList(key);
  }
}

/// Never answers: images are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// One floor of a thread page, the author in the post header like the real page; [body] is the post text.
String _floor({required int pid, required int floor, required int uid, required String name, String? body}) =>
    '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=$uid" class="xi2">$name</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">${body ?? 'floor $floor text'}</div></div></div></td>
</tr></tbody></table></div>''';

/// A quote as Discuz renders it: the quoted post is only named by the pid of its `findpost` link.
String _quote(int pid, String name, String text) =>
    '<div class="quote"><blockquote><font size="2"><a href="forum.php?mod=redirect&amp;goto=findpost&amp;pid=$pid'
    '&amp;ptid=$_tid" target="_blank"><font color="#999999">$name 发表于 2026-9-5 17:38</font></a></font><br />'
    '$text</blockquote></div>';

/// A thread page of board 8 ("Board"), with the breadcrumb and the search form field a visit is recorded from.
String _threadPage(List<String> floors) =>
    '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=$_tid" /></head><body>
<div id="pt" class="bm cl"><div class="z"><a href="./" class="nvhm">Home</a><em>›</em><a href="forum.php">Forum</a>
<em>›</em><a href="forum.php?gid=1">Group</a><em>›</em><a href="forum.php?mod=forumdisplay&fid=8">Board</a>
<em>›</em><a href="forum.php?mod=viewthread&tid=$_tid">Secret title</a></div></div>
<form id="scbar_form"><input type="hidden" name="srhfid" value="8" /></form>
<div id="postlist"><h1 class="ts"><span id="thread_subject">Secret title</span></h1><div class="bm">
${floors.join('\n')}
</div></div>
</body></html>''';

/// Thread pages by page number; a page in [gates] is answered only once its completer completes.
final class _ThreadAdapter implements HttpClientAdapter {
  _ThreadAdapter(this.pages);

  final Map<String, String> pages;
  final gates = <String, Completer<void>>{};
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final page = options.uri.queryParameters['page'] ?? '1';
    final gate = gates[page];
    if (gate != null) {
      await gate.future;
    }
    return ResponseBody.fromString(
      pages[page] ?? '<html></html>',
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
  late SettingsBloc settingsBloc;
  late UserBlockRepository blocks;
  late _Auth auth;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
    getIt.registerSingleton<ImageCacheProvider>(
      ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
    );
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    blocks = UserBlockRepository(storage);
    auth = _Auth(_alice);
    ThreadAuthorCache.clear();
  });

  tearDown(() async {
    await settingsBloc.close();
    await blocks.dispose();
    await auth.close();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// Pump [child] under the providers of the app, with a block cubit reading [repository] (default: [blocks]) for
  /// Alice.
  Future<UserBlockCubit> pump(
    WidgetTester tester,
    Widget child, {
    UserBlockRepository? repository,
    List<BlocProvider> blocs = const [],
  }) async {
    final info = NotificationInfoRepository();
    final counts = NotificationStateCubit(info);
    addTearDown(() async {
      await info.dispose();
      await counts.close();
    });
    final cubit = UserBlockCubit(
      repository: repository ?? blocks,
      currentUid: () => auth.currentUser?.uid,
      authStatus: auth.status,
      // Reads are asked again by the retry buttons only: no timer outlives a test.
      retryDelays: const [],
    );
    addTearDown(cubit.close);
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => child)],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            // Provided app wide like in the app; the thread page menu asks it whether the thread is a favorite.
            RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>.value(value: settingsBloc),
              BlocProvider<UserBlockCubit>.value(value: cubit),
              BlocProvider<NotificationBloc>.value(value: _Notifications()),
              BlocProvider<NotificationStateCubit>.value(value: counts),
              ...blocs,
            ],
            child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
          ),
        ),
      ),
    );
    await settle(tester);
    return cubit;
  }

  Future<void> blockBob() => blocks.block(ownerUid: _alice.uid, uid: _bob, username: 'Bob');

  bool shows(String text) => find.textContaining(text, findRichText: true).evaluate().isNotEmpty;

  group('topic rows', () {
    User author(int uid, String name) => User(name: name, url: '$baseUrl/home.php?mod=space&uid=$uid', uid: '$uid');

    NormalThread forumRow(String tid, String title, User by) => NormalThread(
      title: title,
      url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
      threadID: tid,
      author: by,
      publishDate: DateTime(2026, 9),
      latestReplyAuthor: by,
      latestReplyTime: DateTime(2026, 9, 2, 8),
      iconUrl: '',
      threadType: null,
      replyCount: 3,
      viewCount: 30,
      price: null,
      privilege: null,
      css: null,
      stateSet: const {},
      isRecentThread: false,
    );

    SearchedThread searchRow(int tid, String title, User by) => SearchedThread(
      tid: tid,
      title: title,
      url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
      author: by,
      publishTime: DateTime(2026, 9),
      forumName: 'Board',
      forumUrl: '$baseUrl/forum.php?mod=forumdisplay&fid=8',
    );

    testWidgets('a forum row of a blocked author renders nothing, its neighbours stay', (tester) async {
      await tester.runAsync(blockBob);
      final cubit = await pump(
        tester,
        Scaffold(
          body: ListView(
            children: [
              NormalThreadCard(forumRow('11', 'Topic by Bob', author(_bob, 'Bob'))),
              NormalThreadCard(forumRow('12', 'Topic by Carol', author(_carol, 'Carol'))),
            ],
          ),
        ),
      );
      expect(shows('Topic by Bob'), isFalse);
      expect(shows('Topic by Carol'), isTrue);
      // The author of a hidden row is still learnt: opening the thread from elsewhere hides it as well.
      expect(ThreadAuthorCache.authorOf('11'), _bob);

      await tester.runAsync(() => cubit.unblock(_bob, expectedOwner: _alice.uid));
      await settle(tester);
      expect(shows('Topic by Bob'), isTrue);
    });

    testWidgets('a search result of a blocked author renders nothing, its neighbours stay', (tester) async {
      await tester.runAsync(blockBob);
      await pump(
        tester,
        Scaffold(
          body: ListView(
            children: [
              SearchedThreadCard(searchRow(21, 'Found from Bob', author(_bob, 'Bob'))),
              SearchedThreadCard(searchRow(22, 'Found from Carol', author(_carol, 'Carol'))),
            ],
          ),
        ),
      );
      expect(shows('Found from Bob'), isFalse);
      expect(shows('Found from Carol'), isTrue);
      expect(ThreadAuthorCache.authorOf('21'), _bob);
    });

    testWidgets('a pinned homepage row is left out by the uid of its author link, never by the name', (tester) async {
      await tester.runAsync(blockBob);
      PinnedThread row(int tid, String title, {required int uid, required String name}) => PinnedThread(
        threadUrl: 'forum.php?mod=viewthread&amp;tid=$tid',
        threadTitle: title,
        authorUrl: 'home.php?mod=space&uid=$uid',
        authorName: name,
      );
      await pump(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: PinSection([
              PinnedThreadGroup(
                title: 'Pinned',
                threadList: [
                  row(31, 'Pinned by Bob', uid: _bob, name: 'Bob'),
                  row(32, 'Pinned by Carol', uid: _carol, name: 'Carol'),
                  // Named like the blocked user, linked to somebody else: the name proves nothing.
                  row(33, 'Pinned by a namesake', uid: _carol, name: 'Bob'),
                ],
              ),
            ]),
          ),
        ),
      );
      expect(find.text('Pinned'), findsOneWidget);
      expect(shows('Pinned by Bob'), isFalse);
      expect(shows('Pinned by Carol'), isTrue);
      expect(shows('Pinned by a namesake'), isTrue);
      expect(ThreadAuthorCache.authorOf('31'), _bob);
    });
  });

  group('notice menu', () {
    NoticeV2 notice({String? type, int? author}) =>
        NoticeV2(id: 7, timestamp: 1788000000, data: 'a notice', ignoreType: type, authorId: author);

    Future<void> openMenu(WidgetTester tester, NoticeV2 data) async {
      await pump(tester, Scaffold(body: NoticeCardV2(data)));
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
    }

    PopupMenuItem<dynamic> itemOf(WidgetTester tester, String text) => tester.widget<PopupMenuItem<dynamic>>(
      find.ancestor(of: find.text(text), matching: find.byWidgetPredicate((w) => w is PopupMenuItem)),
    );

    testWidgets('a notice of a user offers the local block and the forum rule', (tester) async {
      await openMenu(tester, notice(type: 'post', author: _bob));
      expect(find.text(tr.userBlock.block), findsOneWidget);
      expect(find.text(tr.userBlock.serverRules.entry), findsOneWidget);
      expect(find.text(tr.userBlock.serverRules.notAvailable), findsNothing);
    });

    testWidgets('an old notice without its ignore link offers nothing but a disabled explanation', (tester) async {
      await openMenu(tester, notice());
      expect(find.text(tr.userBlock.serverRules.notAvailable), findsOneWidget);
      expect(itemOf(tester, tr.userBlock.serverRules.notAvailable).enabled, isFalse);
      expect(find.text(tr.userBlock.block), findsNothing);
      expect(find.text(tr.userBlock.serverRules.entry), findsNothing);
    });

    for (final (name, data) in [
      ('only a type', notice(type: 'post')),
      ('only an author', notice(author: _bob)),
    ]) {
      testWidgets('a notice with $name is treated as one without the ignore link', (tester) async {
        await openMenu(tester, data);
        expect(find.text(tr.userBlock.serverRules.notAvailable), findsOneWidget);
        expect(find.text(tr.userBlock.block), findsNothing);
        expect(find.text(tr.userBlock.serverRules.entry), findsNothing);
      });
    }

    testWidgets('a system notice and a notice of the account itself offer the forum rule only', (tester) async {
      await openMenu(tester, notice(type: 'system', author: 0));
      expect(find.text(tr.userBlock.block), findsNothing);
      expect(find.text(tr.userBlock.serverRules.entry), findsOneWidget);

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await openMenu(tester, notice(type: 'post', author: _alice.uid));
      expect(find.text(tr.userBlock.block), findsNothing);
      expect(find.text(tr.userBlock.serverRules.entry), findsOneWidget);
    });

    testWidgets('the local block entry blocks the author of that notice for the current account', (tester) async {
      await openMenu(tester, notice(type: 'post', author: _bob));
      await tester.tap(find.text(tr.userBlock.block));
      await tester.pumpAndSettle();
      expect(find.text(tr.userBlock.blockConfirmTitle(name: 'UID $_bob')), findsOneWidget);
      await tester.tap(find.text(tr.general.ok));
      await settle(tester);
      await tester.pumpAndSettle();

      final list = await tester.runAsync(() => blocks.load(_alice.uid));
      expect(list!.users.map((e) => (e.uid, e.username)), [(_bob, 'UID $_bob')]);
      // Blocked now: the card itself goes away.
      expect(shows('a notice'), isFalse);
    });

    testWidgets('the forum rule entry asks about the type and the author of that notice', (tester) async {
      await openMenu(tester, notice(type: 'pcomment', author: _bob));
      await tester.tap(find.text(tr.userBlock.serverRules.entry));
      await tester.pumpAndSettle();
      final type = tr.userBlock.serverRules.types.pcomment;
      expect(find.text(tr.userBlock.serverRules.ignoreThisUser(type: type)), findsOneWidget);
      expect(find.text(tr.userBlock.serverRules.ignoreEverybody(type: type)), findsOneWidget);
      // Leave without choosing: nothing is sent.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text(tr.userBlock.serverRules.ignoreEverybody(type: type)), findsNothing);
    });

    testWidgets('the forum rule entry of a system notice offers the rule for everybody only', (tester) async {
      await openMenu(tester, notice(type: 'system', author: 0));
      await tester.tap(find.text(tr.userBlock.serverRules.entry));
      await tester.pumpAndSettle();
      final type = tr.userBlock.serverRules.types.system;
      expect(find.text(tr.userBlock.serverRules.ignoreThisUser(type: type)), findsNothing);
      expect(find.text(tr.userBlock.serverRules.ignoreEverybody(type: type)), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    });
  });

  group('thread page', () {
    late _ThreadAdapter adapter;
    late ThreadVisitHistoryBloc history;

    setUp(() {
      history = ThreadVisitHistoryBloc(ThreadVisitHistoryRepo(storage));
    });

    tearDown(() => history.close());

    void serve(Map<String, String> pages) {
      adapter = _ThreadAdapter(pages);
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      );
    }

    Future<void> open(WidgetTester tester, String page, {UserBlockRepository? repository}) => pump(
      tester,
      ThreadPage(
        threadID: _tid,
        findPostID: null,
        pageNumber: page,
        overrideReverseOrder: false,
        overrideWithExactOrder: null,
      ),
      repository: repository,
      blocs: [BlocProvider<ThreadVisitHistoryBloc>.value(value: history)],
    );

    /// Threads in Alice's visit history, by title.
    Future<List<String>> visited(WidgetTester tester) async {
      final all = await tester.runAsync(() => ThreadVisitHistoryRepo(storage).fetchAllHistory().run());
      return all!.match((e) => fail('history not readable: $e'), (v) => v.map((e) => e.threadTitle).toList());
    }

    final laterPage = _threadPage([
      _floor(pid: 11, floor: 11, uid: _carol, name: 'Carol'),
      _floor(pid: 12, floor: 12, uid: _alice.uid!, name: 'Alice'),
    ]);

    group('visit history', () {
      testWidgets('a thread shown while somebody else is blocked is recorded with its board', (tester) async {
        await tester.runAsync(blockBob);
        serve({
          '1': _threadPage([_floor(pid: 1, floor: 1, uid: _carol, name: 'Carol')]),
        });
        await open(tester, '1');
        expect(shows('floor 1 text'), isTrue);
        final all = await tester.runAsync(() => ThreadVisitHistoryRepo(storage).fetchAllHistory().run());
        final rows = all!.getOrElse((e) => fail('history not readable: $e'));
        expect(rows.map((e) => (e.uid, e.threadId, e.threadTitle, e.forumId, e.forumName)), [
          (_alice.uid, int.parse(_tid), 'Secret title', 8, 'Board'),
        ]);
      });

      testWidgets('a thread of a blocked author is not recorded', (tester) async {
        await tester.runAsync(blockBob);
        serve({
          '1': _threadPage([
            _floor(pid: 1, floor: 1, uid: _bob, name: 'Bob'),
            _floor(pid: 2, floor: 2, uid: _carol, name: 'Carol'),
          ]),
        });
        await open(tester, '1');
        expect(find.text(tr.userBlock.threadHidden), findsOneWidget);
        expect(await visited(tester), isEmpty);
      });

      testWidgets('a held back thread is recorded once its author is known not to be blocked', (tester) async {
        await tester.runAsync(blockBob);
        serve({
          '1': _threadPage([_floor(pid: 1, floor: 1, uid: _carol, name: 'Carol')]),
          '2': laterPage,
        });
        final page1 = adapter.gates['1'] = Completer<void>();
        await open(tester, '2');
        // Page 2 is here, who started the thread is not known yet.
        expect(shows('floor 11 text'), isFalse);
        expect(await visited(tester), isEmpty);

        page1.complete();
        await settle(tester);
        expect(shows('floor 11 text'), isTrue);
        expect(await visited(tester), ['Secret title']);
      });

      testWidgets('a held back thread whose author turns out blocked is never recorded', (tester) async {
        await tester.runAsync(blockBob);
        serve({
          '1': _threadPage([_floor(pid: 1, floor: 1, uid: _bob, name: 'Bob')]),
          '2': laterPage,
        });
        final page1 = adapter.gates['1'] = Completer<void>();
        await open(tester, '2');
        expect(await visited(tester), isEmpty);

        page1.complete();
        await settle(tester);
        expect(find.text(tr.userBlock.threadHidden), findsOneWidget);
        expect(await visited(tester), isEmpty);
      });
    });

    testWidgets('a quote of a blocked post on the same page is replaced, other quotes stay', (tester) async {
      // Every floor on screen: the floors of the thread page are built lazily.
      tester.view
        ..physicalSize = const Size(1000, 5000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(blockBob);
      // Pids are not floor numbers: a quote names the pid of the post it quotes.
      serve({
        '1': _threadPage([
          _floor(pid: 101, floor: 1, uid: _carol, name: 'Carol'),
          _floor(pid: 102, floor: 2, uid: _bob, name: 'Bob'),
          _floor(
            pid: 103,
            floor: 3,
            uid: _alice.uid!,
            name: 'Alice',
            body: '${_quote(102, 'Bob', 'words of Bob')}reply of Alice',
          ),
          _floor(
            pid: 104,
            floor: 4,
            uid: _alice.uid!,
            name: 'Alice',
            // Pid 101 is Carol's floor. Pid 2 is not on this page (the floor numbered 2 is pid 102): its author is not
            // known, whatever name the quote shows.
            body: '${_quote(101, 'Carol', 'words of Carol')}${_quote(2, 'Bob', 'words from another page')}second reply',
          ),
        ]),
      });
      await open(tester, '1');
      // Bob's own floor is a placeholder, and his words do not come back through Alice's quote.
      expect(find.byType(BlockedPostPlaceholder), findsOneWidget);
      expect(shows('words of Bob'), isFalse);
      expect(shows(tr.userBlock.quotePlaceholder), isTrue);
      expect(shows('reply of Alice'), isTrue);
      expect(shows('words of Carol'), isTrue);
      expect(shows('words from another page'), isTrue, reason: 'a quote that can not be attributed is kept');
    });

    testWidgets('a block list that can not be read holds the thread back with a retry, never an unblock', (
      tester,
    ) async {
      final flaky = _FlakyStorage(db);
      final unreadable = UserBlockRepository(flaky);
      addTearDown(unreadable.dispose);
      serve({
        '1': _threadPage([
          _floor(pid: 1, floor: 1, uid: _carol, name: 'Carol'),
          _floor(pid: 2, floor: 2, uid: _bob, name: 'Bob'),
        ]),
      });
      await open(tester, '1', repository: unreadable);
      expect(find.text(tr.userBlock.loadFailed), findsOneWidget);
      expect(find.text(tr.general.retry), findsOneWidget);
      expect(find.text(tr.userBlock.unblock), findsNothing, reason: 'nobody is known to be blocked');
      expect(find.text(tr.userBlock.threadHidden), findsNothing);
      expect(shows('Secret title'), isFalse);
      expect(shows('floor 1 text'), isFalse);
      expect(find.byType(PostCard), findsNothing);
      expect(await visited(tester), isEmpty);

      // Readable again: the retry shows the thread.
      flaky.failing = false;
      await tester.tap(find.text(tr.general.retry));
      await settle(tester);
      expect(shows('floor 1 text'), isTrue);
      expect(find.text(tr.userBlock.loadFailed), findsNothing);
    });
  });
}

Translations get tr => LocaleSettings.instance.currentTranslations;

/// Let database work and futures finish outside the fake zone, then build the frames it caused.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}
