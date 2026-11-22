/// The pages of the forum's other plugins among the services of the "me" tab: game center, court, CP system and
/// part-time job, after the app's own services, each opening its forum page in a browser.
///
/// * Where the in-app browser runs, a tap opens it on the exact page; elsewhere the external browser gets it, and a
///   browser that cannot be started is told with the snack bar of the other browser links.
/// * A guest opens the game center; a tap on the other three opens the login page.
/// * The entry of a plugin goes once `status` says the forum switched it off (`site_plugins`, plugin 4.1.0); shown
///   while nothing tells (an older plugin, no `status` asked yet), from the first frame on when it is known already;
///   the page asks the forum nothing for it.
/// * The labels fit their tiles in the three languages.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/me/view/me_page.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
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

/// The plugin entries in order: key, the id `status` names the plugin by, the page and whether a guest is asked for a
/// login.
const _plugins = <(String, String, String, bool)>[
  ('me-plugin-gamecenter', 'gamecenter', '$baseUrl/plugin.php?id=gamecenter', false),
  ('me-plugin-tsdm_court', 'tsdm_court', '$baseUrl/plugin.php?id=tsdm_court:court', true),
  ('me-plugin-tsdmcp', 'tsdmcp', '$baseUrl/plugin.php?id=tsdmcp', true),
  ('me-plugin-np_cliworkdz', 'np_cliworkdz', '$baseUrl/plugin.php?id=np_cliworkdz:work', true),
];

const _urlLauncher = MethodChannel('plugins.flutter.io/url_launcher');

/// Every request of the app fails, and is noted.
final class _OfflineAdapter implements HttpClientAdapter {
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests.add('${options.uri}');
    throw DioException.connectionError(requestOptions: options, reason: 'offline');
  }

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
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(), body: Text('at ${state.uri.path}'));
}

