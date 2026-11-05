part of 'theme_cubit.dart';

/// State of theme.
@MappableClass()
final class ThemeState with ThemeStateMappable {
  /// Constructor.
  const ThemeState({
    this.accentColor,
    this.themeModeIndex = 0,
    this.fontFamily = '',
    this.scheduled = false,
    this.scheduleStart = DarkSchedule.defaultStart,
    this.scheduleEnd = DarkSchedule.defaultEnd,
    this.scheduleDark = false,
  });

  /// Current using app accent color.
  final Color? accentColor;

  /// Current using theme mode index, the index of a [ThemeMode]; set aside while [scheduled].
  final int themeModeIndex;

  /// Font family
  final String fontFamily;

  /// Whether the clock decides the theme: dark inside the dark hours, light outside.
  final bool scheduled;

  /// Start of the dark hours, minutes after midnight.
  final int scheduleStart;

  /// End of the dark hours, minutes after midnight.
  final int scheduleEnd;

  /// Whether it is inside the dark hours now, as of the last time the cubit worked it out.
  final bool scheduleDark;

  /// The dark hours.
  DarkSchedule get schedule => DarkSchedule(start: scheduleStart, end: scheduleEnd);

  /// The theme mode the app really uses: dark inside the dark hours and light outside when the clock is in charge,
  /// otherwise the one of [themeModeIndex].
  ThemeMode get effectiveThemeMode {
    if (scheduled) {
      return scheduleDark ? ThemeMode.dark : ThemeMode.light;
    }
    return themeModeIndex >= 0 && themeModeIndex < ThemeMode.values.length
        ? ThemeMode.values[themeModeIndex]
        : ThemeMode.system;
  }
}
