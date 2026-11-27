/// Three looks reported from screenshots.
///
/// * The swiper of the homepage takes the height of its pictures' shape: 16:9 before one is known, the shape of the
///   first picture between 4:3 and 4:1, never lower than 96 nor higher than 220.
/// * The content surfaces have a faint line around them in a light theme ([appSurfaceShape]), the same one the floors
///   of a thread had; none in a dark theme, none on a surface inside another, none on the cards of the theme
///   (dialogs, menus).
/// * The moderators of a forum group stand on a soft tone of the primary color, every text pair on it readable for
///   the default color and a cyan, a pink and a purple seed, light and dark.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/homepage/widgets/widgets.dart';
import 'package:tsdm_client/features/topics/widgets/group_moderators_row.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

final class _FakeContext extends Fake implements BuildContext {}

const _seeds = <String, Color?>{
  'default': null,
  'cyan': Color(0xFF069DC7),
  'pink': Color(0xFFE05C9A),
  'purple': Color(0xFF7C5CD6),
};

ThemeData _theme(Color? seed, {required bool dark}) => dark
    ? AppTheme.makeDark(_FakeContext(), seedColor: seed, fontFamily: '')
    : AppTheme.makeLight(_FakeContext(), seedColor: seed, fontFamily: '');

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  // Outside the fake clock of the widget tests: a language is loaded with real async work.
  setUpAll(() => LocaleSettings.setLocale(AppLocale.zhCn));

  group('the swiper of the homepage', () {
    test('16:9 before a picture told its shape', () {
      expect(homeBannerHeight(), closeTo(168.75, 0.01));
      expect(homeBannerDefaultRatio, closeTo(16 / 9, 1e-9));
    });

    test('the shape of the picture gives the height, between 96 and 220', () {
      // The banners of the screenshots: about 1.5:1 to 1.7:1.
      expect(homeBannerHeight(ratio: 1.5), closeTo(200, 0.01));
      expect(homeBannerHeight(ratio: 1.7), closeTo(176.47, 0.01));
      expect(homeBannerHeight(ratio: 16 / 9), closeTo(168.75, 0.01));
      expect(homeBannerHeight(ratio: 3), closeTo(100, 0.01));
      // 4:3 would be 225: held at the most.
      expect(homeBannerHeight(ratio: 4 / 3), 220);
      // 4:1 would be 75: held at the least.
      expect(homeBannerHeight(ratio: 4), 96);
    });

    test('from 4:3 to 4:1 a picture shapes the swiper; outside of it the default stays', () {
      expect(homeBannerRatioAccepted(const Size(400, 300)), isTrue, reason: '4:3');
      expect(homeBannerRatioAccepted(const Size(750, 500)), isTrue, reason: '1.5:1');
      expect(homeBannerRatioAccepted(const Size(1700, 1000)), isTrue, reason: '1.7:1');
      expect(homeBannerRatioAccepted(const Size(1600, 400)), isTrue, reason: '4:1');
      expect(homeBannerRatioAccepted(const Size(390, 300)), isFalse, reason: 'a little taller than 4:3');
      expect(homeBannerRatioAccepted(const Size(300, 600)), isFalse, reason: 'a poster');
      expect(homeBannerRatioAccepted(const Size(2000, 400)), isFalse, reason: 'a strip');
      expect(homeBannerRatioAccepted(Size.zero), isFalse);
      expect(homeBannerHeight(ratio: 0.5), closeTo(168.75, 0.01));
      expect(homeBannerHeight(ratio: 5), closeTo(168.75, 0.01));
    });
  });

  group('the faint line of the surfaces', () {
    Future<void> pump(WidgetTester tester, {required bool dark, required Widget child}) => tester.pumpWidget(
      MaterialApp(
        theme: _theme(null, dark: dark),
        home: Scaffold(body: child),
      ),
    );

    RoundedRectangleBorder shapeOf(WidgetTester tester, Key key) =>
        tester.widget<Card>(find.descendant(of: find.byKey(key), matching: find.byType(Card)).first).shape!
            as RoundedRectangleBorder;

    const outer = ValueKey('outer');
    const inner = ValueKey('inner');
    const nested = AppSurface(
      key: outer,
      child: AppSurface(key: inner, child: Text('a card in a card')),
    );

    testWidgets('light: the line of the theme, one pixel; a surface inside another has none', (tester) async {
      await pump(tester, dark: false, child: nested);
      final line = AppSurfaces.ofTheme(_theme(null, dark: false)).line;
      final shape = shapeOf(tester, outer);
      expect(shape.side.color, line);
      expect(shape.side.width, 1);
      expect(shape.side.style, BorderStyle.solid);
      expect(shape.borderRadius, BorderRadius.circular(appSurfaceRadius));
      expect(shapeOf(tester, inner).side, BorderSide.none, reason: 'no second line inside');
    });

    testWidgets('dark: none', (tester) async {
      await pump(tester, dark: true, child: nested);
      expect(shapeOf(tester, outer).side, BorderSide.none);
      expect(shapeOf(tester, inner).side, BorderSide.none);
    });

    testWidgets('a floor (a card built by hand, marked as a surface) keeps what is in it without a line', (
      tester,
    ) async {
      await pump(
        tester,
        dark: false,
        child: Builder(
          builder: (context) => Card(
            key: outer,
            shape: appSurfaceShape(context),
            child: const AppSurfaceScope(
              child: AppSurface(key: inner, child: Text('a card in a floor')),
            ),
          ),
        ),
      );
      expect(tester.widget<Card>(find.byKey(outer)).shape, isA<RoundedRectangleBorder>());
      expect((tester.widget<Card>(find.byKey(outer)).shape! as RoundedRectangleBorder).side.width, 1);
      expect(shapeOf(tester, inner).side, BorderSide.none);
    });

    test('the cards of the theme (dialogs, menus, a plain Card) have none, in every theme', () {
      for (final seed in _seeds.values) {
        for (final dark in [false, true]) {
          expect((_theme(seed, dark: dark).cardTheme.shape! as RoundedRectangleBorder).side, BorderSide.none);
          expect(appSurfaceShapeOf().side, BorderSide.none);
        }
      }
    });

    test('the line is seen on the card and on the page, and is no heavy frame', () {
      for (final MapEntry(key: name, value: seed) in _seeds.entries) {
        final s = AppSurfaces.ofTheme(_theme(seed, dark: false));
        expect(_contrast(s.line, s.page), greaterThan(1.15), reason: '$name: seen on the page');
        expect(_contrast(s.line, s.card), greaterThan(1.05), reason: '$name: seen on the card');
        expect(_contrast(s.line, s.page), lessThan(1.6), reason: '$name: faint');
      }
    });
  });

  group('the moderators of a forum group', () {
    for (final MapEntry(key: name, value: seed) in _seeds.entries) {
      for (final dark in [false, true]) {
        final label = '$name ${dark ? 'dark' : 'light'}';
        test('$label: a soft tone of the primary color, every pair readable', () {
          final theme = _theme(seed, dark: dark);
          final scheme = theme.colorScheme;
          final surfaces = AppSurfaces.ofTheme(theme);
          final colors = groupModeratorsColors(theme);
          expect(colors.background.a, 1, reason: 'opaque');
          expect(colors.background, isNot(surfaces.inset), reason: 'not the gray of the quotes');
          expect(colors.background, isNot(surfaces.card));
          // Label and icon on the block, a name on its chip, the chip's icon on it.
          expect(_contrast(colors.foreground, colors.background), greaterThanOrEqualTo(4.5), reason: 'label');
          expect(_contrast(scheme.onSurface, colors.chip), greaterThanOrEqualTo(4.5), reason: 'name');
          expect(_contrast(scheme.onSurfaceVariant, colors.chip), greaterThanOrEqualTo(3), reason: 'chip icon');
          // The chips stand out of the block.
          expect(_contrast(colors.chip, colors.background), greaterThan(1.05), reason: 'chip on block');
          // Closer to the card than the primary container itself: soft.
          final soft = _contrast(colors.background, surfaces.card);
          expect(soft, lessThan(_contrast(scheme.primaryContainer, surfaces.card)), reason: 'softer than it');
          expect(colors.line, dark ? isNull : surfaces.line);
        });
      }
    }

    testWidgets('drawn with those colors: the line in a light theme only, the names as chips', (tester) async {
      for (final dark in [false, true]) {
        final theme = _theme(null, dark: dark);
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              theme: theme,
              home: const Scaffold(
                body: GroupModeratorsRow(moderators: ['Alice', 'Bob']),
              ),
            ),
          ),
        );
        // The app eases from one theme to the next.
        await tester.pumpAndSettle();
        final colors = groupModeratorsColors(theme);
        final box = tester.widget<DecoratedBox>(find.byKey(const ValueKey('group-moderators')));
        final decoration = box.decoration as BoxDecoration;
        expect(decoration.color, colors.background);
        expect(decoration.borderRadius, BorderRadius.circular(appInnerRadius));
        expect(decoration.border == null, dark, reason: dark ? 'no line in the dark' : 'the line of the cards');
        if (!dark) {
          expect((decoration.border! as Border).top.color, colors.line);
          expect((decoration.border! as Border).top.width, 1);
        }
        expect(tester.widget<Icon>(find.byIcon(Icons.admin_panel_settings_outlined)).color, colors.foreground);
        final chips = tester.widgetList<ActionChip>(find.byType(ActionChip)).toList();
        expect(chips, hasLength(2));
        expect(chips.every((e) => e.backgroundColor == colors.chip), isTrue);
        expect(find.text('Alice'), findsOneWidget);
      }
    });
  });
}
