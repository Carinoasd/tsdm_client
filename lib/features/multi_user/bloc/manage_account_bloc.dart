import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'manage_account_bloc.mapper.dart';
part 'manage_account_event.dart';
part 'manage_account_state.dart';

typedef _Emit = Emitter<ManageAccountState>;

/// Bloc of the manage accounts page: selection of accounts and deleting them from this device.
///
/// Deleting is local only, the forum is never asked to log out: accounts other than the current one lose their saved
/// login through [StorageProvider.deleteCookiesByUids], the current one through
/// [AuthenticationRepository.forgetCurrentUser] which also signs this device out.
final class ManageAccountBloc extends Bloc<ManageAccountEvent, ManageAccountState> with LoggerMixin {
  /// Constructor.
  ManageAccountBloc({
    required StorageProvider storageProvider,
    required AuthenticationRepository authenticationRepository,
  }) : _storageProvider = storageProvider,
       _authenticationRepository = authenticationRepository,
       super(const ManageAccountState()) {
    on<ManageAccountEvent>(
      (event, emit) => switch (event) {
        ManageAccountSelectionStarted() => emit(const ManageAccountState(selecting: true)),
        ManageAccountSelectionToggled(:final uid) => _onToggled(uid, emit),
        ManageAccountSelectAllRequested(:final uids) => emit(
          state.copyWith(selecting: true, selectedUids: uids.toSet(), status: ManageAccountStatus.idle),
        ),
        ManageAccountSelectionCleared() => emit(const ManageAccountState()),
        ManageAccountDeleteSelectedRequested() => _onDeleteSelected(emit),
      },
    );
  }

  final StorageProvider _storageProvider;
  final AuthenticationRepository _authenticationRepository;

  void _onToggled(int uid, _Emit emit) {
    final selected = {...state.selectedUids};
    if (!selected.remove(uid)) {
      selected.add(uid);
    }
    emit(state.copyWith(selecting: true, selectedUids: selected, status: ManageAccountStatus.idle));
  }

  Future<void> _onDeleteSelected(_Emit emit) async {
    if (state.selectedUids.isEmpty || state.status == ManageAccountStatus.deleting) {
      return;
    }
    emit(state.copyWith(status: ManageAccountStatus.deleting));
    final currentUid = _authenticationRepository.currentUser?.uid;
    final others = state.selectedUids.where((uid) => uid != currentUid);
    var deleted = await _storageProvider.deleteCookiesByUids(others);
    if (currentUid != null && state.selectedUids.contains(currentUid)) {
      switch (await _authenticationRepository.forgetCurrentUser().run()) {
        case Left(:final value):
          handle(value);
          emit(state.copyWith(status: ManageAccountStatus.failed, deletedCount: deleted));
          return;
        case Right():
          deleted += 1;
      }
    }
    info('deleted $deleted account(s) from this device');
    emit(ManageAccountState(status: ManageAccountStatus.deleted, deletedCount: deleted));
  }
}
