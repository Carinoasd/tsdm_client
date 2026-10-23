import 'package:flutter/widgets.dart';

/// Smallest text scale the app shows, system font size and the app's own scale together.
const appMinTextScale = 0.7;

/// Largest text scale the app shows, system font size and the app's own scale together: the largest of the app's own
/// scale setting, as before the system font size counted.
const appMaxTextScale = 1.5;

/// The text scale of the app: the system font size ([system], the platform's scaler) times the app's own text scale
/// setting ([appScale]), kept within [appMinTextScale] and [appMaxTextScale].
///
/// The app used to replace the system font size by its own setting, so a larger system font changed nothing in the
/// app; and its limits were never applied (the clamp was a cascade on the scaler, its result dropped).
TextScaler appTextScaler(TextScaler system, double appScale) => AppTextScaler(system, appScale);

/// The platform's text scaler [system] times [appScale], within [appMinTextScale] and [appMaxTextScale] of the font
/// size.
///
/// The platform's scaler is kept as it is, not turned into a linear one: Android 14 scales large fonts less than small
/// ones (nonlinear font scaling), so a heading does not grow as much as the body text.
@immutable
final class AppTextScaler extends TextScaler {
  /// Constructor.
  const AppTextScaler(this.system, this.appScale);

  /// The text scaler of the platform (the system font size).
  final TextScaler system;

  /// The app's own text scale setting.
  final double appScale;

  @override
  double scale(double fontSize) =>
      (system.scale(fontSize) * appScale).clamp(fontSize * appMinTextScale, fontSize * appMaxTextScale);

  @override
  @Deprecated('Use scale instead.')
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AppTextScaler && other.system == system && other.appScale == appScale;

  @override
  int get hashCode => Object.hash(system, appScale);

  @override
  String toString() => 'AppTextScaler($system x $appScale)';
}
