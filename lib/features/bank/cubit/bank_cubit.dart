import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/bank/models/bank_data.dart';
import 'package:tsdm_client/features/bank/repository/bank_repository.dart';

/// In-memory bank snapshots. Passwords are never held in state or persisted.
final class BankState {
  /// Constructor.
  const BankState({
    this.banks = const [],
    this.bank,
    this.savings,
    this.logs,
    this.uid,
    this.busy = false,
    this.submitting = false,
    this.failed = false,
    this.loginRequired = false,
    this.unconfirmed = false,
    this.received = false,
    this.logPage = 1,
  });

  /// Available banks for this account.
  final List<ForumBank> banks;

  /// Selected bank, or null in the directory.
  final ForumBank? bank;

  /// Current savings and validated form.
  final BankSavings? savings;

  /// Visible transaction records.
  final BankLogs? logs;

  /// The account that owns these snapshots.
  final int? uid;

  /// A read or a transaction is in progress.
  final bool busy;

  /// Keep the transaction result visible by preventing navigation during a POST.
  final bool submitting;

  /// The last read failed. No previous transaction form remains usable.
  final bool failed;

  /// Sign in before reading bank data.
  final bool loginRequired;

  /// A transaction may have been accepted; inspect records before another one.
  final bool unconfirmed;

  /// Whether received records are selected.
  final bool received;

  /// Current log page (one-based).
  final int logPage;
}

/// Serializes transactions and discards obsolete account/bank completions.
class BankCubit extends Cubit<BankState> {
  /// Constructor.
  BankCubit({required this.currentUid, required this.repository}) : super(const BankState());

  /// Active account, checked around every await and confirmation.
  final int? Function() currentUid;

  /// Produces an identity-bound client for a new page load.
  final BankRepository Function() repository;
  int _generation = 0;
  bool _submitting = false;
  BankRepository? _loadedRepository;

  bool _current(int generation, int? uid) => !isClosed && generation == _generation && uid == currentUid();

  /// Immediately erase snapshots and close old confirmation opportunities.
  void invalidate() {
    _generation++;
    _submitting = false;
    _loadedRepository = null;
    if (!isClosed) emit(const BankState(busy: true));
  }

  /// Checks that a confirmation still refers to the displayed account and form.
  bool isCurrent(BankSavings expected) =>
      !isClosed &&
      !state.busy &&
      !_submitting &&
      state.uid != null &&
      state.uid == currentUid() &&
      identical(state.savings, expected) &&
      expected.form != null &&
      _loadedRepository != null;

  /// Return to the directory; only a GET is performed.
  Future<void> load() async {
    if (_submitting || isClosed) return;
    final generation = ++_generation;
    final uid = currentUid();
    _loadedRepository = null;
    if (uid == null || uid <= 0) {
      emit(const BankState(loginRequired: true));
      return;
    }
    emit(BankState(uid: uid, busy: true));
    try {
      final result = await repository().fetchDirectory(uid);
      if (_current(generation, uid)) emit(BankState(uid: uid, banks: List.unmodifiable(result.banks)));
    } on Object {
      if (_current(generation, uid)) emit(BankState(uid: uid, failed: true));
    }
  }

  /// Select only a bank offered by the current account's directory.
  Future<void> selectBank(ForumBank bank) async {
    if (_submitting || isClosed || state.uid == null || state.uid != currentUid()) return;
    if (!state.banks.any((item) => identical(item, bank))) return;
    await _loadSavings(bank, unconfirmed: false);
  }

  Future<void> _loadSavings(ForumBank bank, {required bool unconfirmed}) async {
    final generation = ++_generation;
    final uid = currentUid();
    if (uid == null || uid <= 0) return;
    final banks = state.banks;
    _loadedRepository = null;
    if (!bank.hasAccount) {
      emit(BankState(uid: uid, banks: banks, bank: bank));
      return;
    }
    emit(BankState(uid: uid, banks: banks, bank: bank, busy: true, unconfirmed: unconfirmed));
    try {
      final repo = repository();
      final savings = await repo.fetchSavings(bank.id, uid);
      if (!_current(generation, uid)) return;
      _loadedRepository = repo;
      emit(BankState(uid: uid, banks: banks, bank: bank, savings: savings, unconfirmed: unconfirmed));
    } on Object {
      if (_current(generation, uid)) {
        emit(BankState(uid: uid, banks: banks, bank: bank, failed: true, unconfirmed: unconfirmed));
      }
    }
  }

