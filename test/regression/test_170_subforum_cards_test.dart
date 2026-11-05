import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/forum/view/forum_group_page.dart';
import 'package:tsdm_client/features/forum/view/forum_page.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
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
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/forum_card.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';
import 'package:universal_html/parsing.dart';

/// preview109 feedback: the sub forums tab of a forum and the forum group page (`gid`) still used the shared 960px
/// list width and compact 88x44 cards on desktop windows, while the topics page (test_169) already showed large cards.
/// Every forum list now shares [forumCardListLayout]: large cards in up to [forumCardListMaxWidth] once the page really
/// has [forumCardListLargeWidth] (measured inside the SafeArea) on a desktop platform. Phones must not use the desktop
/// size: Android keeps the compact cards at any width, a 1600 wide landscape included. Desktop cases run as Windows,
/// phone cases as Android.
///
/// The forum page opens its sub forums tab by itself when the forum has no thread; that switch used to run inside the
/// BlocBuilder and called setState during the build, so every forum page case here also covers it.
///
/// Fake data only: no forum icon and no network.
const _parentFid = '73';

/// Desktop window.
const _windows = TargetPlatformVariant({TargetPlatform.windows});

/// Phone.
const _android = TargetPlatformVariant({TargetPlatform.android});

/// No network in tests.
class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

String _row(int fid, String name) =>
    '<tr><td class="fl_icn"></td>'
    '<td><h2><a href="forum.php?mod=forumdisplay&amp;fid=$fid">$name</a></h2></td>'
    '<td class="fl_i"><span class="xi2">123456</span><span class="xg1"> / 9876543</span></td></tr>';

/// Forum [_parentFid] with no thread and [names] as sub forums fid 2000, 2001...
String _forumPage(List<String> names) =>
    '<html><body><div id="ct" class="wp cl"><div class="bm bml pbn"><div class="bm_h cl"><h1 class="xs2">'
    '<a href="forum.php?mod=forumdisplay&amp;fid=$_parentFid">原创绘图区</a></h1></div></div>'
    '<div class="bm bmw"><div id="subforum_$_parentFid" class="bm_c"><table class="fl_tb">'
    '${names.indexed.map((e) => _row(2000 + e.$1, e.$2)).join()}<tr class="fl_row"></tr>'
    '</table></div></div></div></body></html>';

/// Forum index with one group holding [names] as fid 2000, 2001...
String _groupPage(List<String> names) =>
    '<html><body><div id="ct"><div class="mn"><div class="fl bm"><div class="bm bmw  cl"><div class="bm_h cl">'
    '<h2><a href="forum.php?gid=1">天使·后花园</a></h2></div><div id="category_1" class="bm_c"><table class="fl_tb">'
    '${names.indexed.map((e) => _row(2000 + e.$1, e.$2)).join()}'
    '<tr class="fl_row"></tr></table></div></div></div></div></div></body></html>';

final class _FakeForumRepository implements ForumRepository {
  _FakeForumRepository(this.names);

  final List<String> Function() names;

  @override
  AsyncEither<ForumPageData> fetchForum({required String fid, required FilterState filterState, int pageNumber = 1}) =>
      AsyncEither(() async => right(parseForumPage(parseHtmlDocument(_forumPage(names())), fid)));

  @override
  AsyncEither<ForumGroup?> fetchForumGroup(String gid) =>
      AsyncEither(() async => right(buildGroupListFromDocument(parseHtmlDocument(_groupPage(names()))).firstOrNull));
}

