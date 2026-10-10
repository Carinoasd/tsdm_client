import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/high_refresh_rate.dart';

/// GitHub #182: some vendor systems keep apps at 60Hz on 90/120Hz screens unless the app prefers a display mode.
/// The app asks Android for the highest refresh rate by default; a settings switch turns it off. The current value
/// applies at startup and every toggle applies at once.
void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    await settings.init();
  });

  tearDown(() async {
    await settings.dispose();
    await db.close();
  });

  /// Let the settings stream and the follower deliver.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('on by default, with no value stored (new install or an older version)', () {
    expect(SettingsKeys.highRefreshRate.defaultValue, isTrue);
    expect(settings.currentSettings.highRefreshRate, isTrue);
  });

  test('applies the current value at startup and every toggle once', () async {
    final calls = <bool>[];
    final follower = HighRefreshRateFollower(
      settings.settings,
      setter: ({required enable}) async {
        calls.add(enable);
        return enable ? 120 : 0;
      },
    );
    await settle();
    expect(calls, [true], reason: 'the stored value applies at startup');

    await settings.setValue(SettingsKeys.highRefreshRate, false);
    await settle();
    // An unrelated setting does not ask the platform again.
    await settings.setValue(SettingsKeys.showShortcutInForumCard, true);
    await settle();
    await settings.setValue(SettingsKeys.highRefreshRate, true);
    await settle();
    expect(calls, [true, false, true]);

    await follower.dispose();
    await settings.setValue(SettingsKeys.highRefreshRate, false);
    await settle();
    expect(calls, [true, false, true], reason: 'nothing after dispose');
  });

  test('a stored off applies at startup', () async {
    await settings.setValue(SettingsKeys.highRefreshRate, false);
    final reread = SettingsRepository(storage);
    await reread.init();
    expect(reread.currentSettings.highRefreshRate, isFalse);

    final calls = <bool>[];
    final follower = HighRefreshRateFollower(
      reread.settings,
      setter: ({required enable}) async {
        calls.add(enable);
        return 0;
      },
    );
    await settle();
    expect(calls, [false]);
    await follower.dispose();
    await reread.dispose();
  });

  test('a platform failure is logged, not thrown, and later toggles still apply', () async {
    final calls = <bool>[];
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final follower = HighRefreshRateFollower(
        settings.settings,
        setter: ({required enable}) async {
          calls.add(enable);
          if (calls.length == 1) throw Exception('MissingPluginException');
          return 0;
        },
      );
      await settle();
      await settings.setValue(SettingsKeys.highRefreshRate, false);
      await settle();
      await follower.dispose();
    }, (e, _) => errors.add(e));
    expect(errors, isEmpty);
    expect(calls, [true, false]);
  });
}
