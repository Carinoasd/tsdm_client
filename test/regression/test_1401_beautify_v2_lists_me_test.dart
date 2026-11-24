/// The second design of the thread lists and of "me" (beautify v2, items 7 and 10 of its list).
///
/// 1. A thread row is flat on the page, the rows of a list separated by an inset hairline: the head is the author (a
///    24 avatar and the name, one 48 high target) with the date, the thread type tag at its end; the title is 16.5 and
///    bold; the counts on the left of the info row, who replied last and when on its right. The setting putting the
///    info row in equal columns still does.
/// 2. "Me": the account heads the page without a card; the name of each group stands above its panel, without an
///    icon; the tiles have no background of their own, five on a row of a phone and four with 1.3 times the text.
///
/// Screenshots: `BEAUTIFY_SHOTS_DIR` (a directory) and `BEAUTIFY_SHOTS_FONT` (a CJK font file, its bold face in
/// `BEAUTIFY_SHOTS_FONT_BOLD`) write a list of threads and "me" in the light and dark themes, at a phone and a desktop
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
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/date_time.dart';
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
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/heroes.dart';

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

NormalThread _thread(
  int tid,
  String title, {
  required String author,
  required String last,
  required int replies,
  required int views,
  String? type,
}) => NormalThread(
  title: title,
  url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
  threadID: '$tid',
  author: User(name: author, url: '$baseUrl/home.php?mod=space&uid=${100 + tid}', uid: '${100 + tid}'),
  publishDate: DateTime(2026, 11, 24 - tid),
  latestReplyAuthor: User(name: last, url: ''),
  latestReplyTime: DateTime.now().subtract(Duration(minutes: 12 * tid)),
  iconUrl: '',
  threadType: type == null ? null : ThreadType(name: type, url: '$baseUrl/forum.php?mod=forumdisplay&typeid=$tid'),
  replyCount: replies,
  viewCount: views,
  price: null,
  css: null,
  stateSet: const {},
  privilege: null,
  isRecentThread: false,
);

