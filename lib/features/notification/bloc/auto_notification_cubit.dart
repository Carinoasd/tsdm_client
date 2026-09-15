import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'auto_notification_cubit.mapper.dart';

part 'auto_notification_state.dart';

/// Cubit of auto notification feature.
///
/// This cubit takes control of automatically fetching notice from server,
/// update notice state.
///
/// This cubit only triggers automatic update of notification by calling global
/// [NotificationRepository], never handles the returned data .
/// For process on saving notice data in storage and merging fetched data with
/// current ones, see `NotificationBloc`. This is by design because here the
/// cubit SHOULD only be ca optional trigger of notification state update, all
/// data handling logic and presentation state update logic are implemented in
/// `NotificationBloc`.
///
/// Note that it's the pandora box when frequently fetching notification while
/// using the app, because many other actions will cause some unstable, or race
/// condition especially user account related features:
///
/// * Login, logout.
/// * User switching.
///
/// Now we try to solve the chaos by adding mutex and state flag.
final class AutoNotificationCubit extends Cubit<AutoNoticeState> with LoggerMixin {
  /// Constructor.
  AutoNotificationCubit({
    required AuthenticationRepository authenticationRepository,
    required NotificationRepository notificationRepository,
    required StorageProvider storageProvider,
    this.duration = Duration.zero,
  }) : _authenticationRepository = authenticationRepository,
       _notificationRepository = notificationRepository,
       _storageProvider = storageProvider,
       super(const AutoNoticeStateStopped());

  final AuthenticationRepository _authenticationRepository;
  final NotificationRepository _notificationRepository;
  final StorageProvider _storageProvider;

  /// Duration between auto fetch actions.
  Duration duration;

  /// Current time to tick.
  Duration _remainingTick = Duration.zero;

  /// Timer calculating fetch actions.
  Timer? _timer;

  /// Who holds the pause, one entry per [pause] reason.
  ///
  /// The login, the account switch and the sync of all accounts can overlap: the timer restarts only when the last
  /// holder calls [resume], so none of them can lift a pause another one still relies on.
  final _pauseReasons = <String>{};

  /// Check is fetching the task or not.
  ///
  /// Fetching means doing the fetch action, so other conflict actions shall waiting for the sync process till it
  /// finishes.
  bool get isPending => state is AutoNoticeStatePending;

  AsyncVoidEither _emitDataState(int uid) {
    return AsyncVoidEither(() async {
      debug('auto fetch finished with data');
      if (state case AutoNoticeStatePending(:final startedTime)) {
        // Code below is synced from _onRecordFetchTimeRequested in
        // NotificationBloc.
        //
        // NotificationBloc only exists in notice page so can not trigger actions
        // below by adding events to it.
        // Whole minute only: notification times have minute precision, so a message arriving later in the minute the
        // fetch started in is stamped with that minute and must still be inside the next window.
        final since = startedTime.truncateToMinute();
        debug('update last fetch notification time to started minute ${since.yyyyMMDDHHMMSS()}');
        await _storageProvider.updateLastFetchNoticeTime(uid, since).run();
      } else {
        // Unreachable.
        final now = DateTime.now();
        warning('update last fetch notification time to current time ${now.yyyyMMDDHHMMSS()}');
        warning('current state: $state');
        await _storageProvider.updateLastFetchNoticeTime(uid, now).run();
      }
      emit(AutoNoticeStateTicking(total: duration, remain: _remainingTick));
      return rightVoid();
    });
  }

  void _emitErrorState(AppException e) {
    error('auto fetch ended with error: $e');
    emit(const AutoNoticeStateStopped());
  }

