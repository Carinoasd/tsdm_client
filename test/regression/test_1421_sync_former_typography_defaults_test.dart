/// Cross-device sync of the post typography after its defaults went back (1.62.0 had a line height of 1.8 and a
/// paragraph spacing of 10; 1.7 and 8 are the defaults again, as before 1.62.0).
///
/// A 1.62.0 device writes every synced setting into the document, the ones at its defaults too: its 1.8 and 10 would
/// come back as if the reader chose them, and the defaults would never show again for a reader who syncs the
/// settings. A document holding both at 1.8 and 10 is taken as never having set them (the regular apply, the first
/// sync of a fresh device, the first sync of a device with settings of its own); one of them at another value was set
/// by the reader, and both are applied. 1.7 and 8 are applied like any value. A device that stored the pair (a version
/// before 1.62.0 took them from a 1.62.0 device, 1.62.0 stored them from its layout dialog) is reset from it once.
///
/// Synthetic data, no real account or forum.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/features/sync/repository/sync_local_store.dart';
import 'package:tsdm_client/features/sync/repository/sync_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';

const _uid = 3000;

const _lineHeight = 'threadContentLineHeight';
const _spacing = 'threadContentParagraphSpacing';

/// A forum that answers what another device wrote ([remote]) and keeps what this one writes.
final class _FakeApi implements SyncApi {
  SyncPullAnswer pullAnswer = const SyncPulled(updated: 0, data: null, formhash: 'fh', uid: _uid);

  @override
  Future<SyncPullAnswer> pull(int uid) async => pullAnswer;

  @override
  Future<SyncPushAnswer> push(
    int uid, {
    required String data,
    required int baseUpdated,
    required String formhash,
  }) async {
    final current = pullAnswer is SyncPulled ? (pullAnswer as SyncPulled).updated : 0;
    pullAnswer = SyncPulled(updated: current + 1, data: data, formhash: 'fh', uid: _uid);
    return SyncPushed(current + 1);
  }

  void remote(Map<String, dynamic> doc, {int updated = 5}) =>
      pullAnswer = SyncPulled(updated: updated, data: jsonEncode(doc), formhash: 'fh', uid: _uid);
}

