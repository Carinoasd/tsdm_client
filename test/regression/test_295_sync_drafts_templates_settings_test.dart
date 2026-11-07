/// Cross-device sync, three more sections (plugin 3.4.0 keeps the document as it is, the app defines them):
///
/// * `rate_templates` and `settings`: one item each, the later `updated` wins, like `phrases`; the settings carry only
///   the reading and display settings of `syncedSettings`, never one tied to the device, and values this version does
///   not accept are left alone; a fresh device never undoes another's settings.
/// * `drafts`: the local drafts of the account item by item, a deletion as a record with `deleted: true`, only for a
///   draft this device held; a draft too large goes without its editor document or stays on its device, the latest
///   ones within a budget; a document the forum refuses as too large (413) is sent again without the drafts.
/// * A category switched off is neither read nor written; switched on again it deletes nothing of the others.
/// * Sections this version does not know are kept, a document without the new sections merges as before, and a change
///   of the templates, of a synced setting or of a draft schedules a write.
///
/// Synthetic data, no real account or forum.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/sync/models/sync_document.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/features/sync/repository/sync_local_store.dart';
import 'package:tsdm_client/features/sync/repository/sync_repository.dart';
import 'package:tsdm_client/features/sync/sync_coordinator.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/thread_floor_interaction_mode.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const _uid = 3000;

/// A forum that answers from [pullAnswer] and the queued [pushAnswers] (the last one stays), and records every call.
final class _FakeApi implements SyncApi {
  SyncPullAnswer pullAnswer = const SyncPulled(updated: 0, data: null, formhash: 'fh', uid: _uid);
  final pushAnswers = <SyncPushAnswer>[];
  int pulls = 0;
  final pushes = <({String data, int base})>[];

  @override
  Future<SyncPullAnswer> pull(int uid) async {
    pulls++;
    return pullAnswer;
  }

  @override
  Future<SyncPushAnswer> push(
    int uid, {
    required String data,
    required int baseUpdated,
    required String formhash,
  }) async {
    pushes.add((data: data, base: baseUpdated));
    final current = pullAnswer is SyncPulled ? (pullAnswer as SyncPulled).updated : 0;
    final answer = pushAnswers.isEmpty
        ? SyncPushed(current + 1)
        : (pushAnswers.length > 1 ? pushAnswers.removeAt(0) : pushAnswers.first);
    if (answer is SyncPushed) {
      pullAnswer = SyncPulled(updated: answer.updated, data: data, formhash: 'fh', uid: _uid);
    }
    return answer;
  }

  Map<String, dynamic> get lastPushed => jsonDecode(pushes.last.data) as Map<String, dynamic>;

  /// Another device wrote [doc].
  void remote(Map<String, dynamic> doc, {int updated = 5}) =>
      pullAnswer = SyncPulled(updated: updated, data: jsonEncode(doc), formhash: 'fh', uid: _uid);
}

final class _Auth extends Fake implements AuthenticationRepository {
  final _status = BehaviorSubject<AuthStatus>.seeded(
    const AuthStatusAuthed(UserLoginInfo(username: 'u', uid: _uid)),
  );

  @override
  int? get effectiveCurrentUid => _uid;

  @override
  Stream<AuthStatus> get status => _status.stream;

  @override
  Future<void> dispose() => _status.close();
}

FastRateTemplateModel _template(String name, {int ww = 0, int tsb = 1}) =>
    FastRateTemplateModel(name: name, ww: ww, tsb: tsb, xc: 0, tr: 0, fh: 0, jl: 0, special: 0, special2: 0);

LocalDraft _draft(String tid, int updated, {String body = 'b', String? delta, bool maybeSent = false}) => LocalDraft(
  key: LocalDraftKey.threadReply(tid),
  body: body,
  delta: delta,
  updatedAt: DateTime.fromMillisecondsSinceEpoch(updated),
  maybeSent: maybeSent,
);

