import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/app_icon.dart';

/// The app icon is a setting stored by name; a follower switches the launcher icon at startup and on every change.
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

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('the default icon with no value stored', () {
    expect(SettingsKeys.appIcon.defaultValue, 'default');
    expect(settings.currentSettings.appIcon, 'default');
  });

  test('a stored icon is read back after a restart', () async {
    await settings.setValue(SettingsKeys.appIcon, 'pink');
    final reread = SettingsRepository(storage);
    await reread.init();
    expect(reread.currentSettings.appIcon, 'pink');
    await reread.dispose();
  });

  test('every icon has a preview asset and a distinct stored name', () {
    final names = AppIcon.values.map((e) => e.storedName).toSet();
    expect(names, {'default', 'dark', 'mono', 'pink'});
    for (final name in names) {
      expect(AppIcon.fromStoredName(name).storedName, name);
      expect(File('assets/images/app_icons/$name.png').existsSync(), isTrue, reason: name);
    }
  });

  test('an unknown name falls back to the default icon', () {
    expect(AppIcon.fromStoredName('rainbow'), AppIcon.defaultIcon);
    expect(AppIcon.fromStoredName(''), AppIcon.defaultIcon);
  });

  test('applies the stored icon at startup and each change once, not other settings', () async {
    final calls = <String>[];
    final follower = AppIconFollower(
      settings.settings,
      setter: (name) async {
        calls.add(name);
        return true;
      },
    );
    await settle();
    expect(calls, ['default']);

    await settings.setValue(SettingsKeys.appIcon, 'dark');
    await settle();
    await settings.setValue(SettingsKeys.showShortcutInForumCard, true);
    await settle();
    await settings.setValue(SettingsKeys.appIcon, 'dark');
    await settle();
    await settings.setValue(SettingsKeys.appIcon, 'mono');
    await settle();
    expect(calls, ['default', 'dark', 'mono']);

    await follower.dispose();
    await settings.setValue(SettingsKeys.appIcon, 'pink');
    await settle();
    expect(calls, ['default', 'dark', 'mono'], reason: 'nothing after dispose');
  });

  test('a name of a newer version applies the default icon', () async {
    await settings.setValue(SettingsKeys.appIcon, 'rainbow');
    final calls = <String>[];
    final follower = AppIconFollower(
      settings.settings,
      setter: (name) async {
        calls.add(name);
        return true;
      },
    );
    await settle();
    expect(calls, ['default']);
    await follower.dispose();
  });

  test('a platform failure is logged, not thrown, and later changes still apply', () async {
    final calls = <String>[];
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final follower = AppIconFollower(
        settings.settings,
        setter: (name) async {
          calls.add(name);
          if (calls.length == 1) throw Exception('MissingPluginException');
          return true;
        },
      );
      await settle();
      await settings.setValue(SettingsKeys.appIcon, 'pink');
      await settle();
      await follower.dispose();
    }, (e, _) => errors.add(e));
    expect(errors, isEmpty);
    expect(calls, ['default', 'pink']);
  });

  test('the Android manifest and the iOS project carry every icon the app offers', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final switcher = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/AppIconSwitcher.kt').readAsStringSync();
    final ios = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    for (final icon in AppIcon.values) {
      // The default entry keeps the name the launcher activity had before the icons, for the shortcuts on home screens.
      final alias = icon == AppIcon.defaultIcon
          ? 'MainActivity'
          : 'Icon${icon.name[0].toUpperCase()}${icon.name.substring(1)}';
      expect(manifest, contains('android:name=".$alias"'), reason: icon.name);
      expect(switcher, contains('"${icon.storedName}" to "$alias"'), reason: icon.name);
      // Only the default entry is enabled at install; the others wait for the user.
      final tag = RegExp('<activity-alias[^>]*android:name="\\.$alias"[^>]*>').firstMatch(manifest)!.group(0)!;
      expect(tag.contains('android:enabled="true"'), icon == AppIcon.defaultIcon, reason: icon.name);
      if (icon != AppIcon.defaultIcon) {
        final set = 'AppIcon${icon.name[0].toUpperCase()}${icon.name.substring(1)}';
        expect(ios, contains(set), reason: icon.name);
        expect(Directory('ios/Runner/Assets.xcassets/$set.appiconset').existsSync(), isTrue, reason: icon.name);
      }
    }
  });
}