Future<void> _settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// What `status` of 4.1.0 tells, with [off] switched off.
TsdmAppPluginInfo _status({Set<String> off = const {}}) => TsdmAppPluginInfo.fromAnswer({
  'ok': 1,
  'version': '4.1.0',
  'actions': const ['status'],
  'site_plugins': {for (final (_, id, _, _) in _plugins) id: off.contains(id) ? 0 : 1},
})!;

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late GoRouter router;
  late _OfflineAdapter network;

  /// The url of each in-app browser opened.
  final browsed = <String>[];

  /// The url of each page handed to the external browser.
  final launched = <String>[];

  /// What the external browser answers.
  var launches = true;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  setUp(() async {
    TsdmAppApi.reset();
    browsed.clear();
    launched.clear();
    launches = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_urlLauncher, (
      call,
    ) async {
      launched.add((call.arguments as Map<Object?, Object?>)['url']! as String);
      return launches;
    });
    await LocaleSettings.setLocale(AppLocale.zhCn);
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    network = _OfflineAdapter();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = network),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_urlLauncher, null);
    TsdmAppApi.reset();
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
        GoRoute(
          path: ScreenPaths.inAppBrowser,
          name: ScreenPaths.inAppBrowser,
          builder: (_, state) {
            browsed.add(state.uri.queryParameters['url'] ?? '');
            return _Stub(state);
          },
        ),
        GoRoute(path: ScreenPaths.login, name: ScreenPaths.login, builder: (_, state) => _Stub(state)),
      ],
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: RepositoryProvider<AuthenticationRepository>.value(
          value: _Auth(guest ? null : _alice),
          child: Builder(
            builder: (context) => MaterialApp.router(
              routerConfig: router,
              scaffoldMessengerKey: snackbarKey,
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

  /// The services end with [keys], in reading order, right after the pokemon center.
  Future<void> expectPluginEntries(WidgetTester tester, List<String> keys) async {
    final group = find.byKey(const ValueKey('me-group-services'));
    await reveal(tester, group);
    var previous = tester.getTopLeft(find.descendant(of: group, matching: find.byKey(const ValueKey('me-pokemon'))));
    for (final key in keys) {
      final tile = find.descendant(of: group, matching: find.byKey(ValueKey(key)));
      expect(tile, findsOneWidget, reason: key);
      final at = tester.getTopLeft(tile);
      expect(at.dy > previous.dy || (at.dy == previous.dy && at.dx > previous.dx), isTrue, reason: '$key after');
      previous = at;
    }
    for (final (key, _, _, _) in _plugins) {
      if (!keys.contains(key)) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
    }
  }

  testWidgets('with an account: the four entries after the services, each opening its page in the in-app browser', (
    tester,
  ) async {
    await pump(tester, guest: false);
    await expectPluginEntries(tester, [for (final (key, _, _, _) in _plugins) key]);
    for (final (label, (key, _, _, _)) in [
      (tr.mePage.entries.gameCenter, _plugins[0]),
      (tr.mePage.entries.court, _plugins[1]),
      (tr.mePage.entries.cpSystem, _plugins[2]),
      (tr.mePage.entries.partTimeJob, _plugins[3]),
    ]) {
      expect(
        find.descendant(of: find.byKey(ValueKey(key)), matching: find.text(label)),
        findsOneWidget,
        reason: key,
      );
    }
    for (final (key, _, url, _) in _plugins) {
      browsed.clear();
      await reveal(tester, find.byKey(ValueKey(key)));
      await tester.tap(find.byKey(ValueKey(key)));
      await _settle(tester, rounds: 4);
      expect(find.text('at ${ScreenPaths.inAppBrowser}'), findsOneWidget, reason: key);
      expect(browsed.toSet(), {url}, reason: key);
      router.pop();
      await _settle(tester, rounds: 4);
    }
    expect(launched, isEmpty);
    expect(network.requests, isEmpty, reason: 'the page asks the forum nothing for the entries');
    expect(tester.takeException(), isNull);
  });

  testWidgets('as a guest: the game center opens, the other three ask for a login', (tester) async {
    await pump(tester, guest: true);
    await expectPluginEntries(tester, [for (final (key, _, _, _) in _plugins) key]);
    for (final (key, _, url, needLogin) in _plugins) {
      browsed.clear();
      await reveal(tester, find.byKey(ValueKey(key)));
      await tester.tap(find.byKey(ValueKey(key)));
      await _settle(tester, rounds: 4);
      expect(find.text('at ${needLogin ? ScreenPaths.login : ScreenPaths.inAppBrowser}'), findsOneWidget, reason: key);
      expect(browsed.toSet(), needLogin ? isEmpty : {url}, reason: key);
      router.pop();
      await _settle(tester, rounds: 4);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('without the in-app browser: the external browser, and the snack bar when it cannot start', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await pump(tester, guest: false);
    final (key, _, url, _) = _plugins[2];
    await reveal(tester, find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await _settle(tester, rounds: 4);
    expect(launched, [url]);
    expect(browsed, isEmpty);
    expect(find.text(tr.openInAppPage.browserLaunchFailed), findsNothing);

    launches = false;
    await tester.tap(find.byKey(ValueKey(key)));
    await _settle(tester, rounds: 4);
    expect(launched, [url, url]);
    expect(find.text(tr.openInAppPage.browserLaunchFailed), findsOneWidget);
    expect(find.byKey(const ValueKey('me-page-list')), findsOneWidget, reason: 'nothing pushed');
    // The snack bar times out on its own.
    await tester.pump(const Duration(seconds: 10));
    await _settle(tester, rounds: 2);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('an entry goes once status says its plugin is off, and comes back once it says on', (tester) async {
    await pump(tester, guest: false);
    final all = [for (final (key, _, _, _) in _plugins) key];
    await expectPluginEntries(tester, all);

    // An older plugin's status: nothing told.
    TsdmAppApi.pluginInfo.value = TsdmAppPluginInfo.fromAnswer(const {
      'ok': 1,
      'version': '4.0.0',
      'actions': ['status'],
    });
    await _settle(tester, rounds: 2);
    await expectPluginEntries(tester, all);

    TsdmAppApi.pluginInfo.value = _status(off: {'tsdmcp'});
    await _settle(tester, rounds: 2);
    await expectPluginEntries(tester, all.where((e) => e != 'me-plugin-tsdmcp').toList());

    TsdmAppApi.pluginInfo.value = _status(off: {'gamecenter', 'tsdm_court', 'tsdmcp', 'np_cliworkdz'});
    await _settle(tester, rounds: 2);
    await expectPluginEntries(tester, const []);
    // The services of the app itself stay.
    expect(find.byKey(const ValueKey('me-pokemon')), findsOneWidget);

    TsdmAppApi.pluginInfo.value = _status();
    await _settle(tester, rounds: 2);
    await expectPluginEntries(tester, all);
    expect(network.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an entry known off is never shown', (tester) async {
    TsdmAppApi.pluginInfo.value = _status(off: {'np_cliworkdz'});
    // Tall enough for the whole page in the first frame: the entry is not merely scrolled away.
    await pump(tester, guest: false, size: const Size(1280, 2400));
    expect(find.byKey(const ValueKey('me-pokemon')), findsOneWidget);
    expect(find.byKey(const ValueKey('me-plugin-np_cliworkdz')), findsNothing);
    await expectPluginEntries(tester, [
      for (final (key, id, _, _) in _plugins)
        if (id != 'np_cliworkdz') key,
    ]);
  });

  for (final locale in [AppLocale.zhCn, AppLocale.zhTw, AppLocale.en]) {
    for (final (name, size) in [('narrow', const Size(320, 640)), ('wide', const Size(1280, 800))]) {
      testWidgets('${locale.languageTag} $name: the labels fit their tiles', (tester) async {
        await tester.runAsync(() => LocaleSettings.setLocale(locale));
        await pump(tester, guest: false, size: size);
        await expectPluginEntries(tester, [for (final (key, _, _, _) in _plugins) key]);
        final width = tester.getSize(find.byKey(const ValueKey('me-pokemon'))).width;
        for (final (key, _, _, _) in _plugins) {
          expect(tester.getSize(find.byKey(ValueKey(key))).width, moreOrLessEquals(width), reason: key);
          // English only at full width: every glyph of the test font is as wide as it is high.
          if (locale != AppLocale.en || name == 'wide') {
            final label = find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(RichText)).last;
            expect(tester.renderObject<RenderParagraph>(label).didExceedMaxLines, isFalse, reason: '$key $name');
          }
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
