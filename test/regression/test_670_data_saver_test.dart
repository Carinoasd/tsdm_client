/// The data saver (`feat/data-saver`): a setting of its own in "others", off / on a metered network / always.
///
/// 1. stored by its index, off by default, a value it does not know is off; the dialog offers the three; not synced;
/// 2. a page decides once: on a metered network it holds the pictures back, and keeps doing so when the network is
///    free again; a page opened then loads; a page opened on Wi-Fi starts holding back once the network counts;
/// 3. the pictures of a floor: a placeholder of the size the forum tells, a tap loads that one, a cached one shows;
///    back on Wi-Fi nothing loads by itself; the image sheet of a placeholder offers "load all in this floor", which
///    loads those shown and those built later (a fold opened, a table opened full screen);
/// 4. the thumbnails of the thread lists: none while held back.
library;

// Html of the forum is split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shimmer/shimmer.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/image/utils/image_sizes.dart';
import 'package:tsdm_client/features/image/widgets/post_image.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/widgets/select_data_saver_mode_dialog.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
import 'package:tsdm_client/features/thread_preview/widgets/thread_preview_section.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/data_saver_mode.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/post_image_auto_load.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/network_usage.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

// ---------------------------------------------------------------------------------------------------------------------
// Pictures and a forum serving them (as in test_258).

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
const _s = 'https://img.example/s.png';

