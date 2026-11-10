/// The interface language is the one the settings hold, whatever Android does to the activity while the app runs.
///
/// Reported from an emulator run of 1.52.0: with 简体中文 chosen on a device whose language is English, the interface
/// was English again a while later, around the moments a forum link was sent to the app with a VIEW intent. The
/// exported log and the screenshots of that run show what happened: the link of the helper script did not match the
/// app's intent filter, no page opened, and the script's two taps (the first field of the page it expected, 0.4 s
/// later a row below it) landed on the language tile of the settings page and on "English" of its dialog. Both times
/// the dialog was open for half a second, and the language stayed once the link was a valid one.
///
/// Nothing on the Dart side changes the language by itself, and these tests keep it so for the events that were
/// suspected:
///
/// * Android reporting its locales again: `FlutterView.onConfigurationChanged` and every new `FlutterEngine` call
///   `LocalizationPlugin.sendLocalesToFlutter`, which ends in `WidgetsBindingObserver.didChangeLocales`;
/// * the activity leaving and coming back, or made again on the engine that kept running (the audio service's
///   engine since 1.53.0): lifecycle states only, the widgets and their state stay;
/// * the root widget built again;
/// * the Dart side starting again: it reads the stored language before the first frame.
///
/// Following the device still follows it: the language is not kept by ignoring the device altogether.
///
/// Synthetic data, no real account or forum.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/app_language.dart';

const _english = Locale('en', 'US');
const _traditional = Locale('zh', 'TW');

/// The root of the app as `main.dart` and `app.dart` build it: the translations above a [MaterialApp] that takes its
/// locale from them. The text is the name of the language in use, in that language.
Widget _app() => TranslationProvider(
  child: Builder(
    builder: (context) => MaterialApp(
      locale: TranslationProvider.of(context).flutterLocale,
      supportedLocales: AppLocaleUtils.supportedLocales,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(
        builder: (context) => Text('${context.t.locale}|${Localizations.localeOf(context).toLanguageTag()}'),
      ),
    ),
  ),
);

/// What the app shows: the name of the language in use and the locale of the [MaterialApp].
String _shown(WidgetTester tester) => tester.widget<Text>(find.byType(Text)).data!;

/// Let what a platform event started finish: a language loaded on demand is a deferred library, which the test VM
/// loads behind a timer of the zone that asked (the fake clock for an event raised by the test body, the real one
/// inside `runAsync`).
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
}

/// The device's language is [locale], and Android tells Flutter (again), as at every configuration change.
Future<void> _deviceReports(WidgetTester tester, Locale locale) async {
  tester.platformDispatcher
    ..localeTestValue = locale
    ..localesTestValue = [locale];
  await _settle(tester);
}

