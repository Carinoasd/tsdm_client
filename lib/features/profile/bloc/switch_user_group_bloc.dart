import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/models/available_user_group.dart';
import 'package:tsdm_client/features/profile/repository/switch_user_group_repository.dart';
import 'package:tsdm_client/utils/logger.dart';

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
    emit(state.copyWith(status: SwitchUserGroupStatus.loadingInfo, failureReason: null));
    switch (await _repo.fetchAvailableGroups().run()) {
      case Right(:final value):
        emit(
          state.copyWith(
            status: SwitchUserGroupStatus.waitingSwitchAction,
            currentUserGroup: value.currentUserGroup,
            availableGroups: value.availableGroups,
            formHash: value.formHash,
          ),
        );
      case Left(:final value):
        handle(value);
        emit(state.copyWith(status: SwitchUserGroupStatus.failure, failureReason: _reasonOf(value)));
    }
  }

  Future<void> _onRunSwitch(_Emit emit, String name, int gid, String formHash) async {
    emit(state.copyWith(status: SwitchUserGroupStatus.switching, failureReason: null));
    final group =
        state.availableGroups.where((e) => e.gid == gid).firstOrNull ??
        AvailableUserGroup(name: name, gid: gid, infoUrl: '');
    switch (await _repo.switchTo(group, formHash).run()) {
      case Right(:final value):
        emit(state.copyWith(status: SwitchUserGroupStatus.success, destination: value));
      case Left(:final value):
        handle(value);
        emit(state.copyWith(status: SwitchUserGroupStatus.failure, failureReason: _reasonOf(value)));
    }
  }

  /// The forum's own words of a failure, null when it gave none.
  static String? _reasonOf(Object e) => switch (e) {
    SwitchUserGroupFailed(:final reason?) when reason.isNotEmpty => reason,
    _ => null,
  };
}
