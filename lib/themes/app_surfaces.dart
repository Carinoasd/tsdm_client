import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// The layers of surfaces of the app and the lines and quiet text on them.
///
/// The app themes take them from the hue of the seed color ([AppSurfaces.forSeed]): a dark theme has a near black
/// page with a trace of the seed's hue, a light one a near white page with gray-tinted panels on it. Panels carry no
/// border: the layers tell them apart. None of them is translucent, so what is drawn on them and its contrast are
/// known.
@immutable
class AppSurfaces extends ThemeExtension<AppSurfaces> {
  /// Constructor.
  const AppSurfaces({
    required this.page,
    required this.card,
    required this.inset,
    required this.control,
    required this.bar,
    required this.line,
    required this.lineStrong,
    required this.muted,
  });

  /// The layers of the app for [seed] in [brightness]: tones of a palette of the seed's hue at chroma 6 (the
  /// lines 2 more); [muted] is a tone of the neutral variant palette of the seed's scheme.
  ///
  /// The dark page is tone 4: black stays black. A stronger tint (chroma 10 from tone 7) read as a colored ground.
  factory AppSurfaces.forSeed(Color seed, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final hct = Hct.fromInt(seed.toARGB32());
    const chroma = 6.0;
    final n = TonalPalette.of(hct.hue, chroma);
    final nv = TonalPalette.of(hct.hue, chroma + 2);
    final text = SchemeTonalSpot(sourceColorHct: hct, isDark: dark, contrastLevel: 0).neutralVariantPalette;
    Color c(int argb) => Color(argb);
    return dark
        ? AppSurfaces(
            page: c(n.get(4)),
            card: c(n.get(9)),
            inset: c(n.get(13)),
            control: c(n.get(17)),
            bar: c(n.get(7)),
            line: c(nv.get(21)),
            lineStrong: c(nv.get(31)),
            muted: c(text.get(66)),
          )
        : AppSurfaces(
            page: c(n.get(99)),
            card: c(n.get(95)),
            inset: c(n.get(93)),
            control: c(n.get(90)),
            bar: c(n.get(96)),
            line: c(nv.get(88)),
            lineStrong: c(nv.get(78)),
            muted: c(text.get(42)),
          );
  }

  /// The layers of a theme without them (a bare test theme), from the surface roles of its [colorScheme]: the roles
  /// the app themes set to the layers.
  factory AppSurfaces.fromScheme(ColorScheme colorScheme) => AppSurfaces(
    page: colorScheme.surface,
    card: colorScheme.surfaceContainer,
    inset: colorScheme.surfaceContainerHigh,
    control: colorScheme.surfaceContainerHighest,
    bar: colorScheme.surfaceContainerLow,
    line: colorScheme.outlineVariant,
    lineStrong: colorScheme.outline,
    muted: colorScheme.onSurfaceVariant,
  );

  /// The layers of the theme of [context]; derived from its color scheme when the theme has none (a bare test theme).
  factory AppSurfaces.of(BuildContext context) => AppSurfaces.ofTheme(Theme.of(context));

  /// The layers of [theme], see [AppSurfaces.of].
  factory AppSurfaces.ofTheme(ThemeData theme) =>
      theme.extension<AppSurfaces>() ?? AppSurfaces.fromScheme(theme.colorScheme);

  /// [colorScheme] (the scheme of the same seed) with its surface roles set to these layers, so what takes the
  /// surface roles of the theme (dialogs, menus, fields of Material) is on the same palette: [page] the surface,
  /// [bar] the low container, [card] the container, [inset] the high one, [control] the highest, [line] the outline
  /// variant. The lowest container is one step out of [page] (darker in the dark theme, white in the light one).
  ColorScheme applyTo(ColorScheme colorScheme) {
    final dark = colorScheme.brightness == Brightness.dark;
    return colorScheme.copyWith(
      surface: page,
      surfaceDim: dark ? page : control,
      surfaceBright: dark ? control : page,
      surfaceContainerLowest: dark ? Color.lerp(page, const Color(0xFF000000), 0.4) : const Color(0xFFFFFFFF),
      surfaceContainerLow: bar,
      surfaceContainer: card,
      surfaceContainerHigh: inset,
      surfaceContainerHighest: control,
      outlineVariant: line,
    );
  }

  /// Scaffold, app bar, and the lists and floors read row by row.
  final Color page;

  /// Panels: cards, action tiles, dialogs and sheets, the secondary buttons of the greeting.
  final Color card;

  /// A block inside the content: quotes, the reply field, embedded cards.
  final Color inset;

  /// Pills, chips, small floating buttons.
  final Color control;

  /// Bottom navigation, navigation rail, reply bar.
  final Color bar;

  /// Hairline between rows.
  final Color line;

  /// The bar of a quote, outlined pills.
  final Color lineStrong;

  /// Meta text (time, counts, uid, floor number): one step quieter than the on surface variant color.
  final Color muted;

  @override
  AppSurfaces copyWith({
    Color? page,
    Color? card,
    Color? inset,
    Color? control,
    Color? bar,
    Color? line,
    Color? lineStrong,
    Color? muted,
  }) => AppSurfaces(
    page: page ?? this.page,
    card: card ?? this.card,
    inset: inset ?? this.inset,
    control: control ?? this.control,
    bar: bar ?? this.bar,
    line: line ?? this.line,
    lineStrong: lineStrong ?? this.lineStrong,
    muted: muted ?? this.muted,
  );

  @override
  AppSurfaces lerp(AppSurfaces? other, double t) {
    if (other == null) {
      return this;
    }
    return AppSurfaces(
      page: Color.lerp(page, other.page, t)!,
      card: Color.lerp(card, other.card, t)!,
      inset: Color.lerp(inset, other.inset, t)!,
      control: Color.lerp(control, other.control, t)!,
      bar: Color.lerp(bar, other.bar, t)!,
      line: Color.lerp(line, other.line, t)!,
      lineStrong: Color.lerp(lineStrong, other.lineStrong, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
    );
  }
}
