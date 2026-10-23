/// The image cache table is no longer read whole before the first frame (cold start, UX audit item 5): a large table
/// (150 000 rows) doubled the time to it.
///
/// 1. rows are looked up by their url in the table, the ones read or written lately kept in memory (a bounded number,
///    the least recently used one dropped first);
/// 2. the times images were shown are written in batches: in memory at once, in the table every few seconds, when many
///    wait, or when the app goes to the background;
/// 3. the image cache provider reads a cached image through that lookup, and loads the image again when its file can
///    not be read (deleted or unreadable) instead of failing.
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/dao/dao.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

String _url(int i) => 'https://img.example/$i.png';

/// Answers every image request with [bytes] and counts them.
final class _Images implements HttpClientAdapter {
  _Images(this.bytes);

  final List<int> bytes;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late Directory tmp;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    tmp = Directory.systemTemp.createTempSync('tsdm_image_lookup_');
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => switch (call.method) {
        'getApplicationCachePath' || 'getApplicationCacheDirectory' => '${tmp.path}/cache',
        'getApplicationSupportPath' || 'getApplicationSupportDirectory' => '${tmp.path}/support',
        'getTemporaryPath' || 'getTemporaryDirectory' => '${tmp.path}/tmp',
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

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() async {
    await getIt.reset();
    await db.close();
  });

  Future<void> insertRows(int count, {DateTime? usedAt}) => db.batch(
    (b) => b.insertAll(db.image, [
      for (var i = 0; i < count; i++)
        ImageCompanion.insert(
          url: _url(i),
          fileName: '$i',
          lastCachedTime: usedAt ?? DateTime(2026),
          lastUsedTime: usedAt ?? DateTime(2026),
        ),
    ]),
  );

  Future<DateTime?> usedTimeInTable(String url) async => (await ImageDao(db).selectImageByUrl(url))?.lastUsedTime;

  group('1. rows are looked up by their url', () {
    test('the start reads no image row: no preload, the app provider is built without one', () {
      final providers = File('lib/shared/providers/providers.dart').readAsStringSync();
      expect(providers, isNot(contains('preloadImageCache')));
      expect(providers, contains('StorageProvider.forApp(db, preloadedCookie)'));
      final storage = File('lib/shared/providers/storage_provider/storage_provider.dart').readAsStringSync();
      expect(storage, isNot(contains('preloadImageCache')));
      expect(storage, isNot(contains('ImageDao(db).selectAll()')));
    });

    test('found in the table by its key, then kept in memory', () async {
      await insertRows(3000);
      final storage = StorageProvider(db, {}, {});
      expect(storage.imageCacheMemoryCount, 0, reason: 'nothing read up front');
      expect((await storage.getImageCache(_url(2999)))?.fileName, '2999');
      expect(storage.imageCacheMemoryCount, 1);
      // Read from memory now: the row is gone from the table but not asked again.
      await (db.delete(db.image)..where((e) => e.url.equals(_url(2999)))).go();
      expect((await storage.getImageCache(_url(2999)))?.fileName, '2999');
      expect(await storage.getImageCache(_url(5000)), isNull, reason: 'not cached');
    });

    test('memory keeps at most its capacity, the least recently used row goes first', () async {
      const capacity = StorageProvider.imageCacheMemoryCapacity;
      await insertRows(capacity + 10);
      final storage = StorageProvider(db, {}, {});
      for (var i = 0; i < capacity; i++) {
        await storage.getImageCache(_url(i));
      }
      // Row 0 used again: row 1 is the least recently used one now.
      await storage.getImageCache(_url(0));
      for (var i = capacity; i < capacity + 10; i++) {
        await storage.getImageCache(_url(i));
      }
      expect(storage.imageCacheMemoryCount, capacity);
      await (db.delete(db.image)..where((e) => e.url.isIn([_url(0), _url(1)]))).go();
      expect(await storage.getImageCache(_url(0)), isNotNull, reason: 'kept in memory');
      expect(await storage.getImageCache(_url(1)), isNull, reason: 'dropped from memory, gone from the table');
    });

    test('a row read while the table was written stays out of memory', () async {
      await insertRows(1);
      final storage = StorageProvider(db, {}, {});
      final reading = storage.getImageCache(_url(0));
      await storage.updateImageCache(_url(0), fileName: 'again');
      expect((await reading)?.fileName, anyOf('0', 'again'));
      expect((await storage.getImageCache(_url(0)))?.fileName, 'again', reason: 'the write wins');
    });

    test('a cleared cache leaves nothing in memory', () async {
      await insertRows(3);
      final storage = StorageProvider(db, {}, {});
      await storage.getImageCache(_url(1));
      await storage.clearImageCache();
      expect(storage.imageCacheMemoryCount, 0);
      expect(await storage.getImageCache(_url(1)), isNull);
    });
  });

