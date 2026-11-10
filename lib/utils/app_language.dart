import 'package:collection/collection.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// The language [SettingsKeys.locale] holds: one of the app's, or null to follow the device (the empty default, or a
/// tag this version does not know).
AppLocale? appLocaleOfSetting(String stored) => AppLocale.values.firstWhereOrNull((v) => v.languageTag == stored);

/// Make the app speak the language the settings hold; the only place that decides it, at every start of the app's
/// Dart side.
///
/// A chosen language is fixed: what the device reports later is ignored. Android reports its locales again at every
/// configuration change and to every engine it starts, and an activity made again on the engine that kept running
/// (the audio service's) changes nothing on the Dart side. Only "follow the device" keeps listening.
Future<AppLocale> applyLanguageSetting(String stored) async {
  final locale = appLocaleOfSetting(stored);
  final applied = locale == null ? await LocaleSettings.useDeviceLocale() : await LocaleSettings.setLocale(locale);
  // The interface language of an exported log: a report of "the language changed by itself" is read against it.
  talker.info(
    'language: ${locale == null ? 'follow device' : 'fixed'} (stored "$stored"), using ${applied.languageTag}',
  );
  return applied;
}

/// The user chose [locale] (null: follow the device): save it, then switch to it.
///
/// Saved first and without asking whether the page that offered the choice is still there: the language in use is
/// never one the next start would not come back to.
Future<void> chooseAppLanguage(SettingsRepository settings, AppLocale? locale) async {
  final stored = locale?.languageTag ?? '';
  talker.info('language chosen: ${locale == null ? 'follow device' : stored}');
  await settings.setValue(SettingsKeys.locale, stored);
  await applyLanguageSetting(stored);
}
