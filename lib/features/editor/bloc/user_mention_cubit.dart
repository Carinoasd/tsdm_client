import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/editor/repository/mention_repository.dart';
import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'user_mention_cubit.mapper.dart';

part 'user_mention_state.dart';

/// Cubit of the mention picker.
///
/// Loads the candidates once through [MentionRepository] and filters them locally by keyword; a keyword change never
/// touches the network.
final class UserMentionCubit extends Cubit<UserMentionState> with LoggerMixin {
  /// Constructor.
  UserMentionCubit(this._repo, {required String? selfUid}) : _selfUid = selfUid, super(UserMentionState.empty());

  final MentionRepository _repo;

  /// Uid of the current user, null when nobody is logged in (then only the official `@` list is loaded).
  final String? _selfUid;

  /// Load the candidates, from the repository cache unless [force].
  Future<void> load({bool force = false}) async {
    emit(state.copyWith(recommendStatus: UserMentionStatus.loading));
    final result = await _repo.loadCandidates(selfUid: _selfUid, force: force).run();
    if (isClosed) {
      // The sheet was dismissed while loading; the repository cache is already updated for the next open.
      return;
    }
    switch (result) {
      case Left(:final value):
        handle(value);
        emit(state.copyWith(recommendStatus: UserMentionStatus.failure));
      case Right(:final value):
        emit(
          state.copyWith(
            recommendStatus: UserMentionStatus.success,
            friends: value.friends,
            others: value.others,
            friendsMessage: value.friendsMessage,
          ),
        );
    }
  }

  /// Filter the candidates by [keyword], case insensitive.
  void setKeyword(String keyword) {
    final k = keyword.trim();
    if (k == state.keyword) {
      return;
    }
    emit(state.copyWith(keyword: k));
  }
}
