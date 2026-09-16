import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Brings what the Android background message service stored into the running app (#80).
///
/// The service writes to the shared database and then sends a `synced` event with the unread counts of the account
/// it synced. When that is the current account, the unread badge takes the counts and the notification page reloads
/// from storage, the same way the "sync all accounts" action refreshes the page. The state counts the events, for
/// tests.
final class BackgroundSyncBridgeCubit extends Cubit<int> with LoggerMixin {
  /// [events] is the service's `synced` stream; [currentUid] tells which account the app shows right now.
  BackgroundSyncBridgeCubit({
    required Stream<Map<String, dynamic>?> events,
    required NotificationBloc notificationBloc,
    required NotificationInfoRepository infoRepository,
    required int? Function() currentUid,
  }) : _events = events,
       _notificationBloc = notificationBloc,
       _infoRepository = infoRepository,
       _currentUid = currentUid,
       super(0);

  final Stream<Map<String, dynamic>?> _events;
  final NotificationBloc _notificationBloc;
  final NotificationInfoRepository _infoRepository;
  final int? Function() _currentUid;
  StreamSubscription<Map<String, dynamic>?>? _subscription;

  /// Start listening.
  void start() {
    _subscription ??= _events.listen(_onSynced, onError: handleRaw);
  }

  void _onSynced(Map<String, dynamic>? data) {
    final uid = data?['uid'];
    if (uid is! int || uid != _currentUid()) {
      debug('background sync of another account or unknown payload, ignore: uid=$uid');
      return;
    }
    final notice = data?['notice'];
    final personalMessage = data?['personalMessage'];
    final broadcastMessage = data?['broadcastMessage'];
    if (notice is int && personalMessage is int && broadcastMessage is int) {
      _infoRepository.updateInfo(
        unreadNoticeCount: notice,
        unreadPersonalMessageCount: personalMessage,
        unreadBroadcastMessageCount: broadcastMessage,
      );
    }
    debug('background sync stored rows for the current account, reload the notification page');
    _notificationBloc.add(NotificationReloadFromStorageRequested());
    emit(state + 1);
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    return super.close();
  }
}
