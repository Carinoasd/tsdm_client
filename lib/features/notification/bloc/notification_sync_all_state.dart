part of 'notification_sync_all_cubit.dart';

/// State of the sync of all accounts.
@MappableClass()
sealed class NotificationSyncAllState with NotificationSyncAllStateMappable {
  /// Constructor.
  const NotificationSyncAllState();
}

/// Nothing ran yet.
@MappableClass()
final class NotificationSyncAllStateIdle extends NotificationSyncAllState with NotificationSyncAllStateIdleMappable {
  /// Constructor.
  const NotificationSyncAllStateIdle();
}

/// Waiting for the auto sync lock and listing the accounts.
@MappableClass()
final class NotificationSyncAllStatePreparing extends NotificationSyncAllState
    with NotificationSyncAllStatePreparingMappable {
  /// Constructor.
  const NotificationSyncAllStatePreparing();
}

/// Accounts are being synced.
@MappableClass()
final class NotificationSyncAllStateRunning extends NotificationSyncAllState
    with NotificationSyncAllStateRunningMappable {
  /// Constructor.
  const NotificationSyncAllStateRunning(this.info);

  /// Current progress.
  final NotificationSyncAllInfo info;
}

/// Every account is done.
///
/// Kept so the result page can be opened later from the snack bar.
@MappableClass()
final class NotificationSyncAllStateFinished extends NotificationSyncAllState
    with NotificationSyncAllStateFinishedMappable {
  /// Constructor.
  const NotificationSyncAllStateFinished(this.results);

  /// Result of every account, in the order they ran.
  final List<(UserLoginInfo, NotificationSyncResult)> results;
}
