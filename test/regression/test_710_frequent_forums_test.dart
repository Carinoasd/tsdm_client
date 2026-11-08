/// The frequent forums bar: the forums the account pinned (long press a forum card, drag to arrange) and the forums it
/// visited lately, in a row on top of the forum lists.
///
/// 1. the lists: a visit goes first, once, at most 8, a pinned forum is not listed again as a recent one; pinning moves
///    a forum out of the recent ones and unpinning back; a pinned forum moves to a new place;
/// 2. saving: one JSON object in the settings (so a backup carries it), by uid, that survives a restart and reads
///    damaged values as nothing;
/// 3. the bar shows nothing without a forum, the pinned ones before the recent ones, and opens a forum when tapped;
/// 4. a long press on a forum card pins or unpins it, a pinned forum is dragged to a new place, and another account
///    sees its own forums.
///
/// Synthetic data only: no network.
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/forum/utils/frequent_forums.dart';
import 'package:tsdm_client/features/forum/widgets/frequent_forums_bar.dart';
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
import 'package:tsdm_client/widgets/card/forum_card.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

const _alice = UserLoginInfo(username: 'Alice', uid: 31);
const _bob = UserLoginInfo(username: 'Bob', uid: 32);

FrequentForum _f(int fid) => FrequentForum(fid: fid, name: 'Forum $fid');

Forum _forum(int fid) => Forum(
  forumID: fid,
  url: 'https://forum.test/forum.php?mod=forumdisplay&fid=$fid',
  name: 'Forum $fid',
  iconUrl: '',
  threadCount: 1,
  replyCount: 2,
  latestThreadUrl: null,
  latestThreadTime: null,
  latestThreadTimeText: null,
  threadTodayCount: 0,
);

