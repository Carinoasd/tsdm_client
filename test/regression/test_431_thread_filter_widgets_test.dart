/// Keyword and forum filters on the real cards and the management page: a forum row hides by keyword only (the
/// user opened that forum), a search result and a latest thread row by keyword and by forum, the homepage pinned rows
/// by keyword, nothing in place of a hidden row; the page adds and removes keywords and forums as chips.
///
/// All pages are synthetic (grounded in the Discuz templates), no real account or network.
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
import 'package:tsdm_client/features/authentication/repository/models/models.dart' show AuthStatus;
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/blocking/view/user_block_page.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/widgets/widgets.dart';
import 'package:tsdm_client/features/latest_thread/models/latest_thread.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
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
import 'package:universal_html/parsing.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

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

/// Never answers: avatars are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

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

  Future<UserBlockCubit> pump(WidgetTester tester, Widget child) async {
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
          providers: [RepositoryProvider<AuthenticationRepository>.value(value: auth)],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>.value(value: settingsBloc),
              BlocProvider<UserBlockCubit>.value(value: cubit),
              BlocProvider<NotificationBloc>.value(value: _Notifications()),
              BlocProvider<NotificationStateCubit>.value(value: counts),
            ],
            child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
          ),
        ),
      ),
    );
    await settle(tester);
    return cubit;
  }

  bool shows(String text) => find.textContaining(text, findRichText: true).evaluate().isNotEmpty;

  const author = User(name: 'Carol', url: '$baseUrl/home.php?mod=space&uid=1002', uid: '1002');

  NormalThread forumRow(String tid, String title) => NormalThread(
    title: title,
    url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
    threadID: tid,
    author: author,
    publishDate: DateTime(2026, 9),
    latestReplyAuthor: author,
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

  SearchedThread searchRow(int tid, String title, int fid) => SearchedThread(
    tid: tid,
    title: title,
    url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
    author: author,
    publishTime: DateTime(2026, 9),
    forumName: 'Board $fid',
    forumUrl: '$baseUrl/forum.php?mod=forumdisplay&fid=$fid',
  );

  LatestThread latestRow(int tid, String title, int fid) {
    final doc = parseHtmlDocument('''
<table><tbody id="normalthread_$tid"><tr>
<td class="icn"></td>
<th class="common"><a href="forum.php?mod=viewthread&tid=$tid&extra=" class="xst">$title</a></th>
<td class="by"><a href="forum.php?mod=forumdisplay&fid=$fid" target="_blank">Board $fid</a></td>
<td class="by"><cite><a href="home.php?mod=space&uid=1002">Carol</a></cite><em><span>2026-9-4</span></em></td>
<td class="num"><a class="xi2">11</a><em>76</em></td>
<td class="by"><cite><a href="home.php?mod=space&username=Carol">Carol</a></cite><em><a><span title="2026-9-4 20:25">29 分钟前</span></a></em></td>
</tr></tbody></table>''');
    final row = LatestThread.fromTBody(doc.querySelector('tbody')!);
    expect(row.isValid, isTrue);
    return row;
  }

  testWidgets('a forum row hides by keyword only, never by its own forum', (tester) async {
    await tester.runAsync(() async {
      await blocks.addKeyword(ownerUid: _alice.uid, text: 'spoiler');
      await blocks.setForums(ownerUid: _alice.uid, forums: {8: 'Board 8'});
    });
    await pump(
      tester,
      Scaffold(
        body: ListView(
          children: [
            NormalThreadCard(forumRow('11', 'Big SPOILER here')),
            NormalThreadCard(forumRow('12', 'Plain topic')),
          ],
        ),
      ),
    );
    expect(shows('Big SPOILER here'), isFalse);
    expect(shows('Plain topic'), isTrue);
  });

  testWidgets('search results and latest rows hide by keyword and by forum, and show again when removed', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await blocks.addKeyword(ownerUid: _alice.uid, text: '劇透');
      await blocks.setForums(ownerUid: _alice.uid, forums: {8: 'Board 8'});
    });
    final cubit = await pump(
      tester,
      Scaffold(
        body: ListView(
          children: [
            SearchedThreadCard(searchRow(21, 'Found in eight', 8)),
            SearchedThreadCard(searchRow(22, '【劇透】found', 9)),
            SearchedThreadCard(searchRow(23, '【剧透】found', 9)),
            LatestThreadCard(latestRow(31, 'Latest in eight', 8)),
            LatestThreadCard(latestRow(32, 'Latest in nine', 9)),
          ],
        ),
      ),
    );
    expect(shows('Found in eight'), isFalse);
    expect(shows('【劇透】found'), isFalse);
    expect(shows('【剧透】found'), isTrue, reason: 'Simplified and Traditional are not converted');
    expect(shows('Latest in eight'), isFalse);
    expect(shows('Latest in nine'), isTrue);

    await tester.runAsync(() => cubit.setForums(const {}, expectedOwner: _alice.uid));
    await settle(tester);
    expect(shows('Found in eight'), isTrue);
    expect(shows('Latest in eight'), isTrue);
  });

  testWidgets('a pinned homepage row is left out by keyword', (tester) async {
    await tester.runAsync(() => blocks.addKeyword(ownerUid: _alice.uid, text: 'ad'));
    PinnedThread row(int tid, String title) => PinnedThread(
      threadUrl: 'forum.php?mod=viewthread&amp;tid=$tid',
      threadTitle: title,
      authorUrl: 'home.php?mod=space&amp;uid=1002',
      authorName: 'Carol',
    );
    await pump(
      tester,
      Scaffold(
        body: PinnedThreadList(
          PinnedThreadGroup(title: 'Hot', threadList: [row(41, 'An AD row'), row(42, 'A plain row')]),
        ),
      ),
    );
    expect(shows('An AD row'), isFalse);
    expect(shows('A plain row'), isTrue);
  });

  group('management page', () {
    Future<void> scrollTo(WidgetTester tester, Finder target) async {
      final list = find.descendant(of: find.byType(UserBlockPage), matching: find.byType(ListView));
      await tester.scrollUntilVisible(
        target,
        200,
        scrollable: find.descendant(of: list, matching: find.byType(Scrollable)),
      );
      await tester.pumpAndSettle();
    }

    Future<void> addKeyword(WidgetTester tester, String text, {bool submit = false}) async {
      final add = find.byKey(const ValueKey('thread-filter-keyword-add'));
      await scrollTo(tester, add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('thread-filter-keyword-field')), text);
      await tester.pump();
      if (submit) {
        await tester.testTextInput.receiveAction(TextInputAction.done);
      } else {
        await tester.tap(find.byKey(const ValueKey('thread-filter-keyword-confirm')));
      }
      await settle(tester);
      await tester.pumpAndSettle();
    }

    testWidgets('a keyword is added in the dialog and removed from its chip', (tester) async {
      await pump(tester, const UserBlockPage());
      await addKeyword(tester, '  Spoiler ');
      expect(find.byKey(const ValueKey('thread-filter-keyword-spoiler')), findsOneWidget);
      // The same keyword in another case is not added twice.
      await addKeyword(tester, 'SPOILER', submit: true);
      expect(find.byType(InputChip), findsOneWidget);
      expect(find.text(tr.userBlock.filter.keywordExists), findsOneWidget);
      expect((await tester.runAsync(() => blocks.load(_alice.uid)))!.filters.keywordKeys, ['spoiler']);

      final chip = find.byKey(const ValueKey('thread-filter-keyword-spoiler'));
      await scrollTo(tester, chip);
      await tester.tap(find.descendant(of: chip, matching: find.byIcon(Icons.clear)));
      await settle(tester);
      expect(chip, findsNothing);
      expect((await tester.runAsync(() => blocks.load(_alice.uid)))!.filters.keywordKeys, isEmpty);
    });

    testWidgets('a blank keyword can not be confirmed', (tester) async {
      await pump(tester, const UserBlockPage());
      final add = find.byKey(const ValueKey('thread-filter-keyword-add'));
      await scrollTo(tester, add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('thread-filter-keyword-field')), '   ');
      await tester.pump();
      final confirm = tester.widget<FilledButton>(find.byKey(const ValueKey('thread-filter-keyword-confirm')));
      expect(confirm.onPressed, isNull);
    });

    testWidgets('the forums show as chips, one removed from its chip', (tester) async {
      await tester.runAsync(() => blocks.setForums(ownerUid: _alice.uid, forums: {8: 'Board 8', 9: 'Board 9'}));
      await pump(tester, const UserBlockPage());
      final chip = find.byKey(const ValueKey('thread-filter-forum-8'));
      await scrollTo(tester, chip);
      expect(find.byKey(const ValueKey('thread-filter-forum-9')), findsOneWidget);
      await tester.tap(find.descendant(of: chip, matching: find.byIcon(Icons.clear)));
      await settle(tester);
      expect(chip, findsNothing);
      expect((await tester.runAsync(() => blocks.load(_alice.uid)))!.filters.forumIds, {9});
    });
  });
}

Translations get tr => LocaleSettings.instance.currentTranslations;

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}
