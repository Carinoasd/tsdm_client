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
  'cyan dark': [0xFF0C171C, 0xFF172126, 0xFF1F292E, 0xFF273237, 0xFF2E3B42, 0xFF445259, 0xFF9AA2A6, 0xFF131D22],
  'cyan light': [0xFFFAFCFF, 0xFFEDF1F5, 0xFFE7ECEF, 0xFFDFE3E7, 0xFFD6DEE3, 0xFFBAC2C7, 0xFF5C6469, 0xFFF0F4F8],
  'pink dark': [0xFF1F1217, 0xFF291C21, 0xFF322429, 0xFF3B2C32, 0xFF47343B, 0xFF5F4B52, 0xFFAE9CA1, 0xFF25181D],
  'pink light': [0xFFFFFBFF, 0xFFFDEDF0, 0xFFF7E7EB, 0xFFEEDFE2, 0xFFECD8DD, 0xFFCFBCC1, 0xFF6E5F64, 0xFFFFF0F3],
  'purple dark': [0xFF17141E, 0xFF211E28, 0xFF292631, 0xFF322F3A, 0xFF3B3745, 0xFF524E5D, 0xFFA49EA9, 0xFF1D1A24],
  'purple light': [0xFFFFFBFF, 0xFFF5EFF7, 0xFFEFE9F1, 0xFFE6E1E9, 0xFFE1DBE6, 0xFFC4BFCA, 0xFF65626B, 0xFFF8F2FA],
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

  test('a seed of low chroma: no hue made up for the dark layers', () {
    const gray = Color(0xFF7A7A80);
    final hct = Hct.fromInt(gray.toARGB32());
    expect(hct.chroma, lessThan(AppSurfaces.lowChromaSeed));
    final s = AppSurfaces.forSeed(gray, Brightness.dark);
    expect(s.page.toARGB32(), TonalPalette.of(hct.hue, 6).get(7));
    expect(s.card.toARGB32(), TonalPalette.of(hct.hue, 6).get(12));
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
}
