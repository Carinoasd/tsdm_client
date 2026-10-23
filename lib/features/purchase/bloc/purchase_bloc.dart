import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/purchase/models/models.dart';
import 'package:tsdm_client/features/purchase/repository/purchase_repository.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'purchase_bloc.mapper.dart';

part 'purchase_event.dart';

part 'purchase_state.dart';

/// Emitter
typedef PurchaseEmitter = Emitter<PurchaseState>;

/// Bloc of purchasing.
final class PurchaseBloc extends Bloc<PurchaseEvent, PurchaseState> with LoggerMixin {
  /// Constructor.
  PurchaseBloc({required PurchaseRepository purchaseRepository})
    : _purchaseRepository = purchaseRepository,
      super(const PurchaseState()) {
    on<PurchaseFetchConfirmInfoRequested>(_onPurchaseFetchConfirmInfoRequested);
    on<PurchasePurchaseRequested>(_onPurchasePurchaseRequested);
    on<PurchasePurchasedCanceled>(_onPurchasePurchasedCanceled);
  }

  final PurchaseRepository _purchaseRepository;

  Future<void> _onPurchaseFetchConfirmInfoRequested(
    PurchaseFetchConfirmInfoRequested event,
    PurchaseEmitter emit,
  ) async {
    emit(state.copyWith(status: PurchaseStatus.loading));
    await _purchaseRepository.fetchPurchaseConfirmInfo(tid: event.tid, pid: event.pid).match((e) {
      handle(e);
      error('failed to fetch purchase info: $e');
      emit(
        state.copyWith(
          status: PurchaseStatus.failed,
          failedReason: e is PurchaseRefusedException ? e.reason : null,
        ),
      );
    }, (v) => emit(state.copyWith(status: PurchaseStatus.gotInfo, confirmInfo: v, failedReason: null))).run();
  }

  Future<void> _onPurchasePurchaseRequested(PurchasePurchaseRequested event, PurchaseEmitter emit) async {
    if (state.confirmInfo == null) {
      error('failed to purchase: confirm info not prepared');
      emit(state.copyWith(status: PurchaseStatus.failed));
      return;
    }
    emit(state.copyWith(status: PurchaseStatus.loading));

    final confirmInfo = state.confirmInfo!;

    switch (await _purchaseRepository.purchase(confirmInfo).run()) {
      case Right():
        emit(state.copyWith(status: PurchaseStatus.success, failedReason: null));
      case Left(:final value):
        handle(value);
        error('failed to purchase: $value');
        emit(
          state.copyWith(
            status: PurchaseStatus.failed,
            failedReason: switch (value) {
              PurchaseRefusedException(:final reason) => reason,
              PurchaseActionFailedException(:final reason) => reason,
              _ => null,
            },
          ),
        );
    }
  }

  Future<void> _onPurchasePurchasedCanceled(PurchasePurchasedCanceled event, PurchaseEmitter emit) async {
    emit(state.copyWith(status: PurchaseStatus.initial));
  }
}
