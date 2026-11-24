/// The global part of the second design (`tokens-v2.md` sections 2, 4, 5 and items 5, 6, 14 of section 9), on the real
/// app themes, light and dark:
///
/// 1. two weights: every style of the text theme is 400 or 700 with tabular figures; titles and the large label
///    (buttons) bold, the small labels regular; the app bar title is 20 and bold, in the text color;
/// 2. icons: weight 400, grade -25 in the dark theme (0 in the light one);
/// 3. navigation (bar, rail, drawer): the selected destination on the primary container, its icon filled in the on
///    primary container color, its label bold; the others regular;
/// 4. settings groups: rows 52 high, the line between two rows starts at the text (after a leading icon), corners 20.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';

final class _FakeContext extends Fake implements BuildContext {}

ThemeData _theme({required bool dark}) => dark
    ? AppTheme.makeDark(_FakeContext(), seedColor: null, fontFamily: '')
    : AppTheme.makeLight(_FakeContext(), seedColor: null, fontFamily: '');

const List<FontWeight> _twoWeights = [FontWeight.w400, FontWeight.w700];

Widget _app(ThemeData theme, Widget child) => MaterialApp(theme: theme, home: child);

/// The text style of the [Text] reading [text], as painted.
TextStyle _paintedStyle(WidgetTester tester, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
  return paragraph.text.style!;
}

