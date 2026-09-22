import 'dart:async';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart' show AuthStatus;
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/blocking/utils/notice_block_filter.dart';
import 'package:tsdm_client/features/blocking/widgets/block_aware_post.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Robustness of the local block list around it: a damaged stored row, an account switch in the middle of a
/// notification sync, and the quote redaction of post cards rebuilt with the thread page.
const _aliceUid = 1000;
const _bobUid = 1001;
const _alice = UserLoginInfo(username: 'Alice', uid: _aliceUid);
const _bob = UserLoginInfo(username: 'Bob', uid: _bobUid);

final class _SwitchableAuth extends Fake implements AuthenticationRepository {
  _SwitchableAuth(this.currentUser);

  @override
  UserLoginInfo? currentUser;
}

/// Holds the [holdAt]-th read of a block list row until [release] completes.
final class _GatedStorage extends StorageProvider {
  _GatedStorage(AppDatabase db) : super(db, {}, {});

  int reads = 0;
  int holdAt = 0;
  final held = Completer<void>();
  final release = Completer<void>();

  @override
  Future<List<String>?> getStringList(String key) async {
    if (key.startsWith(UserBlockRepository.keyPrefix) && ++reads == holdAt) {
      held.complete();
      await release.future;
    }
    return super.getStringList(key);
  }
}

/// Settings rows kept in memory, for widget tests (no database timers).
final class _MemorySettings extends Fake implements StorageProvider {
  final rows = <String, List<String>>{};

  @override
  Future<List<String>?> getStringList(String key) async => rows[key];

  @override
  Future<void> saveStringList(String key, List<String> value) async => rows[key] = List.of(value);

  @override
  Future<void> deleteKey(String key) async => rows.remove(key);
}

NoticeV2 _notice(int nid, {required int author}) =>
    NoticeV2(id: nid, timestamp: 1700000000 + nid, data: 'notice $nid', ignoreType: 'post', authorId: author);

NotificationV2 _fetched(List<NoticeV2> notices) =>
    NotificationV2(status: 0, noticeList: notices, personalMessageList: const [], broadcastMessageList: const []);

/// A post built at runtime: every call is a new instance, like the posts of a freshly loaded page.
Post _post(String pid, int authorUid, String authorName, String data) => Post(
  postID: pid,
  postFloor: int.parse(pid),
  author: User(name: authorName, uid: '$authorUid', url: 'home.php?mod=space&uid=$authorUid'),
  publishTime: null,
  data: data,
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: 1,
  isDraft: false,
  packetAllTaken: false,
);

