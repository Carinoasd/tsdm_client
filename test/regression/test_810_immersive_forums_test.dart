/// Threads of chosen forums open in immersive reading (regression 810):
///
/// * [ImmersiveForums]: a forum picked matches its own threads, a forum picked with its subforums the threads of the
///   forums under it too, "all forums" every thread; the stored text round-trips;
/// * the setting is one the cross-device sync carries;
/// * the thread page opens with the app bar and the reply bar hidden when its forum (or a forum above it) is picked,
///   once only: a tap shows the bars and they stay; other forums open as before; the menu item picks the forum.
library;

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
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/widgets/immersive_forums_dialog.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/utils/immersive_forums.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread/v1/widgets/collapsing_app_bar.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
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
import 'package:tsdm_client/widgets/list_app_bar/list_app_bar.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 31);
const _tid = 1264975;

/// The forum: thread pages of 10 floors (3 pages) as web pages; records the pages asked.
final class _Forum implements HttpClientAdapter {
  final pages = <int>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final page = int.tryParse(options.uri.queryParameters['page'] ?? '') ?? 1;
    pages.add(page);
    return ResponseBody.fromString(
      _threadPage(page),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Every image request fails at once.
final class _NoImages implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

final class _Notifications extends Fake implements NotificationBloc {
  @override
  void add(NotificationEvent event) {}

  @override
  NotificationState get state => const NotificationState(status: NotificationStatus.success);

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

String _floor(int floor) {
  final pid = 9700000 + floor;
  return '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1000" class="xi2">Bob</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor text<br />${'line<br />' * 6}
</div></div></div>
<div class="pob"><em><a class="fastre" href="forum.php?mod=post&amp;action=reply&amp;fid=8&amp;tid=$_tid&amp;repquote=$pid">回复</a></em></div>
</td>
</tr></tbody></table></div>''';
}

/// Page [page] of 3, 10 floors each.
String _threadPage(int page) {
  final pager =
      '<div class="pg">${[
        for (var i = 1; i <= 3; i++) i == page ? '<strong>$i</strong>' : '<a href="forum.php?mod=viewthread&tid=$_tid&page=$i">$i</a>',
      ].join()}<label><input type="text" name="custompage"/><span title="共 3 页"> / 3 页</span></label></div>';
  return '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=$_tid" /></head><body>
<input name="srhfid" value="8" />
<div id="pt"><div class="z"><a href="forum.php">Home</a><a href="forum.php?gid=1">Group</a><a href="forum.php?mod=forumdisplay&fid=2">Parent</a><a href="forum.php?mod=forumdisplay&fid=8">Sub</a><a href="forum.php?mod=viewthread&tid=$_tid">Thread title</a></div></div>
$pager
<div id="postlist"><table><tr><td><span class="xi1">100</span><span class="xi1">29</span></td></tr></table>
<h1 class="ts"><span id="thread_subject">Thread title</span></h1><div class="bm">
${[for (var f = (page - 1) * 10 + 1; f <= page * 10; f++) _floor(f)].join('\n')}
</div></div>
</body></html>''';
}

void main() {
  group('ImmersiveForums', () {
    test('a forum picked matches its own threads only', () {
      final forums = ImmersiveForums.parse('8');
      expect(forums.matches(8), isTrue);
      expect(forums.matches(9), isFalse);
      expect(forums.matches(9, ancestors: [8]), isFalse);
      expect(forums.matches(null), isFalse);
    });

    test('a forum picked with its subforums matches the forums under it', () {
      final forums = ImmersiveForums.parse('2+');
      expect(forums.matches(2), isTrue);
      expect(forums.matches(8, ancestors: [2]), isTrue);
      expect(forums.matches(8, ancestors: [3]), isFalse);
      expect(forums.matches(8), isFalse, reason: 'without the forums above it nothing tells it is under forum 2');
    });

    test('all forums matches everything', () {
      expect(ImmersiveForums.parse('', all: true).matches(null), isTrue);
      expect(ImmersiveForums.parse('').matches(8), isFalse);
    });

    test('the stored text round-trips, entries that are no forum are dropped', () {
      final forums = ImmersiveForums.parse('34+, 12,x,-1,0,+,12+,5');
      expect(forums.raw, '5,12+,34+');
      expect(ImmersiveForums.parse(forums.raw), forums);
      expect(ImmersiveForums.parse('').raw, '');
    });

    test('withForum picks, moves between the two kinds and takes back', () {
      var forums = const ImmersiveForums().withForum(8, picked: true);
      expect(forums.raw, '8');
      forums = forums.withForum(8, picked: true, subforums: true);
      expect(forums.raw, '8+');
      forums = forums.withForum(3, picked: true);
      expect(forums.raw, '3,8+');
      forums = forums.withForum(8, picked: false);
      expect(forums.raw, '3');
    });

    test('breadcrumbForumIds keeps forums, not groups', () {
      expect(
        breadcrumbForumIds([
          Uri.parse('https://forum.test/forum.php?gid=1'),
          Uri.parse('https://forum.test/forum.php?mod=forumdisplay&fid=2'),
          Uri.parse('https://forum.test/forum.php?mod=forumdisplay&fid=8'),
        ]),
        [2, 8],
      );
    });
  });

  group('the picker dialog', () {
    testWidgets('lists the forums picked, takes them back and switches all forums on', (tester) async {
      await LocaleSettings.setLocale(AppLocale.zhCn);
      ImmersiveForums? result;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async => result = await showImmersiveForumsDialog(context, ImmersiveForums.parse('5,7+')),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      // No forum index (no repository): the picked forums are listed by id.
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('immersive-forum-5'))).value, isTrue);
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('immersive-forum-7'))).value, isTrue);

      await tester.tap(find.byKey(const ValueKey('immersive-forum-5')));
      await tester.tap(find.byKey(const ValueKey('immersive-all-forums')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(result?.all, isTrue);
      expect(result?.raw, '7+');
    });
  });

  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late _Forum forum;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('the thread page', () {
    setUp(() async {
      TsdmAppApi.reset();
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      forum = _Forum();
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
        )
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _NoImages())),
        );
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      ThreadAuthorCache.clear();
    });

    tearDown(() async {
      await settingsBloc.close();
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    /// Let the requests (real futures) and the frames they cause finish.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> pumpThread(WidgetTester tester) async {
      const user = _alice;
      final auth = AuthenticationRepository(user: user);
      final blocks = UserBlockRepository(storage);
      final info = NotificationInfoRepository();
      final counts = NotificationStateCubit(info);
      final history = ThreadVisitHistoryBloc(ThreadVisitHistoryRepo(storage));
      final cubit = UserBlockCubit(repository: blocks, currentUid: () => user.uid, authStatus: auth.status);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('the list')),
            routes: [
              GoRoute(
                path: 'thread',
                builder: (_, _) => const ThreadPage(
                  threadID: '$_tid',
                  findPostID: null,
                  pageNumber: '1',
                  overrideReverseOrder: true,
                  overrideWithExactOrder: null,
                ),
              ),
            ],
          ),
        ],
      );
      addTearDown(() async {
        router.dispose();
        await history.close();
        await cubit.close();
        await info.dispose();
        await counts.close();
        await blocks.dispose();
        await auth.dispose();
      });
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MultiRepositoryProvider(
              providers: [RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository())],
              child: MultiBlocProvider(
                providers: [
                  BlocProvider<SettingsBloc>.value(value: settingsBloc),
                  BlocProvider<ThreadVisitHistoryBloc>.value(value: history),
                  BlocProvider<UserBlockCubit>.value(value: cubit),
                  BlocProvider<NotificationBloc>.value(value: _Notifications()),
                  BlocProvider<NotificationStateCubit>.value(value: counts),
                ],
                child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
              ),
            ),
          ),
        ),
      );
      unawaited(router.push('/thread'));
      await settle(tester);
    }

    Future<void> leave(WidgetTester tester) async {
      await tester.binding.handlePopRoute();
      await settle(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    }

    Future<void> set<T>(WidgetTester tester, SettingsKeys<T> key, T value) async {
      await tester.runAsync(() => settings.setValue<T>(key, value));
      await tester.pump();
    }

    /// Shown part of the app bar.
    double appBarShown(WidgetTester tester) => tester.widget<CollapsingAppBar>(find.byType(CollapsingAppBar)).shown;

    /// Height of the reply bar (and the banner above it) on screen.
    double bottomBarsHeight(WidgetTester tester) =>
        tester.getSize(find.byKey(const ValueKey('thread-bottom-bars'))).height;

    final listTitle = find.descendant(of: find.byType(PostList), matching: find.text('Thread title'));
    Finder floorText(int floor) => find.textContaining('floor $floor text');

    testWidgets('the cross-device sync carries the immersive forums', (tester) async {
      await set(tester, SettingsKeys.immersiveForums, '2+,8');
      await set(tester, SettingsKeys.immersiveAllForums, true);
      final values = syncedSettingsValues(settings.currentSettings);
      expect(values['immersiveForums'], '2+,8');
      expect(values['immersiveAllForums'], true);
      final changes = syncedSettingsChanges({
        'immersiveForums': '3',
        'immersiveAllForums': false,
      }, settings.currentSettings);
      expect(
        changes.map((e) => (e.$1.name, e.$2)),
        containsAll([('immersiveForums', '3'), ('immersiveAllForums', false)]),
      );
    });

    final menuButton = find.descendant(
      of: find.byType(ListAppBar),
      matching: find.byWidgetPredicate((w) => w is PopupMenuButton),
    );

    group('opening in immersive reading', () {
      testWidgets('a forum above the thread picked with its subforums: the bars are hidden at once', (tester) async {
        await set(tester, SettingsKeys.immersiveForums, '2+');
        await pumpThread(tester);
        expect(find.byType(PostList), findsOneWidget);
        expect(appBarShown(tester), 0);
        expect(bottomBarsHeight(tester), 0);

        await tester.tap(floorText(1));
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 1, reason: 'a tap on the floors calls the bars back');
        expect(bottomBarsHeight(tester), greaterThan(0));
        await tester.tap(listTitle);
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 0, reason: 'and another one hides them again');
        await leave(tester);
      });

      testWidgets('the forum itself picked: hidden; a forum above picked without its subforums: shown', (tester) async {
        await set(tester, SettingsKeys.immersiveForums, '2');
        await pumpThread(tester);
        expect(appBarShown(tester), 1);
        expect(bottomBarsHeight(tester), greaterThan(0));
        await leave(tester);

        await set(tester, SettingsKeys.immersiveForums, '8');
        await pumpThread(tester);
        expect(appBarShown(tester), 0);
        await leave(tester);
      });

      testWidgets('all forums on: hidden; nothing picked: shown', (tester) async {
        await pumpThread(tester);
        expect(appBarShown(tester), 1);
        await leave(tester);

        await set(tester, SettingsKeys.immersiveAllForums, true);
        await pumpThread(tester);
        expect(appBarShown(tester), 0);
        expect(bottomBarsHeight(tester), 0);
        await leave(tester);
      });

      testWidgets('the bars called back stay when the thread loads again', (tester) async {
        await set(tester, SettingsKeys.immersiveForums, '8');
        await pumpThread(tester);
        expect(appBarShown(tester), 0);
        await tester.tap(floorText(1));
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 1);

        tester.element(find.byType(PostList)).read<ThreadBloc>().add(ThreadRefreshRequested());
        await settle(tester);
        expect(appBarShown(tester), 1, reason: 'checked once per opening');
        await leave(tester);
      });

      testWidgets('the menu item picks the forum of the thread and takes it back', (tester) async {
        await pumpThread(tester);
        expect(settings.currentSettings.immersiveForums, '');
        await tester.tap(menuButton);
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
        await tester.tap(find.text('预设沉浸此版块'));
        await settle(tester);
        expect(settingsBloc.state.settingsMap.immersiveForums, '8');

        await tester.tap(menuButton);
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.check_box_outlined), findsOneWidget);
        await tester.tap(find.text('预设沉浸此版块'));
        await settle(tester);
        expect(settingsBloc.state.settingsMap.immersiveForums, '');
        await leave(tester);
      });
    });
  });
}
