import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/editor/utils/custom_image_input.dart';
import 'package:tsdm_client/features/editor/widgets/custom_image_tab.dart';
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

/// GitHub #5: the user's own image stickers, saved as urls and inserted into posts from the emoji picker.
/// A 1x1 transparent PNG so every sticker "loads" without a network.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    _png,
    200,
    headers: {
      Headers.contentTypeHeader: ['image/png'],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('parseCustomImageInput', () {
    test('accepts a bare url and the [img] codes hosting sites hand out', () {
      expect(parseCustomImageInput(' https://img.example.com/a.png '), 'https://img.example.com/a.png');
      expect(parseCustomImageInput('[img]https://img.example.com/a.png[/img]'), 'https://img.example.com/a.png');
      expect(parseCustomImageInput('[IMG=300,200]http://img.example.com/b.gif[/IMG]'), 'http://img.example.com/b.gif');
      expect(parseCustomImageInput('[img]\nhttps://img.example.com/c.jpg\n[/img]'), 'https://img.example.com/c.jpg');
    });

    test('rejects everything else', () {
      expect(parseCustomImageInput(''), isNull);
      expect(parseCustomImageInput('not a url'), isNull);
      expect(parseCustomImageInput('ftp://x/y.png'), isNull);
      expect(parseCustomImageInput('[url]https://example.com[/url]'), isNull);
    });

    test('the emoji picker result of a sticker is its [img] code', () {
      expect(customImageBBCode('https://x/y.png'), '[img]https://x/y.png[/img]');
      expect(isCustomImageBBCode('[img]https://x/y.png[/img]'), isTrue);
      expect(isCustomImageBBCode('{:12_345:}'), isFalse);
      expect(isCustomImageBBCode(null), isFalse);
    });
  });

  group('storage', () {
    late AppDatabase db;
    late StorageProvider storage;
    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
    });
    tearDown(() => db.close());

    test('keeps insertion order, dedupes by url, deletes by id and watches', () async {
      final events = <int>[];
      final sub = storage.watchCustomImages().listen((e) => events.add(e.length));
      final a = await storage.addCustomImage(url: 'https://x/a.png', name: 'a');
      await storage.addCustomImage(url: 'https://x/b.png');
      final again = await storage.addCustomImage(url: 'https://x/a.png', name: 'renamed');
      expect(again, a);
      final all = await storage.fetchCustomImages();
      expect(all.map((e) => e.url), ['https://x/a.png', 'https://x/b.png']);
      expect(all.first.name, 'renamed');
      await storage.deleteCustomImage(a);
      expect((await storage.fetchCustomImages()).map((e) => e.url), ['https://x/b.png']);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events.last, 1);
      await sub.cancel();
    });
  });

  group('CustomImageTab', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late Directory tmp;
    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('tsdm_stickers_');
      // Image cache directories under a temp folder, answered on the path_provider channel.
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
    tearDownAll(() => tmp.delete(recursive: true));
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
    });
    tearDown(() async {
      if (getIt.isRegistered<ImageCacheProvider>()) {
        await getIt.get<ImageCacheProvider>().dispose();
      }
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    /// Bounded pumps: the image widgets keep a loading animation running, so pumpAndSettle never returns.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('tapping a saved image pops its [img] code, the add dialog validates the url', (tester) async {
      await storage.addCustomImage(url: 'https://x/a.png', name: 'first');
      String? picked;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    picked = await Navigator.of(context).push<String>(
                      MaterialPageRoute(
                        builder: (_) => const Scaffold(body: SizedBox(height: 400, child: CustomImageTab())),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.byTooltip('first'), findsOneWidget);

      // Add: invalid input shows the error and keeps the dialog, a valid url saves a second sticker.
      await tester.tap(find.byIcon(Icons.add_outlined));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, 'nope');
      await tester.tap(find.text('Ok'));
      await settle(tester);
      expect(find.text('Not an http(s) image url'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '[img]https://x/b.png[/img]');
      await tester.enterText(find.byType(TextField).last, 'second');
      await tester.tap(find.text('Ok'));
      await settle(tester);
      expect((await storage.fetchCustomImages()).map((e) => e.url), ['https://x/a.png', 'https://x/b.png']);
      expect(find.byTooltip('second'), findsOneWidget);

      await tester.tap(find.byTooltip('first'));
      await settle(tester);
      expect(picked, '[img]https://x/a.png[/img]');
      expect(tester.takeException(), isNull);
    });
  });
}
