/// The cross-device sync of the pinned forums and of what an account watches for new threads:
///
/// * a pinned forum keeps when it was pinned, moved or renamed and a rank (where it stands); moving one changes that
///   one only; an unpinned forum leaves a record of when. Lists saved before read as they were;
/// * a forum unwatched and an alert keyword removed leave a record of when, the keyword scope the time of its last
///   change; configs saved before read as they were;
/// * the `pinned_forums`, `watch_forums`, `watch_keywords` and `watch_scope` sections of the sync document: item by
///   item the later wins, a removal like any other item, the scope whole; what a device's check knows never goes
///   with them, and a forum that arrives from another device starts from the threads it has then;
/// * sections and fields this version does not know are kept and written back; a section switched off is neither
///   read nor written; two devices writing in turn (and at once) end with the same.
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
import 'package:tsdm_client/features/forum/utils/frequent_forums.dart';
import 'package:tsdm_client/features/forum_watch/cubit/forum_watch_cubit.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_config.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_sync.dart';
import 'package:tsdm_client/features/forum_watch/repository/forum_watch_store.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_check.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_fetch.dart';
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

const int _step = frequentForumRankStep;

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
  _Api([_Forum? forum]) : forum = forum ?? _Forum();

  final _Forum forum;
  int pulls = 0;
  int conflicts = 0;
  final pushes = <String>[];

  /// Called once, after the next read was answered and before the device gets the answer (another device writes in
  /// between).
  Future<void> Function()? afterPull;

  @override
  Future<SyncPullAnswer> pull(int uid) async {
    pulls++;
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

FrequentForum _f(int fid, {String? name}) => FrequentForum(fid: fid, name: name ?? '版块$fid');

List<int> _ids(FrequentForumsOfAccount a) => [for (final e in a.pinned) e.fid];

/// An account with the forums [fids] pinned in that order, one a millisecond after the other from [at].
FrequentForumsOfAccount _pinned(List<int> fids, {int at = _t}) {
  var account = const FrequentForumsOfAccount();
  for (final (i, fid) in fids.indexed) {
    account = frequentForumsTogglePin(account, _f(fid), now: at + i);
  }
  return account;
}

Map<String, dynamic> _pin(int fid, int updated, int rank, {String? name}) => {
  'updated': updated,
  'name': name ?? '版块$fid',
  'rank': rank,
};

Map<String, dynamic> _gone(int at) => {'updated': at, 'deleted': true};

WatchedForum _w(int fid, int updated) => WatchedForum(fid: fid, name: '版块$fid', updated: updated);

WatchRow _row(int tid, {int fid = 8}) => WatchRow(tid: tid, fid: fid, title: '测试帖 $tid', author: 'someone');

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('pinned forums', () {
    test('a pin keeps its time and a rank after the last; an unpin leaves a record, a pin again is later', () {
      var a = _pinned([1, 2]);
      expect([for (final e in a.pinned) (e.fid, e.updated, e.rank)], [(1, _t, 0), (2, _t + 1, _step)]);
      a = frequentForumsTogglePin(a, _f(1), now: _t + 10);
      expect(_ids(a), [2]);
      expect(a.unpinned, {1: _t + 10});
      expect(a.recent.single.fid, 1);
      // The clock went back: still later than the record, so the pin wins on the other devices.
      a = frequentForumsTogglePin(a, _f(1), now: _t + 5);
      expect([for (final e in a.pinned) (e.fid, e.updated, e.rank)], [(2, _t + 1, _step), (1, _t + 11, 2 * _step)]);
      expect(a.unpinned, isEmpty);
      // And an unpin is later than the pin it undoes.
      a = frequentForumsTogglePin(a, _f(1), now: _t);
      expect(a.unpinned, {1: _t + 12});
    });

    test('moving a forum changes that one only: a rank between its new neighbours', () {
      final a = _pinned([1, 2, 3, 4]);
      final toFront = frequentForumsReorder(a, 3, 0, now: _t + 100);
      expect(_ids(toFront), [4, 1, 2, 3]);
      expect(
        [for (final e in toFront.pinned) (e.fid, e.updated, e.rank)],
        [
          (4, _t + 100, -_step),
          (1, _t, 0),
          (2, _t + 1, _step),
          (3, _t + 2, 2 * _step),
        ],
      );
      final toEnd = frequentForumsReorder(a, 0, 4, now: _t + 100);
      expect(_ids(toEnd), [2, 3, 4, 1]);
      expect(toEnd.pinned.last.rank, 4 * _step);
      final between = frequentForumsReorder(a, 0, 2, now: _t + 100);
      expect(_ids(between), [2, 1, 3, 4]);
      expect(between.pinned[1].rank, _step + _step ~/ 2);
      expect([for (final e in between.pinned) e.updated], [_t + 1, _t + 100, _t + 2, _t + 3]);
      // Dropped where it was: nothing changes.
      expect(frequentForumsReorder(a, 1, 2, now: _t + 100), same(a));
      expect(frequentForumsReorder(a, 1, 1, now: _t + 100), same(a));
    });

    test('no room left between two neighbours: every forum takes the rank of its place and counts as changed', () {
      var a = _pinned([1, 2, 3]);
      // The last forum moves between the first and the second, again and again: the gap halves each time.
      for (var i = 1; i <= 20; i++) {
        a = frequentForumsReorder(a, 2, 1, now: _t + 100 + i);
        expect([for (final e in a.pinned) e.rank], [0, _step >> i, _step >> (i - 1)]);
      }
      expect([for (final e in a.pinned) e.rank], [0, 1, 2]);
      expect(a.pinned.first.updated, _t, reason: 'the first forum never moved');
      // No rank is left between 0 and 1.
      final moved = a.pinned.last.fid;
      a = frequentForumsReorder(a, 2, 1, now: _t + 500);
      expect(_ids(a)[1], moved);
      expect([for (final e in a.pinned) e.rank], [0, _step, 2 * _step]);
      expect(a.pinned.every((e) => e.updated >= _t + 500), isTrue);
    });

    test('saved with the times, the ranks and the records; a list saved before reads in its order', () {
      var a = _pinned([5, 6, 7]);
      a = frequentForumsVisited(a, _f(9));
      a = frequentForumsTogglePin(a, _f(6), now: _t + 50);
      final raw = encodeFrequentForums({_uid: a});
      final back = decodeFrequentForums(raw)[_uid]!;
      expect(
        [for (final e in back.pinned) (e.fid, e.name, e.updated, e.rank)],
        [
          for (final e in a.pinned) (e.fid, e.name, e.updated, e.rank),
        ],
      );
      expect(back.unpinned, {6: _t + 50});
      expect([for (final e in back.recent) e.fid], [6, 9]);
      expect(encodeFrequentForums({_uid: back}), raw);

      // Saved by a version before the sync: no time, no rank, no records.
      const legacy = '{"31":{"pinned":[{"fid":3,"name":"c"},{"fid":1,"name":"a"}],"recent":[{"fid":2,"name":"b"}]}}';
      final old = decodeFrequentForums(legacy)[_uid]!;
      expect([for (final e in old.pinned) (e.fid, e.name, e.updated, e.rank)], [(3, 'c', 0, 0), (1, 'a', 0, _step)]);
      expect(old.unpinned, isEmpty);
      expect([for (final e in old.recent) e.fid], [2]);
      // What this version saves, a version before reads: the same lists (it looks at fid and name only).
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      expect(
        [for (final e in (saved['31'] as Map<String, dynamic>)['pinned'] as List) (e as Map<String, dynamic>)['fid']],
        [5, 7],
      );
      // An account with nothing but a record is kept: the record has yet to reach the other devices.
      final onlyRecord = frequentForumsTogglePin(_pinned([4]), _f(4), now: _t + 9);
      expect(
        decodeFrequentForums(
          encodeFrequentForums({_uid: FrequentForumsOfAccount(unpinned: onlyRecord.unpinned)}),
        )[_uid]!.unpinned,
        {4: _t + 9},
      );
    });

    test('a visit renames a pinned forum (a change of it); the same name changes nothing', () {
      final a = _pinned([1]);
      expect(frequentForumsVisited(a, _f(1), now: _t + 9).pinned.single.updated, _t);
      final renamed = frequentForumsVisited(a, _f(1, name: '新名字'), now: _t + 9);
      expect((renamed.pinned.single.name, renamed.pinned.single.updated), ('新名字', _t + 9));
    });

    test('the records of unpinned forums: half a year, the latest 30', () {
      var a = const FrequentForumsOfAccount();
      for (var fid = 1; fid <= frequentForumsUnpinnedMax + 5; fid++) {
        a = frequentForumsTogglePin(a, _f(fid), now: _t + fid * 10);
        a = frequentForumsTogglePin(a, _f(fid), now: _t + fid * 10 + 1);
      }
      expect(a.unpinned, hasLength(frequentForumsUnpinnedMax));
      expect(a.unpinned.containsKey(1), isFalse);
      expect(a.unpinned.containsKey(frequentForumsUnpinnedMax + 5), isTrue);
      final later = _t + frequentForumsUnpinnedKeptFor.inMilliseconds + 1000;
      a = frequentForumsTogglePin(a, _f(900), now: later);
      a = frequentForumsTogglePin(a, _f(900), now: later + 1);
      expect(a.unpinned.keys, [900]);
    });

    test('the items of the section, and taking the section in: the later wins, the document on the same time', () {
      final a = frequentForumsTogglePin(_pinned([1, 2, 3]), _f(3), now: _t + 50);
      expect(frequentForumsSyncItems(a), {
        '1': _pin(1, _t, 0),
        '2': _pin(2, _t + 1, _step),
        '3': _gone(_t + 50),
      });
      // Its own items change nothing.
      expect(frequentForumsWithSynced(a, frequentForumsSyncItems(a), now: _t + 60), isNull);

      final next = frequentForumsWithSynced(a, {
        // Renamed and moved to the front later.
        '2': _pin(2, _t + 70, -_step, name: '改名'),
        // Pinned again after this device unpinned it.
        '3': _pin(3, _t + 80, 5 * _step),
        // Pinned on the other device.
        '7': _pin(7, _t + 5, _step ~/ 2),
        // Unpinned there before this device pinned it: the pin stays.
        '1': _gone(_t - 1),
        // Never held here: nothing to remove. Not items: left alone.
        '8': _gone(_t + 5),
        'x': _pin(4, _t + 5, 0),
        '04': _pin(4, _t + 5, 0),
        '5': {'updated': _t + 5, 'rank': 0},
        '6': {'updated': _t + 5, 'name': '无次序'},
      }, now: _t + 90)!;
      expect(
        [for (final e in next.pinned) (e.fid, e.name, e.updated, e.rank)],
        [
          (2, '改名', _t + 70, -_step),
          (1, '版块1', _t, 0),
          (7, '版块7', _t + 5, _step ~/ 2),
          (3, '版块3', _t + 80, 5 * _step),
        ],
      );
      expect(next.unpinned, isEmpty);
      expect(next.recent, isEmpty, reason: 'forum 3 is pinned again');

      // A later removal unpins; an older item changes nothing; the same time takes the document's (other) item.
      final removed = frequentForumsWithSynced(next, {'7': _gone(_t + 6), '2': _pin(2, _t + 60, 0)}, now: _t + 90)!;
      expect(_ids(removed), [2, 1, 3]);
      expect(removed.unpinned, {7: _t + 6});
      expect(removed.recent, isEmpty, reason: 'unpinned by another device: not a visit of this one');
      final tie = frequentForumsWithSynced(removed, {'1': _pin(1, _t, 9 * _step, name: '别名')}, now: _t + 90)!;
      expect(_ids(tie), [2, 3, 1]);
      expect(tie.pinned.last.name, '别名');
      // The same rank on two forums: by forum id.
      final same = frequentForumsWithSynced(tie, {'9': _pin(9, _t + 1, 5 * _step)}, now: _t + 90)!;
      expect(_ids(same), [2, 3, 9, 1]);
    });

    test('over the limit after a merge: the latest pinned are kept, the others dropped without a record', () {
      final a = _pinned([for (var fid = 1; fid <= frequentForumsPinnedMax; fid++) fid]);
      final next = frequentForumsWithSynced(a, {
        for (var fid = 101; fid <= 105; fid++) '$fid': _pin(fid, _t + 1000 + fid, fid * _step),
      }, now: _t + 2000)!;
      expect(next.pinned, hasLength(frequentForumsPinnedMax));
      expect(_ids(next).toSet().containsAll([101, 102, 103, 104, 105]), isTrue);
      expect(_ids(next).toSet().intersection({1, 2, 3, 4, 5}), isEmpty, reason: 'the five pinned first went');
      expect(next.unpinned, isEmpty);
    });
  });

  group('the watch', () {
    test('a forum unwatched and a keyword removed leave a record; watched or added again is later', () {
      var c = const ForumWatchConfig().watching(8, name: '版块8', now: _t).withKeyword(' 芙莉莲 ', now: _t + 1);
      expect(c.forums.single, _w(8, _t));
      expect((c.keywords.single.text, c.keywords.single.updated), ('芙莉莲', _t + 1));
      c = c.unwatching(8, now: _t - 5).withoutKeyword('芙莉莲', now: _t + 9);
      expect(c.isEmpty, isTrue);
      expect(c.isBlank, isFalse);
      expect(c.removedForums, {8: _t + 1}, reason: 'the clock went back: still later than the watch');
      expect(c.removedKeywords, {'芙莉莲': _t + 9});
      c = c.watching(8, name: '版块8', now: _t).withKeyword('芙莉莲', now: _t + 20);
      expect(c.forums.single.updated, _t + 2);
      expect(c.keywords.single.updated, _t + 20);
      expect(c.removedForums, isEmpty);
      expect(c.removedKeywords, isEmpty);
      // What is not there is not removed.
      expect(c.unwatching(99, now: _t + 30), same(c));
      expect(c.withoutKeyword('none', now: _t + 30), same(c));
    });

    test('the scope keeps the time of its last change; the same choice is no change', () {
      const c = ForumWatchConfig();
      expect(c.withScope(const KeywordScope(), now: _t), same(c));
      final custom = c.withScope(const KeywordScope(custom: true, latest: false), now: _t);
      expect((custom.scope.custom, custom.scope.latest, custom.scope.updated), (true, false, _t));
      expect(custom.withScope(custom.scope.copyWith(), now: _t + 5), same(custom));
      // Back to the default: a change like any other, later even when the clock went back.
      final back = custom.withScope(const KeywordScope(), now: _t - 1);
      expect((back.scope.custom, back.scope.updated), (false, _t + 1));
      expect(back.isBlank, isFalse);
    });

    test('stored with the records; a config stored before reads as it was', () {
      final c = const ForumWatchConfig()
          .watching(8, name: '版块8', now: _t)
          .watching(9, name: '版块9', now: _t + 1)
          .unwatching(9, now: _t + 2)
          .withKeyword('Key', now: _t + 3)
          .withKeyword('旧', now: _t + 4)
          .withoutKeyword('旧', now: _t + 5)
          .withScope(
            const KeywordScope(custom: true, forums: [WatchedForum(fid: 3, name: 'x', updated: 2)]),
            now: _t,
          );
      final back = ForumWatchConfig.fromJson(jsonDecode(jsonEncode(c)));
      expect(back, c);
      expect(back.removedForums, {9: _t + 2});
      expect(back.removedKeywords, {'旧': _t + 5});
      expect(back.scope.updated, _t);

      // Stored by the version before the sync: no records, no time of the scope.
      final old = ForumWatchConfig.fromJson(const {
        'forums': [
          {'fid': 8, 'name': '版块8', 'at': 5},
        ],
        'keywords': [
          {'text': 'k', 'at': 6},
        ],
        'scope': {'custom': true, 'latest': false, 'forums': <Object>[]},
      });
      expect((old.forums.single, old.keywords.single.updated), (_w(8, 5), 6));
      expect((old.scope.custom, old.scope.latest, old.scope.updated), (true, false, 0));
      expect(old.removedForums, isEmpty);
      expect(old.removedKeywords, isEmpty);
      // Records that are not records are left out.
      final odd = ForumWatchConfig.fromJson(const {
        'gone_forums': {'8': 5, 'x': 5, '0': 5, '9': 'soon'},
        'gone_keywords': {'k': 5, 'K': 5, '': 5},
      });
      expect(odd.removedForums, {8: 5});
      expect(odd.removedKeywords, {'k': 5});
    });

    test('the records: half a year, the latest 30 forums and 50 keywords', () {
      var c = const ForumWatchConfig();
      for (var i = 1; i <= forumWatchKeywordRemovalMax + 3; i++) {
        c = c.withKeyword('k$i', now: _t + i * 10).withoutKeyword('k$i', now: _t + i * 10 + 1);
        c = c.watching(i, name: '', now: _t + i * 10).unwatching(i, now: _t + i * 10 + 1);
      }
      expect(c.removedKeywords, hasLength(forumWatchKeywordRemovalMax));
      expect(c.removedKeywords.containsKey('k1'), isFalse);
      expect(c.removedForums, hasLength(forumWatchForumRemovalMax));
      expect(c.removedForums.containsKey(forumWatchKeywordRemovalMax + 3), isTrue);
      final later = _t + forumWatchRemovalKeptFor.inMilliseconds + 5000;
      c = c.watching(8, name: '', now: later).unwatching(8, now: later + 1);
      expect(c.removedForums, {8: later + 1});
      c = c.withKeyword('new', now: later).withoutKeyword('new', now: later + 1);
      expect(c.removedKeywords.keys, ['new']);
    });

    test('the items of the sections: what is watched and the records, the scope once it was changed', () {
      final c = const ForumWatchConfig()
          .watching(8, name: '版块8', now: _t)
          .watching(9, name: '版块9', now: _t + 1)
          .unwatching(9, now: _t + 2)
          .withKeyword('ABC def', now: _t + 3)
          .withKeyword('旧', now: _t + 4)
          .withoutKeyword('旧', now: _t + 5);
      expect(forumWatchForumItems(c), {
        '8': {'updated': _t, 'name': '版块8'},
        '9': _gone(_t + 2),
      });
      expect(forumWatchKeywordItems(c), {
        'abc def': {'updated': _t + 3, 'text': 'ABC def'},
        '旧': _gone(_t + 5),
      });
      expect(forumWatchScopeItem(c), isNull, reason: 'never changed: nothing to say');
      final scoped = c.withScope(
        const KeywordScope(custom: true, latest: false, forums: [WatchedForum(fid: 3, name: '版块3', updated: 7)]),
        now: _t + 6,
      );
      expect(forumWatchScopeItem(scoped), {
        'updated': _t + 6,
        'custom': true,
        'latest': false,
        'forums': [
          {'fid': 3, 'name': '版块3'},
        ],
      });
      // Nothing of the check: no mark, no alert, no time of a check.
      final text = jsonEncode([
        forumWatchForumItems(scoped),
        forumWatchKeywordItems(scoped),
        forumWatchScopeItem(scoped),
      ]);
      for (final word in ['marks', 'alerts', 'tid', 'checked']) {
        expect(text, isNot(contains(word)));
      }
    });

    test('taking the sections in: the later wins, the document on the same time, the scope whole', () {
      final c = const ForumWatchConfig()
          .watching(8, name: '版块8', now: _t)
          .watching(9, name: '版块9', now: _t + 1)
          .unwatching(9, now: _t + 2)
          .withKeyword('mine', now: _t + 3)
          .withScope(const KeywordScope(custom: true), now: _t + 4);
      // Its own items change nothing.
      expect(
        forumWatchWithSynced(
          c,
          forums: forumWatchForumItems(c),
          keywords: forumWatchKeywordItems(c),
          scope: forumWatchScopeItem(c),
          now: _t + 10,
        ),
        isNull,
      );
      final next = forumWatchWithSynced(
        c,
        forums: {
          // Unwatched on the other device later.
          '8': _gone(_t + 20),
          // Watched there again after this device unwatched it.
          '9': {'updated': _t + 30, 'name': '版块九'},
          // Watched there.
          '12': {'updated': _t + 5},
          // Never held here; not items.
          '13': _gone(_t + 5),
          '014': {'updated': _t + 5, 'name': 'x'},
          '-1': {'updated': _t + 5, 'name': 'x'},
          '15': {'name': 'no time'},
        },
        keywords: {
          'theirs': {'updated': _t + 6, 'text': 'Theirs'},
          // Removed there before this device added it: stays.
          'mine': _gone(_t + 2),
          // Not the key of its text, not a key: left alone.
          'other': {'updated': _t + 6, 'text': 'another'},
          'UPPER': {'updated': _t + 6, 'text': 'UPPER'},
          'notext': {'updated': _t + 6},
          'x' * 51: {'updated': _t + 6, 'text': 'x' * 51},
        },
        scope: {
          'updated': _t + 40,
          'custom': true,
          'latest': false,
          'forums': [
            {'fid': 3, 'name': '版块3'},
            {'fid': 3, 'name': 'again'},
            'x',
          ],
        },
        now: _t + 50,
      )!;
      expect(next.forums, [
        const WatchedForum(fid: 9, name: '版块九', updated: _t + 30),
        const WatchedForum(fid: 12, name: '', updated: _t + 5),
      ]);
      expect(next.removedForums, {8: _t + 20});
      expect([for (final k in next.keywords) (k.text, k.updated)], [('Theirs', _t + 6), ('mine', _t + 3)]);
      expect(next.removedKeywords, isEmpty);
      expect((next.scope.custom, next.scope.latest, next.scope.updated), (true, false, _t + 40));
      expect([for (final f in next.scope.forums) (f.fid, f.name)], [(3, '版块3')]);

      // An older item, an older scope: this device's stay.
      expect(
        forumWatchWithSynced(
          next,
          forums: {
            '9': _gone(_t + 29),
            '12': {'updated': _t + 4, 'name': '别名'},
          },
          keywords: {'mine': _gone(_t + 2)},
          scope: {'updated': _t + 39, 'custom': false},
          now: _t + 50,
        ),
        isNull,
      );
      // The same time: the document's, as the merge of two documents keeps the forum's item then.
      final tie = forumWatchWithSynced(
        next,
        forums: {
          '9': _gone(_t + 30),
          '12': {'updated': _t + 5, 'name': '别名'},
        },
        keywords: {
          'mine': {'updated': _t + 3, 'text': 'MINE'},
        },
        scope: {'updated': _t + 40, 'custom': false},
        now: _t + 50,
      )!;
      expect(tie.forums, [const WatchedForum(fid: 12, name: '别名', updated: _t + 5)]);
      expect(tie.removedForums, {8: _t + 20, 9: _t + 30});
      expect([for (final k in tie.keywords) k.text], ['Theirs', 'MINE']);
      expect((tie.scope.custom, tie.scope.updated), (false, _t + 40));
      // The same choice of the same time under another name of a forum: the document's name.
      final named = tie.copyWith(
        scope: const KeywordScope(
          custom: true,
          forums: [WatchedForum(fid: 3, name: '旧名', updated: 1)],
          updated: _t + 40,
        ),
      );
      final renamed = forumWatchWithSynced(
        named,
        forums: const {},
        keywords: const {},
        scope: {
          'updated': _t + 40,
          'custom': true,
          'latest': true,
          'forums': [
            {'fid': 3, 'name': '新名'},
          ],
        },
        now: _t + 50,
      )!;
      expect(renamed.scope.forums.single.name, '新名');
      expect(
        forumWatchWithSynced(
          renamed,
          forums: const {},
          keywords: const {},
          scope: forumWatchScopeItem(renamed),
          now: _t + 50,
        ),
        isNull,
      );
      // And then nothing more to take.
      expect(
        forumWatchWithSynced(
          tie,
          forums: forumWatchForumItems(tie),
          keywords: forumWatchKeywordItems(tie),
          scope: forumWatchScopeItem(tie),
          now: _t + 50,
        ),
        isNull,
      );
    });

    test('the forums a round fetches stay within 10 after a merge: the forums watched longest ago go', () {
      // This device: 6 forums watched, 4 others picked for the keywords (10 fetched, the limit).
      var c = const ForumWatchConfig().withKeyword('k', now: _t);
      for (var fid = 1; fid <= 6; fid++) {
        c = c.watching(fid, name: '版块$fid', now: _t + fid);
      }
      c = c.withScope(
        KeywordScope(
          custom: true,
          forums: [for (var fid = 21; fid <= 23; fid++) _w(fid, 1), _w(6, 1)],
        ),
        now: _t + 10,
      );
      expect(c.fetchedFids, hasLength(9));
      // The other device watched 4 more meanwhile.
      final next = forumWatchWithSynced(
        c,
        forums: {
          for (var fid = 11; fid <= 14; fid++) '$fid': {'updated': _t + 100 + fid, 'name': '版块$fid'},
        },
        keywords: const {},
        scope: null,
        now: _t + 500,
      )!;
      expect(next.fetchedFids, hasLength(forumWatchForumMax));
      expect(
        next.sources.toSet().containsAll([for (var fid = 21; fid <= 23; fid++) forumWatchForumSource(fid)]),
        isTrue,
      );
      expect(next.watchedFids, {11, 12, 13, 14, 6, 5, 4}, reason: 'forums 1 to 3, watched longest ago, went');
      expect(next.removedForums, isEmpty, reason: 'dropped, not unwatched: the other device keeps them');
      // Forum 6 is older than what went but the keywords look in it too: dropping it would free nothing.
      // Without a keyword the scope fetches nothing: every forum watched stays.
      final plain = forumWatchWithSynced(
        c.withoutKeyword('k', now: _t + 20),
        forums: {
          for (var fid = 11; fid <= 14; fid++) '$fid': {'updated': _t + 100 + fid, 'name': '版块$fid'},
        },
        keywords: const {},
        scope: null,
        now: _t + 500,
      )!;
      expect(plain.watchedFids, hasLength(10));
      // What went was not unwatched: the document still holds it, and once there is room (the scope back to the
      // default) the next sync watches it here again.
      final roomy = forumWatchWithSynced(
        next.withScope(const KeywordScope(), now: _t + 600),
        forums: {
          for (var fid = 1; fid <= 3; fid++) '$fid': {'updated': _t + fid, 'name': '版块$fid'},
        },
        keywords: const {},
        scope: null,
        now: _t + 700,
      )!;
      expect(roomy.watchedFids, {11, 12, 13, 14, 6, 5, 4, 3, 2, 1});
    });

    test('over the limits after a merge: the latest 10 forums and 50 keywords, the others without a record', () {
      var c = const ForumWatchConfig();
      for (var fid = 1; fid <= forumWatchForumMax; fid++) {
        c = c.watching(fid, name: '', now: _t + fid);
      }
      final next = forumWatchWithSynced(
        c,
        forums: {
          for (var fid = 21; fid <= 23; fid++) '$fid': {'updated': _t + 100 + fid, 'name': ''},
        },
        keywords: {
          for (var i = 0; i < forumWatchKeywordMax + 5; i++) 'k$i': {'updated': _t + i, 'text': 'k$i'},
        },
        scope: null,
        now: _t + 500,
      )!;
      expect(next.forums, hasLength(forumWatchForumMax));
      expect(next.watchedFids.containsAll([21, 22, 23]), isTrue);
      expect(next.watchedFids.intersection({1, 2, 3}), isEmpty);
      expect(next.removedForums, isEmpty);
      expect(next.keywords, hasLength(forumWatchKeywordMax));
      expect(next.keywords.first.text, 'k${forumWatchKeywordMax + 4}');
    });
  });

  group('the store of the watch', () {
    late AppDatabase db;
    late StorageProvider storage;
    late ForumWatchStore store;
    late ForumWatchCubit cubit;
    final now = DateTime.fromMillisecondsSinceEpoch(_t);

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      store = ForumWatchStore(storage);
      cubit = ForumWatchCubit(store: store, storage: storage, uid: _uid, clock: () => now);
    });

    tearDown(() async {
      await cubit.close();
      await store.dispose();
      await db.close();
    });

    Future<ForumWatchRound> round(Map<String, List<WatchRow>> rows, {List<ForumWatchBatch>? announced}) {
      Future<ForumWatchFetch> fetch(String source) async =>
          ForumWatchFetched(rows[source] ?? const [], viewerUid: _uid);
      return checkForumWatch(
        store: store,
        uid: _uid,
        gap: Duration.zero,
        clock: () => now,
        blocks: () async => const UserBlockList.empty(_uid),
        fetch: fetch,
        announcing: (_) async => true,
        announce: (batch) async {
          announced?.add(batch);
          return true;
        },
      );
    }

    test('the row stays while a record is to be kept, and goes with the last of them', () async {
      await cubit.watchForum(8, name: '版块8');
      await cubit.unwatchForum(8);
      final config = await store.loadConfig(_uid);
      expect(config.isEmpty, isTrue);
      expect(config.removedForums, {8: _t + 1});
      expect(await storage.getString(StorageProvider.forumWatchKey(_uid)), isNotNull);
      await store.updateConfig(_uid, (c) => c.copyWith(removedForums: const {}));
      expect(await storage.getString(StorageProvider.forumWatchKey(_uid)), isNull);
    });

    test('a forum that arrives from another device starts from the threads it has: nothing is announced', () async {
      // This device watches forum 8 and has checked it; its check found a thread.
      await cubit.watchForum(8, name: '版块8', newestTid: 100);
      final announced = <ForumWatchBatch>[];
      await round({
        forumWatchForumSource(8): [_row(101), _row(100)],
      }, announced: announced);
      expect(announced, hasLength(1));
      final before = await store.loadState(_uid);
      expect(before.marks, {forumWatchForumSource(8): 101});
      expect(before.alerts.map((a) => a.tid), [101]);

      // The other device watches forum 9 and a keyword; its own marks and alerts are no part of the document.
      await store.applySynced(
        _uid,
        forums: {
          '9': {'updated': _t + 50, 'name': '版块9'},
        },
        keywords: {
          '关键字': {'updated': _t + 51, 'text': '关键字'},
        },
        scope: null,
        now: now,
      );
      final config = await store.loadConfig(_uid);
      expect(config.watchedFids, {9, 8});
      final after = await store.loadState(_uid);
      expect(after.marks, before.marks, reason: 'the mark of forum 8 stays, forum 9 and the latest list have none');
      expect(after.alerts, before.alerts);

      // The first check of forum 9 here: its threads are there already, none is announced.
      announced.clear();
      final first = await round({
        forumWatchForumSource(8): [_row(101)],
        forumWatchForumSource(9): [_row(500, fid: 9), _row(499, fid: 9)],
        forumWatchLatestSource: [_row(500, fid: 9)],
      }, announced: announced);
      expect(first.found, isEmpty);
      expect(announced, isEmpty);
      expect((await store.loadState(_uid)).marks, {
        forumWatchForumSource(8): 101,
        forumWatchForumSource(9): 500,
        forumWatchLatestSource: 500,
      });
      // The next thread is.
      final second = await round({
        forumWatchForumSource(8): [_row(101)],
        forumWatchForumSource(9): [_row(501, fid: 9), _row(500, fid: 9)],
        forumWatchLatestSource: [_row(501, fid: 9)],
      }, announced: announced);
      expect(second.found.map((a) => a.tid), [501]);
    });

    test('a forum another device unwatched is unwatched here, its mark with it; no change, no write', () async {
      await cubit.watchForum(8, name: '版块8', newestTid: 100);
      await cubit.addKeyword('旧');
      final configChanges = <int>[];
      final changes = <int>[];
      final subs = [store.configChanges.listen(configChanges.add), store.changes.listen(changes.add)];
      addTearDown(() async {
        for (final sub in subs) {
          await sub.cancel();
        }
      });
      await store.applySynced(_uid, forums: {'8': _gone(_t + 60)}, keywords: {'旧': _gone(_t + 61)}, scope: null);
      await pumpEventQueue();
      expect((await store.loadConfig(_uid)).isEmpty, isTrue);
      expect((await store.loadState(_uid)).marks, isEmpty);
      expect(configChanges, [_uid]);
      // The same again changes nothing.
      await store.applySynced(_uid, forums: {'8': _gone(_t + 60)}, keywords: {'旧': _gone(_t + 61)}, scope: null);
      await pumpEventQueue();
      expect(configChanges, [_uid]);
      // What the check learns is no change of what is watched.
      await store.updateState(_uid, (_, state) => state.withMark(forumWatchLatestSource, 7));
      await pumpEventQueue();
      expect(configChanges, [_uid]);
      expect(changes, [_uid, _uid]);
    });

    test('the cubit shows what the sync took in', () async {
      await pumpEventQueue();
      await store.applySynced(
        _uid,
        forums: {
          '9': {'updated': _t + 50, 'name': '版块9'},
        },
        keywords: const {},
        scope: null,
      );
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(cubit.state.config.watches(9), isTrue);
    });
  });

  group('document', () {
    test('the new sections merge item by item, the scope whole; sections it does not know are kept', () {
      final mine = <String, dynamic>{
        'schema': 1,
        'pinned_forums': {'1': _pin(1, 10, 0), '2': _gone(30), '3': _pin(3, 5, 2)},
        'watch_forums': {
          '8': {'updated': 10, 'name': 'a'},
        },
        'watch_keywords': {'k': _gone(40)},
        'watch_scope': {'updated': 10, 'custom': true},
        'only_local': {'x': 1},
      };
      final theirs = <String, dynamic>{
        'schema': 1,
        'pinned_forums': {'1': _pin(1, 20, 7), '2': _pin(2, 20, 1), '3': _pin(3, 5, 9)},
        'watch_forums': {
          '8': _gone(9),
          '9': {'updated': 1, 'name': 'b'},
        },
        'watch_keywords': {
          'k': {'updated': 50, 'text': 'K'},
        },
        'watch_scope': {'updated': 20, 'custom': false, 'later_field': 1},
        'future_section': {'y': 2},
      };
      final merged = SyncDocument.merge(SyncDocument(mine), SyncDocument(theirs)).raw;
      expect(merged['pinned_forums'], {'1': _pin(1, 20, 7), '2': _gone(30), '3': _pin(3, 5, 9)});
      expect(merged['watch_forums'], {
        '8': {'updated': 10, 'name': 'a'},
        '9': {'updated': 1, 'name': 'b'},
      });
      expect(merged['watch_keywords'], {
        'k': {'updated': 50, 'text': 'K'},
      });
      expect(merged['watch_scope'], {'updated': 20, 'custom': false, 'later_field': 1});
      expect(merged['only_local'], {'x': 1});
      expect(merged['future_section'], {'y': 2});
    });
  });

  group('repository', () {
    late _Api api;
    late MemorySyncLocalStore store;
    late DateTime now;
    late Set<SyncCategory> off;

    SyncRepository repoOf(_Api api, MemorySyncLocalStore store) => SyncRepository(
      api: api,
      store: store..clock = (() => now.millisecondsSinceEpoch),
      enabled: () => true,
      categoryEnabled: (c) => !off.contains(c),
      now: () => now,
    );

    SyncRepository repo() => repoOf(api, store);

    setUp(() {
      api = _Api();
      store = MemorySyncLocalStore();
      now = DateTime.fromMillisecondsSinceEpoch(_t + 1000);
      off = {};
    });

    Map<String, dynamic> pushed() => jsonDecode(api.pushes.last) as Map<String, dynamic>;

    test("this device's lists and removals are written, the forum's are taken", () async {
      store.pinnedByUid[_uid] = frequentForumsTogglePin(_pinned([1, 2, 3]), _f(3), now: _t + 50);
      store.watchByUid[_uid] = const ForumWatchConfig()
          .watching(8, name: '版块8', now: _t)
          .withKeyword('Mine', now: _t + 1)
          .withKeyword('旧', now: _t + 2)
          .withoutKeyword('旧', now: _t + 3)
          .withScope(const KeywordScope(custom: true), now: _t + 4);
      api.forum.write({
        'pinned_forums': {'3': _pin(3, _t + 10, 2 * _step), '7': _pin(7, _t + 20, -_step), '2': _gone(_t + 30)},
        'watch_forums': {
          '9': {'updated': _t + 5, 'name': '版块9'},
          '8': _gone(_t - 1),
        },
        'watch_keywords': {
          '旧': {'updated': _t + 2, 'text': '旧'},
          'theirs': {'updated': _t + 9, 'text': 'Theirs'},
        },
        'watch_scope': {'updated': _t + 3, 'custom': false, 'latest': true, 'forums': <Object>[]},
      });
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      expect(pushed()['pinned_forums'], {
        '1': _pin(1, _t, 0),
        '2': _gone(_t + 30),
        '3': _gone(_t + 50),
        '7': _pin(7, _t + 20, -_step),
      });
      expect(pushed()['watch_forums'], {
        '8': {'updated': _t, 'name': '版块8'},
        '9': {'updated': _t + 5, 'name': '版块9'},
      });
      expect(pushed()['watch_keywords'], {
        'mine': {'updated': _t + 1, 'text': 'Mine'},
        '旧': _gone(_t + 3),
        'theirs': {'updated': _t + 9, 'text': 'Theirs'},
      });
      expect(pushed()['watch_scope'], {'updated': _t + 4, 'custom': true, 'latest': true, 'forums': <Object>[]});
      // And this device holds the same.
      expect(_ids(store.pinnedByUid[_uid]!), [7, 1]);
      expect(store.pinnedByUid[_uid]!.unpinned, {3: _t + 50, 2: _t + 30});
      final watch = store.watchByUid[_uid]!;
      expect(watch.watchedFids, {8, 9});
      expect([for (final k in watch.keywords) k.text], ['Theirs', 'Mine']);
      expect(watch.scope.custom, isTrue);
      // Nothing more to say.
      final pulls = api.pulls;
      expect(await repo().pushNow(_uid), SyncOutcome.upToDate);
      expect(api.pulls, pulls, reason: 'this device holds what the forum has: not even asked');
    });

    test('the state of a device never goes to the forum: recent forums, marks, alerts', () async {
      store.pinnedByUid[_uid] = frequentForumsVisited(_pinned([1]), _f(55, name: '最近去过'));
      store.watchByUid[_uid] = const ForumWatchConfig().watching(8, name: '版块8', now: _t);
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      expect(api.pushes.last, isNot(contains('最近去过')));
      expect(pushed().keys.toSet(), {'schema', 'pinned_forums', 'watch_forums'});
      expect((pushed()['watch_forums'] as Map<String, dynamic>)['8'], {'updated': _t, 'name': '版块8'});
    });

    test('a later change of the forum is taken, a later removal removes; nothing written back', () async {
      store.pinnedByUid[_uid] = _pinned([1, 2]);
      store.watchByUid[_uid] = const ForumWatchConfig().watching(8, name: '版块8', now: _t).withKeyword('k', now: _t);
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      final doc = api.forum.doc;
      api.forum.write({
        ...doc,
        'pinned_forums': {'1': _gone(_t + 100), '2': _pin(2, _t + 100, 0, name: '改名'), '5': _pin(5, _t + 100, -_step)},
        'watch_forums': {'8': _gone(_t + 100)},
        'watch_keywords': {
          'k': _gone(_t + 100),
          'n': {'updated': _t + 100, 'text': 'N'},
        },
        'watch_scope': {'updated': _t + 100, 'custom': true, 'latest': false, 'forums': <Object>[]},
      });
      final pushes = api.pushes.length;
      expect(await repo().pull(_uid), SyncOutcome.upToDate);
      expect(api.pushes, hasLength(pushes));
      expect([for (final e in store.pinnedByUid[_uid]!.pinned) (e.fid, e.name)], [(5, '版块5'), (2, '改名')]);
      final watch = store.watchByUid[_uid]!;
      expect(watch.forums, isEmpty);
      expect([for (final k in watch.keywords) k.text], ['N']);
      expect((watch.scope.custom, watch.scope.latest), (true, false));
      expect(await repo().pushNow(_uid), SyncOutcome.upToDate);
    });

    test('switched off: neither read nor written; on again, nothing of the others is deleted', () async {
      api.forum.write({
        'pinned_forums': {'7': _pin(7, _t + 5, 0)},
        'watch_forums': {
          '9': {'updated': _t + 5, 'name': '版块9'},
        },
        'watch_keywords': {
          'k': {'updated': _t + 5, 'text': 'K'},
        },
        'watch_scope': {'updated': _t + 5, 'custom': true},
      });
      store.pinnedByUid[_uid] = _pinned([1]);
      store.watchByUid[_uid] = const ForumWatchConfig().watching(8, name: '版块8', now: _t);
      off = {SyncCategory.pinnedForums, SyncCategory.forumWatch};
      expect(await repo().pull(_uid), SyncOutcome.upToDate);
      expect(_ids(store.pinnedByUid[_uid]!), [1]);
      expect(store.watchByUid[_uid]!.watchedFids, {8});
      expect(api.pushes, isEmpty);
      // A write of something else while off leaves the sections as the forum has them.
      store
        ..phraseList = ['你好']
        ..phrasesUpdatedAt = _t + 500;
      expect(await repo().pushNow(_uid), SyncOutcome.pushed);
      expect(pushed()['pinned_forums'], {'7': _pin(7, _t + 5, 0)});
      expect((pushed()['watch_forums'] as Map<String, dynamic>).keys, ['9']);
      expect(pushed()['watch_scope'], {'updated': _t + 5, 'custom': true});

      off = {};
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      expect(_ids(store.pinnedByUid[_uid]!), [1, 7], reason: 'the same rank: by forum id');
      expect(store.watchByUid[_uid]!.watchedFids, {8, 9});
      expect((pushed()['pinned_forums'] as Map<String, dynamic>).keys.toSet(), {'1', '7'});
      expect((pushed()['watch_forums'] as Map<String, dynamic>).keys.toSet(), {'8', '9'});
      expect((pushed()['watch_keywords'] as Map<String, dynamic>).keys.toSet(), {'k'});
    });

    test('a watch that can not be kept here is left alone, the section of the forum with it', () async {
      api.forum.write({
        'watch_forums': {
          '9': {'updated': _t + 5, 'name': '版块9'},
        },
      });
      store.watchUnavailable.add(_uid);
      store.pinnedByUid[_uid] = _pinned([1]);
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      expect((pushed()['watch_forums'] as Map<String, dynamic>).keys, ['9']);
    });

    test(
      'a version before these sections kept them in its last document: nothing is deleted after the update',
      () async {
        // What the forum holds was read (and carried, not applied) by the version before.
        final doc = {
          'schema': 1,
          'pinned_forums': {'7': _pin(7, _t + 5, 0)},
          'watch_forums': {
            '9': {'updated': _t + 5, 'name': '版块9'},
          },
          'watch_keywords': {
            'k': {'updated': _t + 5, 'text': 'K'},
          },
        };
        api.forum.write(doc);
        store.lastByUid[_uid] = (document: SyncDocument(doc).encode(), updated: api.forum.updated);
        store.pinnedByUid[_uid] = _pinned([1]);
        // A write first (a local change), then the pull: neither reads the missing items as removed here.
        expect(await repo().pushNow(_uid), SyncOutcome.pushed);
        expect(pushed()['pinned_forums'], {'1': _pin(1, _t, 0), '7': _pin(7, _t + 5, 0)});
        expect((pushed()['watch_forums'] as Map<String, dynamic>)['9'], {'updated': _t + 5, 'name': '版块9'});
        expect(_ids(store.pinnedByUid[_uid]!), [1, 7]);
        expect(store.watchByUid[_uid]!.watchedFids, {9});
        expect([for (final k in store.watchByUid[_uid]!.keywords) k.text], ['K']);
      },
    );

    test('sections and fields this version does not know are kept and written back', () async {
      api.forum.write({
        'pinned_forums': {
          '7': {..._pin(7, _t + 5, 0), 'color': 'red'},
        },
        'watch_forums': {
          '9': {'updated': _t + 5, 'name': '版块9', 'muted': true},
        },
        'watch_scope': {'updated': _t + 5, 'custom': true, 'latest': true, 'forums': <Object>[], 'titles_only': 1},
        'future_section': {
          'a': {
            'updated': 1,
            'v': [1, 2, 3],
          },
        },
        'future_value': 'kept',
      });
      store.pinnedByUid[_uid] = _pinned([1]);
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      expect(pushed()['future_section'], {
        'a': {
          'updated': 1,
          'v': [1, 2, 3],
        },
      });
      expect(pushed()['future_value'], 'kept');
      expect((pushed()['pinned_forums'] as Map<String, dynamic>)['7'], {..._pin(7, _t + 5, 0), 'color': 'red'});

      // This device changes the items: the fields it does not write stay on them.
      now = now.add(const Duration(seconds: 5));
      final at = now.millisecondsSinceEpoch;
      expect(_ids(store.pinnedByUid[_uid]!), [1, 7]);
      store.pinnedByUid[_uid] = frequentForumsReorder(store.pinnedByUid[_uid]!, 1, 0, now: at);
      store.watchByUid[_uid] = store.watchByUid[_uid]!
          .watching(9, name: '版块九', now: at)
          .withScope(const KeywordScope(custom: true, latest: false), now: at);
      expect(await repo().pushNow(_uid), SyncOutcome.pushed);
      expect((pushed()['pinned_forums'] as Map<String, dynamic>)['1'], _pin(1, _t, 0));
      expect((pushed()['pinned_forums'] as Map<String, dynamic>)['7'], {..._pin(7, at, -_step), 'color': 'red'});
      expect((pushed()['watch_forums'] as Map<String, dynamic>)['9'], {'updated': at, 'name': '版块九', 'muted': true});
      expect(pushed()['watch_scope'], {
        'updated': at,
        'custom': true,
        'latest': false,
        'forums': <Object>[],
        'titles_only': 1,
      });
      expect(pushed()['future_section'], isNotNull);
      expect(pushed()['future_value'], 'kept');
    });

    test('a document of a newer schema is left alone', () async {
      api.forum.write({
        'schema': 2,
        'pinned_forums': {'7': _pin(7, _t + 5, 0)},
      });
      store.pinnedByUid[_uid] = _pinned([1]);
      expect(await repo().pull(_uid), SyncOutcome.newerSchema);
      expect(api.pushes, isEmpty);
      expect(_ids(store.pinnedByUid[_uid]!), [1]);
    });

    test('the caps: 30 pinned forums, 10 forums and 50 keywords, the recent removals; old removals dropped', () async {
      final old = _t - syncTombstoneKeptFor.inMilliseconds;
      api.forum.write({
        'pinned_forums': {
          for (var fid = 1; fid <= 40; fid++) '$fid': _pin(fid, _t + fid, fid * _step),
          for (var fid = 101; fid <= 100 + frequentForumsUnpinnedMax + 5; fid++) '$fid': _gone(_t + fid),
          '999': _gone(old),
        },
        'watch_forums': {
          for (var fid = 1; fid <= 15; fid++) '$fid': {'updated': _t + fid, 'name': ''},
          '999': _gone(old),
        },
        'watch_keywords': {
          for (var i = 1; i <= 60; i++) 'k$i': {'updated': _t + i, 'text': 'k$i'},
          for (var i = 1; i <= forumWatchKeywordRemovalMax + 5; i++) 'gone$i': _gone(_t + i),
        },
      });
      expect(await repo().pull(_uid), SyncOutcome.pushed);
      final pinned = pushed()['pinned_forums'] as Map<String, dynamic>;
      final live = {
        for (final e in pinned.entries)
          if (!SyncDocument.isDeleted(e.value as Map<String, dynamic>)) e.key,
      };
      expect(live, {for (var fid = 11; fid <= 40; fid++) '$fid'});
      expect(pinned.length - live.length, frequentForumsUnpinnedMax);
      expect(pinned.containsKey('999'), isFalse);
      expect(pinned.containsKey('101'), isFalse, reason: 'the oldest records go first');
      expect((pushed()['watch_forums'] as Map<String, dynamic>).keys.toSet(), {
        for (var fid = 6; fid <= 15; fid++) '$fid',
      });
      final keywords = pushed()['watch_keywords'] as Map<String, dynamic>;
      expect(keywords.keys.where((k) => k.startsWith('k')).toSet(), {for (var i = 11; i <= 60; i++) 'k$i'});
      expect(keywords.keys.where((k) => k.startsWith('gone')), hasLength(forumWatchKeywordRemovalMax));
      // The device keeps the same ones.
      expect(_ids(store.pinnedByUid[_uid]!), [for (var fid = 11; fid <= 40; fid++) fid]);
      expect(store.watchByUid[_uid]!.watchedFids, {for (var fid = 6; fid <= 15; fid++) fid});
      expect(store.watchByUid[_uid]!.keywords, hasLength(forumWatchKeywordMax));
      expect(await repo().pushNow(_uid), SyncOutcome.upToDate);
    });

    test('the room they take: 12 KB with every list full, 18 KB at most whatever the names', () async {
      FrequentForumsOfAccount pinnedFull(String Function(int fid) name) {
        var a = const FrequentForumsOfAccount();
        for (var fid = 1; fid <= frequentForumsUnpinnedMax; fid++) {
          a = frequentForumsTogglePin(a, _f(2000 + fid, name: name(fid)), now: _t + fid);
          a = frequentForumsTogglePin(a, _f(2000 + fid, name: name(fid)), now: _t + 500 + fid);
        }
        for (var fid = 1; fid <= frequentForumsPinnedMax; fid++) {
          a = frequentForumsTogglePin(a, _f(1000 + fid, name: name(fid)), now: _t + 1000 + fid);
        }
        return a;
      }

      ForumWatchConfig watchFull(String Function(int i) name, String Function(int i) keyword) {
        var c = const ForumWatchConfig();
        for (var i = 1; i <= forumWatchForumRemovalMax; i++) {
          c = c.watching(2000 + i, name: name(i), now: _t + i).unwatching(2000 + i, now: _t + 500 + i);
        }
        for (var i = 1; i <= forumWatchKeywordRemovalMax; i++) {
          c = c.withKeyword('旧${keyword(i)}', now: _t + i).withoutKeyword('旧${keyword(i)}', now: _t + 500 + i);
        }
        for (var i = 1; i <= forumWatchForumMax; i++) {
          c = c.watching(1000 + i, name: name(i), now: _t + 1000 + i);
        }
        for (var i = 1; i <= forumWatchKeywordMax; i++) {
          c = c.withKeyword(keyword(i), now: _t + 1000 + i);
        }
        return c.withScope(
          KeywordScope(
            custom: true,
            forums: [
              for (var i = 1; i <= forumWatchForumMax; i++) WatchedForum(fid: 3000 + i, name: name(i), updated: 1),
            ],
          ),
          now: _t + 2000,
        );
      }

      int bytesOf(Object? json) => utf8.encode(jsonEncode(json)).length;

      Future<(Map<String, dynamic>, MemorySyncLocalStore)> written(
        FrequentForumsOfAccount pinned,
        ForumWatchConfig watch,
      ) async {
        final api = _Api();
        final store = MemorySyncLocalStore()
          ..pinnedByUid[_uid] = pinned
          ..watchByUid[_uid] = watch;
        final repo = repoOf(api, store);
        expect(await repo.pull(_uid), SyncOutcome.pushed);
        // What the budget left out is not written again and again.
        expect(await repo.pushNow(_uid), SyncOutcome.upToDate);
        return (jsonDecode(api.pushes.last) as Map<String, dynamic>, store);
      }

      // Every list full, names as the forum has them: nothing is left out.
      final (usual, _) = await written(
        pinnedFull((fid) => '动漫讨论区$fid'),
        watchFull((i) => '动漫讨论区$i', (i) => '关键字$i'),
      );
      expect((usual['pinned_forums'] as Map).length, frequentForumsPinnedMax + frequentForumsUnpinnedMax);
      expect((usual['watch_forums'] as Map).length, forumWatchForumMax + forumWatchForumRemovalMax);
      expect((usual['watch_keywords'] as Map).length, forumWatchKeywordMax + forumWatchKeywordRemovalMax);
      expect(bytesOf(usual['pinned_forums']), lessThan(4 * 1024));
      expect(bytesOf(usual['watch_forums']), lessThan(syncWatchForumsMaxBytes));
      expect(bytesOf(usual['watch_keywords']), lessThan(6 * 1024));
      expect(bytesOf(usual), lessThan(12 * 1024 + 512));

      // Forum names of 20 Chinese characters, keywords of the 50 a keyword may have: each list within its budget,
      // the latest kept, the older ones left on the device (not removed from it).
      final (longest, store) = await written(
        pinnedFull((fid) => '版' * 17 + '$fid'.padLeft(3, '0')),
        watchFull((i) => '版' * 17 + '$i'.padLeft(3, '0'), (i) => '字' * 46 + '$i'.padLeft(3, '0')),
      );
      expect(bytesOf(longest['pinned_forums']), lessThanOrEqualTo(syncPinnedForumsMaxBytes));
      expect(bytesOf(longest['watch_forums']), lessThanOrEqualTo(syncWatchForumsMaxBytes));
      expect(bytesOf(longest['watch_keywords']), lessThanOrEqualTo(syncWatchKeywordsMaxBytes));
      expect(bytesOf(longest), lessThan(18 * 1024));
      final keywords = longest['watch_keywords'] as Map<String, dynamic>;
      expect(keywords.length, inInclusiveRange(20, 30));
      expect(keywords.containsKey('字' * 46 + '$forumWatchKeywordMax'.padLeft(3, '0')), isTrue, reason: 'the latest');
      expect(keywords.values.every((e) => !SyncDocument.isDeleted(e as Map<String, dynamic>)), isTrue);
      expect(store.watchByUid[_uid]!.keywords, hasLength(forumWatchKeywordMax));
      expect(store.pinnedByUid[_uid]!.pinned, hasLength(frequentForumsPinnedMax));
    });
  });

  group('two devices', () {
    late _Forum forum;
    late DateTime now;
    late _Api apiA;
    late _Api apiB;
    late MemorySyncLocalStore a;
    late MemorySyncLocalStore b;
    late SyncRepository repoA;
    late SyncRepository repoB;

    setUp(() {
      forum = _Forum();
      now = DateTime.fromMillisecondsSinceEpoch(_t);
      apiA = _Api(forum);
      apiB = _Api(forum);
      a = MemorySyncLocalStore()..clock = (() => now.millisecondsSinceEpoch);
      b = MemorySyncLocalStore()..clock = (() => now.millisecondsSinceEpoch);
      repoA = SyncRepository(api: apiA, store: a, enabled: () => true, now: () => now);
      repoB = SyncRepository(api: apiB, store: b, enabled: () => true, now: () => now);
    });

    int tick([int ms = 1000]) {
      now = now.add(Duration(milliseconds: ms));
      return now.millisecondsSinceEpoch;
    }

    FrequentForumsOfAccount pinnedOf(MemorySyncLocalStore s) => s.pinnedByUid[_uid] ?? const FrequentForumsOfAccount();
    ForumWatchConfig watchOf(MemorySyncLocalStore s) => s.watchByUid[_uid] ?? const ForumWatchConfig();

    void expectSame() {
      expect(_ids(pinnedOf(a)), _ids(pinnedOf(b)));
      expect(
        [for (final e in pinnedOf(a).pinned) (e.name, e.updated, e.rank)],
        [
          for (final e in pinnedOf(b).pinned) (e.name, e.updated, e.rank),
        ],
      );
      expect(watchOf(a).forums, watchOf(b).forums);
      expect(watchOf(a).keywords, watchOf(b).keywords);
      expect(watchOf(a).scope, watchOf(b).scope);
    }

    test('lists kept before the sync on both: united, neither loses a forum', () async {
      a.pinnedByUid[_uid] = decodeFrequentForums(
        '{"31":{"pinned":[{"fid":3,"name":"c"},{"fid":1,"name":"a"}],"recent":[]}}',
      )[_uid]!;
      b.pinnedByUid[_uid] = decodeFrequentForums(
        '{"31":{"pinned":[{"fid":1,"name":"a"},{"fid":2,"name":"b"}],"recent":[]}}',
      )[_uid]!;
      expect(await repoA.pull(_uid), SyncOutcome.pushed);
      expect(await repoB.pull(_uid), SyncOutcome.pushed);
      expect(await repoA.pull(_uid), SyncOutcome.upToDate);
      expect(_ids(pinnedOf(a)).toSet(), {1, 2, 3});
      expectSame();
      expect(await repoB.pushNow(_uid), SyncOutcome.upToDate);
      expect(await repoA.pushNow(_uid), SyncOutcome.upToDate);
    });

    test('writing in turn: pins, an order, removals and the watch go both ways', () async {
      a.pinnedByUid[_uid] = _pinned([1, 2, 3], at: tick());
      a.watchByUid[_uid] = const ForumWatchConfig().watching(8, name: '版块8', now: tick()).withKeyword('甲', now: tick());
      expect(await repoA.pull(_uid), SyncOutcome.pushed);
      expect(await repoB.pull(_uid), SyncOutcome.upToDate);
      expectSame();

      // B moves forum 3 to the front and unpins forum 2, watches forum 9, removes the keyword, picks a scope.
      b.pinnedByUid[_uid] = frequentForumsTogglePin(
        frequentForumsReorder(pinnedOf(b), 2, 0, now: tick()),
        _f(2),
        now: tick(),
      );
      b.watchByUid[_uid] = watchOf(b)
          .watching(9, name: '版块9', now: tick())
          .withoutKeyword('甲', now: tick())
          .withScope(const KeywordScope(custom: true, latest: false), now: tick());
      expect(await repoB.pushNow(_uid), SyncOutcome.pushed);
      // Meanwhile A pinned forum 4 and added a keyword, not written yet.
      a.pinnedByUid[_uid] = frequentForumsTogglePin(pinnedOf(a), _f(4), now: tick());
      a.watchByUid[_uid] = watchOf(a).withKeyword('乙', now: tick());
      expect(await repoA.pull(_uid), SyncOutcome.pushed);
      expect(_ids(pinnedOf(a)), [3, 1, 4]);
      expect(watchOf(a).watchedFids, {8, 9});
      expect([for (final k in watchOf(a).keywords) k.text], ['乙']);
      expect((watchOf(a).scope.custom, watchOf(a).scope.latest), (true, false));
      expect(await repoB.pull(_uid), SyncOutcome.upToDate);
      expectSame();

      // A unwatches forum 9; B watches it again later: watched on both.
      a.watchByUid[_uid] = watchOf(a).unwatching(9, now: tick());
      expect(await repoA.pushNow(_uid), SyncOutcome.pushed);
      expect(await repoB.pull(_uid), SyncOutcome.upToDate);
      expect(watchOf(b).watchedFids, {8});
      b.watchByUid[_uid] = watchOf(b).watching(9, name: '版块9', now: tick());
      expect(await repoB.pushNow(_uid), SyncOutcome.pushed);
      expect(await repoA.pull(_uid), SyncOutcome.upToDate);
      expect(watchOf(a).watchedFids, {8, 9});
      expectSame();
      expect(await repoA.pushNow(_uid), SyncOutcome.upToDate);
      expect(await repoB.pushNow(_uid), SyncOutcome.upToDate);
    });

    test('writing at once: the second write is refused, merged and written; neither change is lost', () async {
      a.pinnedByUid[_uid] = _pinned([1, 2], at: tick());
      expect(await repoA.pull(_uid), SyncOutcome.pushed);
      expect(await repoB.pull(_uid), SyncOutcome.upToDate);

      // Both change while apart: A moves forum 2 first and watches forum 8, B pins forum 5 and adds a keyword.
      a.pinnedByUid[_uid] = frequentForumsReorder(pinnedOf(a), 1, 0, now: tick());
      a.watchByUid[_uid] = watchOf(a).watching(8, name: '版块8', now: tick());
      b.pinnedByUid[_uid] = frequentForumsTogglePin(pinnedOf(b), _f(5), now: tick());
      b.watchByUid[_uid] = watchOf(b).withKeyword('丙', now: tick());
      // B's write reaches the forum between A's read and A's write.
      var writtenByB = false;
      apiA.afterPull = () async {
        expect(await repoB.pushNow(_uid), SyncOutcome.pushed);
        writtenByB = true;
      };
      expect(await repoA.pushNow(_uid), SyncOutcome.pushed);
      expect(writtenByB, isTrue);
      expect(apiA.conflicts, 1);
      expect(_ids(pinnedOf(a)), [2, 1, 5]);
      expect([for (final k in watchOf(a).keywords) k.text], ['丙']);
      expect(await repoB.pull(_uid), SyncOutcome.upToDate);
      expect(watchOf(b).watchedFids, {8});
      expectSame();
    });

    test('one device unpins what the other moved later: the move wins; unpinned later: gone on both', () async {
      a.pinnedByUid[_uid] = _pinned([1, 2, 3], at: tick());
      expect(await repoA.pull(_uid), SyncOutcome.pushed);
      expect(await repoB.pull(_uid), SyncOutcome.upToDate);
      a.pinnedByUid[_uid] = frequentForumsTogglePin(pinnedOf(a), _f(3), now: tick());
      b.pinnedByUid[_uid] = frequentForumsReorder(pinnedOf(b), 2, 0, now: tick());
      expect(await repoA.pushNow(_uid), SyncOutcome.pushed);
      expect(await repoB.pushNow(_uid), SyncOutcome.pushed);
      expect(await repoA.pull(_uid), SyncOutcome.upToDate);
      expect(_ids(pinnedOf(a)), [3, 1, 2]);
      expect(pinnedOf(a).unpinned, isEmpty);
      expectSame();
      b.pinnedByUid[_uid] = frequentForumsTogglePin(pinnedOf(b), _f(3), now: tick());
      expect(await repoB.pushNow(_uid), SyncOutcome.pushed);
      expect(await repoA.pull(_uid), SyncOutcome.upToDate);
      expect(_ids(pinnedOf(a)), [1, 2]);
      expectSame();
    });

    test('a device of the version before in between carries the sections through untouched', () async {
      a.pinnedByUid[_uid] = _pinned([1, 2], at: tick());
      a.watchByUid[_uid] = const ForumWatchConfig().watching(8, name: '版块8', now: tick());
      expect(await repoA.pull(_uid), SyncOutcome.pushed);
      // The old version: its document is what the forum had, with its own sections on top.
      final old = forum.doc;
      forum.write({
        ...old,
        'phrases': {
          'updated': tick(),
          'items': ['旧版本写的'],
        },
      });
      expect(forum.doc['pinned_forums'], old['pinned_forums']);
      expect(await repoB.pull(_uid), SyncOutcome.upToDate);
      expect(_ids(pinnedOf(b)), [1, 2]);
      expect(watchOf(b).watchedFids, {8});
      expect(b.phraseList, ['旧版本写的']);
    });
  });

  group('coordinator', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late UserBlockRepository blocks;
    late _Api api;
    late MemorySyncLocalStore store;
    late _Auth auth;
    late StreamController<int> watchChanges;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      await settings.init();
      blocks = UserBlockRepository(storage);
      api = _Api();
      store = MemorySyncLocalStore();
      auth = _Auth();
      watchChanges = StreamController<int>.broadcast();
    });

    tearDown(() async {
      await watchChanges.close();
      await auth.dispose();
      await blocks.dispose();
      await settings.dispose();
      await db.close();
    });

    Future<SyncCoordinator> started() async {
      final c = SyncCoordinator(
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
        watchChanges: watchChanges.stream,
      )..start();
      addTearDown(c.dispose);
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      c.repository.cancelScheduled();
      return c;
    }

    test('pinning, moving and unpinning schedule a write; a visit and another account do not', () async {
      final frequent = FrequentForumsStore(settings);
      await frequent.togglePin(_uid, _f(1));
      await frequent.togglePin(_uid, _f(2));
      final c = await started();
      await frequent.visit(_uid, _f(50));
      await frequent.togglePin(_uid + 1, _f(3));
      await pumpEventQueue();
      expect(c.repository.pushScheduled, isFalse);
      await frequent.togglePin(_uid, _f(3));
      await pumpEventQueue();
      expect(c.repository.pushScheduled, isTrue);
      c.repository.cancelScheduled();
      await frequent.reorder(_uid, 2, 0);
      await pumpEventQueue();
      expect(c.repository.pushScheduled, isTrue);
      c.repository.cancelScheduled();
      await frequent.togglePin(_uid, _f(1));
      await pumpEventQueue();
      expect(c.repository.pushScheduled, isTrue);
    });

    test('the store of the settings keeps what the sync takes in, and a restart reads it back', () async {
      final frequent = FrequentForumsStore(settings);
      await frequent.togglePin(_uid, _f(1));
      await frequent.visit(_uid, _f(7));
      await frequent.applySynced(_uid, {
        '7': _pin(7, _t + 5, -_step, name: '版块七'),
        '1': _gone(DateTime.now().millisecondsSinceEpoch + 60000),
      });
      final account = frequent.current(_uid);
      expect([for (final e in account.pinned) (e.fid, e.name)], [(7, '版块七')]);
      expect(account.recent, isEmpty);
      expect(account.unpinned.keys, [1]);
      final again = SettingsRepository(storage);
      await again.init();
      addTearDown(again.dispose);
      expect(
        FrequentForumsStore.syncSnapshot(again.currentSettings, _uid),
        FrequentForumsStore.syncSnapshot(settings.currentSettings, _uid),
      );
      // The same again saves nothing.
      final before = settings.currentSettings.frequentForums;
      await frequent.applySynced(_uid, {'7': _pin(7, _t + 5, -_step, name: '版块七')});
      expect(settings.currentSettings.frequentForums, before);
    });

    test('a change of what the account watches schedules a write, of another account not', () async {
      final c = await started();
      watchChanges.add(_uid + 1);
      await pumpEventQueue();
      expect(c.repository.pushScheduled, isFalse);
      watchChanges.add(_uid);
      await pumpEventQueue();
      expect(c.repository.pushScheduled, isTrue);
    });

    test('the two switches: on by default, off leaves the lists out, on again pulls', () async {
      for (final (key, category) in [
        (SettingsKeys.crossDeviceSyncPinnedForums, SyncCategory.pinnedForums),
        (SettingsKeys.crossDeviceSyncForumWatch, SyncCategory.forumWatch),
      ]) {
        expect(SyncCoordinator.categoryEnabledIn(settings.currentSettings, category), isTrue);
        await settings.setValue(key, false);
        expect(SyncCoordinator.categoryEnabledIn(settings.currentSettings, category), isFalse);
      }
      await started();
      final before = api.pulls;
      await settings.setValue(SettingsKeys.crossDeviceSyncPinnedForums, true);
      await pumpEventQueue();
      expect(api.pulls, before + 1);
      // Neither switch is itself a synced setting: each device chooses what it syncs.
      final names = {for (final s in syncedSettings) s.key.name};
      expect(names, isNot(contains('crossDeviceSyncPinnedForums')));
      expect(names, isNot(contains('crossDeviceSyncForumWatch')));
      expect(names, isNot(contains('frequentForums')));
    });
  });
}
