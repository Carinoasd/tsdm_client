/// The cross-device sync of the settings added to it and of the fast reply templates:
///
/// * the settings of the images uploaded in the editors go with the reading settings; the notifications, the tray,
///   the in-app browser, the data saver and the switches of the sync never do; a setting added later takes, on a
///   device that synced its settings before, the forum's value where the device has the default;
/// * the `reply_templates` section: one item, the later change wins whole, united by name at the first sync, held
///   within its budget (over it the forum's section stays), a section switched off neither read nor written;
/// * a document without the new sections or settings (an older version's) and one with sections and fields this
///   version does not know (a newer one's) both work.
///
/// Synthetic data, no real account or forum.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/sync/models/sync_document.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/features/sync/repository/sync_local_store.dart';
import 'package:tsdm_client/features/sync/repository/sync_repository.dart';
import 'package:tsdm_client/features/sync/sync_coordinator.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const _uid = 31;

/// The device clock of the tests (milliseconds).
const _t = 1700000000000;

/// The forum's row of the account: what its `sync` action keeps.
final class _Forum {
  int updated = 0;
  String? data;

  Map<String, dynamic> get doc => data == null ? const {} : jsonDecode(data!) as Map<String, dynamic>;

  /// Another device wrote [doc].
  void write(Map<String, dynamic> doc) {
    updated++;
    data = jsonEncode(doc);
  }
}

/// A device's view of [forum]: reads its row, writes it when nobody wrote since the read (else 409).
final class _Api implements SyncApi {
  _Api(this.forum);

  final _Forum forum;
  int conflicts = 0;
  final pushes = <String>[];

  /// Called once, after the next read was answered and before the device gets the answer.
  Future<void> Function()? afterPull;

  @override
  Future<SyncPullAnswer> pull(int uid) async {
    final answer = SyncPulled(updated: forum.updated, data: forum.data, formhash: 'f1f2f3f4', uid: _uid);
    final hook = afterPull;
    afterPull = null;
    await hook?.call();
    return answer;
  }

  @override
  Future<SyncPushAnswer> push(
    int uid, {
    required String data,
    required int baseUpdated,
    required String formhash,
  }) async {
    if (baseUpdated != forum.updated) {
      conflicts++;
      return SyncConflict(updated: forum.updated, data: forum.data);
    }
    pushes.add(data);
    forum
      ..updated += 1
      ..data = data;
    return SyncPushed(forum.updated);
  }
}

final class _Auth extends Fake implements AuthenticationRepository {
  final _status = BehaviorSubject<AuthStatus>.seeded(const AuthStatusAuthed(UserLoginInfo(username: 'u', uid: _uid)));

  @override
  int? get effectiveCurrentUid => _uid;

  @override
  Stream<AuthStatus> get status => _status.stream;

  @override
  Future<void> dispose() => _status.close();
}

/// One device of the account.
final class _Device {
  _Device(_Forum forum, DateTime Function() now, {Set<SyncCategory> off = const {}})
    : api = _Api(forum),
      store = MemorySyncLocalStore() {
    repo = SyncRepository(
      api: api,
      store: store,
      enabled: () => true,
      categoryEnabled: (c) => !this.off.contains(c),
      now: now,
    );
    this.off.addAll(off);
  }

  final _Api api;
  final MemorySyncLocalStore store;
  final off = <SyncCategory>{};
  late final SyncRepository repo;

  Future<SyncOutcome> sync() => repo.pull(_uid);

  /// The user changed the reply templates to [templates].
  Future<void> setReplyTemplates(List<FastReplyTemplateModel> templates) async {
    store.replyTemplateList = templates;
    await repo.onReplyTemplatesChanged(_uid, SyncRepository.encodeReplyTemplates(templates));
    repo.cancelScheduled();
  }

  /// The user changed the synced settings to [values].
  Future<void> setSettings(Map<String, Object> values) async {
    store.settingsMap = {...store.settingsMap, ...values};
    await repo.onSettingsChanged(_uid, SyncRepository.encodeSettingsValues(store.settingsMap));
    repo.cancelScheduled();
  }

  List<String> get replyNames => [for (final t in store.replyTemplateList) t.name];
}

