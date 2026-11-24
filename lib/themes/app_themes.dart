import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// App themes.
class AppTheme {
  static const FlexSubThemesData _subThemesData = FlexSubThemesData(
    interactionEffects: true,
    tintedDisabledControls: true,
    blendOnLevel: 10,
    outlinedButtonPressedBorderWidth: 1.5,
    sliderValueTinted: true,
    sliderTrackHeight: 5,
    inputDecoratorFocusedBorderWidth: 2,
    inputDecoratorBorderType: FlexInputBorderType.outline,
    fabUseShape: true,
    bottomNavigationBarShowUnselectedLabels: false,
    alignedDropdown: true,

    // Navigation bar: the selected destination is a pill of the primary container, its icon on it, its label in the
    // text color (bold, see [AppTheme._navigationLabel]).
    navigationBarIndicatorSchemeColor: SchemeColor.primaryContainer,
    navigationBarIndicatorOpacity: 1,
    navigationBarSelectedLabelSchemeColor: SchemeColor.onSurface,
    navigationBarSelectedIconSchemeColor: SchemeColor.onPrimaryContainer,
    navigationBarMutedUnselectedLabel: false,
    navigationBarMutedUnselectedIcon: false,
    navigationBarLabelBehavior: NavigationDestinationLabelBehavior.alwaysShow,

    // Navigation rail: as the bar.
    navigationRailIndicatorSchemeColor: SchemeColor.primaryContainer,
    navigationRailIndicatorOpacity: 1,
    navigationRailSelectedLabelSchemeColor: SchemeColor.onSurface,
    navigationRailSelectedIconSchemeColor: SchemeColor.onPrimaryContainer,
    navigationRailUseIndicator: true,
    navigationRailMutedUnselectedLabel: false,
    navigationRailMutedUnselectedIcon: false,
    navigationRailLabelType: NavigationRailLabelType.all,
    drawerRadius: 0,
  );

  /// Cards are the rounded content surfaces of the homepage design, app wide.
  static CardThemeData _buildCardTheme(ThemeData base, AppSurfaces surfaces) =>
      base.cardTheme.copyWith(elevation: 0, color: surfaces.card, shape: appSurfaceShapeOf());

  /// Popup menus and dialogs follow the rounded surfaces.
  ///
  /// Their items are regular: the large label (700, the buttons) is what Material takes for them.
  static PopupMenuThemeData _buildPopupMenuTheme(
    ThemeData base,
    AppSurfaces surfaces,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) => base.popupMenuTheme.copyWith(
    color: surfaces.card,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
    textStyle: (base.popupMenuTheme.textStyle ?? textTheme.titleMedium)?.copyWith(fontWeight: FontWeight.w400),
    labelTextStyle: WidgetStateProperty.resolveWith((states) {
      final style =
          base.popupMenuTheme.labelTextStyle?.resolve(states) ??
          textTheme.labelLarge?.copyWith(
            color: states.contains(WidgetState.disabled)
                ? colorScheme.onSurface.withValues(alpha: 0.38)
                : colorScheme.onSurface,
          );
      return style?.copyWith(fontWeight: FontWeight.w400);
    }),
  );

