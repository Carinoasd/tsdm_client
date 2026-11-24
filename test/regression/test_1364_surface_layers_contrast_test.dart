/// The surface layers of the theme ([AppSurfaces]) and the contrast of the main text pairs on them, computed on the
/// real colors of the app themes for the default color, a cyan, a pink and a purple seed in the light and dark
/// themes:
///
/// 1. one algorithm for every color: the default (no seed) is the scheme of [AppTheme.defaultSeedColor] as a chosen
///    color would be, and the page, bars and cards of the theme are the layers of [AppSurfaces];
/// 2. the layers go the same way for every seed: in a dark theme a card is lighter than the page, in a light theme
///    a white card on a darker page; cards have no border;
/// 3. every text pair of the design is at least 4.5:1 (body, secondary and meta text on every layer, primary text,
///    the hero card, tags, buttons);
/// 4. meta text is the on surface variant color, no longer the outline (4.07:1 on a card of the light theme before).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/utils/html/author_style.dart';

final class _FakeContext extends Fake implements BuildContext {}

const _seeds = <String, Color?>{
  'default': null,
  'cyan': Color(0xFF069DC7),
  'pink': Color(0xFFE05C9A),
  'purple': Color(0xFF7C5CD6),
};

/// Least contrast of a text pair.
const _textContrast = 4.5;

double _luminance(Color c) => c.computeLuminance();

void main() {
  for (final MapEntry(key: name, value: seed) in _seeds.entries) {
    for (final dark in [false, true]) {
      final label = '$name ${dark ? 'dark' : 'light'}';
      ThemeData theme() => dark
          ? AppTheme.makeDark(_FakeContext(), seedColor: seed, fontFamily: '')
          : AppTheme.makeLight(_FakeContext(), seedColor: seed, fontFamily: '');

      group(label, () {
        test('one algorithm: the scheme of the seed, the layers on the theme', () {
          final t = theme();
          final scheme = t.colorScheme;
          final expected = ColorScheme.fromSeed(
            seedColor: seed ?? AppTheme.defaultSeedColor,
            brightness: dark ? Brightness.dark : Brightness.light,
          );
          expect(scheme.primary, expected.primary);
          expect(scheme.surfaceContainerLowest, expected.surfaceContainerLowest);
          expect(scheme.surfaceContainer, expected.surfaceContainer);

          final s = t.extension<AppSurfaces>();
          expect(s, isNotNull);
          expect(t.scaffoldBackgroundColor, s!.page);
          expect(t.appBarTheme.backgroundColor, s.page);
          expect(t.navigationRailTheme.backgroundColor, s.page);
          expect(t.navigationBarTheme.backgroundColor, s.bar);
          expect(t.cardTheme.color, s.card);
          expect(s.hero, scheme.primaryContainer);
          final shape = t.cardTheme.shape! as RoundedRectangleBorder;
          expect(shape.side, BorderSide.none);
        });

        test('layers: card lighter than the page, inset and control apart from the card', () {
          final s = AppSurfaces.ofTheme(theme());
          expect(_luminance(s.card), greaterThan(_luminance(s.page)));
          expect(s.inset, isNot(s.card));
          expect(s.control, isNot(s.inset));
          if (dark) {
            expect(_luminance(s.inset), greaterThan(_luminance(s.card)));
            expect(_luminance(s.control), greaterThan(_luminance(s.inset)));
          } else {
            expect(s.card, const Color(0xFFFFFFFF), reason: 'white cards on a gray page');
            expect(_luminance(s.inset), lessThan(_luminance(s.card)));
            expect(_luminance(s.control), lessThan(_luminance(s.inset)));
          }
          for (final c in [s.page, s.card, s.inset, s.control, s.bar, s.hero]) {
            expect(c.a, 1, reason: 'no translucent layer');
          }
        });

        test('text pairs are at least $_textContrast:1', () {
          final t = theme();
          final c = t.colorScheme;
          final s = AppSurfaces.ofTheme(t);
          final pairs = <String, (Color, Color)>{
            'body / card': (c.onSurface, s.card),
            'body / inset (quote)': (c.onSurface, s.inset),
            'secondary / card': (c.onSurfaceVariant, s.card),
            'secondary / inset': (c.onSurfaceVariant, s.inset),
            'secondary / page': (c.onSurfaceVariant, s.page),
            'secondary / control': (c.onSurfaceVariant, s.control),
            'secondary / bar': (c.onSurfaceVariant, s.bar),
            'primary / card': (c.primary, s.card),
            'primary / page': (c.primary, s.page),
            'primary / control': (c.primary, s.control),
            'primary / hero': (c.primary, s.hero),
            'hero text': (s.onHero, s.hero),
            'tag': (c.onSecondaryContainer, c.secondaryContainer),
            'pill / control': (c.onSurface, s.control),
            'on primary / primary (check-in)': (c.onPrimary, c.primary),
            'hero action label / card': (c.onSurface, s.card),
          };
          for (final MapEntry(key: pair, value: (fg, bg)) in pairs.entries) {
            expect(contrastRatio(fg, bg), greaterThanOrEqualTo(_textContrast), reason: '$label $pair');
          }
        });
      });
    }
  }

  test('a bare theme gets the same layers from its color scheme', () {
    final t = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF069DC7)));
    expect(t.extension<AppSurfaces>(), isNull);
    final s = AppSurfaces.ofTheme(t);
    expect(s.card, t.colorScheme.surfaceContainerLowest);
    expect(s.page, t.colorScheme.surfaceContainer);
  });

  test('the cyan seed of the design: dark primary as measured on the device', () {
    final t = AppTheme.makeDark(_FakeContext(), seedColor: const Color(0xFF069DC7), fontFamily: '');
    expect(t.colorScheme.primary, const Color(0xFF8BD0EF));
  });
}
