import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/notification_type.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

part 'notification_bloc.mapper.dart';
part 'notification_event.dart';
part 'notification_state.dart';

/// Read state of freshly [fetched] notices reconciled with the copies already [stored] for the same user.
///
/// * A notice seen for the first time keeps the flag the server rendered. Discuz! X5 shows the unread marker only
///   until the notice page is listed once, and our own fetch is that listing, so this is the only chance to read it.
/// * A notice already stored keeps the local flag (the user may have read it in the app meanwhile), unless the
///   server copy is newer: Discuz merges repeated replies in one thread into the same notice and bumps its time, so
///   a newer copy is a new event and becomes unread again.
List<NoticeV2> reconcileNoticeReadState({required List<NoticeV2> fetched, required List<NoticeEntity> stored}) {
  final byNid = {for (final e in stored) e.nid: e};
  return fetched.map((n) {
    final local = byNid[n.id];
    if (local == null) {
      return n;
    }
    if (n.timestamp > local.timestamp) {
      return n.copyWith(alreadyRead: false);
    }
    return n.copyWith(alreadyRead: local.alreadyRead ?? false);
  }).toList();
}

/// Read state of freshly [fetched] personal message conversations reconciled with the copies already [stored] for
/// the same user.
///
/// A conversation is one entry per peer holding its last message. The server flag is trustworthy: Discuz keeps the
/// "new" marker until the conversation is viewed on the server. But the user may have read it in the app only (the
/// notice card menu), so:
///
/// * A conversation seen for the first time keeps the server flag.
/// * A newer copy, or the same time with another last message, carries a new message and keeps the server flag.
/// * Otherwise the conversation is read when either side says so.
List<PersonalMessageV2> reconcilePersonalMessageReadState({
  required List<PersonalMessageV2> fetched,
  required List<PersonalMessageEntity> stored,
}) {
  final byPeer = {for (final e in stored) e.peerUid: e};
  return fetched.map((m) {
    final local = byPeer[m.peerUid];
    if (local == null || m.timestamp > local.timestamp || m.data != local.data) {
      return m;
    }
    return m.copyWith(alreadyRead: m.alreadyRead || local.alreadyRead);
  }).toList();
}

/// Read state of freshly [fetched] broadcast messages reconciled with the copies already [stored] for the same user.
///
/// A broadcast message never changes once sent: a message seen for the first time is unread, a stored one keeps the
/// local flag. Saving every fetched copy as unread, as done before, resurrected read messages whenever the last three
/// days were listed again.
List<BroadcastMessageV2> reconcileBroadcastMessageReadState({
  required List<BroadcastMessageV2> fetched,
  required List<BroadcastMessageEntity> stored,
}) {
  final byPmid = {for (final e in stored) e.pmid: e};
  return fetched.map((m) {
    final local = byPmid[m.pmid];
    if (local == null) {
      return m.copyWith(alreadyRead: false);
    }
    return m.copyWith(alreadyRead: local.alreadyRead ?? false);
  }).toList();
}

/// The part of [fetched] that is news to the user: not [stored] yet, or stored as an older copy (a notice merged with
/// a later reply, a conversation with another last message from the peer).
///
/// Only these feed the push notification of the background sync. Copies fetched again (the newest minute is fetched
/// once more on purpose, see [NotificationBloc]) and the user's own replies must not notify.
NotificationV2 freshNotifications({required NotificationV2 fetched, required NotificationGroup stored}) {
  final notices = {for (final e in stored.noticeList) e.nid: e};
  final conversations = {for (final e in stored.personalMessageList) e.peerUid: e};
  final broadcasts = {for (final e in stored.broadcastMessageList) e.pmid: e};
  return fetched.copyWith(
    noticeList: fetched.noticeList.where((n) {
      final local = notices[n.id];
      return local == null || n.timestamp > local.timestamp;
    }).toList(),
    personalMessageList: fetched.personalMessageList.where((m) {
      if (m.sender) {
        return false;
      }
      final local = conversations[m.peerUid];
      return local == null || m.timestamp > local.timestamp || m.data != local.data;
    }).toList(),
    broadcastMessageList: fetched.broadcastMessageList.where((m) => !broadcasts.containsKey(m.pmid)).toList(),
  );
}

/// Result of [persistFetchedNotification]: what was news in the fetched copies, the copies as stored (read state
/// reconciled) and the unread counts of the user recounted from storage after saving.
typedef PersistedNotification = ({NotificationV2 fresh, NotificationV2 reconciled, NotificationStateInfo unread});

