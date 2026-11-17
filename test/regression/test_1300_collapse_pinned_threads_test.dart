import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' show right;
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/forum/bloc/forum_bloc.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_api.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/forum/utils/pinned_fold.dart';
import 'package:tsdm_client/features/forum/view/forum_page.dart';
import 'package:tsdm_client/features/forum/widgets/pinned_threads_fold.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/thread_picking.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
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
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';

/// N3 (11/17): with the setting 折叠置顶帖 (off by default: the pinned threads only show in the pinned tab, as before),
/// the pinned threads of a forum's first page (global, in type, in forum) are folded to one row 「置顶帖 N」 above the
/// thread list; a tap expands them as the first threads of the list, another collapses them. Each forum remembers on
/// the device whether it was left expanded, and the pinned threads seen last: one not seen before expands them this
/// time. Only the list's first page has them (a jump to another page shows none); a refresh and another filter or
/// order keep the section as it was, a filtered first page (the forum then only lists its own pinned threads matching
/// the filter) never counts the others as gone. A moderator picks the pinned threads while they are expanded.
///
/// Fake data only (the forum's app API answers built here), no network.
const _fid = 25;
const _moderator = 31;

/// The pinned threads of the forum's first page: global, in type, in forum.
const _pinned = [9001, 9002, 9003];

/// The forum's own pinned thread, the only one a filtered first page lists.
const _ownPinned = 9003;

const _normal = [101, 102, 103, 104];
const _normalPage2 = [201, 202];

/// No network in tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The forum page asked by `ModerateRepository.network()`: account [_moderator] moderates the forum; anything else
/// fails.
final class _ModeratorAdapter implements HttpClientAdapter {
  final asked = <Uri>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    asked.add(options.uri);
    if (options.uri.queryParameters['mod'] == 'forumdisplay' && options.uri.queryParameters['fid'] == '$_fid') {
      return Future.value(
        ResponseBody.fromString(
          jsonEncode({
            'ok': 1,
            'api': 1,
            'uid': _moderator,
            'type': 'forum',
            'schema': 2,
            'forum': {'fid': _fid, 'name': 'Forum', 'ismoderator': 1},
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json; charset=utf-8'],
          },
        ),
      );
    }
    throw DioException.connectionError(requestOptions: options, reason: 'offline');
  }

  @override
  void close({bool force = false}) {}
}

/// The account in use is [uid].
final class _Auth extends AuthenticationRepository {
  _Auth(this.uid);

  final int? uid;
  final _statuses = StreamController<AuthStatus>.broadcast();

  @override
  int? get effectiveCurrentUid => uid;

  @override
  Stream<AuthStatus> get status => _statuses.stream;

  @override
  Future<void> dispose() async {
    await _statuses.close();
  }
}

/// Author of the pinned threads but [_ownPinned].
const _pinnedAuthor = 1002;

/// Author of [_ownPinned].
const _newPinnedAuthor = 1003;

(int, String) _authorOf(int tid) => switch (tid) {
  _ownPinned => (_newPinnedAuthor, 'Dave'),
  _ when _pinned.contains(tid) || tid == 9004 => (_pinnedAuthor, 'Carol'),
  _ => (1000, 'Alice'),
};

String _title(int tid) => _pinned.contains(tid) || tid == 9004 ? 'Pinned $tid' : 'Thread $tid';

Map<String, dynamic> _row(int tid, {int displayorder = 0}) => {
  'tid': tid,
  'fid': _fid,
  'subject': _title(tid),
  // The pinned threads by their own authors: [_pinnedAuthor], [_newPinnedAuthor] for the last one.
  'author': _authorOf(tid).$2,
  'authorid': _authorOf(tid).$1,
  'dateline': 1700000000,
  'lastpost': 1700000000,
  'lastposter': 'Bob',
  'lastposterid': 1001,
  'replies': 1,
  'views': 10,
  'displayorder': displayorder,
};

