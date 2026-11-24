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

    // Navigation bar
    navigationBarSelectedLabelSchemeColor: SchemeColor.primary,
    navigationBarSelectedIconSchemeColor: SchemeColor.primary,
    navigationBarMutedUnselectedLabel: false,
    navigationBarMutedUnselectedIcon: false,
    navigationBarLabelBehavior: NavigationDestinationLabelBehavior.alwaysShow,

    // Navigation rail
    navigationRailSelectedLabelSchemeColor: SchemeColor.primary,
    navigationRailSelectedIconSchemeColor: SchemeColor.primary,
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
  static PopupMenuThemeData _buildPopupMenuTheme(ThemeData base) => base.popupMenuTheme.copyWith(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
  );

  /// Dialogs and bottom sheets are on the card layer: the blocks in them (inset, control) stand apart as they do in a
  /// card. The defaults were the inset color itself (a dialog of the dark theme, a sheet of the light one).
  static DialogThemeData _buildDialogTheme(ThemeData base, AppSurfaces surfaces) => base.dialogTheme.copyWith(
    backgroundColor: surfaces.card,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(appSurfaceRadius + 6)),
  );

  static BottomSheetThemeData _buildBottomSheetTheme(ThemeData base, AppSurfaces surfaces) =>
      base.bottomSheetTheme.copyWith(backgroundColor: surfaces.card, modalBackgroundColor: surfaces.card);

  /// Theme parts that depend on the final color scheme: the scheme itself (exactly [colorScheme], whatever the
  /// factory derived from it) and the surfaces of [AppSurfaces] on the page, the bars and the cards.
  static ThemeData _finish(ThemeData base, ColorScheme colorScheme) {
    final surfaces = AppSurfaces.fromScheme(colorScheme);
    return base.copyWith(
      colorScheme: colorScheme,
      extensions: [surfaces],
      scaffoldBackgroundColor: surfaces.page,
      appBarTheme: base.appBarTheme.copyWith(backgroundColor: surfaces.page),
      navigationBarTheme: base.navigationBarTheme.copyWith(backgroundColor: surfaces.bar),
      navigationRailTheme: base.navigationRailTheme.copyWith(backgroundColor: surfaces.page),
      cardTheme: _buildCardTheme(base, surfaces),
      chipTheme: _buildChipTheme(),
      listTileTheme: _buildListTileTheme(),
      navigationDrawerTheme: _buildNavigationDrawerTheme(colorScheme),
      tabBarTheme: _buildTabBarTheme(),
      progressIndicatorTheme: _buildProcessIndicatorTheme(),
      popupMenuTheme: _buildPopupMenuTheme(base),
      dialogTheme: _buildDialogTheme(base, surfaces),
      bottomSheetTheme: _buildBottomSheetTheme(base, surfaces),
    );
  }

  static ChipThemeData _buildChipTheme() => const ChipThemeData(padding: EdgeInsets.all(2));

  /// Global theme for [ListTile].
  static ListTileThemeData _buildListTileTheme() => const ListTileThemeData(
    visualDensity: VisualDensity.standard,
    contentPadding: EdgeInsets.symmetric(horizontal: 10),
    horizontalTitleGap: 10,
  );

  /// Global theme for [TabBar].
  static TabBarThemeData _buildTabBarTheme() => const TabBarThemeData(dividerHeight: 0);

  static ProgressIndicatorThemeData _buildProcessIndicatorTheme() => const ProgressIndicatorThemeData(
    // This flag is deprecated since 3.29 but not default to false yet. Keep
    // it to false so we have the latest M3 style process indicator.
    // ignore: deprecated_member_use
    year2023: false,
  );

  static NavigationDrawerThemeData _buildNavigationDrawerTheme(ColorScheme colorScheme) => NavigationDrawerThemeData(
    labelTextStyle: WidgetStateProperty.resolveWith((state) {
      if (state.contains(WidgetState.selected)) {
        return TextStyle(color: colorScheme.primary);
      }
      return null;
    }),
    iconTheme: WidgetStateProperty.resolveWith((state) {
      if (state.contains(WidgetState.selected)) {
        return IconThemeData(color: colorScheme.primary);
      }
      return null;
    }),
  );

  /// The seed of the app's colors when the user chose none: the primary color of the former default scheme.
  static const Color defaultSeedColor = FlexColor.bahamaBlueLightPrimary;

  /// The color scheme of the app for [seedColor] ([defaultSeedColor] when null) in [brightness].
  ///
  /// One algorithm for every color (the default, a chosen one, the system's accent): the default used to come from
  /// the bahamaBlue scheme of FlexColorScheme with its blended surfaces, a chosen color from [ColorScheme.fromSeed],
  /// and the layers of the two went opposite ways in the light theme (cards darker than the page in one, lighter in
  /// the other).
  static ColorScheme colorSchemeOf(Color? seedColor, Brightness brightness) =>
      ColorScheme.fromSeed(seedColor: seedColor ?? defaultSeedColor, brightness: brightness);

  static ThemeData _make(Brightness brightness, {required Color? seedColor, required String fontFamily}) {
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
    return _finish(base, colorScheme);
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
