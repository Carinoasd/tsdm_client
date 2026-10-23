/// The forum's app API, plugin 3.1.0: the excerpt and the thumbnail of every thread in the lists.
///
/// The forum page (`schema: 2`), the guide lists (`schema: 7`), the search results (`schema: 6`) and the "my threads"
/// pages (`schema: 9`, a member's threads too) asked with `tsdmpreview=1` carry `preview` on every thread row: the
/// excerpt of the first floor, up to three of its images and how many it has, or the reason the plugin gives none (a
/// paid thread, a read permission, a password, a forum the viewer may not enter…). The app asks for it once the plugin
/// told it answers it (`status` `preview: 1`, or a version of 3.1.0 or later) and a setting shows some of it; a card
/// then shows two lines of the excerpt under the title and one thumbnail on the right ("+N" when there are more),
/// nothing at all for a withheld preview. Settings: the excerpt on or off, the thumbnail always, on Wi-Fi only (the
/// default) or never.
///
/// The fixtures `preview_v*.json` are answers of the test forum (Discuz X5.0.2 with plugin 3.1.0, 2026-10-23) made by
/// the plugin's contract tool with its fixture script (every rule one thread), scrubbed and with the test accounts
/// renamed. The markers in the fixture threads tell what the viewer may read: `VIS_` is readable, `SEC_` never is.
///
/// Screenshots: with `LISTPREVIEW_SHOTS_DIR` (output directory) and `LISTPREVIEW_SHOTS_FONT` (a font file with CJK
/// glyphs) set, the last group writes the forum page, the guide list and the search results (light, dark, large text)
/// as png files.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_api.dart';
import 'package:tsdm_client/features/forum/view/forum_page.dart';
import 'package:tsdm_client/features/homepage/repository/guide_index_repository.dart';
import 'package:tsdm_client/features/latest_thread/models/latest_thread.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/features/latest_thread/utils/guide_page_api.dart';
import 'package:tsdm_client/features/latest_thread/view/latest_thread_page.dart';
import 'package:tsdm_client/features/member_thread/utils/member_thread_url.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/features/my_thread/utils/my_thread_page_api.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/search/repository/search_repository.dart';
import 'package:tsdm_client/features/search/utils/search_page_api.dart';
import 'package:tsdm_client/features/search/view/search_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/thread_card_appearance.dart';
import 'package:tsdm_client/features/thread_preview/widgets/thread_preview_section.dart';
import 'package:tsdm_client/features/tsdmapp/list_preview.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/utils/network_usage.dart';
import 'package:tsdm_client/widgets/cached_image/cover_resize_image.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';

const _dir = 'test/data/tsdmapp';

String _raw(String name) => File('$_dir/$name').readAsStringSync();

Map<String, dynamic> _json(String name) => jsonDecode(_raw(name)) as Map<String, dynamic>;

/// Every thread row of the answer [name], the rows of the guide index modules included.
List<Map<String, dynamic>> _rows(String name) {
  final json = _json(name);
  return [
    ...tsdmAppList(json['threads']),
    for (final module in tsdmAppList(json['modules'])) ...tsdmAppList(module['threads']),
  ];
}

/// The fixture thread of key [k] (`K01`, `F29`…): the plugin's fixture names its threads `tsdmapp 3.1.0 預覽 K01 000000`.
Map<String, dynamic> _fx(String name, String k) =>
    _rows(name).firstWhere((e) => (e['subject'] as String).endsWith(' $k 000000'));

/// [row] as the plugin before 3.1.0 answered it: without `preview`.
Map<String, dynamic> _withoutPreview(Map<String, dynamic> row) => {...row}..remove('preview');

/// The `status` answer of plugin [version].
Map<String, Object?> _status(String version, {bool preview = false}) => {
  'ok': 1,
  'api': 1,
  'version': version,
  'time': 1700000000,
  'uid': 35,
  'nodoc': 1,
  if (preview) 'preview': 1,
};

/// A forum answering [answer] for every request and recording it.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  Object Function(RequestOptions options) answer;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final a = answer(options);
    return ResponseBody.fromString(
      a is String ? a : jsonEncode(a),
      200,
      headers: {
        Headers.contentTypeHeader: [if (a is String) 'text/html; charset=utf-8' else 'application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Serves [png] for every image url and records the urls (without the `mobile=no` the client adds).
final class _Images implements HttpClientAdapter {
  _Images(this.png);

  Uint8List Function(String url) png;
  final requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final params = {...options.uri.queryParameters}..remove('mobile');
    final uri = options.uri;
    final url = Uri(
      scheme: uri.scheme,
      host: uri.host,
      path: uri.path,
      queryParameters: params.isEmpty ? null : params,
    ).toString();
    // The avatars of the cards are not the previews.
    if (!uri.path.contains('/data/avatar/')) {
      requested.add(url);
    }
    return ResponseBody.fromBytes(
      png(url),
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A png picture of [width] by [height]: a sky, a sun and a hill in colors taken from [seed].
Future<Uint8List> _picture(int width, int height, {int seed = 0}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final hues = [200.0, 28.0, 140.0, 280.0, 340.0, 50.0];
  final hue = hues[seed % hues.length];
  final rect = Offset.zero & Size(width.toDouble(), height.toDouble());
  canvas
    ..drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
          HSLColor.fromAHSL(1, hue, 0.6, 0.72).toColor(),
          HSLColor.fromAHSL(1, (hue + 30) % 360, 0.55, 0.5).toColor(),
        ]),
    )
    ..drawCircle(Offset(width * 0.72, height * 0.32), height * 0.14, Paint()..color = const Color(0xFFFFF3C4))
    ..drawPath(
      Path()
        ..moveTo(0, height.toDouble())
        ..lineTo(width * 0.35, height * 0.45)
        ..lineTo(width * 0.7, height.toDouble())
        ..close(),
      Paint()..color = HSLColor.fromAHSL(1, (hue + 160) % 360, 0.35, 0.35).toColor(),
    );
  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// Settings and storage of one test, as the app registers them.
final class _App {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late _Forum forum;
  late _Images images;

  Future<void> setUp({Uint8List Function(String url)? png}) async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    forum = _Forum((r) => fail('unexpected request: ${r.uri}'));
    images = _Images(png ?? (_) => _tinyPng);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = images)),
      );
    await settings.init();
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
  }

  Future<void> tearDown() async {
    await settingsBloc.close();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.unregister<ImageCacheProvider>();
    await getIt.unregister<NetClientProvider>();
    await getIt.unregister<CookieProvider>();
    await getIt.unregister<SettingsRepository>();
    await getIt.unregister<StorageProvider>();
    await settings.dispose();
    await db.close();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }
}

