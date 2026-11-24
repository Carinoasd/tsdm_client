/// The second design of "me" (beautify v2, item 10 of its list). The thread lists of that design are back to the
/// cards of 1.61.0 (test_1422).
///
/// 2. "Me": the account heads the page without a card; the name of each group stands above its panel, without an
///    icon; the tiles have no background of their own, five on a row of a phone and four with 1.3 times the text.
///
/// Screenshots: `BEAUTIFY_SHOTS_DIR` (a directory) and `BEAUTIFY_SHOTS_FONT` (a CJK font file, its bold face in
/// `BEAUTIFY_SHOTS_FONT_BOLD`) write "me" in the light and dark themes, at a phone and a desktop
/// width and at 1.3 times the text size.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/me/view/me_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/themes/app_themes.dart';

const _user = UserLoginInfo(username: '大和啦', uid: 2042122);

/// No network at all.
final class _Offline implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

final class _Auth extends Fake implements AuthenticationRepository {
  @override
  UserLoginInfo? get currentUser => _user;
}

Translations get tr => LocaleSettings.instance.currentTranslations;

Future<void> _settle(WidgetTester tester, {int rounds = 4}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  setUp(() async {
    await LocaleSettings.setLocale(AppLocale.zhTw);
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Offline())),
      );
    await settings.init();
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    ThreadAuthorCache.clear();
  });

  tearDown(() async {
    await settingsBloc.close();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  void window(WidgetTester tester, Size size, double textScale) {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
  }

  ThemeData themeOf(BuildContext context, Brightness brightness, String? fontFamily) => brightness == Brightness.light
      ? AppTheme.makeLight(context, seedColor: null, fontFamily: fontFamily ?? '')
      : AppTheme.makeDark(context, seedColor: null, fontFamily: fontFamily ?? '');

  late GoRouter router;

  Future<void> pumpMe(
    WidgetTester tester, {
    Size size = const Size(390, 1400),
    double textScale = 1,
    Brightness brightness = Brightness.light,
    String? fontFamily,
  }) async {
    window(tester, size, textScale);
    router = GoRouter(
      initialLocation: ScreenPaths.me,
      routes: [GoRoute(path: ScreenPaths.me, name: ScreenPaths.me, builder: (_, _) => const MePage())],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: RepositoryProvider<AuthenticationRepository>.value(
          value: _Auth(),
          child: Builder(
            builder: (context) => MaterialApp.router(
              theme: themeOf(context, brightness, fontFamily),
              routerConfig: router,
              locale: TranslationProvider.of(context).flutterLocale,
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  group('2. me', () {
    testWidgets('the account is not a card, the group names are above their panels, five tiles on a row', (
      tester,
    ) async {
      await pumpMe(tester);
      final account = find.byKey(const ValueKey('me-account-card'));
      expect(find.ancestor(of: account, matching: find.byType(Card)), findsNothing);
      expect(find.descendant(of: account, matching: find.byType(Card)), findsNothing);
      expect(tester.getRect(find.text(_user.username!)).height, greaterThanOrEqualTo(24));

      final content = find.byKey(const ValueKey('me-group-content'));
      final caption = find.descendant(of: content, matching: find.text(tr.mePage.content));
      expect(
        find.ancestor(of: caption, matching: find.byType(Card)),
        findsNothing,
        reason: 'outside the panel',
      );
      expect(
        find.descendant(of: content, matching: find.byType(Icon)).evaluate().length,
        10,
        reason: 'tiles only',
      );
      final keys = ['me-my-threads', 'me-favorites', 'me-collections', 'me-followed-threads', 'me-floor-bookmarks'];
      final top = tester.getTopLeft(find.byKey(ValueKey(keys.first))).dy;
      for (final key in keys) {
        expect(tester.getTopLeft(find.byKey(ValueKey(key))).dy, top, reason: '$key on the first row');
      }
      expect(tester.getTopLeft(find.byKey(const ValueKey('me-read-later'))).dy, greaterThan(top), reason: 'sixth');
      final tile = tester.widget<Material>(find.byKey(const ValueKey('me-favorites')));
      expect(tile.type, MaterialType.transparency, reason: 'no background of its own');
      expect(tester.takeException(), isNull);
    });

    testWidgets('1.3 times the text: four tiles on a row', (tester) async {
      await pumpMe(tester, textScale: 1.3, size: const Size(390, 1800));
      final top = tester.getTopLeft(find.byKey(const ValueKey('me-my-threads'))).dy;
      expect(tester.getTopLeft(find.byKey(const ValueKey('me-followed-threads'))).dy, top);
      expect(tester.getTopLeft(find.byKey(const ValueKey('me-floor-bookmarks'))).dy, greaterThan(top));
      expect(tester.takeException(), isNull);
    });

    test('columns follow the room and the text scale, four to five', () {
      expect(meEntryColumns(342, 1), 5);
      expect(meEntryColumns(342, 1.3), 4);
      expect(meEntryColumns(272, 1), 4);
      expect(meEntryColumns(728, 1), 5);
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['BEAUTIFY_SHOTS_DIR'];
    final font = Platform.environment['BEAUTIFY_SHOTS_FONT'];
    final bold = Platform.environment['BEAUTIFY_SHOTS_FONT_BOLD'];
    final skip = dir == null || font == null ? 'set BEAUTIFY_SHOTS_DIR and BEAUTIFY_SHOTS_FONT to write them' : null;
    const family = 'ShotSans';

    setUpAll(() async {
      if (skip != null) {
        return;
      }
      final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(font!).readAsBytesSync())));
      if (bold != null) {
        loader.addFont(Future.value(ByteData.sublistView(File(bold).readAsBytesSync())));
      }
      await loader.load();
      final root = Platform.environment['FLUTTER_ROOT'];
      final icons = root == null ? null : '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
      if (icons != null && File(icons).existsSync()) {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(File(icons).readAsBytesSync())))).load();
      }
      // The rounded Material Symbols (`BEAUTIFY_SHOTS_SYMBOLS`: MaterialSymbolsRounded.ttf of the package).
      final symbols = Platform.environment['BEAUTIFY_SHOTS_SYMBOLS'];
      if (symbols != null && File(symbols).existsSync()) {
        await (FontLoader(
          'packages/material_symbols_icons/MaterialSymbolsRounded',
        )..addFont(Future.value(ByteData.sublistView(File(symbols).readAsBytesSync())))).load();
      }
    });

    Future<void> shoot(WidgetTester tester, String name) async {
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);
      final image = await tester.runAsync(boundary.toImage);
      final bytes = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
      File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    for (final (name, size, scale) in [
      ('phone', const Size(390, 1000), 1.0),
      ('phone-1.3x', const Size(390, 1200), 1.3),
      ('desktop', const Size(960, 900), 1.0),
    ]) {
      for (final brightness in Brightness.values) {
        testWidgets('me $name ${brightness.name}', (tester) async {
          await pumpMe(
            tester,
            size: Size(size.width, scale > 1 ? 2000 : 1500),
            textScale: scale,
            brightness: brightness,
            fontFamily: family,
          );
          await shoot(tester, 'me-$name-${brightness.name}');
        }, skip: skip != null);
      }
    }
  });
}
