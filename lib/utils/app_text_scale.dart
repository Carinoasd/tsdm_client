import 'package:flutter/widgets.dart';

/// Smallest text scale the app shows, system font size and the app's own scale together.
const appMinTextScale = 0.7;

/// Largest text scale the app shows, system font size and the app's own scale together: the largest system font of
/// Android (2.0) at the app's default scale.
const appMaxTextScale = 2.0;

/// The text scale of the app: the system font size ([system], the platform's scaler) times the app's own text scale
/// setting ([appScale]), kept within [appMinTextScale] and [appMaxTextScale].
///
/// The app used to replace the system font size by its own setting, so a larger system font changed nothing in the
/// app; and its limits were never applied (the clamp was a cascade on the scaler, its result dropped). The system
/// scaler may be nonlinear (Android 14): its factor is the one of the body text size, 14.
TextScaler appTextScaler(TextScaler system, double appScale) {
  final systemScale = system.scale(14) / 14;
  return TextScaler.linear(
    (systemScale * appScale).clamp(appMinTextScale, appMaxTextScale),
  );
}
