import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/notification_type.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// The unread badge follows what the user read: read state of fetched copies is reconciled with the stored ones,
/// marks always reach storage and the counts are recounted from storage afterwards.
///
/// Testers saw the badge stay on after reading a message and come back after re-listing.
const _uid = 1000;

PersonalMessageV2 _pm(int peer, int t, String data, {required bool read, bool sender = false}) => PersonalMessageV2(
  timestamp: t,
  data: data,
  peerUid: peer,
  peerUsername: 'peer$peer',
  sender: sender,
  alreadyRead: read,
);

PersonalMessageEntity _pmStored(int peer, int t, String data, {required bool read}) => PersonalMessageEntity(
  uid: _uid,
  timestamp: t,
  data: data,
  peerUid: peer,
  peerUsername: 'peer$peer',
  sender: false,
  alreadyRead: read,
);

BroadcastMessageV2 _bm(int pmid, int t, {bool read = false}) =>
    BroadcastMessageV2(timestamp: t, data: 'b$pmid', pmid: pmid, alreadyRead: read);

BroadcastMessageEntity _bmStored(int pmid, int t, {bool? read}) =>
    BroadcastMessageEntity(uid: _uid, timestamp: t, data: 'b$pmid', pmid: pmid, alreadyRead: read);

NoticeV2 _notice(int nid, int t, {bool read = false}) => NoticeV2(id: nid, timestamp: t, data: 'n$nid', alreadyRead: read);

