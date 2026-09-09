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
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/latest_thread/bloc/latest_thread_bloc.dart';
import 'package:tsdm_client/features/latest_thread/models/latest_thread.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/features/latest_thread/view/latest_thread_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// GitHub #12: the full guide list pages behind the homepage modules (`view=hot|digest|sofa`) open in the existing
/// latest thread page.

String _data(String name) => File('test/data/$name').readAsStringSync();

/// Answers `forum.php?mod=guide&view=X` with the captured page for X, records every request.
final class _Adapter implements HttpClientAdapter {
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final q = options.uri.queryParameters;
    final answer = switch ((options.uri.path, q['mod'], q['view'])) {
      ('/forum.php', 'guide', 'hot') => _data('guide_hot_x5.html'),
      ('/forum.php', 'guide', 'digest') => _data('guide_digest_x5.html'),
      ('/forum.php', 'guide', 'new') => _data('guide_new_x5.html'),
      _ => '<html></html>',
    };
    return ResponseBody.fromString(
      answer,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Never answers: avatars are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Serves a captured page instead of the network.
final class _FixtureRepository extends LatestThreadRepository {
  _FixtureRepository(this.name);

  final String name;
  final requested = <String>[];

  @override
  AsyncEither<uh.Document> fetchDocument(String url) {
    requested.add(url);
    return AsyncEither.of(parseHtmlDocument(_data(name)));
  }
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('LatestThread.fromTBody', () {
    test('parses every row of the 最新热门 page', () {
      final doc = parseHtmlDocument(_data('guide_hot_x5.html'));
      final rows = doc.querySelectorAll('tbody[id^="normalthread_"]');
      expect(rows, hasLength(47));
      final threads = rows.map(LatestThread.fromTBody).toList();
      expect(threads.where((e) => e.isValid), hasLength(47));
      final first = threads.first;
      expect(first.threadID, '1264935');
      expect(first.title, '部分用户无法登录的问题我说几句');
      expect(first.forumName, '若闲小阁');
      expect(first.forumUrl, '$baseUrl/forum.php?mod=forumdisplay&fid=4');
      expect(first.latestReplyAuthor?.name, '白洲アズサ');
      expect(first.latestReplyTime, isNotNull);
      expect(first.replyCount, 4);
      expect(first.viewCount, 332);
      for (final thread in threads) {
        expect(thread.title ?? '', isNotEmpty);
        expect(thread.forumName ?? '', isNotEmpty);
      }
    });

    test('the 最新精华 page has no rows, the bloc still succeeds with an empty list', () async {
      final repo = _FixtureRepository('guide_digest_x5.html');
      final bloc = LatestThreadBloc(latestThreadRepository: repo);
      addTearDown(bloc.close);
      final done = bloc.stream.firstWhere((s) => s.status != LatestThreadStatus.loading);
      bloc.add(LatestThreadRefreshRequested(guideUrl('digest')));
      final state = await done;
      expect(state.status, LatestThreadStatus.success);
      expect(state.threadList, isEmpty);
      expect(state.nextPageUrl, isNull);
    });

    test('the 最新热门 page paginates with view=hot', () async {
      final repo = _FixtureRepository('guide_hot_x5.html');
      final bloc = LatestThreadBloc(latestThreadRepository: repo);
      addTearDown(bloc.close);
      final done = bloc.stream.firstWhere((s) => s.status == LatestThreadStatus.success);
      bloc.add(LatestThreadRefreshRequested(guideUrl('hot')));
      final state = await done;
      expect(state.threadList, hasLength(47));
      expect(state.nextPageUrl, '$baseUrl/forum.php?mod=guide&view=hot&page=2');
    });
  });

  group('LatestThreadRepository', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late _Adapter adapter;

    setUp(() async {
      adapter = _Adapter();
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
    });

    tearDown(() async {
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    test('accepts the guide urls of every module and of 抢沙发', () async {
      for (final view in ['hot', 'digest', 'new', 'newthread', 'sofa']) {
        final result = await LatestThreadRepository().fetchDocument(guideUrl(view)).run();
        expect(result.isRight(), isTrue, reason: '$view: $result');
      }
      // The client appends `mobile=no` to every forum request; the guide view is passed through untouched.
      expect(adapter.requests.map((e) => e.path), everyElement('/forum.php'));
      expect(adapter.requests.map((e) => e.queryParameters['mod']), everyElement('guide'));
      expect(adapter.requests.map((e) => e.queryParameters['view']), ['hot', 'digest', 'new', 'newthread', 'sofa']);
      // Only forum urls are fetched.
      final foreign = await LatestThreadRepository()
          .fetchDocument('https://example.com/forum.php?mod=guide&view=hot')
          .run();
      expect(foreign.isLeft(), isTrue);
      expect(adapter.requests, hasLength(5));
    });
  });

  group('LatestThreadPage', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    // The thread cards read the settings bloc; built and closed in the real zone (setUp / tearDown) like the database.
    late SettingsBloc settingsBloc;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
      await settings.init();
      getIt.registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });

    tearDown(() async {
      await settingsBloc.close();
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    Future<void> pump(WidgetTester tester, LatestThreadPage page) async {
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => page),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: BlocProvider<SettingsBloc>.value(
            value: settingsBloc,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the module title in the app bar and the rows of the 最新热门 page', (tester) async {
      final repo = _FixtureRepository('guide_hot_x5.html');
      await pump(tester, LatestThreadPage(url: guideUrl('hot'), title: '最新热门', repository: repo));
      expect(repo.requested, [guideUrl('hot')]);
      expect(find.widgetWithText(AppBar, '最新热门'), findsOneWidget);
      expect(find.byType(LatestThreadCard), findsWidgets);
      expect(find.text('部分用户无法登录的问题我说几句'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty page (最新精华) says so instead of showing a blank list', (tester) async {
      final repo = _FixtureRepository('guide_digest_x5.html');
      await pump(tester, LatestThreadPage(url: guideUrl('digest'), repository: repo));
      expect(find.widgetWithText(AppBar, 'Latest Thread'), findsOneWidget, reason: 'generic title without one');
      expect(find.byType(LatestThreadCard), findsNothing);
      expect(find.text('No threads yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