  /// GET-only refresh. An ambiguous transaction warning survives refreshes.
  Future<void> refresh() async {
    if (_submitting || isClosed) return;
    if (state.uid != currentUid()) {
      await load();
      return;
    }
    final bank = state.bank;
    if (bank == null) {
      await load();
    } else {
      final snapshot = state;
      await _loadSavings(bank, unconfirmed: snapshot.unconfirmed);
      if (!state.failed && state.bank == bank && state.uid == snapshot.uid && snapshot.logs != null) {
        await loadLogs(received: snapshot.received, page: snapshot.logPage);
      }
    }
  }

  /// Load own/received records, preserving the current balance on success.
  Future<void> loadLogs({bool received = false, int page = 1}) async {
    if (_submitting || isClosed || page < 1 || state.bank?.hasAccount != true || state.uid != currentUid()) return;
    final snapshot = state;
    final uid = snapshot.uid;
    if (uid == null || uid <= 0) return;
    final generation = ++_generation;
    emit(
      BankState(
        uid: uid,
        banks: snapshot.banks,
        bank: snapshot.bank,
        savings: snapshot.savings,
        busy: true,
        unconfirmed: snapshot.unconfirmed,
        received: received,
        logPage: page,
      ),
    );
    try {
      final logs = await repository().fetchLogs(snapshot.bank!.id, uid, received: received, page: page);
      if (!_current(generation, uid)) return;
      emit(
        BankState(
          uid: uid,
          banks: snapshot.banks,
          bank: snapshot.bank,
          savings: snapshot.savings,
          logs: logs,
          unconfirmed: snapshot.unconfirmed,
          received: received,
          logPage: page,
        ),
      );
    } on Object {
      if (!_current(generation, uid)) return;
      _loadedRepository = null;
      emit(
        BankState(
          uid: uid,
          banks: snapshot.banks,
          bank: snapshot.bank,
          failed: true,
          unconfirmed: snapshot.unconfirmed,
          received: received,
          logPage: page,
        ),
      );
    }
  }

  /// Revalidate the server form, then submit exactly once with the same account.
  Future<void> submit({
    required BankSavings expected,
    required BankOperation operation,
    required String amount,
    required String password,
  }) async {
    if (!isCurrent(expected) || !expected.form!.accepts(amount) || password.isEmpty) return;
    final snapshot = state;
    final uid = snapshot.uid!;
    final repo = _loadedRepository!;
    final bank = snapshot.bank!;
    final generation = ++_generation;
    _submitting = true;
    _loadedRepository = null;
    emit(
      BankState(
        uid: uid,
        banks: snapshot.banks,
        bank: bank,
        busy: true,
        submitting: true,
        unconfirmed: snapshot.unconfirmed,
      ),
    );
    var attempted = false;
    try {
      final fresh = await repo.fetchSavings(bank.id, uid);
      if (!_current(generation, uid)) return;
      final form = fresh.form;
      if (form == null || !form.accepts(amount) || fresh.currency != expected.currency) {
        throw const FormatException('Bank form changed before confirmation');
      }
      attempted = true;
      try {
        await repo.submit(form, operation, amount, password);
      } on Object {
        // The server could already have accepted it. Never repeat the POST.
      }
      if (!_current(generation, uid)) return;
      final savings = await repo.fetchSavings(bank.id, uid);
      if (!_current(generation, uid)) return;
      final logs = await repo.fetchLogs(bank.id, uid);
      if (!_current(generation, uid)) return;
      _loadedRepository = repo;
      emit(BankState(uid: uid, banks: snapshot.banks, bank: bank, savings: savings, logs: logs, unconfirmed: true));
    } on Object {
      if (_current(generation, uid)) {
        emit(
          BankState(
            uid: uid,
            banks: snapshot.banks,
            bank: bank,
            failed: true,
            unconfirmed: attempted || snapshot.unconfirmed,
          ),
        );
      }
    } finally {
      if (_current(generation, uid)) _submitting = false;
    }
  }
}
