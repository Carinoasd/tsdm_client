/// An image still loading when the image cache is disposed (`ImageCacheProvider.dispose`) loads all the same: what it
/// read or fetched answers its caller, it only tells nothing on the closed stream of responses.
///
/// It used to add to that stream after it closed: `Bad state: Cannot add new events after calling close`, which failed
/// the image (`failed to render image <url>: Bad state: Cannot add new events after calling close`). A test ending
/// while a picture was read from the cache got it, reported in the test running next.
///
/// Each test disposes while the load waits for its first step, nothing is timed: the stream is closed from the moment
/// `dispose` is called.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';

const _url = 'https://img.example/a.png';

/// A PNG of one pixel.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// The image host: answers [_png], once [gate] lets it when there is one.
final class _ImageServer implements HttpClientAdapter {
  final requests = <String>[];

  /// While not null, an answer waits for it.
  Completer<void>? gate;

  /// Completed at each request.
  Completer<void> asked = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.uri}');
    if (!asked.isCompleted) {
      asked.complete();
    }
    await gate?.future;
    return ResponseBody(
      Stream.value(_png),
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
        Headers.contentLengthHeader: ['${_png.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late SettingsRepository settings;
  late _ImageServer server;
  late ImageCacheProvider images;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    tmp = Directory.systemTemp.createTempSync('tsdm_858_');
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
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    server = _ImageServer();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    images = ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = server));
    getIt.registerSingleton<ImageCacheProvider>(images);
    await settings.init();
  });

  tearDown(() async {
    await images.dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  /// Cache [_url] (fetched once).
  Future<void> cache() async {
    expect((await images.getOrMakeCache(const ImageCacheGeneralRequest(_url))).isSome(), isTrue);
    expect(server.requests, hasLength(1));
  }

  test('read from the cache while the image cache is disposed: the image is answered', () async {
    await cache();
    // Waits for the cache row; the stream of responses closes under it.
    final reading = images.getOrMakeCache(const ImageCacheGeneralRequest(_url), cacheOnly: true);
    final disposing = images.dispose();
    expect((await reading).toNullable(), _png);
    await disposing;
    // Nothing fetched again.
    expect(server.requests, hasLength(1));
  });

  test('fetched while the image cache is disposed: the image is answered', () async {
    server.gate = Completer<void>();
    final fetching = images.getOrMakeCache(const ImageCacheGeneralRequest(_url));
    await server.asked.future;
    final disposing = images.dispose();
    server.gate!.complete();
    expect((await fetching).toNullable(), _png);
    await disposing;
    expect(server.requests, hasLength(1));
  });

  test('a picture resolving while the image cache is disposed shows, no error is reported', () async {
    await cache();
    final shown = Completer<ImageInfo>();
    final stream = const CachedImageProvider(_url, cacheOnly: true).resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) => shown.complete(info),
      onError: shown.completeError,
    );
    // The load started with `resolve` and waits for the cache row.
    stream.addListener(listener);
    final disposing = images.dispose();
    final info = await shown.future;
    expect((info.image.width, info.image.height), (1, 1));
    info.dispose();
    stream.removeListener(listener);
    await disposing;
  });
}
