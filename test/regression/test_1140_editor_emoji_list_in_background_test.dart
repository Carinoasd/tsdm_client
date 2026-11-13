/// The forum's emoji in the editor (an old draft, a quote) on a device whose emoji panel never loaded the list:
///
/// * the list is fetched in the background, once for every emoji shown together, then the images: each emoji shows
///   its image instead of its code;
/// * without network the emoji stay their code, without an error; the fetch is not tried again in the same run (a new
///   emoji shown later asks nothing), and the list the emoji panel loads later brings the images;
/// * with the list on the device nothing is fetched but the images.
///
/// Synthetic data, no real forum.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/editor/repository/editor_repository.dart';
import 'package:tsdm_client/features/editor/widgets/emoji_image.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// A 1x1 png.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// The forum's emoji list (`data/cache/common_smilies_var.js`): group 12 with 6 emoji, group 4 with 3, one of them a
/// file name with spaces.
final String _smiliesJs = [
  "var smthumb = '20';var smilies_type = new Array();smilies_type['_12'] = ['梦予馨', 'TSDM'];",
  "smilies_type['_4'] = ['MIKU', 'MIKU'];var smilies_array = new Array();var smilies_fast = new Array();",
  'smilies_array[12] = new Array();',
  "smilies_array[12][1] = [['865', '{:12_865:}','9.jpg','20','20','50'],['853', '{:12_853:}','16.jpg','20','20','50'],",
  "['852', '{:12_852:}','15.jpg','20','20','50'],['851', '{:12_851:}','14.jpg','20','20','50']];",
  "smilies_array[12][2] = [['850', '{:12_850:}','13.jpg','20','20','50'],['849', '{:12_849:}','12.jpg','20','20','50']];",
  'smilies_array[4] = new Array();',
  "smilies_array[4][1] = [['131', '{:4_131:}','9.jpg','20','20','50'],['119', '{:4_119:}','1 (15).gif','20','20','50'],",
  "['96', '{:4_96:}','15.gif','20','20','50']];",
].join();

/// The forum: the emoji list and images, counted; [offline] fails every request, [failing] the urls containing it.
final class _Forum implements HttpClientAdapter {
  final requests = <String>[];
  bool offline = false;
  String? failing;
  int _running = 0;
  int maxRunning = 0;

