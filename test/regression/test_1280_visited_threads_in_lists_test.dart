/// The thread lists mark the threads read before (11/17 round N1), on top of the reading progress of test_256:
///
/// * a thread read with no reply since is dimmed; one with replies since is not dimmed and tells "+N" after its reply
///   count; a card without a reply count (the latest threads) is still undimmed by the replies since;
/// * the setting "標出看過的貼文" (on by default, synced) turns every mark off: the cards, the guide, the favorites and
///   the read later list look as for a thread never read;
/// * a guest marks nothing;
/// * the dimmed title stays readable: at least WCAG AA on the card in the light and the dark themes, AAA with the
///   platform's high contrast;
/// * the cards read the marks from the records held in memory: one watch of the store for a whole list, not one query
///   per card.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/widgets/favorite_card.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/widgets/guide_section.dart';
import 'package:tsdm_client/features/latest_thread/models/latest_thread.dart';
import 'package:tsdm_client/features/read_later/cubit/read_later_cubit.dart';
import 'package:tsdm_client/features/read_later/view/read_later_page.dart';
import 'package:tsdm_client/features/reading_progress/cubit/reading_progress_cubit.dart';
import 'package:tsdm_client/features/reading_progress/models/reading_progress.dart';
import 'package:tsdm_client/features/reading_progress/repository/reading_progress_store.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/thread_card_appearance.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/utils/html/author_style.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:universal_html/parsing.dart';

const _uid = 31;

/// A [MemoryReadingProgressStore] that counts the watches asked of it.
final class _CountingStore implements ReadingProgressStore {
  final _inner = MemoryReadingProgressStore();
  int watches = 0;

  @override
  Stream<Map<int, ReadingProgress>> watch(int uid) {
    watches++;
    return _inner.watch(uid);
  }

  @override
  Future<void> save(int uid, int tid, ReadingProgress progress) => _inner.save(uid, tid, progress);
}

/// No image is loaded: the avatars fail at once, nothing goes to the network.
final class _NoImages implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

NormalThread _thread(int tid, int replies, {Color? color}) => NormalThread(
  title: 'thread $tid',
  url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
  threadID: '$tid',
  author: const User(name: 'a', url: ''),
  publishDate: null,
  latestReplyAuthor: const User(name: 'a', url: ''),
  latestReplyTime: null,
  iconUrl: '',
  threadType: null,
  replyCount: replies,
  viewCount: 0,
  price: null,
  css: color == null ? null : CssTypes(fontWeight: null, color: color, backgroundColor: null),
  stateSet: const {},
  privilege: null,
  isRecentThread: false,
);

