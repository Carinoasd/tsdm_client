import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/rate/models/models.dart';
import 'package:tsdm_client/features/rate/repository/rate_repository.dart';
import 'package:tsdm_client/features/rate/repository/rate_window_cache.dart';
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
    final tid = RateWindowCache.tidOf(event.rateAction);
    final kept = tid == null ? null : RateWindowCache.get(tid);
    if (kept != null) {
      // The window of this thread from the last rate: the form shows at once, with this post; the window of this
      // post loads behind it and only replaces the info (today's remaining scores, a new form hash) while the user
      // has not sent anything. A window the forum refuses for this post still closes the page with its message.
      debug('rate window of thread $tid kept from the last rate, loading this post behind it');
      emit(state.copyWith(status: RateStatus.gotInfo, info: RateWindowCache.forPost(kept, event.pid)));
      final rates = _rateCount;
      switch (await _rateRepository.fetchInfo(pid: event.pid, rateTarget: event.rateAction).run()) {
        case Right(:final value):
          // A window from before a rate sent meanwhile would put back what that rate took off.
          // Neither kept nor shown once a rate went out meanwhile: the form then shows what that rate took off.
          if (rates == _rateCount) {
            RateWindowCache.put(value);
            if (!emit.isDone && state.status == RateStatus.gotInfo && _pid == event.pid) {
              emit(state.copyWith(info: value));
            }
          }
        case Left(:final value):
          handle(value);
          if (value case RateInfoWithErrorException() when !emit.isDone && state.status == RateStatus.gotInfo) {
            error('failed to fetch rate info: $value');
            emit(state.copyWith(status: RateStatus.failed, failedReason: value.message, shouldRetry: false));
          }
        // Otherwise the kept window stays: the rate goes out with it, the forum refuses a stale one with a message.
      }
      return;
    }
    emit(state.copyWith(status: RateStatus.fetchingInfo));
    await _rateRepository
        .fetchInfo(pid: event.pid, rateTarget: event.rateAction)
        .match(
          (e) {
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
          },
          (v) {
            RateWindowCache.put(v);
            emit(state.copyWith(status: RateStatus.gotInfo, info: v));
          },
        )
        .run();
  }

  Future<void> _onRateRateRequested(RateRateRequested event, RateEmitter emit) async {
    // One rate at a time: a second tap while one is out would rate the post again (the forum takes it).
    if (state.status == RateStatus.rating) {
      debug('a rate is being sent, dropped another one');
      return;
    }
    final rate = ++_rateCount;
    emit(state.copyWith(status: RateStatus.rating, failedReason: null, justRated: false));

    switch (await _rateRepository.rate(event.rateInfo, target: state.info?.submitUrl).run()) {
      case Right():
        // The page stays with the form: the floor may get another rate right away. What this rate took off today's
        // scores shows at once, the forum's own window loads behind it (and the next page of this thread starts
        // from it too).
        final rated = state.info == null ? null : RateWindowCache.rated(state.info!, event.rateInfo);
        if (rated != null) RateWindowCache.put(rated);
        emit(state.copyWith(status: RateStatus.gotInfo, info: rated ?? state.info, justRated: true));
        await _refreshInfo(emit, rate);
      case Left(:final value):
        handle(value);
        error('failed to rate: $value');
        // Keep the form: the forum's reason (not enough points, over the 24 hour limit, wrong score...) is what the
        // user needs, loading the rate window again in front of it only hid it behind a generic message.
        emit(
          state.copyWith(
            status: RateStatus.rateFailed,
            failedReason: switch (value) {
              // A refusal without a reason (the app API's result without a message) shows the page's own text.
              RateFailedException(:final reason) when reason.isNotEmpty => reason,
              _ => null,
            },
          ),
        );
        await _refreshInfo(emit, rate);
    }
  }

  /// Load the rate window again behind the form after a rate: the form hash may have expired and the remaining
  /// scores changed. The form (and the reason of a refused rate) stays on screen, a failure is ignored.
  Future<void> _refreshInfo(RateEmitter emit, int rate) async {
    final pid = _pid;
    final rateAction = _rateAction;
    if (pid == null || rateAction == null) {
      return;
    }
    final result = await _rateRepository.fetchInfo(pid: pid, rateTarget: rateAction).run();
    // Only while the form of this rate is still shown: the user may have sent the rate again meanwhile.
    final current =
        !emit.isDone &&
        rate == _rateCount &&
        (state.status == RateStatus.rateFailed || (state.status == RateStatus.gotInfo && state.justRated));
    switch (result) {
      case Right(:final value):
        if (rate == _rateCount) RateWindowCache.put(value);
        if (current) emit(state.copyWith(info: value));
      case Left(value: RateInfoWithErrorException(:final message)) when current:
        // The forum rates nothing on this post (own post, too old…): the page closes with its message, as it does
        // when the window refuses before any form is shown.
        error('failed to fetch rate info: $message');
        emit(state.copyWith(status: RateStatus.failed, failedReason: message, shouldRetry: false));
      case Left():
        break;
    }
  }
}
