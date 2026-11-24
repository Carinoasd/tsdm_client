/// The account card of the "me" tab on the content background the account uses in the forum's background shop
/// (plugin 4.1.0, `bgmine`):
///
/// * the kind of a picture: on white (its edge), wide, smaller, or repeated by the member;
/// * where a picture as high as the card goes;
/// * the background drawn for the account logged in, asked once and kept for it; asked again past its freshness or
///   after a write of the shop; nothing asked nor drawn with the website's shop (`bggrant` only), a background not
///   shown (`display` 0), a picture that fails, or for another account (an answer that arrives after the switch is
///   dropped).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/background_shop/models/background_shop.dart';
import 'package:tsdm_client/features/background_shop/repository/background_shop_repository.dart';
import 'package:tsdm_client/features/background_shop/repository/my_content_background.dart';
import 'package:tsdm_client/features/me/utils/account_backdrop.dart';
import 'package:tsdm_client/features/me/view/me_page.dart';
import 'package:tsdm_client/features/me/widgets/account_card_backdrop.dart';
import 'package:tsdm_client/features/post_background/models/post_background.dart';
import 'package:tsdm_client/features/post_background/widgets/post_background_paint.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/post_image_auto_load.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/html/author_style.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 31);
const _bob = UserLoginInfo(username: 'Bob', uid: 32);

const _wide = 'https://forum.test/source/plugin/background/background/wide.png';
const _white = 'https://forum.test/source/plugin/background/background/white.png';
const _broken = 'https://forum.test/source/plugin/background/background/broken.png';

/// Every request of the app fails, and is noted.
final class _OfflineAdapter implements HttpClientAdapter {
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests.add('${options.uri}');
    throw DioException.connectionError(requestOptions: options, reason: 'offline');
  }

  @override
  void close({bool force = false}) {}
}

final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  final UserLoginInfo? currentUser;
}

Map<String, dynamic> _fixture() =>
    jsonDecode(File('test/data/tsdmapp/bgshop/bg_mine_v74.json').readAsStringSync()) as Map<String, dynamic>;

/// `bgmine` served to [uid] with the content background [image] (none when null), shown or not ([display]).
Map<String, dynamic> _mine(int uid, {String? image, int display = 1, String repeat = 'none'}) {
  final json = _fixture()..['uid'] = uid;
  final backgrounds = json['backgrounds'] as Map<String, dynamic>;
  if (image == null) {
    backgrounds.remove('content');
  } else {
    (backgrounds['content'] as Map<String, dynamic>)
      ..['image'] = image
      ..['display'] = display
      ..['style'] = {'repeat': repeat, 'align_x': 'center', 'align_y': 'center', 'size': 'natural'};
  }
  return json;
}

/// RGBA bytes of [width] × [height] pixels: [edge] on a band [band] pixels wide, [center] inside.
Uint8List _rgba(int width, int height, {required int edge, required int center, int band = 2}) {
  final bytes = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final inside = x >= band && y >= band && x < width - band && y < height - band;
      final c = inside ? center : edge;
      bytes.setAll((y * width + x) * 4, [(c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF, (c >> 24) & 0xFF]);
    }
  }
  return bytes;
}

/// A PNG of [width] × [height] made of [_rgba].
Future<Uint8List> _png(int width, int height, {required int edge, required int center}) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    _rgba(width, height, edge: edge, center: center, band: (math.min(width, height) * 0.2).round()),
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

TsdmAppPluginInfo _status(Map<String, Object> flags) => TsdmAppPluginInfo.fromAnswer({
  'ok': 1,
  'version': '4.1.0',
  'actions': const ['status'],
  ...flags,
})!;