/// A row of the guide page (11 replies).
LatestThread _latest(int tid) {
  final doc = parseHtmlDocument('''
<table><tbody id="normalthread_$tid"><tr>
<td class="icn"></td>
<th class="common"><a href="forum.php?mod=viewthread&tid=$tid&extra=" class="xst">latest $tid</a></th>
<td class="by"><a href="forum.php?mod=forumdisplay&fid=2" target="_blank">Board</a></td>
<td class="by"><cite><a href="home.php?mod=space&uid=1002">Carol</a></cite><em><span>2026-9-4</span></em></td>
<td class="num"><a class="xi2">11</a><em>76</em></td>
<td class="by"><cite><a href="home.php?mod=space&username=Carol">Carol</a></cite><em><a><span title="2026-9-4 20:25">29 分钟前</span></a></em></td>
</tr></tbody></table>''');
  final row = LatestThread.fromTBody(doc.querySelector('tbody')!);
  expect(row.isValid, isTrue);
  return row;
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late _CountingStore store;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _NoImages())),
      );
    await settings.init();
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    store = _CountingStore();
    ThreadAuthorCache.clear();
  });

  tearDown(() async {
    await settingsBloc.close();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<ReadingProgressCubit> cubitOf(int? uid) async {
    final cubit = ReadingProgressCubit(store: store, uid: uid);
    addTearDown(cubit.close);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return cubit;
  }

  Future<void> pump(
    WidgetTester tester,
    ReadingProgressCubit cubit,
    List<Widget> children, {
    ThemeData Function(BuildContext context)? theme,
    bool highContrast = false,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: BlocProvider<SettingsBloc>.value(
          value: settingsBloc,
          child: BlocProvider<ReadingProgressCubit>.value(
            value: cubit,
            child: Builder(
              builder: (context) => MaterialApp(
                theme: theme?.call(context),
                home: MediaQuery(
                  data: MediaQueryData(highContrast: highContrast),
                  child: Scaffold(body: ListView(children: children)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Color colorOf(WidgetTester tester, String text) => tester.widget<Text>(find.text(text)).style!.color!;

  Future<void> setMark(WidgetTester tester, {required bool on}) async {
    settingsBloc.add(SettingsValueChanged(SettingsKeys.threadCardMarkVisited, on));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  testWidgets('read, no reply since: dimmed; replies since: "+N" and not dimmed; never read: as before', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await store.save(_uid, 1, const ReadingProgress(page: 1, floor: 1, seenReplies: 5));
      await store.save(_uid, 2, const ReadingProgress(page: 1, floor: 1, seenReplies: 5));
      // A visit kept before the replies seen were: nothing to compare, dimmed until the next visit keeps them.
      await store.save(_uid, 3, const ReadingProgress());
    });
    final cubit = await tester.runAsync(() => cubitOf(_uid));
    await pump(tester, cubit!, [
      NormalThreadCard(_thread(1, 5)),
      NormalThreadCard(_thread(2, 9)),
      NormalThreadCard(_thread(3, 9)),
      NormalThreadCard(_thread(4, 9)),
    ]);
    expect(colorOf(tester, 'thread 1').a, lessThan(1));
    expect(colorOf(tester, 'thread 2').a, 1);
    expect(colorOf(tester, 'thread 3').a, lessThan(1));
    expect(colorOf(tester, 'thread 4').a, 1);
    expect(find.byKey(const ValueKey('thread-card-new-replies')), findsOneWidget);
    expect(find.textContaining('+4'), findsOneWidget);
  });

  testWidgets('the latest threads show no reply count: the replies since still undim the title, no "+N"', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await store.save(_uid, 21, const ReadingProgress(page: 1, floor: 1, seenReplies: 11));
      await store.save(_uid, 22, const ReadingProgress(page: 1, floor: 1, seenReplies: 8));
    });
    final cubit = await tester.runAsync(() => cubitOf(_uid));
    await pump(tester, cubit!, [LatestThreadCard(_latest(21)), LatestThreadCard(_latest(22))]);
    expect(colorOf(tester, 'latest 21').a, lessThan(1));
    expect(colorOf(tester, 'latest 22').a, 1);
    expect(find.byKey(const ValueKey('thread-card-new-replies')), findsNothing);
  });

  testWidgets('the setting off: no mark anywhere; on again: the marks are back', (tester) async {
    await tester.runAsync(() async {
      for (final tid in [1, 2, 7, 9, 31]) {
        await store.save(_uid, tid, const ReadingProgress(page: 1, floor: 1, seenReplies: 5));
      }
    });
    final cubit = await tester.runAsync(() => cubitOf(_uid));
    await pump(tester, cubit!, [
      NormalThreadCard(_thread(1, 5)),
      NormalThreadCard(_thread(2, 9)),
      const GuideModuleList(
        GuideModule(
          title: 'hot',
          view: 'hot',
          moreUrl: '',
          items: [GuideItem(tid: '7', title: 'guide 7', url: '')],
        ),
      ),
      FavoriteCard(
        const FavoriteThread(favid: '1', tid: '9', title: 'favorite 9', url: ''),
        onRemove: () {},
      ),
    ]);
    expect(colorOf(tester, 'thread 1').a, lessThan(1));
    expect(colorOf(tester, 'guide 7').a, lessThan(1));
    expect(colorOf(tester, 'favorite 9').a, lessThan(1));
    expect(find.textContaining('+4'), findsOneWidget);

    await setMark(tester, on: false);
    expect(settingsBloc.state.settingsMap.threadCardMarkVisited, isFalse);
    for (final text in ['thread 1', 'thread 2', 'guide 7', 'favorite 9']) {
      expect(colorOf(tester, text).a, 1, reason: text);
    }
    expect(find.byKey(const ValueKey('thread-card-new-replies')), findsNothing);

    await setMark(tester, on: true);
    expect(colorOf(tester, 'thread 1').a, lessThan(1));
    expect(colorOf(tester, 'guide 7').a, lessThan(1));
    expect(colorOf(tester, 'favorite 9').a, lessThan(1));
    expect(find.textContaining('+4'), findsOneWidget);
  });

  testWidgets('the read later list dims what was read, and nothing with the setting off', (tester) async {
    await tester.runAsync(() async {
      await storage.addReadLater(uid: _uid, tid: 7, title: 'later 7', time: DateTime(2026, 1, 2));
      await storage.addReadLater(uid: _uid, tid: 8, title: 'later 8', time: DateTime(2026, 1, 3));
      await store.save(_uid, 7, const ReadingProgress(page: 2, floor: 14, seenReplies: 20));
    });
    final progress = await tester.runAsync(() => cubitOf(_uid));
    final readLater = ReadLaterCubit(storageProvider: storage, uid: _uid);
    addTearDown(readLater.close);
    await tester.pumpWidget(
      TranslationProvider(
        child: BlocProvider<SettingsBloc>.value(
          value: settingsBloc,
          child: BlocProvider<ReadingProgressCubit>.value(
            value: progress!,
            child: BlocProvider<ReadLaterCubit>.value(
              value: readLater,
              child: const MaterialApp(home: ReadLaterPage()),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(colorOf(tester, 'later 7').a, lessThan(1));
    expect(colorOf(tester, 'later 8').a, 1);

    await setMark(tester, on: false);
    expect(colorOf(tester, 'later 7').a, 1);
  });

  testWidgets('a forum in the favorites is never dimmed', (tester) async {
    await tester.runAsync(() => store.save(_uid, 9, const ReadingProgress(page: 1, floor: 1, seenReplies: 5)));
    final cubit = await tester.runAsync(() => cubitOf(_uid));
    await pump(tester, cubit!, [
      FavoriteCard(
        const FavoriteForum(favid: '2', fid: '9', title: 'forum 9', url: ''),
        onRemove: () {},
      ),
    ]);
    expect(colorOf(tester, 'forum 9').a, 1);
  });

  testWidgets('a guest marks nothing', (tester) async {
    await tester.runAsync(() => store.save(_uid, 1, const ReadingProgress(page: 1, floor: 1, seenReplies: 5)));
    final cubit = await tester.runAsync(() => cubitOf(null));
    await pump(tester, cubit!, [NormalThreadCard(_thread(1, 9))]);
    expect(colorOf(tester, 'thread 1').a, 1);
    expect(find.byKey(const ValueKey('thread-card-new-replies')), findsNothing);
    expect(store.watches, 0);
  });

  testWidgets('a whole list reads the marks from one watch of the records', (tester) async {
    await tester.runAsync(() async {
      for (var tid = 1; tid <= 40; tid += 2) {
        await store.save(_uid, tid, const ReadingProgress(page: 1, floor: 1, seenReplies: 5));
      }
    });
    final cubit = await tester.runAsync(() => cubitOf(_uid));
    await pump(tester, cubit!, [for (var tid = 1; tid <= 40; tid++) NormalThreadCard(_thread(tid, 5))]);
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, 3000));
    await tester.pump();
    expect(store.watches, 1);
  });

  group('the dimmed title stays readable', () {
    double contrastOn(WidgetTester tester, String text) {
      final theme = Theme.of(tester.element(find.text(text)));
      final background = theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow;
      return contrastRatio(Color.alphaBlend(colorOf(tester, text), background), background);
    }

    for (final (name, brightness) in [('light', Brightness.light), ('dark', Brightness.dark)]) {
      testWidgets('the app theme, $name', (tester) async {
        await tester.runAsync(() async {
          await store.save(_uid, 1, const ReadingProgress(page: 1, floor: 1, seenReplies: 5));
          await store.save(_uid, 2, const ReadingProgress(page: 1, floor: 1, seenReplies: 5));
        });
        final cubit = await tester.runAsync(() => cubitOf(_uid));
        ThemeData theme(BuildContext context) => brightness == Brightness.light
            ? AppTheme.makeLight(context, seedColor: Colors.blue, fontFamily: '')
            : AppTheme.makeDark(context, seedColor: Colors.blue, fontFamily: '');
        // A forum colored title, darker than the theme's text on a dark card.
        await pump(tester, cubit!, [
          NormalThreadCard(_thread(1, 5)),
          NormalThreadCard(_thread(2, 5, color: const Color(0xFF8E44AD))),
        ], theme: theme);
        for (final text in ['thread 1', 'thread 2']) {
          final full = Theme.of(tester.element(find.text(text)));
          final color = colorOf(tester, text);
          final background = full.cardTheme.color ?? full.colorScheme.surfaceContainerLow;
          final fullContrast = contrastRatio(Color.alphaBlend(color.withValues(alpha: 1), background), background);
          expect(contrastOn(tester, text), greaterThanOrEqualTo(math.min(readableContrast, fullContrast) - 0.01));
        }
        expect(colorOf(tester, 'thread 1').a, lessThan(1));

        await pump(tester, cubit, [NormalThreadCard(_thread(1, 5))], theme: theme, highContrast: true);
        expect(contrastOn(tester, 'thread 1'), greaterThanOrEqualTo(highContrastVisitedTitle - 0.01));
        expect(colorOf(tester, 'thread 1').a, lessThan(1));
      });
    }
  });

  test('the setting is on by default and goes with the cross-device sync, as one added later', () {
    expect(SettingsKeys.threadCardMarkVisited.defaultValue, isTrue);
    final synced = syncedSettings.firstWhere((s) => s.key == SettingsKeys.threadCardMarkVisited);
    expect(synced.decode(false), isFalse);
    expect(synced.decode('x'), isNull);
    expect(syncedSettingsAddedLater, contains('threadCardMarkVisited'));
  });

  testWidgets('the switch is in the thread card settings', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: BlocProvider<SettingsBloc>.value(
          value: settingsBloc,
          child: const MaterialApp(home: SettingsThreadCardAppearancePage()),
        ),
      ),
    );
    await tester.pump();
    final tile = find.byKey(const ValueKey('settings-thread-card-mark-visited'));
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first,
    );
    expect(find.text(t.settingsPage.appearanceSection.threadCard.markVisited), findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.pump();
    await tester.tap(find.text(t.settingsPage.appearanceSection.threadCard.markVisited));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(settingsBloc.state.settingsMap.threadCardMarkVisited, isFalse);
  });
}
