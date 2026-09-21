import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/rate/models/models.dart';
import 'package:tsdm_client/features/rate/repository/rate_repository.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'rate_bloc.mapper.dart';

part 'rate_event.dart';

part 'rate_state.dart';

/// Emitter
typedef RateEmitter = Emitter<RateState>;

/// Bloc to rate.
final class RateBloc extends Bloc<RateEvent, RateState> with LoggerMixin {
  /// Constructor.
  RateBloc({required RateRepository rateRepository}) : _rateRepository = rateRepository, super(const RateState()) {
    on<RateFetchInfoRequested>(_onRateFetchInfoRequested);
    on<RateRateRequested>(_onRateRateRequested);
  }

  final RateRepository _rateRepository;

  /// Post and rate action of the rate window loaded last, to load it again after a refused rate.
  String? _pid;
  String? _rateAction;

  /// Counts the rates sent: a reload started for an older rate is dropped.
  int _rateCount = 0;

  Future<void> _onRateFetchInfoRequested(RateFetchInfoRequested event, RateEmitter emit) async {
    _pid = event.pid;
    _rateAction = event.rateAction;
    emit(state.copyWith(status: RateStatus.fetchingInfo));
    await _rateRepository.fetchInfo(pid: event.pid, rateTarget: event.rateAction).match((e) {
      handle(e);
      if (e case HttpRequestFailedException()) {
        error('failed to fetch rate info: $e');
        emit(state.copyWith(status: RateStatus.failed));
      } else if (e case RateInfoWithErrorException()) {
        error('failed to fetch rate info: $e');
        // Do NOT retry if server returns an error.
        emit(state.copyWith(status: RateStatus.failed, failedReason: e.message, shouldRetry: false));
      } else if (e case RateInfoException()) {
        error('failed to fetch rate info: $e');
        emit(state.copyWith(status: RateStatus.failed, failedReason: e.toString()));
      } else {
        emit(state.copyWith(status: RateStatus.failed));
      }
    }, (v) => emit(state.copyWith(status: RateStatus.gotInfo, info: v))).run();
  }

  Future<void> _onRateRateRequested(RateRateRequested event, RateEmitter emit) async {
    final rate = ++_rateCount;
    emit(state.copyWith(status: RateStatus.rating, failedReason: null));

    switch (await _rateRepository.rate(event.rateInfo).run()) {
      case Right():
        emit(state.copyWith(status: RateStatus.success));
      case Left(:final value):
        handle(value);
        error('failed to rate: $value');
        // Keep the form: the forum's reason (not enough points, over the 24 hour limit, wrong score...) is what the
        // user needs, loading the rate window again in front of it only hid it behind a generic message.
        emit(
          state.copyWith(
            status: RateStatus.rateFailed,
            failedReason: switch (value) {
              RateFailedException(:final reason) => reason,
              _ => null,
            },
          ),
        );
        await _refreshInfo(emit, rate);
    }
  }

  /// Load the rate window again behind the refused form: the form hash may have expired and the remaining scores
  /// changed. The form and the reason stay on screen, a failure is ignored.
  Future<void> _refreshInfo(RateEmitter emit, int rate) async {
    final pid = _pid;
    final rateAction = _rateAction;
    if (pid == null || rateAction == null) {
      return;
    }
    final result = await _rateRepository.fetchInfo(pid: pid, rateTarget: rateAction).run();
    // Only while the form refused for this rate is shown: the user may have sent the rate again meanwhile.
    if (result case Right(
      :final value,
    ) when !emit.isDone && rate == _rateCount && state.status == RateStatus.rateFailed) {
      emit(state.copyWith(info: value));
    }
  }
}
