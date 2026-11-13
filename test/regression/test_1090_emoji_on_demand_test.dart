/// The forum's emoji are no longer bundled with the app: downloaded when used and kept on this device.
///
/// 1. the app bundles no emoji image and nothing refers to the bundled ones any more;
/// 2. the emoji panel loads the list (the one saved on this device first, the forum's only without), then the images
///    of a group when it is shown, one request per image, at most a few at once, never again once there; a user
///    upgrading keeps the emoji already on the device without any request;
/// 3. without network and without a saved list the panel shows the failure state, with a retry;
/// 4. an emoji in a post is read from the emoji cache, else downloaded once and kept there (not in the image cache,
///    which the automatic clean up trims);
/// 5. file names with spaces are encoded in the urls.
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
import 'package:tsdm_client/features/editor/bloc/emoji_bloc.dart';
import 'package:tsdm_client/features/editor/repository/editor_repository.dart';
import 'package:tsdm_client/features/editor/widgets/emoji_panel.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_trim.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
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
  late StorageProvider storage;
  late NetClientProvider client;
  late ImageCacheProvider cache;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    tmp = Directory.systemTemp.createTempSync('tsdm_emoji_on_demand_');
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

  /// A new provider: what a new run of the app has.
  ImageCacheProvider newCache() => ImageCacheProvider(client);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    forum = _Forum();
    storage = StorageProvider(db, {}, {});
    final settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings, dispose: (s) => s.dispose())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
    client = NetClientProvider.buildNoCookie(
      dio: Dio()..httpClientAdapter = forum,
      cookie: CookieProvider.buildEmpty(),
    );
    cache = newCache();
    await cache.clearEmojiCache();
  });
  tearDown(() async {
    await cache.dispose();
    await getIt.reset();
    await db.close();
  });

  EditorRepository newRepo() => EditorRepository(netClientProvider: client, imageCacheProvider: cache);

  group('1. no bundled emoji', () {
    test('pubspec bundles no emoji directory and the files are gone', () {
      expect(File('pubspec.yaml').readAsStringSync(), isNot(contains('assets/images/emoji')));
      expect(Directory('assets/images/emoji').existsSync(), isFalse);
    });

    test('nothing in the app or its tests reads the bundled emoji', () {
      for (final dir in ['lib', 'test', 'scripts']) {
        for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
          if (!f.path.endsWith('.dart') && !f.path.endsWith('.py') && !f.path.endsWith('.sh')) continue;
          if (f.path.endsWith('test_1090_emoji_on_demand_test.dart')) continue;
          final text = f.readAsStringSync();
          expect(text, isNot(contains('images/emoji/')), reason: f.path);
          expect(text, isNot(contains('assetEmoji')), reason: f.path);
        }
      }
    });
  });

  group('2. the emoji panel downloads what it shows', () {
    test('the list comes from the forum once, then from this device; only the list, no image', () async {
      final repo = newRepo();
      expect((await repo.loadEmojiFromCacheOrServer().run()).isRight(), isTrue);
      expect(repo.emojiGroupList!.map((e) => e.id), ['12', '4']);
      expect(forum.requests, hasLength(1));
      expect(forum.requests.single, endsWith('/data/cache/common_smilies_var.js'));

      final again = EditorRepository(netClientProvider: client, imageCacheProvider: newCache());
      expect((await again.loadEmojiFromCacheOrServer().run()).isRight(), isTrue);
      expect(again.emojiGroupList!.map((e) => e.id), ['12', '4']);
      expect(forum.requests, hasLength(1), reason: 'the saved list');
    });

    test('a group downloads each missing image once, at most a few at once, and not again', () async {
      final repo = newRepo();
      await repo.loadEmojiFromCacheOrServer().run();
      final group = repo.emojiGroupList!.first;
      final progress = <int>[];
      expect(await repo.downloadEmojiGroup(group, onProgress: (done, total) => progress.add(done)), 0);
      expect(forum.imageRequests, 6, reason: 'one request per image');
      expect(forum.maxRunning, lessThanOrEqualTo(ImageCacheProvider.maxEmojiDownloads));
      expect(progress.first, 0);
      expect(progress.last, 6);
      for (final emoji in group.emojiList) {
        expect(cache.hasEmojiCacheFile('12', emoji.id), isTrue);
      }
      expect(forum.requests.where((e) => e.contains('/MIKU/')), isEmpty, reason: 'the other group is not shown');

      expect(await repo.downloadEmojiGroup(group), 0);
      expect(forum.imageRequests, 6, reason: 'already there');
    });

    test('every emoji downloaded alone (recent ones, the editor) shares the same few at once', () async {
      final repo = newRepo();
      await repo.loadEmojiFromCacheOrServer().run();
      final emoji = [
        for (final g in repo.emojiGroupList!)
          for (final e in g.emojiList) (g.id, e.id),
      ];
      final data = await Future.wait(emoji.map((e) => newCache().getOrMakeEmojiCache(e.$1, e.$2)));
      expect(data, everyElement(isNotNull));
      expect(forum.imageRequests, emoji.length);
      expect(forum.maxRunning, lessThanOrEqualTo(ImageCacheProvider.maxEmojiDownloads));
    });

    test('a failed image is asked again on retry, the others are not', () async {
      final repo = newRepo();
      await repo.loadEmojiFromCacheOrServer().run();
      final group = repo.emojiGroupList!.first;
      forum.failing = '/TSDM/16.jpg';
      expect(await repo.downloadEmojiGroup(group), 1);
      expect(cache.hasEmojiCacheFile('12', '853'), isFalse);
      forum.requests.clear();
      forum.failing = null;
      expect(await repo.downloadEmojiGroup(group), 0);
      expect(forum.requests.single, endsWith('/TSDM/16.jpg'));
    });

    test('a user upgrading keeps the emoji on this device: no request at all', () async {
      // What the bundled emoji left: the list and every image, in the emoji cache.
      final group = EmojiGroup(
        name: '梦予馨',
        id: '12',
        routeName: 'TSDM',
        emojiList: [
          for (final id in ['865', '853'])
            Emoji(id: id, code: '{:12_$id:}', url: 'https://img.tsdm39.com/img02/smilies//TSDM/$id.jpg'),
        ],
      );
      await cache.saveEmojiInfo([group]);
      for (final id in ['865', '853']) {
        await cache.updateEmojiCache('12', id, _png);
      }
      final repo = EditorRepository(netClientProvider: client, imageCacheProvider: newCache());
      expect((await repo.loadEmojiFromCacheOrServer().run()).isRight(), isTrue);
      expect(await repo.downloadEmojiGroup(repo.emojiGroupList!.single), 0);
      expect(forum.requests, isEmpty);
    });

    test('the bloc downloads the group asked only, and tells its progress', () async {
      final bloc = EmojiBloc(editRepository: newRepo());
      addTearDown(bloc.close);
      bloc.add(EmojiFetchFromCacheEvent());
      await bloc.stream.firstWhere((e) => e.status == EmojiStatus.success);
      final states = <EmojiGroupProgress?>[];
      final sub = bloc.stream.listen((e) => states.add(e.groupProgress['4']));
      addTearDown(sub.cancel);
      bloc.add(EmojiFetchGroupEvent('4'));
      final done = await bloc.stream.firstWhere((e) => e.groupProgress['4']?.status == EmojiStatus.success);
      expect(done.groupProgress['4']!.done, 3);
      expect(done.groupProgress.containsKey('12'), isFalse);
      expect(states.first?.status, EmojiStatus.loading);
      expect(forum.requests.where((e) => e.contains('/TSDM/')), isEmpty);
      expect(forum.imageRequests, 3);

      // Shown again: nothing to do.
      bloc.add(EmojiFetchGroupEvent('4'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forum.imageRequests, 3);
    });
  });

  group('3. without network and without a saved list', () {
    test('the bloc fails', () async {
      forum.offline = true;
      final bloc = EmojiBloc(editRepository: newRepo());
      addTearDown(bloc.close);
      bloc.add(EmojiFetchFromCacheEvent());
      final state = await bloc.stream.firstWhere((e) => e.status != EmojiStatus.loading);
      expect(state.status, EmojiStatus.failure);
    });

    testWidgets('the panel shows the retry, and the first group once online', (tester) async {
      forum.offline = true;
      getIt
        ..registerSingleton<ImageCacheProvider>(cache)
        ..registerSingleton<NetClientProvider>(client, instanceName: ServiceKeys.noCookie);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(body: EmojiPanel(onPicked: (_) {})),
          ),
        ),
      );
      // The client tries a failed request again a few times first.
      for (var i = 0; i < 100 && find.byType(FilledButton).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        // The requests wait on the test's clock.
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(FilledButton), findsOneWidget, reason: 'the existing failure state');

      forum.offline = false;
      await tester.tap(find.byType(FilledButton));
      for (var i = 0; i < 20 && forum.imageRequests < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      for (var i = 0; i < 20 && find.byKey(const ValueKey('emoji-group-progress')).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const ValueKey('emoji-panel-group-12')), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('emoji-panel-group-12')), matching: find.byType(Image)),
        findsNWidgets(6),
        reason: 'the images shown as they come',
      );
      expect(forum.imageRequests, 6, reason: 'the group shown only');
      expect(forum.requests.where((e) => e.contains('/MIKU/')), isEmpty);
      expect(find.byKey(const ValueKey('emoji-group-progress')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('4. an emoji in a post', () {
    const postUrl = 'https://www.tsdm39.com/static/image/smiley/TSDM/9.jpg';

    test('read from the emoji cache when there, no request', () async {
      final repo = newRepo();
      await repo.loadEmojiFromCacheOrServer().run();
      await cache.updateEmojiCache('12', '865', _png);
      forum.requests.clear();
      final data = await newCache().getOrMakeCache(const ImageCacheGeneralRequest(postUrl));
      expect(data.toNullable(), _png);
      expect(forum.requests, isEmpty);
    });

    test('downloaded once and kept in the emoji cache, not in the image cache the clean up trims', () async {
      final repo = newRepo();
      await repo.loadEmojiFromCacheOrServer().run();
      forum.requests.clear();
      final posts = newCache();
      expect((await posts.getOrMakeCache(const ImageCacheGeneralRequest(postUrl))).toNullable(), _png);
      expect(forum.requests, [postUrl]);
      expect(posts.hasEmojiCacheFile('12', '865'), isTrue);
      expect(await storage.getImageCache(postUrl), isNull);

      await posts.trimCache(const ImageCacheLimits(maxEntries: 0, maxBytes: 0));
      expect(posts.hasEmojiCacheFile('12', '865'), isTrue);
      expect((await posts.getOrMakeCache(const ImageCacheGeneralRequest(postUrl))).toNullable(), _png);
      expect(forum.requests, hasLength(1));
    });

    test('an image of another site with the same path is never kept as the emoji', () async {
      final repo = newRepo();
      await repo.loadEmojiFromCacheOrServer().run();
      const other = 'https://evil.example/x/smiley/TSDM/9.jpg';
      final posts = newCache();
      expect((await posts.getOrMakeCache(const ImageCacheGeneralRequest(other))).toNullable(), _png);
      expect(posts.hasEmojiCacheFile('12', '865'), isFalse);
      expect(await storage.getImageCache(other), isNotNull, reason: 'an image like any other');
    });

    test('clearing the emoji cache forgets the list too', () async {
      final repo = newRepo();
      await repo.loadEmojiFromCacheOrServer().run();
      await cache.clearEmojiCache();
      await cache.getOrMakeCache(const ImageCacheGeneralRequest(postUrl));
      expect(cache.hasEmojiCacheFile('12', '865'), isFalse);
      expect(await storage.getImageCache(postUrl), isNotNull);
    });

    test('without a saved list it is an image like any other', () async {
      final data = await cache.getOrMakeCache(const ImageCacheGeneralRequest(postUrl));
      expect(data.toNullable(), _png);
      expect(cache.hasEmojiCacheFile('12', '865'), isFalse);
      expect(await storage.getImageCache(postUrl), isNotNull);
    });

    test('the image place is the same for the post and for the list', () {
      expect(ImageCacheProvider.emojiImageKeyOf(postUrl), 'TSDM/9.jpg');
      expect(ImageCacheProvider.emojiImageKeyOf('https://img.tsdm39.com/img02/smilies//TSDM/9.jpg'), 'TSDM/9.jpg');
      expect(
        ImageCacheProvider.emojiImageKeyOf('https://www.tsdm39.com/static/image/smiley/LI/1 (15).gif'),
        'LI/1 (15).gif',
      );
      expect(
        ImageCacheProvider.emojiImageKeyOf('https://img.tsdm39.com/img02/smilies/LI/1%20(15).gif'),
        'LI/1 (15).gif',
      );
      expect(ImageCacheProvider.emojiImageKeyOf('https://img.example/a/b/9.jpg'), isNull);
      expect(ImageCacheProvider.emojiImageKeyOf('https://evil.example/x/smiley/TSDM/9.jpg'), isNull);
      expect(
        ImageCacheProvider.emojiImageKeyOf('https://tsdm39.com.evil.example/static/image/smiley/TSDM/9.jpg'),
        isNull,
      );
      expect(ImageCacheProvider.emojiImageKeyOf('https://www.tsdm39.com/static/image/common/logo.png'), isNull);
    });
  });

  test('5. file names with spaces are encoded in the urls', () {
    final groups = newRepo().parseEmojiInfo(_smiliesJs);
    final miku = groups.firstWhere((e) => e.id == '4');
    expect(miku.emojiList.map((e) => e.url), [
      'https://img.tsdm39.com/img02/smilies/MIKU/9.jpg',
      'https://img.tsdm39.com/img02/smilies/MIKU/1%20(15).gif',
      'https://img.tsdm39.com/img02/smilies/MIKU/15.gif',
    ]);
  });
}
