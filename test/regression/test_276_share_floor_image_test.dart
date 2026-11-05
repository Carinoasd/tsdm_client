import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/image/utils/image_actions.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/view/share_floor_image_page.dart';
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
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// A floor shared as a picture (its menu's "share as image"):
///
/// 1. the floor's menu offers it, and the page shows the thread title, the author with the floor and the time, the
///    content and the forum's name with the link of the floor (its `findpost` link by thread and post id, without the
///    `fromuid` of the reader);
/// 2. the picture captured is 420 logical pixels wide at 2 pixels each, whatever the screen;
/// 3. save and share wait until the pictures of the content are decoded, then share hands a PNG file of that width to
///    the share sheet;
/// 4. a floor taller than the limit is cut there, with a fading mark, and the picture ends there within the texture
///    limit; a picture under the cut is not waited for; a picture that grows the content past the limit once decoded is
///    marked too;
/// 5. the surface follows the theme in use.
///
/// Synthetic floors and pictures only: no network, nothing is sent.
Translations get tr => LocaleSettings.instance.currentTranslations;

String _data(String name) => File('test/data/$name').readAsStringSync();

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

const _a = 'https://img.example/a.png';
const _tall = 'https://img.example/tall.png';

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

/// A PNG of [width] by [height] pixels, of one color.
Uint8List _pngOf(int width, int height) {
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
}

/// The size a PNG declares in its header.
({int width, int height}) _pngSize(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return (width: data.getUint32(16), height: data.getUint32(20));
}

/// Answers a PNG for every picture, held back while the test says so; nothing leaves the test.
final class _ImageServer implements HttpClientAdapter {
  /// Pictures whose answer waits for the test.
  final held = <String, Completer<void>>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    final gate = held[url];
    if (gate != null) {
      await gate.future;
    }
    if (!url.endsWith('.png')) {
      return ResponseBody.fromString('', 404);
    }
    return ResponseBody.fromBytes(
      url == _tall ? _pngOf(200, 1500) : _png,
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Let the real work (requests, files, decoding) and the frames go on until [until] holds.
Future<void> _settle(WidgetTester tester, {bool Function()? until, int rounds = 40}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      if (i > 1 && until != null && until()) {
        return;
      }
    }
  });
  await tester.pump();
}

/// A page pushed: its transition, then what loads.
Future<void> _navigated(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await _settle(tester, rounds: 10);
}

const _shareLink = '$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=1264966&pid=77983102&fromuid=42';
const _cleanLink = '$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=1264966&pid=77983102';

