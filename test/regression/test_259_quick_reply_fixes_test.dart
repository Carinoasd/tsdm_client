/// GitHub #235, the quick reply of 1.47.0 (the reply page opened from a notice, `NoticeDetailPage`):
///
/// 1. the thread is not closed while the page loads: the box of a thread open for replies never showed "帖子已关闭",
///    that hint is never text of the box, of the editor or of a draft, and a draft holding only it is dropped;
/// 2. the home button goes home: at once without an unsent reply, after asking (the reply kept as a local draft) with
///    one;
/// 3. the reply page does not resize for the keyboard, the editor makes room for it itself (as on the thread page);
/// 4. leaving the thread right after it scrolled to a floor throws nothing (the list's own scroll animation kept
///    ticking on a list already gone);
/// 5. a `notify` answered "too soon" for a second (the background service polled the same account a moment before)
///    is asked again after that second instead of reading the three notification pages.
///
/// Synthetic accounts and pages only: no network, nothing is sent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/editor/repository/recent_emoji_store.dart';
import 'package:tsdm_client/features/editor/widgets/rich_editor.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/local_draft/utils/draft_text.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_detail_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/view/notification_detail_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/page_stack.dart';
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
import 'package:tsdm_client/widgets/back_to_home_button.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

const _alice = UserLoginInfo(username: 'Alice', uid: 31);

const _tid = '1264975';
const _pid = 11;

const _parameters = ReplyParameters(fid: '8', tid: _tid, postTime: '0', formHash: 'XXXXXXXX', subject: '');

/// A floor of a thread page (grounded in the Discuz templates, as in test_171).
String _threadFloor({required int pid, required int floor}) =>
    '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1002" class="xi2">Carol</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor text</div></div></div></td>
</tr></tbody></table></div>''';

/// A thread page with two floors, open for replies (its fast reply form has the textarea), as in test_171.
const _threadPage =
    '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=$_tid" /></head><body>
<form id="scbar_form"><input type="hidden" name="srhfid" value="8" /></form>
<div id="postlist"><h1 class="ts"><span id="thread_subject">Synthetic thread</span></h1><div class="bm">
FLOORS
</div></div>
<form method="post" id="fastpostform" action="forum.php?mod=post&amp;action=reply&amp;fid=8&amp;tid=$_tid&amp;extra=&amp;replysubmit=yes&amp;infloat=yes&amp;handlekey=fastpost">
<div class="area"><textarea rows="6" cols="80" name="message" id="fastpostmessage" class="pt"></textarea></div>
<input type="hidden" name="posttime" id="posttime" value="0" />
<input type="hidden" name="formhash" value="XXXXXXXX" />
<input type="hidden" name="subject" value="  " />
</form>
</body></html>''';

String get _openThread =>
    _threadPage.replaceFirst('FLOORS', '${_threadFloor(pid: 10, floor: 1)}\n${_threadFloor(pid: _pid, floor: 2)}');

