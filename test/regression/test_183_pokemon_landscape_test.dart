import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/pokemon/models/models.dart';
import 'package:tsdm_client/features/pokemon/repository/adventure_cache.dart';
import 'package:tsdm_client/features/pokemon/view/adventure_page.dart';
import 'package:tsdm_client/features/pokemon/view/battle_page.dart';
import 'package:tsdm_client/features/pokemon/view/pokemon_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// A 1x1 transparent png, so the sprites a page draws can actually decode in a widget test.
final Uint8List _pixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Answers the pokemon endpoints with the smallest envelopes that decode, and any image request with a real pixel, so
/// a page can be laid out at a phone's landscape size without touching the network.
final class _PetApiAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream, Future<void>? cancel) async {
    final uri = options.uri;
    // The page the client reads the session formhash from.
    if (uri.queryParameters['id'] == 'pokemon:game') {
      return body('<input type="hidden" name="formhash" value="deadbeef">');
    }
    if (uri.queryParameters['action'] == null) {
      // Every plugin call carries an action; the rest are images.
      return ResponseBody.fromBytes(
        _pixelPng,
        200,
        headers: {
          Headers.contentTypeHeader: ['image/png'],
        },
      );
    }
    switch (uri.queryParameters['action']) {
      case 'recover':
        // No battle running: the adventure page reads that as "nothing to resume".
        return body('{"success":false,"message":"No active battle"}', status: 404);
      case 'maps':
        return body(
          '{"success":true,"data":{"maps":[{ '
          '"id":1,"name":"Veridian Forest","area_type":"l","area_type_name":"Plain", '
          '"min_level":3,"max_level":8,"mode":"wild","wild_pokemons":[{"id":10,"name":"Caterpie"}]}]}}',
        );
      default:
        return body('{"success":true,"data":{}}');
    }
  }

  /// A JSON body (except for the plugin page above, which the client only scans for the formhash).
  static ResponseBody body(String text, {int status = 200}) => ResponseBody.fromString(
    text,
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late Directory tmp;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
    tmp = Directory.systemTemp.createTempSync('tsdm_pokemon_landscape_');
    // The image cache needs a directory, which a widget test has no platform for: answer it on its own channel.
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => switch (call.method) {
        'getApplicationCachePath' || 'getApplicationCacheDirectory' => '${tmp.path}/cache',
        'getApplicationSupportPath' || 'getApplicationSupportDirectory' => '${tmp.path}/support',
        'getTemporaryPath' || 'getTemporaryDirectory' => '${tmp.path}/tmp',
        'getApplicationDocumentsPath' || 'getApplicationDocumentsDirectory' => '${tmp.path}/docs',
        _ => null,
      },
    );
    await initCache();
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    tmp.deleteSync(recursive: true);
  });

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    final dio = Dio()..httpClientAdapter = _PetApiAdapter();
    final client = NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty());
    // This is a layout test: keep the app's interceptors out of the way.
    dio.interceptors.clear();
    getIt
      ..registerSingleton<StorageProvider>(StorageProvider(db, {}, {}))
      ..registerSingleton<AdventureCache>(AdventureCache())
      ..registerSingleton<CookieProvider>(CookieProvider(const UserLoginInfo(username: 'Alice', uid: 1), const {}))
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<NetClientProvider>(client)
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(
          NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty()),
        ),
      );
  });

  tearDown(() async {
    if (getIt.isRegistered<ImageCacheProvider>()) {
      await getIt.get<ImageCacheProvider>().dispose();
    }
    await getIt.reset();
    await db.close();
  });

  /// Lay the next page out at a landscape phone size with a cutout, the shape the logs show when the phone is turned.
  void landscape(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(792, 368);
    tester.view.padding = const FakeViewPadding(left: 44, right: 36, bottom: 24);
    addTearDown(tester.view.reset);
  }

  /// Bounded pumps: a page with images keeps a loading animation running, so [WidgetTester.pumpAndSettle] may never
  /// return.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the pokemon centre lays out in landscape, on every tab', (tester) async {
    landscape(tester);
    await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: PokemonPage())));
    await settle(tester);

    // A render overflow is reported as an exception by the test framework.
    expect(tester.takeException(), isNull);
    expect(find.byType(PokemonPage), findsOneWidget);

    // Every tab has to fit the same short screen, not only the one that is opened first.
    final tabCount = find.byType(Tab).evaluate().length;
    expect(tabCount, 4);
    for (var i = 0; i < tabCount; i++) {
      await tester.tap(find.byType(Tab).at(i));
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'tab $i overflows in landscape');
    }
  });

  testWidgets('the adventure page lays out in landscape', (tester) async {
    landscape(tester);
    await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: AdventurePage())));
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(AdventurePage), findsOneWidget);
  });

  test('a "no battle" answer is only reused for a short while', () {
    final cache = getIt.get<AdventureCache>();
    expect(cache.battleCheckFresh, isFalse);
    cache.markNoBattle();
    expect(cache.battleCheckFresh, isTrue);
    // Starting a battle, or switching account, has to ask the server again.
    cache.invalidateBattleCheck();
    expect(cache.battleCheckFresh, isFalse);
  });

  testWidgets('the battle page lays out in landscape', (tester) async {
    landscape(tester);
    final scene = BattleScene.fromMap(const {
      'battle_id': 'battle_1',
      'map_id': 3,
      'map_name': 'Veridian Forest',
      'status': 'active',
      'turn': 1,
      'my_pokemon': {
        'instance_id': 7,
        'id': 25,
        'name': 'Pikachu',
        'level': 12,
        'hp': 30,
        'max_hp': 40,
        'skills': [
          {'id': 1, 'name': 'Tackle', 'pp': 35, 'max_pp': 35, 'power': 40},
        ],
      },
      'wild_pokemon': {'id': 10, 'name': 'Caterpie', 'level': 5, 'hp': 12, 'max_hp': 18},
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: BattlePage(args: BattlePageArgs.resume(scene, mapId: 3))),
      ),
    );
    await settle(tester);

    expect(tester.takeException(), isNull);
  });
}