/// The floor of the fixture as a post with [body].
Post _post(String body) {
  final doc = parseHtmlDocument(_data('locked_purchase_x5.html'));
  final original = doc.querySelector('div#post_77983102')!;
  final floor = original.clone(true) as uh.Element;
  original.parent!.append(floor);
  final post = Post.fromPostNode(floor, 1)!;
  return post.copyWith(
    data: body,
    locked: const [],
    signature: null,
    pokemon: null,
    checkin: null,
    shareLink: _shareLink,
  );
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late _ImageServer server;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
    tmp = Directory.systemTemp.createTempSync('tsdm_share_floor_image_');
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
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = server)),
      );
    await settings.init();
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    debugCanShareImageFiles = true;
  });

  tearDown(() async {
    debugCanShareImageFiles = null;
    shareImageFiles = SharePlus.instance.share;
    await settingsBloc.close();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  /// The app around a floor: the thread's floor at `/`, the share page on its route; [dark] in the dark theme.
  Future<void> pumpApp(WidgetTester tester, Widget home, {bool dark = false}) async {
    tester.view
      ..physicalSize = const Size(1200, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => home),
        GoRoute(
          path: ScreenPaths.shareFloorImage,
          name: ScreenPaths.shareFloorImage,
          builder: (_, state) => ShareFloorImagePage(state.extra! as ShareFloorImageArgs),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      BlocProvider<SettingsBloc>.value(
        value: settingsBloc,
        child: TranslationProvider(
          child: MaterialApp.router(
            routerConfig: router,
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          ),
        ),
      ),
    );
    await _settle(tester, rounds: 6);
  }

  /// The share page of [post] alone.
  Future<void> pumpPage(WidgetTester tester, Post post, {String? title, bool dark = false}) => pumpApp(
    tester,
    ShareFloorImagePage(ShareFloorImageArgs(post: post, threadTitle: title, link: _cleanLink)),
    dark: dark,
  );

  Finder saveButton() => find.byKey(const ValueKey('share-floor-image-save'));
  Finder shareButton() => find.byKey(const ValueKey('share-floor-image-share'));

  bool enabled(WidgetTester tester, Finder button) => tester.widget<ButtonStyleButton>(button).onPressed != null;

  Future<void> untilReady(WidgetTester tester) async {
    await _settle(tester, until: () => enabled(tester, saveButton()), rounds: 100);
    expect(enabled(tester, saveButton()), isTrue, reason: 'the pictures are there, the buttons act');
  }

  /// The picture of the page as the buttons capture it.
  Future<Uint8List> capture(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.ancestor(of: find.byKey(shareFloorImageCanvasKey), matching: find.byType(RepaintBoundary)).first,
    );
    late Uint8List bytes;
    await tester.runAsync(() async => bytes = await renderShareFloorImage(boundary));
    return bytes;
  }

  group('1. the menu and the page', () {
    testWidgets('the floor menu offers it and the page shows author, content and the link without fromuid', (
      tester,
    ) async {
      final post = _post('<p>floor body text</p>');
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: PostCard(post))));
      await tester.tap(find.byIcon(Icons.adaptive.more));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(tr.postCard.shareAsImage), findsOneWidget, reason: 'in the menu, with "copy share link"');
      expect(find.text(tr.postCard.share), findsOneWidget);

      await tester.tap(find.text(tr.postCard.shareAsImage));
      await _navigated(tester);
      expect(find.byType(ShareFloorImagePage), findsOneWidget);
      expect(find.text(tr.shareFloorImage.title), findsOneWidget);
      final canvas = find.byKey(shareFloorImageCanvasKey);
      expect(find.descendant(of: canvas, matching: find.text(post.author.name)), findsOneWidget);
      expect(find.descendant(of: canvas, matching: find.text('#${post.postFloor}')), findsOneWidget);
      expect(find.descendant(of: canvas, matching: find.textContaining('floor body text')), findsOneWidget);
      expect(
        find.descendant(of: canvas, matching: find.textContaining(_cleanLink)),
        findsOneWidget,
        reason: 'the link of the floor by thread and post id',
      );
      expect(find.descendant(of: canvas, matching: find.textContaining('fromuid')), findsNothing);
      expect(find.descendant(of: canvas, matching: find.textContaining(tr.shareFloorImage.siteName)), findsOneWidget);
      expect(find.text(tr.shareFloorImage.save), findsOneWidget);
      expect(find.text(tr.shareFloorImage.share), findsOneWidget);
    });

    testWidgets('the thread title heads the picture when the floor is on its thread page', (tester) async {
      await pumpPage(tester, _post('<p>body</p>'), title: 'The thread title');
      expect(
        find.descendant(of: find.byKey(shareFloorImageCanvasKey), matching: find.text('The thread title')),
        findsOneWidget,
      );
    });

    test('the link: findpost by thread and post id, else the share link without fromuid', () {
      expect(
        shareFloorImageLink(pid: '77983102', tid: '1264966', shareLink: _shareLink),
        '$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=1264966&pid=77983102',
      );
      expect(shareFloorImageLink(pid: '77983102', shareLink: _shareLink), _cleanLink);
      expect(shareFloorImageLink(pid: '77983102', shareLink: _cleanLink), _cleanLink);
      expect(shareFloorImageLink(pid: '77983102'), isNull);
    });
  });

  group('2. the picture', () {
    testWidgets('captured 420 logical pixels wide at 2 pixels each', (tester) async {
      await pumpPage(tester, _post('<p>a short floor</p>'));
      await untilReady(tester);
      final size = _pngSize(await capture(tester));
      expect(size.width, (shareFloorImageWidth * shareFloorImagePixelRatio).round());
      expect(size.height, greaterThan(100));
      expect(size.height, lessThan(1200), reason: 'a short floor: header, one line, footer');
    });

    testWidgets('the same width on a screen narrower than the picture', (tester) async {
      await pumpPage(tester, _post('<p>a short floor</p>'));
      tester.view.physicalSize = const Size(360, 800);
      await _settle(tester, rounds: 6);
      await untilReady(tester);
      expect(_pngSize(await capture(tester)).width, 840);
      expect(tester.takeException(), isNull);
    });
  });

  group('3. the buttons wait for the pictures', () {
    testWidgets('disabled while a picture loads, enabled once it is decoded; share hands the PNG over', (
      tester,
    ) async {
      server.held[_a] = Completer<void>();
      final shared = <ShareParams>[];
      shareImageFiles = (params) async {
        shared.add(params);
        return const ShareResult('', ShareResultStatus.success);
      };
      await pumpPage(tester, _post('<p>text</p><img src="$_a" />'));
      await _settle(tester, rounds: 15);
      expect(enabled(tester, saveButton()), isFalse, reason: 'the picture is still loading');
      expect(enabled(tester, shareButton()), isFalse);
      expect(
        find.descendant(of: saveButton(), matching: find.byType(CircularProgressIndicator)),
        findsOneWidget,
        reason: 'the button says it waits',
      );

      server.held[_a]!.complete();
      await untilReady(tester);
      expect(enabled(tester, shareButton()), isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(shareButton());
      await _settle(tester, until: () => shared.isNotEmpty, rounds: 100);
      expect(shared, hasLength(1));
      final file = shared.single.files!.single;
      expect(file.mimeType, 'image/png');
      expect(file.name, 'tsdm-floor-77983102.png');
      expect(_pngSize(File(file.path).readAsBytesSync()).width, 840);
    });

    testWidgets('a picture under the cut of a long floor is not waited for', (tester) async {
      server.held[_a] = Completer<void>();
      final long = List.generate(600, (i) => '<p>line $i of a very long floor</p>').join();
      await pumpPage(tester, _post('$long<img src="$_a" />'));
      await untilReady(tester);
      expect(find.byKey(shareFloorImageTruncatedKey), findsOneWidget);
      expect(server.held[_a]!.isCompleted, isFalse, reason: 'the picture never came, the buttons act regardless');
    });

    testWidgets('a floor without pictures is ready at once', (tester) async {
      await pumpPage(tester, _post('<p>text only</p>'));
      await untilReady(tester);
    });
  });

  group('4. a long floor is cut', () {
    testWidgets(
      'the content stops at the limit with a fading mark; the picture is that tall, within the texture limit',
      (
        tester,
      ) async {
        final long = List.generate(600, (i) => '<p>line $i of a very long floor</p>').join();
        await pumpPage(tester, _post(long));
        await untilReady(tester);
        expect(find.byKey(shareFloorImageTruncatedKey), findsOneWidget);
        final size = _pngSize(await capture(tester));
        expect(size.width, 840, reason: 'header and footer fit the limit at the full ratio');
        expect(size.height, greaterThanOrEqualTo((shareFloorImageMaxHeight * shareFloorImagePixelRatio).round()));
        expect(size.height, lessThanOrEqualTo(shareFloorImageMaxPixels.round()), reason: 'a texture of 8192 holds it');
      },
    );

    test('the ratio is lowered when the canvas would pass the texture limit', () {
      expect(shareFloorImagePixelRatioFor(const Size(420, 1000)), shareFloorImagePixelRatio);
      expect(shareFloorImagePixelRatioFor(const Size(420, 4000)), shareFloorImagePixelRatio);
      expect(shareFloorImagePixelRatioFor(const Size(420, 5000)) * 5000, shareFloorImageMaxPixels);
    });

    testWidgets('a picture without a declared size that decodes tall pushes the content past the limit: marked', (
      tester,
    ) async {
      // Short of the limit as text alone, past it once the picture is at its height.
      final text = List.generate(130, (i) => '<p>line $i</p>').join();
      await pumpPage(tester, _post(text));
      await untilReady(tester);
      expect(find.byKey(shareFloorImageTruncatedKey), findsNothing, reason: 'the text alone fits');

      await pumpPage(tester, _post('<img src="$_tall" />$text'));
      await untilReady(tester);
      await _settle(tester, until: () => find.byKey(shareFloorImageTruncatedKey).evaluate().isNotEmpty, rounds: 30);
      expect(find.byKey(shareFloorImageTruncatedKey), findsOneWidget, reason: 'measured again after the picture');
    });

    testWidgets('a short floor shows no mark', (tester) async {
      await pumpPage(tester, _post('<p>short</p>'));
      await untilReady(tester);
      expect(find.byKey(shareFloorImageTruncatedKey), findsNothing);
    });
  });

  group('5. the theme', () {
    Color surfaceOf(WidgetTester tester) => tester
        .widget<ColoredBox>(
          find.descendant(of: find.byKey(shareFloorImageCanvasKey), matching: find.byType(ColoredBox)).first,
        )
        .color;

    testWidgets('the surface is the theme in use, light or dark', (tester) async {
      await pumpPage(tester, _post('<p>text</p>'));
      final light = surfaceOf(tester);
      expect(light, ThemeData.light().colorScheme.surface);
      await pumpPage(tester, _post('<p>text</p>'), dark: true);
      // The theme of the app animates to the dark one.
      await tester.pump(const Duration(seconds: 1));
      final dark = surfaceOf(tester);
      expect(dark, ThemeData.dark().colorScheme.surface);
      expect(dark, isNot(light));
    });
  });
}
