import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// The visible unread badge must not count notices of locally blocked users on any path: the foreground sync result
/// ([NotificationBloc] handling [NotificationInfoFetched]) and the homepage header hint
/// ([NotificationInfoRepository.applyServerHint] guarded by [noticeHintAllowed]).
///
/// Personal message conversations with locally blocked peers are muted, not hidden: they are still stored with their
/// real read state and listed, but left out of the news of a fetch (system notification, auto sync hint) and of the
/// unread badge, and they count again once the peer is unblocked. Each account only follows its own list.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _carol = UserLoginInfo(username: 'Carol', uid: 4000);
const _bob = 2000;
const _troll = 3000;

final class _SwitchableAuth extends Fake implements AuthenticationRepository {
  @override
  UserLoginInfo? currentUser = _alice;
}

final class _ReadGateStorage extends StorageProvider {
  _ReadGateStorage(AppDatabase db) : super(db, {}, {});

  bool armed = false;
  final entered = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<List<String>?> getStringList(String key) async {
    if (armed && key.startsWith(UserBlockRepository.keyPrefix)) {
      if (!entered.isCompleted) entered.complete();
      await resume.future;
    }
    return super.getStringList(key);
  }
}

NoticeV2 _notice(int nid, {required int author}) => NoticeV2(
  id: nid,
  timestamp: 100 + nid,
  data: 'n$nid',
  ignoreType: 'post',
  authorId: author,
);

const _unreadPm = PersonalMessageV2(
  timestamp: 150,
  data: 'hi',
  peerUid: _bob,
  peerUsername: 'Bob',
  sender: false,
  alreadyRead: false,
);

/// An unread conversation whose last message came from [peerUid].
PersonalMessageV2 _pm(int peerUid, String peerUsername) => PersonalMessageV2(
  timestamp: 150,
  data: 'hi from $peerUsername',
  peerUid: peerUid,
  peerUsername: peerUsername,
  sender: false,
  alreadyRead: false,
);

/// One unread conversation with the blocked troll and one with Bob, who is not blocked.
List<PersonalMessageV2> _mixedPms() => [_pm(_troll, 'troll'), _pm(_bob, 'Bob')];

