/// The surface layers of the theme ([AppSurfaces]) and the contrast of the main text pairs on them, computed on the
/// real colors of the app themes for the default color, a cyan, a pink and a purple seed in the light and dark
/// themes:
///
/// 1. one algorithm for every color: the accents and text of [ColorScheme.fromSeed], the surfaces replaced by the
///    layers of the seed's hue ([AppSurfaces.forSeed]); the default (no seed) is [AppTheme.defaultSeedColor] as a
///    chosen color would be; page, bars, panels, dialogs and sheets of the theme are the layers;
/// 2. the layers are the swatches of the design (cyan, pink, purple, both themes), a seed of low chroma gets no hue
///    made up in the dark theme;
/// 3. the layers go the same way for every seed: a dark night of the seed's hue with lighter panels, a near white
///    page with gray-tinted panels; panels have no border;
/// 4. every text pair of the design is at least 4.5:1 (body, secondary and meta text on the layers, primary text,
///    containers, buttons).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
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

/// The swatches of the design (`tokens-v2.md` 1.1): page, card, inset, control, line, line strong, muted, bar.
const _swatches = <String, List<int>>{
  'cyan dark': [0xFF0A0F11, 0xFF171C1F, 0xFF212629, 0xFF2C3134, 0xFF333A3E, 0xFF4E565A, 0xFFA4ACB1, 0xFF111619],
  'cyan light': [0xFFFAFCFF, 0xFFEAEEF2, 0xFFDFE3E7, 0xFFD6DBDE, 0xFFCBD3D8, 0xFF9FA7AC, 0xFF4E565A, 0xFFF0F4F8],
  'pink dark': [0xFF130C0F, 0xFF21191C, 0xFF2C2426, 0xFF372E31, 0xFF42363A, 0xFF5F5155, 0xFFB9A7AC, 0xFF1B1416],
  'pink light': [0xFFFFFBFF, 0xFFFAEAED, 0xFFEEDFE2, 0xFFE6D6DA, 0xFFE0CDD2, 0xFFB3A1A6, 0xFF5F5155, 0xFFFFF0F3],
  'purple dark': [0xFF0F0D13, 0xFF1C1B20, 0xFF27252B, 0xFF322F35, 0xFF3B3840, 0xFF57535D, 0xFFAEA9B4, 0xFF16151A],
  'purple light': [0xFFFFFBFF, 0xFFF2ECF4, 0xFFE6E1E9, 0xFFDED8E0, 0xFFD5CFDB, 0xFFA9A4AE, 0xFF57535D, 0xFFF8F2FA],
};

/// Least contrast of a text pair.
const _textContrast = 4.5;

double _luminance(Color c) => c.computeLuminance();

