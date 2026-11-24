/// The second design of the homepage (beautify v2, items 4 and 8 of its list).
///
/// 1. The greeting is the masthead of the page, not a card: the forum and the date as a kicker, the today count with
///    its number in the primary color, and the actions of the day as four tiles on one row on phones, the check-in the
///    one filled with the primary color; when the four do not fit (large text, long labels) they go two by two with
///    their icons before the labels. Checked in, it keeps the panel look with a filled check, not a disabled one.
/// 2. The forum guide is flat on the page: no card, the "unanswered" entry beside its title, its rows separated by
///    hairlines.
///
/// Screenshots: `BEAUTIFY_SHOTS_DIR` (a directory) and `BEAUTIFY_SHOTS_FONT` (a CJK font file, its bold face in
/// `BEAUTIFY_SHOTS_FONT_BOLD`) write the homepage in the light and dark themes, at a phone and a desktop width and at
/// 1.3 times the text size.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/repository/guide_index_repository.dart';
import 'package:tsdm_client/features/homepage/widgets/guide_section.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/themes/app_themes.dart';

const _user = UserLoginInfo(username: '大和啦', uid: 2042122);

/// Authentication repository with one account.
final class _Auth extends Fake implements AuthenticationRepository {
  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  UserLoginInfo? get currentUser => _user;

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  int? get effectiveCurrentUid => _user.uid;

  Future<void> close() => _controller.close();
}

/// The guide with made up threads.
final class _Guide extends GuideIndexRepository {
  const _Guide();

  @override
  AsyncEither<List<GuideModule>> fetchGuideIndex() => AsyncEither.of([
    GuideModule(
      title: '最新热门',
      view: 'hot',
      moreUrl: '$baseUrl/forum.php?mod=guide&view=hot',
      items: [
        for (final (i, (title, forum, extra, highlighted)) in [
          ('【汉化】春日影 第三卷 完结，附全卷合集与勘误表', '轻小说', '32 人参与', false),
          ('十一月新番中期感想：哪部最让你意外？', '动漫番剧', '18 人参与', false),
          ('年末同人展报名开始，摊位抽签说明', '论坛大厅', '41 人参与', true),
          ('练习一个月的厚涂，求指点', '原创绘图', '9 人参与', false),
        ].indexed)
          GuideItem(
            tid: '${9000 + i}',
            title: title,
            url: '$baseUrl/forum.php?mod=viewthread&tid=${9000 + i}',
            fid: '${10 + i}',
            forumName: forum,
            extra: extra,
            highlighted: highlighted,
          ),
      ],
    ),
    for (final (view, title) in [('digest', '最新精华'), ('new', '最新回复'), ('newthread', '最新发表')])
      GuideModule(title: title, view: view, moreUrl: '$baseUrl/forum.php?mod=guide&view=$view', items: const []),
  ]);
}

Translations get tr => LocaleSettings.instance.currentTranslations;

