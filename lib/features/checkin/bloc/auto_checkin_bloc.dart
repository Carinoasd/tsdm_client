import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/repository/auto_checkin_repository.dart';
import 'package:tsdm_client/features/checkin/utils/checkin_day.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

part 'auto_checkin_bloc.mapper.dart';
part 'auto_checkin_event.dart';
part 'auto_checkin_state.dart';

typedef _Emit = Emitter<AutoCheckinState>;

/// Bloc for auto checkin feature.
final class AutoCheckinBloc extends Bloc<AutoCheckinEvent, AutoCheckinState> {
  /// Constructor.
  AutoCheckinBloc({
    required AutoCheckinRepository autoCheckinRepository,
    required SettingsRepository settingsRepository,
    required StorageProvider storageProvider,
  }) : _autoCheckinRepository = autoCheckinRepository,
       _settingsRepository = settingsRepository,
       _storageProvider = storageProvider,
       super(const AutoCheckinStateInitial()) {
    on<AutoCheckinEvent>(
      (e, emit) => switch (e) {
        AutoCheckinStartRequested() => _onStart(emit),
        AutoCheckinUserStateChanged(:final checkinInfo) => _onUserStateChanged(checkinInfo, emit),
      },
    );

    // Update checkin state.
    _stateSub = _autoCheckinRepository.status.listen((e) => add(AutoCheckinUserStateChanged(e)));
  }

  final AutoCheckinRepository _autoCheckinRepository;
  final SettingsRepository _settingsRepository;
  final StorageProvider _storageProvider;

  late final StreamSubscription<AutoCheckinInfo> _stateSub;

  /// Start auto checkin progress.
  ///
  /// Unlike most event handler functions, this one only triggers the progress,
  /// not changing any state of current bloc.
  ///
  /// Alternatively, state is updated by acting on repository's state stream
  /// called [_onUserStateChanged].
  Future<void> _onStart(_Emit emit) async {
    // First trap into preparing state.
    emit(const AutoCheckinStatePreparing());

    final now = DateTime.now();
    final users = await _storageProvider.getAllUsersWithTime();

    final skippedList = <UserLoginInfo>[];
    final waitingList = <UserLoginInfo>[];
    for (final (user, lastCheckinTime) in users) {
      if ((user.uid == null || user.uid! < 1) || (user.username == null || user.username!.isEmpty)) {
        // Drop invalid ones.
        continue;
      }
      // Only check in the accounts that did not check in today (device-local day, see [isCheckedInToday]).
      if (isCheckedInToday(lastCheckinTime, now: now)) {
        skippedList.add(user);
      } else {
        waitingList.add(user);
      }
    }
    if (waitingList.isEmpty) {
      // No users to auto checkin, skip.
      emit(const AutoCheckinStateInitial());
      return;
    }

    final checkinFeeling = await _settingsRepository.getValue<String>(SettingsKeys.checkinFeeling);
    final checkinMessage = await _settingsRepository.getValue<String>(SettingsKeys.checkinMessage);
    await _autoCheckinRepository
        .checkinAll(
          waitingList: waitingList,
          skippedList: skippedList,
          feeling: CheckinFeeling.from(checkinFeeling),
          message: checkinMessage,
        )
        .run();
  }

  Future<void> _onUserStateChanged(AutoCheckinInfo checkinInfo, _Emit emit) async {
    if (checkinInfo.waiting.isEmpty &&
        checkinInfo.running.isEmpty &&
        (checkinInfo.succeeded.isNotEmpty || checkinInfo.failed.isNotEmpty)) {
      // The last check-in time of every account was written by the repository when that account finished; a write
      // here would stamp the batch end, which is the next day when a run crosses midnight.
      emit(AutoCheckinStateFinished(succeeded: checkinInfo.succeeded, failed: checkinInfo.failed));
      return;
    }

    emit(AutoCheckinStateLoading(checkinInfo));
  }

  @override
  Future<void> close() async {
    await _stateSub.cancel();
    await _autoCheckinRepository.dispose();
    return super.close();
  }
}
