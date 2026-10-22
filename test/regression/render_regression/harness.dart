/// Shows a floor as the thread page does and reads it back ([FloorDumper]): the content of a post card (its
/// [MunchedHtml] in a [PostTypographyScope], the reader's line width) in a floor card on a 390 × 844 phone, every
/// spoiler opened, images from placeholders (nothing is fetched).
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:universal_html/parsing.dart';

import 'dump.dart';

/// The phone the floors are shown on.
const phone = Size(390, 844);

/// No request leaves the test.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The image cache provider the images of a floor go through: register in `setUp`, dispose in `tearDown`.
ImageCacheProvider offlineImageCache() => ImageCacheProvider(
  NetClientProvider.buildNoCookie(
    dio: Dio()..httpClientAdapter = _OfflineAdapter(),
    cookie: CookieProvider.buildEmpty(),
  ),
);

/// A theme of the app (`AppTheme.makeLight` only wants a context's type).
ThemeData appTheme({required bool dark}) => dark
    ? AppTheme.makeDark(_FakeContext(), seedColor: null, fontFamily: '')
    : AppTheme.makeLight(_FakeContext(), seedColor: null, fontFamily: '');

final class _FakeContext extends Fake implements BuildContext {}

final _placeholders = <String, ui.Image>{};

/// The size of an image of the synthetic corpus, from its url (`…/img-3-640x360.png`).
final _sizeInUrl = RegExp(r'-(\d+)x(\d+)\.\w+$');

/// Puts a placeholder for every image of [html] in the image cache, under the key the app reads it with; its size
/// from its url, else [sizeOf] (the full corpus' list), else 1000 × 700.
Future<void> seedImages(WidgetTester tester, String html, {(int, int)? Function(String url)? sizeOf}) async {
  final doc = parseHtmlDocument(html);
  final decodeWidth = phone.width.ceil();
  for (final img in doc.querySelectorAll('img')) {
    final dataSrc = img.attributes['data-src'];
    final url = (dataSrc != null && dataSrc.isNotEmpty) ? dataSrc.prependHost() : img.imageUrl();
    if (url == null) {
      continue;
    }
    final m = _sizeInUrl.firstMatch(url);
    final (w, h) = m != null ? (int.parse(m.group(1)!), int.parse(m.group(2)!)) : (sizeOf?.call(url) ?? (1000, 700));
    // ResizeImage only makes an image smaller: one wider than the decode width comes at that width.
    final dw = math.max(1, math.min(w, decodeWidth));
    final dh = math.max(1, (h * dw / w).round());
    final key = '${dw}x$dh';
    final image =
        _placeholders[key] ??
        (_placeholders[key] = (await tester.runAsync(() {
          final recorder = ui.PictureRecorder();
          Canvas(
            recorder,
          ).drawRect(Rect.fromLTWH(0, 0, dw.toDouble(), dh.toDouble()), Paint()..color = Colors.blueGrey);
          final picture = recorder.endRecording();
          return picture.toImage(dw, dh).whenComplete(picture.dispose);
        }))!);
    final provider = ResizeImage.resizeIfNeeded(decodeWidth, null, CachedImageProvider(url));
    final cacheKey = await provider.obtainKey(ImageConfiguration.empty);
    PaintingBinding.instance.imageCache.putIfAbsent(
      cacheKey,
      () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image.clone()))),
    );
  }
}

/// [html] as the content of a floor on the thread page, in [dark] or light.
Widget floorPage(String html, {required bool dark, bool splitLongParagraphs = false, Key? key}) => TranslationProvider(
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    themeAnimationDuration: Duration.zero,
    theme: appTheme(dark: dark),
    home: Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          // The floor's margin on a phone, its padding: as the thread page has them.
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Builder(
            builder: (context) => Card(
              margin: EdgeInsets.zero,
              shape: appSurfaceShape(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: PostTypographyScope(
                          typography: PostTypography(
                            splitLongParagraphs: splitLongParagraphs,
                          ).withLineWidth(postContentLineWidth(context)),
                          child: MunchedHtml(html, key: key),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

/// Lets the floor build, opening every spoiler (nested ones too).
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  for (var round = 0; round < 6; round++) {
    final closed = find.byIcon(Icons.expand_more_outlined).evaluate().toList();
    if (closed.isEmpty) {
      break;
    }
    for (final el in closed) {
      el.visitAncestorElements((a) {
        final w = a.widget;
        if (w is ButtonStyleButton) {
          w.onPressed?.call();
          return false;
        }
        if (w is IconButton) {
          w.onPressed?.call();
          return false;
        }
        return true;
      });
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// What the app shows of [html]: its tokens and the error it threw, if any.
Future<(List<Map<String, Object?>>, String?)> dumpFloor(
  WidgetTester tester,
  String html, {
  required bool dark,
  bool splitLongParagraphs = false,
}) async {
  await tester.pumpWidget(
    floorPage(html, dark: dark, splitLongParagraphs: splitLongParagraphs, key: UniqueKey()),
  );
  await settle(tester);
  final error = tester.takeException()?.toString();
  final d = FloorDumper();
  final root = find.byType(MunchedHtml).evaluate().firstOrNull;
  if (root != null) {
    d.floor(root);
  }
  return (d.tokens, error);
}

/// Sets the test's view to [phone] until the test ends.
void usePhone(WidgetTester tester) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = phone;
  addTearDown(tester.view.reset);
}

/// Registers what showing a floor needs ([offlineImageCache]); the returned function undoes it.
Future<Future<void> Function()> registerFloorServices() async {
  final db = AppDatabase(NativeDatabase.memory());
  NetClientProvider offline() => NetClientProvider.buildNoCookie(
    dio: Dio()..httpClientAdapter = _OfflineAdapter(),
    cookie: CookieProvider.buildEmpty(),
  );
  final cache = offlineImageCache();
  getIt
    ..registerSingleton<StorageProvider>(StorageProvider(db, {}, {}))
    ..registerSingleton<NetErrorSaver>(NetErrorSaver())
    ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
    ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
    ..registerFactory<NetClientProvider>(offline)
    ..registerFactory<NetClientProvider>(offline, instanceName: ServiceKeys.noCookie)
    ..registerSingleton<ImageCacheProvider>(cache);
  PaintingBinding.instance.imageCache
    ..maximumSize = 100000
    ..maximumSizeBytes = 1 << 30;
  return () async {
    await cache.dispose();
    await getIt.reset();
    await db.close();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  };
}