List<int> _ids(List<FrequentForum> list) => list.map((e) => e.fid).toList();

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('1. the lists', () {
    test('a visit goes first, once, at most eight, and a pinned forum is not repeated', () {
      var a = const FrequentForumsOfAccount();
      for (var fid = 1; fid <= 10; fid++) {
        a = frequentForumsVisited(a, _f(fid));
      }
      expect(_ids(a.recent), [10, 9, 8, 7, 6, 5, 4, 3]);
      a = frequentForumsVisited(a, _f(5));
      expect(_ids(a.recent), [5, 10, 9, 8, 7, 6, 4, 3]);
      a = frequentForumsTogglePin(a, _f(9));
      expect(_ids(a.pinned), [9]);
      expect(_ids(a.recent), [5, 10, 8, 7, 6, 4, 3]);
      a = frequentForumsVisited(a, const FrequentForum(fid: 9, name: 'Renamed'));
      expect(a.pinned.single.name, 'Renamed');
      expect(_ids(a.recent), [5, 10, 8, 7, 6, 4, 3]);
    });

    test('unpinning puts the forum back first among the recent ones', () {
      var a = frequentForumsTogglePin(const FrequentForumsOfAccount(), _f(1));
      a = frequentForumsTogglePin(a, _f(2));
      a = frequentForumsVisited(a, _f(3));
      a = frequentForumsTogglePin(a, _f(1));
      expect(_ids(a.pinned), [2]);
      expect(_ids(a.recent), [1, 3]);
    });

    test('a pinned forum moves to its new place, as a reorderable list reports it', () {
      var a = const FrequentForumsOfAccount();
      for (final fid in [1, 2, 3, 4]) {
        a = frequentForumsTogglePin(a, _f(fid));
      }
      expect(_ids(frequentForumsReorder(a, 0, 3).pinned), [2, 3, 1, 4]);
      expect(_ids(frequentForumsReorder(a, 3, 0).pinned), [4, 1, 2, 3]);
      expect(_ids(frequentForumsReorder(a, 1, 99).pinned), [1, 3, 4, 2]);
      expect(frequentForumsReorder(a, 7, 0), a);
    });
  });

  group('2. saving', () {
    test('damaged values read as nothing, duplicates and blanks are dropped', () {
      expect(decodeFrequentForums(''), isEmpty);
      expect(decodeFrequentForums('not json'), isEmpty);
      expect(decodeFrequentForums('[1]'), isEmpty);
      final all = decodeFrequentForums(
        jsonEncode({
          '31': {
            'pinned': [
              {'fid': 1, 'name': 'A'},
              {'fid': 1, 'name': 'again'},
              {'fid': 'x', 'name': 'B'},
              {'fid': 2, 'name': ' '},
              3,
            ],
            'recent': [
              {'fid': 1, 'name': 'A'},
              {'fid': 4, 'name': 'D'},
            ],
          },
          'zz': {'pinned': <Object>[]},
          '32': 'oops',
        }),
      );
      expect(all.keys, [31]);
      expect(_ids(all[31]!.pinned), [1]);
      expect(_ids(all[31]!.recent), [4]);
      expect(encodeFrequentForums(const {}), isEmpty);
      expect(encodeFrequentForums({31: const FrequentForumsOfAccount()}), isEmpty);
    });

    test('the store keeps each account apart and survives a restart', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final storage = StorageProvider(db, {}, {});
      final settings = SettingsRepository(storage);
      await settings.init();
      final store = FrequentForumsStore(settings);
      await store.visit(31, _f(1));
      await store.togglePin(31, _f(2));
      await store.visit(32, _f(3));
      await store.visit(null, _f(4));
      expect(_ids(store.current(31).pinned), [2]);
      expect(_ids(store.current(31).recent), [1]);
      expect(_ids(store.current(32).recent), [3]);
      expect(_ids(store.current(null).recent), [4]);
      await settings.dispose();

      final restarted = SettingsRepository(storage);
      await restarted.init();
      final again = FrequentForumsStore(restarted);
      expect(_ids(again.current(31).pinned), [2]);
      expect(_ids(again.current(32).recent), [3]);
      await restarted.dispose();
    });
  });

  group('3 and 4. the bar', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late FrequentForumsStore store;
    late AuthenticationRepository auth;
    late GoRouter router;
    final opened = <String>[];

    setUp(() async {
      opened.clear();
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(() => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))));
      await settings.init();
      getIt.registerSingleton<ImageCacheProvider>(ImageCacheProvider(getIt.get<NetClientProvider>()));
      store = FrequentForumsStore(settings);
      auth = AuthenticationRepository(user: _alice);
    });

    tearDown(() async {
      router.dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    Future<void> settled(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> pumpBar(WidgetTester tester, {List<int> cards = const [7]}) async {
      tester.view
        ..physicalSize = const Size(800, 844)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: Column(
                children: [
                  const FrequentForumsBar(),
                  for (final fid in cards) ForumCard(_forum(fid)),
                ],
              ),
            ),
          ),
          GoRoute(
            path: ScreenPaths.forum,
            name: ScreenPaths.forum,
            builder: (_, state) {
              opened.add(state.pathParameters['fid']!);
              return const Scaffold(body: Text('forum page'));
            },
          ),
        ],
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await settled(tester);
    }

    Finder chip(String name) => find.widgetWithText(ActionChip, name);

    testWidgets('nothing at all without a pinned or recent forum', (tester) async {
      await pumpBar(tester);
      expect(find.byType(ActionChip), findsNothing);
      expect(tester.getSize(find.byType(FrequentForumsBar)).height, 0);
    });

    testWidgets('pinned forums come first and a tap opens the forum', (tester) async {
      await tester.runAsync(() async {
        await store.visit(31, _f(1));
        await store.visit(31, _f(2));
        await store.togglePin(31, _f(3));
        await store.togglePin(31, _f(4));
        await store.visit(32, _f(9));
      });
      await pumpBar(tester);
      final names = tester.widgetList<ActionChip>(find.byType(ActionChip)).map((e) => (e.label as Text).data).toList();
      expect(names, ['Forum 3', 'Forum 4', 'Forum 2', 'Forum 1']);
      expect(find.byIcon(Icons.push_pin_outlined), findsNWidgets(2));
      expect(find.byIcon(Icons.history), findsNWidgets(2));
      await tester.tap(chip('Forum 2'));
      await tester.pumpAndSettle();
      expect(opened, ['2']);
    });

    testWidgets('a long press on a forum card pins it, and again unpins it', (tester) async {
      await pumpBar(tester);
      await tester.longPress(find.byType(ForumCard));
      await tester.pumpAndSettle();
      expect(find.text(tr.forumCard.pin), findsOneWidget);
      await tester.tap(find.text(tr.forumCard.pin));
      await settled(tester);
      await tester.pumpAndSettle();
      expect(chip('Forum 7'), findsOneWidget);
      expect(_ids(store.current(31).pinned), [7]);

      await tester.longPress(find.byType(ForumCard));
      await tester.pumpAndSettle();
      expect(find.text(tr.forumCard.unpin), findsOneWidget);
      await tester.tap(find.text(tr.forumCard.unpin));
      await settled(tester);
      await tester.pumpAndSettle();
      expect(store.current(31).pinned, isEmpty);
      expect(_ids(store.current(31).recent), [7]);
    });

    testWidgets('a pinned forum is dragged to a new place, a recent one stays put', (tester) async {
      await tester.runAsync(() async {
        await store.togglePin(31, _f(1));
        await store.togglePin(31, _f(2));
        await store.visit(31, _f(5));
      });
      await pumpBar(tester);
      final first = tester.getCenter(chip('Forum 1'));
      final gesture = await tester.startGesture(first);
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(120, 0));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await settled(tester);
      await tester.pumpAndSettle();
      expect(_ids(store.current(31).pinned), [2, 1]);
      expect(_ids(store.current(31).recent), [5]);
    });

    testWidgets('another account sees its own forums', (tester) async {
      await tester.runAsync(() async {
        await store.togglePin(31, _f(1));
        await store.togglePin(32, _f(2));
      });
      auth = AuthenticationRepository(user: _bob);
      await pumpBar(tester);
      expect(chip('Forum 2'), findsOneWidget);
      expect(chip('Forum 1'), findsNothing);
    });
  });
}
