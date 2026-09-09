import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/homepage/cubit/guide_index_cubit.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/repository/guide_index_repository.dart';
import 'package:tsdm_client/features/homepage/utils/parse_guide_index.dart';
import 'package:tsdm_client/features/homepage/widgets/guide_section.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// GitHub #12: the homepage shows the modules of the guide index page (`forum.php?mod=guide&view=index`).

String _data(String name) => File('test/data/$name').readAsStringSync();

uh.Document _index() => parseHtmlDocument(_data('guide_index_x5.html'));

/// Serves the captured guide index page for `view=index`, anything else is an empty document.
final class _Adapter implements HttpClientAdapter {
  _Adapter({this.status = 200});

  final int status;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final q = options.uri.queryParameters;
    final answer = options.uri.path == '/forum.php' && q['mod'] == 'guide' && q['view'] == 'index'
        ? _data('guide_index_x5.html')
        : '<html></html>';
    return ResponseBody.fromString(
      answer,
      status,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers the section from parsed modules, no network.
final class _FixtureRepository extends GuideIndexRepository {
  const _FixtureRepository(this.modules, {this.fail = false});

  final List<GuideModule> modules;
  final bool fail;

  @override
  AsyncEither<List<GuideModule>> fetchGuideIndex() =>
      fail ? AsyncEither.left(HttpRequestFailedException(500)) : AsyncEither.of(modules);
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('parseGuideIndex', () {
    test('finds the four modules in page order with their view keys and 更多 urls', () {
      final modules = parseGuideIndex(_index());
      expect(modules.map((e) => e.title), ['最新热门', '最新精华', '最新回复', '最新发表']);
      expect(modules.map((e) => e.view), ['hot', 'digest', 'new', 'newthread']);
      expect(modules.map((e) => e.moreUrl), [
        guideUrl('hot'),
        guideUrl('digest'),
        guideUrl('new'),
        guideUrl('newthread'),
      ]);
      // The page lists 30 threads per module (the homepage shows the first 10); 最新精华 is empty on the forum.
      expect(modules.map((e) => e.items.length), [30, 0, 30, 30]);
      expect(modules[1].emptyMessage, '暂时还没有帖子');
      expect(modules.where((e) => e.items.isNotEmpty).map((e) => e.emptyMessage), everyElement(isNull));
      for (final item in modules.expand((e) => e.items)) {
        expect(item.tid, matches(RegExp(r'^\d+$')));
        expect(item.title, isNotEmpty);
        expect(item.url, '$baseUrl/forum.php?mod=viewthread&tid=${item.tid}&extra=');
        expect(item.fid, matches(RegExp(r'^\d+$')));
        expect(item.forumName, isNotEmpty);
      }
    });

    test('the first hot thread: highlighted title, forum, participants', () {
      final item = parseGuideIndex(_index()).first.items.first;
      expect(item.tid, '1264935');
      expect(item.title, '部分用户无法登录的问题我说几句');
      expect(item.highlighted, isTrue);
      expect(item.forumName, '若闲小阁');
      expect(item.fid, '4');
      expect(item.extra, '4人参与');
    });

    test('the extra text differs per module: reply time in 最新回复, nothing in 最新发表', () {
      final modules = parseGuideIndex(_index());
      final hot = modules[0].items;
      expect(hot[1].highlighted, isFalse);
      expect(hot[1].extra, '30人参与');
      final latestReply = modules[2].items;
      expect(latestReply[0].extra, '2026-9-30 00:32');
      expect(latestReply[1].extra, '7 秒前', reason: 'nbsp collapsed');
      expect(modules[3].items.map((e) => e.extra), everyElement(isNull));
    });

    test('a missing module is tolerated, a guest or unrelated page yields nothing', () {
      final doc = _index();
      doc.querySelectorAll('div.bm.bmw').elementAt(1).remove();
      expect(parseGuideIndex(doc).map((e) => e.view), ['hot', 'new', 'newthread']);

      expect(parseGuideIndex(parseHtmlDocument('<html><body><div id="wp"></div></body></html>')), isEmpty);
      expect(parseGuideIndex(parseHtmlDocument('')), isEmpty);
      // A block without the 更多 link is not a module.
      expect(
        parseGuideIndex(parseHtmlDocument('<div class="bm bmw"><div class="bm_h"><h2>x</h2></div></div>')),
        isEmpty,
      );
    });
  });

  group('GuideIndexRepository / GuideIndexCubit', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late _Adapter adapter;

    Future<void> register(_Adapter a) async {
      adapter = a;
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
        );
      await settings.init();
    }

    tearDown(() async {
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    test('the repository fetches view=index and parses its modules', () async {
      await register(_Adapter());
      final result = await const GuideIndexRepository().fetchGuideIndex().run();
      expect(result.isRight(), isTrue, reason: '$result');
      final modules = result.getRight().toNullable()!;
      expect(modules.map((e) => e.view), ['hot', 'digest', 'new', 'newthread']);
      expect(adapter.requests, hasLength(1));
      // The client appends `mobile=no` to every forum request.
      final request = adapter.requests.single;
      expect('${request.scheme}://${request.host}${request.path}', '$baseUrl/forum.php');
      expect(request.queryParameters, containsPair('mod', 'guide'));
      expect(request.queryParameters, containsPair('view', 'index'));
    });

    test('the cubit goes loading -> success with the modules, and failure on a server error', () async {
      await register(_Adapter());
      final cubit = GuideIndexCubit(const GuideIndexRepository());
      addTearDown(cubit.close);
      final states = cubit.stream.take(2).map((s) => s.status).toList();
      await cubit.load();
      expect(await states, [GuideIndexStatus.loading, GuideIndexStatus.success]);
      expect(cubit.state.modules.map((e) => e.title), ['最新热门', '最新精华', '最新回复', '最新发表']);

      await getIt.reset();
      await settings.dispose();
      await db.close();
      await register(_Adapter(status: 500));
      final failing = GuideIndexCubit(const GuideIndexRepository());
      addTearDown(failing.close);
      await failing.load();
      expect(failing.state.status, GuideIndexStatus.failure);
      expect(failing.state.modules, isEmpty);
    });
  });

  group('GuideSection', () {
    Future<GoRouter> pump(WidgetTester tester, GuideIndexRepository repository) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: ListView(children: [GuideSection(repository: repository)]),
            ),
          ),
          GoRoute(
            path: ScreenPaths.threadV1,
            name: ScreenPaths.threadV1,
            builder: (_, state) => Scaffold(body: Text('thread ${state.uri.queryParameters['tid']}')),
          ),
          GoRoute(
            path: ScreenPaths.latestThread,
            name: ScreenPaths.latestThread,
            builder: (_, state) => Scaffold(body: Text('list ${state.uri.queryParameters['url']}')),
          ),
          GoRoute(
            path: ScreenPaths.forum,
            name: ScreenPaths.forum,
            builder: (_, state) => Scaffold(body: Text('forum ${state.pathParameters['fid']}')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('shows every module with its title, 更多 button, first 10 items and the 抢沙发 chip', (tester) async {
      tester.view.physicalSize = const Size(1080, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final modules = parseGuideIndex(_index());
      await pump(tester, _FixtureRepository(modules));

      expect(find.byType(GuideModuleCard), findsNWidgets(4));
      for (final module in modules) {
        expect(find.widgetWithText(GuideModuleCard, module.title), findsOneWidget);
        expect(find.widgetWithText(ActionChip, module.title), findsOneWidget, reason: 'nav chip');
      }
      expect(find.widgetWithText(TextButton, 'More'), findsNWidgets(4));
      expect(find.widgetWithText(ActionChip, 'Sofa'), findsOneWidget);

      // 最新热门: 10 of the 30 items, the first one highlighted in the error color with its forum and participants.
      final hot = find.byType(GuideModuleCard).first;
      for (final item in modules[0].items.take(10)) {
        expect(
          find.descendant(of: hot, matching: find.text(item.title)),
          findsOneWidget,
          reason: item.tid,
        );
      }
      expect(find.descendant(of: hot, matching: find.text('部分用户无法登录的问题我说几句')), findsOneWidget);
      expect(find.descendant(of: hot, matching: find.text('4人参与')), findsWidgets);
      expect(find.descendant(of: hot, matching: find.text('若闲小阁')), findsWidgets);
      final context = tester.element(hot);
      final title = tester.widget<Text>(find.descendant(of: hot, matching: find.text('部分用户无法登录的问题我说几句')));
      expect(title.style?.color, Theme.of(context).colorScheme.error);
      expect(find.descendant(of: hot, matching: find.text(modules[0].items[10].title)), findsNothing);
      // 最新精华 is empty: the page's own message.
      expect(find.text('暂时还没有帖子'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping an item opens the thread, 更多 and the chips open the full list pages', (tester) async {
      tester.view.physicalSize = const Size(1080, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final modules = parseGuideIndex(_index());
      final router = await pump(tester, _FixtureRepository(modules));

      await tester.tap(find.text('部分用户无法登录的问题我说几句').first);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, ScreenPaths.threadV1);
      expect(router.state.uri.queryParameters['tid'], '1264935');
      expect(router.state.uri.queryParameters['appBarTitle'], '部分用户无法登录的问题我说几句');
      expect(find.text('thread 1264935'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'More').first);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, ScreenPaths.latestThread);
      expect(router.state.uri.queryParameters['url'], guideUrl('hot'));
      expect(router.state.uri.queryParameters['title'], '最新热门');
      router.pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('guide-sofa')));
      await tester.pumpAndSettle();
      expect(router.state.uri.queryParameters['url'], guideUrl('sofa'));
      expect(router.state.uri.queryParameters['title'], 'Sofa');
      router.pop();
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ActionChip, '最新发表'));
      await tester.pumpAndSettle();
      expect(router.state.uri.queryParameters['url'], guideUrl('newthread'));
      router.pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('若闲小阁').first);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/forum/4');
      expect(router.state.uri.queryParameters['appBarTitle'], '若闲小阁');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed load shows the retry row that reloads, the 抢沙发 chip stays', (tester) async {
      await pump(tester, const _FixtureRepository([], fail: true));
      expect(find.text('Failed to load, tap to retry'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Sofa'), findsOneWidget);
      expect(find.byType(GuideModuleCard), findsNothing);
      // Retry keeps failing here, the row must survive it.
      await tester.tap(find.text('Failed to load, tap to retry'));
      await tester.pumpAndSettle();
      expect(find.text('Failed to load, tap to retry'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