Map<String, dynamic> _draftItem(int updated, {String body = 'b'}) => {'updated': updated, 'body': body};

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('merge', () {
    test('templates and settings: the later updated wins whole, ties keep the forum', () {
      const local = SyncDocument({
        'rate_templates': {'updated': 20, 'items': <Object>[]},
        'settings': {
          'updated': 5,
          'values': {'threadReverseOrder': true},
        },
      });
      final remote = SyncDocument({
        'rate_templates': {
          'updated': 10,
          'items': [rateTemplateToItem(_template('a'))],
        },
        'settings': const {
          'updated': 5,
          'values': {'threadReverseOrder': false},
        },
      });
      final merged = SyncDocument.merge(local, remote);
      expect(merged.single('rate_templates'), local.single('rate_templates'));
      expect(merged.single('settings'), remote.single('settings'));
    });

    test('drafts item by item, a deletion like any other item', () {
      final local = SyncDocument({
        'drafts': {
          'reply:1': _draftItem(30, body: 'mine'),
          'reply:2': SyncDocument.tombstone(40),
          'reply:3': _draftItem(10),
        },
      });
      final remote = SyncDocument({
        'drafts': {
          'reply:1': _draftItem(20, body: 'theirs'),
          'reply:2': _draftItem(35),
          'reply:3': SyncDocument.tombstone(15),
          'reply:4': _draftItem(5),
        },
      });
      expect(SyncDocument.merge(local, remote).items('drafts'), {
        'reply:1': _draftItem(30, body: 'mine'),
        'reply:2': SyncDocument.tombstone(40),
        'reply:3': SyncDocument.tombstone(15),
        'reply:4': _draftItem(5),
      });
    });

    test('a document without the new sections merges as before, sections not known are kept', () {
      const old = SyncDocument({
        'phrases': {
          'updated': 1,
          'items': ['x'],
        },
        'future': {'v': 1},
      });
      const mine = SyncDocument({
        'rate_templates': {'updated': 2, 'items': <Object>[]},
      });
      final merged = SyncDocument.merge(mine, old);
      expect(merged.raw['future'], {'v': 1});
      expect(merged.single('rate_templates'), mine.single('rate_templates'));
      expect(merged.single('phrases'), old.single('phrases'));
    });
  });

  group('settings whitelist', () {
    test('only reading and display settings, never one tied to the device or of the sync itself', () {
      final names = {for (final s in syncedSettings) s.key.name};
      expect(names, containsAll(<String>['textScaleFactor', 'threadReverseOrder', 'autoCheckin', 'darkScheduleStart']));
      for (final key in [
        SettingsKeys.windowSize,
        SettingsKeys.windowPosition,
        SettingsKeys.netClientProxy,
        SettingsKeys.loginUid,
        SettingsKeys.locale,
        SettingsKeys.fontFamily,
        SettingsKeys.accentColor,
        SettingsKeys.accentColorFollowSystem,
        SettingsKeys.highRefreshRate,
        SettingsKeys.twoPaneLayout,
        SettingsKeys.enableBackgroundMessageService,
        SettingsKeys.autoSyncNoticeSeconds,
        SettingsKeys.offlineThreads,
        SettingsKeys.enableAutoClearImageCache,
        SettingsKeys.editorQuickPhrases,
        SettingsKeys.crossDeviceSync,
        SettingsKeys.crossDeviceSyncRateTemplates,
        SettingsKeys.crossDeviceSyncSettings,
        SettingsKeys.crossDeviceSyncDrafts,
      ]) {
        expect(names, isNot(contains(key.name)), reason: key.name);
      }
    });

    test('values of another type, out of range or of a setting not carried are not applied', () {
      final applied = syncedSettingsApplied(syncedSettingsDefaults(), {
        'threadReverseOrder': 'yes',
        'textScaleFactor': 1,
        'threadOpenPosition': 9,
        'threadFloorInteractionMode': 1,
        'windowSize': 'big',
        'darkScheduleStart': 60,
      });
      expect(applied['threadReverseOrder'], false);
      expect(applied['textScaleFactor'], 1.0);
      expect(applied['textScaleFactor'], isA<double>());
      expect(applied['threadOpenPosition'], 1);
      expect(applied['threadFloorInteractionMode'], 1);
      expect(applied['darkScheduleStart'], 60);
      expect(applied.containsKey('windowSize'), isFalse);
    });

    test('the settings repository applies a document at once', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final settings = SettingsRepository(StorageProvider(db, {}, {}));
      await settings.init();
      addTearDown(settings.dispose);
      final published = <SettingsMap>[];
      final sub = settings.settings.skip(1).listen(published.add);
      addTearDown(sub.cancel);
      await settings.setMixedValues(
        syncedSettingsChanges({
          'threadReverseOrder': true,
          'textScaleFactor': 1.2,
          'threadFloorInteractionMode': 1,
          'checkInMessage': 'hi',
        }, settings.currentSettings),
      );
      await pumpEventQueue();
      expect(published, hasLength(1));
      final s = settings.currentSettings;
      expect(s.threadReverseOrder, isTrue);
      expect(s.textScaleFactor, 1.2);
      expect(s.threadFloorInteractionMode, ThreadFloorInteractionMode.values[1]);
      expect(s.checkinMessage, 'hi');
    });
  });

  group('repository', () {
    late _FakeApi api;
    late MemorySyncLocalStore store;
    late DateTime now;
    late Set<SyncCategory> off;

    SyncRepository repo() => SyncRepository(
      api: api,
      store: store,
      enabled: () => true,
      categoryEnabled: (c) => !off.contains(c),
      now: () => now,
    );

    setUp(() {
      api = _FakeApi();
      store = MemorySyncLocalStore();
      now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      off = {};
    });

    group('rate templates', () {
      test("the newer templates of the forum replace this device's, newer ones here are written", () async {
        store
          ..templateList = [_template('old')]
          ..templatesUpdatedAt = 100;
        api.remote({
          'rate_templates': {
            'updated': 200,
            'items': [
              rateTemplateToItem(_template('a', ww: 2)),
              {'name': 'bad', 'ww': 'x'},
              rateTemplateToItem(_template('b')),
            ],
          },
        });
        expect(await repo().pull(_uid), SyncOutcome.upToDate);
        expect(store.templateList.map((t) => t.name), ['a', 'b']);
        expect(store.templateList.first.ww, 2);
        expect(store.templatesUpdatedAt, 200);

        store
          ..templateList = [_template('c')]
          ..templatesUpdatedAt = 300;
        expect(await repo().pull(_uid), SyncOutcome.pushed);
        expect(api.lastPushed['rate_templates'], {
          'updated': 300,
          'items': [rateTemplateToItem(_template('c'))],
        });
      });

      test('the first sync unites both lists by name', () async {
        store.templateList = [_template('a', ww: 1), _template('b')];
        api.remote({
          'rate_templates': {
            'updated': 50,
            'items': [rateTemplateToItem(_template('a', ww: 9)), rateTemplateToItem(_template('z'))],
          },
        });
        expect(await repo().pull(_uid), SyncOutcome.pushed);
        expect(store.templateList.map((t) => (t.name, t.ww)), [('a', 1), ('b', 0), ('z', 0)]);
        expect(store.templatesUpdatedAt, now.millisecondsSinceEpoch);
        expect((api.lastPushed['rate_templates'] as Map)['items'], hasLength(3));
      });
    });

    group('settings', () {
      test("a fresh device with the defaults says nothing and takes the forum's settings", () async {
        expect(await repo().pull(_uid), SyncOutcome.upToDate, reason: 'nothing to write on an empty forum');
        expect(api.pushes, isEmpty);
        expect(store.settingsUpdatedAt, isNull);

        api.remote({
          'settings': {
            'updated': 500,
            'values': {...syncedSettingsDefaults(), 'threadReverseOrder': true, 'newer.setting': 3},
          },
        });
        expect(await repo().pull(_uid), SyncOutcome.upToDate);
        expect(store.settingsMap['threadReverseOrder'], true);
        expect(store.settingsMap.containsKey('newer.setting'), isFalse);
        expect(store.settingsUpdatedAt, 500);
      });

      test('a device whose settings are not the defaults writes them at its first sync', () async {
        store.settingsMap = {...store.settingsMap, 'threadReverseOrder': true};
        expect(await repo().pull(_uid), SyncOutcome.pushed);
        final settings = api.lastPushed['settings'] as Map<String, dynamic>;
        expect(settings['updated'], now.millisecondsSinceEpoch);
        expect((settings['values'] as Map)['threadReverseOrder'], true);
        expect((settings['values'] as Map).keys.toSet(), {for (final s in syncedSettings) s.key.name});
      });

      test('a device with settings of its own keeps them at its first sync, the forum fills in the rest', () async {
        store.settingsMap = {...store.settingsMap, 'threadReverseOrder': true};
        api.remote({
          'settings': {
            'updated': 500,
            'values': {...syncedSettingsDefaults(), 'threadReverseOrder': false, 'textScaleFactor': 1.3},
          },
        });
        expect(await repo().pull(_uid), SyncOutcome.pushed);
        expect(store.settingsMap['threadReverseOrder'], true);
        expect(store.settingsMap['textScaleFactor'], 1.3);
        expect(store.settingsUpdatedAt, now.millisecondsSinceEpoch);
        final values = (api.lastPushed['settings'] as Map)['values'] as Map;
        expect(values['threadReverseOrder'], true);
        expect(values['textScaleFactor'], 1.3);
      });

      test('a later change here is written, keeping the values of settings this version does not carry', () async {
        api.remote({
          'settings': {
            'updated': 500,
            'values': {'threadReverseOrder': true, 'newer.setting': 3},
          },
        });
        store
          ..settingsMap = {...store.settingsMap, 'textScaleFactor': 1.3}
          ..settingsUpdatedAt = 900;
        expect(await repo().pull(_uid), SyncOutcome.pushed);
        final values = (api.lastPushed['settings'] as Map)['values'] as Map;
        expect(values['textScaleFactor'], 1.3);
        expect(values['threadReverseOrder'], false, reason: "this device's whole set is the later one");
        expect(values['newer.setting'], 3);
        expect(store.settingsMap['threadReverseOrder'], false);
      });
    });

    group('drafts', () {
      test('a draft of the forum is taken, one here is written, maybe sent included', () async {
        store.draftsByUid[_uid] = {'reply:1': _draft('1', 100, maybeSent: true)};
        api.remote({
          'drafts': {
            'reply:2': {..._draftItem(200, body: 'theirs'), 'future': 1},
          },
        });
        expect(await repo().pull(_uid), SyncOutcome.pushed);
        expect(store.draftsByUid[_uid]!['reply:2']!.body, 'theirs');
        final drafts = api.lastPushed['drafts'] as Map;
        expect(drafts['reply:1'], {'updated': 100, 'body': 'b', 'maybeSent': true});
        expect(drafts['reply:2'], {..._draftItem(200, body: 'theirs'), 'future': 1});
        expect(store.draftsSeenByUid[_uid], {'reply:1', 'reply:2'});
      });

      test('a draft deleted here is deleted on the others, a later one there stays', () async {
        store.draftsByUid[_uid] = {'reply:1': _draft('1', 100), 'reply:2': _draft('2', 100)};
        await repo().pull(_uid);
        // Sent here (deleted), edited later on another device.
        store.draftsByUid[_uid]!.remove('reply:1');
        store.draftsByUid[_uid]!.remove('reply:2');
        final stored = jsonDecode((api.pullAnswer as SyncPulled).data!) as Map<String, dynamic>;
        api.remote({
          ...stored,
          'drafts': {
            ...stored['drafts'] as Map<String, dynamic>,
            'reply:2': _draftItem(now.millisecondsSinceEpoch + 1, body: 'later'),
          },
        }, updated: 9);
        expect(await repo().pull(_uid), SyncOutcome.pushed);
        final drafts = api.lastPushed['drafts'] as Map;
        expect(drafts['reply:1'], SyncDocument.tombstone(now.millisecondsSinceEpoch));
        expect(drafts['reply:2'], _draftItem(now.millisecondsSinceEpoch + 1, body: 'later'));
        expect(store.draftsByUid[_uid]!.keys, ['reply:2']);
      });

      test('a deletion of the forum deletes an older draft here, not a newer one', () async {
        // Deletion records are kept for half a year: times near now.
        final t = now.millisecondsSinceEpoch;
        store.draftsByUid[_uid] = {'reply:1': _draft('1', t - 900), 'reply:2': _draft('2', t - 100)};
        api.remote({
          'drafts': {'reply:1': SyncDocument.tombstone(t - 500), 'reply:2': SyncDocument.tombstone(t - 500)},
        });
        expect(await repo().pull(_uid), SyncOutcome.pushed);
        expect(store.draftsByUid[_uid]!.keys, ['reply:2']);
        expect((api.lastPushed['drafts'] as Map)['reply:1'], SyncDocument.tombstone(t - 500));
        expect((api.lastPushed['drafts'] as Map)['reply:2'], _draftItem(t - 100));
      });

      test("the same time leaves this device's draft with its editor document", () async {
        store.draftsByUid[_uid] = {'reply:1': _draft('1', 100, delta: '[{"insert":"x"}]')};
        api.remote({
          'drafts': {'reply:1': _draftItem(100)},
        });
        await repo().pull(_uid);
        expect(store.draftsByUid[_uid]!['reply:1']!.delta, isNotNull);
        expect(store.writes.where((w) => w.contains('Draft')), isEmpty);
      });

      test('switched off then on: drafts another device wrote meanwhile are not deleted', () async {
        store.draftsByUid[_uid] = {'reply:1': _draft('1', 100)};
        await repo().pull(_uid);
        off = {SyncCategory.drafts};
        final stored = jsonDecode((api.pullAnswer as SyncPulled).data!) as Map<String, dynamic>;
        api.remote({
          ...stored,
          'drafts': {...stored['drafts'] as Map<String, dynamic>, 'reply:5': _draftItem(300)},
        }, updated: 9);
        expect(await repo().pull(_uid), SyncOutcome.upToDate, reason: 'nothing of the drafts read or written');
        expect(store.draftsByUid[_uid]!.keys, ['reply:1']);
        off = {};
        await repo().pull(_uid);
        expect(store.draftsByUid[_uid]!.keys.toSet(), {'reply:1', 'reply:5'});
        // Whatever was written, the forum's document still holds the draft of the other device.
        final forum = SyncDocument.parse((api.pullAnswer as SyncPulled).data);
        expect(forum.items('drafts')['reply:5'], _draftItem(300));
      });

      test('a large draft goes without its editor document, a larger one stays here', () async {
        store.draftsByUid[_uid] = {
          'reply:1': _draft('1', 100, body: 'short', delta: 'd' * 9000),
          'reply:2': _draft('2', 200, body: 'x' * 9000),
          'reply:3': _draft('3', 300),
        };
        expect(await repo().pull(_uid), SyncOutcome.pushed);
        final drafts = api.lastPushed['drafts'] as Map;
        expect(drafts['reply:1'], _draftItem(100, body: 'short'));
        expect(drafts.containsKey('reply:2'), isFalse);
        expect(drafts['reply:3'], _draftItem(300));
        // Not sent is not deleted.
        expect(await repo().pull(_uid), SyncOutcome.upToDate);
        expect(store.draftsByUid[_uid]!.keys, hasLength(3));
      });

      test('the drafts keep within their budget, the latest first', () async {
        store.draftsByUid[_uid] = {
          for (var i = 1; i <= 10; i++) 'reply:$i': _draft('$i', i * 100, body: '字' * 2000),
        };
        expect(await repo().pull(_uid), SyncOutcome.pushed);
        final drafts = api.lastPushed['drafts'] as Map<String, dynamic>;
        expect(utf8.encode(jsonEncode(drafts)).length, lessThanOrEqualTo(syncDraftsMaxBytes));
        expect(drafts.keys.toSet(), {'reply:10', 'reply:9'});
        // The drafts left out are not deletions.
        expect(await repo().pull(_uid), SyncOutcome.upToDate);
        expect(store.draftsByUid[_uid], hasLength(10));
        final forum = SyncDocument.parse((api.pullAnswer as SyncPulled).data);
        expect(forum.items('drafts').values.where(SyncDocument.isDeleted), isEmpty);
      });

      test('a document the forum refuses as too large is fitted to its limit and written after the debounce', () async {
        store.draftsByUid[_uid] = {'reply:1': _draft('1', 100, body: 'x' * 4000)};
        store.phraseList = ['p'];
        api.pushAnswers.addAll([const SyncTooLarge(3000), const SyncPushed(7)]);
        final r = repo();
        addTearDown(r.dispose);
        expect(await r.pull(_uid), SyncOutcome.failed);
        expect(api.pushes, hasLength(1));
        expect(jsonDecode(api.pushes.first.data), contains('drafts'));
        // Not at once: the plugin answers a write right after a 413 with 429 (busy).
        expect(r.pushScheduled, isTrue);
        expect(await r.pushNow(_uid), SyncOutcome.pushed);
        expect(api.pushes, hasLength(2));
        expect(api.pushes.last.data.length, lessThanOrEqualTo(3000 - 2048));
        expect(api.lastPushed.containsKey('drafts'), isFalse);
        expect(api.lastPushed['phrases'], isNotNull);
        expect(store.draftsByUid[_uid], hasLength(1), reason: 'a draft left out is not deleted');
      });

      test('a forum limit not given leaves the document as it is', () async {
        store.draftsByUid[_uid] = {'reply:1': _draft('1', 100)};
        api.pushAnswers.add(const SyncTooLarge(0));
        expect(await repo().pull(_uid), SyncOutcome.failed);
        expect(api.pushes, hasLength(1));
      });

      test("drafts lost here (their file set aside) are no deletion: the forum's come back", () async {
        store.draftsByUid[_uid] = {'reply:1': _draft('1', 100)};
        await repo().pull(_uid);
        expect(store.draftsSeenByUid[_uid], {'reply:1'});
        store.draftsSetAside.add(_uid);
        await repo().pull(_uid);
        final forum = SyncDocument.parse((api.pullAnswer as SyncPulled).data);
        expect(forum.items('drafts')['reply:1'], _draftItem(100));
        expect(store.draftsByUid[_uid]!.keys, ['reply:1']);
      });

      test('private message drafts stay on their device, in either direction', () async {
        final t = now.millisecondsSinceEpoch;
        store.draftsByUid[_uid] = {
          'pm:77': LocalDraft(
            key: LocalDraftKey.message('77'),
            body: 'secret',
            updatedAt: DateTime.fromMillisecondsSinceEpoch(t),
          ),
          'reply:1': _draft('1', t),
        };
        // A document holding one (written by another build): not taken, and dropped from what is written back.
        api.remote({
          'drafts': {'pm:88': _draftItem(t, body: 'theirs'), 'pm:77': SyncDocument.tombstone(t + 10)},
        });
        expect(await repo().pull(_uid), SyncOutcome.pushed);
        final drafts = api.lastPushed['drafts'] as Map;
        expect(drafts.keys, ['reply:1']);
        expect(store.draftsByUid[_uid]!.keys.toSet(), {'pm:77', 'reply:1'});
        expect(store.draftsSeenByUid[_uid], {'reply:1'});
        // Deleted here: no deletion sent either.
        store.draftsByUid[_uid]!.remove('pm:77');
        expect(await repo().pull(_uid), SyncOutcome.upToDate);
      });

      test('a draft deleted while a run is on its way is not written back, the next run deletes it', () async {
        final t = now.millisecondsSinceEpoch;
        store.draftsByUid[_uid] = {'reply:1': _draft('1', t - 100)};
        await repo().pull(_uid);
        // Another device edits it later; this device deletes it right after the run read the drafts.
        final stored = jsonDecode((api.pullAnswer as SyncPulled).data!) as Map<String, dynamic>;
        api.remote({
          ...stored,
          'drafts': {'reply:1': _draftItem(t - 50, body: 'edited')},
        }, updated: 9);
        store.afterDraftsRead = (uid) {
          store.draftsByUid[uid]!.remove('reply:1');
          store.afterDraftsRead = null;
        };
        await repo().pull(_uid);
        expect(store.draftsByUid[_uid], isEmpty, reason: 'not written back');
        expect(store.draftsSeenByUid[_uid], contains('reply:1'));
        expect(await repo().pull(_uid), SyncOutcome.pushed);
        expect((api.lastPushed['drafts'] as Map)['reply:1'], SyncDocument.tombstone(t));
        expect(store.draftsByUid[_uid], isEmpty);
      });

      test('the draft store tells once that a damaged file was set aside', () async {
        final dir = await Directory.systemTemp.createTemp('drafts');
        addTearDown(() => dir.delete(recursive: true));
        File('${dir.path}/$_uid.json').writeAsStringSync('{broken');
        final drafts = LocalDraftStore(directory: () async => dir);
        expect(await drafts.listForSync(_uid), isEmpty);
        expect(drafts.takeSetAside(_uid), isTrue);
        expect(drafts.takeSetAside(_uid), isFalse);
        expect(File('${dir.path}/$_uid.json.bad').existsSync(), isTrue);
      });

      test('unreadable drafts are left alone', () async {
        store.draftsUnreadable.add(_uid);
        store.draftsSeenByUid[_uid] = {'reply:1'};
        api.remote({
          'drafts': {'reply:1': _draftItem(100)},
        });
        expect(await repo().pull(_uid), SyncOutcome.upToDate);
        expect(api.pushes, isEmpty);
      });
    });

    test('a category switched off is neither applied nor written', () async {
      off = {SyncCategory.rateTemplates, SyncCategory.settings, SyncCategory.drafts};
      store
        ..templateList = [_template('mine')]
        ..templatesUpdatedAt = 900
        ..settingsMap = {...store.settingsMap, 'threadReverseOrder': true}
        ..settingsUpdatedAt = 900
        ..draftsByUid[_uid] = {'reply:1': _draft('1', 900)};
      final remote = {
        'rate_templates': {
          'updated': 100,
          'items': [rateTemplateToItem(_template('theirs'))],
        },
        'settings': {
          'updated': 100,
          'values': {'textScaleFactor': 1.4},
        },
        'drafts': {'reply:2': _draftItem(100)},
      };
      api.remote(remote);
      expect(await repo().pull(_uid), SyncOutcome.upToDate);
      expect(store.templateList.single.name, 'mine');
      expect(store.settingsMap['textScaleFactor'], 1.0);
      expect(store.draftsByUid[_uid]!.keys, ['reply:1']);
    });
  });

  group('coordinator', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late UserBlockRepository blocks;
    late _FakeApi api;
    late MemorySyncLocalStore store;
    late _Auth auth;
    late StreamController<int> draftChanges;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      await settings.init();
      blocks = UserBlockRepository(storage);
      api = _FakeApi();
      store = MemorySyncLocalStore();
      auth = _Auth();
      draftChanges = StreamController<int>.broadcast();
    });

    tearDown(() async {
      await draftChanges.close();
      await auth.dispose();
      await blocks.dispose();
      await settings.dispose();
      await db.close();
    });

    SyncCoordinator coordinator() => SyncCoordinator(
      repository: SyncRepository(
        api: api,
        store: store,
        enabled: () => settings.currentSettings.crossDeviceSync,
        currentUid: () => auth.effectiveCurrentUid,
        categoryEnabled: (c) => SyncCoordinator.categoryEnabledIn(settings.currentSettings, c),
        debounce: const Duration(milliseconds: 300),
      ),
      authentication: auth,
      settings: settings,
      blocks: blocks,
      storage: storage,
      draftChanges: draftChanges.stream,
    );

    Future<SyncCoordinator> started() async {
      final c = coordinator()..start();
      addTearDown(c.dispose);
      await pumpEventQueue();
      // Let the start's pull end.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      c.repository.cancelScheduled();
      return c;
    }

    test('a change of the templates stamps and schedules a write', () async {
      final c = await started();
      await storage.saveFastRateTemplate(_template('a')).run();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.repository.pushScheduled, isTrue);
      expect(store.templatesUpdatedAt, isNotNull);
    });

    test('a synced setting schedules a write, a setting of the device does not', () async {
      final c = await started();
      await settings.setValue(SettingsKeys.windowRememberSize, false);
      await pumpEventQueue();
      expect(c.repository.pushScheduled, isFalse);
      expect(store.settingsUpdatedAt, isNull);
      await settings.setValue(SettingsKeys.threadReverseOrder, true);
      await pumpEventQueue();
      expect(c.repository.pushScheduled, isTrue);
      expect(store.settingsUpdatedAt, isNotNull);
    });

    test('a change of the drafts of the account schedules a write, of another account not', () async {
      final c = await started();
      draftChanges.add(_uid + 1);
      await pumpEventQueue();
      expect(c.repository.pushScheduled, isFalse);
      draftChanges.add(_uid);
      await pumpEventQueue();
      expect(c.repository.pushScheduled, isTrue);
    });

    test('switching a category on pulls', () async {
      await settings.setValue(SettingsKeys.crossDeviceSyncDrafts, false);
      await started();
      final before = api.pulls;
      await settings.setValue(SettingsKeys.crossDeviceSyncDrafts, true);
      await pumpEventQueue();
      expect(api.pulls, before + 1);
    });
  });
}