/// The activity is left and destroyed, then made again on the Dart side that kept running; the same states, without
/// the last two, for a link sent to the running activity.
Future<void> _activityMadeAgain(WidgetTester tester) async {
  for (final state in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
  // The new view of the new activity: Android reports the locales to it as well.
  await _deviceReports(tester, _english);
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;

  /// The settings as a start of the app reads them from the storage.
  Future<SettingsRepository> openSettings(WidgetTester tester) async {
    final settings = SettingsRepository(storage);
    await tester.runAsync(settings.init);
    addTearDown(settings.dispose);
    return settings;
  }

  /// The Dart side starts: nothing of the previous run is left but the storage. (The translations are global to the
  /// isolate: a new one starts in the base language, not listening to the device.)
  Future<SettingsRepository> start(WidgetTester tester) async {
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.en));
    final settings = await openSettings(tester);
    await tester.runAsync(() => applyLanguageSetting(settings.currentSettings.locale));
    await tester.pumpWidget(_app());
    await _settle(tester);
    return settings;
  }

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
  });

  tearDown(() async {
    await LocaleSettings.setLocale(AppLocale.en);
    await db.close();
  });

  test('a stored tag is one of the languages of the app, anything else follows the device', () {
    for (final locale in AppLocale.values) {
      expect(appLocaleOfSetting(locale.languageTag), locale);
    }
    expect(appLocaleOfSetting(''), isNull);
    expect(appLocaleOfSetting('xx-YY'), isNull);
  });

  test('the start applies the stored language before the first frame, and nothing else changes it', () {
    final main = File('lib/main.dart').readAsStringSync();
    final boot = main.substring(main.indexOf('Future<void> _boot'), main.indexOf('runApp('));
    expect(boot, contains('await applyLanguageSetting(settings.locale);'));

    // No lifecycle callback, page or repository sets the language: the start and the choice in the settings go
    // through `app_language.dart`, the background service has its own isolate (and its own translations).
    final setter = RegExp(r'\b(setLocale|setLocaleRaw|useDeviceLocale)(Sync)?\(');
    final callers =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => (path: f.path.replaceAll(r'\', '/'), file: f))
            .where((f) => f.path.endsWith('.dart') && !f.path.startsWith('lib/i18n/'))
            .where((f) => setter.hasMatch(f.file.readAsStringSync()))
            .map((f) => f.path)
            .toList()
          ..sort();
    expect(callers, ['lib/features/background_sync/background_sync_entry.dart', 'lib/utils/app_language.dart']);
  });

  testWidgets('the stored language stays whatever Android does to the activity', (tester) async {
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await _deviceReports(tester, _english);
    await tester.runAsync(() => storage.saveString(SettingsKeys.locale.name, 'zh-CN'));

    await start(tester);
    expect(LocaleSettings.currentLocale, AppLocale.zhCn);
    expect(LocaleSettings.instance.listenToDeviceLocale, isFalse);
    expect(_shown(tester), '简体中文|zh-CN');

    // A configuration change (rotation, dark mode, the keyboard of an emulator): the locales are reported again.
    await _deviceReports(tester, _english);
    expect(_shown(tester), '简体中文|zh-CN');
    await _deviceReports(tester, _traditional);
    expect(_shown(tester), '简体中文|zh-CN');

    // A link sent to the running activity: it is paused and resumed.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);
    expect(_shown(tester), '简体中文|zh-CN');

    await _activityMadeAgain(tester);
    expect(_shown(tester), '简体中文|zh-CN');

    // The root built again with a new provider widget: the translations in use are kept.
    await tester.pumpWidget(_app());
    await _settle(tester);
    expect(_shown(tester), '简体中文|zh-CN');
    expect(LocaleSettings.currentLocale, AppLocale.zhCn);
  });

  testWidgets('a language chosen on a new install stays, in this run and after the next start', (tester) async {
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await _deviceReports(tester, _english);

    // Nothing stored: the app follows the device, and listens to it.
    final settings = await start(tester);
    expect(settings.currentSettings.locale, '');
    expect(LocaleSettings.instance.listenToDeviceLocale, isTrue);
    expect(_shown(tester), 'English|en');

    await tester.runAsync(() => chooseAppLanguage(settings, AppLocale.zhCn));
    await _settle(tester);
    expect(_shown(tester), '简体中文|zh-CN');
    expect(settings.currentSettings.locale, 'zh-CN');
    expect(await tester.runAsync(() => storage.getString(SettingsKeys.locale.name)), 'zh-CN');
    expect(LocaleSettings.instance.listenToDeviceLocale, isFalse, reason: 'a chosen language no longer follows');

    await _deviceReports(tester, _english);
    expect(_shown(tester), '简体中文|zh-CN');
    await _activityMadeAgain(tester);
    expect(_shown(tester), '简体中文|zh-CN');

    // The next start, on the same device: the stored language before the first frame.
    await tester.pumpWidget(const SizedBox.shrink());
    final restarted = await start(tester);
    expect(restarted.currentSettings.locale, 'zh-CN');
    expect(_shown(tester), '简体中文|zh-CN');
    await _deviceReports(tester, _english);
    await _activityMadeAgain(tester);
    expect(_shown(tester), '简体中文|zh-CN');
  });

  testWidgets('following the device keeps following it, until a language is chosen and again after', (tester) async {
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await _deviceReports(tester, _english);

    final settings = await start(tester);
    expect(_shown(tester), 'English|en');

    // The language of the device changed in the system settings while the app runs.
    await _deviceReports(tester, _traditional);
    expect(_shown(tester), '繁體中文|zh-TW');
    expect(settings.currentSettings.locale, '', reason: 'following is not a choice of a language');

    await tester.runAsync(() => chooseAppLanguage(settings, AppLocale.zhCn));
    await _settle(tester);
    expect(_shown(tester), '简体中文|zh-CN');
    await _deviceReports(tester, _english);
    expect(_shown(tester), '简体中文|zh-CN');

    // Back to the device's language: at once, saved as the empty default, and following from there.
    await tester.runAsync(() => chooseAppLanguage(settings, null));
    await _settle(tester);
    expect(_shown(tester), 'English|en');
    expect(settings.currentSettings.locale, '');
    expect(await tester.runAsync(() => storage.getString(SettingsKeys.locale.name)), '');
    await _deviceReports(tester, _traditional);
    expect(_shown(tester), '繁體中文|zh-TW');
  });

  testWidgets('a choice that could not be saved is not applied', (tester) async {
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await _deviceReports(tester, _english);
    await tester.runAsync(() => storage.saveString(SettingsKeys.locale.name, 'zh-CN'));
    final settings = await start(tester);
    expect(_shown(tester), '简体中文|zh-CN');

    // The storage fails: applied first, the app would speak a language the next start does not come back to.
    await tester.runAsync(db.close);
    final error = await tester.runAsync<Object?>(() async {
      try {
        await chooseAppLanguage(settings, AppLocale.en);
        return null;
      } on Object catch (e) {
        return e;
      }
    });
    await _settle(tester);
    expect(error, isNotNull);
    expect(settings.currentSettings.locale, 'zh-CN');
    expect(LocaleSettings.currentLocale, AppLocale.zhCn);
    expect(_shown(tester), '简体中文|zh-CN');
  });

  testWidgets('a stored tag this version does not know follows the device', (tester) async {
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await _deviceReports(tester, _traditional);
    await tester.runAsync(() => storage.saveString(SettingsKeys.locale.name, 'xx-YY'));

    await start(tester);
    expect(_shown(tester), '繁體中文|zh-TW');
    expect(LocaleSettings.instance.listenToDeviceLocale, isTrue);
  });
}
