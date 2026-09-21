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
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
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

NotificationV2 _fetched(List<NoticeV2> notices) => NotificationV2(
  status: 0,
  noticeList: notices,
  personalMessageList: const [_unreadPm],
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

  NotificationBloc buildBloc() {
    final bloc = NotificationBloc(
      notificationRepository: NotificationRepository(storageProvider: storage),
      infoRepository: infoRepository,
      authRepo: AuthenticationRepository(user: _alice),
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
      expect(published.last.personalMessage, 1, reason: 'personal messages are never filtered');
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

  group('homepage header hint', () {
    test('only a known empty list of the current account allows the notice hint', () {
      final uid = _alice.uid;
      expect(noticeHintAllowed(UserBlockList.empty(uid), currentUid: uid), isTrue);
      // No block list provided / guest: behaves as before local blocking.
      expect(noticeHintAllowed(const UserBlockList.empty(null), currentUid: uid), isTrue);

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

      // The forum header counts both notices; what the homepage passes for the current block list.
      final list = await blockRepo.load(_alice.uid);
      const headerCount = 2;
      infoRepository.applyServerHint(
        noticeCount: noticeHintAllowed(list, currentUid: _alice.uid) ? headerCount : null,
        hasPersonalMessage: true,
      );
      await pumpEventQueue();

      expect(published.last.notice, 1);
      expect(published.last.personalMessage, 1);
    });
  });
}
