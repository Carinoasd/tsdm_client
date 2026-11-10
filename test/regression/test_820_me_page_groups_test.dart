/// The "me" tab in groups: the pages of the account in three grids (content, social, stats), the services of the forum
/// in the same grid, the app's list last; a guest gets the services only, a tap on one that needs an account opens the
/// login page.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/me/view/me_page.dart';
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

Translations get tr => LocaleSettings.instance.currentTranslations;

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

const _content = [
  'me-my-threads',
  'me-favorites',
  'me-collections',
  'me-followed-threads',
  'me-floor-bookmarks',
  'me-read-later',
  'me-history',
  'me-local-drafts',
  'me-drafts',
];
const _social = ['me-messages', 'me-friends', 'me-visitors'];
const _stats = ['me-points', 'me-checkin-calendar', 'me-reading-stats', 'me-rating-stats', 'me-site-stats'];

/// The services in order, their page and whether a guest is asked for a login.
const _services = <(String, String, bool)>[
  ('me-tasks', ScreenPaths.taskCenter, true),
  ('me-magic', ScreenPaths.magicCenter, true),
  ('me-bank', ScreenPaths.bank, true),
  ('me-ranklist', ScreenPaths.ranklist, false),
  ('me-activities', ScreenPaths.activities, true),
  ('me-medal-center', ScreenPaths.medalCenter, true),
  ('me-title-shop', ScreenPaths.titleShop, true),
  ('me-medals', ScreenPaths.medalTitleHub, true),
  ('me-achievements', ScreenPaths.achievements, true),
  ('me-pokemon', ScreenPaths.pokemon, true),
];

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  final UserLoginInfo? currentUser;
}

class _Stub extends StatelessWidget {
  const _Stub(this.state);

  final GoRouterState state;

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(), body: Text('at ${state.uri}'));
}