/// Store the notifications [fetched] for user [uid] into [storage], reconciling their read state with the copies
/// already stored, and recount the user's unread notifications from storage afterwards.
///
/// This is the one place that turns a fetch result into stored rows: the current-user sync ([NotificationBloc]) and
/// the sync of all accounts (`NotificationSyncAllRepository`) both go through it so the two store identically.
///
/// * `fresh` is [freshNotifications] decided before the reconciled copies overwrite the stored ones: the items that
///   are news to the user.
/// * `reconciled` is [fetched] with the read state as saved.
/// * `unread` is the recount from storage, the same numbers the unread badge shows when [uid] is the current user.
///
/// Saving the server copies as they come resurrected items the user had read in the app: the last three days are
/// listed again when the last fetch is older than that, and the newest minute is fetched again on purpose. See
/// [reconcileNoticeReadState], [reconcilePersonalMessageReadState] and [reconcileBroadcastMessageReadState].
Future<PersistedNotification> persistFetchedNotification({
  required StorageProvider storage,
  required int uid,
  required NotificationV2 fetched,
}) async {
  final stored = await storage.fetchNotificationSince(uid: uid, timestamp: 0).run();
  final fresh = freshNotifications(fetched: fetched, stored: stored);
  final info = fetched.copyWith(
    noticeList: reconcileNoticeReadState(fetched: fetched.noticeList, stored: stored.noticeList),
    personalMessageList: reconcilePersonalMessageReadState(
      fetched: fetched.personalMessageList,
      stored: stored.personalMessageList,
    ),
    broadcastMessageList: reconcileBroadcastMessageReadState(
      fetched: fetched.broadcastMessageList,
      stored: stored.broadcastMessageList,
    ),
  );
  talker.debug(
    'saving notification: uid=${"$uid".obscured(4)} notice=${info.noticeList.length} '
    'personalMessage=${info.personalMessageList.length} '
    'broadcastMessage=${info.broadcastMessageList.length}',
  );
  await storage
      .saveNotification(
        uid: uid,
        notificationGroup: NotificationGroup(
          noticeList: info.noticeList
              .map(
                (e) => NoticeEntity(
                  uid: uid,
                  nid: e.id,
                  timestamp: e.timestamp,
                  data: e.data,
                  alreadyRead: e.alreadyRead,
                ),
              )
              .toList(),
          personalMessageList: info.personalMessageList
              .map(
                (e) => PersonalMessageEntity(
                  uid: uid,
                  timestamp: e.timestamp,
                  data: e.data,
                  peerUid: e.peerUid,
                  peerUsername: e.peerUsername,
                  sender: e.sender,
                  alreadyRead: e.alreadyRead,
                ),
              )
              .toList(),
          broadcastMessageList: info.broadcastMessageList
              .map(
                (e) => BroadcastMessageEntity(
                  uid: uid,
                  timestamp: e.timestamp,
                  data: e.data,
                  pmid: e.pmid,
                  alreadyRead: e.alreadyRead,
                ),
              )
              .toList(),
        ),
      )
      .run();
  return (fresh: fresh, reconciled: info, unread: await countUnreadNotification(storage: storage, uid: uid));
}

/// Recount the unread notifications of [uid] from [storage].
///
/// Storage is the source of truth of the unread badge; this is what `NotificationBloc` publishes for the current
/// user after every mark and every sync.
Future<NotificationStateInfo> countUnreadNotification({required StorageProvider storage, required int uid}) async {
  final group = await storage.fetchNotificationSince(uid: uid, timestamp: 0).run();
  return NotificationStateInfo(
    notice: group.noticeList.where((e) => !(e.alreadyRead ?? false)).length,
    personalMessage: group.personalMessageList.where((e) => !e.alreadyRead).length,
    broadcastMessage: group.broadcastMessageList.where((e) => !(e.alreadyRead ?? false)).length,
  );
}

/// Emitter
typedef _Emit = Emitter<NotificationState>;