/// The forum's answer of page [page]: [pinned] (in the forum's order, global first) and [normal] threads.
Map<String, dynamic> _answer({required List<int> pinned, required List<int> normal, int page = 1}) => {
  'ok': 1,
  'api': 1,
  'uid': 0,
  'type': 'forum',
  'schema': 2,
  'page': page,
  // One page: a tall window would ask the next one by itself.
  'pages': page,
  'forum': {'fid': _fid, 'name': 'Forum'},
  'threads': [
    for (final (i, tid) in pinned.indexed) _row(tid, displayorder: tid == _ownPinned ? 1 : (i == 0 ? 3 : 2)),
    for (final tid in normal) _row(tid),
  ],
};

/// The forum: its pinned threads now are [pinned]; a filtered first page lists only its own ([_ownPinned]), the
/// second page none.
final class _Forum implements ForumRepository {
  List<int> pinned = _pinned;
  final asked = <(int, FilterState)>[];

  @override
  AsyncEither<ForumPageData> fetchForum({required String fid, required FilterState filterState, int pageNumber = 1}) {
    asked.add((pageNumber, filterState));
    final answer = switch ((pageNumber, filterState.isFiltering())) {
      (1, false) => _answer(pinned: pinned, normal: _normal),
      (1, true) => _answer(pinned: [if (pinned.contains(_ownPinned)) _ownPinned], normal: _normal.take(2).toList()),
      _ => _answer(pinned: const [], normal: _normalPage2, page: pageNumber),
    };
    return AsyncEither(() async => right(forumPageFromApi(answer, fid)));
  }

  @override
  AsyncEither<ForumGroup?> fetchForumGroup(String gid) => throw UnimplementedError();
}

