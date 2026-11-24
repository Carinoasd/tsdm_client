import 'package:flutter/material.dart';

/// The layers of surfaces of the app, picked from the roles of a [ColorScheme] so they hold for every seed color.
///
/// Dark and light themes go opposite ways: in a dark theme a surface is lighter the nearer it is (the page darkest,
/// the cards above it lighter); in a light one cards are white on a gray page. Cards carry no border: the layers tell
/// them apart. None of them is translucent, so what is drawn on them and its contrast are known.
@immutable
class AppSurfaces extends ThemeExtension<AppSurfaces> {
  /// Constructor.
  const AppSurfaces({
    required this.page,
    required this.card,
    required this.inset,
    required this.control,
    required this.bar,
    required this.hero,
    required this.onHero,
  });

  /// The layers for [colorScheme].
  factory AppSurfaces.fromScheme(ColorScheme colorScheme) {
    final dark = colorScheme.brightness == Brightness.dark;
    return AppSurfaces(
      page: dark ? colorScheme.surfaceContainerLowest : colorScheme.surfaceContainer,
      card: dark ? colorScheme.surfaceContainer : colorScheme.surfaceContainerLowest,
      inset: dark ? colorScheme.surfaceContainerHigh : colorScheme.surfaceContainerLow,
      control: dark ? colorScheme.surfaceContainerHighest : colorScheme.surfaceContainerHigh,
      bar: dark ? colorScheme.surfaceContainer : colorScheme.surfaceContainerLowest,
      hero: colorScheme.primaryContainer,
      onHero: colorScheme.onPrimaryContainer,
    );
  }

  /// The layers of the theme of [context]; derived from its color scheme when the theme has none (a bare test theme).
  factory AppSurfaces.of(BuildContext context) => AppSurfaces.ofTheme(Theme.of(context));

  /// The layers of [theme], see [AppSurfaces.of].
  factory AppSurfaces.ofTheme(ThemeData theme) =>
      theme.extension<AppSurfaces>() ?? AppSurfaces.fromScheme(theme.colorScheme);

  /// Scaffold, app bar and navigation rail.
  final Color page;

  /// Cards, floors, and the secondary buttons on a [hero] card.
  final Color card;

  /// A block inside a card: quotes, embedded cards.
  final Color inset;

  /// Pills, chips, tool buttons, the reply field.
  final Color control;

  /// Bottom navigation bar and the reply bar.
  final Color bar;

  /// The one leading card of a page (the greeting of the homepage, the account of "me").
  final Color hero;

  /// Text and icons on [hero].
  final Color onHero;

  @override
  AppSurfaces copyWith({
    Color? page,
    Color? card,
    Color? inset,
    Color? control,
    Color? bar,
    Color? hero,
    Color? onHero,
  }) => AppSurfaces(
    page: page ?? this.page,
    card: card ?? this.card,
    inset: inset ?? this.inset,
    control: control ?? this.control,
    bar: bar ?? this.bar,
    hero: hero ?? this.hero,
    onHero: onHero ?? this.onHero,
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
      hero: Color.lerp(hero, other.hero, t)!,
      onHero: Color.lerp(onHero, other.onHero, t)!,
    );
  }
}
