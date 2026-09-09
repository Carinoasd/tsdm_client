import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/homepage/widgets/user_operation_dialog.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/heroes.dart';

/// Issue #16: the avatar menu on the homepage offers "Manage account" next to "Favorites"; tapping it closes the menu
/// and opens the manage account page.

/// Never answers: the avatar is not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The homepage app bar, reduced to the avatar button that opens the menu the same way the real one does.
class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      actions: [
        IconButton(
          icon: const Icon(Icons.person),
          onPressed: () async => showHeroDialog(
            context,
            (context, _, _) =>
                const UserOperationDialog(username: 'Alice', avatarUrl: null, heroTag: 'Alice', latestThreadUrl: null),
          ),
        ),
      ],
    ),
    body: const Center(child: Text('homepage')),
  );
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

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
  });

  tearDown(() async {
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<GoRouter> pumpHome(WidgetTester tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const _Home()),
        GoRoute(
          path: ScreenPaths.manageAccount,
          name: ScreenPaths.manageAccount,
          builder: (_, _) => const Scaffold(body: Center(child: Text('manage account page'))),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    expect(find.text('homepage'), findsOneWidget);
    return router;
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.person));
    await tester.pumpAndSettle();
    expect(find.byType(UserOperationDialog), findsOneWidget);
  }

  testWidgets('the menu lists Manage account right after Favorites', (tester) async {
    await pumpHome(tester);
    await openMenu(tester);

    final favorites = find.widgetWithText(ListTile, 'Favorites');
    final manage = find.widgetWithText(ListTile, 'Manage account');
    final latest = find.widgetWithText(ListTile, 'Latest thread');
    expect(favorites, findsOneWidget);
    expect(manage, findsOneWidget);
    expect(latest, findsOneWidget);
    expect(tester.widget<ListTile>(manage).onTap, isNotNull);

    final favoritesY = tester.getTopLeft(favorites).dy;
    final manageY = tester.getTopLeft(manage).dy;
    final latestY = tester.getTopLeft(latest).dy;
    expect(manageY, greaterThan(favoritesY), reason: 'below Favorites');
    expect(manageY, lessThan(latestY), reason: 'above Latest thread');
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping Manage account closes the menu and opens the manage account page', (tester) async {
    final router = await pumpHome(tester);
    await openMenu(tester);

    await tester.tap(find.widgetWithText(ListTile, 'Manage account'));
    await tester.pumpAndSettle();

    expect(find.byType(UserOperationDialog), findsNothing, reason: 'the menu closed');
    expect(find.text('manage account page'), findsOneWidget);
    expect(router.state.uri.path, ScreenPaths.manageAccount);
    expect(tester.takeException(), isNull);
  });
}
