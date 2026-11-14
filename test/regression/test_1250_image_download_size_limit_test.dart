/// An image is downloaded up to a limit of bytes, then given up ([responseMaxBytesKey]).
///
/// Every image of a post, an avatar or an emoji was downloaded whole into memory, whatever its size: a post could
/// name an address answering gigabytes, and the app read them all (on Android, in Kotlin, then copied once more to
/// Dart) before failing. Now:
///
/// * an answer saying it is larger than the limit (`Content-Length`) is not read at all;
/// * an answer without its size is read until it goes over the limit, then dropped;
/// * an image of a post may have [maxImageBytes] (long pictures and GIFs of 20 MB are common), an avatar or an emoji
///   [maxSmallImageBytes];
/// * the Kotlin client of Android is told the limit and stops reading there itself;
/// * an image found too large is not downloaded again in the same run (the image widget asks a second time when the
///   first load failed), unless reloaded on purpose.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_limits.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider_android.dart'
    show KotlinHttpClient, KotlinHttpClientAdapter;
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/response_size_limit.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// A PNG of one pixel.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// A host answering every request with [chunks] of [chunkSize] bytes (the first ones a PNG), telling the size or not;
/// recording what was asked and how many chunks were pulled from it.
final class _Host implements HttpClientAdapter {
  int chunks = 1;
  int chunkSize = 1024;
  bool tellsLength = true;

  final options = <RequestOptions>[];

  /// The chunks read from the body, over every request.
  int pulled = 0;

  /// Whether the body of the last answer was cancelled before its end.
  bool cancelled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    this.options.add(options);
    cancelled = false;
    final total = chunks * chunkSize;
    var sent = 0;
    late final StreamController<Uint8List> body;
    body = StreamController<Uint8List>(
      onListen: () async {
        while (true) {
          // A chunk arrives later, as from a socket; none after the body was cancelled.
          await Future<void>.delayed(Duration.zero);
          if (sent >= chunks || cancelled || body.isClosed) {
            break;
          }
          final chunk = Uint8List(chunkSize);
          if (sent == 0) {
            chunk.setRange(0, _png.length.clamp(0, chunkSize), _png);
          }
          sent++;
          pulled++;
          body.add(chunk);
        }
        if (!body.isClosed && !cancelled) {
          await body.close();
        }
      },
      onCancel: () {
        if (sent < chunks) {
          cancelled = true;
        }
      },
    );
    return ResponseBody(
      body.stream,
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
        if (tellsLength) Headers.contentLengthHeader: ['$total'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('the transport of every client', () {
    late NetClientProvider client;
    late _Host host;

    setUp(() {
      getIt
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
      host = _Host();
      client = NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = host);
    });

    tearDown(getIt.reset);

    test('does not read an answer saying it is larger than the limit', () async {
      host
        ..chunks = 64
        ..chunkSize = 1024;
      final result = await client.getImage('https://img.example/a.png', maxBytes: 4096).run();
      expect(result.isLeft(), isTrue);
      expect(result.getLeft().toNullable(), isA<ResponseTooLargeException>());
      expect(host.pulled, 0, reason: 'nothing read from the body');
    });

    test('stops reading an answer without its size once it goes over the limit', () async {
      host
        ..chunks = 64
        ..chunkSize = 1024
        ..tellsLength = false;
      final result = await client.getImage('https://img.example/a.png', maxBytes: 4096).run();
      expect(result.getLeft().toNullable(), isA<ResponseTooLargeException>());
      expect(host.pulled, lessThan(8), reason: 'the body is given up after the limit, not read to its end');
      expect(host.cancelled, isTrue);
    });

    test('takes an answer within the limit, with its size or without', () async {
      for (final tells in [true, false]) {
        host
          ..chunks = 4
          ..chunkSize = 1024
          ..tellsLength = tells;
        final result = await client.getImage('https://img.example/a.png', maxBytes: 4096).run();
        expect((result.toNullable()!.data as Uint8List).length, 4096, reason: 'size told: $tells');
      }
    });

    test('takes any size when no limit is asked for (a page, an attachment)', () async {
      host
        ..chunks = 64
        ..tellsLength = false;
      final result = await client.getImage('https://img.example/a.png').run();
      expect((result.toNullable()!.data as Uint8List).length, 64 * 1024);
      expect(host.options.last.extra.containsKey(responseMaxBytesKey), isFalse);
    });
  });

  group('the Kotlin client of Android', () {
    const channel = MethodChannel('kzs.th000.tsdm_client/httpChannel');
    late List<MethodCall> calls;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      calls = [];
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('is told the limit, and its refusal is the answer too large', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        throw PlatformException(code: 'KT_HTTP_TOO_LARGE', message: 'failed to perform http GET');
      });
      final dio = Dio()..httpClientAdapter = KotlinHttpClientAdapter(KotlinHttpClient(android: true));
      final error = await dio
          .get<dynamic>(
            'https://img.example/a.png',
            options: Options(responseType: ResponseType.bytes, extra: {responseMaxBytesKey: 4096}),
          )
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((calls.single.arguments as Map)['maxBytes'], 4096);
      expect(error, isA<DioException>().having((e) => e.error, 'error', isA<ResponseTooLargeException>()));
      expect(mapException(error!, StackTrace.current), isA<ResponseTooLargeException>());
    });

