/// The image browsing rework (2026-10-23 audit, big update 3; `feat/image-gallery`), one group each:
///
/// 1. a tap on a picture of a floor opens the gallery of the floor's pictures at it (its quotes, a fold once opened;
///    no smiley, no icon), with both renderers; a picture in a link to a page opens the link; a long press opens the
///    image sheet (save, share, copy the url, open in the browser);
/// 2. the gallery: black, the system bars hidden, swiped, "2 / 3", zoomed by a double tap (the pages stay then), closed
///    by a drag down (it follows and comes back when let go early), a long picture from its top; the route takes the
///    pictures and the one tapped, the route of one picture still works;
/// 3. the progress of a download (the chunks of the provider, the Android client's reports) and "tap to retry", in the
///    floor and in the gallery;
/// 4. the place a picture keeps before it is there: its size decoded in this run (memory only), the attachment's of the
///    app API, the `<img>`'s, otherwise 4:3 (not 64 px), the same once loaded;
/// 5. the data saver: always / Wi-Fi only / tap to load (a cached picture shows anyway); the floor shows the thumbnail
///    of an attachment, the gallery the attachment;
/// 6. a picture is shared as a file, never as its url.
///
/// Screenshots: with `GALLERY_SHOTS_DIR` (output directory) and `GALLERY_SHOTS_FONT` (a font file with CJK glyphs) set,
/// the group `screenshots` writes the gallery, a picture loading, one that failed and one waiting for a tap, light and
/// dark. Skipped otherwise.
library;

// Html of the forum is split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shimmer/shimmer.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/image/models/gallery_image.dart';
import 'package:tsdm_client/features/image/utils/image_actions.dart';
import 'package:tsdm_client/features/image/utils/image_sizes.dart';
import 'package:tsdm_client/features/image/view/image_gallery_page.dart';
import 'package:tsdm_client/features/image/widgets/post_image.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/widgets/select_post_image_auto_load_dialog.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode_view.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/smilies.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/post_image_auto_load.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider_android.dart'
    show KotlinHttpClient, KotlinHttpClientAdapter;
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/utils/image_file_name.dart';
import 'package:tsdm_client/utils/network_usage.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';

// ---------------------------------------------------------------------------------------------------------------------
// Pictures and a forum serving them.

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

List<int> _uint32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

final _pngs = <(int, int), Uint8List>{};

/// A PNG of [width] by [height] pixels, of one color.
Uint8List _png(int width, int height) => _pngs.putIfAbsent((width, height), () {
  final row = Uint8List(1 + width * 3);
  for (var x = 0; x < width; x++) {
    row
      ..[1 + x * 3] = 0x33
      ..[2 + x * 3] = 0x66
      ..[3 + x * 3] = 0xCC;
  }
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < height; y++) {
    raw.add(row);
  }
  final out = BytesBuilder()..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final head = ascii.encode(type);
    out
      ..add(_uint32(data.length))
      ..add(head)
      ..add(data)
      ..add(_uint32(_crc32([...head, ...data])));
  }

  chunk('IHDR', [..._uint32(width), ..._uint32(height), 8, 2, 0, 0, 0]);
  chunk('IDAT', ZLibEncoder().convert(raw.toBytes()));
  chunk('IEND', const []);
  return out.toBytes();
});

/// The forum (and image hosts): the pictures it has, the requests it saw.
final class _ImageServer implements HttpClientAdapter {
  final images = <String, Uint8List>{};
  final requests = <String>[];

  /// Urls that fail as if offline.
  final failing = <String>{};

  /// Answers fed by the test, a piece at a time.
  final streams = <String, StreamController<Uint8List>>{};

  void serve(String url, int width, int height) => images[url] = _png(width, height);

