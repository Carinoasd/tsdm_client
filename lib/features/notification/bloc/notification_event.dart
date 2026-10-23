part of 'notification_bloc.dart';

/// Event of notification.
@MappableClass()
sealed class NotificationEvent with NotificationEventMappable {
  const NotificationEvent();
}

/// Required to refresh all kinds of notification.
@MappableClass()
final class NotificationUpdateAllRequested extends NotificationEvent with NotificationUpdateAllRequestedMappable {
  /// Constructor.
  const NotificationUpdateAllRequested({this.bypassGate = false, this.forUid});

  /// Fetch the pages without asking the forum's app API first, keeping every conversation of the private message
  /// page: a refresh the user asked for, or the one after a private message was sent (GitHub #193). The automatic
  /// syncs leave it off.
  final bool bypassGate;

  /// Only for this account: skipped when another one is current by the time it runs, or an account switch is
  /// running. The refresh after a private message was sent is for the account that sent it. Null for the current one.
  final int? forUid;
}

/// Rebuild the lists from what is stored for the current user, without fetching.
///
/// Sent when another path wrote the current user's rows (the sync of all accounts).
@MappableClass()
final class NotificationReloadFromStorageRequested extends NotificationEvent
    with NotificationReloadFromStorageRequestedMappable {}

/// Need to update the last fetch notification timestamp for current user in
/// storage.
@MappableClass()
final class NotificationRecordFetchTimeRequested extends NotificationEvent
    with NotificationRecordFetchTimeRequestedMappable {
  /// Constructor.
  const NotificationRecordFetchTimeRequested(this.time);

  /// The timestamp of latest notice.
  final DateTime time;
}

/// Mark a message as read.
@MappableClass()
final class NotificationMarkReadRequested extends NotificationEvent with NotificationMarkReadRequestedMappable {
  /// Constructor.
  const NotificationMarkReadRequested(this.recordMark);

  /// Purpose of this event.
  final RecordMark recordMark;
}

/// Mark all message of type as read.
@MappableClass()
final class NotificationMarkTypeReadRequested extends NotificationEvent with NotificationMarkTypeReadRequestedMappable {
  /// Constructor.
  const NotificationMarkTypeReadRequested({required this.markType, required this.markAsRead});

  /// Purpose of this event.
  final NotificationType markType;

  /// Flag indicating mark as read or unread.
  final bool markAsRead;
}

/// Mark every notice, personal message and broadcast message of the current user as read at once: the "mark all as
/// read" of the notification page, one storage write and one state update for the three kinds.
@MappableClass()
final class NotificationMarkAllReadRequested extends NotificationEvent with NotificationMarkAllReadRequestedMappable {
  /// Constructor.
  const NotificationMarkAllReadRequested({this.done});

  /// Completed once the marks are written (true), or with false when nothing was written (no account) or the write
  /// failed: the page says "done" or "failed" only then.
  final Completer<bool>? done;
}

/// Internal event.
///
/// Repository has fetched new info from server.
@MappableClass()
final class NotificationInfoFetched extends NotificationEvent with NotificationInfoFetchedMappable {
  /// Constructor.
  const NotificationInfoFetched(this.info);

  /// Latest fetched info.
  final NotificationInfoState info;
}

/// Delete notice.
@MappableClass()
final class NotificationDeleteNoticeRequested extends NotificationEvent with NotificationDeleteNoticeRequestedMappable {
  /// Constructor.
  const NotificationDeleteNoticeRequested({required this.uid, required this.nid});

  /// Uid of the notice.
  final int uid;

  /// Notice id.
  final int nid;
}

/// Delete personal message.
@MappableClass()
final class NotificationDeletePersonalMessageRequested extends NotificationEvent
    with NotificationDeletePersonalMessageRequestedMappable {
  /// Constructor.
  const NotificationDeletePersonalMessageRequested({required this.uid, required this.peerUid});

  /// Uid of current user.
  final int uid;

  /// Uid of user chat with.
  final int peerUid;
}

/// Delete broadcast message.
@MappableClass()
final class NotificationDeleteBroadcastMessageRequested extends NotificationEvent
    with NotificationDeleteBroadcastMessageRequestedMappable {
  /// Constructor.
  const NotificationDeleteBroadcastMessageRequested({required this.uid, required this.pmid});

  /// Uid of current user.
  final int uid;

  /// Id of broadcast message.
  final int pmid;
}
