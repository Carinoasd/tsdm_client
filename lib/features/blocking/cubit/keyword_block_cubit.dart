import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/repository/keyword_block_repository.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Holds the local keyword list of the current account and follows account switches.
///
/// The list is read once per account and kept in the state, so filtering a list or a floor never reads storage. While
/// it is not known (loading, failed) no keyword hides anything. A failed read is tried again on the next auth event
/// of the same account and on [reload].
final class KeywordBlockCubit extends Cubit<KeywordBlockList> with LoggerMixin {
  /// Constructor.
  ///
  /// [onListChanged] is called every time the known keywords of the current account differ from the last known ones,
  /// including the first time a list is known.
  KeywordBlockCubit({
    required KeywordBlockRepository repository,
    required int? Function() currentUid,
    required Stream<AuthStatus> authStatus,
    VoidCallback? onListChanged,
  }) : _repository = repository,
       _currentUid = currentUid,
       _onListChanged = onListChanged,
       super(const KeywordBlockList.unknown(null, status: UserBlockListStatus.loading)) {
    _authSub = authStatus.listen((_) => _follow(_currentUid()));
    _follow(_currentUid());
  }

  final KeywordBlockRepository _repository;
  final int? Function() _currentUid;
  final VoidCallback? _onListChanged;
  late final StreamSubscription<AuthStatus> _authSub;
  StreamSubscription<KeywordBlockList>? _listSub;
  int? _owner;
  bool _followed = false;

  /// Owner and keys of the last known list reported through [_onListChanged].
  (int?, List<String>, List<String>)? _reported;

  /// Uid of the account the actions of this cubit act for now.
  int? get owner => _owner;

  @override
  void emit(KeywordBlockList state) {
    if (isClosed) {
      return;
    }
    super.emit(state);
    if (state.status == UserBlockListStatus.ready) {
      final last = _reported;
      if (last == null ||
          last.$1 != state.ownerUid ||
          !listEquals(last.$2, state.titleKeys) ||
          !listEquals(last.$3, state.postKeys)) {
        _reported = (state.ownerUid, state.titleKeys, state.postKeys);
        _onListChanged?.call();
      }
    }
  }

  void _follow(int? owner) {
    if (_followed && owner == _owner) {
      if (state.status == UserBlockListStatus.failed) {
        _read(owner);
      }
      return;
    }
    _followed = true;
    _owner = owner;
    unawaited(_listSub?.cancel());
    _listSub = null;
    emit(
      owner == null || owner <= 0
          ? KeywordBlockList.empty(owner)
          : KeywordBlockList.unknown(owner, status: UserBlockListStatus.loading),
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
            error('failed to read the keyword block list: $e');
            if (!(state.ownerUid == owner && state.status == UserBlockListStatus.ready)) {
              emit(KeywordBlockList.unknown(owner, status: UserBlockListStatus.failed));
            }
          },
        );
  }

  void _read(int? owner) {
    if (isClosed || owner != _owner) {
      return;
    }
    unawaited(_listSub?.cancel());
    _listSub = null;
    _listen(owner);
  }

  /// Read the list of the current account again, e.g. after a failure.
  Future<void> reload() async => _read(_owner);

  Future<KeywordBlockResult> _guarded(
    int? expectedOwner,
    Future<KeywordBlockResult> Function(int? owner) action,
  ) async {
    final owner = _owner;
    if (expectedOwner != owner) {
      return KeywordBlockResult.accountChanged;
    }
    try {
      return await action(owner);
    } on Object catch (e) {
      error('failed to change the keyword block list: $e');
      return KeywordBlockResult.storageError;
    }
  }

  /// Add [keyword] for the account [expectedOwner], only if that is still the current account.
  Future<KeywordBlockResult> add(String keyword, {required int? expectedOwner}) =>
      _guarded(expectedOwner, (owner) => _repository.add(ownerUid: owner, keyword: keyword));

  /// Remove [keyword] for the account [expectedOwner], only if that is still the current account.
  Future<KeywordBlockResult> remove(String keyword, {required int? expectedOwner}) =>
      _guarded(expectedOwner, (owner) => _repository.remove(ownerUid: owner, keyword: keyword));

  /// Set whether [keyword] also hides floors, for the account [expectedOwner] only.
  Future<KeywordBlockResult> setAppliesToPosts(String keyword, {required bool value, required int? expectedOwner}) =>
      _guarded(
        expectedOwner,
        (owner) => _repository.setAppliesToPosts(ownerUid: owner, keyword: keyword, value: value),
      );

  @override
  Future<void> close() async {
    await _authSub.cancel();
    await _listSub?.cancel();
    return super.close();
  }
}
