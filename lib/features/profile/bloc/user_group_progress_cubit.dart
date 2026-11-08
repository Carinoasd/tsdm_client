import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/models/user_group_progress.dart';
import 'package:tsdm_client/features/profile/repository/user_group_progress_repository.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Loading status of the user group progress.
enum UserGroupProgressStatus {
  /// Nothing requested yet.
  initial,

  /// Reading the forum's user group pages.
  loading,

  /// Read: [UserGroupProgressState.progress] is null when the account has no next credit-based group.
  success,

  /// Reading failed.
  failure,
}

/// State of [UserGroupProgressCubit].
@immutable
final class UserGroupProgressState {
  /// Constructor.
  const UserGroupProgressState({this.status = UserGroupProgressStatus.initial, this.progress});

  /// Loading status.
  final UserGroupProgressStatus status;

  /// The progress, null when none (yet).
  final UserGroupProgress? progress;
}

/// Reads the user group progress of the current account, for the profile section (summary) or its detail page.
final class UserGroupProgressCubit extends Cubit<UserGroupProgressState> with LoggerMixin {
  /// Constructor.
  UserGroupProgressCubit(this._repo) : super(const UserGroupProgressState());

  final UserGroupProgressRepository _repo;

  /// Read the progress; [detail] also reads every group of the table.
  Future<void> load({bool detail = false}) async {
    emit(UserGroupProgressState(status: UserGroupProgressStatus.loading, progress: state.progress));
    final result = await (detail ? _repo.fetchDetail() : _repo.fetchProgress()).run();
    if (isClosed) {
      return;
    }
    switch (result) {
      case Right(:final value):
        emit(UserGroupProgressState(status: UserGroupProgressStatus.success, progress: value));
      case Left<AppException, UserGroupProgress?>(:final value):
        if (value is! IdentityChangedException) {
          error('failed to load user group progress: $value');
        }
        emit(const UserGroupProgressState(status: UserGroupProgressStatus.failure));
    }
  }
}
