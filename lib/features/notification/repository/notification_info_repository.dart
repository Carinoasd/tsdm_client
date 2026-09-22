import 'dart:math' as math;

import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Whether the unread hints from a page header (the notice count and the personal message flag) may be merged into
/// the badge of account [currentUid] while the local block list is [blockList].
///
/// Only when the list is known to be empty for that account: the header count carries no authors and the personal
/// message flag is an aggregate that cannot tell the sender, so with users blocked, or a list still loading, failed
/// or of another account, they would bring hidden notices and muted conversations back into the badge until the next
/// full sync (which may be long or fail). The badge then keeps its filtered counts.
///
/// The owner must be exactly [currentUid]. A ready list without owner only passes for a guest ([currentUid] null),
/// where it hides nothing, as before local blocking existed. With an account logged in it is not that account's list
/// (not loaded yet, or left over from the guest session), so it says nothing about who the account blocked.
///
/// The name is kept from when only the notice count was guarded.
bool noticeHintAllowed(UserBlockList blockList, {required int? currentUid}) =>
    blockList.status == UserBlockListStatus.ready && blockList.uids.isEmpty && blockList.ownerUid == currentUid;

/// A small repository for notification state cubit.
///
/// Act like a bridge between `NotificationBloc` and `AutoNotificationBloc`. The
/// former one calculates the latest notification status info, and the latter
/// one stores the info calculated and provide to presentation layer.
final class NotificationInfoRepository with LoggerMixin {
  final _controller = BehaviorSubject<NotificationStateInfo>();
  final _autoSyncController = BehaviorSubject<NotificationAutoSyncInfo>();

  /// Stream of received notification info.
  Stream<NotificationStateInfo> get status => _controller.asBroadcastStream();

  /// Stream of incoming new notification to display as local notification.
  Stream<NotificationAutoSyncInfo> get autoSyncStatus => _autoSyncController.asBroadcastStream();

  /// Update notification state info.
  ///
  /// This function will construct and update a brand new info from parameters
  /// and override all existing state in state cubit.
  void updateInfo({
    required int unreadNoticeCount,
    required int unreadPersonalMessageCount,
    required int unreadBroadcastMessageCount,
  }) {
    _controller.add(
      NotificationStateInfo(
        notice: unreadNoticeCount,
        personalMessage: unreadPersonalMessageCount,
        broadcastMessage: unreadBroadcastMessageCount,
      ),
    );
  }

  /// Merge unread counts parsed from a page header (server truth) into the current unread info.
  ///
  /// The header only tells the unread notice count and whether unread personal messages exist, so values are
  /// merged by max: a hint can only raise the counts and never lowers what a completed notification sync produced.
  ///
  /// [noticeCount] null leaves the notice count as it is: the header count is a raw forum total without authors, so
  /// it must not be merged while the local block list may hide some notices (see [noticeHintAllowed]).
  ///
  /// [hasPersonalMessage] null leaves the personal message count as it is, for the same reason: the header flag is an
  /// aggregate that cannot identify the sender, so it must not be merged while the local block list may mute some
  /// conversations. The next sync recounts the conversations per peer.
  void applyServerHint({required int? noticeCount, required bool? hasPersonalMessage}) {
    final current = _controller.valueOrNull ?? NotificationStateInfo.empty;
    final merged = NotificationStateInfo(
      notice: noticeCount == null ? current.notice : math.max(current.notice, noticeCount),
      personalMessage: hasPersonalMessage == null
          ? current.personalMessage
          : math.max(current.personalMessage, hasPersonalMessage ? 1 : 0),
      broadcastMessage: current.broadcastMessage,
    );
    if (merged != current) {
      debug('apply server unread hint: notice=$noticeCount pm=$hasPersonalMessage -> $merged');
      _controller.add(merged);
    }
  }

  /// Update the latest received notice status in last auto sync notice action.
  ///
  /// Platform gate: Android and Windows both deliver local notifications when new
  /// notices arrive from the auto sync. Other desktop platforms (Linux / macOS)
  /// currently do not push local notifications, so they are skipped.
  void updateAutoSyncInfo(NotificationAutoSyncInfo info) {
    if (!isAndroid && !isWindows) {
      return;
    }
    // Counts only: the info carries the notice / message text shown in the push notification.
    debug(
      'update auto sync info: ${info.runtimeType} notice=${info.notice} pm=${info.personalMessage} '
      'bm=${info.broadcastMessage}',
    );
    _autoSyncController.add(info);
  }

  /// Dispose the repo.
  Future<void> dispose() async {
    await _controller.close();
    await _autoSyncController.close();
  }
}