  group('2. the times images were shown are written in batches', () {
    test('in memory at once, in the table with the next batch', () async {
      final old = DateTime(2026);
      await insertRows(3, usedAt: old);
      final storage = StorageProvider(db, {}, {});
      await storage.getImageCache(_url(1));
      // The first one after a quiet while goes at once, the next ones wait for the batch.
      storage
        ..markImageCacheUsed(_url(0))
        ..markImageCacheUsed(_url(1));
      await storage.flushImageCacheUsedTimes();
      expect((await usedTimeInTable(_url(0)))!.isAfter(old), isTrue);
      storage.markImageCacheUsed(_url(2));
      await pumpEventQueue();
      expect(await usedTimeInTable(_url(2)), old, reason: 'waits in memory');
      expect((await storage.getImageCache(_url(1)))!.lastUsedTime.isAfter(old), isTrue, reason: 'memory knows');
      expect(
        (await storage.getImageCache(_url(2)))!.lastUsedTime.isAfter(old),
        isTrue,
        reason: 'read from the table, the waiting time applied',
      );
      await storage.flushImageCacheUsedTimes();
      expect((await usedTimeInTable(_url(1)))!.isAfter(old), isTrue);
      expect((await usedTimeInTable(_url(2)))!.isAfter(old), isTrue);
    });

    test('written once enough of them wait', () async {
      final old = DateTime(2026);
      const batch = StorageProvider.imageUsedTimeFlushBatch;
      await insertRows(batch + 1, usedAt: old);
      final storage = StorageProvider(db, {}, {})..markImageCacheUsed(_url(0));
      await storage.flushImageCacheUsedTimes();
      for (var i = 1; i < batch; i++) {
        storage.markImageCacheUsed(_url(i));
      }
      await pumpEventQueue();
      expect(await usedTimeInTable(_url(1)), old);
      storage.markImageCacheUsed(_url(batch));
      await storage.flushImageCacheUsedTimes();
      for (final i in [1, batch ~/ 2, batch]) {
        expect((await usedTimeInTable(_url(i)))!.isAfter(old), isTrue, reason: 'row $i');
      }
    });

    test("the app's provider writes them a moment after the first one waits", () async {
      final old = DateTime(2026);
      await insertRows(2, usedAt: old);
      final storage = StorageProvider.forApp(db, {}, usedTimeFlushDelay: const Duration(milliseconds: 50))
        ..markImageCacheUsed(_url(0));
      await storage.flushImageCacheUsedTimes();
      storage.markImageCacheUsed(_url(1));
      await pumpEventQueue();
      expect(await usedTimeInTable(_url(1)), old);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await storage.flushImageCacheUsedTimes();
      expect((await usedTimeInTable(_url(1)))!.isAfter(old), isTrue);
    });

    test('a time never goes back: a row cached again since keeps its newer time', () async {
      final newer = DateTime(2026, 10, 23, 12);
      await insertRows(1, usedAt: newer);
      await ImageDao(db).updateLastUsedTimes({_url(0): DateTime(2026, 10, 22), _url(9): DateTime(2026, 10, 24)});
      expect(await usedTimeInTable(_url(0)), newer);
      expect(await usedTimeInTable(_url(9)), isNull, reason: 'no row, nothing written');
    });

    test('the app writes them when it goes to the background', () {
      final app = File('lib/app.dart').readAsStringSync();
      expect(app, contains('flushImageCacheUsedTimes()'));
      expect(app, contains('AppLifecycleState.paused'));
    });
  });

  group('3. the image cache provider', () {
    late _Images images;
    late StorageProvider storage;
    late ImageCacheProvider provider;
    final png = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);

    setUp(() async {
      images = _Images([137, 80, 78, 71, 9, 9, 9]);
      storage = StorageProvider(db, {}, {});
      final settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings, dispose: (s) => s.dispose())
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
      await settings.init();
      provider = ImageCacheProvider(
        NetClientProvider.buildNoCookie(
          dio: Dio()..httpClientAdapter = images,
          cookie: CookieProvider.buildEmpty(),
        ),
      );
    });
    tearDown(() async => provider.dispose());

    File fileOf(String url) => provider.getCacheFile(url.fileNameV5())!;

    test('a cached image is read through the lookup, its time written with the batch', () async {
      const url = 'https://img.example/cached.png';
      fileOf(url).writeAsBytesSync(png);
      final old = DateTime(2026);
      await storage.updateImageCache(url, fileName: url.fileNameV5(), lastCacheTime: old, lastUsedTime: old);
      final fresh = StorageProvider(db, {}, {});
      await getIt.unregister<StorageProvider>();
      getIt.registerSingleton<StorageProvider>(fresh);
      // A first image shown after a quiet while is written at once; the one asked here waits for the batch.
      fresh.markImageCacheUsed('https://img.example/other.png');
      final data = await provider.getOrMakeCache(const ImageCacheGeneralRequest(url));
      expect(data.toNullable(), png);
      expect(images.requests, 0, reason: 'from the cache');
      expect(await usedTimeInTable(url), old, reason: 'not written for every image shown');
      await fresh.flushImageCacheUsedTimes();
      expect((await usedTimeInTable(url))!.isAfter(old), isTrue);
    });

    test('a row whose file is gone or can not be read loads the image again', () async {
      const gone = 'https://img.example/gone.png';
      await storage.updateImageCache(gone, fileName: gone.fileNameV5());
      expect(await provider.getOrMakeCache(const ImageCacheGeneralRequest(gone)), isA<Some<Uint8List>>());
      expect(images.requests, 1, reason: 'the file was gone');
      expect(fileOf(gone).existsSync(), isTrue);

      const unreadable = 'https://img.example/unreadable.png';
      final file = fileOf(unreadable)..writeAsBytesSync(png);
      await storage.updateImageCache(unreadable, fileName: unreadable.fileNameV5());
      await Process.run('chmod', ['000', file.path]);
      addTearDown(() => Process.run('chmod', ['644', file.path]));
      final data = await provider.getOrMakeCache(const ImageCacheGeneralRequest(unreadable));
      expect(data.toNullable(), [137, 80, 78, 71, 9, 9, 9], reason: 'loaded again instead of failing');
      expect(images.requests, 2);
    });
  });
}