/// The page of every pinned thread of [_pinned] and every thread of [_normal], as the forum answers it.
ForumPageData _page({List<int> pinned = _pinned, List<int> normal = _normal, int page = 1}) =>
    forumPageFromApi(_answer(pinned: pinned, normal: normal, page: page), '$_fid');

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('what seeing the pinned threads tells', () {
    test('the first time without a filter: they are seen, none is fresh, the section stays as it is', () {
      final seen = pinnedFoldSeen(null, _pinned, filtered: false);
      expect(seen.fresh, isFalse);
      expect(seen.save, const PinnedFold(seen: {9001, 9002, 9003}));
      // Left open before anything was seen: still open.
      final open = pinnedFoldSeen(const PinnedFold(open: true), _pinned, filtered: false);
      expect(open.save, const PinnedFold(open: true, seen: {9001, 9002, 9003}));
    });

    test('a filtered first time learns nothing: it lacks the pinned threads of the other forums', () {
      expect(pinnedFoldSeen(null, const [_ownPinned], filtered: true), (fresh: false, save: null));
    });

    test('the same pinned threads: nothing changes, nothing is saved', () {
      const saved = PinnedFold(seen: {9001, 9002, 9003});
      expect(pinnedFoldSeen(saved, const [9003, 9001, 9002], filtered: false), (fresh: false, save: null));
    });

    test('a pinned thread not seen before is fresh; the ones gone are dropped', () {
      const saved = PinnedFold(seen: {9001, 9002, 9003});
      final seen = pinnedFoldSeen(saved, const [9001, 9003, 9004], filtered: false);
      expect(seen.fresh, isTrue);
      expect(seen.save, const PinnedFold(seen: {9001, 9003, 9004}));
    });

    test('only some gone: not fresh, the ones left are seen', () {
      final seen = pinnedFoldSeen(const PinnedFold(open: true, seen: {9001, 9002, 9003}), const [
        9001,
      ], filtered: false);
      expect(seen.fresh, isFalse);
      expect(seen.save, const PinnedFold(open: true, seen: {9001}));
    });

    test('a filtered first page never counts the others as gone, a pinned thread not seen before is fresh', () {
      const saved = PinnedFold(seen: {9001, 9002, 9003});
      expect(pinnedFoldSeen(saved, const [_ownPinned], filtered: true), (fresh: false, save: null));
      final seen = pinnedFoldSeen(saved, const [_ownPinned, 9005], filtered: true);
      expect(seen.fresh, isTrue);
      expect(seen.save, const PinnedFold(seen: {9001, 9002, 9003, 9005}));
    });

    test('a list without pinned threads (another page) learns nothing', () {
      expect(pinnedFoldSeen(null, const [], filtered: false), (fresh: false, save: null));
      expect(pinnedFoldSeen(const PinnedFold(seen: {9001}), const [], filtered: false), (fresh: false, save: null));
    });
  });

  group('the saved sections', () {
    test('read back as saved, the latest forum last', () {
      final folds = pinnedFoldsWith(
        {
          1: const PinnedFold(open: true, seen: {11, 12}),
          2: const PinnedFold(),
        },
        1,
        const PinnedFold(seen: {13}),
      );
      expect(folds.keys, [2, 1]);
      final raw = encodePinnedFolds(folds);
      expect(jsonDecode(raw), {
        '2': <String, Object>{},
        '1': {
          'seen': [13],
        },
      });
      expect(decodePinnedFolds(raw), folds);
    });

    test('anything else reads as nothing; the forums and the pinned threads kept are capped', () {
      expect(decodePinnedFolds(''), isEmpty);
      expect(decodePinnedFolds('{not json'), isEmpty);
      expect(decodePinnedFolds('[1, 2]'), isEmpty);
      expect(
        decodePinnedFolds(
          jsonEncode({
            'x': {'open': 1},
            '-3': {'open': 1},
            '4': 'open',
            '5': {
              'open': true,
              'seen': [1, 'a', -2, 3.5, 7],
            },
          }),
        ),
        {
          5: const PinnedFold(seen: {1, 7}),
        },
      );
      var folds = <int, PinnedFold>{};
      for (var fid = 1; fid <= pinnedFoldForumsMax + 5; fid++) {
        folds = pinnedFoldsWith(folds, fid, const PinnedFold(open: true));
      }
      expect(folds.length, pinnedFoldForumsMax);
      expect(folds.keys.first, 6, reason: 'the oldest forums dropped');
      final many = jsonEncode({
        '1': {'seen': List.generate(pinnedFoldSeenMax + 10, (i) => i + 1)},
      });
      expect(decodePinnedFolds(many)[1]!.seen, hasLength(pinnedFoldSeenMax));
    });

    test('the switch goes with the cross-device sync, the sections stay on the device', () {
      final names = {for (final s in syncedSettings) s.key.name};
      expect(names, contains(SettingsKeys.collapsePinnedThreads.name));
      expect(syncedSettingsAddedLater, contains(SettingsKeys.collapsePinnedThreads.name));
      expect(names, isNot(contains(SettingsKeys.pinnedThreadsFold.name)));
      expect(SettingsKeys.collapsePinnedThreads.defaultValue, isFalse);
    });
  });

  group('the pinned threads above the list', () {
    final forum = _Forum();
    ForumBloc bloc() => ForumBloc(fid: '$_fid', forumRepository: forum);

    Future<ForumState> settle(ForumBloc bloc, ForumEvent event) async {
      bloc.add(event);
      return bloc.stream.firstWhere((s) => s.status == ForumStatus.success && !s.loadingMore && !s.refreshing);
    }

    List<String> ids(List<NormalThread> threads) => [for (final e in threads) e.threadID];

    test('those of the first page: kept while more pages come, none when the list starts at another page', () async {
      final b = bloc();
      addTearDown(b.close);
      var state = await settle(b, const ForumLoadMoreRequested(1));
      expect(ids(state.listStickThreadList), ['9001', '9002', '9003']);
      expect(ids(state.normalThreadList), ['101', '102', '103', '104']);

      state = await settle(b, const ForumLoadMoreRequested(2));
      expect(ids(state.listStickThreadList), ['9001', '9002', '9003']);
      expect(ids(state.normalThreadList), ['101', '102', '103', '104', '201', '202']);

      state = await settle(b, const ForumJumpPageRequested(2));
      expect(state.listStickThreadList, isEmpty);
      // The pinned tab keeps them.
      expect(ids(state.stickThreadList), ['9001', '9002', '9003']);

      state = await settle(b, ForumRefreshRequested());
      expect(ids(state.listStickThreadList), ['9001', '9002', '9003']);
    });

    test('a filter: the forum own ones matching it, none when it has none', () async {
      final b = bloc();
      addTearDown(b.close);
      await settle(b, const ForumLoadMoreRequested(1));
      const ordered = FilterState(
        filter: 'orderby',
        filterOrder: FilterOrder(name: '发帖时间', orderBy: 'dateline'),
      );
      var state = await settle(b, const ForumChangeThreadFilterStateRequested(ordered));
      expect(ids(state.listStickThreadList), ['9003']);

      forum.pinned = const [9001, 9002];
      addTearDown(() => forum.pinned = _pinned);
      state = await settle(b, ForumRefreshRequested());
      expect(state.listStickThreadList, isEmpty);
      // The pinned tab keeps the ones it had.
      expect(ids(state.stickThreadList), ['9003']);
    });

    test('a later page with pinned threads (more of them than a page holds) adds the ones not listed yet', () async {
      final b = ForumBloc(
        fid: '$_fid',
        forumRepository: _Pages({
          1: _page(pinned: const [9001, 9002], normal: const [101]),
          2: _page(pinned: const [9002, 9003], normal: const [201], page: 2),
        }),
      );
      addTearDown(b.close);
      var state = await settle(b, const ForumLoadMoreRequested(1));
      expect(ids(state.listStickThreadList), ['9001', '9002']);
      state = await settle(b, const ForumLoadMoreRequested(2));
      expect(ids(state.listStickThreadList), ['9001', '9002', '9003']);
      expect(ids(state.normalThreadList), ['101', '201']);
    });
  });

  group('forum page', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late _Forum forum;
    late _ModeratorAdapter moderatorAdapter;

    setUp(() async {
      ModerateRepository.resetModeratorCache();
      forum = _Forum();
      moderatorAdapter = _ModeratorAdapter();
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = moderatorAdapter),
        )
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      // The list alone, without the detail pane of the wide windows.
      await settings.setValue(SettingsKeys.twoPaneLayout, false);
      await settings.setValue(SettingsKeys.collapsePinnedThreads, true);
    });
    tearDown(() async {
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    /// `pumpAndSettle` never returns while a refresh indicator animates; the saves go to the database meanwhile.
    Future<void> pumpFrames(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }

    Future<void> pumpPage(WidgetTester tester, {int? uid, List<int> blocked = const []}) async {
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final auth = _Auth(uid);
      addTearDown(auth.dispose);
      final storage = getIt.get<StorageProvider>();
      for (final b in blocked) {
        await tester.runAsync(() => UserBlockRepository(storage).block(ownerUid: uid, uid: b, username: 'u$b'));
      }
      final blocks = UserBlockCubit(
        repository: UserBlockRepository(storage),
        currentUid: () => auth.uid,
        authStatus: auth.status,
      );
      addTearDown(blocks.close);
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && !blocks.state.isKnown; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const ForumPage(fid: '$_fid'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<ForumRepository>.value(value: forum),
              RepositoryProvider<AuthenticationRepository>.value(value: auth),
              RepositoryProvider<FragmentsRepository>(create: (_) => FragmentsRepository()),
              RepositoryProvider<NotificationRepository>(create: (_) => NotificationRepository()),
              RepositoryProvider<NotificationInfoRepository>(create: (_) => NotificationInfoRepository()),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<UserBlockCubit>.value(value: blocks),
                BlocProvider<SettingsBloc>(
                  create: (ctx) => SettingsBloc(
                    settingsRepository: settings,
                    fragmentsRepository: RepositoryProvider.of<FragmentsRepository>(ctx),
                  ),
                ),
                BlocProvider<NotificationStateCubit>(
                  create: (ctx) => NotificationStateCubit(RepositoryProvider.of<NotificationInfoRepository>(ctx)),
                ),
                BlocProvider<NotificationBloc>(
                  create: (ctx) => NotificationBloc(
                    notificationRepository: RepositoryProvider.of<NotificationRepository>(ctx),
                    infoRepository: RepositoryProvider.of<NotificationInfoRepository>(ctx),
                    authRepo: auth,
                    storageProvider: getIt.get<StorageProvider>(),
                  ),
                ),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          ),
        ),
      );
      await pumpFrames(tester);
    }

    /// Close the page (another route), so the next [pumpPage] opens the forum again.
    Future<void> closePage(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await pumpFrames(tester);
    }

    Finder threadList() => find.byType(CustomScrollView);
    Finder card(int tid) => find.descendant(of: threadList(), matching: find.text(_title(tid)));
    Finder fold() => find.byKey(pinnedThreadsFoldKey);
    String foldText(WidgetTester tester) =>
        tester.widget<Text>(find.descendant(of: fold(), matching: find.byType(Text))).data!;
    ForumBloc forumBloc(WidgetTester tester) => BlocProvider.of<ForumBloc>(tester.element(find.byType(TabBarView)));
    PinnedFold? saved() => decodePinnedFolds(settings.currentSettings.pinnedThreadsFold)[_fid];

    /// The titles of the thread tab's cards, top to bottom.
    List<String> titles(WidgetTester tester) {
      final cards = tester.widgetList<NormalThreadCard>(
        find.descendant(of: threadList(), matching: find.byType(NormalThreadCard)),
      );
      return [for (final c in cards) c.thread.title];
    }

    testWidgets('off: the thread tab is as before, nothing is saved', (tester) async {
      await settings.setValue(SettingsKeys.collapsePinnedThreads, false);
      await pumpPage(tester);
      expect(fold(), findsNothing);
      expect(titles(tester), ['Thread 101', 'Thread 102', 'Thread 103', 'Thread 104']);
      expect(settings.currentSettings.pinnedThreadsFold, isEmpty);

      // The pinned tab still holds them.
      await tester.tap(find.text('置顶'));
      await pumpFrames(tester);
      expect(find.text('Pinned 9001'), findsOneWidget);
    });

    testWidgets('on: one row above the list; a tap expands them as the first threads, another collapses them', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(fold(), findsOneWidget);
      expect(foldText(tester), '置顶帖 3');
      expect(titles(tester), ['Thread 101', 'Thread 102', 'Thread 103', 'Thread 104']);
      // The first visit: they are seen, the section stays collapsed.
      expect(saved(), const PinnedFold(seen: {9001, 9002, 9003}));
      // The row is above the list.
      expect(tester.getTopLeft(fold()).dy, lessThan(tester.getTopLeft(card(101)).dy));

      await tester.tap(fold());
      await pumpFrames(tester);
      expect(titles(tester), [
        'Pinned 9001',
        'Pinned 9002',
        'Pinned 9003',
        'Thread 101',
        'Thread 102',
        'Thread 103',
        'Thread 104',
      ]);
      expect(tester.getTopLeft(fold()).dy, lessThan(tester.getTopLeft(card(9001)).dy));
      expect(saved(), const PinnedFold(open: true, seen: {9001, 9002, 9003}));

      await tester.tap(fold());
      await pumpFrames(tester);
      expect(titles(tester), ['Thread 101', 'Thread 102', 'Thread 103', 'Thread 104']);
      expect(saved(), const PinnedFold(seen: {9001, 9002, 9003}));
    });

    testWidgets('each forum opens as it was left', (tester) async {
      await settings.setValue(
        SettingsKeys.pinnedThreadsFold,
        encodePinnedFolds({
          7: const PinnedFold(seen: {9001}),
          _fid: const PinnedFold(open: true, seen: {9001, 9002, 9003}),
        }),
      );
      await pumpPage(tester);
      expect(titles(tester).take(3), ['Pinned 9001', 'Pinned 9002', 'Pinned 9003']);
      await tester.tap(fold());
      await pumpFrames(tester);
      await closePage(tester);

      await pumpPage(tester);
      expect(titles(tester).first, 'Thread 101');
      // The other forum's section is untouched.
      expect(decodePinnedFolds(settings.currentSettings.pinnedThreadsFold)[7], const PinnedFold(seen: {9001}));
    });

    testWidgets('a pinned thread not seen before expands them this time only', (tester) async {
      await settings.setValue(
        SettingsKeys.pinnedThreadsFold,
        encodePinnedFolds({
          _fid: const PinnedFold(seen: {9001, 9002}),
        }),
      );
      await pumpPage(tester);
      expect(foldText(tester), '置顶帖 3');
      expect(titles(tester).take(3), ['Pinned 9001', 'Pinned 9002', 'Pinned 9003']);
      expect(saved(), const PinnedFold(seen: {9001, 9002, 9003}), reason: 'left collapsed, the new one seen');

      // Still expanded after a refresh.
      forumBloc(tester).add(ForumRefreshRequested());
      await pumpFrames(tester);
      expect(titles(tester).first, 'Pinned 9001');

      await closePage(tester);
      await pumpPage(tester);
      expect(titles(tester).first, 'Thread 101');

      // Another one pinned while the page is open: seen at the refresh.
      forum.pinned = const [9001, 9002, 9003, 9004];
      forumBloc(tester).add(ForumRefreshRequested());
      await pumpFrames(tester);
      expect(foldText(tester), '置顶帖 4');
      expect(titles(tester).take(4), ['Pinned 9001', 'Pinned 9002', 'Pinned 9003', 'Pinned 9004']);
      expect(saved(), const PinnedFold(seen: {9001, 9002, 9003, 9004}));
    });

    testWidgets('a refresh keeps it; another page has none; a filter shows the forum own ones and changes nothing', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.tap(fold());
      await pumpFrames(tester);
      final bloc = forumBloc(tester)..add(ForumRefreshRequested());
      await pumpFrames(tester);
      expect(foldText(tester), '置顶帖 3');
      expect(titles(tester).first, 'Pinned 9001');

      bloc.add(const ForumJumpPageRequested(2));
      await pumpFrames(tester);
      expect(fold(), findsNothing);
      expect(titles(tester), ['Thread 201', 'Thread 202']);

      bloc.add(const ForumJumpPageRequested(1));
      await pumpFrames(tester);
      expect(foldText(tester), '置顶帖 3');
      expect(titles(tester).first, 'Pinned 9001');

      bloc.add(
        const ForumChangeThreadFilterStateRequested(
          FilterState(
            filter: 'orderby',
            filterOrder: FilterOrder(name: '发帖时间', orderBy: 'dateline'),
          ),
        ),
      );
      await pumpFrames(tester);
      expect(foldText(tester), '置顶帖 1');
      expect(titles(tester), ['Pinned 9003', 'Thread 101', 'Thread 102']);
      expect(saved(), const PinnedFold(open: true, seen: {9001, 9002, 9003}));

      bloc.add(const ForumChangeThreadFilterStateRequested(FilterState()));
      await pumpFrames(tester);
      expect(foldText(tester), '置顶帖 3');
      expect(titles(tester).take(3), ['Pinned 9001', 'Pinned 9002', 'Pinned 9003']);
      expect(saved(), const PinnedFold(open: true, seen: {9001, 9002, 9003}));
    });

    testWidgets('pinned threads hidden (blocked authors) are neither counted nor in the list', (tester) async {
      await settings.setValue(
        SettingsKeys.pinnedThreadsFold,
        encodePinnedFolds({
          _fid: const PinnedFold(open: true, seen: {9001, 9002, 9003}),
        }),
      );
      await pumpPage(tester, uid: 35, blocked: const [_pinnedAuthor, _newPinnedAuthor]);
      expect(fold(), findsNothing);
      // The hidden ones are not in the list either (a card hiding itself would still be one of its items).
      expect(titles(tester), ['Thread 101', 'Thread 102', 'Thread 103', 'Thread 104']);
    });

    testWidgets('a fresh pinned thread hidden (blocked author) does not expand them, it is seen', (tester) async {
      await settings.setValue(
        SettingsKeys.pinnedThreadsFold,
        encodePinnedFolds({
          _fid: const PinnedFold(seen: {9001, 9002}),
        }),
      );
      await pumpPage(tester, uid: 35, blocked: const [_newPinnedAuthor]);
      expect(foldText(tester), '置顶帖 2');
      expect(titles(tester).first, 'Thread 101');
      expect(saved(), const PinnedFold(seen: {9001, 9002, 9003}));
      // Expanded: the ones shown, the hidden one not among them.
      await tester.tap(fold());
      await pumpFrames(tester);
      expect(titles(tester).take(3), ['Pinned 9001', 'Pinned 9002', 'Thread 101']);
    });

    testWidgets('turned on while the forum is open: its pinned threads are seen at once', (tester) async {
      await settings.setValue(SettingsKeys.collapsePinnedThreads, false);
      await pumpPage(tester);
      expect(fold(), findsNothing);

      await tester.runAsync(() => settings.setValue(SettingsKeys.collapsePinnedThreads, true));
      await pumpFrames(tester);
      expect(foldText(tester), '置顶帖 3');
      expect(saved(), const PinnedFold(seen: {9001, 9002, 9003}));
    });

    testWidgets('a moderator picks the pinned threads while they are expanded', (tester) async {
      await settings.setValue(SettingsKeys.loginUid, _moderator);
      await settings.setValue(
        SettingsKeys.pinnedThreadsFold,
        encodePinnedFolds({
          _fid: const PinnedFold(open: true, seen: {9001, 9002, 9003}),
        }),
      );
      await pumpPage(tester, uid: _moderator);
      expect(moderatorAdapter.asked.where((e) => e.queryParameters['fid'] == '$_fid'), isNotEmpty);

      // Picking starts from the card's menu (a long press on phones).
      await tester.tap(card(9002), buttons: kSecondaryButton);
      await pumpFrames(tester);
      await tester.tap(find.text(t.moderate.batch.select));
      await pumpFrames(tester);
      expect(find.byType(PickableThreadRow), findsNWidgets(7));
      expect(find.text(t.moderate.batch.selected(count: 1)), findsOneWidget);

      await tester.tap(find.byTooltip(t.moderate.batch.selectAll));
      await pumpFrames(tester);
      expect(find.text(t.moderate.batch.selected(count: 7)), findsOneWidget);

      // Collapsed: the pinned ones are left.
      await tester.tap(fold());
      await pumpFrames(tester);
      expect(find.byType(PickableThreadRow), findsNWidgets(4));
      expect(find.text(t.moderate.batch.selected(count: 4)), findsOneWidget);
    });
  });
}

/// Answers each page with the one given.
final class _Pages implements ForumRepository {
  _Pages(this.pages);

  final Map<int, ForumPageData> pages;

  @override
  AsyncEither<ForumPageData> fetchForum({required String fid, required FilterState filterState, int pageNumber = 1}) {
    final page = pages[pageNumber]!;
    return AsyncEither(() async => right(page));
  }

  @override
  AsyncEither<ForumGroup?> fetchForumGroup(String gid) => throw UnimplementedError();
}