/// Bloc of notification.
class NotificationBloc extends Bloc<NotificationEvent, NotificationState> with LoggerMixin {
  /// Constructor.
  NotificationBloc({
    required NotificationRepository notificationRepository,
    required NotificationInfoRepository infoRepository,
    required AuthenticationRepository authRepo,
    required StorageProvider storageProvider,
  }) : _notificationRepository = notificationRepository,
       _infoRepository = infoRepository,
       _authRepo = authRepo,
       _storageProvider = storageProvider,
       super(const NotificationState()) {
    on<NotificationEvent>(
      (e, emit) => switch (e) {
        NotificationUpdateAllRequested() => _onUpdateAllRequested(emit),
        NotificationReloadFromStorageRequested() => _onReloadFromStorageRequested(emit),
        NotificationRecordFetchTimeRequested(:final time) => _onRecordFetchTimeRequested(time),
        NotificationMarkReadRequested(:final recordMark) => _onMarkReadRequested(emit, recordMark),
        NotificationInfoFetched(:final info) => _onNoticeInfoFetched(emit, info),
        NotificationMarkTypeReadRequested(:final markAsRead, :final markType) => _onMarkTypeReadRequested(
          emit,
          markType,
          markAsRead: markAsRead,
        ),
        NotificationDeleteNoticeRequested(:final uid, :final nid) => _onDeleteNotice(emit, uid: uid, nid: nid),
        NotificationDeletePersonalMessageRequested(:final uid, :final peerUid) => _onDeletePersonalMessage(
          emit,
          uid: uid,
          peerUid: peerUid,
        ),
        NotificationDeleteBroadcastMessageRequested(:final uid, :final pmid) => _onDeleteBroadcastMessage(
          emit,
          uid: uid,
          pmid: pmid,
        ),
      },
    );

    _notificationRepository.status.listen((info) => add(NotificationInfoFetched(info)));
  }

  final NotificationRepository _notificationRepository;
  final NotificationInfoRepository _infoRepository;
  final AuthenticationRepository _authRepo;
  final StorageProvider _storageProvider;

  Future<void> _onUpdateAllRequested(_Emit emit) async {
    if (state.status == NotificationStatus.loading) {
      debug('update all notifications, skipped because already loading one');
      return;
    }
    debug('updating all notifications...');

    emit(state.copyWith(status: NotificationStatus.loading));
    final uid = _authRepo.currentUser?.uid;
    if (uid == null) {
      info('skip request of update notification: uid is null, not authorized');
      return;
    }
    final lastFetchTimeEither = await _storageProvider.fetchLastFetchNoticeTime(uid).run();
    int? timestamp;
    if (lastFetchTimeEither.isRight()) {
      final datetime = lastFetchTimeEither.unwrap();
      if (datetime != null) {
        // Inclusive bound: notification times carry minute precision only, so a message arriving later in the same
        // minute as the newest one fetched last time is stamped with that very minute and an exclusive bound would
        // never fetch it. Copies fetched twice are reconciled with the stored ones, not duplicated.
        timestamp = datetime.millisecondsSinceEpoch ~/ 1000;
      }
      debug('fetch notification since ${datetime?.yyyyMMDDHHMMSS()}');
    } else {
      debug('fetch notification with default duration');
    }

    // The final state will be triggered inside repository, do NOT manually
    // update here.
    await _notificationRepository.fetchNotificationV2(uid: uid, timestamp: timestamp).run();
  }

