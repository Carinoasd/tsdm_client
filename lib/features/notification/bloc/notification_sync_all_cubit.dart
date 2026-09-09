import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'notification_sync_all_cubit.mapper.dart';
part 'notification_sync_all_state.dart';

/// Cubit driving the sync of the notifications of all accounts saved on this device.
///
/// Lives at the top of the app so leaving the progress page does not cancel the run. One run at a time; while it
/// runs the auto sync of the current user is paused with the same lock the account switch uses, so the current
/// account is not fetched twice concurrently.
///
/// After the run only the CURRENT user's unread counts are recounted from storage and published to the badge, through
/// [NotificationInfoRepository.updateInfo] (never the server hint, never another account's counts), and the
/// notification page is asked to rebuild its lists from storage without fetching again. Other accounts get no local
/// push notification: the push always opens the current user's notification page.
final class NotificationSyncAllCubit extends Cubit<NotificationSyncAllState> with LoggerMixin {
  /// Constructor.
  ///
  /// [autoNotificationCubit] and [notificationBloc] are optional so the cubit can run without the UI stack (tests).
  NotificationSyncAllCubit({
    required NotificationSyncAllRepository repository,
    required StorageProvider storageProvider,
    required AuthenticationRepository authenticationRepository,
    required NotificationInfoRepository infoRepository,
    AutoNotificationCubit? autoNotificationCubit,
    NotificationBloc? notificationBloc,
  }) : _repository = repository,
       _storageProvider = storageProvider,
       _authenticationRepository = authenticationRepository,
       _infoRepository = infoRepository,
       _autoNotificationCubit = autoNotificationCubit,
       _notificationBloc = notificationBloc,
       super(const NotificationSyncAllStateIdle()) {
    _stateSub = _repository.status.listen((info) {
      _lastInfo = info;
      // The last progress event may arrive after the finished state was emitted: never overwrite it.
      if (_running && !isClosed) {
        emit(NotificationSyncAllStateRunning(info));
      }
    });
  }

  final NotificationSyncAllRepository _repository;
  final StorageProvider _storageProvider;
  final AuthenticationRepository _authenticationRepository;
  final NotificationInfoRepository _infoRepository;
  final AutoNotificationCubit? _autoNotificationCubit;
  final NotificationBloc? _notificationBloc;

  late final StreamSubscription<NotificationSyncAllInfo> _stateSub;

  /// Reason passed to the auto sync lock.
  static const _lockReason = 'sync all accounts';

  /// How many times, and how long apart, the auto sync lock is tried before running anyway.
  static const _lockRetries = 10;
  static const _lockRetryGap = Duration(milliseconds: 300);

  var _running = false;

  /// Latest progress of the current run, the results so far when the run dies with an error.
  var _lastInfo = NotificationSyncAllInfo.empty();

  /// Whether a run is in progress.
  bool get isRunning => _running;

  /// Start syncing every account saved on this device.
  ///
  /// Ignored while a run is in progress.
  ///
  /// Always ends in [NotificationSyncAllStateFinished]: an error thrown by the run is logged and the accounts done
  /// so far are reported, so the sync button never stays disabled and the progress page never spins forever.
  Future<void> start() async {
    if (_running) {
      debug('sync all accounts already running, skipped');
      return;
    }
    _running = true;
    _lastInfo = NotificationSyncAllInfo.empty();
    emit(const NotificationSyncAllStatePreparing());
    try {
      await _pauseAutoSync();
      final accounts = (await _storageProvider.getAllUsers())
          .where((e) => e.uid != null && e.uid! > 0 && e.username != null && e.username!.isNotEmpty)
          .toList();
      info('sync all accounts: ${accounts.length} account(s)');
      var results = const <(UserLoginInfo, NotificationSyncResult)>[];
      if (accounts.isNotEmpty) {
        final finalInfo = await _repository.syncAll(accounts: accounts).run();
        results = finalInfo.fold((_) => _lastInfo.finished, (info) => info.finished);
        try {
          await _publishCurrentUser();
          // Anything thrown here must be reported, not escape the run.
          // ignore: avoid_catches_without_on_clauses
        } catch (e, st) {
          // A failed recount must not hide the finished run.
          error('publishing the current user after sync all failed: $e', e, st);
        }
      }
      _running = false;
      if (!isClosed) {
        emit(NotificationSyncAllStateFinished(results));
      }
      // Anything thrown here must be reported, not escape the run.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      error('sync all accounts failed: $e', e, st);
      _running = false;
      if (!isClosed) {
        emit(NotificationSyncAllStateFinished(_lastInfo.finished));
      }
    } finally {
      _running = false;
      _autoNotificationCubit?.resume(_lockReason);
    }
  }

  /// Pause the auto sync, waiting for a fetch in flight like the account switch does.
  ///
  /// Runs anyway when the lock is still held after [_lockRetries]: both paths store through the same reconcile and
  /// the rows are upserted, a duplicate fetch is the worst case.
  Future<void> _pauseAutoSync() async {
    final auto = _autoNotificationCubit;
    if (auto == null) {
      return;
    }
    var times = _lockRetries;
    while (auto.pause(_lockReason)) {
      times -= 1;
      if (times <= 0) {
        warning('auto sync lock still held, sync all accounts runs anyway');
        return;
      }
      debug('sync all accounts is waiting for auto sync lock... $times');
      await Future<void>.delayed(_lockRetryGap);
    }
  }

  /// Publish the current user's unread counts recounted from storage and let the notification page reload.
  ///
  /// The current user is read now, not when the run started: an account switch during the run must not publish the
  /// previous account's counts.
  Future<void> _publishCurrentUser() async {
    final uid = _authenticationRepository.currentUser?.uid;
    if (uid == null) {
      debug('skip publishing unread counts after sync all: no current user');
      return;
    }
    final unread = await countUnreadNotification(storage: _storageProvider, uid: uid);
    if (_authenticationRepository.currentUser?.uid != uid) {
      debug('skip publishing unread counts after sync all: current user changed');
      return;
    }
    _infoRepository.updateInfo(
      unreadNoticeCount: unread.notice,
      unreadPersonalMessageCount: unread.personalMessage,
      unreadBroadcastMessageCount: unread.broadcastMessage,
    );
    _notificationBloc?.add(NotificationReloadFromStorageRequested());
  }

  @override
  Future<void> close() async {
    await _stateSub.cancel();
    await _repository.dispose();
    return super.close();
  }
}
