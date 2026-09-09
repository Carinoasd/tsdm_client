import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';
import 'package:universal_html/parsing.dart';

void main() {
  late ImageCacheProvider cache;
  final html = File('test/data/forum_sliced_banner_698.html').readAsStringSync();
  final urls = parseHtmlDocument(html).querySelectorAll('img').map((e) => e.attributes['src']!).toList();
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() {
    cache = ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio(), cookie: CookieProvider.buildEmpty()));
    getIt.registerSingleton<ImageCacheProvider>(cache);
  });
  tearDown(() async {
    await cache.dispose();
    await getIt.reset();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<void> seedImages(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1400);
    addTearDown(tester.view.reset);
    for (var i = 0; i < urls.length; i++) {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 400, 800), Paint()..color = Colors.blue);
      final picture = recorder.endRecording();
      final image = await tester.runAsync(() => picture.toImage(400 - i * 50, 800));
      picture.dispose();
      final provider = ResizeImage.resizeIfNeeded(800, null, CachedImageProvider(urls[i]));
      final key = await provider.obtainKey(ImageConfiguration.empty);
      PaintingBinding.instance.imageCache.putIfAbsent(
        key,
        () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image!))),
      );
    }
  }

  Future<void> pump(WidgetTester tester, String content, double width) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: width, child: MunchedHtml(content)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Rect rect(WidgetTester tester, int index) {
    final finder = find.byWidgetPredicate((w) => w is NetworkIndicatorImage && w.src == urls[index]);
    return Rect.fromPoints(tester.getTopLeft(finder), tester.getBottomRight(finder));
  }

  testWidgets('vertical banner slices stay side by side and fit a narrow viewport', (tester) async {
    await seedImages(tester);
    await pump(tester, html, 320);
    final boxes = List.generate(3, (i) => rect(tester, i));
    expect(boxes[1].top, closeTo(boxes[0].top, 0.01));
    expect(boxes[2].top, closeTo(boxes[0].top, 0.01));
    expect(boxes[1].left, closeTo(boxes[0].right, 0.01));
    expect(boxes[2].left, closeTo(boxes[1].right, 0.01));
    expect(boxes.last.right - boxes.first.left, closeTo(320, 0.01));
    expect(boxes[0].width / boxes[1].width, closeTo(400 / 350, 0.01));
    expect(tester.takeException(), isNull);
  });
  testWidgets('resizing the cached banner keeps the strip joined', (tester) async {
    await seedImages(tester);
    await pump(tester, html, 320);
    await pump(tester, html, 640);
    expect(rect(tester, 1).top, closeTo(rect(tester, 0).top, 0.01));
    expect(rect(tester, 2).right - rect(tester, 0).left, closeTo(640, 0.01));
  });

  testWidgets('explicit line breaks keep horizontal slices stacked', (tester) async {
    await seedImages(tester);
    await pump(tester, html.replaceAll('</a><a', '</a><br><a'), 320);
    expect(rect(tester, 1).top, greaterThan(rect(tester, 0).top));
    expect(rect(tester, 2).top, greaterThan(rect(tester, 1).top));
    expect(find.byType(FittedBox), findsNothing);
  });

  testWidgets('small strips are not enlarged', (tester) async {
    await seedImages(tester);
    await pump(tester, html.replaceAll('<img ', '<img width="40" height="80" '), 700);
    expect(rect(tester, 0).width, closeTo(40, 0.01));
    expect(rect(tester, 2).right - rect(tester, 0).left, lessThan(121));
  });

  testWidgets('each slice keeps its own image and destination link', (tester) async {
    await seedImages(tester);
    await pump(tester, html, 320);
    final links = parseHtmlDocument(html).querySelectorAll('a').map((e) => e.attributes['href']!).toList();
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(rect(tester, i).center);
      await tester.pumpAndSettle();
      expect(find.text(urls[i]), findsOneWidget);
      expect(find.text(links[i]), findsOneWidget);
      Navigator.of(tester.element(find.text(links[i]))).pop();
      await tester.pumpAndSettle();
    }
  });
}