  Future<void> _onNoticeInfoFetched(_Emit emit, NotificationInfoState infoState) async {
    late NotificationV2 info;
    late final int uid;
    switch (infoState) {
      case NotificationInfoStateFailure():
        emit(state.copyWith(status: NotificationStatus.failure));
        // The badge may still hold the header hint of the homepage: fall back to what is stored so the hint does not
        // outlive a failed sync.
        final currentUid = _authRepo.currentUser?.uid;
        if (currentUid != null) {
          await _publishUnreadCounts(currentUid);
        }
        return;
      case NotificationInfoStateLoading():
        emit(state.copyWith(status: NotificationStatus.loading));
        return;
      case NotificationInfoStateSuccess(uid: final u, info: final i):
        info = i;
        uid = u;
    }

    emit(state.copyWith(status: NotificationStatus.loading));

    final latestMessageTime = info.latestTimestamp();

    // Store and reconcile through the shared helper, the same path the sync of all accounts uses.
    final persisted = await persistFetchedNotification(storage: _storageProvider, uid: uid, fetched: info);
    // What is actually news, and the copies as stored.
    final fresh = persisted.fresh;
    info = persisted.reconciled;

    final currentUid = _authRepo.currentUser?.uid;
    if (currentUid != uid) {
      debug('Async gap meets uid changes, do NOT update state.');
      return;
    }

    // Load local notice cache.
    // Here fetch all cached notice, no matter what time is it when last fetch
    // notice happened.
    final localNoticeData = await _storageProvider.fetchNotificationSince(uid: uid, timestamp: 0).run();
    debug(
      'load local notification: '
      'notice=${localNoticeData.noticeList.length} '
      'personalMessage=${localNoticeData.personalMessageList.length} '
      'broadcastMessage=${localNoticeData.broadcastMessageList.length}',
    );

    // Filter all outdated messages.
    localNoticeData.personalMessageList.removeWhere(
      (x) => x.uid == uid && info.personalMessageList.any((y) => y.peerUid == x.peerUid),
    );

    // Filter all duplicate messages.
    localNoticeData.noticeList.removeWhere((x) => info.noticeList.any((y) => x.uid == uid && x.nid == y.id));
    localNoticeData.broadcastMessageList.removeWhere(
      (x) => info.broadcastMessageList.any((y) => x.uid == uid && x.pmid == y.pmid),
    );

    // Here simply prepend fetching notification a front of all current
    // messages.
    //
    // This works because:
    //
    // * If user already fetched notice before, the new coming notice are only
    //   the ones generated after last fetch notice time, so notice in response
    //   are only the ones that never fetched before.
    // * If user haven't fetched notice on this machine before, current state
    //   holds nothing.
    //
    // It is expected that all local notice is older than server ones.
    // TODO: Sort notice by timestamp.

    final allNotice = [
      ...info.noticeList,
      ...localNoticeData.noticeList.map(
        (e) => NoticeV2(id: e.nid, timestamp: e.timestamp, data: e.data, alreadyRead: e.alreadyRead ?? false),
      ),
    ];
    final allPersonalMessage = [
      ...info.personalMessageList,
      ...localNoticeData.personalMessageList.map(
        (e) => PersonalMessageV2(
          timestamp: e.timestamp,
          data: e.data,
          peerUid: e.peerUid,
          peerUsername: e.peerUsername,
          sender: e.sender,
          alreadyRead: e.alreadyRead,
        ),
      ),
    ];
    final allBroadcastMessage = [
      ...info.broadcastMessageList,
      ...localNoticeData.broadcastMessageList.map(
        (e) =>
            BroadcastMessageV2(timestamp: e.timestamp, data: e.data, pmid: e.pmid, alreadyRead: e.alreadyRead ?? false),
      ),
    ];

    // Post the latest unread notification info to global state cubit.
    _infoRepository.updateInfo(
      unreadNoticeCount: allNotice.where((e) => !e.alreadyRead).length,
      unreadPersonalMessageCount: allPersonalMessage.where((e) => !e.alreadyRead).length,
      unreadBroadcastMessageCount: allBroadcastMessage.where((e) => !e.alreadyRead).length,
    );

    // Post the latest sync result in the action to global auto sync info state
    // cubit.
    //
    // Here the state posted only including ones received from server in this
    // sync action that are news to the user, not former ones, local storage
    // ones or copies fetched again.
    //
    // MARK: flnp
    if (fresh.personalMessageList.isNotEmpty) {
      _infoRepository.updateAutoSyncInfo(
        NotificationAutoSyncInfoPm(
          user: fresh.personalMessageList.last.peerUsername,
          msg: fresh.personalMessageList.last.data.truncate(40, ellipsis: true),
          notice: fresh.noticeList.length,
          personalMessage: fresh.personalMessageList.length,
          broadcastMessage: fresh.broadcastMessageList.length,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } else if (fresh.broadcastMessageList.isNotEmpty) {
      _infoRepository.updateAutoSyncInfo(
        NotificationAutoSyncInfoBm(
          msg: fresh.broadcastMessageList.last.data.truncate(40, ellipsis: true),
          notice: fresh.noticeList.length,
          personalMessage: fresh.personalMessageList.length,
          broadcastMessage: fresh.broadcastMessageList.length,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } else if (fresh.noticeList.isNotEmpty) {
      _infoRepository.updateAutoSyncInfo(
        NotificationAutoSyncInfoNotice(
          msg: parseHtmlDocument(fresh.noticeList.last.data).body?.innerText.truncate(40, ellipsis: true) ?? '<null>',
          notice: fresh.noticeList.length,
          personalMessage: fresh.personalMessageList.length,
          broadcastMessage: fresh.broadcastMessageList.length,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }

    emit(
      state.copyWith(
        status: NotificationStatus.success,
        noticeList: allNotice,
        personalMessageList: allPersonalMessage,
        broadcastMessageList: allBroadcastMessage,
        latestTime: latestMessageTime,
      ),
    );
  }

  Future<void> _onMarkTypeReadRequested(_Emit emit, NotificationType markType, {required bool markAsRead}) async {
    final uid = _authRepo.currentUser?.uid;
    if (uid == null) {
      error('intend to mark all notice for user but uid not found');
      return;
    }

    emit(state.copyWith(status: NotificationStatus.loading));

    await _storageProvider.markTypeAsRead(notificationType: markType, uid: uid, alreadyRead: markAsRead).run();
    await _publishUnreadCounts(uid);

    switch (markType) {
      case NotificationType.notice:
        final list = state.noticeList.map((e) => e.copyWith(alreadyRead: markAsRead)).toList();
        emit(state.copyWith(status: NotificationStatus.success, noticeList: list));
      case NotificationType.personalMessage:
        final list = state.personalMessageList.map((e) => e.copyWith(alreadyRead: markAsRead)).toList();
        emit(state.copyWith(status: NotificationStatus.success, personalMessageList: list));
      case NotificationType.broadcastMessage:
        final list = state.broadcastMessageList.map((e) => e.copyWith(alreadyRead: markAsRead)).toList();
        emit(state.copyWith(status: NotificationStatus.success, broadcastMessageList: list));
    }
  }

  Future<void> _onRecordFetchTimeRequested(DateTime time) async {
    if (time.year < 2025) {
      warning('not going to record fetch time as we are in 2025, at least');
      return;
    }

    final uid = _authRepo.currentUser?.uid;
    if (uid == null) {
      error('failed to update last fetch notice time: uid not found');
      return;
    }
    // Never move the time backwards: the state keeps the latest message time of an earlier fetch and publishes it
    // again on every success (reload from storage, mark as read), while the auto sync and the sync of all accounts
    // have already moved the time to the minute their fetch started in. A fetched message is never older than the
    // inclusive bound it was fetched since, so a record from a real fetch is never skipped here.
    final stored = (await _storageProvider.fetchLastFetchNoticeTime(uid).run()).getOrElse((_) => null);
    if (stored != null && !time.isAfter(stored)) {
      debug('keep last fetch notification time ${stored.yyyyMMDDHHMMSS()}, ${time.yyyyMMDDHHMMSS()} is not later');
      return;
    }
    debug('update last fetch notification time to ${time.yyyyMMDDHHMMSS()}');
    await _storageProvider.updateLastFetchNoticeTime(uid, time).run();
  }

  /// The event handler of marking some kind of notice as read or unread.
  ///
  /// The mark is always written to storage, the source of truth for the unread badge, even when the item is not in
  /// the current state: the state is empty until a sync succeeded, while a conversation can be opened from a profile
  /// or a friend card at any time. The state copy, when there is one, is updated in place for the list on screen and
  /// the unread counts are recounted from storage afterwards, see [_publishUnreadCounts].
  Future<void> _onMarkReadRequested(_Emit emit, RecordMark recordMark) async {
    debug('mark notice: $recordMark');
    final int uid;
    final AsyncVoidEither task;
    switch (recordMark) {
      case RecordMarkNotice(uid: final u, :final nid, alreadyRead: final read):
        uid = u;
        final list = state.noticeList.toList();
        final targetIndex = list.indexWhere((e) => e.id == nid);
        if (targetIndex >= 0) {
          list[targetIndex] = list[targetIndex].copyWith(alreadyRead: read);
          emit(state.copyWith(noticeList: list));
        }
        task = _storageProvider.markNoticeAsRead(uid: uid, nid: nid, read: read);
      case RecordMarkPersonalMessage(uid: final u, :final peerUid, alreadyRead: final read):
        uid = u;
        final list = state.personalMessageList.toList();
        final targetIndex = list.indexWhere((e) => e.peerUid == peerUid);
        if (targetIndex >= 0) {
          list[targetIndex] = list[targetIndex].copyWith(alreadyRead: read);
          emit(state.copyWith(personalMessageList: list));
        }
        task = _storageProvider.markPersonalMessageAsRead(uid: uid, peerUid: peerUid, read: read);
      case RecordMarkBroadcastMessage(uid: final u, :final timestamp, alreadyRead: final read):
        uid = u;
        final list = state.broadcastMessageList.toList();
        final targetIndex = list.indexWhere((e) => e.timestamp == timestamp);
        if (targetIndex >= 0) {
          list[targetIndex] = list[targetIndex].copyWith(alreadyRead: read);
          emit(state.copyWith(broadcastMessageList: list));
        }
        task = _storageProvider.markBroadcastMessageAsRead(uid: uid, timestamp: timestamp, read: read);
    }
    await task.run();
    await _publishUnreadCounts(uid);
  }

  /// Recount the unread notifications of [uid] from storage and publish them to the global unread state.
  ///
  /// Cards adjust the badge by one for instant feedback, which drifts (a card tapped twice, a mark that never
  /// reached storage); the recount makes the badge follow what the notification page lists. Skipped when [uid] is no
  /// longer the current user.
  Future<void> _publishUnreadCounts(int uid) async {
    if (_authRepo.currentUser?.uid != uid) {
      debug('skip publishing unread counts: not the current user');
      return;
    }
    final unread = await countUnreadNotification(storage: _storageProvider, uid: uid);
    _infoRepository.updateInfo(
      unreadNoticeCount: unread.notice,
      unreadPersonalMessageCount: unread.personalMessage,
      unreadBroadcastMessageCount: unread.broadcastMessage,
    );
  }

  /// Rebuild the lists in state from what is stored for the current user, without a network fetch.
  ///
  /// Used after the sync of all accounts wrote the current user's rows through [persistFetchedNotification]: the page
  /// then lists them right away instead of on its next pull-to-refresh. Skipped while a fetch is in flight, its result
  /// rebuilds the lists anyway.
  Future<void> _onReloadFromStorageRequested(_Emit emit) async {
    if (state.status == NotificationStatus.loading) {
      debug('reload notification from storage, skipped because already loading');
      return;
    }
    final uid = _authRepo.currentUser?.uid;
    if (uid == null) {
      debug('skip reload notification from storage: uid is null, not authorized');
      return;
    }
    final group = await _storageProvider.fetchNotificationSince(uid: uid, timestamp: 0).run();
    if (_authRepo.currentUser?.uid != uid) {
      debug('Async gap meets uid changes, do NOT update state.');
      return;
    }
    final noticeList = group.noticeList
        .map((e) => NoticeV2(id: e.nid, timestamp: e.timestamp, data: e.data, alreadyRead: e.alreadyRead ?? false))
        .toList();
    final personalMessageList = group.personalMessageList
        .map(
          (e) => PersonalMessageV2(
            timestamp: e.timestamp,
            data: e.data,
            peerUid: e.peerUid,
            peerUsername: e.peerUsername,
            sender: e.sender,
            alreadyRead: e.alreadyRead,
          ),
        )
        .toList();
    final broadcastMessageList = group.broadcastMessageList
        .map(
          (e) => BroadcastMessageV2(
            timestamp: e.timestamp,
            data: e.data,
            pmid: e.pmid,
            alreadyRead: e.alreadyRead ?? false,
          ),
        )
        .toList();
    debug(
      'reload notification from storage: notice=${noticeList.length} personalMessage=${personalMessageList.length} '
      'broadcastMessage=${broadcastMessageList.length}',
    );
    emit(
      state.copyWith(
        status: NotificationStatus.success,
        noticeList: noticeList,
        personalMessageList: personalMessageList,
        broadcastMessageList: broadcastMessageList,
      ),
    );
  }

  Future<void> _onDeleteNotice(_Emit emit, {required int uid, required int nid}) async {
    emit(state.copyWith(noticeList: state.noticeList.toList()..removeWhere((e) => e.id == nid)));
    await _storageProvider.deleteNotice(uid: uid, nid: nid).run();
  }

  Future<void> _onDeletePersonalMessage(_Emit emit, {required int uid, required int peerUid}) async {
    emit(
      state.copyWith(personalMessageList: state.personalMessageList.toList()..removeWhere((e) => e.peerUid == peerUid)),
    );
    await _storageProvider.deletePersonalMessage(uid: uid, peerUid: peerUid).run();
  }

  Future<void> _onDeleteBroadcastMessage(_Emit emit, {required int uid, required int pmid}) async {
    emit(state.copyWith(broadcastMessageList: state.broadcastMessageList.toList()..removeWhere((e) => e.pmid == pmid)));
    await _storageProvider.deleteBroadcastMessage(uid: uid, pmid: pmid).run();
  }

  /// Do NOT dispose [_infoRepository] here because the state cubit owns it.
  @override
  Future<void> close() async {
    await _notificationRepository.dispose();
    return super.close();
  }
}
