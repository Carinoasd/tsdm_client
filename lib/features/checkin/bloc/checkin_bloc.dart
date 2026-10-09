import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/shared/models/models.dart';

part 'checkin_bloc.mapper.dart';

part 'checkin_event.dart';

part 'checkin_state.dart';

/// Bloc of checkin.
final class CheckinBloc extends Bloc<CheckinEvent, CheckinState> {
  /// Constructor.
  CheckinBloc({
    required CheckinRepository checkinRepository,
    required AuthenticationRepository authenticationRepository,
    required SettingsRepository settingsRepository,
  }) : _checkinRepository = checkinRepository,
       _authenticationRepository = authenticationRepository,
       _settingsRepository = settingsRepository,
       super(const CheckinStateInitial()) {
    on<CheckinRequested>(_onCheckinRequested);
    on<CheckinAuthChanged>(_onCheckinAuthChanged);
    on<CheckinStatusRequested>(_onCheckinStatusRequested);
    _authStreamSub = _authenticationRepository.status.listen(
      (status) => add(CheckinAuthChanged(authed: status is AuthStatusAuthed)),
    );
  }

  late StreamSubscription<AuthStatus> _authStreamSub;

  final CheckinRepository _checkinRepository;
  final AuthenticationRepository _authenticationRepository;
  final SettingsRepository _settingsRepository;

  Future<void> _onCheckinRequested(CheckinRequested event, Emitter<CheckinState> emit) async {
    if (_authenticationRepository.currentUser == null) {
      emit(const CheckinStateNeedLogin());
      return;
    }
    emit(const CheckinStateLoading());
    final checkinFeeling = await _settingsRepository.getValue<String>(SettingsKeys.checkinFeeling);
    final checkinMessage = await _settingsRepository.getValue<String>(SettingsKeys.checkinMessage);
    final result = await _checkinRepository.checkin(
      _authenticationRepository.currentUser!.uid!,
      CheckinFeeling.from(checkinFeeling),
      checkinMessage,
    );
    if (result is CheckinResultSuccess) {
      emit(CheckinStateSuccess(result.message));
      return;
    }
    emit(CheckinStateFailed(result));
  }

  Future<void> _onCheckinStatusRequested(CheckinStatusRequested event, Emitter<CheckinState> emit) async {
    final uid = _authenticationRepository.currentUser?.uid;
    if (uid == null) {
      emit(const CheckinStateNeedLogin());
      return;
    }
    if (state is CheckinStateLoading) {
      return;
    }
    final checked = await _checkinRepository.checkedInToday(uid);
    // The account may have changed while reading.
    if (_authenticationRepository.currentUser?.uid != uid || state is CheckinStateLoading) {
      return;
    }
    if (checked) {
      emit(const CheckinStateChecked());
    } else if (_showsChecked(state)) {
      // A new day (the app stayed open past midnight), or another account without a record: the check-in of this
      // run counted for its own day only.
      emit(const CheckinStateInitial());
    }
  }

  /// Whether [state] shows the account as checked in: recorded, checked in now, or answered "already checked in".
  static bool _showsChecked(CheckinState state) =>
      state is CheckinStateChecked ||
      state is CheckinStateSuccess ||
      (state is CheckinStateFailed && state.result is CheckinResultAlreadyChecked);

  void _onCheckinAuthChanged(CheckinAuthChanged event, Emitter<CheckinState> emit) {
    if (event.authed) {
      if (state is CheckinStateLoading) {
        return;
      }
      emit(const CheckinStateInitial());
    } else {
      if (state is CheckinStateLoading) {
        return;
      }
      emit(const CheckinStateNeedLogin());
    }
  }

  @override
  Future<void> close() async {
    await _authStreamSub.cancel();
    await super.close();
  }
}