FastReplyTemplateModel _r(String name, [String? data]) => FastReplyTemplateModel(name: name, data: data ?? '内容$name');

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('settings', () {
    test('the upload settings go with the sync; what is tied to the device never does', () {
      final names = {for (final s in syncedSettings) s.key.name};
      expect(names, containsAll(['editImageBeforeUpload', 'uploadImageMaxSide', 'uploadImageQuality']));
      expect(names, containsAll(syncedSettingsAddedLater));
      for (final key in [
        SettingsKeys.notifyReply,
        SettingsKeys.notifyMention,
        SettingsKeys.notifyRate,
        SettingsKeys.notifyPersonalMessage,
        SettingsKeys.notifySystem,
        SettingsKeys.notifyFollowedThread,
        SettingsKeys.notifyForumNewThread,
        SettingsKeys.notifyKeywordAlert,
        SettingsKeys.notifyQuietHours,
        SettingsKeys.notifyQuietStart,
        SettingsKeys.notifyQuietEnd,
        SettingsKeys.followedThreadCheckMinutes,
        SettingsKeys.forumWatchCheckMinutes,
        SettingsKeys.notificationHideContent,
        SettingsKeys.notificationDirectReply,
        SettingsKeys.systemNotificationsOptIn,
        SettingsKeys.desktopTrayIcon,
        SettingsKeys.closeToTray,
        SettingsKeys.inAppBrowserForForum,
        SettingsKeys.inAppBrowserForAll,
        SettingsKeys.dataSaverMode,
        SettingsKeys.readingTimeStats,
        SettingsKeys.appIcon,
        SettingsKeys.attachmentDownloadDirectory,
        SettingsKeys.editorRecentUsedCustomColors,
        SettingsKeys.homepagePinnedGroup,
        SettingsKeys.crossDeviceSyncReplyTemplates,
        SettingsKeys.crossDeviceSyncReadLater,
        SettingsKeys.crossDeviceSyncFollowedThreads,
      ]) {
        expect(names, isNot(contains(key.name)), reason: key.name);
      }
    });

    test('values out of what the setting takes are not applied', () {
      final defaults = syncedSettingsDefaults();
      Map<String, Object> applied(Map<String, dynamic> values) => syncedSettingsApplied(defaults, values);
      expect(applied({'uploadImageMaxSide': 1920})['uploadImageMaxSide'], 1920);
      expect(applied({'uploadImageMaxSide': 1500})['uploadImageMaxSide'], 0, reason: 'not one of the sides');
      expect(applied({'uploadImageQuality': 5})['uploadImageQuality'], 90);
      expect(applied({'uploadImageQuality': 75})['uploadImageQuality'], 75);
      expect(applied({'uploadImageQuality': 75.5})['uploadImageQuality'], 90, reason: 'not an int');
      expect(applied({'editImageBeforeUpload': 'yes'})['editImageBeforeUpload'], false);
    });

    test('the coordinator: the new switches, a change of the read later list or of the reply templates schedules a '
        'write', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      final settings = SettingsRepository(storage);
      await settings.init();
      final blocks = UserBlockRepository(storage);
      final auth = _Auth();
      final followed = StreamController<int>.broadcast();
      final store = MemorySyncLocalStore();
      final repository = SyncRepository(
        api: _Api(_Forum()),
        store: store,
        enabled: () => settings.currentSettings.crossDeviceSync,
        currentUid: () => auth.effectiveCurrentUid,
        categoryEnabled: (c) => SyncCoordinator.categoryEnabledIn(settings.currentSettings, c),
        debounce: const Duration(minutes: 5),
      );
      final coordinator = SyncCoordinator(
        repository: repository,
        authentication: auth,
        settings: settings,
        blocks: blocks,
        storage: storage,
        followedChanges: followed.stream,
      )..start();
      addTearDown(() async {
        await coordinator.dispose();
        await followed.close();
        await auth.dispose();
        await blocks.dispose();
        await settings.dispose();
        await db.close();
      });
      Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));
      await settle();

      for (final c in [SyncCategory.replyTemplates, SyncCategory.readLater, SyncCategory.followedThreads]) {
        expect(SyncCoordinator.categoryEnabledIn(settings.currentSettings, c), isTrue, reason: '$c on by default');
      }
      await settings.setValue(SettingsKeys.crossDeviceSyncReadLater, false);
      expect(SyncCoordinator.categoryEnabledIn(settings.currentSettings, SyncCategory.readLater), isFalse);
      await settle();
      repository.cancelScheduled();

      await storage.addReadLater(uid: _uid, tid: 3, title: 't');
      await settle();
      expect(repository.pushScheduled, isTrue, reason: 'a change of the read later list');
      repository.cancelScheduled();

      followed.add(32);
      await settle();
      expect(repository.pushScheduled, isFalse, reason: 'another account');
      followed.add(_uid);
      await settle();
      expect(repository.pushScheduled, isTrue, reason: 'a change of the followed threads');
      repository.cancelScheduled();

      expect(store.replyTemplatesUpdatedAt ?? 0, 0, reason: 'none yet: the first sync says nothing');
      await storage.saveFastReplyTemplate(_r('新')).run();
      await settle();
      expect(store.replyTemplatesUpdatedAt, greaterThan(0), reason: 'a change of the reply templates is stamped');
      expect(repository.pushScheduled, isTrue);
      repository.cancelScheduled();
    });

    test('two devices change one setting each: the later change wins, whole, on both', () async {
      var now = DateTime.fromMillisecondsSinceEpoch(_t);
      final forum = _Forum();
      final a = _Device(forum, () => now);
      final b = _Device(forum, () => now);
      await a.sync();
      await b.sync();
      await a.setSettings({'uploadImageQuality': 70});
      now = now.add(const Duration(seconds: 5));
      await b.setSettings({'editImageBeforeUpload': true});
      await a.sync();
      await b.sync();
      await a.sync();
      for (final d in [a, b]) {
        expect(d.store.settingsMap['editImageBeforeUpload'], isTrue);
        expect(
          d.store.settingsMap['uploadImageQuality'],
          90,
          reason: 'the settings are one item: the later wins whole',
        );
      }
    });

    test('a device updated later takes the new settings from the forum where it has the defaults', () async {
      final now = DateTime.fromMillisecondsSinceEpoch(_t + 10000);
      final forum = _Forum()
        ..write({
          'schema': 1,
          'settings': {
            'updated': _t,
            'values': {...syncedSettingsDefaults(), 'uploadImageQuality': 70, 'uploadImageMaxSide': 1280},
          },
        });
      // Synced its settings before (an older version): stamped later than the forum, never knew the upload settings.
      final b = _Device(forum, () => now);
      b.store
        ..settingsUpdatedAt = _t + 5000
        ..settingsMap = {...syncedSettingsDefaults(), 'threadReverseOrder': true, 'uploadImageMaxSide': 1920};
      expect(await b.sync(), SyncOutcome.pushed);
      expect(b.store.settingsMap['uploadImageQuality'], 70, reason: 'the default here: the forum value taken');
      expect(b.store.settingsMap['uploadImageMaxSide'], 1920, reason: 'chosen here: kept');
      expect(b.store.settingsMap['threadReverseOrder'], isTrue);
      final values = (forum.doc['settings'] as Map)['values'] as Map;
      expect(
        (values['uploadImageQuality'], values['uploadImageMaxSide'], values['threadReverseOrder']),
        (70, 1920, true),
      );
      expect(b.store.settingsKnownNames, containsAll(syncedSettingsAddedLater));

      // Taken once: a later default is the user's choice.
      await b.setSettings({'uploadImageQuality': 90});
      await b.sync();
      expect(b.store.settingsMap['uploadImageQuality'], 90);
      expect(((forum.doc['settings'] as Map)['values'] as Map)['uploadImageQuality'], 90);
    });

    test('an older document without the new settings keeps the values of this device for them', () async {
      final now = DateTime.fromMillisecondsSinceEpoch(_t + 10000);
      final old = {...syncedSettingsDefaults()}..removeWhere((k, _) => syncedSettingsAddedLater.contains(k));
      final forum = _Forum()
        ..write({
          'schema': 1,
          'settings': {
            'updated': _t + 9000,
            'values': {...old, 'textScaleFactor': 1.2, 'newer.setting': 'x'},
          },
        });
      final a = _Device(forum, () => now);
      a.store
        ..settingsUpdatedAt = _t
        ..settingsKnownNames = {for (final s in syncedSettings) s.key.name}
        ..settingsMap = {...syncedSettingsDefaults(), 'uploadImageQuality': 60};
      await a.sync();
      expect(a.store.settingsMap['textScaleFactor'], 1.2, reason: 'the forum changed it later');
      expect(a.store.settingsMap['uploadImageQuality'], 60, reason: 'the forum does not hold it');
      final values = (forum.doc['settings'] as Map)['values'] as Map;
      expect(values['uploadImageQuality'], 60, reason: 'filled in from this device');
      expect(values['newer.setting'], 'x', reason: 'a setting this version does not know is kept');
    });
  });

  group('reply templates', () {
    late DateTime now;
    late _Forum forum;
    late _Device a;
    late _Device b;

    setUp(() {
      now = DateTime.fromMillisecondsSinceEpoch(_t);
      forum = _Forum();
      a = _Device(forum, () => now);
      b = _Device(forum, () => now);
    });

    void tick([int ms = 1000]) => now = now.add(Duration(milliseconds: ms));

    test('the first sync unites the templates by name; then a change on either device reaches the other', () async {
      a.store.replyTemplateList = [_r('谢谢'), _r('顶')];
      b.store.replyTemplateList = [_r('顶', '另一台的顶'), _r('收藏了')];
      await a.sync();
      tick();
      await b.sync();
      expect(b.replyNames, ['顶', '收藏了', '谢谢'], reason: 'its own first, the same name kept as it is here');
      expect(b.store.replyTemplateList.first.data, '另一台的顶');
      await a.sync();
      expect(a.replyNames, ['顶', '收藏了', '谢谢'], reason: 'the union is the later change');

      // A removes one, B edits one later: the later change wins whole.
      tick();
      await a.setReplyTemplates([_r('顶'), _r('收藏了')]);
      await a.sync();
      tick();
      await b.sync();
      expect(b.replyNames, ['顶', '收藏了'], reason: 'the removal reaches the other device');
      tick();
      await b.setReplyTemplates([_r('顶', '改过'), _r('收藏了')]);
      await b.sync();
      await a.sync();
      expect(a.store.replyTemplateList.first.data, '改过');
      expect(a.store.writes.where((w) => w == 'saveReplyTemplates'), hasLength(2));
    });

    test("the first union takes the forum's templates only while the list still fits", () async {
      a.store.replyTemplateList = [_r('甲', '字' * 600), _r('乙', '字' * 600)];
      await a.sync();
      tick();
      b.store.replyTemplateList = [_r('丙', '字' * 900)];
      await b.sync();
      expect(b.replyNames, ['丙', '甲'], reason: 'one more would go over the budget');
      expect(SyncRepository.replyTemplatesFit(b.store.replyTemplateList), isTrue);
      expect(SyncRepository.replyTemplatesOf(forum.doc['reply_templates'] as Map<String, dynamic>).map((t) => t.name), [
        '丙',
        '甲',
      ]);
      // One list is kept: the template that did not fit leaves the other device too (a known limitation).
      tick();
      await a.sync();
      expect(a.replyNames, ['丙', '甲']);
    });

    test('two devices change their templates at once: the refused write merges, the later wins on both', () async {
      a.store.replyTemplateList = [_r('一')];
      await a.sync();
      await b.sync();
      tick();
      await a.setReplyTemplates([_r('一'), _r('A')]);
      tick();
      await b.setReplyTemplates([_r('一'), _r('B')]);
      // B writes between A's read and A's write.
      a.api.afterPull = () async => b.sync();
      await a.sync();
      expect(a.api.conflicts, 1);
      await b.sync();
      expect(a.replyNames, ['一', 'B']);
      expect(b.replyNames, ['一', 'B']);
      expect(SyncRepository.replyTemplatesOf(forum.doc['reply_templates'] as Map<String, dynamic>).map((t) => t.name), [
        '一',
        'B',
      ]);
    });

    test('the sync writing them is no change of the user: nothing is stamped, nothing written again', () async {
      a.store.replyTemplateList = [_r('一')];
      await a.sync();
      tick();
      await b.sync();
      final stamp = b.store.replyTemplatesUpdatedAt;
      // What the coordinator reports after the sync wrote the templates.
      await b.repo.onReplyTemplatesChanged(_uid, SyncRepository.encodeReplyTemplates(b.store.replyTemplateList));
      expect(b.store.replyTemplatesUpdatedAt, stamp);
      expect(b.repo.pushScheduled, isFalse);
      expect(await b.sync(), SyncOutcome.upToDate);
    });

    test('over their budget (or their number) they stay out of the sync: neither written nor replaced, until they fit '
        'again', () async {
      a.store.replyTemplateList = [_r('短')];
      await a.sync();
      tick();
      await b.setReplyTemplates([_r('长', '字' * 3000), _r('另一个')]);
      await b.sync();
      expect(SyncRepository.replyTemplatesOf(forum.doc['reply_templates'] as Map<String, dynamic>).single.name, '短');
      expect(b.replyNames, ['长', '另一个']);

      // A changes its list later: B's never reached the forum, so A's does not take them away.
      tick();
      await a.setReplyTemplates([_r('短'), _r('新')]);
      await a.sync();
      tick();
      await b.sync();
      expect(b.replyNames, ['长', '另一个'], reason: 'over the budget here: not replaced');

      // Too many is the same.
      final many = [for (var i = 0; i <= syncReplyTemplatesMax; i++) _r('$i', 'x')];
      expect(SyncRepository.replyTemplatesFit(many), isFalse);
      expect(SyncRepository.replyTemplatesFit(many.take(syncReplyTemplatesMax).toList()), isTrue);

      // Within the budget again: the later change wins whole, as always.
      tick();
      await b.setReplyTemplates([_r('另一个')]);
      await b.sync();
      await a.sync();
      expect(a.replyNames, ['另一个']);
      tick();
      await a.setReplyTemplates([_r('另一个'), _r('A')]);
      await a.sync();
      await b.sync();
      expect(b.replyNames, ['另一个', 'A']);
    });

    test('switched off: neither read nor written; switched on again it syncs', () async {
      a.store.replyTemplateList = [_r('一')];
      await a.sync();
      b.off.add(SyncCategory.replyTemplates);
      b.store.replyTemplateList = [_r('本机')];
      tick();
      await b.sync();
      expect(b.replyNames, ['本机']);
      expect(SyncRepository.replyTemplatesOf(forum.doc['reply_templates'] as Map<String, dynamic>).single.name, '一');
      b.off.clear();
      tick();
      await b.sync();
      expect(b.replyNames, ['本机', '一'], reason: 'the first sync of the category unites');
    });

    test(
      'an older document without the section, and a newer one with fields and sections this one does not know',
      () async {
        a.store.replyTemplateList = [_r('一')];
        forum.write({
          'schema': 1,
          'phrases': {
            'updated': _t,
            'items': ['x'],
          },
        });
        await a.sync();
        expect(SyncRepository.replyTemplatesOf(forum.doc['reply_templates'] as Map<String, dynamic>).single.name, '一');
        expect(a.replyNames, ['一']);

        final doc = forum.doc;
        forum.write({
          ...doc,
          'reply_templates': {
            'updated': _t + 5000,
            'items': [
              {'name': '新', 'data': '内容', 'color': 3},
              {'name': 7},
            ],
            'pinned': true,
          },
          'future_section': {'a': 1},
        });
        tick(10000);
        await a.sync();
        expect(a.replyNames, ['新'], reason: 'an item this version can not read is left out');
        tick();
        await a.setReplyTemplates([_r('新'), _r('再加')]);
        await a.sync();
        final section = forum.doc['reply_templates'] as Map<String, dynamic>;
        expect(section['pinned'], isTrue, reason: 'a field of the section this version does not know is kept');
        expect(forum.doc['future_section'], {'a': 1});
        expect(SyncDocument.parse(forum.data).single('reply_templates'), isNotNull);
      },
    );
  });
}
