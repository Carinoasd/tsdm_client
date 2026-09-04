import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/features/profile/models/available_user_group.dart';
import 'package:tsdm_client/features/profile/repository/switch_user_group_repository.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

part 'switch_user_group_bloc.mapper.dart';
part 'switch_user_group_event.dart';
part 'switch_user_group_state.dart';

typedef _Emit = Emitter<SwitchUserGroupState>;

/// The bloc of switching user group.
final class SwitchUserGroupBloc extends Bloc<SwitchUserGroupBaseEvent, SwitchUserGroupState> with LoggerMixin {
  /// Constructor.
  SwitchUserGroupBloc(this._repo) : super(const SwitchUserGroupState(status: SwitchUserGroupStatus.initial)) {
    on<SwitchUserGroupBaseEvent>(
      (event, emit) => switch (event) {
        SwitchUserGroupLoadInfoRequested() => _onLoadInfo(emit),
        SwitchUserGroupRunSwitchRequested(:final name, :final gid, :final formHash) => _onRunSwitch(
          emit,
          name,
          gid,
          formHash,
        ),
      },
    );
  }

  final SwitchUserGroupRepository _repo;

  Future<void> _onLoadInfo(_Emit emit) async {
    emit(state.copyWith(status: SwitchUserGroupStatus.loadingInfo));
    await _repo.fetchAvailableGroupDocument().match((e) {
      handle(e);
      emit(state.copyWith(status: SwitchUserGroupStatus.failure));
    }, (v) => _updateFromInfoDocument(emit, v)).run();
  }

  Future<void> _onRunSwitch(_Emit emit, String name, int gid, String formHash) async {
    emit(state.copyWith(status: SwitchUserGroupStatus.switching));
    await _repo
        .submitSwitchRequest(gid, formHash)
        .mapLeft((e) {
          handle(e);
          // Rollback to waiting state.
          emit(state.copyWith(status: SwitchUserGroupStatus.failure));
        })
        .map((_) => emit(state.copyWith(status: SwitchUserGroupStatus.success, destination: name)))
        .run();
  }

  void _updateFromInfoDocument(_Emit emit, uh.Document document) {
    final (currentUserGroup, availableUserGroups) = AvailableUserGroup.parseInfoDocument(document);
    final formHash = document.querySelector('input[name="formhash"]')?.attributes['value'];
    if (formHash == null) {
      error('failed to build switch user group document: form hash not found');
      emit(
        state.copyWith(
          status: SwitchUserGroupStatus.failure,
          currentUserGroup: null,
          availableGroups: null,
          formHash: null,
        ),
      );
      return;
    }

    emit(
      state.copyWith(
        status: SwitchUserGroupStatus.waitingSwitchAction,
        currentUserGroup: currentUserGroup,
        availableGroups: availableUserGroups,
        formHash: formHash,
      ),
    );
  }
}
