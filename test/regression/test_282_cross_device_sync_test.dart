/// Cross-device sync (plugin 3.4.0, `sync`): the reading progress, the quick phrases and the block list of an account
/// kept on the forum as one document and merged on every device the account logs in on.
///
/// * The merge: per item the later `updated` wins, a tie keeps the forum's item, a deletion is an item with
///   `deleted: true` that wins like any other, fields this version does not know are kept and written back.
/// * The repository against a fake forum: a pull applies the forum's newer items here and writes back what this
///   device had newer; a refused write (409, another device wrote meanwhile) is merged and tried once more; a plugin
///   that keeps no documents (`supported: 0`, or an older one without the action) switches the sync off for an hour;
///   with the setting off nothing is asked.
/// * A local change is written once after the debounce, a burst of changes once.
///
/// Synthetic data, no real account or forum.
library;

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
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/features/sync/repository/sync_local_store.dart';
import 'package:tsdm_client/features/sync/repository/sync_repository.dart';
import 'package:tsdm_client/features/sync/sync_coordinator.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const _uid = 3000;

/// A forum that answers from [pullAnswer] and the queued [pushAnswers] (the last one stays), and records every call.
final class _FakeApi implements SyncApi {
  SyncPullAnswer pullAnswer = const SyncPulled(updated: 0, data: null, formhash: 'fh', uid: _uid);

  /// The account the forum names in its answers (the session's).
  int answeredUid = _uid;
  final pushAnswers = <SyncPushAnswer>[];
  final pulls = <int>[];
  final pushes = <({String data, int base, String formhash})>[];

  /// The forum's own document: a successful push replaces it, a pull answers it. Null until a push.
  String? stored;
  int storedUpdated = 0;

  @override
  Future<SyncPullAnswer> pull() async {
    pulls.add(pulls.length);
    final answer = pullAnswer;
    return answer is SyncPulled
        ? SyncPulled(updated: answer.updated, data: answer.data, formhash: answer.formhash, uid: answeredUid)
        : answer;
  }

  @override
  Future<SyncPushAnswer> push({required String data, required int baseUpdated, required String formhash}) async {
    pushes.add((data: data, base: baseUpdated, formhash: formhash));
    final current = pullAnswer is SyncPulled ? (pullAnswer as SyncPulled).updated : storedUpdated;
    final answer = pushAnswers.isEmpty
        ? SyncPushed(current + 1)
        : (pushAnswers.length > 1 ? pushAnswers.removeAt(0) : pushAnswers.first);
    if (answer is SyncPushed) {
      stored = data;
      storedUpdated = answer.updated;
      pullAnswer = SyncPulled(updated: storedUpdated, data: stored, formhash: 'fh');
    }
    return answer;
  }

  Map<String, dynamic> get lastPushed => jsonDecode(pushes.last.data) as Map<String, dynamic>;
}

/// The account in use, switchable (the coordinator follows it).
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(int uid) : _uid = uid {
    _status.add(AuthStatusAuthed(UserLoginInfo(username: 'u$uid', uid: uid)));
  }

  int? _uid;
  final _status = BehaviorSubject<AuthStatus>();

  @override
  int? get effectiveCurrentUid => _uid;

  @override
  UserLoginInfo? get currentUser => _uid == null ? null : UserLoginInfo(username: 'u$_uid', uid: _uid);

  @override
  Stream<AuthStatus> get status => _status.stream;

  void switchTo(int uid) {
    _uid = uid;
    _status.add(AuthStatusAuthed(UserLoginInfo(username: 'u$uid', uid: uid)));
  }

  @override
  Future<void> dispose() => _status.close();
}

SyncVisit _visit(int tid, int updated, {int? floor, String title = 't'}) =>
    SyncVisit(tid: tid, title: title, fid: 7, forumName: 'f', updated: updated, floor: floor);

/// A document of [raw] (a plain call, so the literals need not be const).
SyncDocument _doc(Map<String, dynamic> raw) => SyncDocument(raw);

