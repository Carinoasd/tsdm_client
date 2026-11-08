/// The card of a video of bilibili or YouTube in a post shows its cover, title, author and length: which addresses
/// are videos, what the sites answer, what is kept, and the card itself.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/html/media_card.dart';
import 'package:tsdm_client/utils/html/media_preview.dart';

const _bvid = 'BV17x411w7KC';
const _yt = 'dQw4w9WgXcQ';

MediaPreviewTarget? _t(String url) => MediaPreviewTarget.tryParse(Uri.tryParse(url));

String? _key(String url) => _t(url)?.key;

const Map<String, Object?> _biliAnswer = {
  'code': 0,
  'data': {
    'title': 'A title',
    'pic': 'http://i2.hdslb.com/bfs/archive/x.jpg',
    'duration': 3725,
    'owner': {'name': 'An uploader'},
  },
};

const _ytAnswer = {
  'title': 'A song',
  'author_name': 'A singer',
  'thumbnail_url': 'https://i.ytimg.com/vi/$_yt/hqdefault.jpg',
};

/// Every cover fails to load: nothing to fetch in a widget test.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('addresses', () {
    test('bilibili: BV, av, the player, with or without a part', () {
      expect(_key('https://www.bilibili.com/video/$_bvid'), 'bili:$_bvid');
      expect(_key('https://www.bilibili.com/video/$_bvid/?p=2'), 'bili:$_bvid');
      expect(_key('http://bilibili.com/video/$_bvid/'), 'bili:$_bvid');
      expect(_key('https://m.bilibili.com/video/$_bvid'), 'bili:$_bvid');
      expect(_key('https://www.bilibili.com/video/av170001'), 'bili:av170001');
      expect(_key('https://www.bilibili.com/video/AV170001/'), 'bili:av170001');
      expect(_key('https://player.bilibili.com/player.html?aid=170001&page=1'), 'bili:av170001');
      expect(_key('//player.bilibili.com/player.html?bvid=$_bvid&page=1'), isNull, reason: 'not absolute');
      expect(_key('https://player.bilibili.com/player.html?bvid=$_bvid&page=1'), 'bili:$_bvid');
      expect(_t('https://www.bilibili.com/video/av170001')?.apiUrl.toString(), contains('aid=170001'));
      expect(_t('https://www.bilibili.com/video/$_bvid')?.apiUrl.toString(), contains('bvid=$_bvid'));
    });

    test('bilibili: a short link is not followed, nor is a page that is no video', () {
      expect(_key('https://b23.tv/abcdEFG'), isNull);
      expect(_key('https://www.bilibili.com/bangumi/play/ep1'), isNull);
      expect(_key('https://www.bilibili.com/video/BV1'), isNull);
      expect(_key('https://www.bilibili.com/video/av0'), isNull);
      expect(_key('https://www.bilibili.com/video/avx1'), isNull);
      expect(_key('https://player.bilibili.com/player.html?aid=abc'), isNull);
      expect(_key('https://evilbilibili.com/video/$_bvid'), isNull);
      expect(_key('https://bilibili.com.evil.example/video/$_bvid'), isNull);
    });

    test('YouTube: youtu.be, watch, shorts, embed', () {
      expect(_key('https://youtu.be/$_yt'), 'yt:$_yt');
      expect(_key('https://youtu.be/$_yt?t=10'), 'yt:$_yt');
      expect(_key('https://www.youtube.com/watch?v=$_yt'), 'yt:$_yt');
      expect(_key('https://www.youtube.com/watch?feature=share&v=$_yt&t=5'), 'yt:$_yt');
      expect(_key('https://m.youtube.com/watch?v=$_yt'), 'yt:$_yt');
      expect(_key('https://youtube.com/shorts/$_yt'), 'yt:$_yt');
      expect(_key('https://www.youtube.com/shorts/$_yt/'), 'yt:$_yt');
      expect(_key('https://www.youtube.com/embed/$_yt'), 'yt:$_yt');
      expect(_key('https://www.youtube-nocookie.com/embed/$_yt'), 'yt:$_yt');
      expect(_t('https://youtu.be/$_yt')?.apiUrl.toString(), startsWith('https://www.youtube.com/oembed?url='));
      expect(_t('https://youtu.be/$_yt')?.apiUrl.queryParameters['url'], 'https://www.youtube.com/watch?v=$_yt');
    });

    test('YouTube: what is no single video', () {
      expect(_key('https://www.youtube.com/watch'), isNull);
      expect(_key('https://www.youtube.com/watch?v=short'), isNull);
      expect(_key('https://www.youtube.com/playlist?list=PL1234567890A'), isNull);
      expect(_key('https://www.youtube.com/@channel'), isNull);
      expect(_key('https://youtu.be/'), isNull);
      expect(_key('https://youtu.be/$_yt/extra'), isNull);
      expect(_key('https://youtube.com.evil.example/watch?v=$_yt'), isNull);
    });

    test('other sites, other schemes, nothing', () {
      expect(_key('https://www.nicovideo.jp/watch/sm9'), isNull);
      expect(_key('ftp://www.bilibili.com/video/$_bvid'), isNull);
      expect(_key('https://www.youtube.com/watch?v=%zz'), isNull);
      expect(MediaPreviewTarget.tryParse(null), isNull);
    });
  });

  group('answers', () {
    test('bilibili: title, uploader, cover on https, length', () {
      final preview = const BilibiliTarget.bvid(_bvid).parse(_biliAnswer)!;
      expect(preview.title, 'A title');
      expect(preview.author, 'An uploader');
      expect(preview.thumbnail.toString(), 'https://i2.hdslb.com/bfs/archive/x.jpg@480w_270h_1c.webp');
      expect(preview.duration, const Duration(seconds: 3725));
      expect(preview.durationText, '1:02:05');
    });

    test('bilibili: an error code, no title or a page instead of json is none', () {
      const target = BilibiliTarget.bvid(_bvid);
      expect(target.parse({'code': -404, 'message': 'gone'}), isNull);
      expect(target.parse({'code': 0, 'data': <String, dynamic>{}}), isNull);
      expect(
        target.parse({
          'code': 0,
          'data': {'title': '  '},
        }),
        isNull,
      );
      expect(target.parse('<html></html>'), isNull);
      expect(target.parse(null), isNull);
      final bare = target.parse({
        'code': 0,
        'data': {'title': 'T', 'pic': '//i0.hdslb.com/a.png', 'duration': 0},
      })!;
      expect(bare.author, isNull);
      expect(bare.duration, isNull);
      expect(bare.durationText, isNull);
      expect(bare.thumbnail.toString(), 'https://i0.hdslb.com/a.png@480w_270h_1c.webp');
    });

    test('YouTube: no length, as oEmbed has none', () {
      final preview = const YoutubeTarget(_yt).parse(_ytAnswer)!;
      expect(preview.title, 'A song');
      expect(preview.author, 'A singer');
      expect(preview.thumbnail.toString(), contains('hqdefault'));
      expect(preview.duration, isNull);
      expect(const YoutubeTarget(_yt).parse({'author_name': 'x'}), isNull);
    });

    test('a length under an hour is m:ss', () {
      String? text(int s) => MediaPreview(
        title: 't',
        duration: Duration(seconds: s),
      ).durationText;
      expect(text(5), '0:05');
      expect(text(65), '1:05');
      expect(text(3599), '59:59');
      expect(text(3600), '1:00:00');
    });
  });

  group('repository', () {
    test('a video is asked once, however often the card is built', () async {
      var calls = 0;
      final repo = MediaPreviewRepository(
        fetcher: (_) async {
          calls++;
          return _biliAnswer;
        },
      );
      const target = BilibiliTarget.bvid(_bvid);
      final results = await Future.wait([repo.preview(target), repo.preview(target)]);
      expect(results.every((p) => p?.title == 'A title'), isTrue);
      await repo.preview(target);
      expect(calls, 1);
    });

    test('a request that takes too long gives none, and is asked again later, not at once', () async {
      var calls = 0;
      var now = DateTime(2026);
      final repo = MediaPreviewRepository(
        timeout: const Duration(milliseconds: 20),
        now: () => now,
        fetcher: (_) {
          calls++;
          return calls == 1 ? Completer<Object?>().future : Future.value(_ytAnswer);
        },
      );
      const target = YoutubeTarget(_yt);
      expect(await repo.preview(target), isNull);
      expect(await repo.preview(target), isNull);
      expect(calls, 1);
      now = now.add(const Duration(minutes: 3));
      expect((await repo.preview(target))?.title, 'A song');
      expect(calls, 2);
    });

    test('an error is none, not thrown', () async {
      final repo = MediaPreviewRepository(fetcher: (_) async => throw StateError('offline'));
      expect(await repo.preview(const YoutubeTarget(_yt)), isNull);
    });

    test('the oldest goes when over capacity', () async {
      var calls = 0;
      final repo = MediaPreviewRepository(
        capacity: 2,
        fetcher: (_) async {
          calls++;
          return _ytAnswer;
        },
      );
      await repo.preview(const YoutubeTarget('aaaaaaaaaaa'));
      await repo.preview(const YoutubeTarget('bbbbbbbbbbb'));
      await repo.preview(const YoutubeTarget('ccccccccccc'));
      expect(calls, 3);
      await repo.preview(const YoutubeTarget('ccccccccccc'));
      expect(calls, 3);
      await repo.preview(const YoutubeTarget('aaaaaaaaaaa'));
      expect(calls, 4);
    });
  });

  group('card', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late MediaPreviewRepository original;
    var asked = <Uri>[];
    late Object? Function(Uri) answer;

    setUp(() async {
      asked = [];
      answer = (_) => _biliAnswer;
      original = MediaPreviewRepository.instance;
      MediaPreviewRepository.instance = MediaPreviewRepository(
        fetcher: (url) async {
          asked.add(url);
          return answer(url);
        },
      );
      db = AppDatabase(NativeDatabase.memory());
      settings = SettingsRepository(StorageProvider(db, {}, {}));
      await settings.init();
      getIt
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
    });

    tearDown(() async {
      await getIt.reset();
      MediaPreviewRepository.instance = original;
      await settings.dispose();
      await db.close();
    });

    Future<void> pumpCard(WidgetTester tester, String url, {double width = 400}) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: SizedBox(
                  width: width,
                  child: Text.rich(
                    WidgetSpan(
                      child: PostMediaCard(PostMedia(kind: PostMediaKind.video, url: Uri.parse(url))),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('is on by default and shows title, uploader and length', (tester) async {
      expect(SettingsKeys.postMediaPreview.defaultValue, isTrue);
      await pumpCard(tester, 'https://www.bilibili.com/video/$_bvid/?p=1');
      expect(find.text('A title'), findsOneWidget);
      expect(find.text('An uploader'), findsOneWidget);
      expect(find.text('1:02:05'), findsOneWidget);
      expect(find.textContaining('影音'), findsNothing);
      expect(asked.single.queryParameters['bvid'], _bvid);
      expect(tester.takeException(), isNull);
    });

    testWidgets('YouTube: no length badge', (tester) async {
      answer = (_) => _ytAnswer;
      await pumpCard(tester, 'https://youtu.be/$_yt');
      expect(find.text('A song'), findsOneWidget);
      expect(find.text('A singer'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is Text && RegExp(r'^\d+:\d\d$').hasMatch(w.data ?? '')), findsNothing);
    });

    testWidgets('a site that tells nothing leaves the small card', (tester) async {
      answer = (_) => throw StateError('offline');
      await pumpCard(tester, 'https://www.bilibili.com/video/$_bvid');
      expect(find.textContaining('影音：Bilibili', findRichText: true), findsOneWidget);
      expect(find.byType(InkWell), findsOneWidget);
    });

    testWidgets('while the site has not answered yet it is the small card too', (tester) async {
      final completer = Completer<Object?>();
      MediaPreviewRepository.instance = MediaPreviewRepository(fetcher: (_) => completer.future);
      await pumpCard(tester, 'https://www.bilibili.com/video/$_bvid');
      expect(find.textContaining('影音：Bilibili', findRichText: true), findsOneWidget);
      completer.complete(_biliAnswer);
      await tester.pump();
      await tester.pump();
      expect(find.text('A title'), findsOneWidget);
      expect(find.textContaining('影音：Bilibili', findRichText: true), findsNothing);
    });

    testWidgets('a short link is the small card and asks nothing', (tester) async {
      await pumpCard(tester, 'https://b23.tv/abcdEFG');
      expect(find.textContaining('影音：Bilibili', findRichText: true), findsOneWidget);
      expect(asked, isEmpty);
    });

    testWidgets('turned off in the settings: the small card, nothing asked', (tester) async {
      await tester.runAsync(() => settings.setValue(SettingsKeys.postMediaPreview, false));
      await pumpCard(tester, 'https://www.bilibili.com/video/$_bvid');
      expect(find.textContaining('影音：Bilibili', findRichText: true), findsOneWidget);
      expect(asked, isEmpty);
    });

    testWidgets('a narrow place holds it', (tester) async {
      await pumpCard(tester, 'https://www.bilibili.com/video/$_bvid', width: 200);
      expect(find.text('A title'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(PostMediaCard)).width, lessThanOrEqualTo(200));
    });
  });

  test('the setting has a title in every language', () {
    for (final locale in AppLocale.values) {
      expect(locale.translations.settingsPage.appearanceSection.postMediaPreview.title, isNotEmpty);
    }
  });
}
