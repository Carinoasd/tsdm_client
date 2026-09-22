import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Holds the local block list of the current account and follows account switches.
///
/// State is always the list of exactly one owner: after a switch the state is "loading" for the new account (content
/// with an identified author is held back, see [UserBlockList.hides]) until its list is read, changes of other
/// accounts are ignored. A failed read keeps the last known list of the same account, or stays unknown ("failed"):
/// then the list is read again after each of [retryDelays], on the next auth event of the same account, and on
/// [reload].
final class UserBlockCubit extends Cubit<UserBlockList> with LoggerMixin {
  /// Constructor.
  ///
  /// [currentUid] returns the uid of the account this device acts as, it is read again on every [authStatus] event.
  ///
  /// [onListChanged] is called every time the known blocked uids of the current account differ from the last known
  /// ones, including the first time a list is known (so counts computed before are redone once on purpose).
  ///
  /// [retryDelays] are the waits before each automatic read after the list of the current account failed to load.
  UserBlockCubit({
    required UserBlockRepository repository,
    required int? Function() currentUid,
    required Stream<AuthStatus> authStatus,
    VoidCallback? onListChanged,
    this.retryDelays = defaultRetryDelays,
  }) : _repository = repository,
       _currentUid = currentUid,
       _onListChanged = onListChanged,
       super(const UserBlockList.unknown(null, status: UserBlockListStatus.loading)) {
    _authSub = authStatus.listen((_) => _follow(_currentUid()));
    _follow(_currentUid());
  }

  /// Default [retryDelays].
  ///
  /// A read fails rarely (the database stays busy, the row is damaged) and content of identified authors is held back
  /// until it works, so it is tried again on its own a few times, then left to the user and to auth events: a row
  /// that stays unreadable is not read again and again in the background.
  static const defaultRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 2),
  ];

  /// Waits before each automatic read after a failed one, see [defaultRetryDelays].
  final List<Duration> retryDelays;

  final UserBlockRepository _repository;
  final int? Function() _currentUid;
  final VoidCallback? _onListChanged;
  late final StreamSubscription<AuthStatus> _authSub;
  StreamSubscription<UserBlockList>? _listSub;
  int? _owner;
  bool _followed = false;

  /// Next automatic read of a list that failed to load, and how many of [retryDelays] were used.
  Timer? _retryTimer;
  int _retries = 0;

  /// Owner and uids of the last known list reported through [_onListChanged].
  (int?, Set<int>)? _reported;

  /// Uid of the account the actions of this cubit act for now.
  ///
  /// UI capturing this before an async step (a confirmation dialog) passes it back as `expectedOwner`, so a choice
  /// made for one account is never applied to another one.
  int? get owner => _owner;

  @override
  void emit(UserBlockList state) {
    if (isClosed) {
      return;
    }
    super.emit(state);
    if (state.isKnown) {
      final now = (state.ownerUid, state.uids);
      final last = _reported;
      if (last == null || last.$1 != now.$1 || !setEquals(last.$2, now.$2)) {
        _reported = now;
        _onListChanged?.call();
      }
    }
  }

  void _follow(int? owner) {
    if (_followed && owner == _owner) {
      // Same account (a login check, a relogin): a good moment to read a list that failed to load.
      if (state.status == UserBlockListStatus.failed) {
        _read(owner, showLoading: false);
      }
      return;
    }
    _followed = true;
    _owner = owner;
    _stopRetries();
    unawaited(_listSub?.cancel());
    _listSub = null;
    // Never show the list of the previous account, and never show content as "not blocked" before the list of the
    // new account is read.
    emit(
      owner == null || owner <= 0
          ? UserBlockList.empty(owner)
          : UserBlockList.unknown(owner, status: UserBlockListStatus.loading),
    );
    _listen(owner);
  }

  void _listen(int? owner) {
    _listSub = _repository
        .watch(owner)
        .listen(
          (list) {
            if (list.ownerUid == _owner) {
              _stopRetries();
              emit(list);
            }
          },
          onError: (Object e) {
            if (owner != _owner) {
              return;
            }
            error('failed to read the block list: $e');
            // Keep a list already known for this account; otherwise stay unknown and read it again later.
            if (!(state.ownerUid == owner && state.status == UserBlockListStatus.ready)) {
              if (state.ownerUid != owner || state.status != UserBlockListStatus.failed) {
                emit(UserBlockList.unknown(owner, status: UserBlockListStatus.failed));
              }
              _scheduleRetry(owner);
            }
          },
        );
  }

  void _scheduleRetry(int? owner) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (isClosed || _retries >= retryDelays.length) {
      return;
    }
    _retryTimer = Timer(retryDelays[_retries++], () {
      _retryTimer = null;
      if (!isClosed && owner == _owner && state.status == UserBlockListStatus.failed) {
        _read(owner, showLoading: false);
      }
    });
  }

  void _stopRetries() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retries = 0;
  }

  /// Read the list of the current account again, e.g. after a failure. The automatic retries start over.
  Future<void> reload() async {
    _stopRetries();
    _read(_owner, showLoading: true);
  }

  /// Read the list of [owner] again. [showLoading] turns a failed state into loading while it is read (a retry the
  /// user asked for); automatic retries stay "failed" until a read works.
  ///
  /// The previous subscription delivers nothing once cancelled, its cleanup is not waited for.
  void _read(int? owner, {required bool showLoading}) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (isClosed || owner != _owner) {
      return;
    }
    unawaited(_listSub?.cancel());
    _listSub = null;
    if (showLoading && state.status == UserBlockListStatus.failed) {
      emit(UserBlockList.unknown(owner, status: UserBlockListStatus.loading));
    }
    _listen(owner);
  }

  Future<UserBlockResult> _guarded(int? expectedOwner, Future<UserBlockResult> Function(int? owner) action) async {
    final owner = _owner;
    if (expectedOwner != owner) {
      return UserBlockResult.accountChanged;
    }
    try {
      return await action(owner);
    } on Object catch (e) {
      error('failed to change the block list: $e');
      return UserBlockResult.storageError;
    }
  }

  /// Block [uid] for the account [expectedOwner], only if that is still the current account.
  Future<UserBlockResult> block({required int uid, required String username, required int? expectedOwner}) =>
      _guarded(expectedOwner, (owner) => _repository.block(ownerUid: owner, uid: uid, username: username));

  /// Unblock [uid] for the account [expectedOwner], only if that is still the current account.
  Future<UserBlockResult> unblock(int uid, {required int? expectedOwner}) =>
      _guarded(expectedOwner, (owner) => _repository.unblock(ownerUid: owner, uid: uid));

  @override
  Future<void> close() async {
    _retryTimer?.cancel();
    await _authSub.cancel();
    await _listSub?.cancel();
    return super.close();
  }
}