NoticeEntity _noticeStored(int nid, int t, {bool? read}) =>
    NoticeEntity(uid: _uid, nid: nid, timestamp: t, data: 'n$nid', alreadyRead: read);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('reconcilePersonalMessageReadState', () {
    test('a conversation seen for the first time keeps the server flag', () {
      final r = reconcilePersonalMessageReadState(
        fetched: [_pm(1, 100, 'a', read: false), _pm(2, 100, 'b', read: true)],
        stored: [],
      );
      expect(r.map((e) => e.alreadyRead), [false, true]);
    });

    test('a newer copy or another last message is a new message and keeps the server flag', () {
      final r = reconcilePersonalMessageReadState(
        fetched: [_pm(1, 200, 'later', read: false), _pm(2, 100, 'changed', read: false)],
        stored: [_pmStored(1, 100, 'a', read: true), _pmStored(2, 100, 'b', read: true)],
      );
      expect(r.map((e) => e.alreadyRead), [false, false]);
    });

    test('the same copy is read when either side says so', () {
      final r = reconcilePersonalMessageReadState(
        fetched: [
          // Read in the app only, the server still shows the new marker.
          _pm(1, 100, 'a', read: false),
          // Read on the web, the app copy is still unread.
          _pm(2, 100, 'b', read: true),
          // Unread on both sides.
          _pm(3, 100, 'c', read: false),
        ],
        stored: [
          _pmStored(1, 100, 'a', read: true),
          _pmStored(2, 100, 'b', read: false),
          _pmStored(3, 100, 'c', read: false),
        ],
      );
      expect(r.map((e) => e.alreadyRead), [true, true, false]);
    });
  });

  group('reconcileBroadcastMessageReadState', () {
    test('a message seen for the first time is unread whatever the server rendered', () {
      final r = reconcileBroadcastMessageReadState(fetched: [_bm(1, 100, read: true), _bm(2, 100)], stored: []);
      expect(r.map((e) => e.alreadyRead), [false, false]);
    });

    test('a stored message keeps the local flag when listed again', () {
      final r = reconcileBroadcastMessageReadState(
        fetched: [_bm(1, 100), _bm(2, 100), _bm(3, 100)],
        stored: [_bmStored(1, 100, read: true), _bmStored(2, 100, read: false), _bmStored(3, 100)],
      );
      expect(r.map((e) => e.alreadyRead), [true, false, false]);
    });
  });

  group('freshNotifications', () {
    test('keeps only what is news to the user', () {
      final fresh = freshNotifications(
        fetched: NotificationV2(
          status: 0,
          noticeList: [_notice(1, 100), _notice(2, 200), _notice(3, 100)],
          personalMessageList: [
            _pm(1, 100, 'a', read: false),
            _pm(2, 200, 'later', read: false),
            _pm(3, 100, 'changed', read: false),
            _pm(4, 100, 'new peer', read: false),
            // The user's own reply is no news.
            _pm(5, 300, 'mine', read: true, sender: true),
          ],
          broadcastMessageList: [_bm(1, 100), _bm(2, 100)],
        ),
        stored: NotificationGroup(
          noticeList: [_noticeStored(1, 100, read: true), _noticeStored(2, 100, read: true)],
          personalMessageList: [
            _pmStored(1, 100, 'a', read: true),
            _pmStored(2, 100, 'a', read: true),
            _pmStored(3, 100, 'a', read: true),
          ],
          broadcastMessageList: [_bmStored(1, 100, read: true)],
        ),
      );
      expect(fresh.noticeList.map((e) => e.id), [2, 3]);
      expect(fresh.personalMessageList.map((e) => e.peerUid), [2, 3, 4]);
      expect(fresh.broadcastMessageList.map((e) => e.pmid), [2]);
    });
  });

  group('NotificationBloc', () {
    late AppDatabase db;
    late StorageProvider storage;
    late NotificationInfoRepository infoRepository;
    late NotificationBloc bloc;
    late List<NotificationStateInfo> published;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      infoRepository = NotificationInfoRepository();
      published = [];
      infoRepository.status.listen(published.add);
      bloc = NotificationBloc(
        notificationRepository: NotificationRepository(),
        infoRepository: infoRepository,
        authRepo: AuthenticationRepository(user: const UserLoginInfo(username: 'Alice', uid: _uid)),
        storageProvider: storage,
      );
      await storage
          .saveNotification(
            uid: _uid,
            notificationGroup: NotificationGroup(
              noticeList: [_noticeStored(7, 100, read: false), _noticeStored(8, 100, read: true)],
              personalMessageList: [_pmStored(2000, 100, 'hi', read: false), _pmStored(2001, 100, 'yo', read: false)],
              broadcastMessageList: [_bmStored(5, 100, read: true)],
            ),
          )
          .run();
    });

    tearDown(() async {
      await bloc.close();
      await db.close();
    });

    Future<NotificationStateInfo> counts() =>
        Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return published.isEmpty;
        }).then((_) => published.last).timeout(const Duration(seconds: 5));

    test('a mark for a conversation not in the state still reaches storage and recounts the badge', () async {
      // The state is empty: no sync ran yet, the chat page was opened from a profile.
      expect(bloc.state.personalMessageList, isEmpty);
      bloc.add(
        const NotificationMarkReadRequested(RecordMarkPersonalMessage(uid: _uid, peerUid: 2000, alreadyRead: true)),
      );
      final info = await counts();
      expect((info.notice, info.personalMessage, info.broadcastMessage), (1, 1, 0));
      final stored = await storage.fetchNotificationSince(uid: _uid, timestamp: 0).run();
      expect(stored.personalMessageList.singleWhere((e) => e.peerUid == 2000).alreadyRead, isTrue);
      expect(stored.personalMessageList.singleWhere((e) => e.peerUid == 2001).alreadyRead, isFalse);
    });

    test('marking a whole type read recounts the badge', () async {
      bloc.add(const NotificationMarkTypeReadRequested(markType: NotificationType.notice, markAsRead: true));
      final info = await counts();
      expect((info.notice, info.personalMessage, info.broadcastMessage), (0, 2, 0));
    });

    test('a sync reconciles read state with the stored copies and publishes the counts', () async {
      final fetched = NotificationV2(
          status: 0,
        noticeList: [
          // Listed again: the local flag stands.
          _notice(8, 100, read: true),
          // Newer copy of the unread one, still unread.
          _notice(7, 200),
          _notice(9, 300),
        ],
        personalMessageList: [
          // Read on the web meanwhile.
          _pm(2000, 100, 'hi', read: true),
          // Server marker still there, nothing new: stays as stored (unread).
          _pm(2001, 100, 'yo', read: false),
        ],
        // Read already, listed again with the server marker: must not become unread.
        broadcastMessageList: [_bm(5, 100), _bm(6, 400)],
      );
      final done = bloc.stream.firstWhere((s) => s.status == NotificationStatus.success);
      bloc.add(NotificationInfoFetched(NotificationInfoStateSuccess(_uid, fetched)));
      final state = await done.timeout(const Duration(seconds: 5));
      expect(state.noticeList.where((e) => !e.alreadyRead).map((e) => e.id), unorderedEquals([7, 9]));
      expect(state.personalMessageList.where((e) => !e.alreadyRead).map((e) => e.peerUid), [2001]);
      expect(state.broadcastMessageList.where((e) => !e.alreadyRead).map((e) => e.pmid), [6]);
      final info = await counts();
      expect((info.notice, info.personalMessage, info.broadcastMessage), (2, 1, 1));
      final stored = await storage.fetchNotificationSince(uid: _uid, timestamp: 0).run();
      expect(stored.broadcastMessageList.singleWhere((e) => e.pmid == 5).alreadyRead, isTrue);
      expect(stored.personalMessageList.singleWhere((e) => e.peerUid == 2000).alreadyRead, isTrue);
    });
  });
}