/// A 1x1 transparent png.
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void _knowsPreview() => TsdmAppApi.pluginInfo.value = TsdmAppPluginInfo.fromAnswer(_status('3.1.0', preview: true));

bool _asksPreview(RequestOptions o) => o.uri.queryParameters['tsdmpreview'] == '1';

void main() {
  late Directory tmp;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    tmp = Directory.systemTemp.createTempSync('tsdm_list_preview_');
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
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
    await tmp.delete(recursive: true);
  });
  setUp(() {
    TsdmAppApi.reset();
    NetworkUsage.reset();
  });

  group('A. the plugin tells it answers the previews', () {
    test('status preview: 1, or a version of 3.1.0 or later; never before something told', () {
      expect(tsdmAppPreviewVersion, '3.1.0');
      expect(expectedTsdmAppVersion, '3.1.0');
      expect(TsdmAppApi.knowsPreview, isFalse, reason: 'nothing told yet');

      final status = TsdmAppPluginInfo.fromAnswer(_status('3.1.0', preview: true))!;
      expect(status.preview, isTrue);
      expect(TsdmAppPluginInfo.fromAnswer(_status('3.1.0'))!.preview, isFalse);
      expect(status, isNot(TsdmAppPluginInfo.fromAnswer(_status('3.1.0'))));

      TsdmAppApi.pluginInfo.value = status;
      expect(TsdmAppApi.knowsPreview, isTrue);
      TsdmAppApi.pluginInfo.value = const TsdmAppPluginInfo(version: '3.1.0', api: 1, nodoc: false);
      expect(TsdmAppApi.knowsPreview, isTrue, reason: 'notify names the version only');
      TsdmAppApi.pluginInfo.value = const TsdmAppPluginInfo(version: '3.10.0', api: 1, nodoc: false);
      expect(TsdmAppApi.knowsPreview, isTrue);
      TsdmAppApi.pluginInfo.value = const TsdmAppPluginInfo(version: '3.0.0', api: 1, nodoc: true);
      expect(TsdmAppApi.knowsPreview, isFalse, reason: 'the small forms, not the previews');
      TsdmAppApi.reset();
      expect(TsdmAppApi.knowsPreview, isFalse);
    });

    test('a notify answer of the same version keeps what status told', () async {
      final app = _App();
      await app.setUp();
      addTearDown(app.tearDown);
      app.forum.answer = (r) => r.uri.queryParameters['action'] == 'status'
          ? _status('3.1.0', preview: true)
          : {'ok': 1, 'api': 1, 'version': '3.1.0', 'time': 1700000000, 'notices': <Object>[]};
      final client = getIt.get<NetClientProvider>();
      await TsdmAppApi.ask(client, 'status');
      expect(TsdmAppApi.pluginInfo.value?.preview, isTrue);
      await TsdmAppApi.ask(client, 'notify');
      expect(TsdmAppApi.pluginInfo.value?.preview, isTrue, reason: 'notify names no preview');
      expect(TsdmAppApi.knowsPreview, isTrue);
    });
  });

  group('B. the lists ask for the previews when the plugin answers them and a setting shows them', () {
    final app = _App();
    setUp(app.setUp);
    tearDown(app.tearDown);

    /// The requests of every list page the parameter is for, and of those it is not for.
    Future<({List<RequestOptions> lists, List<RequestOptions> others})> askAll() async {
      app.forum
        ..requests.clear()
        ..answer = (r) => switch (r.uri.path) {
          '/forum.php' when r.uri.queryParameters['mod'] == 'forumdisplay' => _json('preview_v2_forum.json'),
          '/forum.php' when r.uri.queryParameters['view'] == 'index' => _json('preview_v7_guide_index.json'),
          '/forum.php' => _json('preview_v7_guide_newthread.json'),
          '/search.php' => _json('preview_v6_search.json'),
          '/home.php' when r.uri.queryParameters['type'] == 'reply' => _json('preview_v9_mythread_reply.json'),
          _ => _json('preview_v9_mythread.json'),
        };
      await ForumRepository().fetchForum(fid: '13', filterState: const FilterState()).run();
      await LatestThreadRepository().fetchPage(guideUrl('newthread')).run();
      await LatestThreadRepository().fetchPage('$baseUrl/search.php?mod=forum&srchfrom=86400&searchsubmit=yes').run();
      final search = SearchRepository();
      await search.searchWithParameters(keyword: 'k', fid: '0', uid: '0', pageNumber: 1).run();
      await search.searchWithParameters(keyword: 'k', fid: '0', uid: '0', pageNumber: 2).run();
      await MyThreadRepository().fetchPage(myThreadThreadUrl).run();
      await MyThreadRepository().fetchPage(memberThreadUrl(MemberThreadTab.thread, uid: '31')).run();
      final lists = [...app.forum.requests];
      app.forum.requests.clear();
      await MyThreadRepository().fetchPage(myThreadReplyUrl).run();
      await MyThreadRepository().fetchPage(memberThreadUrl(MemberThreadTab.reply, uid: '31')).run();
      await LatestThreadRepository().fetchPage('${guideUrl('my')}&type=reply').run();
      await const GuideIndexRepository().fetchGuideIndex().run();
      return (lists: lists, others: [...app.forum.requests]);
    }

    test('an older plugin, or one that told nothing: asked as before', () async {
      for (final info in [null, const TsdmAppPluginInfo(version: '3.0.0', api: 1, nodoc: true)]) {
        TsdmAppApi.pluginInfo.value = info;
        final asked = await askAll();
        expect(asked.lists, hasLength(7));
        expect([...asked.lists, ...asked.others].where(_asksPreview), isEmpty, reason: '$info');
      }
    });

    test(
      'plugin 3.1.0: every list of threads, the filters and the search id kept; not the replies nor the index',
      () async {
        _knowsPreview();
        final asked = await askAll();
        expect(asked.lists, hasLength(7));
        expect(asked.lists.every(_asksPreview), isTrue, reason: '${asked.lists.map((e) => e.uri)}');
        expect(asked.lists.every((e) => e.uri.queryParameters['tsdmapp'] == 'json'), isTrue);
        expect(asked.lists.first.uri.queryParameters, containsPair('forumdefstyle', 'yes'));
        expect(asked.lists[4].uri.queryParameters, containsPair('searchid', '1'), reason: 'page 2 of the same search');
        expect(asked.lists[6].uri.queryParameters, containsPair('uid', '31'));
        expect(asked.others, hasLength(4));
        expect(asked.others.where(_asksPreview), isEmpty, reason: '${asked.others.map((e) => e.uri)}');
      },
    );

    test('the settings: nothing asked when no list would show any of it', () async {
      _knowsPreview();
      Future<bool> asks({required bool excerpt, required ThreadThumbnailMode mode}) async {
        await app.settings.setValue(SettingsKeys.threadCardShowExcerpt, excerpt);
        await app.settings.setValue(SettingsKeys.threadCardThumbnailMode, mode.index);
        return (await askAll()).lists.every(_asksPreview);
      }

      expect(await asks(excerpt: false, mode: ThreadThumbnailMode.never), isFalse);
      expect((await askAll()).lists.where(_asksPreview), isEmpty);
      expect(await asks(excerpt: false, mode: ThreadThumbnailMode.always), isTrue);
      expect(await asks(excerpt: false, mode: ThreadThumbnailMode.wifiOnly), isTrue);
      expect(await asks(excerpt: true, mode: ThreadThumbnailMode.never), isTrue);
    });

    test('withTsdmAppListPreview: before the fragment, once', () {
      expect(withTsdmAppListPreview('$baseUrl/forum.php?mod=guide&view=new'), '$baseUrl/forum.php?mod=guide&view=new');
      _knowsPreview();
      expect(
        withTsdmAppListPreview('$baseUrl/forum.php?mod=guide&view=new#top'),
        '$baseUrl/forum.php?mod=guide&view=new&tsdmpreview=1#top',
      );
      expect(withTsdmAppListPreview('$baseUrl/x.php'), '$baseUrl/x.php?tsdmpreview=1');
      const asked = '$baseUrl/forum.php?mod=guide&view=new&tsdmpreview=1';
      expect(withTsdmAppListPreview(asked), asked);
      expect(
        withTsdmAppListPreview('$baseUrl/forum.php?mod=guide&view=index'),
        '$baseUrl/forum.php?mod=guide&view=index',
      );
      expect(tsdmAppListPreviewParameters(), {'tsdmpreview': '1'});
    });
  });

  group('C. the rows read the preview', () {
    test('an excerpt and images: one flowing text, the thumbnail the forum made first, the count of the floor', () {
      final p = ThreadPreview.fromApi(_fx('preview_v2_forum.json', 'K01')['preview'])!;
      expect(p.withheld, isFalse);
      expect(p.excerpt, contains('\r\n\r\n\r\n'), reason: 'kept as it came');
      expect(p.excerptText, 'K01 正文 VIS_K01A_000000 第一段文字，用來看摘要。 第二段 VIS_K01B_000000');
      expect(p.images, hasLength(3));
      expect(p.imageTotal, 4);
      final thumb = p.thumbnailOf()!;
      expect(thumb.thumb, isTrue);
      expect(thumb.url, endsWith('_K01_a1.png.thumb.jpg'));
      expect(thumb.url, startsWith('https://www.tsdm39.com/data/attachment/forum/'));
      expect(thumb.attachment, isTrue);
      expect((thumb.width, thumb.height), (1920, 1080));
      expect(p.moreImagesOf(), 3);
      expect(p.thumbnailOf(external: true)!.url, thumb.url, reason: 'the thumbnail the forum made first anyway');
      expect(p.partial, isFalse);
    });

    test('a withheld preview: no excerpt, no image, whatever the reason', () {
      final reasons = <String>{};
      for (final name in [
        'preview_v2_forum.json',
        'preview_v2_forum_p2.json',
        'preview_v2_forum_low.json',
        'preview_v2_forum_guest.json',
        'preview_v2_forum_sticky_low.json',
        'preview_v7_guide_newthread.json',
        'preview_v7_guide_index.json',
      ]) {
        for (final row in _rows(name)) {
          final p = ThreadPreview.fromApi(row['preview'])!;
          if (!p.withheld) {
            continue;
          }
          reasons.add(p.reason!);
          expect(p.excerpt, isNull);
          expect(p.excerptText, isEmpty);
          expect(p.images, isEmpty);
          expect(p.thumbnailOf(external: true), isNull);
          expect(p.moreImagesOf(external: true), 0);
          expect(ThreadPreviewSection.shows(p, showExcerpt: true, thumbnailMode: ThreadThumbnailMode.always), isFalse);
        }
      }
      expect(reasons, containsAll(['password', 'html', 'json', 'imgcontent', 'readperm', 'moderate', 'banned']));
      expect(reasons, containsAll(['moved', 'hide', 'blocked', 'forum', 'price', 'jammer']));
    });

    test('nothing the viewer may not read is in any preview', () {
      for (final name in Directory(_dir).listSync().map((e) => e.uri.pathSegments.last)) {
        if (!name.startsWith('preview_v')) {
          continue;
        }
        for (final row in _rows(name)) {
          final p = ThreadPreview.fromApi(row['preview']);
          expect(p?.excerpt ?? '', isNot(contains('SEC_')), reason: '$name ${row['subject']}');
        }
      }
      // The guest may not read the paid thread its author sees.
      expect(ThreadPreview.fromApi(_fx('preview_v2_forum_guest.json', 'K10')['preview'])!.reason, 'price');
      expect(ThreadPreview.fromApi(_fx('preview_v2_forum.json', 'K10')['preview'])!.excerptText, 'K10 PAID_K10_000000');
    });

    test('the image shown: attachments only unless the images of other sites are allowed, https before http', () {
      final k20 = ThreadPreview.fromApi(_fx('preview_v2_forum.json', 'K20')['preview'])!;
      expect(k20.images.map((e) => e.secure), [true, false, true]);
      expect(k20.images.map((e) => e.attachment), everyElement(isFalse));
      expect(k20.thumbnailOf(), isNull, reason: 'the site of an [img] would learn who scrolls past');
      expect(k20.moreImagesOf(), 0);
      expect(k20.thumbnailOf(external: true)!.url, 'https://img.example.com/k20a.png');
      expect(k20.moreImagesOf(external: true), 3);
      final http = ThreadPreview.fromApi({
        'excerpt': '',
        'reason': null,
        'images': [
          {'url': 'http://img.example.com/a.png', 'thumb': 0},
          {'url': 'https://img.example.com/b.png', 'thumb': 0},
          {'url': 'data:image/png;base64,AAAA'},
          {'url': '/data/attachment/forum/x.png'},
          {'url': ''},
          'x',
        ],
        'image_total': 2,
      })!;
      expect(http.images.map((e) => e.url), ['http://img.example.com/a.png', 'https://img.example.com/b.png']);
      expect(http.thumbnailOf(external: true)!.url, 'https://img.example.com/b.png');
      expect(http.excerptText, isEmpty);
      expect(ThreadPreviewSection.shows(http, showExcerpt: true, thumbnailMode: ThreadThumbnailMode.never), isFalse);
      expect(ThreadPreviewSection.shows(http, showExcerpt: false, thumbnailMode: ThreadThumbnailMode.always), isFalse);
      expect(
        ThreadPreviewSection.shows(
          http,
          showExcerpt: false,
          thumbnailMode: ThreadThumbnailMode.always,
          externalImages: true,
        ),
        isTrue,
      );

      final k23 = ThreadPreview.fromApi(_fx('preview_v2_forum_p2.json', 'K23')['preview'])!;
      expect((k23.images.length, k23.imageTotal, k23.moreImagesOf()), (3, 7, 6));
      expect(
        k23.thumbnailOf()!.url,
        endsWith('_K23_m1.png'),
        reason: 'the attachment, after two images of other sites',
      );
      final k24 = ThreadPreview.fromApi(_fx('preview_v2_forum_p2.json', 'K24')['preview'])!;
      expect(k24.partial, isTrue);
      expect(k24.excerptText, endsWith(' ...'));

      for (final none in [null, 'x', 1, <Object>[]]) {
        expect(ThreadPreview.fromApi(none), isNull);
      }
      expect(
        const ThreadPreview(
          excerpt: 'x',
          images: [ThreadPreviewImage(url: '')],
        ).moreImagesOf(),
        0,
      );
    });

    test('the models carry it: the forum page with its sticky rows, the search, the guide, my threads', () {
      final page = forumPageFromApi(_json('preview_v2_forum_sticky_low.json'), '30');
      final sticky = page.stickThreadList.firstWhere((e) => e.title.endsWith(' S31 000000'));
      expect(sticky.preview!.reason, 'forum', reason: 'the sticky row of another forum the viewer may not enter');
      expect(page.normalThreadList.where((e) => e.preview != null), hasLength(page.normalThreadList.length));
      final forum = forumPageFromApi(_json('preview_v2_forum.json'), '13');
      expect(forum.normalThreadList.first.preview!.excerptText, startsWith('K01 '));

      final searched = SearchedThread.fromApi(_fx('preview_v6_search.json', 'K01'));
      expect(searched.preview!.thumbnailOf()!.thumb, isTrue);
      final result = searchResultFromApi(_json('preview_v6_search.json'));
      expect(result.data!.every((e) => e.preview != null), isTrue);

      final (guide, _) = latestThreadsFromApi(_json('preview_v7_guide_newthread.json'), guideUrl('newthread'));
      expect(guide.every((e) => e.preview != null), isTrue);
      expect(guide.firstWhere((e) => e.title!.endsWith(' F29 000000')).preview!.reason, 'forum');

      final (mine, _) = myThreadsFromApi(_json('preview_v9_mythread.json'), myThreadThreadUrl);
      expect(mine.first.preview!.excerptText, startsWith('K01 '));
      expect(mine.first.quotedMessage, isNull);
      final (replies, _) = myThreadsFromApi(_json('preview_v9_mythread_reply.json'), myThreadReplyUrl);
      expect(replies, isNotEmpty);
      expect(
        replies.every((e) => e.preview == null && e.quotedMessage != null),
        isTrue,
        reason: 'a reply quotes itself',
      );
    });

    test('the search of 查看新帖: the preview stands for the search excerpt, which shows what the viewer may not read', () {
      final json = _json('preview_v6_search.json');
      final (rows, _) = latestThreadsFromApi(json, '$baseUrl/search.php?mod=forum&srchfrom=86400&searchsubmit=yes');
      final k04 = rows.firstWhere((e) => e.title!.endsWith(' K04 000000'));
      expect(
        _fx('preview_v6_search.json', 'K04')['summary'],
        contains('SEC_K04'),
        reason: 'the forum excerpt leaks it',
      );
      expect(k04.quotedMessage, isNull);
      expect(k04.preview!.excerptText, isNot(contains('SEC_')));
      expect(rows.every((e) => e.quotedMessage == null), isTrue);
      expect(rows.map((e) => e.preview?.excerptText ?? '').join(), isNot(contains('SEC_')));

      // An older plugin: the search excerpt as before.
      final old = LatestThread.fromSearchApi(_withoutPreview(_fx('preview_v6_search.json', 'K01')));
      expect(old.preview, isNull);
      expect(old.quotedMessage, startsWith('K01 正文'));
    });

    test('the answers of an older plugin: no preview anywhere', () {
      expect(
        forumPageFromApi(_json('forum_v2_fid2.json'), '2').normalThreadList.map((e) => e.preview),
        everyElement(isNull),
      );
      expect(searchResultFromApi(_json('search_v6_results.json')).data!.map((e) => e.preview), everyElement(isNull));
      final (guide, _) = latestThreadsFromApi(_json('guide_v7_new.json'), guideUrl('new'));
      expect(guide.map((e) => e.preview), everyElement(isNull));
      final (mine, _) = myThreadsFromApi(_json('mythread_v9_thread.json'), myThreadThreadUrl);
      expect(mine.map((e) => e.preview), everyElement(isNull));
    });

    test('decoded to cover the square: the shorter side at the extent, never enlarged, a long picture bounded', () {
      ui.TargetImageSize size(int w, int h, int extent) => CoverResizeImage.targetSize(w, h, extent);
      expect((size(1920, 1080, 192).width, size(1920, 1080, 192).height), (341, 192));
      expect((size(1080, 1920, 192).width, size(1080, 1920, 192).height), (192, 341));
      expect(size(100, 80, 192).width, isNull, reason: 'smaller than the square: as it is');
      final long = size(800, 20000, 192);
      expect(long.height, 576, reason: 'the longer side at most three times the extent');
      expect(long.width, 23);
      expect(size(0, 100, 192).width, isNull);
    });

    test('the settings: excerpt on, the thumbnail on Wi-Fi only, by default', () {
      expect(SettingsKeys.threadCardShowExcerpt.defaultValue, isTrue);
      expect(SettingsKeys.threadCardExternalThumbnails.defaultValue, isFalse);
      expect(
        ThreadThumbnailMode.fromIndex(SettingsKeys.threadCardThumbnailMode.defaultValue),
        ThreadThumbnailMode.wifiOnly,
      );
      expect(ThreadThumbnailMode.fromIndex(9), ThreadThumbnailMode.wifiOnly);
      expect(ThreadThumbnailMode.fromIndex(0), ThreadThumbnailMode.always);
      expect(ThreadThumbnailMode.fromIndex(2), ThreadThumbnailMode.never);
    });
  });

  group('D. the card', () {
    final app = _App();
    late Uint8List landscape;

    setUpAll(() async => landscape = await _picture(400, 200));
    setUp(() => app.setUp(png: (_) => landscape));
    tearDown(app.tearDown);

    NormalThread thread(String k, {String name = 'preview_v2_forum.json'}) =>
        NormalThread.fromApi(_fx(name, k), fid: 13, typePrefix: 0);

    /// [cards] in an app routing the thread page, pumped until [until] holds (images load for real).
    Future<GoRouter> pump(
      WidgetTester tester,
      List<Widget> cards, {
      bool Function()? until,
      bool dark = false,
      Size size = const Size(400, 900),
      double textScale = 1,
    }) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: ListView(children: cards),
            ),
          ),
          GoRoute(
            path: ScreenPaths.threadV1,
            name: ScreenPaths.threadV1,
            builder: (_, state) => Text('THREAD ${state.uri.queryParameters['tid']}'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          TranslationProvider(
            child: BlocProvider<SettingsBloc>.value(
              value: app.settingsBloc,
              child: MediaQuery(
                data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
                child: MaterialApp.router(
                  theme: dark ? ThemeData.dark() : ThemeData.light(),
                  routerConfig: router,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
                    child: child!,
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));
          if (i > 4 && (until?.call() ?? true)) {
            return;
          }
        }
      });
      return router;
    }

    Finder excerpt() => find.byKey(const ValueKey('thread-preview-excerpt'));
    Finder thumbnail() => find.byKey(const ValueKey('thread-preview-thumbnail'));
    bool loaded() => find.byType(RawImage).evaluate().any((e) => (e.widget as RawImage).image != null);

    testWidgets('the excerpt in two lines under the title, the thumbnail on the right with +N, decoded to its size', (
      tester,
    ) async {
      await pump(tester, [NormalThreadCard(thread('K01'))], until: loaded);
      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(excerpt());
      expect(text.data, 'K01 正文 VIS_K01A_000000 第一段文字，用來看摘要。 第二段 VIS_K01B_000000');
      expect(text.maxLines, 2);
      expect(tester.getTopLeft(excerpt()).dy, greaterThan(tester.getBottomLeft(find.text(thread('K01').title)).dy));
      expect(tester.getCenter(thumbnail()).dx, greaterThan(tester.getCenter(excerpt()).dx));
      expect(tester.getSize(thumbnail()), const Size.square(threadPreviewThumbnailBaseExtent));
      expect(find.text('+3'), findsOneWidget);
      expect(app.images.requested, [thread('K01').preview!.thumbnailOf()!.url], reason: 'the thumbnail the forum made');
      // 400x200 decoded to cover 64 at a device pixel ratio of 1: 128x64, not the whole picture.
      final raw = tester.widget<RawImage>(find.byType(RawImage));
      expect((raw.image!.width, raw.image!.height), (128, 64));
      expect(
        tester.widget<Image>(find.descendant(of: thumbnail(), matching: find.byType(Image))).image,
        isA<CoverResizeImage>(),
      );
    });

    testWidgets('a withheld preview shows nothing, not the reason: the card as without a preview', (tester) async {
      final withheld = thread('K05');
      expect(withheld.preview!.reason, 'password');
      await pump(tester, [NormalThreadCard(withheld)]);
      expect(excerpt(), findsNothing);
      expect(thumbnail(), findsNothing);
      expect(find.textContaining('password'), findsNothing);
      final height = tester.getSize(find.byType(Card)).height;
      await pump(
        tester,
        [
          NormalThreadCard(
            NormalThread.fromApi(_withoutPreview(_fx('preview_v2_forum.json', 'K05')), fid: 13, typePrefix: 0),
          ),
        ],
      );
      expect(tester.getSize(find.byType(Card)).height, height);
      expect(app.images.requested, isEmpty);
    });

    testWidgets('the settings: the excerpt off, the thumbnail never, both off', (tester) async {
      await app.settings.setValue(SettingsKeys.threadCardShowExcerpt, false);
      await pump(tester, [NormalThreadCard(thread('K01'))], until: loaded);
      expect(excerpt(), findsNothing);
      expect(thumbnail(), findsOneWidget);

      await app.settings.setValue(SettingsKeys.threadCardShowExcerpt, true);
      await app.settings.setValue(SettingsKeys.threadCardThumbnailMode, ThreadThumbnailMode.never.index);
      await pump(tester, [NormalThreadCard(thread('K01'))]);
      expect(excerpt(), findsOneWidget);
      expect(thumbnail(), findsNothing);

      await app.settings.setValue(SettingsKeys.threadCardShowExcerpt, false);
      await pump(tester, [NormalThreadCard(thread('K01'))]);
      expect(find.byType(ThreadPreviewSection), findsNothing);
    });

    testWidgets('on Wi-Fi only: none on a metered network, and none asked; always: on any network', (tester) async {
      NetworkUsage.check = () async => false;
      await pump(tester, [NormalThreadCard(thread('K01'))]);
      expect(excerpt(), findsOneWidget);
      expect(thumbnail(), findsNothing);
      expect(app.images.requested, isEmpty);

      NetworkUsage.unmetered.value = true;
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && !loaded(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));
        }
      });
      expect(thumbnail(), findsOneWidget, reason: 'on Wi-Fi now');

      NetworkUsage.reset();
      NetworkUsage.check = () async => false;
      await app.settings.setValue(SettingsKeys.threadCardThumbnailMode, ThreadThumbnailMode.always.index);
      await pump(tester, [NormalThreadCard(thread('K01'))]);
      expect(thumbnail(), findsOneWidget);
    });

    testWidgets('an image of another site: not loaded in the list unless allowed', (tester) async {
      final k16 = thread('K16');
      expect(k16.preview!.images.single.source, 'img');
      await pump(tester, [NormalThreadCard(k16)]);
      expect(excerpt(), findsOneWidget);
      expect(thumbnail(), findsNothing);
      expect(app.images.requested, isEmpty, reason: 'its site never learns who scrolled past');

      await app.settings.setValue(SettingsKeys.threadCardExternalThumbnails, true);
      await pump(tester, [NormalThreadCard(k16)], until: loaded);
      expect(thumbnail(), findsOneWidget);
      expect(app.images.requested, ['https://img.example.com/k16.png']);
    });

    testWidgets('a tap on the thumbnail opens the thread', (tester) async {
      final router = await pump(tester, [NormalThreadCard(thread('K01'))], until: loaded);
      await tester.tap(thumbnail());
      await tester.pumpAndSettle();
      expect(router.state.uri.path, ScreenPaths.threadV1);
      expect(find.text('THREAD ${thread('K01').threadID}'), findsOneWidget);
    });

    testWidgets('a large text on a narrow dark screen: nothing overflows, the excerpt keeps most of the row', (
      tester,
    ) async {
      await pump(
        tester,
        [
          NormalThreadCard(thread('K01')),
          NormalThreadCard(thread('K02')),
          NormalThreadCard(thread('K24', name: 'preview_v2_forum_p2.json')),
        ],
        until: loaded,
        dark: true,
        size: const Size(320, 1600),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      for (final e in thumbnail().evaluate()) {
        final side = tester.getSize(find.byWidget(e.widget)).width;
        expect(side, lessThanOrEqualTo((320 - 32) / 3 + 1));
        expect(side, greaterThan(threadPreviewThumbnailBaseExtent - 1));
      }
      expect(excerpt(), findsNWidgets(3));
      expect(tester.getSize(excerpt().first).width, greaterThan(160));
    });

    testWidgets('the cards of the search, the guide and my threads show it too; the search excerpt never', (
      tester,
    ) async {
      final (latest, _) = latestThreadsFromApi(_json('preview_v6_search.json'), '$baseUrl/search.php?mod=forum');
      final (mine, _) = myThreadsFromApi(_json('preview_v9_mythread.json'), myThreadThreadUrl);
      final (guide, _) = latestThreadsFromApi(_json('preview_v7_guide_newthread.json'), guideUrl('newthread'));
      await pump(tester, [
        SearchedThreadCard(searchResultFromApi(_json('preview_v6_search.json')).data!.first),
        LatestThreadCard(latest.firstWhere((e) => e.title!.endsWith(' K04 000000'))),
        MyThreadCard(mine.first),
        LatestThreadCard(guide.firstWhere((e) => e.preview?.thumbnailOf() != null)),
      ], until: loaded);
      expect(excerpt(), findsNWidgets(4));
      expect(find.textContaining('SEC_'), findsNothing);
      expect(thumbnail(), findsAtLeastNWidgets(2));
    });
  });

  group('E. the settings page', () {
    final app = _App();
    setUp(app.setUp);
    tearDown(app.tearDown);

    testWidgets('the excerpt switch, the thumbnail modes, the example card', (tester) async {
      tester.view
        ..physicalSize = const Size(420, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: BlocProvider<SettingsBloc>.value(
            value: app.settingsBloc,
            child: MaterialApp.router(
              routerConfig: GoRouter(
                routes: [GoRoute(path: '/', builder: (_, _) => const SettingsThreadCardAppearancePage())],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tr = t.settingsPage.appearanceSection.threadCard;
      // The settings are stored for real (the database), then streamed back to the page.
      Future<void> settle() async {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
      }

      // The example card: its excerpt and the picture placeholder with +2.
      expect(find.text(tr.example.message), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      expect(find.text(tr.listPreview.note), findsOneWidget);
      expect(find.text(tr.listPreview.thumbnail.wifiOnly), findsOneWidget, reason: 'the current mode');
      expect(app.settings.currentSettings.threadCardExternalThumbnails, isFalse);
      await tester.ensureVisible(find.byKey(const ValueKey('settings-thread-card-external')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-thread-card-external')));
      await settle();
      expect(app.settings.currentSettings.threadCardExternalThumbnails, isTrue);

      await tester.ensureVisible(find.byKey(const ValueKey('settings-thread-card-excerpt')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-thread-card-excerpt')));
      await settle();
      expect(app.settings.currentSettings.threadCardShowExcerpt, isFalse);
      expect(find.text(tr.example.message), findsNothing);

      await tester.tap(find.byKey(const ValueKey('settings-thread-card-thumbnail')));
      await tester.pumpAndSettle();
      expect(find.text(tr.listPreview.thumbnail.neverDetail), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('thread-thumbnail-mode-never')));
      await settle();
      expect(app.settings.currentSettings.threadCardThumbnailMode, ThreadThumbnailMode.never.index);
      expect(
        tester.widget<SwitchListTile>(find.byKey(const ValueKey('settings-thread-card-external'))).onChanged,
        isNull,
        reason: 'no thumbnail at all',
      );
      expect(find.text(tr.listPreview.thumbnail.never), findsOneWidget);
      expect(find.text('+2'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('F. the network check', () {
    test('asked once while fresh, a failure counts as metered', () async {
      var asked = 0;
      NetworkUsage.check = () async {
        asked++;
        return true;
      };
      NetworkUsage.refreshIfStale();
      NetworkUsage.refreshIfStale();
      await Future<void>.delayed(Duration.zero);
      expect(NetworkUsage.unmetered.value, isTrue);
      NetworkUsage.refreshIfStale();
      await Future<void>.delayed(Duration.zero);
      expect(asked, 1);

      NetworkUsage.reset();
      NetworkUsage.check = () async => throw PlatformException(code: 'x');
      NetworkUsage.refreshIfStale();
      await Future<void>.delayed(Duration.zero);
      expect(NetworkUsage.unmetered.value, isFalse);
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['LISTPREVIEW_SHOTS_DIR'];
    final font = Platform.environment['LISTPREVIEW_SHOTS_FONT'];
    final skip = dir == null || font == null
        ? 'set LISTPREVIEW_SHOTS_DIR and LISTPREVIEW_SHOTS_FONT to write them'
        : null;
    const family = 'ShotSans';
    final app = _App();
    final pictures = <String, Uint8List>{};

    setUpAll(() async {
      if (skip != null) {
        return;
      }
      await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(font!).readAsBytesSync())))).load();
      final root = Platform.environment['FLUTTER_ROOT'];
      final icons = root == null ? null : '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
      if (icons != null && File(icons).existsSync()) {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(File(icons).readAsBytesSync())))).load();
      }
      for (var i = 0; i < 6; i++) {
        pictures['$i'] = await _picture(i.isEven ? 480 : 300, i.isEven ? 300 : 420, seed: i);
      }
    });

    setUp(() async {
      if (skip != null) {
        return;
      }
      await app.setUp(png: (url) => pictures['${url.hashCode.abs() % 6}']!);
      _knowsPreview();
    });
    tearDown(() async {
      if (skip == null) {
        await app.tearDown();
      }
    });

    /// The rows of [name] made readable: forum-like titles and excerpts over the shape of the fixture's rows (a
    /// preview with images, without, withheld), the other rows dropped.
    Map<String, dynamic> readable(String name) {
      final json = _json(name);
      const samples = [
        ('【心得】十月新番第三集觀後感：作畫穩定、劇情節奏剛好', '這一集終於把前兩集埋的伏筆收回來了，配樂也很到位，特別是最後那段長鏡頭，看完直接重播了三次。', 'K01'),
        ('分享幾張這週末去海邊拍的照片', '', 'K23'),
        ('【求助】新手入坑該從哪一部看起？', '最近朋友推坑，想問大家有沒有適合新手、集數不要太長的作品可以推薦，類型不限，謝謝各位。', 'K17'),
        ('【付費】整理好的設定集掃圖合集', '', 'K09'),
        ('【繪圖】練習中的角色設計，歡迎給建議', '畫了一個多禮拜，配色還在調整，背景是參考上次旅行拍的照片。', 'K02'),
        ('【閒聊】大家最近在玩什麼遊戲', '最近在玩一款像素風的經營遊戲，一不小心就玩到天亮。', 'K18'),
        ('【公告】版規更新與活動說明', '', 'K05'),
      ];
      final rows = <Map<String, dynamic>>[];
      for (final (title, text, k) in samples) {
        final row = {
          ...[
            ..._rows(name),
            ..._rows('preview_v2_forum_p2.json'),
          ].firstWhere((e) => (e['subject'] as String).endsWith(' $k 000000')),
        };
        row['subject'] = title;
        final preview = {...row['preview'] as Map<String, dynamic>};
        if (preview['reason'] == null) {
          preview['excerpt'] = text;
        }
        row['preview'] = preview;
        rows.add(row);
      }
      json['threads'] = rows;
      return json;
    }

    ThemeData theme({required bool dark}) => dark
        ? AppTheme.makeDark(_FakeContext(), seedColor: null, fontFamily: family)
        : AppTheme.makeLight(_FakeContext(), seedColor: null, fontFamily: family);

    Future<void> capture(WidgetTester tester, Key key, String name) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
      final bytes = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
      image.dispose();
      Directory(dir!).createSync(recursive: true);
      File('$dir/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
    }

    Future<void> shoot(
      WidgetTester tester,
      String name,
      Widget page, {
      required bool dark,
      double textScale = 1,
    }) async {
      tester.view
        ..physicalSize = const Size(390, 1900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final auth = AuthenticationRepository(user: const UserLoginInfo(username: 'Alice', uid: 35));
      addTearDown(auth.dispose);
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => page)],
      );
      addTearDown(router.dispose);
      final key = UniqueKey();
      await tester.runAsync(() async {
        await tester.pumpWidget(
          TranslationProvider(
            child: MultiRepositoryProvider(
              providers: [
                RepositoryProvider<ForumRepository>(create: (_) => ForumRepository()),
                RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
                RepositoryProvider<AuthenticationRepository>.value(value: auth),
                RepositoryProvider<FragmentsRepository>(create: (_) => FragmentsRepository()),
                RepositoryProvider<NotificationRepository>(create: (_) => NotificationRepository()),
                RepositoryProvider<NotificationInfoRepository>(create: (_) => NotificationInfoRepository()),
              ],
              child: MultiBlocProvider(
                providers: [
                  BlocProvider<SettingsBloc>.value(value: app.settingsBloc),
                  BlocProvider<NotificationStateCubit>(
                    create: (ctx) => NotificationStateCubit(RepositoryProvider.of<NotificationInfoRepository>(ctx)),
                  ),
                  BlocProvider<NotificationBloc>(
                    create: (ctx) => NotificationBloc(
                      notificationRepository: RepositoryProvider.of<NotificationRepository>(ctx),
                      infoRepository: RepositoryProvider.of<NotificationInfoRepository>(ctx),
                      authRepo: auth,
                      storageProvider: getIt.get<StorageProvider>(),
                    ),
                  ),
                ],
                child: RepaintBoundary(
                  key: key,
                  child: MaterialApp.router(
                    debugShowCheckedModeBanner: false,
                    theme: theme(dark: dark),
                    routerConfig: router,
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
                      child: child!,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 60; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await tester.pump(const Duration(milliseconds: 30));
        }
      });
      if (page is SearchPage) {
        await tester.enterText(find.byType(TextFormField).first, '新番');
        await tester.tap(find.byIcon(Icons.search_outlined));
        await tester.runAsync(() async {
          for (var i = 0; i < 60; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            await tester.pump(const Duration(milliseconds: 30));
          }
        });
      }
      expect(tester.takeException(), isNull);
      await capture(tester, key, name);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }

    for (final dark in [false, true]) {
      final mode = dark ? 'dark' : 'light';
      testWidgets('the forum page, $mode', skip: skip != null, (tester) async {
        await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhTw));
        app.forum.answer = (_) =>
            readable('preview_v2_forum.json')
              ..['forum'] = {...?_json('preview_v2_forum.json')['forum'] as Map<String, dynamic>?, 'name': '動漫討論'};
        await shoot(
          tester,
          'forum_$mode',
          const ForumPage(fid: '13', title: '動漫討論'),
          dark: dark,
        );
      });
      testWidgets('the guide list, $mode', skip: skip != null, (tester) async {
        await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhTw));
        app.forum.answer = (_) => readable('preview_v7_guide_newthread.json');
        await shoot(
          tester,
          'guide_$mode',
          LatestThreadPage(url: guideUrl('newthread'), title: '最新發表'),
          dark: dark,
        );
      });
      testWidgets('the search results, $mode', skip: skip != null, (tester) async {
        await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhTw));
        app.forum.answer = (_) => readable('preview_v6_search.json');
        await shoot(tester, 'search_$mode', const SearchPage(), dark: dark);
      });
      testWidgets('the forum page, large text, $mode', skip: skip != null, (tester) async {
        await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhTw));
        app.forum.answer = (_) => readable('preview_v2_forum.json');
        await shoot(
          tester,
          'forum_large_text_$mode',
          const ForumPage(fid: '13', title: '動漫討論'),
          dark: dark,
          textScale: 1.5,
        );
      });
    }
  });
}

final class _FakeContext extends Fake implements BuildContext {}
