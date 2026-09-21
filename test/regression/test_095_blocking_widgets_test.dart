import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/blocking/view/user_block_page.dart';
import 'package:tsdm_client/features/blocking/widgets/block_aware_post.dart';
import 'package:tsdm_client/features/blocking/widgets/notice_ignore_actions.dart';
import 'package:tsdm_client/features/blocking/widgets/user_block_button.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/features/latest_thread/view/latest_thread_page.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/view/notification_search_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
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
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Widget level regressions of the local block and the forum notice rules, on the real pages and cards:
/// account switches while a confirmation is open, the management page, notice search, fully hidden list pages and
/// threads opened directly. All pages are synthetic (grounded in the Discuz templates), no real account or network.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 2000);
const _troll = 3000;

/// Authentication with a current account that the test switches, like a switch in the account manager.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  int? get effectiveCurrentUid => currentUser?.uid;

  void switchTo(UserLoginInfo? user) {
    currentUser = user;
    _controller.add(user == null ? const AuthStatusNotAuthed() : AuthStatusAuthed(user));
  }

  Future<void> close() => _controller.close();
}

/// Forum rules answered by the test through completers.
final class _Rules extends NoticeIgnoreRepository {
  final fetches = <(int, Completer<NoticeIgnoreResult>)>[];
  final removals = <(int, NoticeIgnoreRule, Completer<NoticeIgnoreResult>)>[];

  @override
  Future<NoticeIgnoreResult> fetchRules(NetClientProvider client, {required int uid}) {
    final c = Completer<NoticeIgnoreResult>();
    fetches.add((uid, c));
    return c.future;
  }

  @override
  Future<NoticeIgnoreResult> removeRule(NetClientProvider client, {required int uid, required NoticeIgnoreRule rule}) {
    final c = Completer<NoticeIgnoreResult>();
    removals.add((uid, rule, c));
    return c.future;
  }
}

/// Notification bloc holding a fixed state; the search page only reads it.
final class _Notifications extends Fake implements NotificationBloc {
  _Notifications(this.state);

  @override
  final NotificationState state;

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// Never answers: avatars are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// One floor of a thread page, the author in the post header like the real page.
String _floor({required int pid, required int floor, required int uid, required String name}) =>
    '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=$uid" class="xi2">$name</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor text</div></div></div></td>
</tr></tbody></table></div>''';

String _threadPage(List<String> floors) =>
    '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=1264975" /></head><body>
<div id="postlist"><h1 class="ts"><span id="thread_subject">Secret title</span></h1><div class="bm">
${floors.join('\n')}
</div></div>
</body></html>''';

/// Thread pages by page number; every request is recorded.
///
/// A page in [gates] is answered only once its completer completes; a page in [failures] fails with a connection
/// error that many times before it is served.
final class _ThreadAdapter implements HttpClientAdapter {
  _ThreadAdapter(this.pages);