  int requestsOf(String url) => requests.where((e) => e == url).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // The client asks the forum for its desktop pages (`mobile=no`): the url the app used is without it.
    final uri = options.uri;
    final query = Map.of(uri.queryParameters)..remove('mobile');
    final url = (query.isEmpty ? uri.replace(query: '') : uri.replace(queryParameters: query)).toString().replaceFirst(
      RegExp(r'\?$'),
      '',
    );
    requests.add(url);
    if (failing.contains(url)) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    final data = images[url];
    if (data == null) {
      return ResponseBody.fromString('', 404);
    }
    return ResponseBody(
      streams[url]?.stream ?? Stream.value(data),
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
        Headers.contentLengthHeader: ['${data.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A page pushed or popped: its transition, then what loads.
Future<void> _navigated(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await _settle(tester, rounds: 10);
}

/// Let the real work (requests, files, the database, decoding) and the frames go on until [until] holds and no image
/// waits any more (a shimmer would keep the frames going).
Future<void> _settle(WidgetTester tester, {bool Function()? until, int rounds = 60}) async {
  bool done() => (until == null || until()) && find.byType(Shimmer).evaluate().isEmpty;
  await tester.runAsync(() async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
      await tester.pump(const Duration(milliseconds: 15));
      if (i > 1 && done()) {
        return;
      }
    }
  });
  await tester.pump();
}

const _a = 'https://img.example/a.png';
const _b = 'https://img.example/b.png';
const _bFull = 'https://img.example/b-full.png';
const _c = 'https://img.example/c.png';
const _q = 'https://img.example/q.png';
const _s = 'https://img.example/s.png';
const _icon = 'https://img.example/icon.png';
const _smiley = '$baseUrl/static/image/smiley/default/smile.gif';
const _fileType = '$baseUrl/static/image/filetype/image.gif';
const _thread = '$baseUrl/forum.php?mod=viewthread&tid=1264975';

/// A floor of each kind of picture: a smiley, a quoted picture, a picture, a file type icon, a small icon, a picture in
/// a fold, a picture in a link to its full size, a picture in a link to a thread.
const _floorHtml =
    '<div class="t_fsz"><div class="t_f" id="postmessage_1">'
    '文字 <img src="static/image/smiley/default/smile.gif" smilieid="1" border="0" alt="" /><br />'
    '<div class="quote"><blockquote>引用 <img src="$_q" /></blockquote></div>'
    '<img src="$_a" /><br />'
    '<img src="static/image/filetype/image.gif" border="0" class="vm" alt="" />'
    '<img src="$_icon" width="16" height="16" /><br />'
    '<div class="spoiler"><div class="spoilerheader"><input type="button" class="spoilerbutton" value="標題" /></div>'
    '<div class="spoilerbody" style="display: none;"><img src="$_s" /></div></div>'
    '<a href="$_bFull" target="_blank"><img src="$_b" /></a><br />'
    '<a href="$_thread" target="_blank"><img src="$_c" /></a>'
    '</div></div>';

void main() {
  late Directory tmp;
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late _ImageServer server;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
    tmp = Directory.systemTemp.createTempSync('tsdm_image_gallery_');
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
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    server = _ImageServer();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = server)),
      );
    await settings.init();
    ImageSizes.clear();
    NetworkUsage.reset();
    debugCanShareImageFiles = true;
  });

  tearDown(() async {
    debugCanShareImageFiles = null;
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  // -------------------------------------------------------------------------------------------------------------------
  // A floor under its scope, with the routes a tap goes to.

  late FloorImages floor;
  ImageGalleryArgs? opened;
  Map<String, String>? openedThread;

  Future<void> pumpFloor(
    WidgetTester tester,
    Widget content, {
    PostImageAutoLoad autoLoad = PostImageAutoLoad.always,
    List<PostAttachment> attachments = const [],
    bool Function()? until,
  }) async {
    // Tall enough for a floor of pictures, 400 wide.
    tester.view
      ..devicePixelRatio = 3
      ..physicalSize = const Size(1200, 9000);
    addTearDown(tester.view.reset);
    floor = FloorImages(attachments);
    opened = null;
    openedThread = null;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: SingleChildScrollView(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  child: PostImageScope(images: floor, autoLoad: autoLoad, child: content),
                ),
              ),
            ),
          ),
        ),
        GoRoute(
          path: ScreenPaths.imageDetail,
          name: ScreenPaths.imageDetail,
          builder: (_, state) {
            opened = state.extra as ImageGalleryArgs?;
            return const Scaffold(body: Text('the gallery'));
          },
        ),
        GoRoute(
          path: ScreenPaths.threadV1,
          name: ScreenPaths.threadV1,
          builder: (_, state) {
            openedThread = state.uri.queryParameters;
            return const Scaffold(body: Text('the thread'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
      ),
    );
    await _settle(tester, until: until);
  }

  Finder pictureOf(String url) => find.byWidgetPredicate((w) => w is PostImage && w.image.floorUrl == url);

  /// The picture shown (its frame decoded) for [url] in the floor.
  bool shown(String url) => find.descendant(of: pictureOf(url), matching: find.byType(RawImage)).evaluate().any((e) {
    final widget = e.widget as RawImage;
    return widget.image != null;
  });

  Future<void> back(WidgetTester tester) async {
    GoRouter.of(tester.element(find.byType(Scaffold).last)).pop();
    // The page transition first: the page below takes no tap while it runs.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await _settle(tester, rounds: 20);
  }

  group('1. a tap opens the gallery of the floor', () {
    setUp(() {
      for (final url in [_a, _b, _c, _q, _s]) {
        server.serve(url, 40 * 5, 30 * 5);
      }
      server
        ..serve(_icon, 16, 16)
        ..serve(_smiley, 20, 20)
        ..serve(_fileType, 16, 16);
    });

    testWidgets('its pictures in the order of the floor, quotes in, no smiley nor icon, a fold only once opened', (
      tester,
    ) async {
      await pumpFloor(tester, const MunchedHtml(_floorHtml), until: () => shown(_a) && shown(_c));
      expect(find.byType(PostImage), findsNWidgets(4), reason: 'the picture in the closed fold is not built');
      expect(
        pictureOf(_icon),
        findsNothing,
        reason: 'a 16 x 16 icon, a smiley and a file type icon are not pictures',
      );

      await tester.tap(pictureOf(_a));
      await _navigated(tester);
      expect(find.text('the gallery'), findsOneWidget, reason: 'no image sheet first');
      expect(opened!.images.map((e) => e.url), [_q, _a, _b, _c]);
      expect(opened!.initialIndex, 1);
      await back(tester);

      // Tapped where it is drawn (the center the finder derives for a widget in a line of text is off).
      await tester.tapAt(
        tester.getRect(find.ancestor(of: find.text('標題'), matching: find.byType(OutlinedButton))).center,
      );
      await _settle(tester, until: () => shown(_s));
      await tester.tap(pictureOf(_b));
      await _navigated(tester);
      expect(opened!.images.map((e) => e.url), [_q, _a, _s, _b, _c], reason: 'the opened fold is in its place');
      expect(opened!.initialIndex, 3, reason: 'a picture in a link to its full size opens the gallery');
      expect(opened!.images[3].linkUrl, _bFull);
    });

    testWidgets('a picture in a script link or an anchor is not in a link: a tap opens the gallery', (tester) async {
      await pumpFloor(
        tester,
        const MunchedHtml(
          '<a href="javascript:void(0)"><img src="$_a" /></a><br /><a href="#top"><img src="$_b" /></a>',
        ),
        until: () => shown(_a) && shown(_b),
      );
      expect(tester.widget<PostImage>(pictureOf(_a)).image.linkUrl, isNull);
      expect(tester.widget<PostImage>(pictureOf(_b)).image.linkUrl, isNull);
      await tester.tap(pictureOf(_b));
      await _navigated(tester);
      expect(opened!.images.map((e) => e.url), [_a, _b]);
    });

    testWidgets('a picture in a link to a page opens the link; a smiley opens the image sheet', (tester) async {
      await pumpFloor(tester, const MunchedHtml(_floorHtml), until: () => shown(_c));
      await tester.tap(pictureOf(_c));
      await _navigated(tester);
      expect(openedThread, containsPair('tid', '1264975'));
      expect(opened, isNull);
      await back(tester);

      await tester.tapAt(
        tester.getRect(find.byWidgetPredicate((w) => w is NetworkIndicatorImage && w.src == _smiley)).center,
      );
      await _settle(tester, until: () => find.text(t.imageBottomSheet.title).evaluate().isNotEmpty);
      expect(find.text(t.imageBottomSheet.title), findsOneWidget);
      expect(opened, isNull);
    });

    testWidgets('a long press opens the image sheet: save, share, copy the url, open in the browser', (tester) async {
      await pumpFloor(tester, const MunchedHtml(_floorHtml), until: () => shown(_a));
      await tester.longPress(pictureOf(_a));
      await _settle(tester, until: () => find.text(t.imageBottomSheet.title).evaluate().isNotEmpty);
      final tr = t.imageBottomSheet;
      expect(find.text(tr.title), findsOneWidget);
      for (final item in [tr.checkDetail, tr.saveImage, tr.shareImage, tr.copyImageUrl, tr.openInBrowser]) {
        expect(find.text(item), findsOneWidget, reason: item);
      }
      expect(opened, isNull);

      tester.widget<ListTile>(find.ancestor(of: find.text(tr.checkDetail), matching: find.byType(ListTile))).onTap!();
      await _settle(tester, until: () => opened != null);
      expect(opened!.images.map((e) => e.url), [_q, _a, _b, _c], reason: '"check details" opens the gallery too');
    });

    testWidgets('the app renderer: pictures, quoted ones and attachments in the gallery, smilies out', (tester) async {
      const attachment = PostAttachment(
        aid: 562,
        filename: 'cover.png',
        description: '',
        isImage: true,
        url: '$baseUrl/data/attachment/forum/cover.png',
        thumb: '$baseUrl/data/attachment/forum/cover.png.thumb.jpg',
        download: '$baseUrl/forum.php?mod=attachment&aid=562',
        width: 1920,
        height: 1080,
        filesize: 39494,
        price: 0,
        readPerm: 0,
        downloads: 3,
        locked: false,
        inPost: true,
      );
      server.serve(attachment.thumb, 192, 108);
      const nodes = <BbNode>[
        BbImage(_a),
        BbText(' '),
        BbSmiley(Smiley(id: 1, code: ':)', url: _smiley, type: 'default')),
        BbQuote([BbImage(_q)]),
        BbAttachment(attachment),
      ];
      await pumpFloor(tester, const PostBbcodeView(nodes), until: () => shown(attachment.thumb));
      expect(server.requestsOf(attachment.thumb), 1, reason: 'the floor shows the thumbnail');
      expect(server.requestsOf(attachment.url), 0);
      await tester.tap(pictureOf(attachment.thumb));
      await _navigated(tester);
      expect(opened!.images.map((e) => e.url), [_a, _q, attachment.url], reason: 'the gallery the attachment itself');
      expect(opened!.initialIndex, 2);
    });

    testWidgets('the parts of a floor drawn from its bbcode keep their order, whichever is built first', (
      tester,
    ) async {
      await pumpFloor(
        tester,
        const Column(
          children: [
            // The html after the message (the attachments listed below it) built before the message here.
            PostImagePart(part: 2, child: MunchedHtml('<img src="$_c" />')),
            PostImagePart(part: 1, child: PostBbcodeView([BbImage(_a), BbImage(_b)])),
          ],
        ),
        until: () => shown(_c) && shown(_b),
      );
      await tester.tap(pictureOf(_c));
      await _navigated(tester);
      expect(opened!.images.map((e) => e.url), [_a, _b, _c]);
      expect(opened!.initialIndex, 2);
    });

    testWidgets('a floor card: its attachment and pictures from the forum html (schema 14), its own gallery', (
      tester,
    ) async {
      final json = jsonDecode(File('test/data/tsdmapp/thread_v14_attachments.json').readAsStringSync());
      final post = threadPageFromApi(json as Map<String, dynamic>, 1).postList.first.copyWith(
        author: const User(name: 'Alice', uid: '31', url: '$baseUrl/home.php?mod=space&uid=31'),
        userBriefProfile: null,
        postMedals: null,
        badge: null,
        secondBadge: null,
        signature: null,
        pokemon: null,
        checkin: null,
      );
      final attachment = post.attachments.firstWhere((e) => e.aid == 562);
      server
        ..serve('https://example.com/a.png', 300, 200)
        ..serve(attachment.url, 800, 450);
      for (final icon in [
        'smiley/default/smile.gif',
        'smiley/default/sad.gif',
        'filetype/image.gif',
        'filetype/zip.gif',
      ]) {
        server.serve('$baseUrl/static/image/$icon', 16, 16);
      }
      final bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      tester.view
        ..devicePixelRatio = 3
        ..physicalSize = const Size(1200, 9000);
      addTearDown(tester.view.reset);
      opened = null;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(body: SingleChildScrollView(child: PostCard(post))),
          ),
          GoRoute(
            path: ScreenPaths.imageDetail,
            name: ScreenPaths.imageDetail,
            builder: (_, state) {
              opened = state.extra as ImageGalleryArgs?;
              return const Scaffold(body: Text('the gallery'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        BlocProvider<SettingsBloc>.value(
          value: bloc,
          child: TranslationProvider(child: MaterialApp.router(routerConfig: router)),
        ),
      );
      Finder attachmentPicture() => find.byWidgetPredicate((w) => w is PostImage && w.image.url == attachment.url);
      await _settle(tester, until: () => attachmentPicture().evaluate().isNotEmpty);
      final picture = tester.widget<PostImage>(attachmentPicture());
      expect(picture.image.width, 1920, reason: 'the size of the attachment the app API gives');
      expect(picture.image.height, 1080);
      expect(picture.image.fileSize, 39494);
      await tester.tap(attachmentPicture());
      await _navigated(tester);
      expect(opened!.images.map((e) => e.url), ['https://example.com/a.png', attachment.url]);
      expect(opened!.initialIndex, 1);
      // The card's timers (the relative times) go with it.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      // Not closed here: its handler follows the settings until they are disposed in the tear down.
      unawaited(bloc.close());
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  // The gallery.

  group('2. the gallery', () {
    late List<MethodCall> systemCalls;

    setUp(() {
      systemCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          systemCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
    });

    /// The system bars asked for: a mode, or the bars shown (`manual`).
    List<String> systemUiModes() => [
      for (final call in systemCalls)
        if (call.method == 'SystemChrome.setEnabledSystemUIMode')
          '${call.arguments}'
        else if (call.method == 'SystemChrome.setEnabledSystemUIOverlays')
          'shown: ${call.arguments}',
    ];

    /// The home page with a button opening [images] at [index], or the route of [path] at once.
    Future<GoRouter> pumpGallery(WidgetTester tester, List<GalleryImage> images, {int index = 0, String? path}) async {
      final router = GoRouter(
        initialLocation: path ?? '/',
        observers: [popupRouteObserver, routeObserver],
        routes: [
          GoRoute(
            path: '/over',
            builder: (_, _) => const Scaffold(body: Text('a page over the gallery')),
          ),
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => openImageGallery(context, images, index),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          ImageGalleryRoute(),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
        ),
      );
      await tester.pump();
      if (path == null) {
        await tester.tap(find.text('open'));
      }
      await _settle(tester, until: () => find.byType(InteractiveViewer).evaluate().isNotEmpty);
      return router;
    }

    String counter(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey('image-gallery-counter'))).data!;

    TransformationController zoomOf(WidgetTester tester) =>
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!;

    testWidgets('black, the system bars hidden, swiped, "2 / 3"; closing gives the bars back', (tester) async {
      for (final url in [_a, _b, _c]) {
        server.serve(url, 300, 200);
      }
      await pumpGallery(tester, const [GalleryImage(_a), GalleryImage(_b), GalleryImage(_c)], index: 1);
      expect(counter(tester), '2 / 3');
      expect(systemUiModes(), ['SystemUiMode.immersiveSticky']);
      final material = tester.widget<Material>(
        find.ancestor(of: find.byType(PageView), matching: find.byType(Material)).first,
      );
      expect(material.color, Colors.black);

      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await _settle(
        tester,
        until: () =>
            counter(tester) == '3 / 3' && find.byKey(const ValueKey('image-gallery-loading')).evaluate().isEmpty,
      );
      expect(counter(tester), '3 / 3');
      expect(server.requestsOf(_c), 1, reason: 'each picture loads when shown');

      await tester.tap(find.byKey(const ValueKey('image-gallery-close')));
      await tester.pumpAndSettle();
      expect(find.byType(ImageGalleryPage), findsNothing);
      expect(
        systemUiModes().last,
        'shown: [SystemUiOverlay.top, SystemUiOverlay.bottom]',
        reason: 'both bars shown again, as the app has them',
      );
    });

    testWidgets('a double tap zooms in (the pages stay), another one back; a tap hides the bar', (tester) async {
      for (final url in [_a, _b]) {
        server.serve(url, 300, 200);
      }
      await pumpGallery(tester, const [GalleryImage(_a), GalleryImage(_b)]);
      final page = find.byKey(const ValueKey('image-gallery-page-0'));
      await tester.tap(page);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(page);
      await tester.pumpAndSettle();
      expect(zoomOf(tester).value.getMaxScaleOnAxis(), greaterThan(2));

      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(counter(tester), '1 / 2', reason: 'zoomed in, a swipe moves the picture, not the pages');

      await tester.tap(page);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(page);
      await tester.pumpAndSettle();
      expect(zoomOf(tester).value.getMaxScaleOnAxis(), closeTo(1, 0.01));
      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await _settle(
        tester,
        until: () =>
            counter(tester) == '2 / 2' && find.byKey(const ValueKey('image-gallery-loading')).evaluate().isEmpty,
      );
      expect(counter(tester), '2 / 2');

      // The page settles first: a page still moving takes no tap.
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('image-gallery-page-1')));
      // A single tap waits to be sure it is not a double one.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      final bar = tester.widget<AnimatedOpacity>(
        find.ancestor(of: find.byKey(const ValueKey('image-gallery-counter')), matching: find.byType(AnimatedOpacity)),
      );
      expect(bar.opacity, 0, reason: 'a tap hides the bar on top');
    });

    testWidgets('a drag down follows the finger: let go early it comes back, far enough it closes', (tester) async {
      server.serve(_a, 300, 200);
      await pumpGallery(tester, const [GalleryImage(_a)]);
      final page = find.byKey(const ValueKey('image-gallery-page-0'));

      final gesture = await tester.startGesture(tester.getCenter(page));
      await gesture.moveBy(const Offset(0, 30), timeStamp: const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 30), timeStamp: const Duration(milliseconds: 200));
      await tester.pump();
      final translate = find.byKey(const ValueKey('image-gallery-drag'));
      expect(tester.widget<Transform>(translate).transform.getTranslation().y, greaterThan(40));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byType(ImageGalleryPage), findsOneWidget, reason: 'let go early');
      expect(tester.widget<Transform>(translate).transform.getTranslation().y, closeTo(0, 0.01));

      await tester.timedDrag(page, const Offset(0, 300), const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byType(ImageGalleryPage), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('a long picture fills the width from its top and scrolls; dragged down from its top it closes', (
      tester,
    ) async {
      server.serve(_a, 100, 1000);
      await pumpGallery(tester, const [GalleryImage(_a)]);
      final viewport = tester.getSize(find.byType(InteractiveViewer));
      final picture = find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(Image));
      expect(tester.getSize(picture).width, closeTo(viewport.width, 0.01));
      expect(tester.getTopLeft(picture).dy, closeTo(tester.getTopLeft(find.byType(InteractiveViewer)).dy, 0.01));

      await tester.timedDrag(find.byType(InteractiveViewer), const Offset(0, -400), const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(zoomOf(tester).value.getTranslation().y, lessThan(-200), reason: 'scrolled down the picture');

      await tester.timedDrag(find.byType(InteractiveViewer), const Offset(0, 150), const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byType(ImageGalleryPage), findsOneWidget, reason: 'not at its top: it scrolls back up');

      zoomOf(tester).value = Matrix4.identity();
      await tester.pump();
      await tester.timedDrag(find.byType(InteractiveViewer), const Offset(0, 300), const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byType(ImageGalleryPage), findsNothing);
    });

    testWidgets('a page opened over the gallery has the system bars; back to the gallery they go again', (
      tester,
    ) async {
      server.serve(_a, 300, 200);
      final router = await pumpGallery(tester, const [GalleryImage(_a)]);
      expect(systemUiModes(), ['SystemUiMode.immersiveSticky']);
      unawaited(router.push('/over'));
      await tester.pumpAndSettle();
      expect(systemUiModes().last, startsWith('shown:'));
      router.pop();
      await tester.pumpAndSettle();
      expect(systemUiModes().last, 'SystemUiMode.immersiveSticky');
    });

    testWidgets('the image sheet over the gallery keeps the system bars hidden', (tester) async {
      server.serve(_a, 300, 200);
      await pumpGallery(tester, const [GalleryImage(_a)]);
      await tester.tap(find.byKey(const ValueKey('image-gallery-more')));
      await _settle(tester, until: () => find.text(t.imageBottomSheet.title).evaluate().isNotEmpty);
      expect(find.text(t.imageBottomSheet.title), findsOneWidget);
      expect(systemUiModes(), ['SystemUiMode.immersiveSticky'], reason: 'no flash of the bars');
    });

    testWidgets('the route of one picture (its url in the path, no pictures given) shows it alone', (tester) async {
      server.serve(_a, 300, 200);
      await pumpGallery(tester, const [], path: '/imageDetail/${Uri.encodeComponent(_a)}');
      expect(counter(tester), '1 / 1');
      expect(server.requestsOf(_a), 1);
    });

    testWidgets('the bar saves and shares the picture shown', (tester) async {
      server.serve(_a, 300, 200);
      final shared = <ShareParams>[];
      shareImageFiles = (params) async {
        shared.add(params);
        return const ShareResult('ok', ShareResultStatus.success);
      };
      addTearDown(() => shareImageFiles = SharePlus.instance.share);
      await pumpGallery(tester, const [GalleryImage(_a)]);
      expect(find.byKey(const ValueKey('image-gallery-save')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('image-gallery-share')));
      await _settle(tester, until: () => shared.isNotEmpty);
      expect(shared.single.files!.single.path, endsWith('/a.png'));
      expect(shared.single.text, isNull, reason: 'the file, not the url');
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  // Progress and retry.

  group('3. the progress of a download, and "tap to retry"', () {
    testWidgets('the provider tells the chunks of the download, with the size of the image', (tester) async {
      server.serve(_a, 300, 200);
      final data = server.images[_a]!;
      final feed = StreamController<Uint8List>();
      server.streams[_a] = feed;
      final events = <ImageChunkEvent>[];
      await tester.runAsync(() async {
        final done = Completer<void>();
        final listener = ImageStreamListener(
          (info, _) {
            info.dispose();
            done.complete();
          },
          onChunk: events.add,
          onError: (e, _) => done.completeError(e),
        );
        final stream = const CachedImageProvider(_a).resolve(ImageConfiguration.empty)..addListener(listener);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final half = data.length ~/ 2;
        feed.add(data.sublist(0, half));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        feed.add(data.sublist(half));
        await feed.close();
        await done.future.timeout(const Duration(seconds: 5));
        stream.removeListener(listener);
      });
      expect(events.map((e) => e.cumulativeBytesLoaded), [data.length ~/ 2, data.length]);
      expect(events.map((e) => e.expectedTotalBytes).toSet(), {data.length});
    });

    test(
      'the Android client forwards how much arrived while Kotlin downloads; a plain request asks for nothing',
      () async {
        const channel = MethodChannel('kzs.th000.tsdm_client/httpChannel');
        final calls = <MethodCall>[];
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final id = (call.arguments as Map)['progressId'];
          if (id != null) {
            for (final received in [40, 100]) {
              await messenger.handlePlatformMessage(
                channel.name,
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall('progress', {'id': id, 'received': received, 'total': 100}),
                ),
                (_) {},
              );
            }
          }
          return {
            'statusCode': 200,
            'headers': <String, List<String>>{
              'content-type': ['image/png'],
            },
            'body': Uint8List(100),
            'isRedirect': false,
          };
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final dio = Dio()..httpClientAdapter = KotlinHttpClientAdapter(KotlinHttpClient(android: true));
        final progress = <(int, int)>[];
        await dio.get<dynamic>(
          'https://img.example/a.png',
          options: Options(responseType: ResponseType.bytes),
          onReceiveProgress: (received, total) => progress.add((received, total)),
        );
        expect(progress.take(2), [(40, 100), (100, 100)], reason: 'told by Kotlin while it downloads');
        expect((calls.single.arguments as Map)['progressId'], isA<int>());

        calls.clear();
        await dio.get<dynamic>('https://img.example/b.png', options: Options(responseType: ResponseType.bytes));
        expect((calls.single.arguments as Map).containsKey('progressId'), isFalse);
      },
    );

    testWidgets('a picture only read from the cache and not there leaves the image cache, nothing logged', (
      tester,
    ) async {
      const provider = CachedImageProvider(_a, cacheOnly: true);
      await tester.runAsync(() async {
        final failed = Completer<void>();
        provider
            .resolve(ImageConfiguration.empty)
            .addListener(
              ImageStreamListener((info, _) => info.dispose(), onError: (_, _) => failed.complete()),
            );
        await failed.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(PaintingBinding.instance.imageCache.containsKey(provider), isFalse);
      expect(server.requests, isEmpty);
    });

    test('the Kotlin side reads a body in pieces only when its progress is asked for', () {
      final source = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/MainActivity.kt').readAsStringSync();
      expect(
        source,
        contains('if (progressId == null) resp.body.bytes() else readReportingProgress(resp, progressId)'),
      );
      expect(source, contains('runOnUiThread { httpChannel?.invokeMethod(HTTP_PROGRESS, args) }'));
    });

    testWidgets('a picture of a floor shows how much of it arrived, then itself', (tester) async {
      server.serve(_a, 300, 200);
      final data = server.images[_a]!;
      final feed = StreamController<Uint8List>();
      server.streams[_a] = feed;
      await pumpFloor(tester, const MunchedHtml('<img src="$_a" />'), until: () => server.requests.isNotEmpty);
      await tester.runAsync(() async {
        feed.add(data.sublist(0, data.length ~/ 2));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      // The chunk is told on the next frame.
      await tester.pump();
      expect(find.byKey(const ValueKey('post-image-progress')), findsOneWidget);
      expect(find.text('${(data.length ~/ 2 * 100 / data.length).floor()}%'), findsOneWidget);
      await tester.runAsync(() async {
        feed.add(data.sublist(data.length ~/ 2));
        await feed.close();
      });
      await _settle(tester, until: () => shown(_a));
      expect(shown(_a), isTrue);
      expect(find.byKey(const ValueKey('post-image-progress')), findsNothing);
    });

    testWidgets('a picture that failed says "failed, tap to retry"; tapped, it loads again', (tester) async {
      server
        ..serve(_a, 300, 200)
        ..failing.add(_a);
      await pumpFloor(
        tester,
        const MunchedHtml('<img src="$_a" />'),
        until: () => find.byKey(const ValueKey('post-image-retry')).evaluate().isNotEmpty,
      );
      expect(find.text(t.imageGallery.failedTapToRetry), findsOneWidget);
      final asked = server.requestsOf(_a);

      server.failing.clear();
      await tester.tap(find.byKey(const ValueKey('post-image-retry')));
      await _settle(tester, until: () => shown(_a));
      expect(shown(_a), isTrue);
      expect(server.requestsOf(_a), greaterThan(asked));
      expect(opened, isNull, reason: 'the tap retried, it did not open the gallery');
    });

    testWidgets('the gallery shows the progress, and a picture that failed is tapped to load again', (tester) async {
      server
        ..serve(_a, 300, 200)
        ..failing.add(_a);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Builder(
              builder: (context) => TextButton(
                onPressed: () async => openImageGallery(context, const [GalleryImage(_a)], 0),
                child: const Text('open'),
              ),
            ),
          ),
          ImageGalleryRoute(),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
      await tester.tap(find.text('open'));
      await _settle(tester, until: () => find.byKey(const ValueKey('image-gallery-retry')).evaluate().isNotEmpty);
      expect(find.text(t.imageGallery.failedTapToRetry), findsOneWidget);

      server.failing.clear();
      final feed = StreamController<Uint8List>();
      server.streams[_a] = feed;
      final data = server.images[_a]!;
      await tester.tap(find.byKey(const ValueKey('image-gallery-retry')));
      await _settle(tester, rounds: 5);
      await tester.runAsync(() async {
        feed.add(data.sublist(0, data.length ~/ 4));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('image-gallery-loading')), findsOneWidget);
      expect(find.text('${(data.length ~/ 4 * 100 / data.length).floor()}%'), findsOneWidget);
      await tester.runAsync(() async {
        feed.add(data.sublist(data.length ~/ 4));
        await feed.close();
      });
      await _settle(tester, until: () => find.byType(InteractiveViewer).evaluate().isNotEmpty);
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  // The place kept.

  group('4. the place a picture keeps before it is there', () {
    test('best known first: decoded in this run, the attachment, the <img>, else 4:3 as wide as there is room', () {
      const image = GalleryImage(_a, width: 1920, height: 1080);
      expect(
        reservedImageBoxOf(image, known: const KnownImageSize(aspectRatio: 2, width: 300)),
        (aspectRatio: 2.0, width: 300.0),
      );
      expect(reservedImageBoxOf(image, declaredWidth: 600, declaredHeight: 600), (
        aspectRatio: 1920 / 1080,
        width: 1920.0,
      ));
      expect(
        reservedImageBoxOf(const GalleryImage(_a, floorUrl: _b, width: 1920, height: 1080)),
        (aspectRatio: 1920 / 1080, width: null),
        reason: 'a thumbnail has the aspect ratio of the attachment, not its width',
      );
      expect(reservedImageBoxOf(const GalleryImage(_a), declaredWidth: 600, declaredHeight: 300), (
        aspectRatio: 2.0,
        width: 600.0,
      ));
      expect(reservedImageBoxOf(const GalleryImage(_a), declaredWidth: 600), (
        aspectRatio: defaultImageAspectRatio,
        width: 600.0,
      ));
      expect(reservedImageBoxOf(const GalleryImage(_a)), (aspectRatio: 4 / 3, width: null));
    });

    test('the sizes decoded are kept in memory, the width only when decoded whole', () {
      ImageSizes.record(_a, const Size(1200, 600), downscaled: true);
      expect(ImageSizes.of(_a), const KnownImageSize(aspectRatio: 2));
      ImageSizes.record(_b, const Size(300, 600), downscaled: false);
      expect(ImageSizes.of(_b), const KnownImageSize(aspectRatio: 0.5, width: 300));
      ImageSizes.record(_b, const Size(150, 300), downscaled: true);
      expect(ImageSizes.of(_b)!.width, 300, reason: 'decoded whole once: its width stays known');
      for (var i = 0; i < ImageSizes.capacity + 10; i++) {
        ImageSizes.record('$_c?$i', const Size(10, 10), downscaled: false);
      }
      expect(ImageSizes.length, ImageSizes.capacity);
      expect(ImageSizes.of(_a), isNull, reason: 'the least recently decoded forgotten first');
    });

    test('asked how wide it is (a table), the box says its width, or 320 when unknown', () {
      final known = RenderImageReservedBox(2, 200);
      final unknown = RenderImageReservedBox(4 / 3, null);
      expect(known.getMaxIntrinsicWidth(double.infinity), 200);
      expect(known.getMinIntrinsicHeight(100), 50);
      expect(unknown.getMaxIntrinsicWidth(double.infinity), ImageReservedBox.fallbackWidth);
      expect(unknown.getMaxIntrinsicHeight(double.infinity), ImageReservedBox.fallbackWidth * 3 / 4);
    });

    Size placeholderOf(WidgetTester tester, String url) =>
        tester.getSize(find.descendant(of: pictureOf(url), matching: find.byType(ImageReservedBox)));

    testWidgets('waiting, it takes the size it will have: the <img>, the attachment, 4:3, the size decoded', (
      tester,
    ) async {
      for (final url in [_a, _b, _c, _q]) {
        server
          ..serve(url, 800, 400)
          ..streams[url] = StreamController<Uint8List>();
      }
      ImageSizes.record(_q, const Size(300, 600), downscaled: false);
      await pumpFloor(
        tester,
        const MunchedHtml(
          '<img src="$_a" width="600" height="300" /><br /><img aid="562" src="$_b" /><br /><img src="$_c" /><br />'
          '<img src="$_q" />',
        ),
        attachments: const [
          PostAttachment(
            aid: 562,
            filename: 'b.png',
            description: '',
            isImage: true,
            url: _b,
            thumb: '',
            download: _b,
            width: 1920,
            height: 1080,
            filesize: 1,
            price: 0,
            readPerm: 0,
            downloads: 0,
            locked: false,
            inPost: true,
          ),
        ],
        until: () => server.requests.length >= 4,
      );
      expect(placeholderOf(tester, _a), const Size(400, 200), reason: 'the <img> 600 x 300, in 400');
      expect(placeholderOf(tester, _b).height, closeTo(400 * 1080 / 1920, 0.01), reason: 'the attachment 1920 x 1080');
      expect(placeholderOf(tester, _c), const Size(400, 300), reason: '4:3 as wide as there is room, not 64 px');
      expect(placeholderOf(tester, _q), const Size(300, 600), reason: 'decoded before in this run');
      // The pictures come; nothing is left loading once the test is over.
      await tester.runAsync(() async {
        for (final MapEntry(:key, value: feed) in server.streams.entries) {
          feed.add(server.images[key]!);
          await feed.close();
        }
      });
      await _settle(tester, until: () => [_a, _b, _c, _q].every(shown));
    });

    testWidgets('loaded, it is as large as its placeholder was: the floor below does not move', (tester) async {
      server
        ..serve(_a, 800, 400)
        ..streams[_a] = StreamController<Uint8List>();
      await pumpFloor(
        tester,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MunchedHtml('<img src="$_a" width="600" height="300" />'),
            Text('below', key: ValueKey('below')),
          ],
        ),
        until: () => server.requests.isNotEmpty,
      );
      final before = tester.getTopLeft(find.byKey(const ValueKey('below'))).dy;
      await tester.runAsync(() async {
        server.streams[_a]!.add(server.images[_a]!);
        await server.streams[_a]!.close();
      });
      await _settle(tester, until: () => shown(_a));
      expect(shown(_a), isTrue);
      expect(tester.getTopLeft(find.byKey(const ValueKey('below'))).dy, closeTo(before, 0.01));
      expect(ImageSizes.of(_a)?.aspectRatio, 2, reason: 'remembered for the next time it loads');
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  // The data saver.

  group('5. the data saver', () {
    const attachment = PostAttachment(
      aid: 562,
      filename: 'cover.png',
      description: '',
      isImage: true,
      url: '$baseUrl/data/attachment/forum/cover.png',
      thumb: '',
      download: '$baseUrl/forum.php?mod=attachment&aid=562',
      width: 1920,
      height: 1080,
      filesize: 39494,
      price: 0,
      readPerm: 0,
      downloads: 3,
      locked: false,
      inPost: true,
    );
    const html =
        '<img id="aimg_562" aid="562" src="static/image/common/none.gif" zoomfile="data/attachment/forum/cover.png" '
        'file="data/attachment/forum/cover.png" class="zoom" width="600" inpost="1" />';

    test('always by default, stored by its index; a value it does not know is always', () async {
      expect(SettingsKeys.postImageAutoLoad.defaultValue, PostImageAutoLoad.always.index);
      expect(settings.currentSettings.postImageAutoLoad, 0);
      await settings.setValue(SettingsKeys.postImageAutoLoad, PostImageAutoLoad.never.index);
      final again = SettingsRepository(storage);
      await again.init();
      addTearDown(again.dispose);
      expect(PostImageAutoLoad.fromIndex(again.currentSettings.postImageAutoLoad), PostImageAutoLoad.never);
      expect(PostImageAutoLoad.fromIndex(9), PostImageAutoLoad.always);
    });

    testWidgets('the settings offer always, Wi-Fi only and tap to load', (tester) async {
      PostImageAutoLoad? picked;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => picked = await showSelectPostImageAutoLoad(context, PostImageAutoLoad.always),
                  child: const Text('pick'),
                ),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      final tr = t.settingsPage.behaviorSection.postImageAutoLoad;
      expect(find.text(tr.always), findsOneWidget);
      expect(find.text(tr.wifiOnly), findsOneWidget);
      tester.widget<ListTile>(find.byKey(const ValueKey('post-image-auto-load-never'))).onTap!();
      await tester.pumpAndSettle();
      expect(picked, PostImageAutoLoad.never);
    });

    testWidgets('tap to load: a placeholder with the size of the attachment, nothing fetched until tapped', (
      tester,
    ) async {
      server.serve(attachment.url, 800, 450);
      await pumpFloor(tester, const MunchedHtml(html), autoLoad: PostImageAutoLoad.never, attachments: [attachment]);
      expect(find.byKey(const ValueKey('post-image-tap-to-load')), findsOneWidget);
      expect(find.text(t.imageGallery.tapToLoad), findsOneWidget);
      expect(find.text('38.57 KB · 1920 × 1080'), findsOneWidget);
      expect(server.requests, isEmpty);
      // The image sheet shows what is cached only: nothing is downloaded for its preview.
      await tester.longPress(find.byKey(const ValueKey('post-image-tap-to-load')));
      await _settle(tester, until: () => find.text(t.imageBottomSheet.title).evaluate().isNotEmpty);
      expect(find.text(t.imageBottomSheet.title), findsOneWidget);
      expect(server.requests, isEmpty);
      Navigator.of(tester.element(find.text(t.imageBottomSheet.title))).pop();
      await _settle(tester, rounds: 20);

      await tester.tap(find.byKey(const ValueKey('post-image-tap-to-load')));
      await _settle(tester, until: () => shown(attachment.url));
      expect(shown(attachment.url), isTrue);
      expect(server.requestsOf(attachment.url), 1);
      expect(opened, isNull, reason: 'the tap loaded it; the next one opens the gallery');
    });

    testWidgets('tap to load, its size not known: a low bar, not the room of a picture', (tester) async {
      server.serve(_a, 800, 450);
      await pumpFloor(tester, const MunchedHtml('<img src="$_a" />'), autoLoad: PostImageAutoLoad.never);
      final box = tester.getSize(find.descendant(of: pictureOf(_a), matching: find.byType(ImageReservedBox)));
      expect(box, const Size(400, unknownPlaceholderHeight));
    });

    testWidgets('tap to load: a picture cached already shows at once, it costs nothing', (tester) async {
      server.serve(attachment.url, 800, 450);
      await tester.runAsync(
        () => getIt.get<ImageCacheProvider>().getOrMakeCache(ImageCacheGeneralRequest(attachment.url)),
      );
      expect(server.requestsOf(attachment.url), 1);
      await pumpFloor(
        tester,
        const MunchedHtml(html),
        autoLoad: PostImageAutoLoad.never,
        attachments: [attachment],
        until: () => shown(attachment.url),
      );
      expect(shown(attachment.url), isTrue);
      expect(find.byKey(const ValueKey('post-image-tap-to-load')), findsNothing);
      expect(server.requestsOf(attachment.url), 1, reason: 'read from the cache');
    });

    testWidgets('Wi-Fi only: loads on a network that is not metered, waits for a tap on a metered one', (tester) async {
      server.serve(_a, 300, 200);
      NetworkUsage.check = () async => false;
      await pumpFloor(tester, const MunchedHtml('<img src="$_a" />'), autoLoad: PostImageAutoLoad.wifiOnly);
      expect(find.byKey(const ValueKey('post-image-tap-to-load')), findsOneWidget);
      expect(server.requests, isEmpty);

      NetworkUsage.reset();
      NetworkUsage.check = () async => true;
      await pumpFloor(
        tester,
        const MunchedHtml('<img src="$_a" />'),
        autoLoad: PostImageAutoLoad.wifiOnly,
        until: () => shown(_a),
      );
      expect(shown(_a), isTrue);
    });

    testWidgets('the floor shows the thumbnail of an attachment (the app API or the page), the gallery itself', (
      tester,
    ) async {
      const thumb = '$baseUrl/data/attachment/forum/cover.png.thumb.jpg';
      server
        ..serve(thumb, 192, 108)
        ..serve('$baseUrl/data/attachment/forum/other.jpg.thumb.jpg', 100, 100);
      await pumpFloor(
        tester,
        const MunchedHtml(
          '$html<br /><img aid="9" zoomfile="data/attachment/forum/other.jpg" '
          'file="data/attachment/forum/other.jpg.thumb.jpg" />',
        ),
        attachments: [attachment.copyWith(thumb: thumb)],
        until: () => shown(thumb) && shown('$baseUrl/data/attachment/forum/other.jpg.thumb.jpg'),
      );
      expect(server.requestsOf(thumb), 1);
      expect(server.requestsOf(attachment.url), 0, reason: 'the attachment itself is not fetched for the floor');
      await tester.tap(pictureOf(thumb));
      await _navigated(tester);
      expect(opened!.images.map((e) => e.url), [
        attachment.url,
        '$baseUrl/data/attachment/forum/other.jpg',
      ]);
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  // Sharing.

  group('6. a picture is shared as a file', () {
    testWidgets('its bytes, named with the extension of its type, never its url', (tester) async {
      const url = '$baseUrl/forum.php?mod=attachment&aid=abc';
      server.serve(url, 30, 20);
      final shared = <ShareParams>[];
      shareImageFiles = (params) async {
        shared.add(params);
        return const ShareResult('ok', ShareResultStatus.success);
      };
      addTearDown(() => shareImageFiles = SharePlus.instance.share);
      await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: SizedBox())));
      final context = tester.element(find.byType(SizedBox));
      final ok = await tester.runAsync(() => shareImageOf(context, url));
      expect(ok, isTrue);
      final params = shared.single;
      expect(params.text, isNull);
      expect(params.uri, isNull);
      final file = params.files!.single;
      expect(await tester.runAsync(file.readAsBytes), server.images[url]);
      expect(file.mimeType, 'image/png');
      expect(file.path, endsWith('.png'));
      expect(imageMimeTypeOf('x.JPG'), 'image/jpeg');
    });

    testWidgets('a url naming a path writes nothing out of the folder of shared images', (tester) async {
      const url = 'https://evil.example/a/..%2F..%2Fapp_flutter%2Ftsdm.sqlite';
      server.serve(url, 30, 20);
      final shared = <ShareParams>[];
      shareImageFiles = (params) async {
        shared.add(params);
        return const ShareResult('ok', ShareResultStatus.success);
      };
      addTearDown(() => shareImageFiles = SharePlus.instance.share);
      await tester.pumpWidget(TranslationProvider(child: const MaterialApp(home: SizedBox())));
      final context = tester.element(find.byType(SizedBox));
      expect(await tester.runAsync(() => shareImageOf(context, url)), isTrue);
      final file = File(shared.single.files!.single.path);
      expect(file.parent.path, '${tmp.path}/tmp/shared_images');
      expect(file.path.split('/').last, 'tsdm.png');
      expect(File('${tmp.path}/app_flutter/tsdm.sqlite').existsSync(), isFalse);
    });

    test('a name taken from the url is a plain file name: no path, no reserved character, not too long', () {
      final png = Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]);
      final unknown = Uint8List.fromList(const [1, 2, 3, 4]);
      final now = DateTime.fromMicrosecondsSinceEpoch(42);
      String name(String url, [Uint8List? data]) => imageFileNameOf(url, data ?? png, now: now);
      expect(name('https://e.example/a/..%2F..%2Fapp_flutter%2Ftsdm.sqlite'), 'tsdm.png');
      expect(name('https://e.example/a/..%5C..%5CStartup%5Cevil.png'), 'evil.png');
      expect(name('https://e.example/a/..'), 'tsdm_client_image_42.png');
      expect(name('https://e.example/a/%2E%2E'), 'tsdm_client_image_42.png');
      expect(name('https://e.example/a/x%3A%2A%3F%22%3C%3E%7C.png'), 'x.png');
      expect(name('https://e.example/a/b%07%0Ac%7F.png'), 'bc.png');
      expect(name('https://e.example/a/.hidden.png'), 'hidden.png');
      expect(name('https://e.example/a/${'x' * 300}.png'), '${'x' * imageFileNameMaxLength}.png');
      expect(name('https://e.example/a/run.exe', unknown), 'run.jpg', reason: "an unknown type is never the url's");
      expect(name('https://e.example/a/CON.png'), '_CON.png', reason: 'a name Windows keeps for a device');
      expect(name('https://e.example/a/lpt9.png'), '_lpt9.png');
      expect(name('https://e.example/a/nul.tar.png'), '_nul.tar.png');
      expect(name('https://e.example/a/console.png'), 'console.png');
      expect(name('https://e.example/a/a%E2%80%AEgnp.exe.png'), 'agnp.exe.png', reason: 'no mark turning the text');
      expect(name('https://e.example/a/.%20x.png'), 'x.png');
      final emoji = name('https://e.example/a/${Uri.encodeComponent('😀' * 100)}.png');
      expect(emoji, '${'😀' * imageFileNameMaxLength}.png', reason: 'cut by characters, not code units');
      for (final url in [
        'https://e.example/a/..%2F..%2Fx.png',
        'https://e.example/%2F%2Fetc%2Fpasswd',
        'https://e.example/C%3A%5CWindows%5Cx.png',
      ]) {
        final n = name(url);
        expect(n, isNot(contains('/')), reason: url);
        expect(n, isNot(contains(r'\')), reason: url);
        expect(n.startsWith('.'), isFalse, reason: url);
      }
    });
  });

  // -------------------------------------------------------------------------------------------------------------------
  // Screenshots.

  group('screenshots', () {
    final dir = Platform.environment['GALLERY_SHOTS_DIR'];
    final font = Platform.environment['GALLERY_SHOTS_FONT'];
    final skip = dir == null || font == null ? 'set GALLERY_SHOTS_DIR and GALLERY_SHOTS_FONT to write them' : null;
    const family = 'ShotSans';
    final pictures = <String, Uint8List>{};
    const boundaryKey = ValueKey('shot');

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
      for (final (i, (w, h)) in [(960, 640), (720, 960), (960, 540), (640, 640)].indexed) {
        pictures['https://img.example/shot$i.png'] = await _scene(w, h, seed: i);
      }
    });

    ThemeData theme({required bool dark}) => dark
        ? AppTheme.makeDark(_FakeContext(), seedColor: null, fontFamily: family)
        : AppTheme.makeLight(_FakeContext(), seedColor: null, fontFamily: family);

    Future<void> capture(WidgetTester tester, String name) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
      final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
      final bytes = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
      image.dispose();
      Directory(dir!).createSync(recursive: true);
      File('$dir/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
    }

    Future<GoRouter> pumpApp(WidgetTester tester, Widget home, {required bool dark, bool tall = false}) async {
      tester.view
        ..physicalSize = Size(390, tall ? 1250 : 844)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => home),
          ImageGalleryRoute(),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: TranslationProvider(
            child: MaterialApp.router(
              routerConfig: router,
              theme: theme(dark: dark),
              darkTheme: theme(dark: dark),
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              debugShowCheckedModeBanner: false,
            ),
          ),
        ),
      );
      return router;
    }

    /// A floor of the thread page: its line of text, and [image] in the state its scope says.
    Widget floorOf(
      String title,
      String text,
      String image, {
      PostImageAutoLoad autoLoad = PostImageAutoLoad.always,
      PostAttachment? attachment,
    }) => Builder(
      builder: (context) => Card(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              PostImageScope(
                images: FloorImages([?attachment]),
                autoLoad: autoLoad,
                child: MunchedHtml(
                  '$text<br /><img ${attachment == null ? '' : 'aid="${attachment.aid}" '}src="$image" '
                  'width="960" height="640" />',
                ),
              ),
            ],
          ),
        ),
      ),
    );

    for (final dark in [false, true]) {
      final mode = dark ? 'dark' : 'light';

      testWidgets('the floor: loading with its progress, failed, waiting for a tap ($mode)', (tester) async {
        const loading = 'https://img.example/shot0.png';
        const failed = 'https://img.example/shot1.png';
        const waiting = 'https://img.example/shot2.png';
        server.images.addAll(pictures);
        server.failing.add(failed);
        final feed = StreamController<Uint8List>();
        server.streams[loading] = feed;
        await pumpApp(
          tester,
          Scaffold(
            appBar: AppBar(title: const Text('攝影分享')),
            body: ListView(
              children: [
                floorOf('1 樓 · 載入中', '週末去海邊拍的，第一張是日落。', loading),
                floorOf('2 樓 · 載入失敗', '這張是港口，網路斷了一下。', failed),
                floorOf(
                  '3 樓 · 不自動載入',
                  '省流量模式：點擊才載入。',
                  waiting,
                  autoLoad: PostImageAutoLoad.never,
                  attachment: const PostAttachment(
                    aid: 7,
                    filename: 'harbor.jpg',
                    description: '',
                    isImage: true,
                    url: waiting,
                    thumb: '',
                    download: waiting,
                    width: 1920,
                    height: 1080,
                    filesize: 1288490,
                    price: 0,
                    readPerm: 0,
                    downloads: 0,
                    locked: false,
                    inPost: true,
                  ),
                ),
              ],
            ),
          ),
          dark: dark,
          tall: true,
        );
        await _settle(
          tester,
          until: () => find.byKey(const ValueKey('post-image-retry')).evaluate().isNotEmpty,
          rounds: 120,
        );
        final data = pictures[loading]!;
        await tester.runAsync(() async {
          feed.add(data.sublist(0, data.length * 45 ~/ 100));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('post-image-progress')), findsOneWidget);
        expect(find.byKey(const ValueKey('post-image-tap-to-load')), findsOneWidget);
        await capture(tester, 'floor_states_$mode');
        await tester.runAsync(() async {
          feed.add(data.sublist(data.length * 45 ~/ 100));
          await feed.close();
        });
        await _settle(tester);
      }, skip: skip != null);

      testWidgets('the gallery: a picture, its loading, a failed one ($mode)', (tester) async {
        server.images.addAll(pictures);
        const images = [
          GalleryImage('https://img.example/shot0.png'),
          GalleryImage('https://img.example/shot1.png'),
          GalleryImage('https://img.example/shot2.png'),
          GalleryImage('https://img.example/shot3.png'),
        ];
        await pumpApp(
          tester,
          Scaffold(
            appBar: AppBar(title: const Text('攝影分享')),
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () async => openImageGallery(context, images, 1),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          dark: dark,
        );
        await tester.tap(find.text('open'));
        await _settle(tester, until: () => find.byType(InteractiveViewer).evaluate().isNotEmpty, rounds: 120);
        await tester.pumpAndSettle();
        await capture(tester, 'gallery_$mode');

        // The next one loading, with its progress.
        final feed = StreamController<Uint8List>();
        server.streams['https://img.example/shot2.png'] = feed;
        await tester.drag(find.byType(PageView), const Offset(-300, 0));
        await _settle(tester, until: () => server.requestsOf('https://img.example/shot2.png') > 0);
        final data = pictures['https://img.example/shot2.png']!;
        await tester.runAsync(() async {
          feed.add(data.sublist(0, data.length * 62 ~/ 100));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
        await tester
            .pumpAndSettle(
              const Duration(milliseconds: 100),
              EnginePhase.sendSemanticsUpdate,
              const Duration(seconds: 2),
            )
            .catchError((_) => 0);
        await capture(tester, 'gallery_loading_$mode');
        await tester.runAsync(() async {
          feed.add(data.sublist(data.length * 62 ~/ 100));
          await feed.close();
        });
        await _settle(tester);

        // The last one failed.
        server.failing.add('https://img.example/shot3.png');
        await tester.drag(find.byType(PageView), const Offset(-300, 0));
        await _settle(
          tester,
          until: () => find.byKey(const ValueKey('image-gallery-retry')).evaluate().isNotEmpty,
          rounds: 120,
        );
        await tester.pump(const Duration(milliseconds: 500));
        await capture(tester, 'gallery_failed_$mode');
      }, skip: skip != null);
    }
  });
}

final class _FakeContext extends Fake implements BuildContext {}

/// A picture to look at: a sky, a sun and a hill, of [width] by [height] pixels.
Future<Uint8List> _scene(int width, int height, {int seed = 0}) async {
  final recorder = ui.PictureRecorder();
  final hues = [200.0, 28.0, 140.0, 280.0];
  final hue = hues[seed % hues.length];
  final rect = Offset.zero & Size(width.toDouble(), height.toDouble());
  Canvas(recorder)
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
