import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/editor/repository/recent_emoji_store.dart';
import 'package:tsdm_client/features/editor/widgets/custom_image_tab.dart';
import 'package:tsdm_client/features/editor/widgets/emoji_panel.dart';
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

/// GitHub #338: the "my images" tab of the reply bar's emoji panel adds and deletes saved images like the editor's
/// sheet does, with the same tab ([CustomImageTab]).

/// A 1x1 transparent PNG so every saved image "loads" without a network.
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
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late Directory tmp;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    tmp = Directory.systemTemp.createTempSync('tsdm_reply_images_');
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
    EmojiPanel.debugGroups = const [];
  });

  tearDown(() async {
    EmojiPanel.debugGroups = null;
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

  /// Finish real image I/O before the cache is disposed and its files deleted, then drop the tree so the timers of
  /// the storage's watch streams run out.
  Future<void> finish(WidgetTester tester) async {
    for (var i = 0; i < 100 && tester.binding.imageCache.pendingImageCount > 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  /// Storage writes run on drift's own timers: let them finish outside the fake clock.
  Future<void> flush(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);
  }

  /// The reply bar's panel as the phone shows it (240 high on the desktop, the keyboard's height or 280 on phones),
  /// on its "my images" tab.
  Future<void> pumpPanel(WidgetTester tester, List<String> picked, {double height = 240, Widget? below}) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (below != null) Expanded(child: below),
                EmojiPanel(height: height, onPicked: picked.add),
              ],
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('My images'));
    await settle(tester);
  }

  testWidgets('empty: the notice and the add tile, in a short panel', (tester) async {
    await pumpPanel(tester, [], height: 200);
    expect(find.text('Save image URLs here and insert them into posts with one tap'), findsOneWidget);
    expect(find.byTooltip('Add image'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('add: same dialog and check as the editor, the panel stays open and shows the new image', (
    tester,
  ) async {
    final picked = <String>[];
    await pumpPanel(tester, picked);

    await tester.tap(find.byTooltip('Add image'));
    await settle(tester);
    expect(find.text('Save an image'), findsOneWidget);

    // The keyboard of the dialog comes up over the panel: nothing overflows.
    tester.view.viewInsets = FakeViewPadding(bottom: 300 * tester.view.devicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await settle(tester);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField).first, 'nope');
    await tester.tap(find.text('OK'));
    await settle(tester);
    expect(find.text('Not an http(s) image URL'), findsOneWidget);
    expect(await tester.runAsync(storage.fetchCustomImages), isEmpty);

    await tester.enterText(find.byType(TextField).first, '[img]https://x/b.png[/img]');
    await tester.enterText(find.byType(TextField).last, 'second');
    await tester.tap(find.text('OK'));
    await flush(tester);
    tester.view.resetViewInsets();
    await settle(tester);

    expect(find.text('Save an image'), findsNothing);
    expect((await tester.runAsync(storage.fetchCustomImages))?.map((e) => e.url), ['https://x/b.png']);
    expect(find.byKey(const ValueKey('emoji-panel')), findsOneWidget);
    expect(find.byTooltip('second'), findsOneWidget);
    expect(find.text('Save image URLs here and insert them into posts with one tap'), findsNothing);
    expect(picked, isEmpty);

    // A tap inserts it and keeps the panel open, like every other emoji there.
    await tester.tap(find.byTooltip('second'));
    await settle(tester);
    expect(picked, ['[img]https://x/b.png[/img]']);
    expect(find.byKey(const ValueKey('emoji-panel')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a tap is remembered among the recent emojis', (tester) async {
    final recent = RecentEmojiStore.memory();
    getIt.registerSingleton<RecentEmojiStore>(recent);
    await tester.runAsync(() => storage.addCustomImage(url: 'https://x/a.png', name: 'first'));
    final picked = <String>[];
    await pumpPanel(tester, picked);
    await tester.tap(find.byTooltip('first'));
    await settle(tester);
    expect(picked, ['[img]https://x/a.png[/img]']);
    expect(recent.recent.value, ['[img]https://x/a.png[/img]']);
    await finish(tester);
  });

  testWidgets('long press deletes after the same confirmation, cancel keeps it', (tester) async {
    await tester.runAsync(() async {
      await storage.addCustomImage(url: 'https://x/a.png', name: 'first');
      await storage.addCustomImage(url: 'https://x/b.png', name: 'second');
    });
    final picked = <String>[];
    await pumpPanel(tester, picked);

    await tester.longPress(find.byTooltip('first'));
    await settle(tester);
    expect(find.text('Remove this image from my images?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await flush(tester);
    expect((await tester.runAsync(storage.fetchCustomImages))!.length, 2);

    await tester.longPress(find.byTooltip('first'));
    await settle(tester);
    await tester.tap(find.text('OK'));
    await flush(tester);
    expect((await tester.runAsync(storage.fetchCustomImages))?.map((e) => e.url), ['https://x/b.png']);
    expect(find.byTooltip('first'), findsNothing);
    expect(find.byTooltip('second'), findsOneWidget);
    expect(picked, isEmpty);
    await finish(tester);
  });

  testWidgets("both pickers follow each other's changes at once", (tester) async {
    await pumpPanel(tester, [], below: const CustomImageTab());
    expect(find.byTooltip('Add image'), findsNWidgets(2));

    // Added from the reply bar's panel (the last add tile), shown by the editor's tab too.
    await tester.tap(find.byTooltip('Add image').last);
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, 'https://x/c.png');
    await tester.enterText(find.byType(TextField).last, 'third');
    await tester.tap(find.text('OK'));
    await flush(tester);
    expect(find.byTooltip('third'), findsNWidgets(2));

    // Deleted from the editor's tab, gone from the panel too.
    await tester.longPress(find.byTooltip('third').first);
    await settle(tester);
    await tester.tap(find.text('OK'));
    await flush(tester);
    expect(find.byTooltip('third'), findsNothing);
    expect(await tester.runAsync(storage.fetchCustomImages), isEmpty);
    await finish(tester);
  });

  testWidgets("the editor's sheet still pops the tapped image and deletes on long press", (tester) async {
    await tester.runAsync(() async {
      await storage.addCustomImage(url: 'https://x/a.png', name: 'first');
      await storage.addCustomImage(url: 'https://x/b.png', name: 'second');
    });
    String? popped;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  popped = await Navigator.of(context).push<String>(
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

    await tester.longPress(find.byTooltip('first'));
    await settle(tester);
    await tester.tap(find.text('OK'));
    await flush(tester);
    expect(find.byTooltip('first'), findsNothing);
    expect((await tester.runAsync(storage.fetchCustomImages))?.map((e) => e.url), ['https://x/b.png']);

    await tester.tap(find.byTooltip('second'));
    await settle(tester);
    expect(popped, '[img]https://x/b.png[/img]');
    expect(find.text('open'), findsOneWidget);
    await finish(tester);
  });
}