Future<void> _settle(WidgetTester tester, {int rounds = 4}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The top of the phone homepage: the greeting, the support entry and the guide, on the page padding.
class _Home extends StatelessWidget {
  const _Home({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.t.homepage.title)),
    body: ListView(
      padding: EdgeInsets.fromLTRB(compact ? 16 : 24, 12, compact ? 16 : 24, 16),
      children: [
        HomeGreetingCard(
          username: _user.username!,
          uid: _user.uid,
          forumStatus: const ForumStatus(todayCount: '2962', yesterdayCount: '4381', threadCount: '1203557'),
          dailyRedPacket: null,
          formHash: 'f1f2f3f4',
          compact: compact,
        ),
        const SizedBox(height: 12),
        if (compact)
          const HomeSupportCard()
        else
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: HomeForumStatsCard(
                  ForumStatus(todayCount: '2962', yesterdayCount: '4381', threadCount: '1203557'),
                ),
              ),
              SizedBox(width: 16),
              Expanded(child: HomeSupportCard()),
            ],
          ),
        const SizedBox(height: 12),
        const GuideSection(repository: _Guide(), maxCount: 4),
        const SizedBox(height: 12),
        HomeToolsCard(columns: compact ? 3 : 6),
      ],
    ),
  );
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<CheckinBloc> pump(
    WidgetTester tester, {
    required Size size,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    bool compact = true,
    String? fontFamily,
  }) async {
    final auth = _Auth();
    final checkin = CheckinBloc(
      checkinRepository: CheckinRepository(storageProvider: storage),
      authenticationRepository: auth,
      settingsRepository: settings,
    );
    addTearDown(() async {
      await checkin.close();
      await auth.close();
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => _Home(compact: compact),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      RepositoryProvider<AuthenticationRepository>.value(
        value: auth,
        child: BlocProvider<CheckinBloc>.value(
          value: checkin,
          child: TranslationProvider(
            child: Builder(
              builder: (context) => MaterialApp.router(
                theme: brightness == Brightness.light
                    ? AppTheme.makeLight(context, seedColor: null, fontFamily: fontFamily ?? '')
                    : AppTheme.makeDark(context, seedColor: null, fontFamily: fontFamily ?? ''),
                locale: AppLocale.zhTw.flutterLocale,
                supportedLocales: AppLocaleUtils.supportedLocales,
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                routerConfig: router,
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    return checkin;
  }

  Finder action(String label) =>
      find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).first;

  /// The color the button is painted with.
  Color? background(WidgetTester tester, Finder button) =>
      tester.widget<Material>(find.descendant(of: button, matching: find.byType(Material)).first).color;

  group('1. the greeting', () {
    testWidgets('a phone: four tiles on one row, the check-in the filled one; no card around the greeting', (
      tester,
    ) async {
      await pump(tester, size: const Size(390, 900));
      final labels = [
        tr.homepage.welcome.checkin,
        tr.redPacket.daily.unavailable,
        tr.activitiesPage.title,
        tr.medalTitleHub.title,
      ];
      final rects = [for (final label in labels) tester.getRect(action(label))];
      for (final rect in rects.skip(1)) {
        expect(rect.top, closeTo(rects.first.top, 0.5), reason: 'one row');
        expect(rect.height, closeTo(rects.first.height, 0.5), reason: 'the same height');
      }
      expect(rects.first.height, greaterThanOrEqualTo(72), reason: 'tiles, 72 high');
      // Icon over the label.
      final icon = tester.getRect(find.descendant(of: action(labels[2]), matching: find.byType(Icon)));
      expect(icon.bottom, lessThanOrEqualTo(tester.getRect(find.text(labels[2])).top));

      final colorScheme = Theme.of(tester.element(find.byType(HomeGreetingCard))).colorScheme;
      final surfaces = AppSurfaces.of(tester.element(find.byType(HomeGreetingCard)));
      expect(background(tester, action(labels[0])), colorScheme.primary, reason: 'the one filled action');
      for (final label in labels.skip(1)) {
        expect(background(tester, action(label)), surfaces.card, reason: '$label on a panel');
      }
      expect(
        find.ancestor(of: find.byType(HomeGreetingCard), matching: find.byType(Card)),
        findsNothing,
        reason: 'the page itself',
      );
      expect(
        find.descendant(of: find.byType(HomeGreetingCard), matching: find.byType(Card)),
        findsNothing,
        reason: 'not a card',
      );
      // The number of the today count is bold in the primary color.
      final today = tester.widget<RichText>(
        find.descendant(of: find.byType(HomeGreetingCard), matching: find.byType(RichText)).at(2),
      );
      final spans = <TextSpan>[];
      today.text.visitChildren((span) {
        if (span is TextSpan) {
          spans.add(span);
        }
        return true;
      });
      final number = spans.firstWhere((e) => e.text == '2962');
      expect(number.style?.color, colorScheme.primary);
      expect(number.style?.fontWeight, FontWeight.w700);
      expect(spans.map((e) => e.text ?? '').join(), tr.homepage.todayPosts(count: '2962'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('checked in: the panel look with a filled check, the label not dimmed', (tester) async {
      await storage.saveCookie(
        username: _user.username!,
        uid: _user.uid!,
        cookie: {'.domains': '{"${_user.username}":1}', '${cookiePrefix}_auth': 'yamato'},
      );
      await storage.updateLastCheckinTime(_user.uid!, DateTime.now()).run();
      final checkin = await pump(tester, size: const Size(390, 900));
      checkin.add(const CheckinStatusRequested());
      await _settle(tester);
      final done = action(tr.homepage.welcome.checkedIn);
      final surfaces = AppSurfaces.of(tester.element(find.byType(HomeGreetingCard)));
      final style = tester.widget<ButtonStyleButton>(done).style!;
      expect(tester.widget<ButtonStyleButton>(done).onPressed, isNull, reason: 'no second check-in');
      expect(style.backgroundColor?.resolve({WidgetState.disabled}), surfaces.card);
      expect(
        style.foregroundColor?.resolve({WidgetState.disabled}),
        Theme.of(tester.element(done)).colorScheme.onSurface,
      );
      expect(find.descendant(of: done, matching: find.byIcon(Icons.check_circle)), findsOneWidget);
      expect(tester.getRect(done).height, greaterThanOrEqualTo(72), reason: 'still a tile');
    });

    testWidgets('large text: two columns, icons before the labels, nothing cut or overflowing', (tester) async {
      await pump(tester, size: const Size(390, 1200), textScale: 1.6);
      final checkin = tester.getRect(action(tr.homepage.welcome.checkin));
      final packet = tester.getRect(action(tr.redPacket.daily.unavailable));
      final activities = tester.getRect(action(tr.activitiesPage.title));
      final medals = tester.getRect(action(tr.medalTitleHub.title));
      expect(packet.top, closeTo(checkin.top, 0.5));
      expect(activities.top, greaterThan(checkin.bottom), reason: 'a second row');
      expect(medals.top, closeTo(activities.top, 0.5));
      expect(packet.left, greaterThan(checkin.right), reason: 'two columns');
      final icon = tester.getRect(find.descendant(of: action(tr.activitiesPage.title), matching: find.byType(Icon)));
      expect(icon.right, lessThanOrEqualTo(tester.getRect(find.text(tr.activitiesPage.title)).left));
      expect(tester.takeException(), isNull);
    });

    testWidgets('desktop: the four actions are pills under the today count', (tester) async {
      await pump(tester, size: const Size(960, 900), compact: false);
      final checkin = tester.getRect(action(tr.homepage.welcome.checkin));
      final medals = tester.getRect(action(tr.medalTitleHub.title));
      expect(medals.top, closeTo(checkin.top, 6), reason: 'one row');
      expect(checkin.height, lessThan(60), reason: 'pills, not tiles');
      expect(
        checkin.top,
        greaterThan(
          tester
              .getRect(find.descendant(of: find.byType(HomeGreetingCard), matching: find.textContaining('2962')))
              .bottom,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('2. the forum guide', () {
    testWidgets('flat: no card, the sofa entry beside the title, hairlines between the rows', (tester) async {
      await pump(tester, size: const Size(390, 1400));
      expect(find.descendant(of: find.byType(GuideSection), matching: find.byType(Card)), findsNothing);
      final title = tester.getRect(find.text(tr.homepage.guideTitle));
      final sofa = tester.getRect(find.byKey(const ValueKey('guide-sofa')));
      expect(sofa.center.dy, closeTo(title.center.dy, 8), reason: 'in the title row');
      expect(sofa.left, greaterThan(title.left));
      final row = tester.getRect(find.text('十一月新番中期感想：哪部最让你意外？'));
      expect(row.left, closeTo(title.left, 0.5), reason: 'the rows start where the title does');
      final line = AppSurfaces.of(tester.element(find.byType(GuideSection))).line;
      expect(
        tester
            .widgetList<Divider>(find.descendant(of: find.byType(GuideSection), matching: find.byType(Divider)))
            .every((e) => e.color == line),
        isTrue,
      );
      expect(tester.takeException(), isNull);
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
    });

    for (final (name, size, compact, scale) in [
      ('phone', const Size(390, 1400), true, 1.0),
      ('phone-1.3x', const Size(390, 1500), true, 1.3),
      ('desktop', const Size(960, 1200), false, 1.0),
    ]) {
      for (final brightness in Brightness.values) {
        testWidgets('home $name ${brightness.name}', (tester) async {
          await pump(
            tester,
            size: size,
            textScale: scale,
            brightness: brightness,
            compact: compact,
            fontFamily: family,
          );
          expect(tester.takeException(), isNull);
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);
          final image = await tester.runAsync(boundary.toImage);
          final bytes = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
          File('$dir/home-$name-${brightness.name}.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        }, skip: skip != null);
      }
    }
  });
}
