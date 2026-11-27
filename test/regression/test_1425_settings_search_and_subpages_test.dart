/// The settings page in groups of their own, its two sub pages and its search.
///
/// * The cross-device sync is one row of the settings page (`settings-cross-device-sync-entry`) that tells what it is
///   at; its switch (`settings-cross-device-sync`) and the ten lists it may carry are on a page of their own, under
///   the keys they always had. "On" stands also with none of the ten: the sync carries more than them.
/// * The notification categories and the quiet hours are on a page of their own, under the keys they always had.
/// * The search finds a row by its title, its group or the keywords of the language; a switch is switched in the
///   results, a row with a dialog opens it from the settings page, a row of a sub page opens that page.
/// * A switch builds its group again, not the others.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/utils/push_rules.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/cross_device_sync_page.dart';
import 'package:tsdm_client/features/settings/view/notice_categories_page.dart';
import 'package:tsdm_client/features/settings/view/settings_page.dart';
import 'package:tsdm_client/features/settings/view/settings_search.dart';
import 'package:tsdm_client/features/theme/cubit/theme_cubit.dart';
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

Translations get tr => LocaleSettings.instance.currentTranslations;

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

Future<void> _settle(WidgetTester tester, {int rounds = 4}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

const List<SettingsKeys<bool>> _syncKeys = [
  SettingsKeys.crossDeviceSyncRateTemplates,
  SettingsKeys.crossDeviceSyncSettings,
  SettingsKeys.crossDeviceSyncDrafts,
  SettingsKeys.crossDeviceSyncBookmarks,
  SettingsKeys.crossDeviceSyncPinnedForums,
  SettingsKeys.crossDeviceSyncForumWatch,
  SettingsKeys.crossDeviceSyncReplyTemplates,
  SettingsKeys.crossDeviceSyncReadLater,
  SettingsKeys.crossDeviceSyncFollowedThreads,
  SettingsKeys.crossDeviceSyncCustomImages,
];

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late SettingsBloc bloc;
  late ThemeCubit theme;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  setUp(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<AppDatabase>(db)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
    // Made here, outside the fake async zone of the widget tests: a bloc made inside it never finishes closing.
    bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    theme = ThemeCubit();
  });

  tearDown(() async {
    await bloc.close();
    await theme.close();
    await getIt.reset();
    await db.close();
  });

  /// The settings page under a router that knows its sub pages by the names the app gives them.
  Future<void> pumpSettings(WidgetTester tester, {double width = 420}) async {
    tester.view.physicalSize = Size(width, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: ScreenPaths.settings.path,
      routes: [
        GoRoute(
          path: ScreenPaths.settings.path,
          builder: (_, _) => const SettingsPage(),
          routes: [
            GoRoute(
              path: ScreenPaths.settingsCrossDeviceSync.path,
              name: ScreenPaths.settingsCrossDeviceSync.path,
              builder: (_, _) => const SettingsCrossDeviceSyncPage(),
            ),
            GoRoute(
              path: ScreenPaths.settingsNoticeCategories.path,
              name: ScreenPaths.settingsNoticeCategories.path,
              builder: (_, _) => const SettingsNoticeCategoriesPage(),
            ),
          ],
        ),
        GoRoute(
          path: ScreenPaths.debugLog,
          name: ScreenPaths.debugLog,
          builder: (_, _) => Scaffold(appBar: AppBar(), body: const Text('the log page')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<SettingsBloc>.value(value: bloc),
          BlocProvider<ThemeCubit>.value(value: theme),
        ],
        child: TranslationProvider(child: MaterialApp.router(routerConfig: router)),
      ),
    );
    await _settle(tester);
  }

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      BlocProvider<SettingsBloc>.value(
        value: bloc,
        child: TranslationProvider(child: MaterialApp(home: page)),
      ),
    );
    await _settle(tester);
  }

  Future<void> set<T>(WidgetTester tester, SettingsKeys<T> key, T value) async {
    bloc.add(SettingsValueChanged(key, value));
    await _settle(tester);
  }

  Future<void> openSearch(WidgetTester tester, String query) async {
    await tester.tap(find.byKey(const ValueKey('settings-search')));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('settings-search-field')), query);
    await _settle(tester, rounds: 2);
  }

  Finder result(String id) => find.byKey(ValueKey('settings-search-result-$id'));
  final entry = find.byKey(const ValueKey('settings-cross-device-sync-entry'));
  final master = find.byKey(const ValueKey('settings-cross-device-sync'));

  group('the cross-device sync', () {
    testWidgets('one row on the settings page, telling what it is at', (tester) async {
      await pumpSettings(tester);
      final sync = tr.settingsPage.accountSection.crossDeviceSync;
      expect(entry, findsOneWidget);
      expect(tester.widget(entry), isA<ListTile>(), reason: 'a way to the page, no switch');
      expect(master, findsNothing, reason: 'the switch is on the page of the sync');
      for (final key in _syncKeys) {
        expect(find.byKey(ValueKey('settings-${key.name}'), skipOffstage: false), findsNothing);
      }
      final on = _syncKeys.where((k) => k.defaultValue).length;
      final expected = SettingsKeys.crossDeviceSync.defaultValue ? sync.onWith(n: on, total: 10) : sync.off;
      expect(find.descendant(of: entry, matching: find.text(expected)), findsOneWidget);

      await set(tester, SettingsKeys.crossDeviceSync, true);
      for (final key in _syncKeys) {
        await set(tester, key, false);
      }
      expect(
        find.descendant(of: entry, matching: find.text(sync.onWith(n: 0, total: 10))),
        findsOneWidget,
        reason: 'on with none of the ten: the progress, the phrases and the block lists are still synced',
      );
      expect(sync.onWith(n: 0, total: 10), startsWith('已开启'));

      await set(tester, SettingsKeys.crossDeviceSyncDrafts, true);
      expect(find.descendant(of: entry, matching: find.text(sync.onWith(n: 1, total: 10))), findsOneWidget);
      await set(tester, SettingsKeys.crossDeviceSync, false);
      expect(find.descendant(of: entry, matching: find.text(sync.off)), findsOneWidget);
    });

    testWidgets('its page: the switch and the ten lists under the keys they had', (tester) async {
      await pumpSettings(tester);
      await set(tester, SettingsKeys.crossDeviceSync, true);
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await _settle(tester);
      expect(find.byType(SettingsCrossDeviceSyncPage), findsOneWidget);
      expect(master, findsOneWidget);
      expect(entry.hitTestable(), findsNothing);
      expect(tester.widget<SwitchListTile>(master).value, isTrue);
      for (final key in _syncKeys) {
        expect(find.byKey(ValueKey('settings-${key.name}')), findsOneWidget, reason: key.name);
      }

      final drafts = find.byKey(ValueKey('settings-${SettingsKeys.crossDeviceSyncDrafts.name}'));
      final before = tester.widget<SwitchListTile>(drafts).value;
      await tester.tap(drafts);
      await _settle(tester);
      expect(bloc.state.settingsMap.crossDeviceSyncDrafts, !before);
      expect(tester.widget<SwitchListTile>(drafts).value, !before);

      await tester.tap(master);
      await _settle(tester);
      expect(bloc.state.settingsMap.crossDeviceSync, isFalse);
      expect(drafts, findsNothing, reason: 'nothing to choose while the sync is off');
    });
  });

  group('the notification categories', () {
    testWidgets('their page: every category, the interval and the quiet hours under the keys they had', (
      tester,
    ) async {
      await pumpPage(tester, const SettingsNoticeCategoriesPage());
      for (final category in NoticeCategory.values) {
        expect(find.byKey(ValueKey('notice-category-${category.name}')), findsOneWidget, reason: category.name);
      }
      expect(find.byKey(const ValueKey('notice-followed-thread-interval')), findsOneWidget);
      final quiet = find.byKey(const ValueKey('notice-quiet-hours'));
      expect(quiet, findsOneWidget);
      expect(find.byKey(const ValueKey('notice-quiet-start')), findsNothing);

      await tester.tap(quiet);
      await _settle(tester);
      expect(bloc.state.settingsMap.notifyQuietHours, isTrue);
      expect(find.byKey(const ValueKey('notice-quiet-start')), findsOneWidget);
      expect(find.byKey(const ValueKey('notice-quiet-end')), findsOneWidget);

      final reply = find.byKey(const ValueKey('notice-category-reply'));
      await tester.tap(reply);
      await _settle(tester);
      expect(bloc.state.settingsMap.notifyReply, isFalse);
      expect(tester.widget<SwitchListTile>(reply).value, isFalse);
    });

    test('the row of the settings page counts the categories that are on', () {
      final all = noticeCategoriesSummary(tr, bloc.state.settingsMap);
      final total = NoticeCategory.values.length;
      final on = NoticeCategory.values.where((c) => c.settingsKey.defaultValue).length;
      expect(all, tr.settingsPage.behaviorSection.noticeCategories.enabledOf(n: on, total: total));
    });

    testWidgets('none of them is on the settings page', (tester) async {
      await pumpSettings(tester);
      expect(find.byKey(const ValueKey('notice-category-reply'), skipOffstage: false), findsNothing);
      expect(find.byKey(const ValueKey('notice-quiet-hours'), skipOffstage: false), findsNothing);
      // The way to them only where notifications are posted, as the categories were.
      expect(
        find.byKey(const ValueKey('settings-notice-categories'), skipOffstage: false),
        autoSyncPostsNotifications ? findsOneWidget : findsNothing,
      );
    });
  });

  group('the search', () {
    testWidgets('finds a switch by a keyword of the language and switches it in the results', (tester) async {
      await pumpSettings(tester);
      await openSearch(tester, '双栏');
      final row = result('settings-two-pane-layout');
      expect(row, findsOneWidget);
      expect(tester.widget(row), isA<SwitchListTile>());
      final before = bloc.state.settingsMap.twoPaneLayout;
      expect(tester.widget<SwitchListTile>(row).value, before);

      await tester.tap(row);
      await _settle(tester);
      expect(bloc.state.settingsMap.twoPaneLayout, !before);
      expect(tester.widget<SwitchListTile>(row).value, !before, reason: 'the result follows the setting');
      expect(find.byKey(const ValueKey('settings-search-field')), findsOneWidget, reason: 'the search stays');
    });

    testWidgets('by title, by group, every word must be there; nothing found says so', (tester) async {
      await pumpSettings(tester);
      final appearance = tr.settingsPage.appearanceSection;
      await openSearch(tester, appearance.twoPaneLayout.title);
      expect(result('settings-two-pane-layout'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('settings-search-field')), '${appearance.title} 双栏');
      await _settle(tester, rounds: 2);
      expect(result('settings-two-pane-layout'), findsOneWidget, reason: 'the group and a keyword');

      await tester.enterText(find.byKey(const ValueKey('settings-search-field')), '双栏 zzzz');
      await _settle(tester, rounds: 2);
      expect(result('settings-two-pane-layout'), findsNothing);
      expect(find.text(tr.settingsPage.search.empty), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('settings-search-field')), '');
      await _settle(tester, rounds: 2);
      expect(find.byType(ListTile), findsNothing, reason: 'nothing typed, nothing listed');
      expect(find.text(tr.settingsPage.search.empty), findsNothing);
    });

    testWidgets('a row with a dialog: the search closes and the settings page opens it', (tester) async {
      await pumpSettings(tester);
      await openSearch(tester, '繁简');
      final row = result('settings-chinese-display');
      expect(row, findsOneWidget);
      expect(tester.widget(row), isNot(isA<SwitchListTile>()));

      await tester.tap(row);
      await _settle(tester, rounds: 8);
      expect(find.byKey(const ValueKey('settings-search-field')), findsNothing);
      expect(find.byType(SettingsSearchPage), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is Dialog || w is AlertDialog || w is SimpleDialog),
        findsWidgets,
        reason: 'the dialog of the row, opened from the page',
      );
    });

    testWidgets('a row of a sub page opens that page', (tester) async {
      await pumpSettings(tester);
      final sync = tr.settingsPage.accountSection.crossDeviceSync;
      await openSearch(tester, sync.rateTemplates);
      final row = result('settings-${SettingsKeys.crossDeviceSyncRateTemplates.name}');
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.textContaining(sync.title)), findsOneWidget);

      await tester.tap(row);
      await _settle(tester, rounds: 8);
      expect(find.byType(SettingsSearchPage), findsNothing);
      expect(find.byType(SettingsCrossDeviceSyncPage), findsOneWidget);
    });

    testWidgets('the row of the sync itself leads to its page too', (tester) async {
      await pumpSettings(tester);
      await openSearch(tester, '多设备');
      final row = result('settings-cross-device-sync-entry');
      expect(row, findsOneWidget);
      await tester.tap(row);
      await _settle(tester, rounds: 8);
      expect(find.byType(SettingsCrossDeviceSyncPage), findsOneWidget);
    });

    testWidgets('the rows of the collapsed troubleshooting group are found', (tester) async {
      await pumpSettings(tester);
      await openSearch(tester, tr.settingsPage.debugSection.enableDebugOperations.title);
      expect(find.byType(SwitchListTile), findsOneWidget);
    });

    testWidgets('the key of an expansion tile names its header: found by its keywords', (tester) async {
      await pumpSettings(tester);
      await openSearch(tester, '调试');
      expect(result('settings-debug-expansion'), findsOneWidget);
      expect(
        find.descendant(of: result('settings-debug-expansion'), matching: find.text(tr.settingsPage.debugSection.tip)),
        findsOneWidget,
      );
    });

    testWidgets('a row of the collapsed group: the group opens, then the row is tapped', (tester) async {
      await pumpSettings(tester);
      final debug = tr.settingsPage.debugSection;
      expect(find.text(debug.enableDebugOperations.title), findsNothing, reason: 'collapsed');
      await openSearch(tester, debug.viewLog.title);
      await tester.tap(find.widgetWithText(ListTile, debug.viewLog.title));
      await _settle(tester, rounds: 12);
      expect(find.text('the log page'), findsOneWidget, reason: 'the row was tapped');

      await tester.pageBack();
      await _settle(tester, rounds: 6);
      expect(find.text(debug.enableDebugOperations.title).hitTestable(), findsOneWidget, reason: 'the group is open');
    });

    testWidgets('a switch that is no setting of the bloc is followed in the results too', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // As the app lock: the switch keeps its value elsewhere, the settings bloc never hears of it.
      final on = ValueNotifier(false);
      addTearDown(on.dispose);
      await tester.pumpWidget(
        BlocProvider<SettingsBloc>.value(
          value: bloc,
          child: TranslationProvider(
            child: MaterialApp(
              home: Builder(
                builder: (page) => Scaffold(
                  body: Column(
                    children: [
                      ValueListenableBuilder(
                        valueListenable: on,
                        builder: (_, value, _) => SwitchListTile(
                          key: const ValueKey('settings-app-lock-account-switch'),
                          title: const Text('lock when the account changes'),
                          value: value,
                          onChanged: (v) => on.value = v,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(page).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SettingsSearchPage(
                              collect: () => collectSettingsSearchEntries(
                                page as Element,
                                t: tr,
                                settings: bloc.state.settingsMap,
                                noticeCategories: false,
                              ),
                            ),
                          ),
                        ),
                        child: const Text('search'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('search'));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('settings-search-field')), 'lock');
      await _settle(tester, rounds: 2);
      final row = result('settings-app-lock-account-switch');
      expect(tester.widget<SwitchListTile>(row).value, isFalse);

      await tester.tap(row);
      await _settle(tester, rounds: 2);
      expect(on.value, isTrue);
      expect(tester.widget<SwitchListTile>(row).value, isTrue, reason: 'read again after the tap');
      await tester.tap(row);
      await _settle(tester, rounds: 2);
      expect(tester.widget<SwitchListTile>(row).value, isFalse);
    });

    for (final (locale, word) in [(AppLocale.en, 'dark'), (AppLocale.zhTw, '深色'), (AppLocale.zhCn, '夜间')]) {
      testWidgets('keywords of ${locale.languageTag}: "$word" finds the theme mode', (tester) async {
        // Outside the fake clock: a language not loaded yet is loaded with real async work.
        await tester.runAsync(() => LocaleSettings.setLocale(locale));
        await pumpSettings(tester);
        await openSearch(tester, word);
        expect(result('settings-theme-mode'), findsOneWidget);
      });
    }

    test('every language has the same keywords, each naming a row', () {
      final ids = AppLocale.zhCn.translations.settingsPage.search.keywords.keys.toSet();
      for (final locale in AppLocale.values) {
        final keywords = locale.translations.settingsPage.search.keywords;
        expect(keywords.keys.toSet(), ids, reason: locale.languageTag);
        expect(keywords.values.every((e) => e.trim().isNotEmpty), isTrue, reason: locale.languageTag);
      }
    });
  });

  group('rebuilds', () {
    testWidgets('a switch builds its group again, not the others', (tester) async {
      await pumpSettings(tester);
      final twoPane = find.byKey(const ValueKey('settings-two-pane-layout'), skipOffstage: false);
      final dataSaver = find.byKey(const ValueKey('settings-data-saver-mode'), skipOffstage: false);
      final looks = tester.widget(twoPane);
      final others = tester.widget(dataSaver);

      // A setting of the last group.
      await set(tester, SettingsKeys.clipboardLinkPrompt, !bloc.state.settingsMap.clipboardLinkPrompt);
      expect(identical(tester.widget(twoPane), looks), isTrue, reason: 'the looks were not built again');
      expect(identical(tester.widget(dataSaver), others), isFalse, reason: 'its own group was');

      // A setting of the looks.
      final again = tester.widget(dataSaver);
      await set(tester, SettingsKeys.twoPaneLayout, !bloc.state.settingsMap.twoPaneLayout);
      expect(identical(tester.widget(twoPane), looks), isFalse);
      expect(identical(tester.widget(dataSaver), again), isTrue, reason: 'the last group was not built again');

      // A setting no row of the page reads.
      final a = tester.widget(twoPane);
      final b = tester.widget(dataSaver);
      await set(tester, SettingsKeys.homeLayout, 'x');
      expect(identical(tester.widget(twoPane), a), isTrue);
      expect(identical(tester.widget(dataSaver), b), isTrue);
    });
  });
}