/// The settings section a 1.62.0 device (defaults 1.8 and 10) writes, with [changed] chosen there.
Map<String, dynamic> _v1620Document(int updated, Map<String, Object> changed) => {
  'settings': {
    'updated': updated,
    'values': {...syncedSettingsDefaults(), _lineHeight: 1.8, _spacing: 10.0, ...changed},
  },
};

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  test('the defaults are 1.7 and 8 again; 1.8 and 10 are the former defaults, as a pair', () {
    expect(PostTypography.defaultLineHeight, 1.7);
    expect(PostTypography.defaultParagraphSpacing, 8.0);
    expect(syncedSettingsFormerDefaults, [
      {_lineHeight: 1.8, _spacing: 10.0},
    ]);
    expect(syncedSettingsDefaults()[_lineHeight], 1.7);
    expect(syncedSettingsDefaults()[_spacing], 8.0);
  });

  group('applied values', () {
    final defaults = syncedSettingsDefaults();
    final chosen = {...defaults, _lineHeight: 1.5, _spacing: 12.0};

    test('the pair 1.8 and 10 is not applied, the other settings of the document are', () {
      final applied = syncedSettingsApplied(chosen, {_lineHeight: 1.8, _spacing: 10, 'threadReverseOrder': true});
      expect(applied[_lineHeight], 1.5);
      expect(applied[_spacing], 12.0);
      expect(applied['threadReverseOrder'], true);
      // As the forum keeps it: 10 written as an int.
      expect(syncedSettingsIncoming({_lineHeight: 1.8, _spacing: 10}), isEmpty);
    });

    test('one of them at another value: the reader set it, both are applied', () {
      expect(syncedSettingsApplied(chosen, {_lineHeight: 1.8, _spacing: 8.0}), {
        ...chosen,
        _lineHeight: 1.8,
        _spacing: 8.0,
      });
      expect(syncedSettingsApplied(chosen, {_lineHeight: 1.5, _spacing: 10.0}), {
        ...chosen,
        _lineHeight: 1.5,
        _spacing: 10.0,
      });
    });

    test('1.7 and 8, the defaults again, are applied like any value', () {
      final applied = syncedSettingsApplied(chosen, {_lineHeight: 1.7, _spacing: 8});
      expect(applied[_lineHeight], 1.7);
      expect(applied[_spacing], 8.0);
    });

    test('the settings repository skips the pair too', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final settings = SettingsRepository(StorageProvider(db, {}, {}));
      await settings.init();
      addTearDown(settings.dispose);

      final changes = syncedSettingsChanges({
        _lineHeight: 1.8,
        _spacing: 10,
        'threadReverseOrder': true,
      }, settings.currentSettings);
      expect(changes.map((c) => c.$1), [SettingsKeys.threadReverseOrder]);
      await settings.setMixedValues(changes);
      expect(settings.currentSettings.threadContentLineHeight, 1.7);
      expect(settings.currentSettings.threadContentParagraphSpacing, 8.0);

      await settings.setMixedValues(syncedSettingsChanges({_lineHeight: 1.5, _spacing: 12}, settings.currentSettings));
      expect(settings.currentSettings.threadContentLineHeight, 1.5);
      expect(settings.currentSettings.threadContentParagraphSpacing, 12.0);

      // Back at the defaults on another device: applied.
      await settings.setMixedValues(syncedSettingsChanges({_lineHeight: 1.7, _spacing: 8}, settings.currentSettings));
      expect(settings.currentSettings.threadContentLineHeight, 1.7);
      expect(settings.currentSettings.threadContentParagraphSpacing, 8.0);

      await settings.setMixedValues(syncedSettingsChanges({_lineHeight: 1.8, _spacing: 8}, settings.currentSettings));
      expect(settings.currentSettings.threadContentLineHeight, 1.8);
    });
  });

  group('repository', () {
    late _FakeApi api;
    late MemorySyncLocalStore store;

    SyncRepository repo() => SyncRepository(
      api: api,
      store: store,
      enabled: () => true,
      now: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

    setUp(() {
      api = _FakeApi();
      store = MemorySyncLocalStore()..settingsKnownNames = {for (final s in syncedSettings) s.key.name};
    });

    test('a later document of 1.62.0: its other settings are applied, not its defaults', () async {
      store
        ..settingsUpdatedAt = 100
        ..settingsMap = {...store.settingsMap, _lineHeight: 1.5, _spacing: 12.0};
      api.remote(_v1620Document(500, {'threadReverseOrder': true}));
      await repo().pull(_uid);
      expect(store.settingsUpdatedAt, 500);
      expect(store.settingsMap['threadReverseOrder'], true);
      expect(store.settingsMap[_lineHeight], 1.5);
      expect(store.settingsMap[_spacing], 12.0);
    });

    test('a fresh device takes the settings of 1.62.0, not its defaults', () async {
      api.remote(_v1620Document(500, {'threadReverseOrder': true}));
      await repo().pull(_uid);
      expect(store.settingsMap['threadReverseOrder'], true);
      expect(store.settingsMap[_lineHeight], 1.7);
      expect(store.settingsMap[_spacing], 8.0);
    });

    test('a device with settings of its own at its first sync: the defaults of 1.62.0 do not fill in', () async {
      store.settingsMap = {...store.settingsMap, 'textScaleFactor': 1.3};
      api.remote(_v1620Document(500, {'threadReverseOrder': true}));
      await repo().pull(_uid);
      expect(store.settingsMap['textScaleFactor'], 1.3);
      expect(store.settingsMap['threadReverseOrder'], true);
      expect(store.settingsMap[_lineHeight], 1.7);
      expect(store.settingsMap[_spacing], 8.0);
    });

    test('a value the reader chose on a 1.62.0 device is applied, the default beside it too', () async {
      store.settingsUpdatedAt = 100;
      api.remote(_v1620Document(500, {_lineHeight: 1.5}));
      await repo().pull(_uid);
      expect(store.settingsMap[_lineHeight], 1.5);
      expect(store.settingsMap[_spacing], 10.0);
    });

    test('values the reader chose on another device are applied', () async {
      store.settingsUpdatedAt = 100;
      api.remote(_v1620Document(500, {_lineHeight: 1.4, _spacing: 6.0}));
      await repo().pull(_uid);
      expect(store.settingsMap[_lineHeight], 1.4);
      expect(store.settingsMap[_spacing], 6.0);
    });

    test('a document of a version before 1.62.0 (1.7 and 8) is applied', () async {
      store
        ..settingsUpdatedAt = 100
        ..settingsMap = {...store.settingsMap, _lineHeight: 1.5, _spacing: 12.0};
      api.remote({
        'settings': {
          'updated': 500,
          'values': {...syncedSettingsDefaults(), _lineHeight: 1.7, _spacing: 8.0},
        },
      });
      await repo().pull(_uid);
      expect(store.settingsMap[_lineHeight], 1.7);
      expect(store.settingsMap[_spacing], 8.0);
    });
  });

  group('the pair stored on a device is reset once', () {
    late AppDatabase db;
    late StorageProvider storage;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
    });

    tearDown(() => db.close());

    /// A start of the app: the settings loaded, then the reset (`main`).
    Future<SettingsRepository> start() async {
      final settings = SettingsRepository(storage);
      await settings.init();
      await settings.resetFormerDefaultsOnce();
      addTearDown(settings.dispose);
      return settings;
    }

    test('stored at 1.8 and 10: read as the defaults, nothing stored any more', () async {
      await storage.saveDouble(_lineHeight, 1.8);
      await storage.saveDouble(_spacing, 10);
      await storage.saveDouble(SettingsKeys.threadContentMaxWidth.name, 800);
      final settings = await start();
      expect(settings.currentSettings.threadContentLineHeight, 1.7);
      expect(settings.currentSettings.threadContentParagraphSpacing, 8.0);
      expect(settings.currentSettings.threadContentMaxWidth, 800, reason: 'the rest of the layout stays');
      expect(await storage.getDouble(_lineHeight), isNull);
      expect(await storage.getDouble(_spacing), isNull);
      expect(await storage.getBool(SettingsRepository.formerDefaultsResetKey), isTrue);
    });

    test('loading the settings stores nothing: a new install still tells itself from an update', () async {
      final settings = SettingsRepository(storage);
      await settings.init();
      addTearDown(settings.dispose);
      expect(await storage.getAllSettings(), isEmpty);
    });

    test('once: the pair set after it stays', () async {
      await start();
      final settings = await start();
      await settings.setValues<double>([
        (SettingsKeys.threadContentLineHeight, 1.8),
        (SettingsKeys.threadContentParagraphSpacing, 10),
      ]);
      final again = await start();
      expect(again.currentSettings.threadContentLineHeight, 1.8);
      expect(again.currentSettings.threadContentParagraphSpacing, 10.0);
    });

    test('one of them at another value stays', () async {
      await storage.saveDouble(_lineHeight, 1.8);
      await storage.saveDouble(_spacing, 12);
      final settings = await start();
      expect(settings.currentSettings.threadContentLineHeight, 1.8);
      expect(settings.currentSettings.threadContentParagraphSpacing, 12.0);
    });
  });
}
