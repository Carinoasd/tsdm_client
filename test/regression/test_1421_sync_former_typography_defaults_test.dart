/// Cross-device sync of the post typography after its defaults changed (1.62.0: line height 1.7 → 1.8, paragraph
/// spacing 8 → 10).
///
/// An older version writes every synced setting into the document, the ones still at their default too: its 1.7 and 8
/// would come back to a device of this version as if the reader chose them, and the new defaults would never show
/// for a reader who syncs the settings. A value of the document equal to the former default of these two settings is
/// taken as never set and not applied (the regular apply, the first sync of a fresh device, the first sync of a device
/// with settings of its own); any other value is applied as before, and so are the other settings of the document.
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

/// The settings section an older version (defaults 1.7 and 8) writes, with [changed] chosen there.
Map<String, dynamic> _olderDocument(int updated, Map<String, Object> changed) => {
  'settings': {
    'updated': updated,
    'values': {...syncedSettingsDefaults(), _lineHeight: 1.7, _spacing: 8.0, ...changed},
  },
};

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  test('the new defaults', () {
    expect(PostTypography.defaultLineHeight, 1.8);
    expect(PostTypography.defaultParagraphSpacing, 10.0);
    expect(syncedSettingsFormerDefaults, {_lineHeight: 1.7, _spacing: 8.0});
  });

  group('applied values', () {
    test('the former defaults are not applied, other values and other settings are', () {
      final defaults = syncedSettingsDefaults();
      final applied = syncedSettingsApplied(defaults, {_lineHeight: 1.7, _spacing: 8, 'threadReverseOrder': true});
      expect(applied[_lineHeight], 1.8);
      expect(applied[_spacing], 10.0);
      expect(applied['threadReverseOrder'], true);

      final chosen = syncedSettingsApplied(defaults, {_lineHeight: 1.5, _spacing: 12});
      expect(chosen[_lineHeight], 1.5);
      expect(chosen[_spacing], 12.0);
    });

    test('the settings repository skips the former defaults too', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final settings = SettingsRepository(StorageProvider(db, {}, {}));
      await settings.init();
      addTearDown(settings.dispose);

      final changes = syncedSettingsChanges({
        _lineHeight: 1.7,
        _spacing: 8,
        'threadReverseOrder': true,
      }, settings.currentSettings);
      expect(changes.map((c) => c.$1), [SettingsKeys.threadReverseOrder]);
      await settings.setMixedValues(changes);
      expect(settings.currentSettings.threadContentLineHeight, 1.8);
      expect(settings.currentSettings.threadContentParagraphSpacing, 10.0);

      await settings.setMixedValues(syncedSettingsChanges({_lineHeight: 1.5, _spacing: 12}, settings.currentSettings));
      expect(settings.currentSettings.threadContentLineHeight, 1.5);
      expect(settings.currentSettings.threadContentParagraphSpacing, 12.0);

      // A device that set them before back at the former defaults: taken as never set, this device keeps its own.
      await settings.setMixedValues(syncedSettingsChanges({_lineHeight: 1.7, _spacing: 8}, settings.currentSettings));
      expect(settings.currentSettings.threadContentLineHeight, 1.5);
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

    test('a later document of an older version: its other settings are applied, not its defaults', () async {
      store.settingsUpdatedAt = 100;
      api.remote(_olderDocument(500, {'threadReverseOrder': true}));
      await repo().pull(_uid);
      expect(store.settingsUpdatedAt, 500);
      expect(store.settingsMap['threadReverseOrder'], true);
      expect(store.settingsMap[_lineHeight], 1.8);
      expect(store.settingsMap[_spacing], 10.0);
    });

    test('a fresh device takes the settings of an older version, not its defaults', () async {
      api.remote(_olderDocument(500, {'threadReverseOrder': true}));
      await repo().pull(_uid);
      expect(store.settingsMap['threadReverseOrder'], true);
      expect(store.settingsMap[_lineHeight], 1.8);
      expect(store.settingsMap[_spacing], 10.0);
    });

    test(
      'a device with settings of its own at its first sync: the defaults of an older version do not fill in',
      () async {
        store.settingsMap = {...store.settingsMap, 'textScaleFactor': 1.3};
        api.remote(_olderDocument(500, {'threadReverseOrder': true}));
        await repo().pull(_uid);
        expect(store.settingsMap['textScaleFactor'], 1.3);
        expect(store.settingsMap['threadReverseOrder'], true);
        expect(store.settingsMap[_lineHeight], 1.8);
        expect(store.settingsMap[_spacing], 10.0);
      },
    );

    test('values the reader chose on another device are applied', () async {
      store.settingsUpdatedAt = 100;
      api.remote(_olderDocument(500, {_lineHeight: 1.5, _spacing: 12.0}));
      await repo().pull(_uid);
      expect(store.settingsMap[_lineHeight], 1.5);
      expect(store.settingsMap[_spacing], 12.0);
    });
  });
}