Map<String, dynamic> _visitItem(int updated, {int? floor, String title = 't'}) => {
  'updated': updated,
  'title': title,
  'fid': 7,
  'forum': 'f',
  'floor': ?floor,
};

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('merge', () {
    test('per item the later updated wins, whole item, in either direction', () {
      final local = _doc({
        'schema': 1,
        'visits': {
          '1': _visitItem(200, floor: 5),
          '2': _visitItem(100, floor: 1),
        },
      });
      final remote = _doc({
        'schema': 1,
        'visits': {
          '1': _visitItem(100, floor: 9),
          '2': _visitItem(300, floor: 7),
          '3': _visitItem(50),
        },
      });
      final merged = SyncDocument.merge(local, remote);
      expect(merged.items('visits')['1'], _visitItem(200, floor: 5));
      expect(merged.items('visits')['2'], _visitItem(300, floor: 7));
      expect(merged.items('visits')['3'], _visitItem(50));
    });

    test('equal timestamps keep the forum item', () {
      final local = _doc({
        'schema': 1,
        'visits': {'1': _visitItem(100, floor: 5)},
      });
      final remote = _doc({
        'schema': 1,
        'visits': {'1': _visitItem(100, floor: 9)},
      });
      expect(SyncDocument.merge(local, remote).items('visits')['1'], _visitItem(100, floor: 9));
      expect(SyncDocument.merge(remote, local).items('visits')['1'], _visitItem(100, floor: 5));
    });

    test('a deletion is an item too: a later tombstone removes, a later visit revives', () {
      final local = _doc({
        'schema': 1,
        'visits': {'1': _visitItem(100), '2': SyncDocument.tombstone(500)},
      });
      final remote = _doc({
        'schema': 1,
        'visits': {'1': SyncDocument.tombstone(200), '2': _visitItem(400)},
      });
      final merged = SyncDocument.merge(local, remote).items('visits');
      expect(SyncDocument.isDeleted(merged['1']!), isTrue);
      expect(SyncDocument.isDeleted(merged['2']!), isTrue);
      expect(SyncDocument.updatedOf(merged['2']!), 500);
    });

    test('phrases and blocks merge the same way', () {
      final local = _doc({
        'schema': 1,
        'phrases': {
          'updated': 10,
          'items': <String>['a'],
        },
        'blocks': {
          '9': {'updated': 10, 'username': 'nine'},
        },
      });
      final remote = _doc({
        'schema': 1,
        'phrases': {
          'updated': 20,
          'items': <String>['b', 'c'],
        },
        'blocks': {
          '9': SyncDocument.tombstone(30),
          '8': {'updated': 5, 'username': 'eight'},
        },
      });
      final merged = SyncDocument.merge(local, remote);
      expect(merged.single('phrases'), {
        'updated': 20,
        'items': <String>['b', 'c'],
      });
      expect(SyncDocument.isDeleted(merged.items('blocks')['9']!), isTrue);
      expect(merged.items('blocks')['8'], {'updated': 5, 'username': 'eight'});
    });

    test('unknown fields are kept: at the top, inside a section and inside a winning item', () {
      final local = _doc({
        'schema': 1,
        'mine': 1,
        'visits': {
          '1': {..._visitItem(300), 'future': 'x'},
        },
        'phrases': {'updated': 1, 'items': <String>[], 'extra': true},
      });
      final remote = _doc({
        'schema': 1,
        'theirs': {'a': 1},
        'drafts': {'7': 'kept as it is'},
        'visits': {
          '1': {..._visitItem(100), 'other': 2},
        },
      });
      final merged = SyncDocument.merge(local, remote);
      expect(merged.raw['mine'], 1);
      expect(merged.raw['theirs'], {'a': 1});
      expect(merged.raw['drafts'], {'7': 'kept as it is'});
      expect(merged.items('visits')['1'], {..._visitItem(300), 'future': 'x'});
      expect(merged.single('phrases')!['extra'], true);
      // A section neither knows: the forum's, when it has one.
      final both = SyncDocument.merge(
        const SyncDocument({'schema': 1, 'x': 1}),
        const SyncDocument({'schema': 1, 'x': 2}),
      );
      expect(both.raw['x'], 2);
    });

    test('the text is stable and damaged text reads as empty', () {
      final a = _doc({
        'schema': 1,
        'visits': {'2': _visitItem(1), '1': _visitItem(2)},
      });
      final b = _doc({
        'visits': {'1': _visitItem(2), '2': _visitItem(1)},
        'schema': 1,
      });
      expect(a.encode(), b.encode());
      expect(SyncDocument.parse('not json').raw, {'schema': 1});
      expect(SyncDocument.parse('[1,2]').raw, {'schema': 1});
      expect(SyncDocument.parse(null).raw, {'schema': 1});
      expect(SyncDocument.parse('{"schema":0,"visits":{"1":{"updated":5}},"drop":"no"}').raw['drop'], 'no');
    });
  });

  group('repository', () {
    late _FakeApi api;
    late MemorySyncLocalStore store;
    late DateTime now;
    var enabled = true;

    SyncRepository repo({Duration debounce = const Duration(seconds: 30)}) => SyncRepository(
      api: api,
      store: store,
      enabled: () => enabled,
      now: () => now,
      debounce: debounce,
    );

    setUp(() {
      api = _FakeApi();
      store = MemorySyncLocalStore();
      now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      enabled = true;
    });

    test('the first pull of an empty forum writes what this device has', () async {
      store.visitsByUid[_uid] = {12: _visit(12, 1000, floor: 3)};
      store.phraseList = ['hi'];
      store.blocksByUid[_uid] = [const SyncBlock(uid: 77, username: 'x', updated: 500)];
      final outcome = await repo().pull(_uid);
      expect(outcome, SyncOutcome.pushed);
      expect(api.pulls, hasLength(1));
      expect(api.pushes, hasLength(1));
      expect(api.pushes.single.base, 0);
      expect(api.pushes.single.formhash, 'fh');
      final doc = api.lastPushed;
      expect(doc['schema'], 1);
      expect(doc['visits'], {'12': _visitItem(1000, floor: 3)});
      // Phrases never stamped before: stamped now, since there are some.
      expect(doc['phrases'], {
        'updated': now.millisecondsSinceEpoch,
        'items': <String>['hi'],
      });
      expect(doc['blocks'], {
        '77': {'updated': 500, 'username': 'x'},
      });
      expect(store.lastByUid[_uid], (document: api.stored, updated: 1));
      expect(store.writes, isEmpty);
    });

    test('a pull applies the newer items of the forum here and writes nothing back when nothing is newer', () async {
      store.visitsByUid[_uid] = {12: _visit(12, 1000, floor: 3), 13: _visit(13, 9000)};
      store.phraseList = ['old'];
      store.phrasesUpdatedAt = 100;
      store.blocksByUid[_uid] = [const SyncBlock(uid: 77, username: 'x', updated: 500)];
      final remote = {
        'schema': 1,
        'visits': {
          '12': _visitItem(2000, floor: 8, title: 'newer'),
          '13': _visitItem(9000),
          '14': _visitItem(3000, floor: 1),
        },
        'phrases': {
          'updated': 200,
          'items': ['new', 'phrases'],
        },
        'blocks': {
          '77': {'updated': 500, 'username': 'x'},
          '78': {'updated': 600, 'username': 'y'},
        },
      };
      api.pullAnswer = SyncPulled(updated: 5, data: jsonEncode(remote), formhash: 'fh');
      expect(await repo().pull(_uid), SyncOutcome.upToDate);
      expect(api.pushes, isEmpty);
      expect(store.visitsByUid[_uid]![12], _visit(12, 2000, floor: 8, title: 'newer'));
      expect(store.visitsByUid[_uid]![14], _visit(14, 3000, floor: 1));
      expect(store.phraseList, ['new', 'phrases']);
      expect(store.phrasesUpdatedAt, 200);
      expect(store.blocksByUid[_uid], [
        const SyncBlock(uid: 77, username: 'x', updated: 500),
        const SyncBlock(uid: 78, username: 'y', updated: 600),
      ]);
      expect(store.writes, unorderedEquals(['saveVisit 12', 'saveVisit 14', 'savePhrases', 'saveBlocks']));
      expect(store.lastByUid[_uid], (document: SyncDocument(remote).encode(), updated: 5));
    });

    test('both sides changed: the forum gets the merge, this device the rest', () async {
      store.visitsByUid[_uid] = {12: _visit(12, 5000, floor: 3)};
      store.phraseList = ['mine'];
      store.phrasesUpdatedAt = 900;
      final remote = {
        'schema': 1,
        'visits': {'12': _visitItem(2000, floor: 8), '14': _visitItem(3000)},
        'phrases': {
          'updated': 200,
          'items': ['theirs'],
        },
        'keep': 'me',
      };
      api.pullAnswer = SyncPulled(updated: 5, data: jsonEncode(remote), formhash: 'fh');
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      expect(api.pushes.single.base, 5);
      final doc = api.lastPushed;
      expect(doc['visits'], {'12': _visitItem(5000, floor: 3), '14': _visitItem(3000)});
      expect(doc['phrases'], {
        'updated': 900,
        'items': ['mine'],
      });
      expect(doc['keep'], 'me');
      expect(store.visitsByUid[_uid]![14], _visit(14, 3000));
      expect(store.phraseList, ['mine']);
      expect(store.writes, ['saveVisit 14']);
      expect(store.lastByUid[_uid]!.updated, 6);
    });

    test('a refused write (another device wrote meanwhile) is merged and tried once more', () async {
      store.visitsByUid[_uid] = {12: _visit(12, 5000)};
      final other = {
        'schema': 1,
        'visits': {'12': _visitItem(2000), '15': _visitItem(7000)},
      };
      api.pushAnswers.add(SyncConflict(updated: 9, data: jsonEncode(other)));
      api.pushAnswers.add(const SyncPushed(10));
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      expect(api.pushes, hasLength(2));
      expect(api.pushes.first.base, 0);
      expect(api.pushes.last.base, 9);
      expect(api.lastPushed['visits'], {'12': _visitItem(5000), '15': _visitItem(7000)});
      expect(store.visitsByUid[_uid]![15], _visit(15, 7000));
      expect(store.lastByUid[_uid]!.updated, 10);
    });

    test('a write refused twice waits for the next run', () async {
      store.visitsByUid[_uid] = {12: _visit(12, 5000)};
      api.pushAnswers.add(const SyncConflict(updated: 9, data: '{"schema":1}'));
      expect(await repo().pull(_uid), SyncOutcome.failed);
      expect(api.pushes, hasLength(2));
      // The forum's last known document is kept, so the next run sends the change again.
      expect(store.lastByUid[_uid]!.updated, 9);
    });

    test('a plugin that keeps no documents switches the sync off for an hour', () async {
      api.pullAnswer = const SyncUnsupported();
      final r = repo();
      expect(await r.pull(_uid), SyncOutcome.unsupported);
      expect(r.unsupported, isTrue);
      expect(await r.pull(_uid), SyncOutcome.unsupported);
      expect(await r.pushNow(_uid), SyncOutcome.unsupported);
      r.schedulePush(_uid);
      expect(r.pushScheduled, isFalse);
      expect(api.pulls, hasLength(1));
      now = now.add(const Duration(minutes: 59));
      expect(await r.pull(_uid), SyncOutcome.unsupported);
      expect(api.pulls, hasLength(1));
      now = now.add(const Duration(minutes: 2));
      api.pullAnswer = const SyncPulled(updated: 0, data: null, formhash: 'fh');
      expect(await r.pull(_uid), isNot(SyncOutcome.unsupported));
      expect(api.pulls, hasLength(2));
    });

    test('with the setting off nothing is asked', () async {
      enabled = false;
      store.visitsByUid[_uid] = {12: _visit(12, 5000)};
      final r = repo();
      expect(await r.pull(_uid), SyncOutcome.disabled);
      expect(await r.pushNow(_uid), SyncOutcome.disabled);
      r.schedulePush(_uid);
      expect(r.pushScheduled, isFalse);
      expect(api.pulls, isEmpty);
      expect(api.pushes, isEmpty);
    });

    test('a logged out session changes nothing', () async {
      api.pullAnswer = const SyncNotLoggedIn();
      expect(await repo().pull(_uid), SyncOutcome.notLoggedIn);
      expect(api.pushes, isEmpty);
      expect(store.lastByUid, isEmpty);
    });

    test('a burst of local changes is written once, after the debounce', () async {
      const debounce = Duration(milliseconds: 300);
      final r = repo(debounce: debounce);
      store.visitsByUid[_uid] = {12: _visit(12, 5000)};
      r.schedulePush(_uid);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      store.visitsByUid[_uid]![13] = _visit(13, 6000);
      r.schedulePush(_uid);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(api.pushes, isEmpty, reason: 'the second change restarted the wait');
      expect(r.pushScheduled, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(api.pushes, hasLength(1));
      expect(api.lastPushed['visits'], {'12': _visitItem(5000), '13': _visitItem(6000)});
      // Nothing changed since: the next scheduled write sends nothing.
      r.schedulePush(_uid);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(api.pushes, hasLength(1));
      await r.dispose();
    });

    test('a visit removed here is removed on the forum, and one removed there is removed here', () async {
      store.visitsByUid[_uid] = {12: _visit(12, 5000), 13: _visit(13, 4000)};
      final r = repo();
      expect(await r.pull(_uid), SyncOutcome.pushed);
      // Removed here.
      store.visitsByUid[_uid]!.remove(12);
      now = now.add(const Duration(minutes: 1));
      expect(await r.pushNow(_uid), SyncOutcome.pushed);
      final visits = (api.lastPushed['visits'] as Map<String, dynamic>).cast<String, Map<String, dynamic>>();
      expect(visits['12'], {'updated': now.millisecondsSinceEpoch, 'deleted': true});
      expect(visits['13'], _visitItem(4000));
      // Removed on another device, later than this device's visit.
      final other = {
        'schema': 1,
        'visits': {'12': visits['12'], '13': SyncDocument.tombstone(now.millisecondsSinceEpoch + 1)},
      };
      api.pullAnswer = SyncPulled(updated: 20, data: jsonEncode(other), formhash: 'fh');
      expect(await r.pull(_uid), SyncOutcome.upToDate);
      expect(store.visitsByUid[_uid], isEmpty);
      expect(store.writes.last, 'deleteVisit 13');
    });

    test('a user unblocked here is unblocked on the forum', () async {
      store.blocksByUid[_uid] = [
        const SyncBlock(uid: 77, username: 'x', updated: 500),
        const SyncBlock(uid: 78, username: 'y', updated: 600),
      ];
      final r = repo();
      await r.pull(_uid);
      store.blocksByUid[_uid]!.removeAt(0);
      now = now.add(const Duration(seconds: 5));
      expect(await r.pushNow(_uid), SyncOutcome.pushed);
      expect(api.lastPushed['blocks'], {
        '77': {'updated': now.millisecondsSinceEpoch, 'deleted': true},
        '78': {'updated': 600, 'username': 'y'},
      });
    });

    test('the phrases the sync wrote itself are not stamped as a local change', () async {
      store.phraseList = ['old'];
      store.phrasesUpdatedAt = 100;
      api.pullAnswer = SyncPulled(
        updated: 5,
        data: jsonEncode({
          'schema': 1,
          'phrases': {
            'updated': 200,
            'items': ['new'],
          },
        }),
        formhash: 'fh',
      );
      final r = repo();
      await r.pull(_uid);
      expect(store.phraseList, ['new']);
      // The settings stream reports the value the sync wrote: not a change of this device.
      await r.onPhrasesChanged(_uid, jsonEncode(['new']));
      expect(store.phrasesUpdatedAt, 200);
      expect(r.pushScheduled, isFalse);
      // The user edits them: a change, stamped now.
      await r.onPhrasesChanged(_uid, jsonEncode(['new', 'mine']));
      expect(store.phrasesUpdatedAt, now.millisecondsSinceEpoch);
      expect(r.pushScheduled, isTrue);
      await r.dispose();
    });

    test('the same time on both sides: this device keeps its own progress', () async {
      store.visitsByUid[_uid] = {12: _visit(12, 5000, floor: 30)};
      api.pullAnswer = SyncPulled(
        updated: 5,
        data: jsonEncode({
          'schema': 1,
          'visits': {'12': _visitItem(5000, floor: 10)},
        }),
        formhash: 'fh',
      );
      expect(await repo().pull(_uid), SyncOutcome.upToDate);
      expect(store.visitsByUid[_uid]![12]!.floor, 30);
      expect(store.writes, isEmpty);
    });

    test('a run of an account that is no longer in use changes nothing', () async {
      store.visitsByUid[_uid] = {12: _visit(12, 5000)};
      var current = _uid;
      final r = SyncRepository(
        api: api,
        store: store,
        enabled: () => enabled,
        currentUid: () => current,
        now: () => now,
      );
      // The forum answers for another account (the session changed under the request).
      api.answeredUid = 3001;
      api.pullAnswer = SyncPulled(
        updated: 5,
        data: jsonEncode({
          'schema': 1,
          'visits': {'99': _visitItem(9000)},
        }),
        formhash: 'fh',
      );
      expect(await r.pull(_uid), SyncOutcome.accountChanged);
      expect(store.writes, isEmpty);
      expect(api.pushes, isEmpty);
      expect(store.lastByUid, isEmpty);
      // The account in use changed before the run started.
      api.answeredUid = _uid;
      current = 3001;
      expect(await r.pull(_uid), SyncOutcome.accountChanged);
      expect(await r.pushNow(_uid), SyncOutcome.accountChanged);
      expect(api.pulls, hasLength(1));
      // A scheduled write is dropped on the switch.
      current = _uid;
      r.schedulePush(_uid);
      expect(r.pushScheduled, isTrue);
      r.cancelScheduled();
      expect(r.pushScheduled, isFalse);
    });

    test('two devices with different histories: the merge is capped too, never over the limit', () async {
      store.visitsByUid[_uid] = {
        for (var i = 1; i <= 400; i++) i: _visit(i, i * 1000, title: 'mine ' * 20),
      };
      final theirs = {
        for (var i = 1001; i <= 1400; i++) '$i': _visitItem(i * 1000, title: 'theirs ' * 20),
      };
      api.pullAnswer = SyncPulled(updated: 5, data: jsonEncode({'schema': 1, 'visits': theirs}), formhash: 'fh');
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      final visits = api.lastPushed['visits'] as Map<String, dynamic>;
      expect(visits.length, lessThanOrEqualTo(syncVisitsMax));
      expect(utf8.encode(api.pushes.single.data).length, lessThanOrEqualTo(syncDocumentMaxBytes));
      // The latest of both, by time: the forum's are newer here.
      expect(visits.containsKey('1400'), isTrue);
      expect(visits.containsKey('1'), isFalse);
      // The other device's visits reached this device (what was applied is not limited by the document cap).
      expect(store.visitsByUid[_uid]!.containsKey(1400), isTrue);
    });

    test('a document of a newer schema is left alone', () async {
      store.visitsByUid[_uid] = {12: _visit(12, 5000)};
      api.pullAnswer = SyncPulled(
        updated: 5,
        data: jsonEncode({
          'schema': 2,
          'visits': {'13': _visitItem(9000)},
        }),
        formhash: 'fh',
      );
      expect(await repo().pull(_uid), SyncOutcome.newerSchema);
      expect(store.writes, isEmpty);
      expect(api.pushes, isEmpty);
      expect(store.lastByUid, isEmpty);
    });

    test('an item of the forum this version could not read is carried over, not taken for a deletion', () async {
      store.lastByUid[_uid] = (
        document: jsonEncode({
          'schema': 1,
          'visits': {
            '12': {'updated': 5000, 'future': true},
          },
        }),
        updated: 5,
      );
      api.pullAnswer = SyncPulled(updated: 5, data: store.lastByUid[_uid]!.document, formhash: 'fh');
      store.visitsByUid[_uid] = {13: _visit(13, 6000)};
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      final visits = api.lastPushed['visits'] as Map<String, dynamic>;
      expect(visits['12'], {'updated': 5000, 'future': true});
      expect(visits['13'], _visitItem(6000));
    });

    test('the first sync of a device that had phrases before unites them with the forum phrases', () async {
      store.phraseList = ['a', 'b'];
      api.pullAnswer = SyncPulled(
        updated: 5,
        data: jsonEncode({
          'schema': 1,
          'phrases': {
            'updated': 900,
            'items': ['b', 'c'],
          },
        }),
        formhash: 'fh',
      );
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      expect(store.phraseList, ['a', 'b', 'c']);
      expect(api.lastPushed['phrases'], {
        'updated': now.millisecondsSinceEpoch,
        'items': ['a', 'b', 'c'],
      });
      // Not a first sync any more: the forum's later list replaces it.
      api.pullAnswer = SyncPulled(
        updated: 7,
        data: jsonEncode({
          'schema': 1,
          'phrases': {
            'updated': now.millisecondsSinceEpoch + 1,
            'items': ['z'],
          },
        }),
        formhash: 'fh',
      );
      expect(await repo().pull(_uid), SyncOutcome.upToDate);
      expect(store.phraseList, ['z']);
    });

    test('a document over the limit drops the oldest visits', () async {
      store.visitsByUid[_uid] = {
        for (var i = 1; i <= 1200; i++) i: _visit(i, i * 1000, title: 'title ' * 10),
      };
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      final visits = api.lastPushed['visits'] as Map<String, dynamic>;
      expect(visits.length, lessThanOrEqualTo(syncVisitsMax));
      expect(utf8.encode(api.pushes.single.data).length, lessThanOrEqualTo(syncDocumentMaxBytes));
      expect(visits.containsKey('1200'), isTrue);
      expect(visits.containsKey('1'), isFalse);
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

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      await settings.init();
      blocks = UserBlockRepository(storage);
      api = _FakeApi();
      store = MemorySyncLocalStore();
      auth = _Auth(_uid);
    });

    tearDown(() async {
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
        debounce: const Duration(milliseconds: 300),
      ),
      authentication: auth,
      settings: settings,
      blocks: blocks,
      storage: storage,
    );

    test('the start pulls the account in use once, a switch pulls the new one and drops the old write', () async {
      final c = coordinator()..start();
      addTearDown(c.dispose);
      await pumpEventQueue();
      expect(api.pulls, hasLength(1), reason: 'the start and the replayed login status pull once');
      // A visit of the account: a write is scheduled.
      await storage.updateThreadVisitHistory(
        uid: _uid,
        tid: 7,
        fid: 2,
        username: 'a',
        threadTitle: 't',
        forumName: 'f',
        visitTime: DateTime.now(),
      );
      await pumpEventQueue();
      expect(c.repository.pushScheduled, isTrue);
      // The account changes before the write runs.
      auth.switchTo(3001);
      api.answeredUid = 3001;
      await pumpEventQueue();
      expect(c.repository.pushScheduled, isFalse);
      expect(api.pulls, hasLength(2), reason: 'the new account is pulled');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(api.pushes, isEmpty, reason: 'the old account write never ran');
      // Nothing of the old account reached the new one.
      expect(store.visitsByUid[3001], isNull);
    });

    test('with the setting off nothing is asked, switching it on pulls', () async {
      await settings.setValue(SettingsKeys.crossDeviceSync, false);
      final c = coordinator()..start();
      addTearDown(c.dispose);
      await pumpEventQueue();
      expect(api.pulls, isEmpty);
      await settings.setValue(SettingsKeys.crossDeviceSync, true);
      await pumpEventQueue();
      expect(api.pulls, hasLength(1));
    });
  });
}