/// A quote of post [pid] linked the way Discuz renders it, followed by [body].
String _quoteOf(int pid, String quoted, {String body = 'reply body'}) =>
    '<div class="quote"><blockquote><font size="2"><a href="forum.php?mod=redirect&amp;goto=findpost&amp;pid=$pid'
    '&amp;ptid=5"><font color="#999999">Bob 发表于 2026-9-5 17:38</font></a></font><br>$quoted</blockquote></div>'
    '$body';

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('stored block list with an element that is not a string', () {
    late AppDatabase db;
    late StorageProvider storage;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      storage = StorageProvider(db, {}, {});
      final key = UserBlockRepository.keyOf(_aliceUid);
      await storage.saveStringList(key, const ['placeholder']);
      // The json of the row is valid, one element is a number: only a hand edited row or a modified backup has it.
      await db.customStatement('UPDATE settings SET string_list_value = ? WHERE name = ?', [
        '["{\\"uid\\":$_bobUid,\\"username\\":\\"Bob\\",\\"at\\":0}", 7]',
        key,
      ]);
    });

    test('is an unreadable row, not a TypeError', () async {
      final repository = UserBlockRepository(storage);
      addTearDown(repository.dispose);
      await expectLater(repository.load(_aliceUid), throwsA(isA<UserBlockStorageException>()));
      expect((await noticeBlockListOf(storage, _aliceUid)).status, UserBlockListStatus.failed);
      // Nothing is written over the stored row.
      await expectLater(
        repository.block(ownerUid: _aliceUid, uid: 1002, username: 'Carol'),
        throwsA(isA<UserBlockStorageException>()),
      );
      final row = await db
          .customSelect(
            'SELECT string_list_value FROM settings WHERE name = ?',
            variables: [Variable.withString(UserBlockRepository.keyOf(_aliceUid))],
          )
          .getSingle();
      expect(row.read<String>('string_list_value'), contains('7]'));
    });

    test('the sync of the account still stores its notices and holds back attributed ones', () async {
      final persisted = await persistFetchedNotification(
        storage: storage,
        uid: _aliceUid,
        fetched: _fetched([_notice(1, author: _bobUid), _notice(2, author: 0)]),
      );
      expect(persisted.fresh.noticeList.map((e) => e.id), [2], reason: 'the list is unknown: attributed ones wait');
      expect(persisted.unread.notice, 1);
      final stored = await storage.fetchNotificationSince(uid: _aliceUid, timestamp: 0).run();
      expect(stored.noticeList.map((e) => e.nid), unorderedEquals([1, 2]));
      expect((await countUnreadNotification(storage: storage, uid: _aliceUid)).notice, 1);
    });
  });

  group('NotificationBloc and account changes', () {
    late AppDatabase db;
    late _GatedStorage storage;
    late NotificationInfoRepository infoRepository;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      storage = _GatedStorage(db);
      addTearDown(() {
        if (!storage.release.isCompleted) storage.release.complete();
      });
      infoRepository = NotificationInfoRepository();
      addTearDown(infoRepository.dispose);
    });

    NotificationBloc buildBloc(AuthenticationRepository auth) {
      final bloc = NotificationBloc(
        notificationRepository: NotificationRepository(storageProvider: storage),
        infoRepository: infoRepository,
        authRepo: auth,
        storageProvider: storage,
      );
      addTearDown(bloc.close);
      return bloc;
    }

    Future<NotificationState> next(NotificationBloc bloc, bool Function(NotificationState) test) =>
        bloc.stream.firstWhere(test).timeout(const Duration(seconds: 5));

    /// A sync of Alice whose [holdRead]-th block list read (1: storing, 2: its recount, 3: the published recount)
    /// switches the current account to Bob.
    Future<void> switchDuringSync(int holdRead) async {
      final auth = _SwitchableAuth(_alice);
      final bloc = buildBloc(auth);

      // A first sync of Alice leaves her lists and latest time in the state.
      final first = next(bloc, (s) => s.status == NotificationStatus.success);
      bloc.add(NotificationInfoFetched(NotificationInfoStateSuccess(_aliceUid, _fetched([_notice(1, author: 0)]))));
      expect((await first).latestTime, isNotNull);
      await pumpEventQueue();

      storage.holdAt = storage.reads + holdRead;
      bloc.add(NotificationInfoFetched(NotificationInfoStateSuccess(_aliceUid, _fetched([_notice(2, author: 0)]))));
      await storage.held.future.timeout(const Duration(seconds: 5));
      expect(bloc.state.status, NotificationStatus.loading);
      auth.currentUser = _bob;
      final settled = next(bloc, (s) => s.status != NotificationStatus.loading);
      storage.release.complete();
      expect(await settled, const NotificationState(), reason: 'nothing of Alice is kept, the state is not loading');

      // The reload of Bob is not skipped and does not carry the latest time of Alice.
      await persistFetchedNotification(storage: storage, uid: _bobUid, fetched: _fetched([_notice(9, author: 0)]));
      final reloaded = next(bloc, (s) => s.status == NotificationStatus.success);
      bloc.add(NotificationReloadFromStorageRequested());
      final state = await reloaded;
      expect(state.noticeList.map((e) => e.id), [9]);
      expect(state.latestTime, isNull);
    }

    test('a switch while the result is stored resets the state instead of leaving it loading', () async {
      await switchDuringSync(1);
    });

    test('a switch while the unread counts are published resets the state instead of leaving it loading', () async {
      await switchDuringSync(3);
    });

    test('a reload after an account switch does not carry the latest time of the previous account', () async {
      // The app records the latest time of every success as the fetch time of the current account; a change of the
      // block list reloads right after every account switch.
      final auth = _SwitchableAuth(_alice);
      final bloc = buildBloc(auth);
      final first = next(bloc, (s) => s.status == NotificationStatus.success);
      bloc.add(NotificationInfoFetched(NotificationInfoStateSuccess(_aliceUid, _fetched([_notice(1, author: 0)]))));
      expect((await first).latestTime, isNotNull);
      await pumpEventQueue();

      auth.currentUser = _bob;
      await persistFetchedNotification(storage: storage, uid: _bobUid, fetched: _fetched([_notice(9, author: 0)]));
      final reloaded = next(bloc, (s) => s.status == NotificationStatus.success);
      bloc.add(NotificationReloadFromStorageRequested());
      final state = await reloaded;
      expect(state.noticeList.map((e) => e.id), [9]);
      expect(state.latestTime, isNull);
    });

    test('a sync requested without an account does not leave the state loading', () async {
      final auth = _SwitchableAuth(null);
      final bloc = buildBloc(auth)..add(NotificationUpdateAllRequested());
      await pumpEventQueue();
      expect(bloc.state.status, isNot(NotificationStatus.loading));

      auth.currentUser = _alice;
      await persistFetchedNotification(storage: storage, uid: _aliceUid, fetched: _fetched([_notice(3, author: 0)]));
      final reloaded = next(bloc, (s) => s.status == NotificationStatus.success);
      bloc.add(NotificationReloadFromStorageRequested());
      expect((await reloaded).noticeList.map((e) => e.id), [3]);
    });
  });

  group('quote redaction kept with the post', () {
    const secret = 'secret words';
    final bobPost = _post('1', _bobUid, 'Bob', 'first');
    final alicePost = _post('2', _aliceUid, 'Alice', 'second');

    int? authorOf(List<Post> posts, int pid) =>
        int.tryParse(posts.where((e) => e.postID == '$pid').firstOrNull?.author.uid ?? '');

    test('a rebuild gets the same redacted html without parsing again', () {
      final reply = _post('3', _aliceUid, 'Alice', _quoteOf(1, secret));
      String redact() => redactBlockedQuotesOf(
        reply,
        blockedUids: const {_bobUid},
        authorOfPost: (pid) => authorOf([bobPost, reply], pid),
        placeholder: 'HIDDEN',
      );
      final first = redact();
      expect(first, isNot(contains(secret)));
      expect(first, contains('HIDDEN'));
      expect(first, contains('reply body'));
      expect(redact(), same(first));
    });

    test('the kept result follows the loaded posts, the block list and the placeholder', () {
      final reply = _post('3', _aliceUid, 'Alice', _quoteOf(1, secret));
      String redact(List<Post> posts, Set<int> blocked, String placeholder) {
        final kept = redactBlockedQuotesOf(
          reply,
          blockedUids: blocked,
          authorOfPost: (pid) => authorOf(posts, pid),
          placeholder: placeholder,
        );
        final plain = redactBlockedQuotes(
          reply.data,
          blockedUids: blocked,
          authorOfPost: (pid) => authorOf(posts, pid),
          placeholder: placeholder,
        );
        expect(kept, plain, reason: 'same result as redacting without keeping anything');
        return kept;
      }

      // The quoted post is not loaded yet: it can not be attributed.
      expect(redact([reply], {_bobUid}, 'HIDDEN'), same(reply.data));
      // A later page loads it.
      expect(redact([bobPost, reply], {_bobUid}, 'HIDDEN'), isNot(contains(secret)));
      // Unblocked, or somebody else blocked.
      expect(redact([bobPost, reply], {}, 'HIDDEN'), same(reply.data));
      expect(redact([bobPost, reply], {1002}, 'HIDDEN'), same(reply.data));
      // Blocked again with another language.
      expect(redact([bobPost, reply], {_bobUid}, 'VERBORGEN'), contains('VERBORGEN'));
    });

    test('nested quotes give the same result as without keeping', () {
      final nested = _post('4', _aliceUid, 'Alice', _quoteOf(1, _quoteOf(2, 'inner words', body: 'outer words')));
      final posts = [bobPost, alicePost, nested];
      for (final blocked in [
        {_bobUid},
        {_aliceUid},
        {_aliceUid, _bobUid},
        {1002},
        {_bobUid},
      ]) {
        final kept = redactBlockedQuotesOf(
          nested,
          blockedUids: blocked,
          authorOfPost: (pid) => authorOf(posts, pid),
          placeholder: 'HIDDEN',
        );
        final plain = redactBlockedQuotes(
          nested.data,
          blockedUids: blocked,
          authorOfPost: (pid) => authorOf(posts, pid),
          placeholder: 'HIDDEN',
        );
        expect(kept, plain, reason: 'blocked $blocked');
      }
    });

    testWidgets('BlockAwarePost passes the same redacted html on every rebuild', (tester) async {
      final repository = UserBlockRepository(_MemorySettings());
      await repository.block(ownerUid: _aliceUid, uid: _bobUid, username: 'Bob');
      final cubit = UserBlockCubit(
        repository: repository,
        currentUid: () => _aliceUid,
        authStatus: const Stream<AuthStatus>.empty(),
      );
      addTearDown(() async {
        await cubit.close();
        await repository.dispose();
      });
      final reply = _post('3', _aliceUid, 'Alice', _quoteOf(1, secret));
      final built = <String>[];
      late StateSetter rebuild;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: BlocProvider.value(
              value: cubit,
              child: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    rebuild = setState;
                    return BlockAwarePost(
                      post: reply,
                      postList: [bobPost, reply],
                      builder: (_, p) {
                        built.add(p.data);
                        return Text(p.data);
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      rebuild(() {});
      await tester.pump();
      rebuild(() {});
      await tester.pump();

      expect(built.length, greaterThanOrEqualTo(2));
      expect(built.last, isNot(contains(secret)));
      expect(built.last, contains(t.userBlock.quotePlaceholder));
      expect(built.last, same(built[built.length - 2]), reason: 'kept, not parsed again on the rebuild');
      expect(tester.takeException(), isNull);
    });
  });
}