enum _Page { subforums, group }

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  late AppDatabase db;
  late SettingsRepository settings;
  late AuthenticationRepository auth;
  var names = <String>[];

  setUp(() async {
    names = ['美术部', '音乐部', '文学部', '摄影部'];
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
    // The cards are measured across the whole window: without the detail pane the wide windows get (test 281).
    await settings.setValue(SettingsKeys.twoPaneLayout, false);
    auth = AuthenticationRepository();
  });
  tearDown(() async {
    await auth.dispose();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// `pumpAndSettle` never returns while a refresh indicator animates.
  Future<void> pumpFrames(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpPage(
    WidgetTester tester,
    _Page page,
    Size size, {
    double textScale = 1,
    FakeViewPadding padding = FakeViewPadding.zero,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1
      ..padding = padding;
    addTearDown(tester.view.reset);
    if (textScale != 1) {
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => switch (page) {
            _Page.subforums => const ForumPage(fid: _parentFid),
            _Page.group => const ForumGroupPage(gid: '1'),
          },
        ),
        GoRoute(
          path: ScreenPaths.forum,
          name: ScreenPaths.forum,
          builder: (_, state) => Text('forum ${state.pathParameters['fid']}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<ForumRepository>(create: (_) => _FakeForumRepository(() => names)),
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<FragmentsRepository>(create: (_) => FragmentsRepository()),
            RepositoryProvider<NotificationRepository>(create: (_) => NotificationRepository()),
            RepositoryProvider<NotificationInfoRepository>(create: (_) => NotificationInfoRepository()),
          ],
          child: MultiBlocProvider(
            providers: [
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
    // The forum page switches to its sub forums tab by itself: the forum has no thread.
    await pumpFrames(tester);
  }

  Finder card(int index) => find.byType(ForumCard).at(index);
  Iterable<ForumCard> cards(WidgetTester tester) => tester.widgetList<ForumCard>(find.byType(ForumCard));
  Size imageSize(WidgetTester tester, int index) =>
      tester.getSize(find.descendant(of: card(index), matching: find.byType(NetworkIndicatorImage)));
  Future<void> scrollWithoutError(WidgetTester tester) async {
    // The list holding the cards, kept once found: the first card leaves the tree while scrolling.
    final listView = tester.widget<ListView>(find.ancestor(of: card(0), matching: find.byType(ListView)).first);
    final list = find.byWidget(listView);
    for (var i = 0; i < 6; i++) {
      await tester.drag(list, const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    }
  }

  /// Tab bar controller of the forum page.
  TabController forumTabs(WidgetTester tester) => tester.widget<TabBar>(find.byType(TabBar)).controller!;

  for (final page in _Page.values) {
    group(page.name, () {
      testWidgets('desktop 1600: two columns of large cards across the wide content area', (tester) async {
        await pumpPage(tester, page, const Size(1600, 1000));
        expect(tester.takeException(), isNull);
        expect(find.byType(ForumCard), findsNWidgets(4));
        expect(cards(tester).every((e) => e.large), isTrue);

        const side = (1600 - forumCardListMaxWidth) / 2;
        final first = tester.getRect(card(0));
        final second = tester.getRect(card(1));
        expect(first.left, moreOrLessEquals(side));
        expect(second.right, moreOrLessEquals(1600 - side));
        expect(second.top, moreOrLessEquals(first.top));
        expect(first.width, moreOrLessEquals((forumCardListMaxWidth - appSurfaceGap) / 2));
        expect(tester.getRect(card(2)).top, greaterThan(first.bottom));

        // Same large content as the topics page: 240x120 picture, 24px name, three counters filling the bottom.
        expect(imageSize(tester, 0), forumCardLargeImageSize);
        expect(tester.widget<Text>(find.text('美术部')).style?.fontSize, 24);
        expect(find.descendant(of: card(0), matching: find.byType(ForumCardStat)), findsNWidgets(3));
      }, variant: _windows);

      testWidgets('Android 1600 wide landscape: phone cards and the shared width, never the desktop size', (
        tester,
      ) async {
        await pumpPage(tester, page, const Size(1600, 1000));
        expect(tester.takeException(), isNull);
        expect(find.byType(ForumCard), findsNWidgets(4));
        expect(cards(tester).any((e) => e.large), isFalse);
        final first = tester.getRect(card(0));
        final second = tester.getRect(card(1));
        expect(second.right - first.left, moreOrLessEquals(appListMaxWidth));
        expect(second.top, moreOrLessEquals(first.top));
        expect(imageSize(tester, 0), forumCardImageSize);
        expect(tester.widget<Text>(find.text('美术部')).style?.fontSize, isNot(24));
        expect(find.descendant(of: card(0), matching: find.byType(AppInfoPill)), findsNWidgets(3));
        expect(find.byType(ForumCardStat), findsNothing);
      }, variant: _android);

      testWidgets('1100 at 2x text with long names: still large, nothing overflows', (tester) async {
        names = [for (var i = 0; i < 6; i++) '很长很长的子版块名称$i' * 6];
        await pumpPage(tester, page, const Size(forumCardListLargeWidth, 700), textScale: 2);
        expect(tester.takeException(), isNull);
        expect(cards(tester).every((e) => e.large), isTrue);
        expect(tester.getRect(card(1)).top, moreOrLessEquals(tester.getRect(card(0)).top));
        await scrollWithoutError(tester);
      }, variant: _windows);

      testWidgets('side insets count: 1140 wide minus a 44 inset stays compact', (tester) async {
        await pumpPage(tester, page, const Size(1140, 800), padding: const FakeViewPadding(left: 44));
        expect(tester.takeException(), isNull);
        expect(cards(tester).any((e) => e.large), isFalse);
        expect(tester.getRect(card(0)).left, greaterThanOrEqualTo(44));
      }, variant: _windows);

      testWidgets('Android landscape 844x390 with side insets: compact cards inside the safe area', (tester) async {
        names = [for (var i = 0; i < 6; i++) '很长很长的子版块名称$i' * 3];
        await pumpPage(
          tester,
          page,
          const Size(844, 390),
          textScale: 2,
          padding: const FakeViewPadding(left: 44, right: 44, bottom: 21),
        );
        expect(tester.takeException(), isNull);
        expect(cards(tester).any((e) => e.large), isFalse);
        for (var i = 0; i < find.byType(ForumCard).evaluate().length; i++) {
          final rect = tester.getRect(card(i));
          expect(rect.left, greaterThanOrEqualTo(44));
          expect(rect.right, lessThanOrEqualTo(844 - 44));
        }
        await scrollWithoutError(tester);
      }, variant: _android);

      testWidgets('phone 320 at 2x text: one compact column, no overflow', (tester) async {
        names = [for (var i = 0; i < 6; i++) '很长很长的子版块名称$i' * 4];
        await pumpPage(tester, page, const Size(320, 640), textScale: 2);
        expect(tester.takeException(), isNull);
        expect(cards(tester).any((e) => e.large), isFalse);
        expect(tester.getRect(card(0)).width, moreOrLessEquals(320 - 2 * appPagePadding(320)));
        expect(imageSize(tester, 0), forumCardImageSize);
        await scrollWithoutError(tester);
      }, variant: _android);

      testWidgets('phone 390: tapping a compact card opens the sub forum', (tester) async {
        await pumpPage(tester, page, const Size(390, 844));
        expect(cards(tester).any((e) => e.large), isFalse);
        await tester.tap(find.text('音乐部'));
        await pumpFrames(tester);
        expect(find.text('forum 2001'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: _android);

      testWidgets('desktop: tapping a large card opens the sub forum', (tester) async {
        await pumpPage(tester, page, const Size(1600, 1000));
        expect(cards(tester).every((e) => e.large), isTrue);
        await tester.tap(find.text('摄影部'));
        await pumpFrames(tester);
        expect(find.text('forum 2003'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: _windows);
    });
  }

  group('forum without threads', () {
    Finder tab(String title) => find.descendant(of: find.byType(TabBar), matching: find.text(title));

    testWidgets('opens the sub forums tab once, the user can still switch tabs, cards navigate', (tester) async {
      await pumpPage(tester, _Page.subforums, const Size(390, 844));
      // The switch runs after the loaded state, not during a build.
      expect(tester.takeException(), isNull);
      expect(forumTabs(tester).index, 2);
      expect(find.byType(ForumCard), findsNWidgets(4));

      // Rebuilds (the tab listener calls setState) no longer force the sub forums tab back.
      await tester.tap(tab(t.forumPage.threadTab.title));
      await pumpFrames(tester);
      expect(tester.takeException(), isNull);
      expect(forumTabs(tester).index, 1);
      expect(find.text(t.forumPage.threadTab.noThread), findsOneWidget);

      await tester.tap(tab(t.forumPage.subredditTab.title));
      await pumpFrames(tester);
      expect(forumTabs(tester).index, 2);
      await tester.tap(find.text('文学部'));
      await pumpFrames(tester);
      expect(find.text('forum 2002'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: _android);

    testWidgets('desktop: opens the sub forums tab with large cards', (tester) async {
      await pumpPage(tester, _Page.subforums, const Size(1600, 1000));
      expect(tester.takeException(), isNull);
      expect(forumTabs(tester).index, 2);
      expect(cards(tester).every((e) => e.large), isTrue);
    }, variant: _windows);
  });
}
