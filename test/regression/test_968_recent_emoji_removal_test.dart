/// The emoji panel's recent ones (#338 follow-up): a saved image deleted from "my images" leaves the recent ones too,
/// and any recent one can be removed by a long press there; a
/// removal waits for the list kept on the device, so what it removed does not come back once read.
///
/// Also the message search's types in Chinese (`noticeSearchPage.type`): `bm` is the public messages, `pm` the private
/// ones, as in English.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/editor/repository/recent_emoji_store.dart';
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

const _a = '[img]https://x/a.png[/img]';
const _b = '[img]https://x/b.png[/img]';

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late Directory tmp;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    tmp = Directory.systemTemp.createTempSync('tsdm_recent_removal_');
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

  group('store', () {
    test('a removal waits for the file: what it removed does not come back once read', () async {
      final file = File('${tmp.path}/recent_${DateTime.now().microsecondsSinceEpoch}.json')
        ..writeAsStringSync(
          jsonEncode({
            'v': RecentEmojiStore.formatVersion,
            'codes': [_a, '{:1_1:}', _b],
          }),
        );
      final store = RecentEmojiStore(file: () async => file);
      await store.remove(_a);
      expect(store.recent.value, ['{:1_1:}', _b]);
      await store.pendingWrites;
      expect((jsonDecode(file.readAsStringSync()) as Map)['codes'], ['{:1_1:}', _b]);

      // Read again from the file: still gone.
      final again = RecentEmojiStore(file: () async => file);
      await again.load();
      expect(again.recent.value, ['{:1_1:}', _b]);
      // Removing one not listed writes nothing new.
      await again.remove('{:9_9:}');
      expect(again.recent.value, ['{:1_1:}', _b]);
    });
  });

  group('panel', () {
    late RecentEmojiStore recent;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      recent = RecentEmojiStore.memory();
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        )
        ..registerSingleton<RecentEmojiStore>(recent);
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

    Future<void> flush(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await settle(tester);
    }

    Future<void> finish(WidgetTester tester) async {
      for (var i = 0; i < 100 && tester.binding.imageCache.pendingImageCount > 0; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> pumpPanel(WidgetTester tester, List<String> picked) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [EmojiPanel(height: 240, onPicked: picked.add)],
              ),
            ),
          ),
        ),
      );
      await settle(tester);
    }

    testWidgets('a saved image deleted leaves the recent ones', (tester) async {
      await tester.runAsync(() async {
        await storage.addCustomImage(url: 'https://x/a.png', name: 'first');
        await storage.addCustomImage(url: 'https://x/b.png', name: 'second');
      });
      recent
        ..use(_b)
        ..use(_a);
      await pumpPanel(tester, []);
      await tester.tap(find.text('My images'));
      await settle(tester);
      await tester.longPress(find.byTooltip('first'));
      await settle(tester);
      await tester.tap(find.text('OK'));
      await flush(tester);
      expect((await tester.runAsync(storage.fetchCustomImages))?.map((e) => e.url), ['https://x/b.png']);
      expect(recent.recent.value, [_b]);

      await tester.tap(find.text('Recent'));
      await settle(tester);
      expect(find.byKey(const ValueKey('emoji-panel-$_a')), findsNothing);
      expect(find.byKey(const ValueKey('emoji-panel-$_b')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a long press on a recent one removes it, a tap still inserts', (tester) async {
      recent
        ..use('{:1_1:}')
        ..use(_b);
      final picked = <String>[];
      await pumpPanel(tester, picked);
      expect(find.byKey(const ValueKey('emoji-panel-$_b')), findsOneWidget);

      await tester.longPress(find.byKey(const ValueKey('emoji-panel-$_b')));
      await settle(tester);
      expect(find.text(t.bbcodeEditor.emoji.removeRecent), findsOneWidget);
      // Dismissed: kept.
      await tester.tapAt(Offset.zero);
      await settle(tester);
      expect(recent.recent.value, [_b, '{:1_1:}']);

      await tester.longPress(find.byKey(const ValueKey('emoji-panel-$_b')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('emoji-panel-remove-recent')));
      await flush(tester);
      expect(recent.recent.value, ['{:1_1:}']);
      expect(find.byKey(const ValueKey('emoji-panel-$_b')), findsNothing);
      expect(picked, isEmpty);

      await tester.tap(find.byKey(const ValueKey('emoji-panel-{:1_1:}')));
      await settle(tester);
      expect(picked, ['{:1_1:}']);
      await finish(tester);
    });
  });

  group('message search types', () {
    test('bm is the public messages, pm the private ones, in every language', () async {
      for (final (locale, public, private) in [
        (AppLocale.en, 'Public', 'Private'),
        (AppLocale.zhCn, '公共', '私人'),
        (AppLocale.zhTw, '公用', '私人'),
      ]) {
        final tr = await locale.build();
        expect(tr.noticeSearchPage.type.bm, contains(public), reason: '$locale');
        expect(tr.noticeSearchPage.type.pm, contains(private), reason: '$locale');
      }
    });
  });
}
