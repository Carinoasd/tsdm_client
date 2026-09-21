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
/// accounts are ignored. A failed read keeps the last known list of the same account, or stays unknown.
final class UserBlockCubit extends Cubit<UserBlockList> with LoggerMixin {
  /// Constructor.
  ///
  /// [currentUid] returns the uid of the account this device acts as, it is read again on every [authStatus] event.
  ///
  /// [onListChanged] is called every time the known blocked uids of the current account differ from the last known
  /// ones, including the first time a list is known (so counts computed before are redone once on purpose).
  UserBlockCubit({
    required UserBlockRepository repository,
    required int? Function() currentUid,
    required Stream<AuthStatus> authStatus,
    VoidCallback? onListChanged,
  }) : _repository = repository,
       _currentUid = currentUid,
       _onListChanged = onListChanged,
       super(const UserBlockList.unknown(null, status: UserBlockListStatus.loading)) {
    _authSub = authStatus.listen((_) => _follow(_currentUid()));
    _follow(_currentUid());
  }

  final UserBlockRepository _repository;
  final int? Function() _currentUid;
  final VoidCallback? _onListChanged;
  late final StreamSubscription<AuthStatus> _authSub;
  StreamSubscription<UserBlockList>? _listSub;
  int? _owner;
  bool _followed = false;

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
      return;
    }
    _followed = true;
    _owner = owner;
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
              emit(list);
            }
          },
          onError: (Object e) {
            if (owner != _owner) {
              return;
            }
            error('failed to read the block list: $e');
            // Keep a list already known for this account; otherwise stay unknown.
            if (!(state.ownerUid == owner && state.status == UserBlockListStatus.ready)) {
              emit(UserBlockList.unknown(owner, status: UserBlockListStatus.failed));
            }
          },
        );
  }

  /// Read the list of the current account again, e.g. after a failure.
  Future<void> reload() async {
    final owner = _owner;
    await _listSub?.cancel();
    if (isClosed || owner != _owner) {
      return;
    }
    if (state.status == UserBlockListStatus.failed) {
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
    await _authSub.cancel();
    await _listSub?.cancel();
    return super.close();
  }
}
