/// The automatic clean up of the image cache (cold start, UX audit item 5; the high items of the review of the small
/// fixes):
///
/// 1. it never holds the homepage: no spinner in place of the home pages any more, it runs in the background long after
///    the first frame;
/// 2. the pictures of the offline thread pages are recognised in the saved pages (web pages and JSON answers);
/// 3. what goes is decided from the age, the count and the size, the least recently shown first; the image stickers,
///    the avatars of the saved accounts and the pictures of the offline pages stay; rows without their file and files
///    without their row go;
/// 4. the clean up itself: nothing read whole when the cache is within its limits, at most so many deletions a run, the
///    files of a batch before its rows, the rows in memory only lose the deleted ones, a row shown meanwhile stays.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/home/cubit/init_cubit.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_trim.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const int _hour = 60 * 60 * 1000;

ImageCacheTrimRow _row(String url, int lastUsedMs, {String? file}) =>
    (url: url, fileName: file ?? url.split('/').last, lastUsedMs: lastUsedMs);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('1. the homepage never waits for it', () {
    test('no spinner in place of the home pages, no clean up before the first frame', () {
      final home = File('lib/features/home/view/home_page.dart').readAsStringSync();
      expect(home, isNot(contains('clearingOutdatedImageCache')));
      expect(home, isNot(contains('BlocBuilder<InitCubit')));
      final init = File('lib/features/home/cubit/init_cubit.dart').readAsStringSync();
      expect(init, isNot(contains('clearingOutdatedImageCache')));
      final app = File('lib/app.dart').readAsStringSync();
      expect(app, contains('scheduleImageCacheTrim('));
      expect(app, isNot(contains('autoClearImageCache(')));
    });

    testWidgets('scheduled after the first frame and its delay, never once the app is gone', (tester) async {
      final runs = <ImageCacheLimits>[];
      final cubit = InitCubit();
      const limits = ImageCacheLimits(maxAge: Duration(days: 7));
      cubit.scheduleImageCacheTrim(() => limits, delay: const Duration(seconds: 5), trim: (l) async => runs.add(l));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
      expect(runs, isEmpty);
      await tester.pump(const Duration(seconds: 2));
      expect(runs, [limits]);

      final closed = InitCubit()
        ..scheduleImageCacheTrim(() => limits, delay: const Duration(seconds: 5), trim: (l) async => runs.add(l));
      await tester.pump();
      await closed.close();
      await tester.pump(const Duration(seconds: 30));
      expect(runs, hasLength(1));
      await cubit.close();

      // Switched off before the time came: nothing cleaned.
      final off = InitCubit()
        ..scheduleImageCacheTrim(() => null, delay: const Duration(seconds: 5), trim: (l) async => runs.add(l));
      await tester.pumpWidget(const SizedBox(width: 1));
      await tester.pump(const Duration(seconds: 6));
      expect(runs, hasLength(1));
      await off.close();
    });
  });

  group('2. the pictures of a saved thread page', () {
    test('the key of an image url: the last part of its path with its query', () {
      expect(imageCacheKeyOf('https://www.tsdm39.com/data/attachment/forum/202610/23/abc.jpg'), 'abc.jpg');
      expect(imageCacheKeyOf('data/attachment/forum/202610/23/abc.jpg'), 'abc.jpg');
      expect(
        imageCacheKeyOf('https://tsdm39.com/forum.php?mod=attachment&aid=MTIz&nothumb=yes#x'),
        'forum.php?mod=attachment&aid=MTIz&nothumb=yes',
      );
      expect(imageCacheKeyOf('src=forum.php?mod=image&aid=7'), 'forum.php?mod=image&aid=7');
      expect(imageCacheKeyOf(''), '');
    });

    test('a JSON answer: every url and path of its fields, escaped or not, and the avatars of its authors', () {
      final body = jsonEncode({
        'ok': 1,
        'type': 'thread',
        'posts': [
          {
            'authorid': '7',
            'avatar': 'https://www.tsdm39.com/data/avatar/000/00/00/07_avatar_middle.jpg',
            'body_html':
                '<p>text</p><img src="static/image/common/none.gif" zoomfile="data/attachment/forum/202610/23/big.jpg" '
                'file="data/attachment/forum/202610/23/big.jpg"><img src="forum.php?mod=attachment&amp;aid=MTIz&amp;x=1">',
            'attachments': [
              {'aid': 9, 'isimage': 1, 'url': 'data/attachment/forum/202610/23/att.png'},
            ],
          },
          {'authorid': 1234567, 'avatar': '', 'body_html': '<img src="https://img.example/outer.webp">'},
        ],
      });
      final keys = imageKeysOfPage(body);
      for (final url in [
        'https://www.tsdm39.com/data/attachment/forum/202610/23/big.jpg',
        '$baseUrl/forum.php?mod=attachment&aid=MTIz&x=1',
        '$baseUrl/data/attachment/forum/202610/23/att.png',
        'https://img.example/outer.webp',
        avatarUrlOfUid('7')!,
        avatarUrlOfUid('1234567')!,
      ]) {
        expect(keys, contains(imageCacheKeyOf(url)), reason: url);
      }
      // The same answer as the forum printed it, with its slashes escaped.
      final escaped = imageKeysOfPage(body.replaceAll('/', r'\/'));
      expect(escaped, contains('big.jpg'));
      expect(escaped, contains('forum.php?mod=attachment&aid=MTIz&x=1'));
    });

    test('spaces, character references and percent-encoding are read alike on both sides', () {
      final cases = <String, String>{
        r'{"message":"[img]https:\/\/img.example\/图片.jpg[\/img]"}': 'https://img.example/图片.jpg',
        '<img src="https://img.example/a b.jpg">': 'https://img.example/a b.jpg',
        '<img src="https://img.example/%E5%9B%BE.jpg">': 'https://img.example/图.jpg',
        '<img src="forum.php?mod=attachment&#x26;aid=XYZ">': '$baseUrl/forum.php?mod=attachment&aid=XYZ',
        '[img=100,100]https://img.example/abc.jpg[/img]': 'https://img.example/abc.jpg',
        '<img src="//img.example/proto.jpg">': 'https://img.example/proto.jpg',
        r'{"body_html":"<img zoomfile=\"data/attachment/forum/x y.jpg\">"}': '$baseUrl/data/attachment/forum/x y.jpg',
      };
      for (final MapEntry(key: page, value: url) in cases.entries) {
        expect(imageKeysOfPage(page), contains(imageCacheKeyOf(url)), reason: page);
      }
    });

    test('a web page: the attributes of its images, quoted or not', () {
      const page =
          '<div class="pcb"><img id="aimg_1" src="static/image/common/none.gif" zoomfile="data/attachment/forum/a1.jpg" '
          "file='data/attachment/forum/a1.jpg'> <img src=https://img.example/plain.png alt=x> "
          '<div style="background:url(https://img.example/bg.jpg)"></div></div>';
      final keys = imageKeysOfPage(page);
      expect(keys, containsAll(['a1.jpg', 'plain.png', 'bg.jpg']));
    });
  });

  group('3. the plan', () {
    const now = 1000 * _hour;
    final files = {
      for (final name in ['a', 'b', 'c', 'd', 'e']) name: (size: 100, modifiedMs: now - 48 * _hour),
    };
    final rows = [
      _row('https://img.example/a', now - 1 * _hour),
      _row('https://img.example/b', now - 2 * _hour),
      _row('https://img.example/c', now - 3 * _hour),
      _row('https://img.example/d', now - 200 * _hour),
      _row('https://img.example/e', now - 300 * _hour),
    ];

    ImageCacheTrimPlan plan({
      List<ImageCacheTrimRow>? of,
      Map<String, ImageCacheFileStat>? onDisk,
      Set<String> keptUrls = const {},
      Set<String> keptFiles = const {},
      Set<String> keptKeys = const {},
      int? maxAgeMs,
      int maxEntries = 100,
      int maxBytes = 1 << 30,
    }) => planImageCacheTrim(
      rows: of ?? rows,
      files: onDisk ?? files,
      keptUrls: keptUrls,
      keptFiles: keptFiles,
      keptKeys: keptKeys,
      nowMs: now,
      maxAgeMs: maxAgeMs,
      maxEntries: maxEntries,
      maxBytes: maxBytes,
    );

    List<String> deleted(ImageCacheTrimPlan p) => p.rows.map((e) => e.fileName).toList();

    test('within the limits: nothing', () {
      final p = plan(maxAgeMs: 1000 * _hour);
      expect(p.rows, isEmpty);
      expect(p.orphanFiles, isEmpty);
      expect((p.countBefore, p.countAfter, p.bytesBefore, p.bytesAfter), (5, 5, 500, 500));
    });

    test('the age, the count and the size: the least recently shown go first', () {
      expect(deleted(plan(maxAgeMs: 7 * 24 * _hour)), ['e', 'd'], reason: 'not shown for a week, oldest first');
      expect(deleted(plan(maxEntries: 2)), ['e', 'd', 'c']);
      expect(deleted(plan(maxBytes: 350)), ['e', 'd'], reason: 'three files fit');
      expect(plan(maxEntries: 2).countAfter, 2);
    });

    test('the stickers, the avatars of the saved accounts and the offline pictures stay, and count first', () {
      final p = plan(
        maxAgeMs: 24 * _hour,
        maxEntries: 4,
        keptUrls: {'https://img.example/e'},
        keptFiles: {'d'},
        keptKeys: {'c'},
      );
      expect(deleted(p), ['b'], reason: 'kept ones whatever their age, and first: a fills the last place');
      expect(p.countAfter, 4);
      expect(
        deleted(plan(maxEntries: 2, keptUrls: {'https://img.example/e'}, keptFiles: {'d'}, keptKeys: {'c'})),
        [
          'b',
          'a',
        ],
        reason: 'kept ones are never deleted for the count, the others make room',
      );
    });

    test('rows whose file is gone go; files no row names go once old enough', () {
      final p = plan(
        of: [...rows, _row('https://img.example/x', now)],
        onDisk: {
          ...files,
          'orphan-old': (size: 7, modifiedMs: now - 2 * _hour),
          'orphan-new': (size: 7, modifiedMs: now - 10 * 60 * 1000),
        },
      );
      expect(deleted(p), ['x']);
      expect(p.orphanFiles, ['orphan-old'], reason: 'a young one may be an image being saved now');
    });
  });

  group('4. the clean up', () {
    late Directory tmp;
    late AppDatabase db;
    late StorageProvider storage;
    late ImageCacheProvider provider;
    late Directory images;

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('tsdm_image_trim_');
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => switch (call.method) {
          'getApplicationCachePath' || 'getApplicationCacheDirectory' => '${tmp.path}/cache',
          'getApplicationSupportPath' || 'getApplicationSupportDirectory' => '${tmp.path}/support',
          _ => null,
        },
      );
      await initCache();
      images = Directory('${tmp.path}/cache/images');
    });
    tearDownAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      tmp.deleteSync(recursive: true);
    });

    setUp(() {
      for (final f in images.listSync()) {
        f.deleteSync();
      }
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      provider = ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio(), cookie: CookieProvider.buildEmpty()));
      getIt.registerSingleton<StorageProvider>(storage);
    });
    tearDown(() async {
      await provider.dispose();
      await getIt.reset();
      await db.close();
    });

    /// [count] cached images, image `i` last shown `i` hours ago, each with a file of [size] bytes.
    Future<void> cache(int count, {int size = 10, String prefix = 'img'}) async {
      final now = DateTime.now();
      for (var i = 0; i < count; i++) {
        File('${images.path}/$prefix$i').writeAsBytesSync(List.filled(size, 1));
      }
      await db.batch(
        (b) => b.insertAll(db.image, [
          for (var i = 0; i < count; i++)
            ImageCompanion.insert(
              url: 'https://img.example/$prefix$i.png',
              fileName: '$prefix$i',
              lastCachedTime: now.subtract(Duration(hours: i)),
              lastUsedTime: now.subtract(Duration(hours: i)),
            ),
        ]),
      );
    }

    Set<String> filesLeft() => images.listSync().map((e) => e.uri.pathSegments.last).toSet();
    Future<Set<String>> rowsLeft() async => (await db.select(db.image).get()).map((e) => e.fileName).toSet();

    test('within its limits: nothing deleted, nothing read whole', () async {
      await cache(5);
      final result = await provider.trimCache(const ImageCacheLimits(maxAge: Duration(days: 7), maxEntries: 10));
      expect(result, (countBefore: 5, bytesBefore: 50, deletedRows: 0, deletedFiles: 0, more: false));
      expect(filesLeft(), hasLength(5));
    });

    test('beyond the count: the least recently shown go, files and rows, a few thousand a run', () async {
      await cache(30);
      await storage.getImageCache('https://img.example/img29.png');
      await storage.getImageCache('https://img.example/img0.png');
      final first = await provider.trimCache(const ImageCacheLimits(maxEntries: 10, maxDeletesPerRun: 12));
      expect(first?.deletedRows, 12);
      expect(first?.more, isTrue, reason: 'eight more for the next run');
      expect(await rowsLeft(), hasLength(18));
      expect(filesLeft(), hasLength(18));
      expect(await rowsLeft(), isNot(contains('img29')), reason: 'the oldest went first');
      expect(await storage.getImageCache('https://img.example/img29.png'), isNull, reason: 'dropped from memory too');
      expect(await storage.getImageCache('https://img.example/img0.png'), isNotNull, reason: 'kept in memory');

      final second = await provider.trimCache(const ImageCacheLimits(maxEntries: 10, maxDeletesPerRun: 12));
      expect(second?.deletedRows, 8);
      expect(second?.more, isFalse);
      expect(await rowsLeft(), {for (var i = 0; i < 10; i++) 'img$i'});
      expect(filesLeft(), await rowsLeft());
    });

    test('the pictures of the offline pages, the stickers and the account avatars stay though outdated', () async {
      await cache(6);
      // Image 5 is a picture of a saved thread page, 4 a sticker, 3 the avatar of a saved account.
      await db.into(db.cookie).insert(CookieCompanion.insert(username: 'Alice', uid: const Value(1000), cookie: '{}'));
      await db
          .into(db.offlineThread)
          .insert(
            OfflineThreadCompanion.insert(
              uid: 1000,
              tid: 1,
              page: 1,
              orderType: 0,
              authorId: 0,
              size: 10,
              savedAt: DateTime.now(),
              lastUsedAt: 0,
              body: jsonEncode({
                'posts': [
                  {'body_html': r'<img src="https:\/\/img.example\/img5.png">'},
                ],
              }),
            ),
          );
      await db
          .into(db.customImage)
          .insert(
            CustomImageCompanion.insert(url: 'https://img.example/img4.png', addedAt: DateTime.now()),
          );
      await db
          .into(db.userAvatar)
          .insert(
            UserAvatarCompanion.insert(
              username: 'Alice',
              cacheName: 'img3',
              imageUrl: const Value('https://img.example/img3.png'),
            ),
          );
      final result = await provider.trimCache(const ImageCacheLimits(maxAge: Duration(minutes: 30)));
      expect(result?.deletedRows, 2);
      expect(await rowsLeft(), {'img0', 'img3', 'img4', 'img5'});
      expect(filesLeft(), {'img0', 'img3', 'img4', 'img5'});
    });

    test(
      'a run stopped between the files and the rows is finished by the next one; old files no row names go',
      () async {
        await cache(3);
        // Files first: a run killed after the files of a batch left their rows.
        File('${images.path}/img2').deleteSync();
        // An older run deleted rows before their files: those files had no row any more.
        File('${images.path}/left-behind').writeAsBytesSync([1, 2, 3]);
        final old = DateTime.now().subtract(const Duration(hours: 3));
        await File('${images.path}/left-behind').setLastModified(old);
        File('${images.path}/being-saved').writeAsBytesSync([1]);
        final result = await provider.trimCache(const ImageCacheLimits());
        expect(result?.deletedRows, 1);
        expect(await rowsLeft(), {'img0', 'img1'});
        expect(filesLeft(), {'img0', 'img1', 'being-saved'});
      },
    );

    test('a row shown while the clean up runs stays', () async {
      await cache(3);
      storage
        ..beginImageCacheTouchLog()
        ..markImageCacheUsed('https://img.example/img2.png');
      final deleted = await storage.deleteImageCacheRows(
        ['https://img.example/img1.png', 'https://img.example/img2.png'],
        usedNoLaterThan: DateTime.now(),
      );
      storage.endImageCacheTouchLog();
      expect(deleted, 1);
      expect(await rowsLeft(), {'img0', 'img2'});
    });
  });
}
