/// Two faults found in the logs of the reports of 1.48.0 and 1.48.1:
///
/// 1. the credit pages read from the web page («我的积分» and the credit log of an older plugin) dropped every log row
///    another plugin wrote (a game's reward, a check-in): such a row names no operation and the page prints its title
///    as plain text, without the link the parser required ("failed to build PointsChange: operation=null"); a member
///    whose recent changes were all such rows saw an empty list;
/// 2. an image answered with no bytes (some avatars on the forum are zero-byte files answering 200) was cached and then
///    failed to decode every time it showed ("Invalid image data"), never asked again; an empty file an earlier version
///    cached is read as not cached and loaded again. The emoji cache, a cache of its own, the same (a review of 1.48.2).
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/points/utils/parse_points.dart';
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
import 'package:universal_html/parsing.dart';

/// The recent changes of «我的积分» on Discuz X5 (`spacecp_credit_base`): a forum operation (a link to the log filtered
/// by it) and a log another plugin wrote (its title, plain text; its text as the detail).
const _creditTable = '''
<table cellspacing="0" cellpadding="0" class="dt">
<tr><th width="80">操作</th><th width="164">积分变更</th><th>变更后</th><th>详情</th><th width="100">变更时间</th></tr>
<tr>
<td><a href="home.php?mod=spacecp&ac=credit&op=log&optype=PRC">评分</a></td>
<td>天使币 <span class="xi1">+5</span></td>
<td>天使币 120</td>
<td><a href="forum.php?mod=viewthread&tid=1">帖子</a></td>
<td>2026-10-24 12:30:00</td>
</tr>
<tr>
<td>游戏中心</td>
<td>天使币 <span class="xi1">+12</span></td>
<td>天使币 115</td>
<td>贪食蛇 成绩 220</td>
<td>2026-10-24 12:29:01</td>
</tr>
</table>''';

/// Answers every image request with [bytes] and counts them.
final class _Images implements HttpClientAdapter {
  _Images(this.bytes);

  List<int> bytes;
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
        Headers.contentTypeHeader: ['image/jpeg'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('1. credit logs another plugin wrote', () {
    test("read with their title, no filter link, and the plugin's text as the detail", () {
      final changes = buildChangeListFromTable(parseHtmlDocument(_creditTable).querySelector('table.dt')!);
      expect(changes, hasLength(2));
      expect(changes[0].operation, '评分');
      expect(changes[0].operationFilterUrl, 'home.php?mod=spacecp&ac=credit&op=log&optype=PRC');
      final game = changes[1];
      expect(game.operation, '游戏中心');
      expect(game.operationFilterUrl, isEmpty);
      expect(game.changeMap, {'天使币': '+12'});
      expect(game.detail, contains('贪食蛇 成绩 220'));
      expect(game.redirectUrl, isNull);
    });

    test('a row with nothing in its first cell is still no change', () {
      final table = _creditTable.replaceFirst('<td>游戏中心</td>', '<td> </td>');
      expect(buildChangeListFromTable(parseHtmlDocument(table).querySelector('table.dt')!), hasLength(1));
    });
  });

  group('2. an image answered with no bytes', () {
    late AppDatabase db;
    late Directory tmp;
    late _Images images;
    late StorageProvider storage;
    late ImageCacheProvider provider;
    final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff, 1, 2, 3]);

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('tsdm_empty_images_');
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
      db = AppDatabase(NativeDatabase.memory());
      images = _Images(const []);
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
    tearDown(() async {
      await provider.dispose();
      await getIt.reset();
      await db.close();
    });

    File fileOf(String url) => provider.getCacheFile(url.fileNameV5())!;

    test('is no image: never cached, asked again the next time', () async {
      const url = 'https://img.example/empty.jpg';
      expect(await provider.getOrMakeCache(const ImageCacheGeneralRequest(url)), isA<None>());
      expect(fileOf(url).existsSync(), isFalse);
      expect(await storage.getImageCache(url), isNull);

      images.bytes = jpeg;
      expect((await provider.getOrMakeCache(const ImageCacheGeneralRequest(url))).toNullable(), jpeg);
      expect(images.requests, 2);
    });

    test('an avatar answering nothing is remembered like a missing one', () async {
      const url = 'https://www.example/data/avatar/001/22/66/17_avatar_middle.jpg';
      final got = await provider.getOrMakeCache(const ImageCacheUserAvatarRequest(username: 'alice', imageUrl: url));
      expect(got, isA<None>());
      expect(provider.isKnownMissingAvatar(url), isTrue, reason: 'not asked again by every card');
      expect(fileOf(url).existsSync(), isFalse);
    });

    test('an emoji answered with no bytes is not cached either; an empty emoji file is no emoji', () async {
      await provider.updateEmojiCache('9', 'empty', const []);
      expect(provider.hasEmojiCacheFile('9', 'empty'), isFalse, reason: 'asked again');
      await provider.updateEmojiCache('9', 'full', jpeg);
      expect(provider.hasEmojiCacheFile('9', 'full'), isTrue);
      expect(await provider.getEmojiCache('9', 'full'), jpeg);
      // An empty file an earlier version wrote.
      final file =
          Directory(tmp.path)
              .listSync(recursive: true)
              .whereType<File>()
              .singleWhere(
                (f) => f.path.endsWith('/9_full.jpg'),
              )
            ..writeAsBytesSync(const []);
      expect(file.lengthSync(), 0);
      expect(provider.hasEmojiCacheFile('9', 'full'), isFalse);
      expect(await provider.getEmojiCache('9', 'full'), isNull);
      expect(provider.getEmojiCacheSync('9', 'full'), isNull);
    });

    test('an empty file an earlier version cached is read as not cached and loaded again', () async {
      const url = 'https://img.example/cached-empty.jpg';
      fileOf(url).writeAsBytesSync(const []);
      await storage.updateImageCache(url, fileName: url.fileNameV5());
      images.bytes = jpeg;
      expect((await provider.getOrMakeCache(const ImageCacheGeneralRequest(url))).toNullable(), jpeg);
      expect(images.requests, 1);
      expect(fileOf(url).readAsBytesSync(), jpeg);
    });
  });
}
