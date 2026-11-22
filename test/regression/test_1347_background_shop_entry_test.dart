/// The entry of the background shop among the services of the "me" tab, from what `status` told (nothing is asked for
/// it):
///
/// * `bgshop: 1` (plugin 4.1.0): the app's own pages;
/// * no `bgshop: 1` but `bggrant: 1` (plugin 3.9.0 to 4.0.x, or a background plugin too old for 4.1.0): the website's
///   page in a browser;
/// * neither, or no `status` told yet: no entry. A guest's tap asks for a login.
///
/// `status` is read into [TsdmAppPluginInfo.backgroundShop]: only a `status` tells it, an answer of the same version
/// that does not keeps it, and forgetting the flags of 4.0.0 keeps it too.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

const ValueKey<String> _entry = ValueKey('me-background-shop');
const _web = '$baseUrl/plugin.php?id=background:memcp';

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

/// A `status` of [version] with [flags].
TsdmAppPluginInfo _status(Map<String, Object> flags, {String version = '4.1.0'}) => TsdmAppPluginInfo.fromAnswer({
  'ok': 1,
  'version': version,
  'actions': const ['status'],
  ...flags,
})!;

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  GoRouter? router;
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
    router?.dispose();
    router = null;
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
        GoRoute(
          path: ScreenPaths.backgroundShop,
          name: ScreenPaths.backgroundShop,
          builder: (_, state) => _Stub(state),
        ),
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

  testWidgets("bgshop 1: the app's own pages", (tester) async {
    TsdmAppApi.pluginInfo.value = _status(const {'bgshop': 1, 'bggrant': 1});
    await pump(tester, guest: false);
    await reveal(tester, find.byKey(_entry));
    expect(find.descendant(of: find.byKey(_entry), matching: find.text(tr.backgroundShop.title)), findsOneWidget);
    await tester.tap(find.byKey(_entry));
    await _settle(tester, rounds: 4);
    expect(find.text('at ${ScreenPaths.backgroundShop}'), findsOneWidget);
    expect(browsed, isEmpty);
    expect(network.requests, isEmpty);
  });

  for (final flags in const <Map<String, Object>>[
    {'bggrant': 1},
    {'bgshop': 0, 'bggrant': 1},
  ]) {
    testWidgets('$flags: the website in a browser', (tester) async {
      TsdmAppApi.pluginInfo.value = _status(flags, version: flags.containsKey('bgshop') ? '4.1.0' : '4.0.0');
      await pump(tester, guest: false);
      await reveal(tester, find.byKey(_entry));
      await tester.tap(find.byKey(_entry));
      await _settle(tester, rounds: 4);
      expect(find.text('at ${ScreenPaths.inAppBrowser}'), findsOneWidget);
      expect(browsed, [_web]);
      expect(network.requests, isEmpty);
    });
  }

  testWidgets('neither, or nothing told: no entry; told later, it comes', (tester) async {
    await pump(tester, guest: false, size: const Size(1280, 2400));
    expect(find.byKey(const ValueKey('me-pokemon')), findsOneWidget);
    expect(find.byKey(_entry), findsNothing);
    TsdmAppApi.pluginInfo.value = _status(const {'bgshop': 0, 'bggrant': 0});
    await _settle(tester, rounds: 2);
    expect(find.byKey(_entry), findsNothing);
    TsdmAppApi.pluginInfo.value = _status(const {'bgshop': 1});
    await _settle(tester, rounds: 2);
    expect(find.byKey(_entry), findsOneWidget);
    expect(network.requests, isEmpty);
  });

  testWidgets('a guest is asked to log in', (tester) async {
    TsdmAppApi.pluginInfo.value = _status(const {'bgshop': 1});
    await pump(tester, guest: true);
    await reveal(tester, find.byKey(_entry));
    await tester.tap(find.byKey(_entry));
    await _settle(tester, rounds: 4);
    expect(find.text('at ${ScreenPaths.login}'), findsOneWidget);
  });

  test('only status tells it; the same version keeps it; forgetting the 4.0.0 flags keeps it', () {
    expect(_status(const {'bgshop': 1}).backgroundShop, TsdmAppBackgroundShop.native);
    expect(_status(const {'bggrant': 1}).backgroundShop, TsdmAppBackgroundShop.web);
    expect(_status(const {'bgshop': 0, 'bggrant': 1}).backgroundShop, TsdmAppBackgroundShop.web);
    expect(_status(const {'bggrant': 0}).backgroundShop, TsdmAppBackgroundShop.none);
    // Before 3.9.0: neither named.
    expect(_status(const {}).backgroundShop, isNull);
    expect(TsdmAppPluginInfo.fromAnswer(const {'ok': 1, 'version': '4.1.0', 'bgshop': 1})!.backgroundShop, isNull);
    expect(_status(const {'bgshop': 1}), isNot(_status(const {'bggrant': 1})));

    TsdmAppApi.pluginInfo.value = _status(const {'bgshop': 1, 'v4': 1});
    TsdmAppApi.forgetStatus();
    expect(TsdmAppApi.backgroundShop, TsdmAppBackgroundShop.native);
  });
}
