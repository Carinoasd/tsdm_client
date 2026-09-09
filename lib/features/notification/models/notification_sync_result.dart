part of 'models.dart';

/// Result of syncing the notifications of one account in the sync of all accounts.
@MappableClass()
sealed class NotificationSyncResult with NotificationSyncResultMappable {
  /// Constructor.
  const NotificationSyncResult();
}

/// The account was fetched and stored.
@MappableClass()
final class NotificationSyncResultSuccess extends NotificationSyncResult with NotificationSyncResultSuccessMappable {
  /// Constructor.
  const NotificationSyncResultSuccess({
    required this.newNotice,
    required this.newPersonalMessage,
    required this.newBroadcastMessage,
    required this.unreadNotice,
    required this.unreadPersonalMessage,
    required this.unreadBroadcastMessage,
  });

  /// Notices that are news to the account (not stored before, or a newer copy).
  final int newNotice;

  /// Personal message conversations with a new message from the peer.
  final int newPersonalMessage;

  /// Broadcast messages not stored before.
  final int newBroadcastMessage;

  /// Unread notices of the account, recounted from storage after saving.
  final int unreadNotice;

  /// Unread personal message conversations of the account, recounted from storage after saving.
  final int unreadPersonalMessage;

  /// Unread broadcast messages of the account, recounted from storage after saving.
  final int unreadBroadcastMessage;
}

/// The stored cookie of the account is gone or expired: the server answered the guest page.
@MappableClass()
final class NotificationSyncResultNotAuthorized extends NotificationSyncResult
    with NotificationSyncResultNotAuthorizedMappable {
  /// Constructor.
  const NotificationSyncResultNotAuthorized();
}

/// The server rate-limited the requests (HTTP 429), also after the one retry.
@MappableClass()
final class NotificationSyncResultRateLimited extends NotificationSyncResult
    with NotificationSyncResultRateLimitedMappable {
  /// Constructor.
  const NotificationSyncResultRateLimited();
}

/// The fetch failed for another reason.
@MappableClass()
final class NotificationSyncResultFailed extends NotificationSyncResult with NotificationSyncResultFailedMappable {
  /// Constructor.
  const NotificationSyncResultFailed(this.message);

  /// What went wrong, for the result page.
  final String message;
}

/// Progress of the sync of all accounts, shaped like the auto check-in progress.
@MappableClass()
final class NotificationSyncAllInfo with NotificationSyncAllInfoMappable {
  /// Constructor.
  const NotificationSyncAllInfo({required this.waiting, required this.running, required this.finished});

  /// Construct an instance with empty data.
  factory NotificationSyncAllInfo.empty() => const NotificationSyncAllInfo(waiting: [], running: [], finished: []);

  /// Accounts not started yet.
  final List<UserLoginInfo> waiting;

  /// The account being fetched, at most one at a time.
  final List<UserLoginInfo> running;

  /// Accounts done, with their result, in the order they ran.
  final List<(UserLoginInfo, NotificationSyncResult)> finished;

  /// Whether every account is done.
  bool get isDone => waiting.isEmpty && running.isEmpty;
}
