import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// When the "N accounts have an expired login" hint is shown (issue #25), as a pure rule so it can be tested without
/// a database.
///
/// Feed every change of the set of expired accounts through [onExpired]:
///
/// * The first call is the app start: the hint is shown once when any stored account is expired.
/// * Later the hint is shown when the account in use is found expired and was not announced yet in this run.
/// * An account whose expiry was cleared (logged in again) is announced again when it expires again.
///
/// Other accounts expiring while the app runs are not announced here: the auto check-in and the sync of all accounts
/// report them in their own result pages, and the manage accounts page tells for every account.
final class SessionExpiryNotifier {
  bool _startupDone = false;
  final _announced = <int>{};

  /// Whether the start-up check ran.
  bool get startupDone => _startupDone;

  /// Uids announced so far and still expired.
  Set<int> get announced => Set.unmodifiable(_announced);

  /// The number of accounts to announce for [expiredUids], null when nothing is to be shown.
  int? onExpired(Set<int> expiredUids, {required int? currentUid}) {
    // Accounts logged in again may be announced again later.
    _announced.retainAll(expiredUids);
    if (!_startupDone) {
      _startupDone = true;
      _announced.addAll(expiredUids);
      return expiredUids.isEmpty ? null : expiredUids.length;
    }
    if (currentUid != null && expiredUids.contains(currentUid) && _announced.add(currentUid)) {
      return expiredUids.length;
    }
    return null;
  }
}

/// The accounts with an expired login and the hint to show about them.
final class SessionExpiryState extends Equatable {
  /// Constructor.
  const SessionExpiryState({this.expiredUids = const {}, this.noticeCount = 0, this.noticeSeq = 0});

  /// Uids of every stored account whose session is known to be expired.
  final Set<int> expiredUids;

  /// Accounts counted in the last hint.
  final int noticeCount;

  /// Grows by one for every hint to show; listeners react to its change.
  final int noticeSeq;

  /// Copy with.
  SessionExpiryState copyWith({Set<int>? expiredUids, int? noticeCount, int? noticeSeq}) => SessionExpiryState(
    expiredUids: expiredUids ?? this.expiredUids,
    noticeCount: noticeCount ?? this.noticeCount,
    noticeSeq: noticeSeq ?? this.noticeSeq,
  );

  @override
  List<Object?> get props => [expiredUids, noticeCount, noticeSeq];
}

/// Watches which stored accounts have an expired login (issue #25) and decides when to tell the user.
///
/// The expiry is a column of the cookie table written by whatever got the guest page with an account's cookie
/// (see `StorageProvider.markSessionExpired`), so this cubit only watches that column: at start, after
/// [startupDelay] so the scaffold showing the hint is there, and on every later change. The rule of what to announce
/// is [SessionExpiryNotifier].
final class SessionExpiryCubit extends Cubit<SessionExpiryState> with LoggerMixin {
  /// Constructor.
  ///
  /// [currentUid] tells the account in use when a change arrives.
  SessionExpiryCubit({
    required StorageProvider storageProvider,
    required int? Function() currentUid,
    this.startupDelay = const Duration(seconds: 2),
  }) : _storageProvider = storageProvider,
       _currentUid = currentUid,
       super(const SessionExpiryState());

  final StorageProvider _storageProvider;
  final int? Function() _currentUid;

  /// Wait before the first look at the stored accounts.
  final Duration startupDelay;

  final _notifier = SessionExpiryNotifier();
  StreamSubscription<Set<int>>? _sub;
  Timer? _startTimer;

  /// Start watching after [startupDelay]; does nothing when already started.
  void start() {
    if (_sub != null || _startTimer != null) {
      return;
    }
    if (startupDelay == Duration.zero) {
      _subscribe();
      return;
    }
    _startTimer = Timer(startupDelay, _subscribe);
  }

  void _subscribe() {
    _startTimer = null;
    if (isClosed) {
      return;
    }
    _sub = _storageProvider.watchExpiredSessionUids().listen(
      _onExpired,
      onError: (Object e, StackTrace st) => error('failed to watch expired sessions: $e', e, st),
    );
  }

  void _onExpired(Set<int> uids) {
    if (isClosed) {
      return;
    }
    final count = _notifier.onExpired(uids, currentUid: _currentUid());
    if (count == null) {
      emit(state.copyWith(expiredUids: uids));
      return;
    }
    info('$count account(s) with an expired login');
    emit(state.copyWith(expiredUids: uids, noticeCount: count, noticeSeq: state.noticeSeq + 1));
  }

  @override
  Future<void> close() async {
    _startTimer?.cancel();
    await _sub?.cancel();
    return super.close();
  }
}
