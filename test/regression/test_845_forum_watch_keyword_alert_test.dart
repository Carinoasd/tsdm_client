/// Forum watch and keyword alerts: new threads of the forums an account watches, and new threads whose title holds one
/// of its alert keywords, announced by the app itself.
///
/// * A source (a forum's first page by publish time, `orderby=dateline`, or the guide's list of the latest threads) is
///   read from the structured answer of the forum's app API, or from the web page without the plugin; the forum's
///   message (the guide switched off), a guest's page or a page served to another account is no reading.
/// * The threads above the highest thread id seen in a source are new; the first reading of a source only sets it,
///   so nothing older than the moment the forum was watched is announced. A thread is announced once (the alerts
///   kept, at most 300), never one of a blocked author, with a filter keyword or of a filtered forum.
/// * Every source is read once a round, the forums (at most 10, watched and picked for the keywords together) then
///   the latest threads, with a pause between two; a 429 or a page of another account stops the round, a failure
///   keeps the mark of its source.
/// * One notification per forum for its new threads, one for the threads found with a keyword; each category can be
///   switched off and keeps the quiet hours.
///
/// The answers are the test forum's: `forum_watch_v2_fid8_before.json` and `forum_watch_v2_fid8_after.json` (plugin
/// 3.7.0, `schema: 2`: the forum before and after another account posted a thread), `guide_v7_newthread.json` and
/// `forum_picture_mode_defstyle_x5.html` (a forum page without the plugin), scrubbed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/forum_watch/cubit/forum_watch_cubit.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_config.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_state.dart';
import 'package:tsdm_client/features/forum_watch/repository/forum_watch_store.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_check.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_fetch.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_notice.dart';
import 'package:tsdm_client/features/forum_watch/view/forum_watch_page.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/utils/push_rules.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_notice.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';

String _data(String name) => File('test/data/$name').readAsStringSync();

const _uid = 35;
const _fid = 8;
const _newTid = 9202876;
final _now = DateTime(2026, 11, 10, 12);

WatchRow _row(int tid, {int fid = _fid, String title = '', int authorUid = 40, String author = 'someone'}) => WatchRow(
  tid: tid,
  fid: fid,
  title: title.isEmpty ? 'thread $tid' : title,
  author: author,
  authorUid: authorUid,
  forumName: 'forum $fid',
);

ForumWatchConfig _config({
  List<int> forums = const [_fid],
  List<String> keywords = const [],
  KeywordScope scope = const KeywordScope(),
}) => ForumWatchConfig(
  forums: [for (final f in forums) WatchedForum(fid: f, name: 'forum $f', updated: 1)],
  keywords: [for (final k in keywords) AlertKeyword(text: k, updated: 1)],
  scope: scope,
);

