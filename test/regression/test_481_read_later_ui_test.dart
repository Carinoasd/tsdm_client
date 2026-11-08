/// Read later: the page of the list and the entries that put a thread aside (「稍後閱讀」).
///
/// The page lists the title, the author, the forum and the time put aside, opens the thread, drops an entry swiped
/// away and empties the list after asking. The thread card's menu puts a thread aside or takes it off, only for an
/// account. The account's removal deletes the list too. No network, no real account.
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/read_later/cubit/read_later_cubit.dart';
import 'package:tsdm_client/features/read_later/view/read_later_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';

final class _NoImages implements HttpClientAdapter {
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

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    await settings.init();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _NoImages())),
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

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Widget host(Widget home, ReadLaterCubit cubit, {List<GoRoute> routes = const []}) {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => home),
        GoRoute(path: ScreenPaths.threadV1, name: ScreenPaths.threadV1, builder: (_, _) => const Text('thread opened')),
        ...routes,
      ],
    );
    return TranslationProvider(
      child: BlocProvider<SettingsBloc>.value(
        value: settingsBloc,
        child: BlocProvider<ReadLaterCubit>.value(
          value: cubit,
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
  }

  group('the page', () {
    testWidgets('lists the entries, opens one, and swiping drops it', (tester) async {
      await storage.addReadLater(
        uid: 31,
        tid: 7,
        title: 'seven',
        author: 'Bob',
        forumName: 'forum',
        time: DateTime(2026, 1, 2),
      );
      await storage.addReadLater(uid: 31, tid: 8, title: 'eight', time: DateTime(2026, 1, 3));
      final cubit = ReadLaterCubit(storageProvider: storage, uid: 31);
      addTearDown(cubit.close);
      await tester.pumpWidget(host(const ReadLaterPage(), cubit));
      await settle(tester);

      expect(find.text('seven'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('forum'), findsOneWidget);
      expect(tester.getTopLeft(find.text('eight')).dy, lessThan(tester.getTopLeft(find.text('seven')).dy));

      await tester.fling(find.text('eight'), const Offset(-600, 0), 2000);
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.text('eight'), findsNothing);
      expect((await storage.fetchReadLater(31)).map((e) => e.tid), [7]);

      await tester.tap(find.text('seven'));
      await settle(tester);
      expect(find.text('thread opened'), findsOneWidget);
    });

    testWidgets('clear asks first, then empties the list', (tester) async {
      await storage.addReadLater(uid: 31, tid: 7, title: 'seven');
      final cubit = ReadLaterCubit(storageProvider: storage, uid: 31);
      addTearDown(cubit.close);
      await tester.pumpWidget(host(const ReadLaterPage(), cubit));
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('read-later-clear')));
      await settle(tester);
      expect(find.text(t.readLater.clearConfirm), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextButton).first);
      await settle(tester);
      expect(await storage.fetchReadLater(31), hasLength(1));

      await tester.tap(find.byKey(const ValueKey('read-later-clear')));
      await settle(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextButton).last);
      await settle(tester);
      expect(await storage.fetchReadLater(31), isEmpty);
      expect(find.text(t.readLater.empty), findsOneWidget);
    });

    testWidgets('a guest is asked to log in', (tester) async {
      final cubit = ReadLaterCubit(storageProvider: storage);
      addTearDown(cubit.close);
      await tester.pumpWidget(host(const ReadLaterPage(), cubit));
      await settle(tester);
      expect(find.text(t.readLater.needLogin), findsOneWidget);
    });
  });

  group('the thread card menu', () {
    NormalThread thread(int tid) => NormalThread(
      title: 'thread $tid',
      url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
      threadID: '$tid',
      author: const User(name: 'Bob', url: ''),
      publishDate: null,
      latestReplyAuthor: const User(name: 'Bob', url: ''),
      latestReplyTime: null,
      iconUrl: '',
      threadType: null,
      replyCount: 1,
      viewCount: 0,
      price: null,
      css: null,
      stateSet: const {},
      privilege: null,
      isRecentThread: false,
    );

    Future<void> openMenu(WidgetTester tester) async {
      // Desktop: the context menu opens on a right click.
      await tester.tap(find.text('thread 5'), buttons: kSecondaryButton);
      await settle(tester);
    }

    testWidgets('puts a thread aside and takes it off again', (tester) async {
      final cubit = ReadLaterCubit(storageProvider: storage, uid: 31);
      addTearDown(cubit.close);
      await tester.pumpWidget(host(Scaffold(body: ListView(children: [NormalThreadCard(thread(5))])), cubit));
      await settle(tester);

      await openMenu(tester);
      await tester.tap(find.text(t.readLater.add));
      await settle(tester);
      final row = (await storage.fetchReadLater(31)).single;
      expect((row.tid, row.threadTitle, row.author), (5, 'thread 5', 'Bob'));

      await openMenu(tester);
      expect(find.text(t.readLater.add), findsNothing);
      await tester.tap(find.text(t.readLater.remove));
      await settle(tester);
      expect(await storage.fetchReadLater(31), isEmpty);
    });

    testWidgets('a guest is not offered it', (tester) async {
      final cubit = ReadLaterCubit(storageProvider: storage);
      addTearDown(cubit.close);
      await tester.pumpWidget(host(Scaffold(body: ListView(children: [NormalThreadCard(thread(5))])), cubit));
      await settle(tester);
      await openMenu(tester);
      expect(find.text(t.threadCard.viewInfo), findsOneWidget);
      expect(find.text(t.readLater.add), findsNothing);
    });
  });
}