    test('is told no limit when none is asked for', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return {
          'statusCode': 200,
          'headers': <String, List<String>>{
            'content-type': ['text/html'],
          },
          'body': Uint8List(10),
          'isRedirect': false,
        };
      });
      final dio = Dio()..httpClientAdapter = KotlinHttpClientAdapter(KotlinHttpClient(android: true));
      await dio.get<dynamic>('https://www.tsdm39.com/forum.php', options: Options(responseType: ResponseType.bytes));
      expect((calls.single.arguments as Map).containsKey('maxBytes'), isFalse);
    });

    test('stops reading at the limit itself (the Kotlin source)', () {
      final activity = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/MainActivity.kt').readAsStringSync();
      expect(activity, contains('call.argument<Number>("maxBytes")'));
      final client = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/HttpClient.kt').readAsStringSync();
      expect(client, contains('KT_HTTP_TOO_LARGE'));
      expect(client, contains('fun readBody('));
    });
  });

  group('the image cache', () {
    late Directory tmp;
    late AppDatabase db;
    late _Host host;
    late ImageCacheProvider images;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('tsdm_1250_');
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
      final settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<CookieProvider>(CookieProvider(const UserLoginInfo(username: 'Alice', uid: 31), {}))
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
      await settings.init();
      host = _Host();
      images = ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = host));
      getIt.registerSingleton<ImageCacheProvider>(images);
    });

    tearDown(() async {
      await images.dispose();
      await getIt.reset();
      await db.close();
    });

    test('asks for a picture of a post with the large limit, for an avatar with the small one', () async {
      await images.getOrMakeCache(const ImageCacheGeneralRequest('https://img.example/post.png'));
      await images.getOrMakeCache(
        const ImageCacheUserAvatarRequest(username: 'Bob', imageUrl: 'https://img.example/avatar.png'),
      );
      expect(host.options.map((e) => e.extra[responseMaxBytesKey]), [maxImageBytes, maxSmallImageBytes]);
      expect(maxImageBytes, greaterThanOrEqualTo(40 * 1024 * 1024), reason: 'long pictures of 20 MB load');
      expect(maxSmallImageBytes, lessThan(maxImageBytes ~/ 8));
    });

    test('does not download a picture found too large again in the same run, unless reloaded', () async {
      host
        ..chunks = 8
        ..chunkSize = 1024;
      const url = 'https://img.example/huge.png';
      const avatar = ImageCacheUserAvatarRequest(username: 'Bob', imageUrl: url);
      images.debugMaxBytes = (_) => 4096;
      expect((await images.getOrMakeCache(avatar)).isNone(), isTrue);
      expect((await images.getOrMakeCache(avatar)).isNone(), isTrue);
      expect(host.options, hasLength(1));
      // Reloaded on purpose: asked again.
      expect((await images.getOrMakeCache(avatar, force: true)).isNone(), isTrue);
      expect(host.options, hasLength(2));
      // A larger limit tries again.
      images.debugMaxBytes = (_) => 1 << 20;
      expect((await images.getOrMakeCache(avatar)).isSome(), isTrue);
      expect(host.options, hasLength(3));
      // The server's message of a page is not set for it: the placeholder shows no message.
      expect(images.htmlMessageOf(url), isNull);
    });
  });
}