ForumWatchReading _hits(
  String source,
  List<WatchRow> rows, {
  ForumWatchConfig? config,
  ForumWatchState state = const ForumWatchState(),
  UserBlockList? blocks,
}) => forumWatchHitsOf(
  source: source,
  rows: rows,
  config: config ?? _config(),
  state: state,
  blocks: blocks ?? const UserBlockList.empty(_uid),
  now: _now,
);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('reading a source', () {
    test('a forum is asked by publish time, in the JSON mode without blocks nor previews', () {
      final url = forumWatchForumUrl(_fid, base: 'https://forum.test');
      final uri = Uri.parse(url);
      expect(uri.queryParameters, containsPair('mod', 'forumdisplay'));
      expect(uri.queryParameters, containsPair('fid', '$_fid'));
      expect(uri.queryParameters, containsPair('orderby', 'dateline'));
      expect(uri.queryParameters, containsPair('tsdmapp', 'json'));
      expect(uri.queryParameters, containsPair('nodoc', '1'));
      expect(uri.queryParameters.keys, isNot(contains('preview')));
      expect(forumWatchUrlOf(forumWatchLatestSource, base: 'https://forum.test'), contains('view=newthread'));
      expect(forumWatchUrlOf('nonsense'), isNull);
    });

    test('the structured forum answer: its threads, the forum name, the account served', () {
      final before = forumWatchRowsOf(forumWatchForumSource(_fid), _data('tsdmapp/forum_watch_v2_fid8_before.json'));
      final after = forumWatchRowsOf(
        forumWatchForumSource(_fid),
        jsonDecode(_data('tsdmapp/forum_watch_v2_fid8_after.json')),
      );
      expect(before, isA<ForumWatchFetched>());
      expect(after, isA<ForumWatchFetched>());
      before as ForumWatchFetched;
      after as ForumWatchFetched;
      expect(after.viewerUid, _uid);
      expect(before.rows.map((e) => e.tid), isNot(contains(_newTid)));
      final fresh = after.rows.firstWhere((e) => e.tid == _newTid);
      expect(fresh.title, '新帖提醒实测：芙莉莲 第二季讨论');
      expect(fresh.author, 'ag_low');
      expect(fresh.authorUid, 31);
      expect(fresh.fid, _fid);
      expect(fresh.forumName, '聲優茶話會');
    });

    test('the guide of the latest threads: its rows with their forums, moved placeholders left out', () {
      final json = jsonDecode(_data('tsdmapp/guide_v7_newthread.json')) as Map<String, dynamic>;
      final result = forumWatchRowsOf(forumWatchLatestSource, json);
      expect(result, isA<ForumWatchFetched>());
      result as ForumWatchFetched;
      final rows = (json['threads'] as List).cast<Map<String, dynamic>>();
      expect(result.rows, hasLength(rows.where((e) => e['moved'] == 0).length));
      expect(result.rows.first.fid, 31);
      expect(result.rows.first.forumName, isNotEmpty);
      expect(result.viewerUid, _uid);
    });

    test("the forum's message (the guide switched off) is no reading", () {
      const off = '{"ok":0,"error":"message","message":"抱歉，导读功能尚未开启","login":0,"uid":35}';
      expect(forumWatchRowsOf(forumWatchLatestSource, off), isA<ForumWatchFetchFailed>());
      expect(forumWatchRowsOf(forumWatchForumSource(2), off), isA<ForumWatchFetchFailed>());
    });

    test('the web page without the plugin', () {
      final result = forumWatchRowsOf(forumWatchForumSource(73), _data('forum_picture_mode_defstyle_x5.html'));
      expect(result, isA<ForumWatchFetched>());
      result as ForumWatchFetched;
      expect(result.rows.map((e) => e.tid), containsAll([1000004, 1000001]));
      expect(result.rows.every((e) => e.tid > 0 && e.fid == 73 && e.title.isNotEmpty), isTrue);
      expect(result.rows.first.forumName, '原创绘图区');
    });
  });

  group('what a reading brings', () {
    test('the first reading of a source only sets its mark', () {
      final r = _hits(forumWatchForumSource(_fid), [_row(10), _row(12), _row(11)]);
      expect(r.mark, 12);
      expect(r.found, isEmpty);
    });

    test('the threads above the mark of a watched forum are found, the mark follows', () {
      final source = forumWatchForumSource(_fid);
      final r = _hits(
        source,
        [_row(14), _row(13), _row(12), _row(9)],
        state: ForumWatchState(marks: {source: 12}),
      );
      expect(r.mark, 14);
      expect(r.found.map((e) => e.tid), [14, 13]);
      expect(r.found.first.keywords, isEmpty);
      expect(r.found.first.forumName, 'forum $_fid');
      expect(r.found.first.at, _now);
    });

    test('the threads of another forum in a forum page (global sticky) are not counted', () {
      final source = forumWatchForumSource(_fid);
      final r = _hits(source, [_row(99, fid: 2), _row(13)], state: ForumWatchState(marks: {source: 12}));
      expect(r.mark, 13);
      expect(r.found.map((e) => e.tid), [13]);
    });

    test('a keyword (case ignored) is found in the latest threads, with the keywords it holds', () {
      final r = _hits(
        forumWatchLatestSource,
        [_row(21, fid: 3, title: 'Frieren 第二季'), _row(20, fid: 3, title: '别的主题')],
        config: _config(forums: const [], keywords: const ['frieren', '第二季', '无关']),
        state: const ForumWatchState(marks: {forumWatchLatestSource: 19}),
      );
      expect(r.found.map((e) => e.tid), [21]);
      expect(r.found.single.keywords, ['frieren', '第二季']);
    });

    test('a forum not watched brings nothing but its keywords', () {
      final source = forumWatchForumSource(5);
      final config = _config(
        keywords: const ['芙莉莲'],
        scope: const KeywordScope(custom: true, latest: false, forums: [WatchedForum(fid: 5, name: '', updated: 1)]),
      );
      final r = _hits(
        source,
        [_row(31, fid: 5, title: '芙莉莲讨论'), _row(30, fid: 5)],
        config: config,
        state: ForumWatchState(marks: {source: 29}),
      );
      expect(r.found.map((e) => e.tid), [31]);
      expect(r.found.single.keywords, ['芙莉莲']);
    });

    test('a picked scope without the latest threads leaves them out', () {
      final config = _config(
        forums: const [],
        keywords: const ['芙莉莲'],
        scope: const KeywordScope(custom: true, latest: false),
      );
      expect(config.sources, isEmpty);
      final r = _hits(
        forumWatchLatestSource,
        [_row(31, title: '芙莉莲')],
        config: config,
        state: const ForumWatchState(marks: {forumWatchLatestSource: 30}),
      );
      expect(r.found, isEmpty);
    });

    test('a thread is found once, by whichever source read it first', () {
      final source = forumWatchForumSource(_fid);
      final state = ForumWatchState(
        marks: {source: 12, forumWatchLatestSource: 12},
        alerts: [WatchAlert(tid: 13, fid: _fid, title: 't', author: 'a', at: _now)],
      );
      expect(_hits(source, [_row(14), _row(13), _row(14)], state: state).found.map((e) => e.tid), [14]);
      final latest = _hits(
        forumWatchLatestSource,
        [_row(13, title: 'kw')],
        config: _config(keywords: const ['kw']),
        state: state,
      );
      expect(latest.found, isEmpty);
    });

    test('nothing of a blocked author, with a filter keyword or of a filtered forum', () {
      final source = forumWatchForumSource(_fid);
      final blocks = UserBlockList(
        ownerUid: _uid,
        users: [BlockedUser(uid: 77, username: 'x', blockedAt: _now)],
        filters: ThreadFilters(
          keywordRecords: const [BlockedKeyword(text: '剧透', updated: 1)],
          forumRecords: const [BlockedForum(fid: 3, name: '', updated: 1)],
        ),
      );
      final r = _hits(
        source,
        [_row(15, authorUid: 77), _row(14, title: '第二季剧透'), _row(13)],
        state: ForumWatchState(marks: {source: 12}),
        blocks: blocks,
      );
      expect(r.found.map((e) => e.tid), [13]);
      // The mark goes past them all the same: they are never announced.
      expect(r.mark, 15);
      final latest = _hits(
        forumWatchLatestSource,
        [_row(20, fid: 3, title: 'kw')],
        config: _config(keywords: const ['kw']),
        state: const ForumWatchState(marks: {forumWatchLatestSource: 19}),
        blocks: blocks,
      );
      expect(latest.found, isEmpty);
    });

    test('the alerts are kept up to their limit, the oldest dropped', () {
      var state = const ForumWatchState();
      for (var i = 1; i <= forumWatchAlertsKept + 5; i++) {
        state = state.withAlerts([WatchAlert(tid: i, fid: 1, title: '$i', author: '', at: _now)]);
      }
      expect(state.alerts, hasLength(forumWatchAlertsKept));
      expect(state.alerts.first.tid, forumWatchAlertsKept + 5);
      expect(state.alerted(1), isFalse);
      expect(ForumWatchState.fromJson(jsonDecode(jsonEncode(state))), state);
    });
  });

  group('what is watched', () {
    test('the sources: the forums (at most 10, the watched first), then the latest threads with keywords', () {
      final many = _config(forums: [for (var i = 1; i <= 12; i++) i]);
      expect(many.sources, [for (var i = 1; i <= forumWatchForumMax; i++) forumWatchForumSource(i)]);
      expect(_config().sources, [forumWatchForumSource(_fid)]);
      expect(_config(keywords: const ['k']).sources, [forumWatchForumSource(_fid), forumWatchLatestSource]);
      final picked = _config(
        keywords: const ['k'],
        scope: const KeywordScope(custom: true, latest: false, forums: [WatchedForum(fid: 2, name: '', updated: 1)]),
      );
      expect(picked.sources, [forumWatchForumSource(_fid), forumWatchForumSource(2)]);
      expect(picked.copyWith(keywords: const []).sources, [forumWatchForumSource(_fid)]);
    });

    test('stored as JSON; garbage reads as nothing watched, duplicates once', () {
      final config = _config(
        forums: const [_fid, 2],
        keywords: const ['a', 'B'],
        scope: const KeywordScope(custom: true, forums: [WatchedForum(fid: 3, name: 'x', updated: 2)]),
      );
      expect(ForumWatchConfig.fromJson(jsonDecode(jsonEncode(config))), config);
      expect(ForumWatchConfig.fromJson('nonsense'), const ForumWatchConfig());
      final dup = ForumWatchConfig.fromJson(const {
        'forums': [
          {'fid': 2, 'name': 'a'},
          {'fid': 2, 'name': 'b'},
          {'fid': -1},
          'x',
        ],
        'keywords': [
          {'text': 'K'},
          {'text': ' k '},
          {'text': '   '},
        ],
      });
      expect(dup.forums.single.name, 'a');
      expect(dup.keywords.single.text, 'K');
    });
  });

  group('store, cubit and round', () {
    late AppDatabase db;
    late StorageProvider storage;
    late ForumWatchStore store;
    late ForumWatchCubit cubit;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      store = ForumWatchStore(storage);
      cubit = ForumWatchCubit(store: store, storage: storage, uid: _uid, clock: () => _now);
    });

    tearDown(() async {
      await cubit.close();
      await store.dispose();
      await db.close();
    });

    test('watching a forum from its page starts from the newest thread shown; unwatching drops the mark', () async {
      expect(await cubit.watchForum(_fid, name: 'forum', newestTid: 100), ForumWatchChange.ok);
      expect(await cubit.watchForum(_fid, name: 'forum'), ForumWatchChange.exists);
      expect((await store.loadState(_uid)).marks, {forumWatchForumSource(_fid): 100});
      expect((await store.loadConfig(_uid)).watches(_fid), isTrue);
      // Per account.
      expect((await store.loadConfig(_uid + 1)).isEmpty, isTrue);
      await cubit.unwatchForum(_fid);
      expect((await store.loadConfig(_uid)).watches(_fid), isFalse);
      expect((await store.loadState(_uid)).marks, isEmpty);
      // Watched again: a fresh start, the first reading sets the mark.
      await cubit.watchForum(_fid, name: 'forum');
      expect((await store.loadState(_uid)).marks, isEmpty);
    });

    test('at most 10 forums, the watched and the picked ones together; at most 50 keywords', () async {
      for (var fid = 1; fid <= forumWatchForumMax; fid++) {
        expect(await cubit.watchForum(fid, name: '$fid'), ForumWatchChange.ok);
      }
      expect(await cubit.watchForum(99, name: '99'), ForumWatchChange.limitReached);
      await cubit.unwatchForum(1);
      expect(await cubit.addKeyword('kw'), ForumWatchChange.ok);
      expect(await cubit.addKeyword(' KW '), ForumWatchChange.exists);
      final scope = const KeywordScope(custom: true).copyWith(
        forums: [
          const WatchedForum(fid: 50, name: '', updated: 1),
          const WatchedForum(fid: 51, name: '', updated: 1),
        ],
      );
      expect(await cubit.setScope(scope), ForumWatchChange.limitReached);
      expect(
        await cubit.setScope(scope.copyWith(forums: [const WatchedForum(fid: 50, name: '', updated: 1)])),
        ForumWatchChange.ok,
      );
      expect((await store.loadConfig(_uid)).fetchedFids, hasLength(forumWatchForumMax));
      expect(await cubit.watchForum(1, name: '1'), ForumWatchChange.limitReached);
      for (var i = 1; i < forumWatchKeywordMax; i++) {
        expect(await cubit.addKeyword('k$i'), ForumWatchChange.ok);
      }
      expect(await cubit.addKeyword('one more'), ForumWatchChange.limitReached);
    });

    test('a change for another account than the one bound is not made', () async {
      expect(await cubit.watchForum(_fid, name: 'f', expectedUid: _uid + 1), ForumWatchChange.noAccount);
      expect((await store.loadConfig(_uid)).isEmpty, isTrue);
    });

    Future<ForumWatchRound> round({
      required Map<String, List<WatchRow>> rows,
      Set<String> fail = const {},
      Set<String> limited = const {},
      int? viewer = _uid,
      List<String>? asked,
      List<ForumWatchBatch>? announced,
      Set<NoticeCategory> allowed = const {NoticeCategory.forumNewThread, NoticeCategory.keywordAlert},
      Future<UserBlockList> Function()? blocks,
    }) => checkForumWatch(
      store: store,
      uid: _uid,
      gap: Duration.zero,
      clock: () => _now,
      blocks: blocks ?? () async => const UserBlockList.empty(_uid),
      fetch: (source) async {
        asked?.add(source);
        if (limited.contains(source)) {
          return const ForumWatchFetchFailed('429', rateLimited: true);
        }
        if (fail.contains(source)) {
          return const ForumWatchFetchFailed('down');
        }
        return ForumWatchFetched(rows[source] ?? const [], viewerUid: viewer);
      },
      announcing: (category) async => allowed.contains(category),
      announce: (batch) async {
        announced?.add(batch);
        return true;
      },
    );

    test(
      'a round: the first sets the marks, the next finds and announces once per forum and for the keywords',
      () async {
        await cubit.watchForum(_fid, name: 'forum $_fid');
        await cubit.watchForum(2, name: 'forum 2');
        await cubit.addKeyword('芙莉莲');
        final source = forumWatchForumSource(_fid);
        final asked = <String>[];
        final first = await round(
          rows: {
            source: [_row(10)],
            forumWatchForumSource(2): [_row(5, fid: 2)],
            forumWatchLatestSource: [_row(10)],
          },
          asked: asked,
        );
        expect(asked, [forumWatchForumSource(2), source, forumWatchLatestSource]);
        expect(first.found, isEmpty);
        final announced = <ForumWatchBatch>[];
        final second = await round(
          rows: {
            source: [_row(13), _row(12, title: '芙莉莲 第二季'), _row(11), _row(10)],
            forumWatchForumSource(2): [_row(6, fid: 2)],
            forumWatchLatestSource: [_row(14, fid: 3, title: '芙莉莲周边'), _row(12, title: '芙莉莲 第二季')],
          },
          announced: announced,
        );
        expect(second.found.map((e) => e.tid).toSet(), {13, 12, 11, 6, 14});
        expect(announced, hasLength(3));
        final keyword = announced.firstWhere((b) => b.keyword);
        expect(keyword.alerts.map((e) => e.tid), [12, 14]);
        expect(announced.firstWhere((b) => !b.keyword && b.fid == _fid).alerts.map((e) => e.tid), [13, 11]);
        expect(announced.firstWhere((b) => !b.keyword && b.fid == 2).alerts.map((e) => e.tid), [6]);
        // The same lists again: nothing new.
        final again = <ForumWatchBatch>[];
        await round(
          rows: {
            source: [_row(13), _row(12, title: '芙莉莲 第二季')],
            forumWatchLatestSource: [_row(14, fid: 3, title: '芙莉莲周边')],
          },
          announced: again,
        );
        expect(again, isEmpty);
        await cubit.reload();
        expect(cubit.state.alerts.map((e) => e.tid).toSet(), {13, 12, 11, 6, 14});
      },
    );

    test('a category switched off (or the quiet hours) keeps the alerts but posts nothing, not later either', () async {
      await cubit.watchForum(_fid, name: 'f', newestTid: 10);
      final announced = <ForumWatchBatch>[];
      final r = await round(
        rows: {
          forumWatchForumSource(_fid): [_row(11)],
        },
        announced: announced,
        allowed: const {NoticeCategory.keywordAlert},
      );
      expect(r.found.map((e) => e.tid), [11]);
      expect(announced, isEmpty);
      await round(
        rows: {
          forumWatchForumSource(_fid): [_row(11)],
        },
        announced: announced,
      );
      expect(announced, isEmpty);
      expect((await store.loadState(_uid)).alerted(11), isTrue);
    });

    test('a failure keeps the mark, a 429 or a page of another account stops the round and stores nothing', () async {
      await cubit.watchForum(1, name: '1', newestTid: 10);
      await cubit.watchForum(2, name: '2', newestTid: 10);
      final asked = <String>[];
      var r = await round(
        rows: {
          forumWatchForumSource(1): [_row(11, fid: 1)],
        },
        fail: {forumWatchForumSource(2)},
        asked: asked,
      );
      expect(r.failed, 1);
      expect((await store.loadState(_uid)).marks[forumWatchForumSource(2)], 10);
      asked.clear();
      r = await round(
        rows: {
          forumWatchForumSource(1): [_row(12, fid: 1)],
        },
        limited: {forumWatchForumSource(2)},
        asked: asked,
      );
      expect(r.stopped, isTrue);
      expect(asked, [forumWatchForumSource(2)]);
      r = await round(
        rows: {
          forumWatchForumSource(2): [_row(12, fid: 2)],
        },
        viewer: null,
      );
      expect(r.stopped, isTrue);
      expect(r.found, isEmpty);
      expect((await store.loadState(_uid)).marks[forumWatchForumSource(2)], 10);
    });

    test('nothing is asked when the block list can not be read', () async {
      await cubit.watchForum(_fid, name: 'f', newestTid: 10);
      final asked = <String>[];
      final r = await round(
        rows: const {},
        asked: asked,
        blocks: () async => throw const UserBlockStorageException('broken'),
      );
      expect(asked, isEmpty);
      expect(r.stopped, isTrue);
    });

    test('the check is shared through the time of the last one; the interval is 15, 30 or 60 minutes', () async {
      await cubit.watchForum(_fid, name: 'f', newestTid: 10);
      Future<ForumWatchRound?> tick(DateTime at) => forumWatchTick(
        storage: storage,
        store: store,
        uid: _uid,
        clock: () => at,
        gap: Duration.zero,
        blocks: () async => const UserBlockList.empty(_uid),
        fetch: (source) async => const ForumWatchFetched([], viewerUid: _uid),
        announce: (_) async => true,
      );
      expect(await readForumWatchInterval(storage), const Duration(minutes: 30));
      expect(await tick(_now), isNotNull);
      expect(await tick(_now.add(const Duration(minutes: 10))), isNull);
      expect(await tick(_now.add(const Duration(minutes: 30))), isNotNull);
      await storage.saveInt(SettingsKeys.forumWatchCheckMinutes.name, 7);
      expect(await readForumWatchInterval(storage), const Duration(minutes: 30));
      await storage.saveInt(SettingsKeys.forumWatchCheckMinutes.name, 15);
      expect(await readForumWatchInterval(storage), const Duration(minutes: 15));
      // Nothing watched: no check, no slot taken.
      await cubit.unwatchForum(_fid);
      expect(await tick(_now.add(const Duration(hours: 5))), isNull);
    });

    test('the category switches and the quiet hours', () async {
      expect(await forumWatchAnnounced(storage, NoticeCategory.keywordAlert, _now), isTrue);
      await storage.saveBool(SettingsKeys.notifyKeywordAlert.name, value: false);
      expect(await forumWatchAnnounced(storage, NoticeCategory.keywordAlert, _now), isFalse);
      expect(await forumWatchAnnounced(storage, NoticeCategory.forumNewThread, _now), isTrue);
      await storage.saveBool(SettingsKeys.notifyQuietHours.name, value: true);
      expect(
        await forumWatchAnnounced(storage, NoticeCategory.forumNewThread, DateTime(2026, 11, 10, 23, 30)),
        isFalse,
      );
    });
  });

  group('the notification', () {
    WatchAlert alert(int tid, {List<String> keywords = const [], int fid = _fid}) => WatchAlert(
      tid: tid,
      fid: fid,
      forumName: '聲優茶話會',
      title: 'title $tid',
      author: 'ag_low',
      at: _now,
      keywords: keywords,
    );

    test('the new threads of a forum: one opens the thread, several open the forum', () async {
      final tr = await AppLocale.zhCn.build();
      final one = forumWatchNoticeContentOf(
        tr,
        ForumWatchBatch(alerts: [alert(1)], fid: _fid, forumName: '聲優茶話會'),
        uid: _uid,
      );
      expect(one.title, '聲優茶話會');
      expect(one.body, 'ag_low：title 1');
      expect(one.lines, isEmpty);
      expect(LocalNoticeKeys.parseOpenNotification(one.payload), (uid: _uid));
      expect(LocalNoticeKeys.parseTarget(one.payload), const LocalNoticeTarget(tid: 1));
      final many = forumWatchNoticeContentOf(
        tr,
        ForumWatchBatch(alerts: [alert(1), alert(2)], fid: _fid, forumName: '聲優茶話會'),
        uid: _uid,
      );
      expect(many.body, '2 个新主题');
      expect(many.lines, ['ag_low：title 1', 'ag_low：title 2']);
      expect(LocalNoticeKeys.parseTarget(many.payload), const LocalNoticeTarget(fid: _fid));
      expect(many.id, one.id);
      expect(many.id, forumWatchForumNoticeId(_fid));
    });

    test('the keywords: named in the notification; several open the page of the alerts', () async {
      final tr = await AppLocale.zhCn.build();
      final one = forumWatchNoticeContentOf(
        tr,
        ForumWatchBatch(
          alerts: [
            alert(1, keywords: ['芙莉莲']),
          ],
          keyword: true,
        ),
        uid: _uid,
      );
      expect(one.title, '关键字「芙莉莲」');
      expect(LocalNoticeKeys.parseTarget(one.payload), const LocalNoticeTarget(tid: 1));
      final many = forumWatchNoticeContentOf(
        tr,
        ForumWatchBatch(
          alerts: [
            alert(1, keywords: ['芙莉莲']),
            alert(2, keywords: ['a', 'b']),
          ],
          keyword: true,
        ),
        uid: _uid,
      );
      expect(many.title, tr.localNotification.channels.keywordAlert);
      expect(many.body, '2 个主题含关键字');
      expect(many.lines, ['「芙莉莲」title 1', '「a、b」title 2']);
      expect(LocalNoticeKeys.parseTarget(many.payload), const LocalNoticeTarget(watchAlerts: true));
      expect(many.id, forumWatchKeywordNoticeId(_uid));
      final hidden = forumWatchNoticeContentOf(
        tr,
        ForumWatchBatch(
          alerts: [
            alert(1, keywords: ['芙莉莲']),
          ],
          keyword: true,
        ),
        uid: _uid,
        hideContent: true,
      );
      expect('${hidden.title}${hidden.body}${hidden.lines}', isNot(contains('芙莉莲')));
      expect(hidden.body, contains('1'));
    });

    test('the batches of a round: the keywords together, the rest per forum', () {
      final batches = forumWatchBatchesOf([
        alert(1),
        alert(2, keywords: ['k']),
        alert(3, fid: 2),
        alert(4),
      ]);
      expect(batches.map((b) => (b.keyword, b.fid, b.alerts.map((a) => a.tid).join(','))), [
        (true, 0, '2'),
        (false, _fid, '1,4'),
        (false, 2, '3'),
      ]);
      expect(batches.first.category, NoticeCategory.keywordAlert);
      expect(batches.last.category, NoticeCategory.forumNewThread);
    });

    test('the ids are apart from the others', () {
      for (final n in [1, _fid, _uid, 0x0FFFFFFF]) {
        for (final id in [forumWatchForumNoticeId(n), forumWatchKeywordNoticeId(n)]) {
          expect(isLocalNoticeId(id), isFalse);
          expect(id, isNot(followedThreadNoticeId(n)));
          expect(isForumWatchNoticeId(id), isTrue);
        }
        expect(forumWatchForumNoticeId(n), isNot(forumWatchKeywordNoticeId(n)));
      }
      expect(isForumWatchNoticeId(followedThreadNoticeId(3)), isFalse);
    });

    test('the targets read back; the categories have their own channels and switches', () async {
      for (final target in const [LocalNoticeTarget(fid: 8), LocalNoticeTarget(watchAlerts: true)]) {
        expect(
          LocalNoticeKeys.parseTarget(LocalNoticeKeys.withTarget(LocalNoticeKeys.openNotificationOf(3), target)),
          target,
        );
        expect(target.isEmpty, isFalse);
      }
      // A tap opens the forum or the page of the alerts (`openLocalNoticeTarget`).
      final forum = '$baseUrl/forum.php?mod=forumdisplay&fid=8'.parseUrlToRoute();
      expect(forum?.screenPath, ScreenPaths.forum);
      expect(forum?.pathParameters, containsPair('fid', '8'));
      Iterable<String> paths(List<RouteBase> routes) sync* {
        for (final r in routes) {
          if (r is GoRoute) {
            yield r.path;
          }
          yield* paths(r.routes);
        }
      }

      expect(paths(router.configuration.routes), contains(ScreenPaths.forumWatch));
      expect(NoticeCategory.forumNewThread.settingsKey, SettingsKeys.notifyForumNewThread);
      expect(NoticeCategory.keywordAlert.settingsKey, SettingsKeys.notifyKeywordAlert);
      for (final tr in [await AppLocale.zhCn.build(), await AppLocale.zhTw.build(), await AppLocale.en.build()]) {
        expect(noticeChannelName(tr, NoticeCategory.forumNewThread), isNotEmpty);
        expect(noticeChannelName(tr, NoticeCategory.keywordAlert), isNotEmpty);
        expect(tr.forumWatch.notice.forumMany(n: 3), contains('3'));
      }
    });
  });

  group('the page', () {
    late AppDatabase db;
    late StorageProvider storage;
    late ForumWatchStore store;
    late ForumWatchCubit cubit;
    late SettingsRepository settings;
    late SettingsBloc bloc;

    setUp(() async {
      await LocaleSettings.setLocale(AppLocale.zhCn);
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings);
      await settings.init();
      bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      store = ForumWatchStore(storage);
      await store.updateConfig(
        _uid,
        (_) => _config(keywords: const ['芙莉莲']),
      );
      await store.updateState(
        _uid,
        (_, s) => s.withAlerts([
          WatchAlert(
            tid: 1,
            fid: _fid,
            forumName: '聲優茶話會',
            title: '芙莉莲 第二季',
            author: 'ag_low',
            at: _now,
            keywords: const ['芙莉莲'],
          ),
        ]),
      );
      cubit = ForumWatchCubit(store: store, storage: storage, uid: _uid);
      await cubit.reload();
    });

    tearDown(() async {
      await cubit.close();
      await bloc.close();
      await store.dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
      await LocaleSettings.setLocale(AppLocale.en);
    });

    /// Let the database writes of a change and the reload after it run, a frame between each step.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<SettingsBloc>.value(value: bloc),
            BlocProvider<ForumWatchCubit>.value(value: cubit),
          ],
          child: TranslationProvider(child: const MaterialApp(home: ForumWatchPage())),
        ),
      );
      await tester.pump();
    }

    testWidgets('the alerts, then what is watched: forums with their count, keywords, scope, interval', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('forum-watch-alert-1')), findsOneWidget);
      expect(find.text('芙莉莲 第二季'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('forum-watch-tab-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('forum-watch-forum-$_fid')), findsOneWidget);
      expect(find.text('1/$forumWatchForumMax'), findsOneWidget);
      expect(find.byKey(const ValueKey('forum-watch-keyword-芙莉莲')), findsOneWidget);
      expect(find.byKey(const ValueKey('forum-watch-scope')), findsOneWidget);
      expect(find.byKey(const ValueKey('forum-watch-scope-latest')), findsNothing);
      expect(find.text('30 分钟'), findsOneWidget);

      // A keyword added in the dialog.
      await tester.tap(find.byKey(const ValueKey('forum-watch-keyword-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('forum-watch-keyword-field')), '第二季');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('forum-watch-keyword-confirm')));
      await settle(tester);
      expect(find.byKey(const ValueKey('forum-watch-keyword-第二季')), findsOneWidget);
      expect((await tester.runAsync(() => store.loadConfig(_uid)))!.keywords.map((k) => k.text), ['第二季', '芙莉莲']);

      // The picked scope.
      await tester.tap(find.text('自选'));
      await settle(tester);
      expect(find.byKey(const ValueKey('forum-watch-scope-latest')), findsOneWidget);
      expect(find.byKey(const ValueKey('forum-watch-scope-pick')), findsOneWidget);
    });
  });
}