NotificationV2 _fetched(List<NoticeV2> notices, {List<PersonalMessageV2> personalMessages = const [_unreadPm]}) =>
    NotificationV2(
      status: 0,
      noticeList: notices,
      personalMessageList: personalMessages,
      broadcastMessageList: const [],
    );

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late UserBlockRepository blockRepo;
  late NotificationInfoRepository infoRepository;
  late List<NotificationStateInfo> published;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    storage = StorageProvider(db, {}, {});
    blockRepo = UserBlockRepository(storage);
    addTearDown(blockRepo.dispose);
    infoRepository = NotificationInfoRepository();
    addTearDown(infoRepository.dispose);
    published = <NotificationStateInfo>[];
    final sub = infoRepository.status.listen(published.add);
    addTearDown(sub.cancel);
  });

  NotificationBloc buildBloc({UserLoginInfo user = _alice}) {
    final bloc = NotificationBloc(
      notificationRepository: NotificationRepository(storageProvider: storage),
      infoRepository: infoRepository,
      authRepo: AuthenticationRepository(user: user),
      storageProvider: storage,
    );
    addTearDown(bloc.close);
    return bloc;
  }

  Future<void> deliver(NotificationBloc bloc, int uid, NotificationV2 info) async {
    final done = bloc.stream.firstWhere((s) => s.status == NotificationStatus.success);
    bloc.add(NotificationInfoFetched(NotificationInfoStateSuccess(uid, info)));
    await done.timeout(const Duration(seconds: 5));
    await pumpEventQueue();
  }

  /// Ask [bloc] for the reload a change of the block list requests (`onListChanged`, see doc/user_blocking.md) and
  /// wait until the recounted badge satisfies [reached], or give up: the expectation after it reports the failure.
  ///
  /// The reloaded lists may equal the ones in state, so there is no new bloc state to wait for.
  Future<void> reloadUntilBadge(NotificationBloc bloc, bool Function(NotificationStateInfo) reached) async {
    bloc.add(NotificationReloadFromStorageRequested());
    for (var i = 0; i < 200 && (published.isEmpty || !reached(published.last)); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Peer and read flag of every conversation stored for [uid].
  Future<List<(int, bool)>> storedConversations(int uid) async {
    final group = await storage.fetchNotificationSince(uid: uid, timestamp: 0).run();
    return group.personalMessageList.map((e) => (e.peerUid, e.alreadyRead)).toList();
  }

  group('foreground sync result', () {
    test('switching accounts during the stored unread recount discards the old badge', () async {
      final gated = _ReadGateStorage(db);
      await persistFetchedNotification(
        storage: gated,
        uid: _alice.uid!,
        fetched: _fetched([_notice(1, author: _troll)]),
      );
      final auth = _SwitchableAuth();
      final bloc = NotificationBloc(
        notificationRepository: NotificationRepository(storageProvider: gated),
        infoRepository: infoRepository,
        authRepo: auth,
        storageProvider: gated,
      );
      addTearDown(() async {
        if (!gated.resume.isCompleted) gated.resume.complete();
        await bloc.close();
      });
      gated.armed = true;
      bloc.add(NotificationReloadFromStorageRequested());
      await gated.entered.future.timeout(const Duration(seconds: 5));
      auth.currentUser = const UserLoginInfo(username: 'Bob', uid: _bob);
      gated.resume.complete();
      await bloc.close();
      await pumpEventQueue();
      expect(published, isEmpty, reason: 'a recount started for Alice must not update Bob after its async read');
    });

    test('the badge published by a successful fetch leaves out notices of blocked users', () async {
      await blockRepo.block(ownerUid: _alice.uid, uid: _troll, username: 'troll');
      final bloc = buildBloc();

      await deliver(bloc, _alice.uid!, _fetched([_notice(1, author: _troll), _notice(2, author: _bob)]));

      expect(published, isNotEmpty);
      expect(published.last.notice, 1, reason: 'the blocked author notice is stored but must not count');
      expect(
        published.last.personalMessage,
        1,
        reason: 'the unread conversation is with Bob, who is not blocked: only blocked peers are muted',
      );
      // The page still gets every notice; hiding is done where it is shown.
      expect(bloc.state.noticeList.map((e) => e.id), containsAll([1, 2]));
    });

    test('without blocked users the fetched count is unchanged', () async {
      final bloc = buildBloc();

      await deliver(bloc, _alice.uid!, _fetched([_notice(1, author: _troll), _notice(2, author: _bob)]));

      expect(published.last.notice, 2);
      expect(published.last.personalMessage, 1);
    });

    test('a fetch finishing after the account changed does not touch the badge', () async {
      // Result for another account than the current one (Alice): stored for that account, badge left alone.
      buildBloc().add(
        NotificationInfoFetched(NotificationInfoStateSuccess(_bob, _fetched([_notice(1, author: _troll)]))),
      );
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();

      expect(published, isEmpty);
    });
  });

  group('personal messages of blocked peers', () {
    test('a mixed delivery counts only the peer that is not blocked and keeps the muted one unread', () async {
      await blockRepo.block(ownerUid: _alice.uid, uid: _troll, username: 'troll');
      final bloc = buildBloc();

      await deliver(bloc, _alice.uid!, _fetched([_notice(2, author: _bob)], personalMessages: _mixedPms()));

      expect(published, isNotEmpty);
      expect(published.last.personalMessage, 1, reason: 'the conversation with the blocked peer must not count');
      expect(published.last.notice, 1);
      // Muted is not hidden: the page still lists the conversation, with its real read state.
      expect(
        bloc.state.personalMessageList.map((e) => (e.peerUid, e.alreadyRead)),
        unorderedEquals([(_troll, false), (_bob, false)]),
        reason: 'the conversation with the blocked peer stays listed and unread',
      );
      expect(
        await storedConversations(_alice.uid!),
        unorderedEquals([(_troll, false), (_bob, false)]),
        reason: 'blocking never marks a conversation as read nor drops it from storage',
      );
    });

    test('the news of a fetch leaves out the blocked peer while both conversations are stored unread', () async {
      await blockRepo.block(ownerUid: _alice.uid, uid: _troll, username: 'troll');

      final persisted = await persistFetchedNotification(
        storage: storage,
        uid: _alice.uid!,
        fetched: _fetched([_notice(1, author: _troll), _notice(2, author: _bob)], personalMessages: _mixedPms()),
      );

      // `fresh` is what feeds the system notification and the auto sync hint.
      expect(
        persisted.fresh.personalMessageList.map((e) => e.peerUid),
        [_bob],
        reason: 'a message from a blocked peer is never announced',
      );
      expect(persisted.fresh.noticeList.map((e) => e.id), [2]);
      expect(persisted.unread.personalMessage, 1);
      expect(persisted.unread.notice, 1);
      // The copies that are stored and listed are not filtered.
      expect(persisted.reconciled.personalMessageList.map((e) => e.peerUid), unorderedEquals([_troll, _bob]));
      expect(await storedConversations(_alice.uid!), unorderedEquals([(_troll, false), (_bob, false)]));
    });

    test('unblocking brings the muted conversation back into the badge', () async {
      await blockRepo.block(ownerUid: _alice.uid, uid: _troll, username: 'troll');
      final bloc = buildBloc();
      await deliver(bloc, _alice.uid!, _fetched(const [], personalMessages: _mixedPms()));
      expect(published.last.personalMessage, 1);

      expect(await blockRepo.unblock(ownerUid: _alice.uid, uid: _troll), UserBlockResult.ok);

      final recount = await countUnreadNotification(storage: storage, uid: _alice.uid!);
      expect(recount.personalMessage, 2, reason: 'the conversation kept its unread state while it was muted');
      await reloadUntilBadge(bloc, (badge) => badge.personalMessage == 2);
      expect(published.last.personalMessage, 2, reason: 'the reload after a change of the list recounts the badge');
      expect(bloc.state.personalMessageList.map((e) => e.peerUid), unorderedEquals([_troll, _bob]));
    });

    test('blocking after the delivery mutes the stored conversation on the next recount', () async {
      final bloc = buildBloc();
      await deliver(bloc, _alice.uid!, _fetched(const [], personalMessages: _mixedPms()));
      expect(published.last.personalMessage, 2);

      await blockRepo.block(ownerUid: _alice.uid, uid: _troll, username: 'troll');

      await reloadUntilBadge(bloc, (badge) => badge.personalMessage == 1);
      expect(published.last.personalMessage, 1);
      expect(await storedConversations(_alice.uid!), unorderedEquals([(_troll, false), (_bob, false)]));
    });

    test('a muted conversation read while its peer is blocked stays read after unblocking', () async {
      await blockRepo.block(ownerUid: _alice.uid, uid: _troll, username: 'troll');
      await persistFetchedNotification(
        storage: storage,
        uid: _alice.uid!,
        fetched: _fetched(const [], personalMessages: _mixedPms()),
      );

      // The conversation is still listed, so it can be opened and marked as read like any other.
      await storage.markPersonalMessageAsRead(uid: _alice.uid!, peerUid: _troll, read: true).run();
      expect(await storedConversations(_alice.uid!), unorderedEquals([(_troll, true), (_bob, false)]));

      await blockRepo.unblock(ownerUid: _alice.uid, uid: _troll);
      final recount = await countUnreadNotification(storage: storage, uid: _alice.uid!);
      expect(recount.personalMessage, 1, reason: 'unblocking restores the real read state, it invents no unread');
    });

    test('another account does not inherit the blocks of the first one', () async {
      await blockRepo.block(ownerUid: _alice.uid, uid: _troll, username: 'troll');

      final forAlice = await persistFetchedNotification(
        storage: storage,
        uid: _alice.uid!,
        fetched: _fetched([_notice(1, author: _troll)], personalMessages: _mixedPms()),
      );
      final forCarol = await persistFetchedNotification(
        storage: storage,
        uid: _carol.uid!,
        fetched: _fetched([_notice(11, author: _troll)], personalMessages: _mixedPms()),
      );

      expect(forAlice.fresh.personalMessageList.map((e) => e.peerUid), [_bob]);
      expect(forAlice.unread.personalMessage, 1);
      expect(forAlice.unread.notice, 0);
      expect((await blockRepo.load(_carol.uid)).uids, isEmpty);
      expect(
        forCarol.fresh.personalMessageList.map((e) => e.peerUid),
        unorderedEquals([_troll, _bob]),
        reason: 'Carol blocked nobody: the peer blocked by Alice is announced to her',
      );
      expect(forCarol.fresh.noticeList.map((e) => e.id), [11]);
      expect(forCarol.unread.personalMessage, 2);
      expect(forCarol.unread.notice, 1);

      // Same for the badge of the foreground sync once Carol is the current account.
      final bloc = buildBloc(user: _carol);
      await deliver(bloc, _carol.uid!, _fetched([_notice(11, author: _troll)], personalMessages: _mixedPms()));
      expect(published.last.personalMessage, 2);
      expect(published.last.notice, 1);
      // And the list of Alice still applies to Alice.
      expect((await countUnreadNotification(storage: storage, uid: _alice.uid!)).personalMessage, 1);
    });
  });

  group('homepage header hint', () {
    test('only a known empty list of the current account allows the notice hint', () {
      final uid = _alice.uid;
      expect(noticeHintAllowed(UserBlockList.empty(uid), currentUid: uid), isTrue);
      // A guest list cannot authorize raw hints for a logged-in account.
      expect(noticeHintAllowed(const UserBlockList.empty(null), currentUid: uid), isFalse);
      expect(noticeHintAllowed(const UserBlockList.empty(null), currentUid: null), isTrue);

      final active = UserBlockList(
        ownerUid: uid,
        users: [BlockedUser(uid: _troll, username: 'troll', blockedAt: DateTime(2026))],
      );
      expect(noticeHintAllowed(active, currentUid: uid), isFalse);
      expect(
        noticeHintAllowed(UserBlockList.unknown(uid, status: UserBlockListStatus.loading), currentUid: uid),
        isFalse,
      );
      expect(
        noticeHintAllowed(UserBlockList.unknown(uid, status: UserBlockListStatus.failed), currentUid: uid),
        isFalse,
      );
      // Cubit still on the list of the previous account, or its initial state before following one.
      expect(noticeHintAllowed(const UserBlockList.empty(_bob), currentUid: uid), isFalse);
      expect(
        noticeHintAllowed(const UserBlockList.unknown(null, status: UserBlockListStatus.loading), currentUid: uid),
        isFalse,
      );
    });

    test('a withheld notice hint keeps the filtered badge and still merges the personal message hint', () async {
      infoRepository
        ..updateInfo(unreadNoticeCount: 1, unreadPersonalMessageCount: 0, unreadBroadcastMessageCount: 3)
        ..applyServerHint(noticeCount: null, hasPersonalMessage: true);
      await pumpEventQueue();

      expect(published.map((e) => (e.notice, e.personalMessage, e.broadcastMessage)), [(1, 0, 3), (1, 1, 3)]);
    });

    test('a withheld personal message hint keeps the filtered count', () async {
      infoRepository
        ..updateInfo(unreadNoticeCount: 1, unreadPersonalMessageCount: 2, unreadBroadcastMessageCount: 3)
        // Both hints withheld: nothing changes and nothing new is published.
        ..applyServerHint(noticeCount: null, hasPersonalMessage: null)
        // The notice hint alone still merges; the personal message count is left as it is, not reset nor raised.
        ..applyServerHint(noticeCount: 4, hasPersonalMessage: null);
      await pumpEventQueue();

      expect(published.map((e) => (e.notice, e.personalMessage, e.broadcastMessage)), [(1, 2, 3), (4, 2, 3)]);
    });

    test('a withheld personal message hint does not bring a muted conversation back', () async {
      infoRepository
        ..updateInfo(unreadNoticeCount: 0, unreadPersonalMessageCount: 0, unreadBroadcastMessageCount: 0)
        ..applyServerHint(noticeCount: null, hasPersonalMessage: null);
      await pumpEventQueue();

      expect(published.map((e) => (e.notice, e.personalMessage, e.broadcastMessage)), [(0, 0, 0)]);
    });

    test('an allowed notice hint still raises the badge by max as before', () async {
      infoRepository
        ..updateInfo(unreadNoticeCount: 1, unreadPersonalMessageCount: 0, unreadBroadcastMessageCount: 0)
        ..applyServerHint(noticeCount: 4, hasPersonalMessage: false);
      await pumpEventQueue();

      expect(published.last.notice, 4);
    });

    test('sync then header with blocked users: the hidden notice never reaches the badge', () async {
      await blockRepo.block(ownerUid: _alice.uid, uid: _troll, username: 'troll');
      final bloc = buildBloc();
      await deliver(bloc, _alice.uid!, _fetched([_notice(1, author: _troll), _notice(2, author: _bob)]));

      // The forum header counts both notices; what the homepage passes for the current block list: one guard for
      // both hints.
      final list = await blockRepo.load(_alice.uid);
      final allowHint = noticeHintAllowed(list, currentUid: _alice.uid);
      expect(allowHint, isFalse);
      const headerCount = 2;
      const headerHasUnreadMessage = true;
      infoRepository.applyServerHint(
        noticeCount: allowHint ? headerCount : null,
        hasPersonalMessage: allowHint ? headerHasUnreadMessage : null,
      );
      await pumpEventQueue();

      expect(published.last.notice, 1);
      expect(published.last.personalMessage, 1);
    });

    test('sync then header with a blocked peer: the muted conversation never reaches the badge', () async {
      await blockRepo.block(ownerUid: _alice.uid, uid: _troll, username: 'troll');
      final bloc = buildBloc();
      // The only unread conversation is with the blocked peer.
      await deliver(bloc, _alice.uid!, _fetched(const [], personalMessages: [_pm(_troll, 'troll')]));
      expect(published.last.personalMessage, 0);

      // The forum header flag is an aggregate: it is raised by the message of the blocked peer.
      final list = await blockRepo.load(_alice.uid);
      final allowHint = noticeHintAllowed(list, currentUid: _alice.uid);
      const headerHasUnreadMessage = true;
      infoRepository.applyServerHint(
        noticeCount: allowHint ? 0 : null,
        hasPersonalMessage: allowHint ? headerHasUnreadMessage : null,
      );
      await pumpEventQueue();

      expect(published.last.personalMessage, 0, reason: 'the header flag must not bring the muted conversation back');
      expect(bloc.state.personalMessageList.map((e) => (e.peerUid, e.alreadyRead)), [(_troll, false)]);

      // Once unblocked the list is known empty again: the hint is merged as before local blocking.
      await blockRepo.unblock(ownerUid: _alice.uid, uid: _troll);
      final unblocked = await blockRepo.load(_alice.uid);
      expect(noticeHintAllowed(unblocked, currentUid: _alice.uid), isTrue);
    });
  });
}
