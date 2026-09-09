import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// The ids of the threads the current account replied to, from the local marks (issue #21).
///
/// Follows the account in use: the stored marks of [AuthenticationRepository.effectiveCurrentUid] are watched, so
/// the set is there before the session is verified and moves with an account switch; it is empty while no account
/// is in use. Thread lists and the thread page read it through [isThreadReplied].
final class RepliedThreadCubit extends Cubit<Set<int>> with LoggerMixin {
  /// Constructor.
  ///
  /// With [authenticationRepository] the cubit follows the current account; without it the marks of [uid] are
  /// watched (tests).
  RepliedThreadCubit({
    required StorageProvider storageProvider,
    AuthenticationRepository? authenticationRepository,
    int? uid,
  }) : _storageProvider = storageProvider,
       super(const {}) {
    if (authenticationRepository == null) {
      _follow(uid);
      return;
    }
    _follow(authenticationRepository.effectiveCurrentUid);
    _authSub = authenticationRepository.status.listen((_) => _follow(authenticationRepository.effectiveCurrentUid));
  }

  final StorageProvider _storageProvider;

  StreamSubscription<void>? _authSub;
  StreamSubscription<Set<int>>? _marksSub;
  int? _uid;

  /// The account whose marks are watched, null when none.
  int? get uid => _uid;

  void _follow(int? uid) {
    if (uid == _uid && (_marksSub != null || uid == null)) {
      return;
    }
    _uid = uid;
    unawaited(_marksSub?.cancel());
    _marksSub = null;
    if (uid == null) {
      emit(const {});
      return;
    }
    _marksSub = _storageProvider.watchRepliedTids(uid).listen(
      (tids) {
        if (!isClosed) {
          emit(tids);
        }
      },
      onError: (Object e, StackTrace st) => error('failed to watch replied threads: $e', e, st),
    );
  }

  @override
  Future<void> close() async {
    await _authSub?.cancel();
    await _marksSub?.cancel();
    return super.close();
  }
}

/// Whether the current account replied to the thread [tid] according to the local marks.
///
/// Rebuilds the caller when the mark of that thread changes. False when [tid] is not a thread id or when no
/// [RepliedThreadCubit] is above [context] (a widget shown outside the app tree).
bool isThreadReplied(BuildContext context, String? tid) {
  final id = int.tryParse(tid ?? '');
  if (id == null || context.readOrNull<RepliedThreadCubit>() == null) {
    return false;
  }
  return context.select<RepliedThreadCubit, bool>((cubit) => cubit.state.contains(id));
}