/// Two pictures, and one in a fold.
const _floorHtml =
    '<div class="t_fsz"><div class="t_f" id="postmessage_1">'
    '<img src="$_a" /><br />'
    '<img src="$_b" /><br />'
    '<div class="spoiler"><div class="spoilerheader"><input type="button" class="spoilerbutton" value="標題" /></div>'
    '<div class="spoilerbody" style="display: none;"><img src="$_s" /></div></div>'
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
    tmp = Directory.systemTemp.createTempSync('tsdm_data_saver_');
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
    for (final url in [_a, _b, _s]) {
      server.serve(url, 200, 150);
    }
  });

  tearDown(() async {
    NetworkUsage.reset();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  /// A page of the app with [child], and a page pushed over it (`/again`, the same [child] again).
  Future<GoRouter> pumpPages(WidgetTester tester, Widget Function() child, {bool Function()? until}) async {
    tester.view
      ..devicePixelRatio = 3
      ..physicalSize = const Size(1200, 6000);
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: SingleChildScrollView(child: child())),
        ),
        GoRoute(
          path: '/again',
          builder: (_, _) => Scaffold(body: SingleChildScrollView(child: child())),
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
    return router;
  }

  late FloorImages floor;

  /// A floor of [html] under its scope, 400 wide.
  Widget floorOf(String html, DataSaverMode mode, {PostImageAutoLoad autoLoad = PostImageAutoLoad.always}) {
    floor = FloorImages();
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 400,
        child: PostImageScope(images: floor, autoLoad: autoLoad, dataSaver: mode, child: MunchedHtml(html)),
      ),
    );
  }

  Finder pictureOf(String url) => find.byWidgetPredicate((w) => w is PostImage && w.image.floorUrl == url);

  bool shown(String url) => find
      .descendant(of: pictureOf(url), matching: find.byType(RawImage))
      .evaluate()
      .any((e) => (e.widget as RawImage).image != null);

  Finder placeholderOf(String url) =>
      find.descendant(of: pictureOf(url), matching: find.byKey(const ValueKey('post-image-tap-to-load')));

  group('1. the setting', () {
    test('off by default, stored by its index; a value it does not know is off; not synced', () async {
      expect(SettingsKeys.dataSaverMode.defaultValue, DataSaverMode.off.index);
      expect(settings.currentSettings.dataSaverMode, 0);
      await settings.setValue(SettingsKeys.dataSaverMode, DataSaverMode.meteredOnly.index);
      final again = SettingsRepository(storage);
      await again.init();
      addTearDown(again.dispose);
      expect(DataSaverMode.fromIndex(again.currentSettings.dataSaverMode), DataSaverMode.meteredOnly);
      expect(DataSaverMode.fromIndex(9), DataSaverMode.off);
      expect(DataSaverMode.fromIndex(-1), DataSaverMode.off);
      expect({for (final s in syncedSettings) s.key.name}, isNot(contains('dataSaverMode')));
    });

    testWidgets('the dialog offers off, on mobile data and always', (tester) async {
      DataSaverMode? picked;
      await pumpPages(
        tester,
        () => Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await showSelectDataSaverMode(context, DataSaverMode.off),
            child: const Text('pick'),
          ),
        ),
      );
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      final tr = t.settingsPage.othersSection.dataSaver;
      expect(find.text(tr.title), findsOneWidget);
      expect(find.text(tr.off), findsOneWidget);
      expect(find.text(tr.meteredOnly), findsOneWidget);
      tester.widget<ListTile>(find.byKey(const ValueKey('data-saver-mode-always'))).onTap!();
      await tester.pumpAndSettle();
      expect(picked, DataSaverMode.always);
    });
  });

  group('2. a page decides once', () {
    late List<bool?> answers;

    Widget probe(DataSaverMode mode) => Builder(
      builder: (context) {
        answers.add(DataSaver.holdsBack(context, mode));
        return const SizedBox(width: 10, height: 10);
      },
    );

    setUp(() => answers = []);

    testWidgets('off never, always always, whatever the network', (tester) async {
      NetworkUsage.handlePlatformChange(metered: true);
      await pumpPages(tester, () => Column(children: [probe(DataSaverMode.off), probe(DataSaverMode.always)]));
      expect(answers.take(2), [false, true]);
    });

    testWidgets('on a metered network: held back, and still once the network is free; a page opened then is not', (
      tester,
    ) async {
      NetworkUsage.check = () async => false;
      NetworkUsage.handlePlatformChange(metered: true);
      final router = await pumpPages(tester, () => probe(DataSaverMode.meteredOnly));
      expect(answers.last, isTrue);
      final first = tester.element(find.byType(SizedBox).first);

      NetworkUsage.handlePlatformChange(metered: false);
      expect(DataSaver.holdsBack(first, DataSaverMode.meteredOnly), isTrue, reason: 'the page keeps holding back');

      unawaited(router.push('/again'));
      await _settle(tester, rounds: 20);
      final second = tester.element(find.byType(SizedBox).last);
      expect(ModalRoute.of(second), isNot(ModalRoute.of(first)));
      expect(DataSaver.holdsBack(second, DataSaverMode.meteredOnly), isFalse, reason: 'a page opened on Wi-Fi loads');
      expect(DataSaver.holdsBack(first, DataSaverMode.meteredOnly), isTrue);
    });

    testWidgets('a page opened on Wi-Fi holds back from the moment the network counts', (tester) async {
      NetworkUsage.check = () async => true;
      NetworkUsage.handlePlatformChange(metered: false);
      await pumpPages(tester, () => probe(DataSaverMode.meteredOnly));
      expect(answers.last, isFalse);
      final page = tester.element(find.byType(SizedBox).first);
      NetworkUsage.handlePlatformChange(metered: true);
      expect(DataSaver.holdsBack(page, DataSaverMode.meteredOnly), isTrue);
      NetworkUsage.handlePlatformChange(metered: false);
      expect(DataSaver.holdsBack(page, DataSaverMode.meteredOnly), isTrue);
    });

    testWidgets('a page on Wi-Fi that built nothing while on mobile data holds back all the same', (tester) async {
      NetworkUsage.check = () async => true;
      NetworkUsage.handlePlatformChange(metered: false);
      await pumpPages(tester, () => probe(DataSaverMode.meteredOnly));
      final page = tester.element(find.byType(SizedBox).first);
      expect(DataSaver.holdsBack(page, DataSaverMode.meteredOnly), isFalse);
      // Nothing asks while the network counts the data (no picture built then).
      NetworkUsage.handlePlatformChange(metered: true);
      NetworkUsage.handlePlatformChange(metered: false);
      expect(DataSaver.holdsBack(page, DataSaverMode.meteredOnly), isTrue);
    });

    testWidgets('the network not known yet: no answer, then the first one', (tester) async {
      final answer = Completer<bool>();
      NetworkUsage.check = () => answer.future;
      await pumpPages(tester, () => probe(DataSaverMode.meteredOnly));
      expect(answers.first, isNull);
      answer.complete(true);
      await _settle(tester, rounds: 5);
      final page = tester.element(find.byType(SizedBox).first);
      expect(DataSaver.holdsBack(page, DataSaverMode.meteredOnly), isFalse);
    });
  });

  group('3. the pictures of a floor', () {
    testWidgets('always: placeholders, nothing fetched; a tap loads that one only', (tester) async {
      await pumpPages(tester, () => floorOf(_floorHtml, DataSaverMode.always));
      expect(placeholderOf(_a), findsOneWidget);
      expect(placeholderOf(_b), findsOneWidget);
      expect(server.requests, isEmpty);

      await tester.tap(placeholderOf(_a));
      await _settle(tester, until: () => shown(_a));
      expect(shown(_a), isTrue);
      expect(placeholderOf(_b), findsOneWidget);
      expect(server.requests, [_a]);
    });

    testWidgets('over "always load" and "Wi-Fi only" on Wi-Fi alike', (tester) async {
      NetworkUsage.check = () async => true;
      NetworkUsage.handlePlatformChange(metered: false);
      await pumpPages(tester, () => floorOf(_floorHtml, DataSaverMode.always, autoLoad: PostImageAutoLoad.wifiOnly));
      expect(placeholderOf(_a), findsOneWidget);
      expect(server.requests, isEmpty);
    });

    testWidgets('a cached picture shows anyway, it costs nothing', (tester) async {
      await tester.runAsync(() => getIt.get<ImageCacheProvider>().getOrMakeCache(const ImageCacheGeneralRequest(_a)));
      expect(server.requestsOf(_a), 1);
      await pumpPages(tester, () => floorOf(_floorHtml, DataSaverMode.always), until: () => shown(_a));
      expect(shown(_a), isTrue);
      expect(placeholderOf(_b), findsOneWidget);
      expect(server.requests, [_a]);
    });

    testWidgets('on mobile data: placeholders; back on Wi-Fi nothing loads by itself, a page opened then does', (
      tester,
    ) async {
      NetworkUsage.check = () async => false;
      NetworkUsage.handlePlatformChange(metered: true);
      final router = await pumpPages(tester, () => floorOf(_floorHtml, DataSaverMode.meteredOnly));
      expect(placeholderOf(_a), findsOneWidget);

      NetworkUsage.check = () async => true;
      NetworkUsage.handlePlatformChange(metered: false);
      await _settle(tester, rounds: 20);
      expect(placeholderOf(_a), findsOneWidget);
      expect(placeholderOf(_b), findsOneWidget);
      expect(server.requests, isEmpty);

      unawaited(router.push('/again'));
      await _settle(tester, until: () => shown(_a) && shown(_b));
      expect(shown(_a) && shown(_b), isTrue);
    });

    testWidgets('on Wi-Fi with "on mobile data": loads as usual', (tester) async {
      NetworkUsage.check = () async => true;
      NetworkUsage.handlePlatformChange(metered: false);
      await pumpPages(
        tester,
        () => floorOf(_floorHtml, DataSaverMode.meteredOnly),
        until: () => shown(_a) && shown(_b),
      );
      expect(shown(_a) && shown(_b), isTrue);
    });

    testWidgets('the sheet of a placeholder loads the whole floor, a fold opened later too', (tester) async {
      await pumpPages(tester, () => floorOf(_floorHtml, DataSaverMode.always));
      await tester.longPress(placeholderOf(_a));
      await _settle(tester, until: () => find.byKey(const ValueKey('image-sheet-load-floor')).evaluate().isNotEmpty);
      expect(find.text(t.imageGallery.loadFloorImages), findsOneWidget);
      expect(server.requests, isEmpty);
      tester.widget<ListTile>(find.byKey(const ValueKey('image-sheet-load-floor'))).onTap!();
      await _settle(tester, until: () => shown(_a) && shown(_b));
      expect(shown(_a) && shown(_b), isTrue);
      expect(floor.loadsAll, isTrue);

      await tester.tapAt(
        tester.getRect(find.ancestor(of: find.text('標題'), matching: find.byType(OutlinedButton))).center,
      );
      await _settle(tester, until: () => shown(_s));
      expect(shown(_s), isTrue, reason: 'built after "load all": loads too');
    });

    testWidgets('"load all" on a placeholder of the auto load off too, the data saver off', (tester) async {
      await pumpPages(tester, () => floorOf(_floorHtml, DataSaverMode.off, autoLoad: PostImageAutoLoad.never));
      expect(placeholderOf(_a), findsOneWidget);
      await tester.longPress(placeholderOf(_a));
      await _settle(tester, until: () => find.byKey(const ValueKey('image-sheet-load-floor')).evaluate().isNotEmpty);
      tester.widget<ListTile>(find.byKey(const ValueKey('image-sheet-load-floor'))).onTap!();
      await _settle(tester, until: () => shown(_a) && shown(_b));
      expect(shown(_a) && shown(_b), isTrue);
    });

    testWidgets('the auto load off and the network not known yet: the placeholder at once', (tester) async {
      final answer = Completer<bool>();
      NetworkUsage.check = () => answer.future;
      await pumpPages(tester, () => floorOf(_floorHtml, DataSaverMode.meteredOnly, autoLoad: PostImageAutoLoad.never));
      expect(placeholderOf(_a), findsOneWidget);
      answer.complete(true);
      await _settle(tester, rounds: 5);
    });

    test('a table opened full screen: "load all" there or in the floor loads both', () {
      final parent = FloorImages();
      final table = FloorImages.within(parent);
      parent.loadAll();
      expect(table.loadsAll, isTrue);

      final other = FloorImages();
      final otherTable = FloorImages.within(other)..loadAll();
      expect(other.loadsAll, isTrue);
      expect(otherTable.loadsAll, isTrue);
    });

    testWidgets('a picture shown offers no "load all" in its sheet', (tester) async {
      await pumpPages(tester, () => floorOf(_floorHtml, DataSaverMode.off), until: () => shown(_a));
      await tester.longPress(pictureOf(_a));
      await _settle(tester, until: () => find.text(t.imageBottomSheet.title).evaluate().isNotEmpty);
      expect(find.text(t.imageBottomSheet.title), findsOneWidget);
      expect(find.byKey(const ValueKey('image-sheet-load-floor')), findsNothing);
    });
  });

  group('4. the thumbnails of the lists', () {
    const preview = ThreadPreview(
      excerpt: '摘要',
      images: [ThreadPreviewImage(url: '', thumb: true)],
    );
    Finder thumbnail() => find.byKey(const ValueKey('thread-preview-thumbnail'));

    Widget section(DataSaverMode mode) => SizedBox(
      width: 400,
      child: ThreadPreviewSection(
        preview,
        showExcerpt: true,
        thumbnailMode: ThreadThumbnailMode.always,
        dataSaver: mode,
      ),
    );

    testWidgets('off: the thumbnail; always: none, the excerpt stays', (tester) async {
      NetworkUsage.handlePlatformChange(metered: false);
      await pumpPages(tester, () => section(DataSaverMode.off));
      expect(thumbnail(), findsOneWidget);
      await pumpPages(tester, () => section(DataSaverMode.always));
      expect(thumbnail(), findsNothing);
      expect(find.text('摘要'), findsOneWidget);
    });

    testWidgets('on mobile data: none, and none when back on Wi-Fi on the same page', (tester) async {
      NetworkUsage.check = () async => false;
      NetworkUsage.handlePlatformChange(metered: true);
      final router = await pumpPages(tester, () => section(DataSaverMode.meteredOnly));
      expect(thumbnail(), findsNothing);
      NetworkUsage.check = () async => true;
      NetworkUsage.handlePlatformChange(metered: false);
      await _settle(tester, rounds: 10);
      expect(thumbnail(), findsNothing);
      unawaited(router.push('/again'));
      await _settle(tester, rounds: 30);
      expect(thumbnail(), findsOneWidget, reason: 'a page opened on Wi-Fi');
    });
  });
}