  /// Do the auto fetch action when timeout.
  Future<void> _onTimeout() async {
    if (state is AutoNoticeStateStopped || state is AutoNoticeStatePaused) {
      // Do nothing if already stopped.
      // Not intend to happen because the timer is canceled when stop but check
      // to make sure of that.
      return;
    }

    debug('running auto fetch...');

    // Mark as pending data.
    emit(AutoNoticeStatePending(DateTime.now()));

    final uid = _authenticationRepository.currentUser?.uid;
    if (uid == null) {
      debug('skip auto fetch notice due to not-login state');
      return;
    }

    int? lastFetchTime;
    // TODO: More FP.
    final lastFetchTimeEither = await _storageProvider.fetchLastFetchNoticeTime(uid).run();
    if (lastFetchTimeEither.isRight()) {
      final t = lastFetchTimeEither.unwrap();
      if (t != null) {
        // Inclusive, see NotificationBloc: copies fetched again are reconciled, a later message in the same minute
        // would otherwise be missed.
        lastFetchTime = t.millisecondsSinceEpoch ~/ 1000;
      }
    }
    debug('auto fetch since $lastFetchTime');
    await _notificationRepository
        .fetchNotificationV2(uid: uid, timestamp: lastFetchTime)
        .andThen(() => _emitDataState(uid))
        .mapLeft(_emitErrorState)
        .run();
  }

  /// Start and schedule auto fetch actions.
  ///
  /// Will stop and restart if already running.
  ///
  /// Override the auto fetch action duration with parameter [duration].
  void start(Duration? duration) {
    // Do NOT start auto sync if duration is invalid.
    if (duration == null && this.duration.inSeconds < 30) {
      return;
    }
    info('start auto fetch with duration $duration');
    // Note that here is no check on whether already running a auto fetch action
    // because it's the callback to do the actual fetch job so changing duration
    // or timer here breaks nothing.
    _pauseReasons.clear();

    if (duration != null) {
      this.duration = duration;
      _remainingTick = duration;
    }

    if (_timer?.isActive ?? false) {
      _timer?.cancel();
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (state is AutoNoticeStatePending) {
        return;
      }
      _remainingTick -= const Duration(seconds: 1);
      emit(AutoNoticeStateTicking(total: this.duration, remain: _remainingTick));
      if (_remainingTick.inSeconds > 0) {
        return;
      }

      // Timeout, reset.
      _remainingTick = this.duration;
      await _onTimeout();
    });
  }

  /// Restart the ticking process.
  void restart() {
    if (state is! AutoNoticeStateTicking) {
      return;
    }
    stop();
    start(duration);
  }

  /// Stop the auto fetch scheduler.
  void stop() {
    info('stop auto fetch with duration $duration');
    _timer?.cancel();
    _timer = null;
    _remainingTick = Duration.zero;
    _pauseReasons.clear();
    emit(const AutoNoticeStateStopped());
  }

  /// Pause the auto fetch process if running.
  ///
  /// If not running, do nothing.
  ///
  /// Return `true` if the cubit is pending data. The caller shall only enter the critical section when return `false`.
  /// A pause taken while already paused by another [reason] is recorded too: the process resumes only when every
  /// holder has called [resume] with its own reason.
  bool pause(String reason) {
    if (state is AutoNoticeStatePending) {
      return true;
    }

    if (state case AutoNoticeStateTicking(:final total, :final remain)) {
      info('auto fetch paused at total=$total remain=$remain reason=$reason');
      _timer?.cancel();
      _timer = null;
      _pauseReasons.add(reason);
      emit(AutoNoticeStatePaused(total: total, remain: remain));
      return false;
    }

    if (state is AutoNoticeStatePaused) {
      _pauseReasons.add(reason);
      debug('auto fetch already paused, holders=$_pauseReasons reason=$reason');
    }

    return false;
  }

  /// Continue the paused fetch process.
  ///
  /// If not paused, do nothing. Stays paused while another [pause] reason is still held.
  void resume(String reason) {
    _pauseReasons.remove(reason);
    if (state case AutoNoticeStatePaused(:final total, :final remain)) {
      if (_pauseReasons.isNotEmpty) {
        debug('auto fetch stays paused, holders=$_pauseReasons reason=$reason');
        return;
      }
      info('auto fetch resumes with total=$total remain=$remain reason=$reason');
      _timer?.cancel();
      _timer = null;

      _remainingTick = remain;
      duration = total;

      _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
        _remainingTick -= const Duration(seconds: 1);
        emit(AutoNoticeStateTicking(total: duration, remain: _remainingTick));
        if (_remainingTick.inSeconds > 0) {
          return;
        }

        // Timeout, reset.
        _remainingTick = duration;
        await _onTimeout();
      });
    }
  }

  @override
  Future<void> close() async {
    _timer?.cancel();
    await super.close();
  }
}
