/// How a floor's background is drawn (plugin 4.1.0, the thread page's `backgrounds`).
///
/// 1. the veil: over every background a veil of the floor's own color, its opacity from the theme's colors, never
///    below [postBackgroundMinVeilOpacity]; the body text, the name and the secondary text read on it in the light and
///    the dark themes (several seed colors) and with the platform's high contrast, whatever the picture's pixels;
/// 2. the floor: the author row and the content each under their own background; the floor's size is the same with
///    the background as without, before the picture loads, once it loaded and when it failed; a failed picture shows
///    nothing (no error, no icon); the content is never mounted again for it (the picture loading, the network
///    changing); with the setting off, an offline copy or no background the card is the one it always was;
/// 3. an animated picture is drawn still (its first frame).
///
/// The pictures come from a fake network; nothing is sent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/post_background/models/post_background.dart';
import 'package:tsdm_client/features/post_background/utils/still_image.dart';
import 'package:tsdm_client/features/post_background/widgets/post_background_paint.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/post_image_auto_load.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/utils/html/author_style.dart';
import 'package:tsdm_client/utils/network_usage.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

final class _FakeContext extends Fake implements BuildContext {}

/// A small PNG (the app's placeholder).
final Uint8List _png = File('assets/images/placeholder.png').readAsBytesSync();

/// A GIF of two frames.
final Uint8List _gif = base64Decode(
  'R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQABQAAACwAAAAAAgACAAAIBgABCAQQEAAh+QQBBQABACwAAAAAAgAC'
  'AIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7',
);

/// The pictures: `ok.png` answers a PNG, anything else fails at once.
final class _Images implements HttpClientAdapter {
  final requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add('${options.uri}');
    if (!'${options.uri}'.endsWith('ok.png')) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    return ResponseBody.fromBytes(
      _png,
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A floor of the test forum's answer, without what needs more than the card.
Post _floor({PostBackground? background}) {
  final json =
      jsonDecode(File('test/data/tsdmapp_410/thread_v23_same_thread.json').readAsStringSync()) as Map<String, dynamic>;
  final post = threadPageFromApi(threadApiAnswerOf(json)!, 1).postList.first;
  return post.copyWith(
    author: User(name: post.author.name, uid: post.author.uid, url: post.author.url),
    userBriefProfile: null,
    postMedals: null,
    badge: null,
    secondBadge: null,
    signature: null,
    pokemon: null,
    checkin: null,
    background: background,
  );
}

const _both = PostBackground(
  content: PostBackgroundLayer(imageUrl: 'https://cdn.example/content-ok.png', repeat: PostBackgroundRepeat.both),
  sidebar: PostBackgroundLayer(imageUrl: 'https://cdn.example/sidebar-ok.png', alignX: PostBackgroundAlignX.right),
);

const _failing = PostBackground(
  content: PostBackgroundLayer(imageUrl: 'https://cdn.example/content-missing.jpg'),
  sidebar: PostBackgroundLayer(imageUrl: 'https://cdn.example/sidebar-missing.jpg'),
);

/// Whether [provider] gives a picture (from the image cache when it is there).
Future<bool> _resolve(ImageProvider provider) async {
  final done = Completer<bool>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener(
    (info, _) {
      info.dispose();
      if (!done.isCompleted) done.complete(true);
    },
    onError: (_, _) {
      if (!done.isCompleted) done.complete(false);
    },
  );
  stream.addListener(listener);
  final result = await done.future.timeout(const Duration(seconds: 5), onTimeout: () => false);
  stream.removeListener(listener);
  return result;
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    // The pictures are kept in a cache directory of their own.
    tmp = Directory.systemTemp.createTempSync('tsdm_post_background_');
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

  group('1. the veil', () {
    final themes = <String, ThemeData>{
      for (final seed in <Color?>[null, Colors.pink, Colors.yellow, Colors.teal, Colors.purple]) ...{
        'light $seed': AppTheme.makeLight(_FakeContext(), seedColor: seed, fontFamily: ''),
        'dark $seed': AppTheme.makeDark(_FakeContext(), seedColor: seed, fontFamily: ''),
      },
    };

    /// The least contrast [text] has on the veil over any pixel, from black to white.
    double worst(Color veil, Color text) {
      final darkest = Color.alphaBlend(veil, Colors.black);
      final lightest = Color.alphaBlend(veil, Colors.white);
      final l = relativeLuminance(text);
      if (l >= relativeLuminance(darkest) && l <= relativeLuminance(lightest)) {
        return 1;
      }
      return [contrastRatio(text, darkest), contrastRatio(text, lightest)].reduce((a, b) => a < b ? a : b);
    }

    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final highContrast in [false, true]) {
        test('$name${highContrast ? ', high contrast' : ''}: at least the least opacity, every text reads', () {
          final veil = postBackgroundVeil(theme, highContrast: highContrast);
          final surface = postBackgroundSurface(theme);
          expect(veil.a, greaterThanOrEqualTo(postBackgroundMinVeilOpacity));
          expect(veil.withValues(alpha: 1), surface.withValues(alpha: 1), reason: "the floor's own color");
          final scheme = theme.colorScheme;
          final body = highContrast ? 7.0 : readableContrast;
          final secondary = highContrast ? readableContrast : postBackgroundSecondaryContrast;
          for (final (text, needed) in [
            (scheme.onSurface, body),
            (scheme.primary, body),
            (scheme.outline, secondary),
          ]) {
            final own = contrastRatio(text, surface);
            expect(worst(veil, text), greaterThanOrEqualTo((needed < own ? needed : own) - 0.01), reason: '$text');
          }
        });
      }
    }

    test('a text that reads on nothing needs a full veil, not more', () {
      expect(postBackgroundVeilOpacity(const Color(0xFF808080), [(const Color(0xFF7F7F7F), 4.5)]), 1);
      expect(postBackgroundVeilOpacity(Colors.white, []), postBackgroundMinVeilOpacity);
    });
  });