/// The thread page above, answered once [gate] completes; images and anything else are offline.
final class _PagesAdapter implements HttpClientAdapter {
  Completer<void>? gate;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancel) async {
    final uri = options.uri;
    requests.add(uri);
    final q = uri.queryParameters;
    if (uri.pathSegments.lastOrNull == 'forum.php' && q['mod'] == 'redirect' && q['goto'] == 'findpost') {
      await gate?.future;
      return ResponseBody.fromString(
        _openThread,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    throw DioException.connectionError(requestOptions: options, reason: 'offline');
  }

  @override
  void close({bool force = false}) {}
}

/// Every image request fails at once.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancel) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Notification bloc with a fixed state, events ignored.
final class _Notifications extends Fake implements NotificationBloc {
  @override
  NotificationState get state => const NotificationState(status: NotificationStatus.success);

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  void add(NotificationEvent event) {}

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// A few frames with real time in between, for the database and the fake network.
Future<void> _settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// [future], once the frames let it complete.
Future<T> _wait<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  late T value;
  unawaited(
    future.then((v) {
      value = v;
      done = true;
    }),
  );
  for (var i = 0; i < 50 && !done; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done, isTrue, reason: 'the future completed');
  return value;
}

Finder _field() => find.byKey(const ValueKey('reply-bar-field'));

String _boxText(WidgetTester tester) => tester.widget<TextField>(_field()).controller!.text;

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late LocalDraftStore drafts;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  setUp(() async {
    TsdmAppApi.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    drafts = LocalDraftStore.memory();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<LocalDraftStore>(drafts)
      ..registerSingleton<RecentEmojiStore>(RecentEmojiStore.memory());
    await settings.init();
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  group('1. the closed hint of the quick reply page', () {
    test('a notice not loaded yet is not a closed thread', () {
      expect(const NotificationDetailState().threadClosed, isFalse);
    });

    test('the hints of the box in every language are recognized, a reply is not', () {
      for (final hint in ['帖子已关闭', '貼文已關閉', 'Thread is closed', ' 需要登录\n', '需要登入', 'Need login']) {
        expect(isReplyBoxHint(hint), isTrue, reason: hint);
      }
      expect(isReplyBoxHint(tr.threadPage.closed), isTrue);
      expect(isReplyBoxHint('帖子已关闭了吗？'), isFalse);
      expect(isReplyBoxHint(''), isFalse);
    });

    test('a draft 1.47.0 kept holding only the closed hint is dropped when read', () async {
      final tmp = Directory.systemTemp.createTempSync('tsdm_259_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final hint = LocalDraft(key: LocalDraftKey.threadReply(_tid), body: '帖子已关闭', updatedAt: DateTime(2026, 10, 23));
      final real = LocalDraft(
        key: LocalDraftKey.floorReply(_tid, '$_pid'),
        body: '写到一半',
        updatedAt: DateTime(2026, 10, 23),
      );
      // The file 1.47.0 left: the hint kept as the draft of the thread, beside a real draft.
      Directory('${tmp.path}/drafts').createSync();
      File('${tmp.path}/drafts/31.json').writeAsStringSync(
        jsonEncode({
          'v': LocalDraftStore.formatVersion,
          'uid': 31,
          'drafts': {hint.key.value: hint.toJson(), real.key.value: real.toJson()},
        }),
      );
      final store = LocalDraftStore(directory: () async => Directory('${tmp.path}/drafts'));
      expect((await store.list(31)).map((e) => e.body), ['写到一半']);
      expect(await store.load(31, hint.key), isNull);

      // Saving is not judged by the text: the reply box tells its hint by its state, a reply is kept as written.
      store.save(31, LocalDraft(key: LocalDraftKey.threadReply('9'), body: '回复', updatedAt: DateTime(2026)));
      await store.pendingWrites;
      expect((await store.load(31, LocalDraftKey.threadReply('9')))?.body, '回复');
      await store.dispose();
    });

    /// A thread page with the reply bar, the thread told closed or not by [bloc].
    Future<(ReplyBarController, ReplyBloc, Route<dynamic>)> pumpBar(WidgetTester tester, {required bool closed}) async {
      final auth = AuthenticationRepository(user: _alice);
      final controller = ReplyBarController();
      final bloc = ReplyBloc(replyRepository: const ReplyRepository())
        ..add(const ReplyParametersUpdated(_parameters))
        ..add(ReplyThreadClosed(closed: closed));
      addTearDown(() async {
        await bloc.close();
        await auth.dispose();
      });
      await tester.pumpWidget(
        RepositoryProvider<AuthenticationRepository>.value(
          value: auth,
          child: RepositoryProvider<ReplyRepository>(
            create: (_) => const ReplyRepository(),
            child: BlocProvider<ReplyBloc>.value(
              value: bloc,
              child: TranslationProvider(
                child: MaterialApp(
                  home: Scaffold(
                    resizeToAvoidBottomInset: false,
                    body: const Center(child: Text('thread page')),
                    bottomNavigationBar: ReplyBar(controller: controller, replyType: ReplyTypes.notice),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      return (controller, bloc, ModalRoute.of(tester.element(find.text('thread page')))!);
    }

    testWidgets('closed first, then open: the hint goes, nothing is a draft, the editor opens empty', (tester) async {
      final (controller, bloc, route) = await pumpBar(tester, closed: true);
      expect(_boxText(tester), tr.threadPage.closed);
      expect(tester.widget<TextField>(_field()).enabled, isFalse, reason: 'the hint cannot be edited');
      expect(RouteDrafts.hasDraft(route), isFalse);

      bloc.add(const ReplyThreadClosed(closed: false));
      await _settle(tester);
      expect(_boxText(tester), isEmpty, reason: 'the hint is not a reply');
      expect(tester.widget<TextField>(_field()).enabled, isTrue);
      expect(RouteDrafts.hasDraft(route), isFalse, reason: 'nothing written');

      await tester.tap(_field());
      await _settle(tester);
      expect(controller.showingEditor, isTrue);
      final editor = tester.widget<RichEditor>(find.byType(RichEditor)).controller;
      expect(editor.toForumBBCode().trim(), isEmpty, reason: 'the editor did not get the hint');
      expect(RouteDrafts.hasDraft(route), isFalse, reason: 'an open editor still empty holds nothing to lose');

      controller.closeEditor();
      await _settle(tester);
      await tester.pumpWidget(const SizedBox());
      await _wait(tester, drafts.pendingWrites);
      expect(await _wait(tester, drafts.list(31)), isEmpty, reason: 'no draft was kept');
    });

    testWidgets('a closed thread keeps the hint, locked, and keeps no draft', (tester) async {
      final (_, _, route) = await pumpBar(tester, closed: true);
      await tester.tap(_field(), warnIfMissed: false);
      await _settle(tester);
      expect(find.byType(RichEditor), findsNothing, reason: 'no editor for a closed thread');
      expect(_boxText(tester), tr.threadPage.closed);
      expect(RouteDrafts.hasDraft(route), isFalse);
      await tester.pumpWidget(const SizedBox());
      await _wait(tester, drafts.pendingWrites);
      expect(await _wait(tester, drafts.list(31)), isEmpty);
    });

    group('the notice page', () {
      late SettingsBloc settingsBloc;
      late UserBlockRepository blocks;
      late _PagesAdapter pages;

      setUp(() {
        pages = _PagesAdapter();
        getIt
          ..registerFactory<NetClientProvider>(
            () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = pages),
          )
          ..registerSingleton<ImageCacheProvider>(
            ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
          );
        settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
        blocks = UserBlockRepository(storage);
        ThreadAuthorCache.clear();
      });

      tearDown(() async {
        await settingsBloc.close();
        await blocks.dispose();
        await getIt.get<ImageCacheProvider>().dispose();
      });

      Future<void> pumpNotice(WidgetTester tester) async {
        tester.view
          ..physicalSize = const Size(384, 792)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final auth = AuthenticationRepository(user: _alice);
        final info = NotificationInfoRepository();
        final counts = NotificationStateCubit(info);
        final history = ThreadVisitHistoryBloc(ThreadVisitHistoryRepo(storage));
        final blockCubit = UserBlockCubit(
          repository: blocks,
          currentUid: () => auth.currentUser?.uid,
          authStatus: auth.status,
          retryDelays: const [],
        );
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const NoticeDetailPage(
                url: '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=$_pid&ptid=$_tid',
                noticeType: NoticeType.reply,
              ),
            ),
          ],
        );
        addTearDown(() async {
          router.dispose();
          await blockCubit.close();
          await history.close();
          await counts.close();
          await info.dispose();
          await auth.dispose();
        });
        await tester.pumpWidget(
          TranslationProvider(
            child: MultiRepositoryProvider(
              providers: [
                RepositoryProvider<AuthenticationRepository>.value(value: auth),
                RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
              ],
              child: MultiBlocProvider(
                providers: [
                  BlocProvider<SettingsBloc>.value(value: settingsBloc),
                  BlocProvider<UserBlockCubit>.value(value: blockCubit),
                  BlocProvider<NotificationBloc>.value(value: _Notifications()),
                  BlocProvider<NotificationStateCubit>.value(value: counts),
                  BlocProvider<ThreadVisitHistoryBloc>.value(value: history),
                ],
                child: MaterialApp.router(routerConfig: router),
              ),
            ),
          ),
        );
      }

      testWidgets('loading: not closed; loaded, open: the box invites a reply, no hint, no draft', (tester) async {
        pages.gate = Completer<void>();
        await pumpNotice(tester);
        await _settle(tester, rounds: 3);
        expect(_field(), findsNothing, reason: 'still loading');
        final scaffold = find.byType(Scaffold).first;

        // From the first frame the box is on: it invites a reply, never "帖子已关闭" (the bar used to be built before
        // it was told the thread is open, and kept the hint as its text).
        pages.gate!.complete();
        for (var i = 0; i < 200 && _field().evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(find.text(tr.general.retry), findsNothing, reason: 'the page loaded');
        expect(_field(), findsOneWidget);
        expect(_boxText(tester), isEmpty, reason: 'the first frame of the box');
        await _settle(tester, rounds: 12);
        expect(_boxText(tester), isEmpty);
        expect(find.text(tr.threadPage.closed), findsNothing);
        expect(tester.widget<TextField>(_field()).enabled, isTrue);
        final route = ModalRoute.of(tester.element(_field()))!;
        expect(RouteDrafts.hasDraft(route), isFalse, reason: 'the home button has nothing to stop for');

        // 3. The editor makes room for the keyboard itself (chat_bottom_container): the page does not resize too.
        expect(tester.widget<Scaffold>(scaffold).resizeToAvoidBottomInset, isFalse);

        await tester.pumpWidget(const SizedBox());
        await _wait(tester, drafts.pendingWrites);
        expect(await _wait(tester, drafts.list(31)), isEmpty);
        await tester.pump(const Duration(seconds: 2));
      });
    });
  });

  group('2. the home button', () {
    late GoRouter router;

    GoRoute appRoute(String path, Widget Function(GoRouterState state) builder) => GoRoute(
      path: path,
      name: path,
      pageBuilder: (_, state) => MaterialPage<void>(
        name: path,
        child: Scaffold(body: builder(state)),
      ),
    );

    Future<void> pumpApp(WidgetTester tester) async {
      router = GoRouter(
        initialLocation: ScreenPaths.homepage,
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, _, navigator) => navigator,
            branches: [
              StatefulShellBranch(routes: [appRoute(ScreenPaths.homepage, (_) => const Text('home'))]),
              StatefulShellBranch(routes: [appRoute(ScreenPaths.notice, (_) => const Text('notice tab'))]),
            ],
          ),
          appRoute(ScreenPaths.reply, (state) => _ReplyPage('reply ${state.pathParameters['target']}')),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
        ),
      );
      await tester.pumpAndSettle();
      unawaited(router.pushNamed(ScreenPaths.reply, pathParameters: {'target': '1'}));
      await tester.pumpAndSettle();
      expect(find.text('reply 1'), findsOneWidget);
    }

    setUp(_ReplyPageState.drafts.clear);

    Finder homeButton() => find.byTooltip(tr.noticePage.appBar.backToHome);

    testWidgets('nothing written: home at once, nothing asked', (tester) async {
      await pumpApp(tester);
      await tester.tap(homeButton());
      await tester.pumpAndSettle();
      expect(find.text(tr.noticePage.appBar.backToHomeDraftTitle), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(find.text(tr.noticePage.appBar.backToHomeStopped), findsNothing);
    });

    testWidgets('a reply written: asks; cancelled, stays; agreed, home', (tester) async {
      await pumpApp(tester);
      _ReplyPageState.drafts['reply 1'] = true;
      expect(hasDraftAboveShell(router), isTrue);

      await tester.tap(homeButton());
      await tester.pumpAndSettle();
      expect(find.text(tr.noticePage.appBar.backToHomeDraftTitle), findsOneWidget);
      expect(find.text(tr.noticePage.appBar.backToHomeDraftDetail), findsOneWidget);
      expect(tr.noticePage.appBar.backToHomeDraftDetail, contains('同一页'), reason: 'neutral: also a private message');
      await tester.tap(find.text(tr.general.cancel));
      await tester.pumpAndSettle();
      expect(find.text('reply 1'), findsOneWidget, reason: 'cancelled: the reply page stays');
      expect(find.text(tr.noticePage.appBar.backToHomeStopped), findsNothing, reason: 'no hint: the user chose');

      await tester.tap(homeButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr.general.ok));
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      expect(find.text('reply 1'), findsNothing);
      expect(_ReplyPageState.disposed, contains('reply 1'), reason: 'the page went: its bar keeps the draft then');
    });

    testWidgets('without the user agreeing a page with a reply still stops the way home (notification taps)', (
      tester,
    ) async {
      await pumpApp(tester);
      _ReplyPageState.drafts['reply 1'] = true;
      expect(returnToHome(router), isFalse);
      await tester.pumpAndSettle();
      expect(find.text('reply 1'), findsOneWidget);
      expect(returnToHome(router, leaveDrafts: true), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
    });
  });

  group('4. leaving the thread while it scrolls to a floor', () {
    testWidgets('the page taken down right after the scroll began throws nothing', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        BlocProvider(
          create: (_) => JumpPageCubit(),
          child: MaterialApp(
            home: Scaffold(
              body: PostList(
                threadID: '1',
                postList: List.generate(30, (i) => _post(i + 1)),
                canLoadMore: false,
                scrollController: controller,
                latestModAct: null,
                title: 'title',
                useDivider: true,
                initialPostID: 25,
                widgetBuilder: (_, p) => SizedBox(height: 300, child: Text('post ${p.postID}')),
              ),
            ),
          ),
        ),
      );
      // The scroll to the floor starts after the first frame; the page goes in the next one.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpWidget(const MaterialApp(home: Text('left')));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the last floor: the jump stays within the scroll range from the first frame', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        BlocProvider(
          create: (_) => JumpPageCubit(),
          child: MaterialApp(
            home: Scaffold(
              body: PostList(
                threadID: '1',
                postList: List.generate(30, (i) => _post(i + 1)),
                canLoadMore: false,
                scrollController: controller,
                latestModAct: null,
                title: 'title',
                useDivider: true,
                initialPostID: 30,
                widgetBuilder: (_, p) => SizedBox(height: 300, child: Text('post ${p.postID}')),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final position = controller.position;
        expect(position.pixels, lessThanOrEqualTo(position.maxScrollExtent), reason: 'frame $i: nothing past the end');
      }
      expect(find.text('post 30'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the floor asked for is shown', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        BlocProvider(
          create: (_) => JumpPageCubit(),
          child: MaterialApp(
            home: Scaffold(
              body: PostList(
                threadID: '1',
                postList: List.generate(30, (i) => _post(i + 1)),
                canLoadMore: false,
                scrollController: controller,
                latestModAct: null,
                title: 'title',
                useDivider: true,
                initialPostID: 25,
                widgetBuilder: (_, p) => SizedBox(height: 300, child: Text('post ${p.postID}')),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('post 25'), findsOneWidget);
      expect(tester.getTopLeft(find.text('post 25')).dy, closeTo(0, 2), reason: 'at the top of the viewport');
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('5. notify answered "too soon"', () {
    late _ApiAdapter api;
    late NetClientProvider client;

    setUp(() {
      api = _ApiAdapter();
      client = NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = api);
    });

    Map<String, dynamic> nothingNew() => {
      'ok': 1,
      'api': 1,
      'time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'uid': 31,
      'notices': <Object>[],
      'announces': <Object>[],
      'pms': <Object>[],
    };

    test('busy for a second: asked again after it, the pages are not read', () async {
      api.notify = [
        (429, {'ok': 0, 'error': 'busy', 'retry_after': 1}),
        (200, nothingNew()),
      ];
      final watch = Stopwatch()..start();
      final result = await NotificationRepository()
          .fetchNotificationWith(client, timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60)
          .run();
      watch.stop();
      expect(result.isRight(), isTrue);
      expect(api.paths, ['notify', 'notify'], reason: 'no notification page was read');
      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 1)), reason: 'the second asked was waited');
    });

    test('busy for longer: not waited, the pages are read as before', () async {
      api.notify = [
        (429, {'ok': 0, 'error': 'busy', 'retry_after': 3}),
      ];
      final answer = await TsdmAppApi.askWaitingBriefly(client, 'notify', {'since': '1'});
      expect(answer, isNull);
      expect(api.paths, ['notify'], reason: 'asked once');
    });

    test('busy twice: given up after one wait', () async {
      api.notify = [
        (429, {'ok': 0, 'error': 'busy', 'retry_after': 1}),
        (429, {'ok': 0, 'error': 'busy', 'retry_after': 1}),
        (200, nothingNew()),
      ];
      final answer = await TsdmAppApi.askWaitingBriefly(client, 'notify', {'since': '1'});
      expect(answer, isNull);
      expect(api.paths, ['notify', 'notify']);
    });
  });
}

/// The app API answering `notify` with [notify] in order; any other request (a notification page) is offline.
final class _ApiAdapter implements HttpClientAdapter {
  List<(int, Map<String, dynamic>)> notify = [];
  final paths = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancel) async {
    final q = options.uri.queryParameters;
    final action = q['action'];
    paths.add(action ?? options.uri.path);
    if (action == 'notify' && notify.isNotEmpty) {
      final (status, json) = notify.removeAt(0);
      return ResponseBody.fromString(
        jsonEncode(json),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json; charset=utf-8'],
        },
      );
    }
    throw DioException.connectionError(requestOptions: options, reason: 'offline');
  }

  @override
  void close({bool force = false}) {}
}

Post _post(int i) => Post(
  postID: '$i',
  postFloor: i,
  author: User(name: 'u$i', url: 'u'),
  publishTime: DateTime(2026, 10, 23),
  data: 'body $i',
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: 1,
  isDraft: false,
  packetAllTaken: false,
);

/// Stand-in for a reply page: its reply bar reports an unsent reply through [RouteDrafts], as the real bar does, and
/// it has the home button of the reply page.
class _ReplyPage extends StatefulWidget {
  const _ReplyPage(this.label);

  final String label;

  @override
  State<_ReplyPage> createState() => _ReplyPageState();
}

class _ReplyPageState extends State<_ReplyPage> {
  static final drafts = <String, bool>{};
  static final disposed = <String>[];

  Route<dynamic>? _route;

  bool _hasDraft() => drafts[widget.label] ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of(context);
    RouteDrafts.register(_route!, _hasDraft);
  }

  @override
  void dispose() {
    RouteDrafts.unregister(_route!, _hasDraft);
    disposed.add(widget.label);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(children: [Text(widget.label), const BackToHomeButton()]);
}
