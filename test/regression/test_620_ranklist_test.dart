/// The forum's rankings (`misc.php?mod=ranklist`): members by credits, posts and online time, the hot threads.
///
/// 1. the pages parse: place, member, user group and value (the forum's shape: a coloured name, the group in
///    `<font>` with its icon, the post count inside a link), the thread rows, and the cache times of `div.notice`;
/// 2. a ranking the forum turned off is its 提示信息 page: the forum's words, not an empty list;
/// 3. the page: one tab each, the thread orders, the update time, a turned-off ranking told in its tab.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/ranklist/cubit/ranklist_cubit.dart';
import 'package:tsdm_client/features/ranklist/models/ranklist.dart';
import 'package:tsdm_client/features/ranklist/repository/ranklist_repository.dart';
import 'package:tsdm_client/features/ranklist/view/ranklist_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:universal_html/parsing.dart';

String _fixture(String name) => File('test/data/ranklist/$name').readAsStringSync();

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The forum's ranking pages by url, the urls asked kept in [asked].
RanklistRepository _forum(Map<String, String> pages, {List<String>? asked}) => RanklistRepository(
  fetchHtml: (url) {
    asked?.add(url);
    final page = pages[url];
    return page == null ? AsyncEither.left(HttpRequestFailedException(404)) : AsyncEither.right(page);
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('parse', () {
    test('credits: place, member, group and value, in the forum shape', () {
      final page = parseRanklistPage(parseHtmlDocument(_fixture('member_credit_x5.html')));
      expect(page.threads, isEmpty);
      expect(page.members.map((e) => (e.rank, e.uid, e.username, e.groupName, e.value)), [
        (1, '31', '测试版主', '区版主', '2085118'),
        (2, '32', '测试会员甲', '莉莉丝', '1500000'),
        (3, '33', '测试会员乙', '管理员', '991509'),
        (4, '34', '测试会员丙', '高级会员', '606'),
      ]);
      expect(page.lastUpdate, '2026-11-9 00:42');
      expect(page.nextUpdate, '2026-11-9 05:42');
    });

    test('posts: the count inside its link, no group', () {
      final page = parseRanklistPage(parseHtmlDocument(_fixture('member_post_x5.html')));
      expect(page.members.map((e) => (e.rank, e.uid, e.groupName, e.value)), [
        (1, '31', null, '1041482'),
        (2, '32', null, '14'),
      ]);
    });

    test('online time: the value with its unit', () {
      final page = parseRanklistPage(parseHtmlDocument(_fixture('member_onlinetime_x5.html')));
      expect(page.members.map((e) => (e.username, e.groupName, e.value)), [
        ('测试会员丁', '使者', '11160 分钟'),
        ('测试会员戊', '禁止发言', '10 分钟'),
      ]);
    });

    test('threads: place, tid, title, forum, author and value, the header row left out', () {
      final page = parseRanklistPage(parseHtmlDocument(_fixture('thread_replies_x5.html')));
      expect(page.members, isEmpty);
      expect(page.threads.map((e) => (e.rank, e.tid, e.title, e.forumName, e.author, e.value)), [
        (1, '1001', '测试主题 & 长楼', '测试版块一', '测试版主', '301'),
        (2, '1002', '测试主题二', '测试版块二', '测试会员甲', '249'),
        (4, '1003', '测试主题三', '测试版块二', '测试会员乙', '12'),
      ]);
      expect(page.lastUpdate, '2026-11-9 00:42');
    });

    test('heat: the same rows, the value of the order asked', () {
      final page = parseRanklistPage(parseHtmlDocument(_fixture('thread_heats_x5.html')));
      expect(page.threads.map((e) => (e.tid, e.value)), [('1001', '88'), ('1002', '57'), ('1003', '9')]);
    });

    test('online minutes', () {
      expect(ranklistOnlineMinutes('11160 分钟'), 11160);
      expect(ranklistOnlineMinutes('10 minutes'), 10);
      expect(ranklistOnlineMinutes('1 天 2 小时'), isNull);
      expect(ranklistOnlineMinutes('2 小时'), isNull);
      expect(ranklistOnlineMinutes('42'), 42);
    });

    test('a notice without recognized times is kept as printed', () {
      final page = parseRanklistPage(
        parseHtmlDocument(
          '<div class="xld hasrank"><dl><dd class="ranknum">1</dd><dt><a href="home.php?mod=space&uid=9">a</a></dt> '
          '<dd><p>Credits: 5</p></dd></dl></div><div class="notice">Cached, updated a while ago</div>',
        ),
      );
      expect(page.members.single.value, '5');
      expect(page.lastUpdate, isNull);
      expect(page.notice, 'Cached, updated a while ago');
    });

    test('urls of the tabs', () {
      expect(ranklistUrl(RanklistKind.credit), '$baseUrl/misc.php?mod=ranklist&type=member&view=credit');
      expect(ranklistUrl(RanklistKind.post), '$baseUrl/misc.php?mod=ranklist&type=member&view=post');
      expect(ranklistUrl(RanklistKind.online), '$baseUrl/misc.php?mod=ranklist&type=member&view=onlinetime');
      expect(
        ranklistUrl(RanklistKind.thread, threadView: RanklistThreadView.heats),
        '$baseUrl/misc.php?mod=ranklist&type=thread&view=heats',
      );
    });
  });

  group('turned off', () {
    test('the 提示信息 page is the forum message, not an empty ranking', () {
      final result = parseRanklistAnswer(_fixture('thread_closed_x5.html'));
      final e = result.getLeft().toNullable();
      expect(e, isA<ServerRespondedErrorException>());
      expect(e!.message, '此排行功能已关闭');
      expect(LoadFailure.of(e).message, '此排行功能已关闭');
      expect(LoadFailure.of(e).kind, LoadFailureKind.forumMessage);
      expect(LoadFailure.of(ServerRespondedErrorException('排行榜功能关闭')).kind, LoadFailureKind.forumMessage);
    });

    test('an empty ranking stays an empty ranking', () {
      final result = parseRanklistAnswer('<div class="xld hasrank"></div>');
      expect(result.getRight().toNullable()?.isEmpty, isTrue);
    });

    test('the tab fails with the message, a later success clears it', () async {
      final pages = {ranklistUrl(RanklistKind.thread): _fixture('thread_closed_x5.html')};
      final cubit = RanklistCubit(kind: RanklistKind.thread, repository: _forum(pages));
      await cubit.load();
      expect(cubit.state.status, RanklistStatus.failed);
      expect(cubit.state.failure?.message, '此排行功能已关闭');
      pages[ranklistUrl(RanklistKind.thread)] = _fixture('thread_replies_x5.html');
      await cubit.load();
      expect(cubit.state.status, RanklistStatus.success);
      expect(cubit.state.failure, isNull);
      await cubit.close();
    });

    test('a failed refresh keeps the ranking shown', () async {
      final pages = {ranklistUrl(RanklistKind.credit): _fixture('member_credit_x5.html')};
      final cubit = RanklistCubit(kind: RanklistKind.credit, repository: _forum(pages));
      await cubit.load();
      pages.clear();
      await cubit.load();
      expect(cubit.state.status, RanklistStatus.success);
      expect(cubit.state.page?.members, hasLength(4));
      expect(cubit.state.failure, isNotNull);
      await cubit.close();
    });

    test('another thread order asks its own page', () async {
      final asked = <String>[];
      final pages = {
        ranklistUrl(RanklistKind.thread): _fixture('thread_replies_x5.html'),
        ranklistUrl(RanklistKind.thread, threadView: RanklistThreadView.views): _fixture('thread_replies_x5.html'),
      };
      final cubit = RanklistCubit(
        kind: RanklistKind.thread,
        repository: _forum(pages, asked: asked),
      );
      await cubit.load();
      await cubit.changeThreadView(RanklistThreadView.views);
      expect(asked, [
        ranklistUrl(RanklistKind.thread),
        ranklistUrl(RanklistKind.thread, threadView: RanklistThreadView.views),
      ]);
      expect(cubit.state.threadView, RanklistThreadView.views);
      expect(cubit.state.status, RanklistStatus.success);
      await cubit.close();
    });
  });

  group('page', () {
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
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });

    tearDown(() async {
      await settingsBloc.close();
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('the thread orders, each its own page', (tester) async {
      final pages = {
        ranklistUrl(RanklistKind.credit): _fixture('member_credit_x5.html'),
        ranklistUrl(RanklistKind.post): _fixture('member_post_x5.html'),
        ranklistUrl(RanklistKind.online): _fixture('member_onlinetime_x5.html'),
        ranklistUrl(RanklistKind.thread): _fixture('thread_replies_x5.html'),
        ranklistUrl(RanklistKind.thread, threadView: RanklistThreadView.heats): _fixture('thread_heats_x5.html'),
      };
      await tester.pumpWidget(
        TranslationProvider(
          child: BlocProvider<SettingsBloc>.value(
            value: settingsBloc,
            child: MaterialApp(home: RanklistPage(repository: _forum(pages))),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.widgetWithText(Tab, t.ranklistPage.tabs.thread));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.byKey(const ValueKey('ranklist-thread-1001')), findsOneWidget);
      expect(find.text('301'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ranklist-view-heats')));
      await settle(tester);
      expect(find.text('88'), findsOneWidget);
      expect(find.text('301'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tabs, members with their values, the update time, a turned-off ranking', (tester) async {
      final pages = {
        ranklistUrl(RanklistKind.credit): _fixture('member_credit_x5.html'),
        ranklistUrl(RanklistKind.post): _fixture('member_post_x5.html'),
        ranklistUrl(RanklistKind.online): _fixture('member_onlinetime_x5.html'),
        ranklistUrl(RanklistKind.thread): _fixture('thread_closed_x5.html'),
      };
      await tester.pumpWidget(
        TranslationProvider(
          child: BlocProvider<SettingsBloc>.value(
            value: settingsBloc,
            child: MaterialApp(home: RanklistPage(repository: _forum(pages))),
          ),
        ),
      );
      await settle(tester);
      final tr = t.ranklistPage;
      expect(find.text(tr.title), findsOneWidget);
      for (final tab in [tr.tabs.credit, tr.tabs.post, tr.tabs.online, tr.tabs.thread]) {
        expect(find.widgetWithText(Tab, tab), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('ranklist-member-31')), findsOneWidget);
      expect(find.text('2085118'), findsOneWidget);
      expect(find.text('区版主'), findsOneWidget);
      expect(find.text(tr.updated(last: '2026-11-9 00:42', next: '2026-11-9 05:42')), findsOneWidget);

      await tester.tap(find.widgetWithText(Tab, tr.tabs.thread));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.text('此排行功能已关闭'), findsOneWidget);
      expect(find.byKey(const ValueKey('ranklist-view-heats')), findsNothing, reason: 'turned off in every order');

      await tester.tap(find.widgetWithText(Tab, tr.tabs.online));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.text(tr.minutes(n: 11160)), findsOneWidget);
      expect(find.text('使者'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