  int get imageRequests => requests.where((e) => !e.endsWith('.js')).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // Without the query the client adds to every request (`mobile=no`).
    final url = options.uri.replace(query: '').toString().replaceAll(RegExp(r'\?$'), '');
    requests.add(url);
    _running++;
    maxRunning = _running > maxRunning ? _running : maxRunning;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (offline) {
        throw DioException.connectionError(requestOptions: options, reason: 'offline');
      }
      if (failing != null && url.contains(failing!)) {
        return ResponseBody.fromString('', 404);
      }
      if (url.endsWith('common_smilies_var.js')) {
        return ResponseBody.fromString(
          _smiliesJs,
          200,
          headers: {
            Headers.contentTypeHeader: ['application/javascript; charset=utf-8'],
          },
        );
      }
      return ResponseBody.fromBytes(
        _png,
        200,
        headers: {
          Headers.contentTypeHeader: ['image/png'],
        },
      );
    } finally {
      _running--;
    }
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late _Forum forum;
  late NetClientProvider client;
  late ImageCacheProvider cache;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    tmp = Directory.systemTemp.createTempSync('tsdm_emoji_list_editor_');
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

  setUp(() async {
    EmojiListInBackground.reset();
    db = AppDatabase(NativeDatabase.memory());
    forum = _Forum();
    final storage = StorageProvider(db, {}, {});
    final settings = SettingsRepository(storage);
    client = NetClientProvider.buildNoCookie(
      dio: Dio()..httpClientAdapter = forum,
      cookie: CookieProvider.buildEmpty(),
    );
    cache = ImageCacheProvider(client);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings, dispose: (s) => s.dispose())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<NetClientProvider>(client, instanceName: ServiceKeys.noCookie)
      ..registerSingleton<ImageCacheProvider>(cache);
    await settings.init();
    await cache.clearEmojiCache();
  });
  tearDown(() async {
    await getIt.reset();
    await cache.dispose();
    await db.close();
  });

  int listRequests() => forum.requests.where((e) => e.endsWith('common_smilies_var.js')).length;

  Widget editorEmoji(List<String> codes) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          for (final code in codes)
            EmojiCacheImage(
              key: ValueKey(code),
              groupId: emojiIdsOfCode(code)!.groupId,
              id: emojiIdsOfCode(code)!.id,
              fetch: true,
              width: 20,
              height: 20,
              placeholder: Text(code),
            ),
        ],
      ),
    ),
  );

  /// Let the files and the forum answer, until [done] or a while.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 50 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  const codes = ['{:12_865:}', '{:12_853:}', '{:4_131:}'];

  testWidgets('no list on the device: fetched once for all, then each emoji shows its image', (tester) async {
    await tester.runAsync(() => tester.pumpWidget(editorEmoji(codes)));
    expect(find.text('{:12_865:}'), findsOneWidget, reason: 'the code until the image is there');
    await settle(tester, () => find.byType(Image).evaluate().length == codes.length);
    expect(find.byType(Image), findsNWidgets(codes.length));
    for (final code in codes) {
      expect(find.text(code), findsNothing);
    }
    expect(listRequests(), 1, reason: 'one fetch of the list for every emoji');
    expect(forum.imageRequests, codes.length);
    expect(await tester.runAsync(cache.hasEmojiList), isTrue, reason: 'kept for the next time');

    // Another emoji later in the same run: the list is there, only its image.
    await tester.runAsync(() => tester.pumpWidget(editorEmoji(['{:4_96:}'])));
    await settle(tester, () => find.byType(Image).evaluate().isNotEmpty);
    expect(find.byType(Image), findsOneWidget);
    expect(listRequests(), 1);
  });

  testWidgets('without network the code stays, no error, not tried again; the panel loading the list later brings '
      'the images', (tester) async {
    forum.offline = true;
    await tester.runAsync(() => tester.pumpWidget(editorEmoji(codes)));
    await settle(tester, () => listRequests() > 0 && forum.requests.length > listRequests());
    await settle(tester, () => false);
    expect(tester.takeException(), isNull);
    for (final code in codes) {
      expect(find.text(code), findsOneWidget);
    }
    expect(listRequests(), 1, reason: 'one fetch for every emoji, failed');

    // Shown again in the same run: nothing asked.
    await tester.runAsync(() => tester.pumpWidget(editorEmoji(['{:4_96:}', ...codes])));
    await settle(tester, () => false);
    expect(listRequests(), 1, reason: 'a failed fetch is not tried again in the run');
    expect(find.text('{:4_96:}'), findsOneWidget);

    // The emoji panel opened with network: its list brings the images of the emoji shown.
    forum.offline = false;
    final loaded = await tester.runAsync(
      () => EditorRepository(netClientProvider: client, imageCacheProvider: cache).loadEmojiFromCacheOrServer().run(),
    );
    expect(loaded!.isRight(), isTrue);
    await settle(tester, () => find.byType(Image).evaluate().length == codes.length + 1);
    expect(find.byType(Image), findsNWidgets(codes.length + 1));
    expect(listRequests(), 2, reason: 'the panel fetched it, nothing else');
  });

  testWidgets('the list on the device: only the images', (tester) async {
    await tester.runAsync(
      () => EditorRepository(netClientProvider: client, imageCacheProvider: cache).loadEmojiFromCacheOrServer().run(),
    );
    forum.requests.clear();
    await tester.runAsync(() => tester.pumpWidget(editorEmoji(codes)));
    await settle(tester, () => find.byType(Image).evaluate().length == codes.length);
    expect(find.byType(Image), findsNWidgets(codes.length));
    expect(listRequests(), 0);
  });
}