  group('2. the floor', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc bloc;
    late _Images images;

    setUp(() async {
      await LocaleSettings.setLocale(AppLocale.zhCn);
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      images = _Images();
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = images)),
        );
      await settings.init();
      bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      PostBackgroundFailures.clear();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    });
    tearDown(() async {
      await bloc.close();
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
      NetworkUsage.unmetered.value = null;
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      await LocaleSettings.setLocale(AppLocale.en);
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<Size> pumpCard(WidgetTester tester, Post post, {ThemeData? theme}) async {
      await tester.pumpWidget(
        BlocProvider<SettingsBloc>.value(
          value: bloc,
          child: TranslationProvider(
            child: MaterialApp(
              theme: theme,
              themeAnimationDuration: Duration.zero,
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: PostCard(post, key: const ValueKey('card')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getSize(find.byKey(const ValueKey('card')));
    }

    Iterable<DecoratedBox> veils(WidgetTester tester) =>
        tester.widgetList<DecoratedBox>(find.byKey(const ValueKey('post-background-veil')));

    testWidgets('the author row and the content under their own background, each veiled', (tester) async {
      await pumpCard(tester, _floor(background: _both));
      expect(find.byType(PostBackgroundPaint), findsNWidgets(2));
      final layers = tester
          .widgetList<DecoratedBox>(find.byKey(const ValueKey('post-background-image')))
          .map((e) => (e.decoration as BoxDecoration).image!)
          .toList();
      expect(layers, hasLength(2));
      expect(layers.first.alignment, Alignment.centerRight, reason: 'the author row first');
      expect(layers.first.fit, BoxFit.none, reason: "the picture's own size");
      expect(layers.last.repeat, ImageRepeat.repeat);
      // Blended onto the floor's own color, the color the veil is of.
      final theme = Theme.of(tester.element(find.byType(PostCard)));
      for (final box in tester.widgetList<DecoratedBox>(find.byKey(const ValueKey('post-background-image')))) {
        final decoration = box.decoration as BoxDecoration;
        expect(decoration.color, postBackgroundSurface(theme));
        expect(decoration.image!.colorFilter, postBackgroundBlend(postBackgroundSurface(theme)));
      }
      for (final veil in veils(tester)) {
        expect((veil.decoration as BoxDecoration).color!.withValues(alpha: 1), postBackgroundSurface(theme));
        expect((veil.child! as Material).type, MaterialType.transparency);
      }
      expect(veils(tester), hasLength(2));
      for (final veil in veils(tester)) {
        final color = (veil.decoration as BoxDecoration).color!;
        expect(color.a, greaterThanOrEqualTo(postBackgroundMinVeilOpacity));
      }
      // The veil is between the picture and the text.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('post-background-veil')).last,
          matching: find.byType(MunchedHtml),
        ),
        findsOneWidget,
      );
      await settle(tester);
      expect(images.requested.toSet(), {'https://cdn.example/sidebar-ok.png', 'https://cdn.example/content-ok.png'});
      // Loaded: the picture the floor paints is in the image cache, one for every floor of the author.
      final loaded = await tester.runAsync(() => _resolve(postBackgroundImage('https://cdn.example/content-ok.png')));
      expect(loaded, isTrue);
    });

    testWidgets('the dark theme, the light theme: the veil is there and strong enough', (tester) async {
      for (final theme in [
        AppTheme.makeDark(_FakeContext(), seedColor: null, fontFamily: ''),
        AppTheme.makeLight(_FakeContext(), seedColor: Colors.yellow, fontFamily: ''),
      ]) {
        await pumpCard(tester, _floor(background: _both), theme: theme);
        expect(veils(tester), hasLength(2));
        for (final veil in veils(tester)) {
          expect((veil.decoration as BoxDecoration).color, postBackgroundVeil(theme));
        }
        await settle(tester);
      }
    });

    testWidgets('a veil the picture would not show through: no picture asked', (tester) async {
      final theme = AppTheme.makeLight(_FakeContext(), seedColor: null, fontFamily: '');
      expect(postBackgroundVeil(theme, highContrast: true).a, 1);
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(highContrast: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await pumpCard(tester, _floor(background: _both), theme: theme);
      expect(veils(tester), hasLength(2));
      for (final layer in tester.widgetList<DecoratedBox>(find.byKey(const ValueKey('post-background-image')))) {
        expect((layer.decoration as BoxDecoration).image, isNull);
      }
      await settle(tester);
      expect(images.requested, isEmpty);
    });

    testWidgets('the same size with and without, before and after the picture, loaded or failed', (tester) async {
      final plain = await pumpCard(tester, _floor());
      final before = await pumpCard(tester, _floor(background: _both));
      expect(before, plain);
      final content = tester.element(find.byType(MunchedHtml));
      await settle(tester);
      expect(tester.getSize(find.byKey(const ValueKey('card'))), plain, reason: 'loaded');
      expect(tester.takeException(), isNull);
      // The picture loading, the network changing: painted again, the content never mounted again.
      NetworkUsage.unmetered.value = true;
      await tester.pump();
      NetworkUsage.unmetered.value = false;
      await tester.pump();
      expect(tester.element(find.byType(MunchedHtml)), same(content));

      final failed = await pumpCard(tester, _floor(background: _failing));
      await settle(tester);
      expect(failed, plain, reason: 'failed');
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      expect(find.byIcon(Icons.broken_image), findsNothing);
      expect(images.requested, containsAll(['https://cdn.example/content-missing.jpg']));
    });

    testWidgets('the setting off: the card as it always was, no picture asked', (tester) async {
      await settings.setValue(SettingsKeys.showPostBackgrounds, false);
      bloc.add(const SettingsValueChanged(SettingsKeys.showPostBackgrounds, false));
      await tester.runAsync(() => bloc.stream.firstWhere((s) => !s.settingsMap.showPostBackgrounds));
      await pumpCard(tester, _floor(background: _both));
      expect(find.byType(PostBackgroundPaint), findsNothing);
      expect(find.byKey(const ValueKey('post-background-veil')), findsNothing);
      expect(find.byKey(const ValueKey('post-background-image')), findsNothing);
      await settle(tester);
      expect(images.requested, isEmpty);
    });

    testWidgets('no background: the card as it always was', (tester) async {
      await pumpCard(tester, _floor());
      expect(find.byType(PostBackgroundPaint), findsNothing);
      expect(find.byKey(const ValueKey('post-background-veil')), findsNothing);
    });

    testWidgets('the data saver holds the pictures back: only one already cached shows, none is fetched', (
      tester,
    ) async {
      bloc.add(const SettingsValueChanged(SettingsKeys.postImageAutoLoad, 2));
      await tester.runAsync(() => bloc.stream.firstWhere((s) => s.settingsMap.postImageAutoLoad == 2));
      expect(PostImageAutoLoad.fromIndex(2), PostImageAutoLoad.never);
      await pumpCard(tester, _floor(background: _both));
      DecorationImage? sidebar() =>
          (tester.widget<DecoratedBox>(find.byKey(const ValueKey('post-background-image')).first).decoration
                  as BoxDecoration)
              .image;
      await settle(tester);
      expect(images.requested, isEmpty);
      expect(tester.takeException(), isNull);
      // Not in the cache: not asked again while held back, fetched once the pictures load by themselves.
      expect(sidebar(), isNull);
      expect(PostBackgroundFailures.failed(_both.sidebar!.imageUrl, cacheOnly: true), isTrue);
      expect(PostBackgroundFailures.failed(_both.sidebar!.imageUrl, cacheOnly: false), isFalse);
    });

    testWidgets('not cached while held back, fetched later: shown from the cache when held back again', (tester) async {
      Future<void> autoLoad(int index) async {
        bloc.add(SettingsValueChanged(SettingsKeys.postImageAutoLoad, index));
        await tester.runAsync(() => bloc.stream.firstWhere((s) => s.settingsMap.postImageAutoLoad == index));
      }

      DecorationImage? content() =>
          (tester.widget<DecoratedBox>(find.byKey(const ValueKey('post-background-image')).last).decoration
                  as BoxDecoration)
              .image;
      final url = _both.content!.imageUrl;

      await autoLoad(2);
      await pumpCard(tester, _floor(background: _both));
      await settle(tester);
      expect(content(), isNull, reason: 'not cached');
      expect(images.requested, isEmpty);

      await autoLoad(0);
      await settle(tester);
      expect(content()!.image, postBackgroundImage(url));
      expect(images.requested, contains(url));
      expect(PostBackgroundFailures.failed(url, cacheOnly: true), isFalse);

      await autoLoad(2);
      await settle(tester);
      expect(content()!.image, postBackgroundImage(url, cacheOnly: true));
      expect(PostBackgroundFailures.failed(url, cacheOnly: true), isFalse, reason: 'found in the cache');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a picture that failed is not asked again, however often the floor paints', (tester) async {
      await pumpCard(tester, _floor(background: _failing));
      await settle(tester);
      final asked = images.requested.length;
      expect(asked, greaterThan(0));
      expect(
        tester
            .widgetList<DecoratedBox>(find.byKey(const ValueKey('post-background-image')))
            .map(
              (e) => (e.decoration as BoxDecoration).image,
            ),
        everyElement(isNull),
      );
      for (var i = 0; i < 5; i++) {
        for (final box in find.byKey(const ValueKey('post-background-image')).evaluate()) {
          box.renderObject!.markNeedsPaint();
        }
        await tester.pump();
        await settle(tester);
      }
      expect(images.requested, hasLength(asked));
      // Another floor of the same author, built later: nothing asked either.
      await pumpCard(tester, _floor(background: _failing));
      await settle(tester);
      expect(images.requested, hasLength(asked));
      expect(tester.takeException(), isNull);
    });

    testWidgets('floors picked to be quoted: nothing drawn, the same widgets', (tester) async {
      Widget paint({required bool enabled}) => MaterialApp(
        home: BlocProvider<SettingsBloc>.value(
          value: bloc,
          child: PostBackgroundPaint(
            layer: _both.content,
            part: PostBackgroundPart.bottom,
            enabled: enabled,
            child: const SizedBox(key: ValueKey('child'), height: 40),
          ),
        ),
      );
      await tester.pumpWidget(paint(enabled: true));
      final child = tester.element(find.byKey(const ValueKey('child')));
      await tester.pumpWidget(paint(enabled: false));
      expect((veils(tester).single.decoration as BoxDecoration).color, isNull);
      final layer = tester.widget<DecoratedBox>(find.byKey(const ValueKey('post-background-image')));
      expect((layer.decoration as BoxDecoration).image, isNull);
      expect(tester.element(find.byKey(const ValueKey('child'))), same(child));
      await settle(tester);
    });
  });

  group('3. an animated picture', () {
    test('is drawn still: its first frame only', () async {
      final codec = await ui.instantiateImageCodec(_gif);
      expect(codec.frameCount, 2, reason: 'the GIF has two frames');
      codec.dispose();

      final still = StillImage(MemoryImage(_gif));
      expect(StillImage(MemoryImage(_gif)), still);
      final key = await still.obtainKey(ImageConfiguration.empty);
      final completer = still.loadImage(key, (buffer, {getTargetSize}) async {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        return descriptor.instantiateCodec();
      });
      final frames = <ImageInfo>[];
      final listener = ImageStreamListener((info, _) => frames.add(info));
      completer.addListener(listener);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      completer.removeListener(listener);
      expect(frames, hasLength(1));
      for (final f in frames) {
        f.dispose();
      }
    });
  });
}