final List<NormalThread> _threads = [
  _thread(1, '【汉化】春日影 第三卷 完结，附全卷合集与勘误表', author: '白诘草', last: '雪见大福', replies: 126, views: 34000, type: '汉化'),
  _thread(2, '有没有人跟我一样，买了周边却舍不得拆封？', author: '折纸飞机', last: '大和啦', replies: 58, views: 2104),
  _thread(3, '压克力立牌褪色了，有补救方法吗？', author: '雪见大福', last: '灯下黑', replies: 9, views: 512, type: '求助'),
  _thread(4, '分享一下这季收的黏土人开箱', author: '灯下黑', last: '白诘草', replies: 31, views: 1880),
];

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

  /// A list of threads as the forum page lays it out: flat rows, hairlines between them.
  Future<void> pumpList(
    WidgetTester tester, {
    Size size = const Size(390, 1000),
    double textScale = 1,
    Brightness brightness = Brightness.light,
    String? fontFamily,
    List<NormalThread>? threads,
  }) async {
    final shown = threads ?? _threads;
    window(tester, size, textScale);
    await tester.pumpWidget(
      TranslationProvider(
        child: BlocProvider<SettingsBloc>.value(
          value: settingsBloc,
          child: Builder(
            builder: (context) => MaterialApp(
              theme: themeOf(context, brightness, fontFamily),
              home: Scaffold(
                appBar: AppBar(title: const Text('周邊交流')),
                body: LayoutBuilder(
                  builder: (context, constraints) => ListView.separated(
                    padding: threadListPadding(constraints.maxWidth).copyWith(top: 8),
                    itemCount: shown.length,
                    itemBuilder: (_, i) => NormalThreadCard(shown[i]),
                    separatorBuilder: (_, _) => const ThreadListSeparator(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
  }

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

  group('1. thread rows', () {
    test('the info row of v2 is the default: equal columns only when chosen', () {
      expect(SettingsKeys.threadCardInfoRowAlignCenter.defaultValue, isFalse);
    });

    testWidgets('flat, hairlines between them; the head, the title and the info row of v2', (tester) async {
      // The info row of v2 is the one without equal columns (a setting, see the next test).
      settingsBloc.add(const SettingsValueChanged(SettingsKeys.threadCardInfoRowAlignCenter, false));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await pumpList(tester);
      expect(find.byType(Card), findsNothing, reason: 'no card around a row');
      final line = AppSurfaces.of(tester.element(find.byType(ListView))).line;
      final separators = tester.widgetList<Divider>(find.byType(Divider)).toList();
      expect(separators, hasLength(_threads.length - 1));
      expect(separators.every((e) => e.color == line && e.indent == 16 && e.endIndent == 16), isTrue);

      // The head: a 24 avatar, the author in one 48 high target, the type tag at the end of the row.
      final avatar = tester.getRect(find.byType(HeroUserAvatar).first);
      expect(avatar.size, const Size(24, 24));
      expect(avatar.left, 16, reason: 'the row runs to the edges, its texts start at 16');
      final author = find.ancestor(of: find.text('白诘草'), matching: find.byType(GestureDetector)).first;
      expect(tester.getSize(author).height, greaterThanOrEqualTo(48));
      final tag = tester.getRect(find.text('汉化'));
      expect(tag.center.dy, closeTo(avatar.center.dy, 2), reason: 'the tag is in the head');
      expect(tag.right, greaterThan(390 - 40), reason: 'at the end of the head');

      // The title: 16.5, bold.
      final title = tester.widget<Text>(find.text(_threads[0].title));
      expect(title.style?.fontSize, 16.5);
      expect(title.style?.fontWeight, FontWeight.w700);

      // The info row: the counts on the left, the last reply on the right.
      final replies = tester.getRect(find.text('126'));
      final last = tester.getRect(
        find.text(_threads[0].latestReplyTime!.elapsedTillNow(tester.element(find.byType(ListView)))),
      );
      expect(replies.left, lessThan(80));
      expect(last.right, closeTo(390 - 16, 1));
      expect(last.center.dy, closeTo(replies.center.dy, 2), reason: 'one row');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the setting of an info row in equal columns still applies', (tester) async {
      settingsBloc.add(const SettingsValueChanged(SettingsKeys.threadCardInfoRowAlignCenter, true));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await pumpList(tester);
      final replies = tester.getRect(find.text('126'));
      final views = tester.getRect(find.text('34000'));
      final last = tester.getRect(
        find.descendant(of: find.byType(NormalThreadCard).first, matching: find.text('雪见大福')),
      );
      // Four columns of the same width: each text starts a column width after the one before.
      final column = views.left - replies.left;
      expect(last.left - views.left, closeTo(column, 1));
      expect(column, closeTo((390 - 32) / 4, 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('1.3 times the text: nothing overflows', (tester) async {
      await pumpList(tester, textScale: 1.3, size: const Size(390, 1400));
      expect(tester.takeException(), isNull);
    });

    group('a long name of the last reply: only the name is cut, the time is whole', () {
      final long = _thread(
        9,
        '长名称',
        author: '白诘草',
        last: '一个非常非常非常非常非常非常非常长的最后回复者名称',
        replies: 3,
        views: 40,
      );

      RenderParagraph paragraph(WidgetTester tester, String key) =>
          tester.renderObject<RenderParagraph>(find.byKey(ValueKey(key)));

      for (final (width, scale) in [(390.0, 1.0), (390.0, 1.3), (320.0, 1.3)]) {
        testWidgets('$width wide, ${scale}x', (tester) async {
          settingsBloc.add(const SettingsValueChanged(SettingsKeys.threadCardInfoRowAlignCenter, false));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await pumpList(tester, size: Size(width, 1000), textScale: scale, threads: [long]);
          expect(tester.takeException(), isNull);
          final name = paragraph(tester, 'thread-card-last-reply-author');
          final time = paragraph(tester, 'thread-card-last-reply-time');
          expect(name.didExceedMaxLines, isTrue, reason: 'the name is cut');
          expect(time.didExceedMaxLines, isFalse, reason: 'the time is whole');
          expect(time.size.width, closeTo(time.getMaxIntrinsicWidth(double.infinity), 0.5));
          expect(
            tester.getRect(find.byKey(const ValueKey('thread-card-last-reply-time'))).right,
            closeTo(width - 16, 1),
          );
          // The name takes all the time leaves: the right side is as wide as it may grow (60% of the row).
          final right = (width - 32) * 0.6;
          final nameLeft = tester.getRect(find.byKey(const ValueKey('thread-card-last-reply-author'))).left;
          expect(nameLeft, closeTo(width - 16 - right + 16 + 4, 1));
        });
      }

      testWidgets('a very narrow row: no overflow, either layout', (tester) async {
        for (final width in [240.0, 160.0]) {
          for (final center in [false, true]) {
            settingsBloc.add(SettingsValueChanged(SettingsKeys.threadCardInfoRowAlignCenter, center));
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
            await pumpList(tester, size: Size(width, 1000), textScale: 1.3, threads: [long]);
            expect(tester.takeException(), isNull, reason: '$width wide, center: $center');
          }
        }
      });
    });
  });

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
        testWidgets('list $name ${brightness.name}', (tester) async {
          settingsBloc.add(const SettingsValueChanged(SettingsKeys.threadCardInfoRowAlignCenter, false));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await pumpList(tester, size: size, textScale: scale, brightness: brightness, fontFamily: family);
          await shoot(tester, 'list-$name-${brightness.name}');
        }, skip: skip != null);
        testWidgets('list $name ${brightness.name}, equal columns', (tester) async {
          settingsBloc.add(const SettingsValueChanged(SettingsKeys.threadCardInfoRowAlignCenter, true));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await pumpList(tester, size: size, textScale: scale, brightness: brightness, fontFamily: family);
          await shoot(tester, 'list-$name-${brightness.name}-columns');
        }, skip: skip != null);
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