  /// Items of the menus of a [MenuAnchor] (the menu bar, context menus) are regular, as those of the popup menus.
  static MenuButtonThemeData _buildMenuButtonTheme(ThemeData base, TextTheme textTheme) => MenuButtonThemeData(
    style: (base.menuButtonTheme.style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStatePropertyAll(textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w400)),
    ),
  );

  /// Dialogs and bottom sheets are on the card layer: the blocks in them (inset, control) stand apart as they do in a
  /// card. The defaults were the inset color itself (a dialog of the dark theme, a sheet of the light one).
  static DialogThemeData _buildDialogTheme(ThemeData base, AppSurfaces surfaces) => base.dialogTheme.copyWith(
    backgroundColor: surfaces.card,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
  );

  static BottomSheetThemeData _buildBottomSheetTheme(ThemeData base, AppSurfaces surfaces) =>
      base.bottomSheetTheme.copyWith(backgroundColor: surfaces.card, modalBackgroundColor: surfaces.card);

  /// Theme parts that depend on the final color scheme: the scheme itself (exactly [colorScheme], whatever the
  /// factory derived from it) and the [surfaces] on the page, the bars, the panels, dialogs and sheets.
  static ThemeData _finish(ThemeData base, ColorScheme colorScheme, AppSurfaces surfaces) {
    final textTheme = twoWeights(base.textTheme);
    final dark = colorScheme.brightness == Brightness.dark;
    return base.copyWith(
      colorScheme: colorScheme,
      extensions: [surfaces],
      textTheme: textTheme,
      primaryTextTheme: twoWeights(base.primaryTextTheme),
      iconTheme: _buildIconTheme(base.iconTheme, dark: dark),
      primaryIconTheme: _buildIconTheme(base.primaryIconTheme, dark: dark),
      scaffoldBackgroundColor: surfaces.page,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: surfaces.page,
        // 20, bold. The color is given: a title style of the theme does not take the bar's foreground color.
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: base.appBarTheme.titleTextStyle?.color ?? colorScheme.onSurface,
        ),
        iconTheme: _buildIconTheme(base.appBarTheme.iconTheme, dark: dark),
        actionsIconTheme: _buildIconTheme(base.appBarTheme.actionsIconTheme, dark: dark),
      ),
      navigationBarTheme: base.navigationBarTheme.copyWith(
        backgroundColor: surfaces.bar,
        labelTextStyle: _navigationLabel(base.navigationBarTheme.labelTextStyle, textTheme.labelMedium),
        iconTheme: _navigationIcon(base.navigationBarTheme.iconTheme, dark: dark),
      ),
      navigationRailTheme: base.navigationRailTheme.copyWith(
        backgroundColor: surfaces.bar,
        selectedLabelTextStyle: (base.navigationRailTheme.selectedLabelTextStyle ?? textTheme.labelMedium)?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: (base.navigationRailTheme.unselectedLabelTextStyle ?? textTheme.labelMedium)
            ?.copyWith(fontWeight: FontWeight.w400),
        selectedIconTheme: _buildIconTheme(base.navigationRailTheme.selectedIconTheme, dark: dark, fill: 1),
        unselectedIconTheme: _buildIconTheme(base.navigationRailTheme.unselectedIconTheme, dark: dark),
      ),
      cardTheme: _buildCardTheme(base, surfaces),
      chipTheme: _buildChipTheme(colorScheme, textTheme),
      listTileTheme: _buildListTileTheme(),
      navigationDrawerTheme: _buildNavigationDrawerTheme(colorScheme, textTheme, dark: dark),
      tabBarTheme: _buildTabBarTheme(textTheme),
      progressIndicatorTheme: _buildProcessIndicatorTheme(),
      popupMenuTheme: _buildPopupMenuTheme(base, surfaces, colorScheme, textTheme),
      menuButtonTheme: _buildMenuButtonTheme(base, textTheme),
      dialogTheme: _buildDialogTheme(base, surfaces),
      bottomSheetTheme: _buildBottomSheetTheme(base, surfaces),
    );
  }

  /// Chips are tags and filters: regular, the weight of the small labels. The label style of the theme replaces the
  /// default one of the chips, so it carries their colors too (those of Material 3).
  static ChipThemeData _buildChipTheme(ColorScheme colorScheme, TextTheme textTheme) => ChipThemeData(
    padding: const EdgeInsets.all(2),
    labelStyle: textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w400,
      color: WidgetStateColor.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colorScheme.onSurface;
        }
        if (states.contains(WidgetState.selected)) {
          return colorScheme.onSecondaryContainer;
        }
        return colorScheme.onSurfaceVariant;
      }),
    ),
  );

  /// Global theme for [ListTile].
  static ListTileThemeData _buildListTileTheme() => const ListTileThemeData(
    visualDensity: VisualDensity.standard,
    contentPadding: EdgeInsets.symmetric(horizontal: 10),
    horizontalTitleGap: 10,
  );

  /// Global theme for [TabBar]: the selected tab bold, the others regular.
  static TabBarThemeData _buildTabBarTheme(TextTheme textTheme) => TabBarThemeData(
    dividerHeight: 0,
    labelStyle: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    unselectedLabelStyle: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w400),
  );

  /// [textTheme] in the two weights of the app, 400 and 700, with tabular figures.
  ///
  /// The CJK fonts of Windows (Microsoft JhengHei: Light, Regular, Bold) and of most Android systems have no 500 or
  /// 600: the default weights of Material (500 for the titles and labels) fell back to 400 or 700 there, and whatever
  /// hierarchy they were meant to give did not show. The titles and the large label (buttons) are bold, the small
  /// labels (tags, the navigation, badges) regular. Figures are tabular everywhere: times, counts, floor numbers and
  /// pages keep their width.
  static TextTheme twoWeights(TextTheme textTheme) {
    TextStyle? w(TextStyle? style, FontWeight weight) =>
        style?.copyWith(fontWeight: weight, fontFeatures: const [FontFeature.tabularFigures()]);
    return textTheme.copyWith(
      displayLarge: w(textTheme.displayLarge, FontWeight.w400),
      displayMedium: w(textTheme.displayMedium, FontWeight.w400),
      displaySmall: w(textTheme.displaySmall, FontWeight.w400),
      headlineLarge: w(textTheme.headlineLarge, FontWeight.w400),
      headlineMedium: w(textTheme.headlineMedium, FontWeight.w400),
      headlineSmall: w(textTheme.headlineSmall, FontWeight.w400),
      titleLarge: w(textTheme.titleLarge, FontWeight.w400),
      titleMedium: w(textTheme.titleMedium, FontWeight.w700),
      titleSmall: w(textTheme.titleSmall, FontWeight.w700),
      bodyLarge: w(textTheme.bodyLarge, FontWeight.w400),
      bodyMedium: w(textTheme.bodyMedium, FontWeight.w400),
      bodySmall: w(textTheme.bodySmall, FontWeight.w400),
      labelLarge: w(textTheme.labelLarge, FontWeight.w700),
      labelMedium: w(textTheme.labelMedium, FontWeight.w400),
      labelSmall: w(textTheme.labelSmall, FontWeight.w400),
    );
  }

  /// [base] with the icon axes of the app: weight 400, and grade -25 in the dark theme (light strokes on a dark ground
  /// look heavier; -25 is what Material Symbols advise for dark themes). Only the variable Material Symbols have these
  /// axes; [fill] 1 draws the selected icons of the navigation filled.
  static IconThemeData _buildIconTheme(IconThemeData? base, {required bool dark, double? fill}) =>
      (base ?? const IconThemeData()).copyWith(weight: 400, grade: dark ? -25 : 0, fill: fill);

  /// Label of a destination of the navigation bar: bold when selected, regular otherwise, in the colors and size the
  /// [base] theme gives.
  static WidgetStateProperty<TextStyle?> _navigationLabel(
    WidgetStateProperty<TextStyle?>? base,
    TextStyle? fallback,
  ) => WidgetStateProperty.resolveWith((states) {
    final selected = states.contains(WidgetState.selected);
    return (base?.resolve(states) ?? fallback)?.copyWith(fontWeight: selected ? FontWeight.w700 : FontWeight.w400);
  });

  /// Icon of a destination of the navigation bar: the icon axes of the app on the [base] theme, filled when selected.
  static WidgetStateProperty<IconThemeData?> _navigationIcon(
    WidgetStateProperty<IconThemeData?>? base, {
    required bool dark,
  }) => WidgetStateProperty.resolveWith(
    (states) => _buildIconTheme(
      base?.resolve(states),
      dark: dark,
      fill: states.contains(WidgetState.selected) ? 1 : null,
    ),
  );

  static ProgressIndicatorThemeData _buildProcessIndicatorTheme() => const ProgressIndicatorThemeData(
    // This flag is deprecated since 3.29 but not default to false yet. Keep
    // it to false so we have the latest M3 style process indicator.
    // ignore: deprecated_member_use
    year2023: false,
  );

  /// The drawer of wide windows (desktop) looks like the bar and the rail: the selected destination on the primary
  /// container, its icon filled on it, its label bold in the text color.
  static NavigationDrawerThemeData _buildNavigationDrawerTheme(
    ColorScheme colorScheme,
    TextTheme textTheme, {
    required bool dark,
  }) => NavigationDrawerThemeData(
    indicatorColor: colorScheme.primaryContainer,
    labelTextStyle: WidgetStateProperty.resolveWith((state) {
      if (state.contains(WidgetState.selected)) {
        return textTheme.labelLarge?.copyWith(color: colorScheme.onSurface, fontWeight: FontWeight.w700);
      }
      return textTheme.labelLarge?.copyWith(color: colorScheme.onSurfaceVariant, fontWeight: FontWeight.w400);
    }),
    iconTheme: WidgetStateProperty.resolveWith((state) {
      if (state.contains(WidgetState.selected)) {
        return IconThemeData(
          color: colorScheme.onPrimaryContainer,
          size: 24,
          weight: 400,
          grade: dark ? -25 : 0,
          fill: 1,
        );
      }
      return IconThemeData(color: colorScheme.onSurfaceVariant, size: 24, weight: 400, grade: dark ? -25 : 0);
    }),
  );

  /// The seed of the app's colors when the user chose none: the primary color of the former default scheme.
  static const Color defaultSeedColor = FlexColor.bahamaBlueLightPrimary;

  /// The surface layers of the app for [seedColor] ([defaultSeedColor] when null) in [brightness].
  static AppSurfaces surfacesOf(Color? seedColor, Brightness brightness) =>
      AppSurfaces.forSeed(seedColor ?? defaultSeedColor, brightness);

  /// The color scheme of the app for [seedColor] ([defaultSeedColor] when null) in [brightness].
  ///
  /// One algorithm for every color (the default, a chosen one, the system's accent): [ColorScheme.fromSeed] for the
  /// accents and the text, its surfaces replaced by the layers of [surfacesOf] (the seed's hue). The default used to
  /// come from the bahamaBlue scheme of FlexColorScheme with its blended surfaces, a chosen color from
  /// [ColorScheme.fromSeed], and the layers of the two went opposite ways in the light theme.
  static ColorScheme colorSchemeOf(Color? seedColor, Brightness brightness) => surfacesOf(
    seedColor,
    brightness,
  ).applyTo(ColorScheme.fromSeed(seedColor: seedColor ?? defaultSeedColor, brightness: brightness));

  static ThemeData _make(Brightness brightness, {required Color? seedColor, required String fontFamily}) {
    final surfaces = surfacesOf(seedColor, brightness);
    final colorScheme = colorSchemeOf(seedColor, brightness);
    final family = fontFamily.isEmpty ? null : fontFamily;
    final base = brightness == Brightness.light
        ? FlexThemeData.light(
            fontFamily: family,
            colorScheme: colorScheme,
            tabBarStyle: FlexTabBarStyle.forBackground,
            tooltipsMatchBackground: true,
            subThemesData: _subThemesData,
            visualDensity: FlexColorScheme.comfortablePlatformDensity,
          )
        : FlexThemeData.dark(
            fontFamily: family,
            colorScheme: colorScheme,
            tabBarStyle: FlexTabBarStyle.forBackground,
            tooltipsMatchBackground: true,
            subThemesData: _subThemesData,
            visualDensity: FlexColorScheme.comfortablePlatformDensity,
          );
    return _finish(base, colorScheme, surfaces);
  }

  /// App light theme.
  static ThemeData makeLight(BuildContext context, {required Color? seedColor, required String fontFamily}) =>
      _make(Brightness.light, seedColor: seedColor, fontFamily: fontFamily);

  /// App dark themes.
  static ThemeData makeDark(BuildContext context, {required Color? seedColor, required String fontFamily}) =>
      _make(Brightness.dark, seedColor: seedColor, fontFamily: fontFamily);
}

// If you do not have a themeMode switch, uncomment this line
// to let the device system mode control the theme mode:
// themeMode: ThemeMode.system,