Future<void> _settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late GoRouter router;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  setUp(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
  });

  tearDown(() async {
    router.dispose();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, {required bool guest, Size size = const Size(411, 868)}) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    router = GoRouter(
      initialLocation: ScreenPaths.me,
      routes: [
        GoRoute(path: ScreenPaths.me, name: ScreenPaths.me, builder: (_, _) => const MePage()),
        for (final path in {
          ScreenPaths.login,
          ScreenPaths.loggedUserProfile,
          ScreenPaths.manageAccount,
          ScreenPaths.settings.path,
          ScreenPaths.about,
          for (final (_, path, _) in _services) path,
        })
          GoRoute(path: path, name: path, builder: (_, state) => _Stub(state)),
      ],
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: RepositoryProvider<AuthenticationRepository>.value(
          value: _Auth(guest ? null : _alice),
          child: Builder(
            builder: (context) => MaterialApp.router(
              routerConfig: router,
              locale: TranslationProvider.of(context).flutterLocale,
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  final list = find.descendant(of: find.byKey(const ValueKey('me-page-list')), matching: find.byType(Scrollable)).first;

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200, scrollable: list);
    await tester.ensureVisible(finder);
    await _settle(tester, rounds: 2);
  }

  /// The tiles of [group] are all in it, in reading order: left to right, then the next row.
  Future<void> expectGroup(WidgetTester tester, String group, List<String> keys) async {
    final groupFinder = find.byKey(ValueKey(group));
    await reveal(tester, groupFinder);
    Offset? previous;
    for (final key in keys) {
      final tile = find.descendant(of: groupFinder, matching: find.byKey(ValueKey(key)));
      expect(tile, findsOneWidget, reason: '$key in $group');
      final at = tester.getTopLeft(tile);
      if (previous != null) {
        expect(at.dy > previous.dy || (at.dy == previous.dy && at.dx > previous.dx), isTrue, reason: '$key after');
      }
      previous = at;
    }
  }

  testWidgets('with an account: content, social, stats, services and the app, in this order', (tester) async {
    await pump(tester, guest: false);
    for (final (group, title, keys) in [
      ('me-group-content', tr.mePage.content, _content),
      ('me-group-social', tr.mePage.social, _social),
      ('me-group-stats', tr.mePage.stats, _stats),
      ('me-group-services', tr.mePage.services, [for (final (key, _, _) in _services) key]),
    ]) {
      await expectGroup(tester, group, keys);
      expect(find.descendant(of: find.byKey(ValueKey(group)), matching: find.text(title)), findsOneWidget);
    }
    // The groups follow one another down the page, the app's list last.
    await tester.scrollUntilVisible(find.byKey(const ValueKey('me-group-content')), -200, scrollable: list);
    double? top;
    for (final key in ['me-group-content', 'me-group-social', 'me-group-stats', 'me-group-services', 'me-settings']) {
      await reveal(tester, find.byKey(ValueKey(key)));
      final scrollable = tester.state<ScrollableState>(list);
      final at = tester.getTopLeft(find.byKey(ValueKey(key))).dy + scrollable.position.pixels;
      if (top != null) {
        expect(at, greaterThan(top), reason: key);
      }
      top = at;
    }
    expect(find.byKey(const ValueKey('me-manage-accounts')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with an account: every service opens its page', (tester) async {
    await pump(tester, guest: false);
    for (final (key, path, _) in _services) {
      await reveal(tester, find.byKey(ValueKey(key)));
      await tester.tap(find.byKey(ValueKey(key)));
      await _settle(tester, rounds: 4);
      expect(find.text('at $path'), findsOneWidget, reason: key);
      router.pop();
      await _settle(tester, rounds: 4);
    }
  });

  testWidgets('as a guest: the services, a tap on one that needs an account opens the login page', (tester) async {
    await pump(tester, guest: true);
    expect(find.byKey(const ValueKey('me-guest-card')), findsOneWidget);
    for (final group in ['me-group-content', 'me-group-social', 'me-group-stats']) {
      expect(find.byKey(ValueKey(group)), findsNothing, reason: group);
    }
    expect(find.byKey(const ValueKey('me-manage-accounts')), findsNothing);
    await expectGroup(tester, 'me-group-services', [for (final (key, _, _) in _services) key]);
    for (final (key, path, needLogin) in _services) {
      await reveal(tester, find.byKey(ValueKey(key)));
      await tester.tap(find.byKey(ValueKey(key)));
      await _settle(tester, rounds: 4);
      expect(find.text('at ${needLogin ? ScreenPaths.login : path}'), findsOneWidget, reason: key);
      router.pop();
      await _settle(tester, rounds: 4);
    }
    expect(tester.takeException(), isNull);
  });

  for (final locale in [AppLocale.zhCn, AppLocale.zhTw, AppLocale.en]) {
    for (final (name, size) in [
      ('narrow', const Size(320, 640)),
      ('narrowest wide', const Size(640, 800)),
      ('wide', const Size(1280, 800)),
    ]) {
      testWidgets('${locale.languageTag} $name: every group renders without overflow', (tester) async {
        // Loading the translations is real async work: out of the fake clock of the test.
        await tester.runAsync(() => LocaleSettings.setLocale(locale));
        await pump(tester, guest: false, size: size);
        double? tileWidth;
        for (final (group, keys) in [
          ('me-group-content', _content),
          ('me-group-social', _social),
          ('me-group-stats', _stats),
          ('me-group-services', [for (final (key, _, _) in _services) key]),
        ]) {
          await expectGroup(tester, group, keys);
          // Four on a row on phones, five in wider windows: the tile after the last of a row starts the next one.
          final columns = name == 'narrow' ? 4 : 5;
          final rows = {for (final key in keys) tester.getTopLeft(find.byKey(ValueKey(key))).dy};
          expect(rows, hasLength((keys.length + columns - 1) ~/ columns), reason: group);
          if (keys.length > columns) {
            expect(
              tester.getTopLeft(find.byKey(ValueKey(keys[columns]))).dx,
              tester.getTopLeft(find.byKey(ValueKey(keys[0]))).dx,
              reason: group,
            );
          }
          // Every tile as wide as those of the first group, a short group included.
          tileWidth ??= tester.getSize(find.byKey(ValueKey(keys.first))).width;
          expect(tester.getSize(find.byKey(ValueKey(keys.last))).width, moreOrLessEquals(tileWidth), reason: group);
          // Every label shown whole, at most two lines. English only at full width: every glyph of the test font is as
          // wide as it is high, a long word such as "statistics" takes twice its real width.
          if (locale != AppLocale.en || name == 'wide') {
            for (final key in keys) {
              final labels = find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text));
              final paragraph = tester.renderObject<RenderParagraph>(
                find.descendant(of: labels.last, matching: find.byType(RichText)),
              );
              expect(paragraph.didExceedMaxLines, isFalse, reason: '$key $name');
            }
          }
        }
        await reveal(tester, find.byKey(const ValueKey('me-about')));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
