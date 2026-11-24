/// Reading layout (設定 > 外觀 > 閱讀排版): line height (1.2–2.0), paragraph spacing, and the widest the floors of a
/// thread grow (`threadContentMaxWidth`: 600–1200, or none, the default):
///
/// * none keeps the widths the app had: floors at most 920, their content at most 712;
/// * a width set lets the floors grow to it, their content to it less the floor's padding, and the line width the
///   paragraphs are cut by follows (`postContentLineWidthIn`);
/// * the html of a post's content is laid out that wide, the html of a forum's rules or a notice is not;
/// * one dialog picks the three, with a slider of the widths ending at none; on a screen narrower than the least width
///   the width slider is not offered;
/// * the width is tied to the screen: saved, never synced.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/widgets/thread_content_layout_dialog.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// A paragraph far longer than any line.
final String _long = '长' * 400;

/// The widest box laid out by the html renderer under [finder].
double _contentMaxWidth(WidgetTester tester, Finder finder) => tester
    .widgetList<ConstrainedBox>(find.descendant(of: finder, matching: find.byType(ConstrainedBox)))
    .map((box) => box.constraints.maxWidth)
    .firstWhere((w) => w.isFinite);

/// The value the dialog popped.
final class _Picked {
  PostTypography? value;
}

/// Open the dialog with [initial] in a window of [size].
Future<_Picked> _openDialog(WidgetTester tester, PostTypography initial, {required Size size}) async {
  final picked = _Picked();
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () async => picked.value = await showDialog<PostTypography>(
              context: context,
              builder: (_) => ThreadContentLayoutDialog(initial: initial, contentScale: 1),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return picked;
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('PostTypography.maxWidth', () {
    test('none by default: the content as wide as the web page', () {
      const typography = PostTypography();
      expect(typography.maxWidth, 0);
      expect(typography.contentMaxWidth, htmlContentMaxWidth);
      expect(SettingsKeys.threadContentMaxWidth.defaultValue, 0);
    });

    test('a width set: the content that wide less the padding of the floor', () {
      expect(const PostTypography(maxWidth: 1200).contentMaxWidth, 1200 - floorPadding);
      expect(const PostTypography(maxWidth: 600).contentMaxWidth, 600 - floorPadding);
    });

    test('kept by withLineWidth, compared, clamped into 600–1200 or none', () {
      const typography = PostTypography(maxWidth: 900);
      expect(typography.withLineWidth(30).maxWidth, 900);
      expect(typography, isNot(const PostTypography()));
      expect(const PostTypography().withMaxWidth(900), typography);
      expect(const PostTypography(maxWidth: 300).clamped().maxWidth, 600);
      expect(const PostTypography(maxWidth: 5000).clamped().maxWidth, 1200);
      expect(const PostTypography(maxWidth: -1).clamped().maxWidth, 0);
    });

    test('the line height goes down to 1.2', () {
      expect(PostTypography.minLineHeight, 1.2);
      expect(const PostTypography(lineHeight: 1).clamped().lineHeight, 1.2);
    });
  });

  group('ReadingWidthScope', () {
    Future<BuildContext> pumpScope(WidgetTester tester, double? maxWidth, {double width = 1900}) async {
      tester.view
        ..physicalSize = Size(width, 1000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late BuildContext inner;
      final probe = Builder(
        builder: (context) {
          inner = context;
          return const SizedBox();
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: maxWidth == null ? probe : ReadingWidthScope(maxWidth: maxWidth, child: probe),
        ),
      );
      return inner;
    }

    testWidgets('none or 0: the widths of the app', (tester) async {
      for (final maxWidth in [null, 0.0]) {
        final context = await pumpScope(tester, maxWidth);
        expect(ReadingWidthScope.floorOf(context), appReadingMaxWidth);
        expect(ReadingWidthScope.contentOf(context), htmlContentMaxWidth);
        // Floors 1900 less their margins, at most 920; content at most 712, over 14 a character.
        expect(postContentLineWidthIn(context, 1900), closeTo(htmlContentMaxWidth / 14, 1e-9));
      }
    });

    testWidgets('a width set: the floors and the lines that wide', (tester) async {
      final context = await pumpScope(tester, 1200);
      expect(ReadingWidthScope.floorOf(context), 1200);
      expect(ReadingWidthScope.contentOf(context), 1200 - floorPadding);
      expect(postContentLineWidthIn(context, 1900), closeTo((1200 - floorPadding) / 14, 1e-9));
      // Narrower than the width: the window decides, as before.
      expect(postContentLineWidthIn(context, 700), closeTo((700 - 32 - floorPadding) / 14, 1e-9));

      final narrow = await pumpScope(tester, 600);
      expect(postContentLineWidthIn(narrow, 1900), closeTo((600 - floorPadding) / 14, 1e-9));
    });
  });

  group('the html of a post', () {
    Future<void> pumpHtml(WidgetTester tester, PostTypography typography, {bool postContent = true}) async {
      tester.view
        ..physicalSize = const Size(1900, 1000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: PostTypographyScope(
                  typography: typography,
                  postContent: postContent,
                  child: MunchedHtml(_long, key: const ValueKey('html')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    final html = find.byKey(const ValueKey('html'));

    testWidgets('laid out as wide as the floors are let grow', (tester) async {
      await pumpHtml(tester, const PostTypography());
      expect(_contentMaxWidth(tester, html), htmlContentMaxWidth);
      expect(
        tester.getSize(find.descendant(of: html, matching: find.byType(RichText)).first).width,
        lessThanOrEqualTo(712),
      );

      await pumpHtml(tester, const PostTypography(maxWidth: 1200));
      expect(_contentMaxWidth(tester, html), 1200 - floorPadding);
      expect(
        tester.getSize(find.descendant(of: html, matching: find.byType(RichText)).first).width,
        greaterThan(htmlContentMaxWidth),
        reason: 'the long paragraph fills the wider content',
      );
    });

    testWidgets('html outside a post (a notice) keeps the width of the web page', (tester) async {
      await pumpHtml(tester, const PostTypography(maxWidth: 1200), postContent: false);
      expect(_contentMaxWidth(tester, html), 1200 - floorPadding, reason: 'laid out as the scope says');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MunchedHtml(_long, key: const ValueKey('html'))),
        ),
      );
      await tester.pump();
      expect(_contentMaxWidth(tester, html), htmlContentMaxWidth, reason: 'no post typography: as before');
    });
  });

  group('the setting', () {
    late AppDatabase db;
    late SettingsRepository settings;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      settings = SettingsRepository(StorageProvider(db, {}, {}));
      await settings.init();
    });

    tearDown(() async {
      await settings.dispose();
      await db.close();
    });

    test('saved and read back, not part of the typography of html outside the thread page', () async {
      expect(settings.currentSettings.threadContentMaxWidth, 0);
      await settings.setValue<double>(SettingsKeys.threadContentMaxWidth, 1000);
      expect(settings.currentSettings.threadContentMaxWidth, 1000);
      // The rules of a forum, a self introduction lay out with the settings' typography: no width there.
      expect(settings.currentSettings.postTypography.maxWidth, 0);
    });

    test('a width out of range (an old backup, written by hand) is clamped where it is used', () async {
      for (final (saved, used) in [(20.0, 600.0), (5000.0, 1200.0), (-3.0, 0.0), (900.0, 900.0)]) {
        await settings.setValue<double>(SettingsKeys.threadContentMaxWidth, saved);
        expect(settings.currentSettings.readingMaxWidth, used, reason: '$saved');
      }
    });

    test('tied to the screen: never synced', () {
      expect([for (final s in syncedSettings) s.key], isNot(contains(SettingsKeys.threadContentMaxWidth)));
    });
  });

  group('the dialog', () {
    testWidgets('picks a width, none at the end of the slider, reset to none', (tester) async {
      final picked = await _openDialog(tester, const PostTypography(), size: const Size(1400, 1000));
      final tr = t.settingsPage.appearanceSection.threadContentLayout;
      expect(find.text(tr.maxWidth), findsOneWidget);
      expect(find.text(tr.unlimited), findsOneWidget, reason: 'none by default');

      final sliders = find.byType(Slider);
      expect(sliders, findsNWidgets(3));
      final lineHeight = tester.widget<Slider>(sliders.at(0));
      expect(lineHeight.min, 1.2);
      expect(lineHeight.divisions, 8);
      final width = tester.widget<Slider>(sliders.at(2));
      expect(width.divisions, 7);
      expect(width.value, 7, reason: 'none is the last position');

      width.onChanged!(4);
      await tester.pump();
      expect(find.text('1000'), findsWidgets);

      await tester.tap(find.text(t.general.reset));
      await tester.pump();
      expect(tester.widget<Slider>(sliders.at(2)).value, 7);

      tester.widget<Slider>(sliders.at(2)).onChanged!(0);
      tester.widget<Slider>(sliders.at(0)).onChanged!(1.2);
      await tester.pump();
      await tester.tap(find.text(t.general.ok));
      await tester.pumpAndSettle();
      expect(picked.value, const PostTypography(lineHeight: 1.2, maxWidth: 600));
    });

    testWidgets('a width set opens at its position', (tester) async {
      await _openDialog(tester, const PostTypography(maxWidth: 1100), size: const Size(1400, 1000));
      expect(tester.widget<Slider>(find.byType(Slider).at(2)).value, 5);
      expect(find.text('1100'), findsWidgets);
    });

    testWidgets('no width slider on a phone, the width kept', (tester) async {
      final picked = await _openDialog(tester, const PostTypography(maxWidth: 800), size: const Size(390, 844));
      expect(find.byType(Slider), findsNWidgets(2));
      expect(find.text(t.settingsPage.appearanceSection.threadContentLayout.maxWidth), findsNothing);
      // Reset: the width it does not offer stays.
      await tester.tap(find.text(t.general.reset));
      await tester.pump();
      await tester.tap(find.text(t.general.ok));
      await tester.pumpAndSettle();
      expect(picked.value?.maxWidth, 800);
      expect(picked.value?.lineHeight, PostTypography.defaultLineHeight);
    });
  });
}
