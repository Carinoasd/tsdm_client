part of 'models.dart';

/// Base state of [NotificationV2] state.
@MappableClass()
sealed class NotificationInfoState with NotificationInfoStateMappable {
  /// Constructor.
  const NotificationInfoState();
}

/// Fetching notification.
@MappableClass()
final class NotificationInfoStateLoading extends NotificationInfoState with NotificationInfoStateLoadingMappable {
  /// Constructor.
  const NotificationInfoStateLoading();
}

/// Fetched notice successfully.
@MappableClass()
final class NotificationInfoStateSuccess extends NotificationInfoState with NotificationInfoStateSuccessMappable {
  /// Constructor.
  const NotificationInfoStateSuccess(this.uid, this.info, {this.since});

  /// User id of whom the fetch action on.
  final int uid;

  /// Fetched info.
  final NotificationV2 info;

  /// The inclusive lower bound (seconds) this fetch was asked for, null when this device had none stored yet.
  ///
  /// A notice fetched for the first time inside that window is news to this device whatever read flag the server
  /// rendered, see `reconcileNoticeReadState` (GitHub #79).
  final int? since;
}

/// Failed to fetch notification.
@MappableClass()
final class NotificationInfoStateFailure extends NotificationInfoState with NotificationInfoStateFailureMappable {
  /// Constructor.
  const NotificationInfoStateFailure();
}