void main() {
  test('no weight of 500 or 600 is left in the app', () {
    final offenders = [
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') && !file.path.endsWith('.g.dart'))
          if (RegExp(r'FontWeight\.w[56]00').hasMatch(file.readAsStringSync())) file.path,
    ];
    expect(offenders, isEmpty);
  });

  test('the navigation, the homepage, "me" and the floors use the rounded Material Symbols', () {
    const files = [
      'lib/features/home/widgets/widgets.dart',
      'lib/features/homepage/view/homepage_page.dart',
      'lib/features/homepage/widgets/home_dashboard.dart',
      'lib/features/homepage/widgets/guide_section.dart',
      'lib/features/homepage/widgets/guest_home.dart',
      'lib/features/checkin/widgets/checkin_button.dart',
      'lib/features/red_packet/widgets/daily_red_packet_button.dart',
      'lib/features/me/view/me_page.dart',
      'lib/widgets/card/post_card/post_card.dart',
    ];
    // Symbols has no glyph for these: they stay Material Icons.
    const kept = {'Icons.catching_pokemon'};
    for (final path in files) {
      final source = File(path).readAsStringSync();
      final icons = RegExp(r'\bIcons\.\w+').allMatches(source).map((e) => e.group(0)).toSet()..removeAll(kept);
      expect(icons, isEmpty, reason: path);
      final notRounded = RegExp(r'\bSymbols\.(\w+)')
          .allMatches(source)
          .map((e) => e.group(1)!)
          .where(
            (e) => !e.endsWith('_rounded'),
          );
      expect(notRounded, isEmpty, reason: path);
    }
  });

  for (final dark in [false, true]) {
    final label = dark ? 'dark' : 'light';

    group(label, () {
      test('the text theme has two weights and tabular figures', () {
        final theme = _theme(dark: dark);
        for (final textTheme in [theme.textTheme, theme.primaryTextTheme]) {
          final styles = {
            'displayLarge': textTheme.displayLarge,
            'displayMedium': textTheme.displayMedium,
            'displaySmall': textTheme.displaySmall,
            'headlineLarge': textTheme.headlineLarge,
            'headlineMedium': textTheme.headlineMedium,
            'headlineSmall': textTheme.headlineSmall,
            'titleLarge': textTheme.titleLarge,
            'titleMedium': textTheme.titleMedium,
            'titleSmall': textTheme.titleSmall,
            'bodyLarge': textTheme.bodyLarge,
            'bodyMedium': textTheme.bodyMedium,
            'bodySmall': textTheme.bodySmall,
            'labelLarge': textTheme.labelLarge,
            'labelMedium': textTheme.labelMedium,
            'labelSmall': textTheme.labelSmall,
          };
          for (final MapEntry(key: name, value: style) in styles.entries) {
            expect(_twoWeights, contains(style?.fontWeight), reason: name);
            expect(style?.fontFeatures, contains(const FontFeature.tabularFigures()), reason: name);
          }
          expect(textTheme.titleMedium?.fontWeight, FontWeight.w700);
          expect(textTheme.titleSmall?.fontWeight, FontWeight.w700);
          expect(textTheme.labelLarge?.fontWeight, FontWeight.w700);
          expect(textTheme.labelMedium?.fontWeight, FontWeight.w400);
          expect(textTheme.labelSmall?.fontWeight, FontWeight.w400);
          expect(textTheme.bodyMedium?.fontWeight, FontWeight.w400);
        }
      });

      test('icons: weight 400, grade -25 in the dark theme', () {
        final theme = _theme(dark: dark);
        for (final icons in [theme.iconTheme, theme.primaryIconTheme, theme.appBarTheme.iconTheme!]) {
          expect(icons.weight, 400);
          expect(icons.grade, dark ? -25 : 0);
        }
      });

      testWidgets('app bar title: 20, bold, in the text color; its icons graded', (tester) async {
        final theme = _theme(dark: dark);
        await tester.pumpWidget(
          _app(
            theme,
            Scaffold(
              appBar: AppBar(
                title: const Text('title'),
                actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.search))],
              ),
            ),
          ),
        );
        final style = _paintedStyle(tester, 'title');
        expect(style.fontSize, 20);
        expect(style.fontWeight, FontWeight.w700);
        expect(style.color, theme.colorScheme.onSurface);
        final icon = tester.element(find.byIcon(Icons.search));
        expect(IconTheme.of(icon).grade, dark ? -25 : 0);
        expect(IconTheme.of(icon).weight, 400);
      });

      testWidgets('chips are regular and keep the colors of Material 3', (tester) async {
        final theme = _theme(dark: dark);
        await tester.pumpWidget(
          _app(
            theme,
            Scaffold(
              body: Row(
                children: [
                  const Chip(label: Text('tag')),
                  FilterChip(label: const Text('on'), selected: true, onSelected: (_) {}),
                ],
              ),
            ),
          ),
        );
        final scheme = theme.colorScheme;
        expect(_paintedStyle(tester, 'tag').fontWeight, FontWeight.w400);
        expect(_paintedStyle(tester, 'tag').color, scheme.onSurfaceVariant);
        expect(_paintedStyle(tester, 'on').color, scheme.onSecondaryContainer);
      });

      testWidgets('menu items are regular: popup menus and menus of a menu anchor', (tester) async {
        final theme = _theme(dark: dark);
        await tester.pumpWidget(
          _app(
            theme,
            Scaffold(
              body: Column(
                children: [
                  PopupMenuButton<int>(
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 1, child: Text('popup item')),
                      PopupMenuItem(enabled: false, value: 2, child: Text('popup disabled')),
                    ],
                  ),
                  MenuAnchor(
                    menuChildren: [MenuItemButton(onPressed: () {}, child: const Text('menu item'))],
                    builder: (context, controller, _) =>
                        TextButton(onPressed: controller.open, child: const Text('open menu')),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.tap(find.byType(PopupMenuButton<int>));
        await tester.pumpAndSettle();
        expect(_paintedStyle(tester, 'popup item').fontWeight, FontWeight.w400);
        expect(_paintedStyle(tester, 'popup item').color, theme.colorScheme.onSurface);
        expect(_paintedStyle(tester, 'popup disabled').fontWeight, FontWeight.w400);
        await tester.tapAt(Offset.zero);
        await tester.pumpAndSettle();
        // Buttons stay bold.
        expect(_paintedStyle(tester, 'open menu').fontWeight, FontWeight.w700);
        await tester.tap(find.text('open menu'));
        await tester.pumpAndSettle();
        expect(_paintedStyle(tester, 'menu item').fontWeight, FontWeight.w400);
      });

      testWidgets('navigation bar: the selected destination on the primary container, filled, bold', (tester) async {
        final theme = _theme(dark: dark);
        await tester.pumpWidget(
          _app(
            theme,
            Scaffold(
              bottomNavigationBar: NavigationBar(
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.home), label: 'one'),
                  NavigationDestination(icon: Icon(Icons.person), label: 'two'),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scheme = theme.colorScheme;
        expect(theme.navigationBarTheme.indicatorColor, scheme.primaryContainer);
        expect(_paintedStyle(tester, 'one').fontWeight, FontWeight.w700);
        expect(_paintedStyle(tester, 'one').color, scheme.onSurface);
        expect(_paintedStyle(tester, 'two').fontWeight, FontWeight.w400);

        final selected = IconTheme.of(tester.element(find.byIcon(Icons.home)));
        expect(selected.color, scheme.onPrimaryContainer);
        expect(selected.fill, 1);
        expect(selected.grade, dark ? -25 : 0);
        final other = IconTheme.of(tester.element(find.byIcon(Icons.person)));
        expect(other.fill, isNot(1));
        expect(other.grade, dark ? -25 : 0);
      });

      testWidgets('navigation rail: as the bar', (tester) async {
        final theme = _theme(dark: dark);
        await tester.pumpWidget(
          _app(
            theme,
            Scaffold(
              body: NavigationRail(
                selectedIndex: 0,
                labelType: NavigationRailLabelType.all,
                destinations: const [
                  NavigationRailDestination(icon: Icon(Icons.home), label: Text('one')),
                  NavigationRailDestination(icon: Icon(Icons.person), label: Text('two')),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scheme = theme.colorScheme;
        expect(theme.navigationRailTheme.indicatorColor, scheme.primaryContainer);
        expect(_paintedStyle(tester, 'one').fontWeight, FontWeight.w700);
        expect(_paintedStyle(tester, 'two').fontWeight, FontWeight.w400);
        final selected = IconTheme.of(tester.element(find.byIcon(Icons.home)));
        expect(selected.color, scheme.onPrimaryContainer);
        expect(selected.fill, 1);
      });

      testWidgets('navigation drawer (desktop): as the bar', (tester) async {
        final theme = _theme(dark: dark);
        await tester.pumpWidget(
          _app(
            theme,
            const Scaffold(
              body: NavigationDrawer(
                children: [
                  NavigationDrawerDestination(icon: Icon(Icons.home), label: Text('one')),
                  NavigationDrawerDestination(icon: Icon(Icons.person), label: Text('two')),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scheme = theme.colorScheme;
        expect(theme.navigationDrawerTheme.indicatorColor, scheme.primaryContainer);
        expect(_paintedStyle(tester, 'one').fontWeight, FontWeight.w700);
        expect(_paintedStyle(tester, 'two').fontWeight, FontWeight.w400);
        final selected = IconTheme.of(tester.element(find.byIcon(Icons.home)));
        expect(selected.color, scheme.onPrimaryContainer);
        expect(selected.fill, 1);
      });

      testWidgets('settings group without icons: the lines start at the start padding', (tester) async {
        await tester.pumpWidget(
          _app(
            _theme(dark: dark),
            const Scaffold(
              body: AppTileGroup(
                children: [
                  SectionListTile(title: Text('a')),
                  SectionListTile(title: Text('b')),
                ],
              ),
            ),
          ),
        );
        expect(tester.widget<Divider>(find.byType(Divider)).indent, 16);
      });

      testWidgets('settings group: rows 52 high, lines from the text, corners 20', (tester) async {
        final theme = _theme(dark: dark);
        await tester.pumpWidget(
          _app(
            theme,
            Scaffold(
              body: SingleChildScrollView(
                child: AppTileGroup(
                  children: [
                    const SectionListTile(leading: Icon(Icons.home), title: Text('a')),
                    SectionSwitchListTile(
                      secondary: const Icon(Icons.person),
                      title: const Text('b'),
                      value: true,
                      onChanged: (_) {},
                    ),
                    const SectionListTile(title: Text('c')),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(tester.getSize(find.byType(SectionListTile).first).height, AppTileGroup.rowHeight);
        expect(tester.getSize(find.byType(SectionListTile).last).height, AppTileGroup.rowHeight);

        final dividers = tester.widgetList<Divider>(find.byType(Divider)).toList();
        expect(dividers, hasLength(2));
        // Above the switch (it leads with an icon): the line starts at its text.
        final textStart = tester.getTopLeft(find.text('b')).dx;
        expect(dividers[0].indent, textStart);
        expect(dividers[0].color, AppSurfaces.ofTheme(theme).line);
        // One start for the group: a row without an icon (or built by a builder) gets the same line.
        expect(dividers[1].indent, textStart);

        final card = tester.widget<Card>(find.byType(Card));
        expect(card.shape, isA<RoundedRectangleBorder>());
        expect((card.shape! as RoundedRectangleBorder).borderRadius, BorderRadius.circular(20));
        expect(appSurfaceRadius, 20);
        expect(card.color ?? theme.cardTheme.color, AppSurfaces.ofTheme(theme).card);
      });
    });
  }
}