void main() {
  for (final MapEntry(key: name, value: seed) in _seeds.entries) {
    for (final dark in [false, true]) {
      final label = '$name ${dark ? 'dark' : 'light'}';
      final brightness = dark ? Brightness.dark : Brightness.light;
      ThemeData theme() => dark
          ? AppTheme.makeDark(_FakeContext(), seedColor: seed, fontFamily: '')
          : AppTheme.makeLight(_FakeContext(), seedColor: seed, fontFamily: '');

      group(label, () {
        test('one algorithm: the accents of the seed, its hue on the layers, the layers on the theme', () {
          final t = theme();
          final scheme = t.colorScheme;
          final plain = ColorScheme.fromSeed(seedColor: seed ?? AppTheme.defaultSeedColor, brightness: brightness);
          expect(scheme.primary, plain.primary);
          expect(scheme.onSurface, plain.onSurface);
          expect(scheme.onSurfaceVariant, plain.onSurfaceVariant);

          final s = t.extension<AppSurfaces>();
          expect(s, isNotNull);
          final expected = AppTheme.surfacesOf(seed, brightness);
          expect(
            [s!.page, s.card, s.inset, s.control, s.bar, s.line, s.lineStrong, s.muted],
            [
              expected.page,
              expected.card,
              expected.inset,
              expected.control,
              expected.bar,
              expected.line,
              expected.lineStrong,
              expected.muted,
            ],
          );
          expect(scheme.surface, s.page);
          expect(scheme.surfaceContainer, s.card);
          expect(scheme.surfaceContainerHigh, s.inset);
          expect(scheme.surfaceContainerHighest, s.control);
          expect(scheme.surfaceContainerLow, s.bar);
          expect(scheme.outlineVariant, s.line);
          expect(t.scaffoldBackgroundColor, s.page);
          expect(t.appBarTheme.backgroundColor, s.page);
          expect(t.navigationRailTheme.backgroundColor, s.bar);
          expect(t.navigationBarTheme.backgroundColor, s.bar);
          expect(t.cardTheme.color, s.card);
          expect(t.dialogTheme.backgroundColor, s.card);
          expect(t.bottomSheetTheme.backgroundColor, s.card);
          expect(t.popupMenuTheme.color, s.card);
          final shape = t.cardTheme.shape! as RoundedRectangleBorder;
          expect(shape.side, BorderSide.none);
        });

        if (_swatches['$name ${dark ? 'dark' : 'light'}'] case final swatches?) {
          test('the swatches of the design', () {
            final s = AppSurfaces.ofTheme(theme());
            final actual = [s.page, s.card, s.inset, s.control, s.line, s.lineStrong, s.muted, s.bar];
            expect(actual.map((e) => e.toARGB32()).toList(), swatches);
          });
        }

        test('layers: a night of the hue with lighter panels, or a near white page with darker ones', () {
          final s = AppSurfaces.ofTheme(theme());
          if (dark) {
            expect(_luminance(s.card), greaterThan(_luminance(s.page)));
            expect(_luminance(s.bar), greaterThan(_luminance(s.page)));
            expect(_luminance(s.inset), greaterThan(_luminance(s.card)));
            expect(_luminance(s.control), greaterThan(_luminance(s.inset)));
          } else {
            expect(_luminance(s.page), greaterThan(0.9), reason: 'a near white page');
            expect(_luminance(s.card), lessThan(_luminance(s.page)));
            expect(_luminance(s.bar), lessThan(_luminance(s.page)));
            expect(_luminance(s.inset), lessThan(_luminance(s.card)));
            expect(_luminance(s.control), lessThan(_luminance(s.inset)));
          }
          // A layer is told from the one it lies on: steps of 2 tones could not be told apart on a phone.
          for (final (name, over, under) in [
            ('card on page', s.card, s.page),
            ('inset on card', s.inset, s.card),
            ('control on card', s.control, s.card),
          ]) {
            expect(contrastRatio(over, under), greaterThanOrEqualTo(1.1), reason: name);
          }
          for (final c in [s.page, s.card, s.inset, s.control, s.bar, s.line, s.lineStrong]) {
            expect(c.a, 1, reason: 'no translucent layer');
          }
        });

        test('text pairs are at least $_textContrast:1', () {
          final t = theme();
          final c = t.colorScheme;
          final s = AppSurfaces.ofTheme(t);
          final pairs = <String, (Color, Color)>{
            'body / page': (c.onSurface, s.page),
            'body / card': (c.onSurface, s.card),
            'secondary / page': (c.onSurfaceVariant, s.page),
            'secondary / card': (c.onSurfaceVariant, s.card),
            'quote / inset': (c.onSurfaceVariant, s.inset),
            'secondary / control': (c.onSurfaceVariant, s.control),
            'secondary / bar': (c.onSurfaceVariant, s.bar),
            'meta / page': (s.muted, s.page),
            'meta / card': (s.muted, s.card),
            'primary / page': (c.primary, s.page),
            'primary / card': (c.primary, s.card),
            'primary / inset (link in a quote)': (c.primary, s.inset),
            'error / page': (c.error, s.page),
            'on primary / primary (check-in)': (c.onPrimary, c.primary),
            'on primary container / primary container': (c.onPrimaryContainer, c.primaryContainer),
            'on secondary container / secondary container': (c.onSecondaryContainer, c.secondaryContainer),
            'on tertiary container / tertiary container': (c.onTertiaryContainer, c.tertiaryContainer),
          };
          for (final MapEntry(key: pair, value: (fg, bg)) in pairs.entries) {
            expect(contrastRatio(fg, bg), greaterThanOrEqualTo(_textContrast), reason: '$label $pair');
          }
        });
      });
    }
  }

  test('the dark page stays near black whatever the seed', () {
    for (final seed in const [Color(0xFF069DC7), Color(0xFFE05C9A), Color(0xFF7C5CD6), Color(0xFF7A7A80)]) {
      final hct = Hct.fromInt(seed.toARGB32());
      final s = AppSurfaces.forSeed(seed, Brightness.dark);
      expect(s.page.toARGB32(), TonalPalette.of(hct.hue, 6).get(4));
      expect(s.card.toARGB32(), TonalPalette.of(hct.hue, 6).get(10));
    }
  });

  test('a bare theme gets the layers from the surface roles of its color scheme', () {
    final t = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF069DC7)));
    expect(t.extension<AppSurfaces>(), isNull);
    final s = AppSurfaces.ofTheme(t);
    expect(s.page, t.colorScheme.surface);
    expect(s.card, t.colorScheme.surfaceContainer);
  });

  test('the cyan seed of the design: dark primary as measured on the device', () {
    final t = AppTheme.makeDark(_FakeContext(), seedColor: const Color(0xFF069DC7), fontFamily: '');
    expect(t.colorScheme.primary, const Color(0xFF8BD0EF));
  });
  test("the forum's gray (#999999, a quote's header) reads on a light card; a hue and a hidden gray stay", () {
    final t = AppTheme.makeLight(_FakeContext(), seedColor: const Color(0xFF069DC7), fontFamily: '');
    final colors = AuthorColors(t);
    final card = AppSurfaces.ofTheme(t).card;
    for (final gray in const [Color(0xFF999999), Color(0xFFAAAAAA), Color(0xFF888888)]) {
      expect(contrastRatio(colors.text(gray), card), greaterThanOrEqualTo(readableContrast), reason: '$gray');
    }
    expect(colors.text(const Color(0xFF333333)), const Color(0xFF333333));
    expect(colors.text(const Color(0xFFEEEEEE)), const Color(0xFFEEEEEE));
    expect(colors.text(const Color(0xFFFFFFFF)), const Color(0xFFFFFFFF));
    expect(colors.text(const Color(0xFFFF9900)), const Color(0xFFFF9900));
    expect(colors.text(const Color(0xFF999999), on: const Color(0xFF222222)), const Color(0xFF999999));
  });
}