void main() {
  group('the kind of a picture', () {
    test('on white: most of its edge white or transparent', () {
      expect(accountBackdropWhiteEdged(_rgba(64, 40, edge: 0xFFFFFFFF, center: 0xFF203040), 64, 40), isTrue);
      expect(accountBackdropWhiteEdged(_rgba(64, 40, edge: 0xFFF0EEEC, center: 0xFF203040), 64, 40), isTrue);
      expect(accountBackdropWhiteEdged(_rgba(64, 40, edge: 0x00000000, center: 0xFF203040), 64, 40), isTrue);
      // Cream, a scene, a dark frame.
      expect(accountBackdropWhiteEdged(_rgba(64, 40, edge: 0xFFF5F0D8, center: 0xFFFFFFFF), 64, 40), isFalse);
      expect(accountBackdropWhiteEdged(_rgba(64, 40, edge: 0xFF6080A0, center: 0xFFFFFFFF), 64, 40), isFalse);
      expect(accountBackdropWhiteEdged(_rgba(64, 40, edge: 0xFF000000, center: 0xFFFFFFFF), 64, 40), isFalse);
      // Too few bytes: not told.
      expect(accountBackdropWhiteEdged(Uint8List(10), 64, 40), isFalse);
    });

    test('a figure touching the edge: on white while the share of white holds', () {
      Uint8List withDark(double share) {
        final bytes = _rgba(64, 64, edge: 0xFFFFFFFF, center: 0xFF808080, band: 4);
        // Dark pixels along the bottom edge, from the left.
        final dark = (64 * share).round();
        for (var y = 60; y < 64; y++) {
          for (var x = 0; x < dark; x++) {
            bytes.setAll((y * 64 + x) * 4, [0, 0, 0, 255]);
          }
        }
        return bytes;
      }

      // The band is 4 pixels of a 64 square: 960 pixels, 256 of them along the bottom.
      expect(accountBackdropWhiteEdged(withDark(0.5), 64, 64), isTrue);
      expect(accountBackdropWhiteEdged(withDark(0.8), 64, 64), isTrue);
      // A whole side dark: 0.73 of the edge white.
      expect(accountBackdropWhiteEdged(withDark(1), 64, 64), isFalse);
    });

    test('repeated by the member, on white, wide or smaller', () {
      AccountBackdropKind kind(
        int width, {
        bool white = false,
        PostBackgroundRepeat repeat = PostBackgroundRepeat.none,
      }) => accountBackdropKind(width: width, whiteEdged: white, repeat: repeat);
      expect(kind(1280, white: true, repeat: PostBackgroundRepeat.both), AccountBackdropKind.tile);
      expect(kind(100, repeat: PostBackgroundRepeat.x), AccountBackdropKind.tile);
      expect(kind(100, repeat: PostBackgroundRepeat.y), AccountBackdropKind.tile);
      expect(kind(700, white: true), AccountBackdropKind.blend);
      expect(kind(200, white: true), AccountBackdropKind.blend);
      expect(kind(accountBackdropCoverWidth), AccountBackdropKind.cover);
      expect(kind(1280), AccountBackdropKind.cover);
      expect(kind(accountBackdropCoverWidth - 1), AccountBackdropKind.side);
    });

    test('as high as the card; a tall strip wider and cut; never wider than the card', () {
      const card = Size(360, 170);
      final right = accountBackdropSideRect(card, const Size(700, 500), alignX: PostBackgroundAlignX.right);
      expect(right.left, moreOrLessEquals(122));
      expect(right.right, moreOrLessEquals(360));
      expect(right.top, moreOrLessEquals(0));
      expect(right.height, moreOrLessEquals(170));
      expect(
        accountBackdropSideRect(card, const Size(700, 500), alignX: PostBackgroundAlignX.left).left,
        0,
      );
      expect(
        accountBackdropSideRect(card, const Size(700, 500), alignX: PostBackgroundAlignX.center).center.dx,
        moreOrLessEquals(180),
      );
      // 200 × 1000: 144 wide (0.4 of the card), 720 high, cut at the top, the centre or the bottom.
      final strip = accountBackdropSideRect(card, const Size(200, 1000), alignX: PostBackgroundAlignX.right);
      expect(strip.width, moreOrLessEquals(144));
      expect(strip.height, moreOrLessEquals(720));
      expect(strip.center.dy, moreOrLessEquals(85));
      expect(
        accountBackdropSideRect(
          card,
          const Size(200, 1000),
          alignX: PostBackgroundAlignX.right,
          alignY: PostBackgroundAlignY.top,
        ).top,
        0,
      );
      // Not past its own size for the strip: 100 × 1000 stays 100 wide.
      expect(
        accountBackdropSideRect(card, const Size(100, 1000), alignX: PostBackgroundAlignX.right).width,
        moreOrLessEquals(100),
      );
      // A banner: as wide as the card, less high.
      final banner = accountBackdropSideRect(card, const Size(1000, 100), alignX: PostBackgroundAlignX.right);
      expect(banner.width, moreOrLessEquals(360));
      expect(banner.height, moreOrLessEquals(36));
    });

    test('the veil keeps the texts AA in both themes, AAA with high contrast, whatever the picture', () {
      for (final brightness in Brightness.values) {
        final scheme = ColorScheme.fromSeed(seedColor: Colors.teal, brightness: brightness);
        final surface = scheme.surfaceContainerLow;
        for (final (highContrast, needed) in [(false, 4.5), (true, 7.0)]) {
          final veil = accountBackdropVeil(scheme, surface, highContrast: highContrast);
          if (veil >= 1) {
            continue;
          }
          for (final pixel in const [Color(0xFF000000), Color(0xFFFFFFFF), Color(0xFF808080), Color(0xFFFF0000)]) {
            final under = Color.alphaBlend(surface.withValues(alpha: veil), pixel);
            for (final text in [scheme.onSurface, scheme.onSurfaceVariant]) {
              expect(
                contrastRatio(text, under),
                greaterThanOrEqualTo(needed - 0.01),
                reason: '$brightness, high contrast $highContrast, $pixel',
              );
            }
          }
        }
      }
    });
  });

  group('the background of the account', () {
    test("of `bgmine`: shown, a url the app loads, the member's style", () {
      BackgroundInUse? content(Map<String, dynamic> json) =>
          (BackgroundMine.fromJson(json)! as BackgroundShopLoaded<BackgroundMine>).page.content;
      final json = _mine(31, image: _wide, repeat: 'both');
      ((json['backgrounds'] as Map)['content'] as Map)['style'] = {
        'repeat': 'both',
        'align_x': 'right',
        'align_y': 'bottom',
        'size': 'natural',
      };
      expect(
        AccountBackground.of(content(json)),
        const AccountBackground(
          imageUrl: _wide,
          repeat: PostBackgroundRepeat.both,
          alignX: PostBackgroundAlignX.right,
          alignY: PostBackgroundAlignY.bottom,
        ),
      );
      expect(AccountBackground.of(content(_mine(31, image: _wide, display: 0))), isNull);
      expect(AccountBackground.of(content(_mine(31))), isNull);
      // Plain http of another host is not loaded.
      expect(AccountBackground.of(content(_mine(31, image: 'http://elsewhere.test/a.jpg'))), isNull);
    });
  });

  group('the account card', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late _OfflineAdapter network;
    GoRouter? router;

    /// The answers of `bgmine` by the account asking, and each ask.
    late Map<int, Map<String, dynamic>> answers;
    late List<int> asked;

    /// Holds the answer back until completed.
    Completer<void>? hold;

    /// The pictures by url; another url fails.
    final pictures = <String, Uint8List>{};
    late DateTime clock;

    setUpAll(() async {
      talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    });

    setUp(() async {
      TsdmAppApi.reset();
      MyContentBackground.clear();
      PostBackgroundFailures.clear();
      clock = DateTime(2026, 11, 24, 12);
      MyContentBackground.now = () => clock;
      answers = {};
      asked = [];
      hold = null;
      MyContentBackground.repository = () => BackgroundShopRepository(
        ask: (action, query) async {
          expect(action, 'bgmine');
          final uid = getIt.get<SettingsRepository>().currentSettings.loginUid;
          asked.add(uid);
          final answer = answers[uid];
          await hold?.future;
          return answer;
        },
        post: (_, _) async => null,
        get: (_) async => null,
      );
      accountBackdropImage = (url, {cacheOnly = false}) => MemoryImage(pictures[url] ?? Uint8List.fromList([1, 2, 3]));
      await LocaleSettings.setLocale(AppLocale.zhCn);
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      network = _OfflineAdapter();
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = network),
        )
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
      TsdmAppApi.pluginInfo.value = _status(const {'bgshop': 1});
    });

    tearDown(() async {
      TsdmAppApi.reset();
      MyContentBackground.clear();
      MyContentBackground.now = DateTime.now;
      accountBackdropImage = postBackgroundImage;
      PostBackgroundFailures.clear();
      router?.dispose();
      router = null;
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    Future<void> pump(WidgetTester tester, UserLoginInfo user, {Brightness brightness = Brightness.light}) async {
      tester.view
        ..physicalSize = const Size(411, 868)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      router?.dispose();
      router = GoRouter(
        initialLocation: ScreenPaths.me,
        routes: [
          GoRoute(path: ScreenPaths.me, name: ScreenPaths.me, builder: (_, _) => const MePage()),
          GoRoute(
            path: ScreenPaths.backgroundShop,
            name: ScreenPaths.backgroundShop,
            builder: (_, _) => const Scaffold(body: Text('shop')),
          ),
        ],
      );
      // A new tree each time: the card of the account, nothing carried by the widgets.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: _Auth(user),
            child: Builder(
              builder: (context) => MaterialApp.router(
                routerConfig: router,
                theme: ThemeData(colorSchemeSeed: Colors.teal, brightness: brightness),
                locale: TranslationProvider.of(context).flutterLocale,
                supportedLocales: AppLocaleUtils.supportedLocales,
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
              ),
            ),
          ),
        ),
      );
      await settle(tester);
    }

    Future<void> addPicture(WidgetTester tester, String url, int width, int height, {required int edge}) async {
      pictures[url] = (await tester.runAsync(() => _png(width, height, edge: edge, center: 0xFF305070)))!;
    }

    final backdrop = find.byKey(const ValueKey('me-account-backdrop'));

    /// The painter of the card's background, null for none.
    String? painted(WidgetTester tester) {
      final paint = tester.widget<CustomPaint>(find.descendant(of: backdrop, matching: find.byType(CustomPaint)).first);
      return paint.painter?.toString();
    }

    /// Whether the card shows its look without a background.
    bool plain(WidgetTester tester) =>
        tester.widget<DecoratedBox>(find.descendant(of: backdrop, matching: find.byType(DecoratedBox)).first).decoration
            is BoxDecoration &&
        (tester
                        .widget<DecoratedBox>(find.descendant(of: backdrop, matching: find.byType(DecoratedBox)).first)
                        .decoration
                    as BoxDecoration)
                .gradient
            is RadialGradient;

    testWidgets('drawn for the account, asked once while fresh; again past it and after a write', (tester) async {
      await addPicture(tester, _wide, 800, 400, edge: 0xFF305070);
      answers[31] = _mine(31, image: _wide);
      await pump(tester, _alice);
      expect(asked, [31]);
      expect(painted(tester), contains('cover'));
      expect(plain(tester), isFalse);
      expect(find.text('Alice'), findsOneWidget);

      // Shown again: what is kept.
      await pump(tester, _alice);
      expect(asked, [31]);
      expect(painted(tester), contains('cover'));

      // Past its freshness: asked again, drawn meanwhile.
      clock = clock.add(MyContentBackground.fresh + const Duration(seconds: 1));
      await pump(tester, _alice);
      expect(asked, [31, 31]);

      // A write of the shop (here the style form): asked again; the answer now has none.
      answers[31] = _mine(31);
      final shop = BackgroundShopRepository(
        ask: (_, _) async => null,
        post: (_, _) async => {'ok': 1, 'uid': 31, 'type': 'result', 'schema': 13, 'message_key': 'x'},
        get: (_) async => null,
        currentUid: () => 31,
      );
      final form = (BackgroundMine.fromJson(_mine(31, image: _wide))! as BackgroundShopLoaded<BackgroundMine>)
          .page
          .content!
          .form!;
      await tester.runAsync(() async {
        try {
          await shop.saveStyle(31, form, const {'dipbg': '0'});
        } on Object {
          // The answer is not what the test is about.
        }
      });
      await pump(tester, _alice);
      expect(asked, [31, 31, 31]);
      expect(painted(tester), isNull);
      expect(plain(tester), isTrue);
      expect(network.requests, isEmpty);
    });

    testWidgets('not asked while a page is above it; asked when back after a write', (tester) async {
      await addPicture(tester, _wide, 800, 400, edge: 0xFF305070);
      answers[31] = _mine(31, image: _wide);
      await pump(tester, _alice);
      expect(asked, [31]);

      unawaited(router!.pushNamed(ScreenPaths.backgroundShop));
      await settle(tester);
      expect(find.text('shop'), findsOneWidget);
      // A write in the shop, and the card built again under it.
      MyContentBackground.markStale(31);
      MyContentBackground.changes.value++;
      await settle(tester);
      expect(asked, [31]);

      router!.pop();
      await settle(tester);
      expect(asked, [31, 31]);
      expect(painted(tester), contains('cover'));
    });

    testWidgets('an answer asked before a write stays stale', (tester) async {
      await addPicture(tester, _wide, 800, 400, edge: 0xFF305070);
      answers[31] = _mine(31, image: _wide);
      hold = Completer<void>();
      await pump(tester, _alice);
      expect(asked, [31]);
      MyContentBackground.markStale(31);
      hold!.complete();
      hold = null;
      await settle(tester);
      expect(painted(tester), contains('cover'));
      // Shown again: asked again.
      await pump(tester, _alice);
      expect(asked, [31, 31]);
    });

    testWidgets('pictures not loaded by themselves: from the cache only', (tester) async {
      final asks = <bool>[];
      accountBackdropImage = (url, {cacheOnly = false}) {
        asks.add(cacheOnly);
        return MemoryImage(Uint8List.fromList([1, 2, 3]));
      };
      await settings.setValue(SettingsKeys.postImageAutoLoad, PostImageAutoLoad.never.index);
      answers[31] = _mine(31, image: _wide);
      await pump(tester, _alice);
      expect(asks, isNotEmpty);
      expect(asks.every((e) => e), isTrue);
    });

    testWidgets('a picture on white is blended, in both themes', (tester) async {
      await addPicture(tester, _white, 700, 500, edge: 0xFFFFFFFF);
      answers[31] = _mine(31, image: _white);
      for (final brightness in Brightness.values) {
        await pump(tester, _alice, brightness: brightness);
        expect(painted(tester), contains('blend'), reason: '$brightness');
      }
      expect(asked, [31]);
    });

    testWidgets('the shop read by the app fills it: not asked again', (tester) async {
      await addPicture(tester, _wide, 800, 400, edge: 0xFF305070);
      final shop = BackgroundShopRepository(
        ask: (_, _) async => _mine(31, image: _wide),
        post: (_, _) async => null,
        get: (_) async => null,
        currentUid: () => 31,
      );
      await tester.runAsync(shop.mine);
      await pump(tester, _alice);
      expect(asked, isEmpty);
      expect(painted(tester), contains('cover'));
    });

    testWidgets('none, not shown, or a picture that fails: the card as before', (tester) async {
      answers[31] = _mine(31, image: _wide, display: 0);
      await pump(tester, _alice);
      expect(asked, [31]);
      expect(painted(tester), isNull);
      expect(plain(tester), isTrue);

      MyContentBackground.clear();
      answers[31] = _mine(31, image: _broken);
      await pump(tester, _alice);
      expect(asked, [31, 31]);
      expect(painted(tester), isNull);
      expect(plain(tester), isTrue);
      expect(PostBackgroundFailures.failed(_broken, cacheOnly: false), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets("the website's shop (bggrant), or none: nothing asked", (tester) async {
      answers[31] = _mine(31, image: _wide);
      for (final flags in const <Map<String, Object>>[
        {'bggrant': 1},
        {'bgshop': 0, 'bggrant': 0},
      ]) {
        TsdmAppApi.pluginInfo.value = _status(flags);
        await pump(tester, _alice);
        expect(painted(tester), isNull);
        expect(plain(tester), isTrue);
      }
      TsdmAppApi.reset();
      await pump(tester, _alice);
      expect(asked, isEmpty);
    });

    testWidgets('another account: its own background, never the one before', (tester) async {
      await addPicture(tester, _wide, 800, 400, edge: 0xFF305070);
      answers[31] = _mine(31, image: _wide);
      answers[32] = _mine(32);
      await pump(tester, _alice);
      expect(painted(tester), contains('cover'));

      await settings.setValue(SettingsKeys.loginUid, _bob.uid!);
      await pump(tester, _bob);
      expect(asked, [31, 32]);
      expect(painted(tester), isNull);
      expect(MyContentBackground.of(32), isNull);
      expect(MyContentBackground.of(31), isNotNull);
    });

    testWidgets('an answer that arrives after the switch is dropped', (tester) async {
      await addPicture(tester, _wide, 800, 400, edge: 0xFF305070);
      answers[31] = _mine(31, image: _wide);
      hold = Completer<void>();
      await pump(tester, _alice);
      expect(asked, [31]);
      expect(painted(tester), isNull);

      // Bob logs in while Alice's answer is on its way; it arrives after.
      await settings.setValue(SettingsKeys.loginUid, _bob.uid!);
      await pump(tester, _bob);
      hold!.complete();
      await settle(tester);
      expect(MyContentBackground.of(31), isNull);
      expect(MyContentBackground.of(32), isNull);
      expect(painted(tester), isNull);
      expect(plain(tester), isTrue);
    });

    testWidgets('a card shown for an account not logged in asks nothing', (tester) async {
      answers[32] = _mine(32, image: _wide);
      await pump(tester, _bob);
      expect(asked, isEmpty);
      expect(painted(tester), isNull);
    });
  });
}