  final Map<String, String> pages;
  final gates = <String, Completer<void>>{};
  final failures = <String, int>{};
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
    final remaining = failures[page] ?? 0;
    if (remaining > 0) {
      failures[page] = remaining - 1;
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
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

/// Serves a captured guide page instead of the network.
final class _FixtureRepository extends LatestThreadRepository {
  _FixtureRepository(this.name);

  final String name;

  @override
  AsyncEither<uh.Document> fetchDocument(String url) =>
      AsyncEither.of(parseHtmlDocument(File('test/data/$name').readAsStringSync()));
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

  /// Pump [child] under the providers of the app, with a block cubit following [auth].
  Future<UserBlockCubit> pump(WidgetTester tester, Widget child, {bool router = false}) async {
    final info = NotificationInfoRepository();
    final counts = NotificationStateCubit(info);
    addTearDown(() async {
      await info.dispose();
      await counts.close();
    });
    final cubit = UserBlockCubit(
      repository: blocks,
      currentUid: () => auth.currentUser?.uid,
      authStatus: auth.status,
    );
    addTearDown(cubit.close);
    Widget app;
    if (router) {
      final r = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => child)],
      );
      addTearDown(r.dispose);
      app = MaterialApp.router(routerConfig: r, scaffoldMessengerKey: snackbarKey);
    } else {
      app = MaterialApp(home: child, scaffoldMessengerKey: snackbarKey);
    }
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
              BlocProvider<NotificationBloc>.value(
                value: _Notifications(const NotificationState(status: NotificationStatus.success)),
              ),
              BlocProvider<NotificationStateCubit>.value(value: counts),
            ],
            child: app,
          ),
        ),
      ),
    );
    await settle(tester);
    return cubit;
  }

  Future<void> blockNow(int owner, int uid) => blocks.block(ownerUid: owner, uid: uid, username: 'u$uid');

  group('account switch while a confirmation is open', () {
    testWidgets('a block confirmed after switching to another account changes neither account', (tester) async {
      await pump(
        tester,
        const Scaffold(
          body: UserBlockButton(uid: _troll, username: 'troll'),
        ),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(find.text('Block troll?'), findsOneWidget);

      // Account B becomes current while A's dialog is open.
      auth.switchTo(_bob);
      await settle(tester);
      await tester.tap(find.text(tr.general.ok));
      await settle(tester);

      expect(await tester.runAsync(() => blocks.blockedUidsOf(_alice.uid)), isEmpty);
      expect(await tester.runAsync(() => blocks.blockedUidsOf(_bob.uid)), isEmpty);
      expect(find.text(tr.userBlock.accountChanged), findsOneWidget);
    });

    testWidgets('a forum rule chosen for A is never written after switching to B', (tester) async {
      final rules = _Rules();
      await pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => showNoticeIgnoreDialog(
                context,
                const NoticeIgnoreTarget(type: 'post', authorId: _troll),
                repository: rules,
                clientFactory: _client,
              ),
              child: const Text('ignore'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('ignore'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr.userBlock.serverRules.ignoreThisUser(type: 'post')));
      await tester.pumpAndSettle();
      auth.switchTo(_bob);
      await tester.tap(find.text(tr.general.ok));
      await settle(tester);
      expect(find.text(tr.userBlock.serverRules.failure.accountMismatch), findsOneWidget);
      // Nothing reached the repository: no read, no write, for either account.
      expect(rules.fetches, isEmpty);
      expect(rules.removals, isEmpty);
    });

    testWidgets('a system notice only offers the rule for everybody', (tester) async {
      await pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => showNoticeIgnoreDialog(
                context,
                const NoticeIgnoreTarget(type: 'system', authorId: 0),
                repository: _Rules(),
                clientFactory: _client,
              ),
              child: const Text('ignore'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('ignore'));
      await tester.pumpAndSettle();
      expect(find.text(tr.userBlock.serverRules.ignoreThisUser(type: 'system')), findsNothing);
      expect(find.text(tr.userBlock.serverRules.ignoreEverybody(type: 'system')), findsOneWidget);
    });
  });

  group('management page', () {
    testWidgets('rules of A are cleared when B becomes current and a late answer for A is dropped', (tester) async {
      final rules = _Rules();
      await pump(tester, UserBlockPage(noticeIgnoreRepository: rules, clientFactory: _client));
      await tester.tap(find.byIcon(Icons.cloud_sync_outlined));
      await tester.pump();
      expect(rules.fetches.single.$1, _alice.uid);

      // Duplicate taps while loading send nothing more.
      await tester.tap(find.byIcon(Icons.cloud_sync_outlined));
      await tester.pump();
      expect(rules.fetches, hasLength(1));

      rules.fetches.single.$2.complete(
        const NoticeIgnoreResult.success([NoticeIgnoreRule(type: 'post', authorId: _troll)]),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('rule-post|3000')), findsOneWidget);

      auth.switchTo(_bob);
      await settle(tester);
      expect(find.byKey(const ValueKey('rule-post|3000')), findsNothing, reason: "A's rules are not B's");

      // Load for B, then switch back to A before B's answer arrives: B's rules never show for A.
      await tester.tap(find.byIcon(Icons.cloud_sync_outlined));
      await tester.pump();
      expect(rules.fetches.last.$1, _bob.uid);
      auth.switchTo(_alice);
      await settle(tester);
      rules.fetches.last.$2.complete(
        const NoticeIgnoreResult.success([NoticeIgnoreRule(type: 'friend', authorId: 0)]),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('rule-friend|0')), findsNothing);
    });

    testWidgets('removing a rule of A is dropped when B became current during the confirmation', (tester) async {
      final rules = _Rules();
      await pump(tester, UserBlockPage(noticeIgnoreRepository: rules, clientFactory: _client));
      await tester.tap(find.byIcon(Icons.cloud_sync_outlined));
      await tester.pump();
      rules.fetches.single.$2.complete(
        const NoticeIgnoreResult.success([NoticeIgnoreRule(type: 'post', authorId: _troll)]),
      );
      await settle(tester);

      await tester.tap(find.text(tr.userBlock.serverRules.remove));
      // The page shows its progress indicator while the dialog is open: pump frames instead of settling.
      await settle(tester);
      auth.switchTo(_bob);
      await tester.tap(find.text(tr.general.ok));
      await settle(tester);
      expect(rules.removals, isEmpty);
    });

    testWidgets('the local list of the current account is shown and follows a switch', (tester) async {
      await tester.runAsync(() => blockNow(_alice.uid!, _troll));
      await pump(tester, UserBlockPage(noticeIgnoreRepository: _Rules(), clientFactory: _client));
      expect(find.byKey(const ValueKey('blocked-$_troll')), findsOneWidget);
      auth.switchTo(_bob);
      await settle(tester);
      expect(find.byKey(const ValueKey('blocked-$_troll')), findsNothing);
      expect(find.text(tr.userBlock.empty), findsOneWidget);
    });
  });

  group('notice search', () {
    NoticeV2 notice(int id, String text, {int? author}) => NoticeV2(
      id: id,
      timestamp: 1788000000 + id,
      data: text,
      ignoreType: author == null ? null : 'post',
      authorId: author,
    );

    testWidgets('notices of blocked users never show in search, also after a change while open', (tester) async {
      await tester.runAsync(() => blockNow(_alice.uid!, _troll));
      final state = NotificationState(
        status: NotificationStatus.success,
        noticeList: [
          notice(1, 'troll wrote a secret', author: _troll),
          notice(2, 'bob wrote hello', author: _bob.uid),
          notice(3, 'system says hi'),
        ],
      );
      final cubit = await pump(
        tester,
        BlocProvider<NotificationBloc>.value(value: _Notifications(state), child: const NotificationSearchPage()),
      );
      bool shows(String text) => find.textContaining(text, findRichText: true).evaluate().isNotEmpty;
      expect(shows('troll wrote a secret'), isFalse);
      expect(shows('bob wrote hello'), isTrue);
      expect(shows('system says hi'), isTrue);

      await tester.runAsync(() async {
        await cubit.block(uid: _bob.uid!, username: 'Bob', expectedOwner: _alice.uid);
        await cubit.unblock(_troll, expectedOwner: _alice.uid);
        await pumpEventQueue();
      });
      await settle(tester);
      expect(shows('bob wrote hello'), isFalse);
      expect(shows('troll wrote a secret'), isTrue);
    });

    testWidgets('a notice card of a blocked author renders nothing on its own', (tester) async {
      await tester.runAsync(() => blockNow(_alice.uid!, _troll));
      await pump(tester, Scaffold(body: NoticeCardV2(notice(1, 'troll wrote a secret', author: _troll))));
      expect(find.byType(Card), findsNothing);
    });
  });

  group('lists', () {
    testWidgets('a page whose topics are all hidden keeps its list and its pagination', (tester) async {
      await pump(
        tester,
        LatestThreadPage(url: guideUrl('hot'), title: 'hot', repository: _FixtureRepository('guide_hot_x5.html')),
        router: true,
      );
      final cards = tester.widgetList<LatestThreadCard>(find.byType(LatestThreadCard)).toList();
      final authors = cards.map((e) => int.tryParse(e.thread.threadAuthor?.uid ?? '')).whereType<int>().toSet();
      expect(authors, isNotEmpty);
      await tester.runAsync(() async {
        for (final uid in authors) {
          await blockNow(_alice.uid!, uid);
        }
      });
      await settle(tester);
      final withAuthor = cards.where((e) => e.thread.threadAuthor?.uid != null).map((e) => e.thread.title!);
      for (final title in withAuthor) {
        expect(find.text(title), findsNothing, reason: 'topic of a blocked author: $title');
      }
      // Not turned into the empty page: the list and its load-more stay.
      expect(find.text(tr.latestThreadPage.empty), findsNothing);
      expect(find.byType(EasyRefresh), findsOneWidget);
    });
  });

  group('thread opened directly', () {
    late _ThreadAdapter adapter;

    void serve(Map<String, String> pages) {
      adapter = _ThreadAdapter(pages);
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      );
    }

    Widget thread(String page, {String? title, bool reverse = false}) => ThreadPage(
      threadID: '1264975',
      findPostID: null,
      pageNumber: page,
      title: title,
      overrideReverseOrder: reverse,
      overrideWithExactOrder: null,
    );

    bool shows(String text) => find.textContaining(text, findRichText: true).evaluate().isNotEmpty;

    /// Nothing of thread 1264975 is on screen: no title, no floor, no reply bar, and it is not called blocked.
    void expectHeldBack({String? title}) {
      for (final t in ['Secret title', 'floor 11 text', 'floor 12 text', ?title]) {
        expect(shows(t), isFalse, reason: '$t is held back');
      }
      expect(find.byType(ReplyBar), findsNothing);
      expect(find.byType(PostCard), findsNothing);
      expect(find.text(tr.userBlock.threadHidden), findsNothing, reason: 'the author is not known to be blocked');
      expect(find.text(tr.userBlock.unblock), findsNothing);
    }

    final laterPage = _threadPage([
      _floor(pid: 11, floor: 11, uid: _bob.uid!, name: 'Bob'),
      _floor(pid: 12, floor: 12, uid: _alice.uid!, name: 'Alice'),
    ]);

    testWidgets('the title given by the caller never shows while the page and its author load', (tester) async {
      await tester.runAsync(() => blockNow(_alice.uid!, _troll));
      serve({
        '1': _threadPage([_floor(pid: 1, floor: 1, uid: _bob.uid!, name: 'Bob')]),
        '2': laterPage,
      });
      final page2 = adapter.gates['2'] = Completer<void>();
      final page1 = adapter.gates['1'] = Completer<void>();
      await pump(tester, thread('2', title: 'Provided title'), router: true);
      // The page itself is still loading.
      expectHeldBack(title: 'Provided title');

      page2.complete();
      await settle(tester);
      // The page is here, its author is not known yet.
      expect(adapter.requests.map((e) => e.queryParameters['page']), contains('1'));
      expectHeldBack(title: 'Provided title');

      page1.complete();
      await settle(tester);
      // Started by Bob, who is not blocked: the thread shows.
      expect(shows('floor 11 text'), isTrue);
      expect(find.byType(ReplyBar), findsOneWidget);
    });

    testWidgets('a failed author read keeps a later page held back and retry recovers', (tester) async {
      await tester.runAsync(() => blockNow(_alice.uid!, _troll));
      serve({
        '1': _threadPage([_floor(pid: 1, floor: 1, uid: _bob.uid!, name: 'Bob')]),
        '2': laterPage,
      });
      adapter.failures['1'] = 1;
      await pump(tester, thread('2', title: 'Provided title'), router: true);
      expectHeldBack(title: 'Provided title');
      expect(find.text(tr.general.failedToLoad), findsOneWidget);
      // Not a spinner forever: a retry is offered.
      expect(find.text(tr.general.retry), findsOneWidget);

      await tester.tap(find.text(tr.general.retry));
      await settle(tester);
      expect(adapter.requests.where((e) => e.queryParameters['page'] == '1'), hasLength(2));
      expect(shows('floor 11 text'), isTrue);
      expect(find.text(tr.general.failedToLoad), findsNothing);
    });

    testWidgets('a retried author read that names a blocked author hides the thread', (tester) async {
      await tester.runAsync(() => blockNow(_alice.uid!, _troll));
      serve({
        '1': _threadPage([_floor(pid: 1, floor: 1, uid: _troll, name: 'troll')]),
        '2': laterPage,
      });
      adapter.failures['1'] = 1;
      await pump(tester, thread('2'), router: true);
      expectHeldBack();
      await tester.tap(find.text(tr.general.retry));
      await settle(tester);
      expect(find.text(tr.userBlock.threadHidden), findsOneWidget);
      expect(shows('Secret title'), isFalse);
      expect(shows('floor 11 text'), isFalse);
    });

    testWidgets('a first page without a trustworthy first floor keeps the thread held back', (tester) async {
      await tester.runAsync(() => blockNow(_alice.uid!, _troll));
      serve({
        // Answered, but no floor 1: nothing tells who started the thread.
        '1': _threadPage([_floor(pid: 5, floor: 5, uid: _bob.uid!, name: 'Bob')]),
        '2': laterPage,
      });
      await pump(tester, thread('2', title: 'Provided title'), router: true);
      expectHeldBack(title: 'Provided title');
      expect(find.text(tr.general.retry), findsOneWidget);
    });

    testWidgets('a first page that is not a thread page keeps the thread held back', (tester) async {
      await tester.runAsync(() => blockNow(_alice.uid!, _troll));
      serve({'1': '<html><body><div id="messagetext">error</div></body></html>', '2': laterPage});
      await pump(tester, thread('2', title: 'Provided title'), router: true);
      expectHeldBack(title: 'Provided title');
      expect(find.text(tr.general.retry), findsOneWidget);
    });

    testWidgets('with newest first set, the author read still asks the first page oldest first', (tester) async {
      await tester.runAsync(() => blockNow(_alice.uid!, _troll));
      await tester.runAsync(() => settings.setValue<bool>(SettingsKeys.threadReverseOrder, true));
      serve({
        '1': _threadPage([_floor(pid: 1, floor: 1, uid: _troll, name: 'troll')]),
        '2': laterPage,
      });
      await pump(tester, thread('2', reverse: true), router: true);
      final shown = adapter.requests.firstWhere((e) => e.queryParameters['page'] == '2');
      expect(shown.queryParameters['ordertype'], '1', reason: 'the page shown follows the newest first setting');
      final lookup = adapter.requests.where((e) => e.queryParameters['page'] == '1').toList();
      expect(lookup, hasLength(1));
      expect(lookup.single.queryParameters['ordertype'], '2', reason: 'oldest first, so floor 1 is on page 1');
      expect(find.text(tr.userBlock.threadHidden), findsOneWidget);
      expect(shows('floor 11 text'), isFalse);
    });

    testWidgets('first page of a blocked author shows nothing of the thread', (tester) async {
      await tester.runAsync(() => blockNow(_alice.uid!, _troll));
      serve({
        '1': _threadPage([
          _floor(pid: 1, floor: 1, uid: _troll, name: 'troll'),
          _floor(pid: 2, floor: 2, uid: _bob.uid!, name: 'Bob'),
        ]),
      });
      await pump(tester, thread('1'), router: true);
      expect(find.text(tr.userBlock.threadHidden), findsOneWidget);
      expect(find.text('Secret title'), findsNothing);
      expect(find.textContaining('floor 2 text', findRichText: true), findsNothing);
      expect(find.text(tr.userBlock.unblock), findsOneWidget);
    });

    testWidgets('a later page asks the first page for the author and hides the thread', (tester) async {
      await tester.runAsync(() => blockNow(_alice.uid!, _troll));
      serve({
        '1': _threadPage([_floor(pid: 1, floor: 1, uid: _troll, name: 'troll')]),
        '2': _threadPage([
          _floor(pid: 11, floor: 11, uid: _bob.uid!, name: 'Bob'),
          _floor(pid: 12, floor: 12, uid: _alice.uid!, name: 'Alice'),
        ]),
      });
      await pump(tester, thread('2'), router: true);
      expect(adapter.requests.map((e) => e.queryParameters['page']), containsAll(['1', '2']));
      final first = adapter.requests.firstWhere((e) => e.queryParameters['page'] == '1');
      expect(first.queryParameters['ordertype'], '2', reason: 'oldest first, so floor 1 is on page 1');
      expect(find.text(tr.userBlock.threadHidden), findsOneWidget);
      expect(find.text('Secret title'), findsNothing);
      expect(find.textContaining('floor 11 text', findRichText: true), findsNothing);
    });

    testWidgets('an author known from a list is used without asking the forum again', (tester) async {
      await tester.runAsync(() => blockNow(_alice.uid!, _troll));
      ThreadAuthorCache.record('1264975', '$_troll');
      serve({
        '2': _threadPage([_floor(pid: 11, floor: 11, uid: _bob.uid!, name: 'Bob')]),
      });
      await pump(tester, thread('2'), router: true);
      expect(adapter.requests.map((e) => e.queryParameters['page']), ['2']);
      expect(find.text(tr.userBlock.threadHidden), findsOneWidget);
    });

    testWidgets('a reply of a blocked user in a normal thread becomes a placeholder in place', (tester) async {
      await tester.runAsync(() => blockNow(_alice.uid!, _troll));
      serve({
        '1': _threadPage([
          _floor(pid: 1, floor: 1, uid: _bob.uid!, name: 'Bob'),
          _floor(pid: 2, floor: 2, uid: _troll, name: 'troll'),
        ]),
      });
      await pump(tester, thread('1'), router: true);
      expect(find.text(tr.userBlock.threadHidden), findsNothing);
      expect(find.byType(BlockedPostPlaceholder), findsOneWidget);
      expect(find.text('#2'), findsOneWidget, reason: 'the floor keeps its number');
      expect(find.textContaining('floor 2 text', findRichText: true), findsNothing);
    });
  });
}

Translations get tr => LocaleSettings.instance.currentTranslations;

NetClientProvider _client(UserLoginInfo _) => NetClientProvider.buildNoCookie(
  dio: Dio()..httpClientAdapter = _OfflineAdapter(),
  cookie: CookieProvider.buildEmpty(),
);

/// Let database work and futures finish outside the fake zone, then build the frames it caused.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}
