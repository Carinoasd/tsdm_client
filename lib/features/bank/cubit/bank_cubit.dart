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
    this.logsFailed = false,
    this.service,
    this.serviceData,
    this.servicePage = 1,
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

  /// A records-only failure must not erase already loaded savings.
  final bool logsFailed;

  /// Selected native service, or null for current savings and logs.
  final BankService? service;

  /// Current service snapshot, separate from current savings.
  final BankServiceData? serviceData;

  /// Current page of the selected service.
  final int servicePage;
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
    if (state.service case final service?) {
      await loadService(service, page: state.servicePage);
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
      emit(
        BankState(
          uid: uid,
          banks: snapshot.banks,
          bank: snapshot.bank,
          savings: snapshot.savings,
          logsFailed: true,
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
      BankLogs? logs;
      var logsFailed = false;
      try {
        logs = await repo.fetchLogs(bank.id, uid);
      } on Object {
        logsFailed = true;
      }
      if (!_current(generation, uid)) return;
      _loadedRepository = repo;
      emit(
        BankState(
          uid: uid,
          banks: snapshot.banks,
          bank: bank,
          savings: savings,
          logs: logs,
          logsFailed: logsFailed,
          unconfirmed: true,
        ),
      );
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

  /// Read one bank or global service without depending on a savings record.
  Future<void> loadService(BankService service, {int page = 1}) async {
    if (_submitting || isClosed || page < 1 || state.uid != currentUid()) return;
    final uid = state.uid;
    final bank = state.bank;
    if (uid == null || (!service.global && bank == null)) return;
    final snapshot = state;
    final generation = ++_generation;
    _loadedRepository = null;
    emit(
      BankState(
        uid: uid,
        banks: snapshot.banks,
        bank: bank,
        service: service,
        servicePage: page,
        busy: true,
        unconfirmed: snapshot.unconfirmed,
      ),
    );
    try {
      final repo = repository();
      final data = await repo.fetchService(service, uid, bankId: bank?.id, page: page);
      if (!_current(generation, uid)) return;
      _loadedRepository = repo;
      emit(
        BankState(
          uid: uid,
          banks: snapshot.banks,
          bank: bank,
          service: service,
          serviceData: data,
          servicePage: page,
          unconfirmed: snapshot.unconfirmed,
        ),
      );
    } on Object {
      if (_current(generation, uid)) {
        emit(
          BankState(
            uid: uid,
            banks: snapshot.banks,
            bank: bank,
            service: service,
            servicePage: page,
            failed: true,
            unconfirmed: snapshot.unconfirmed,
          ),
        );
      }
    }
  }

  /// A service confirmation must belong to the exact visible snapshot and account.
  bool isCurrentService(BankServiceData expected, BankServiceForm form) =>
      !isClosed &&
      !state.busy &&
      !_submitting &&
      state.uid != null &&
      state.uid == currentUid() &&
      identical(state.serviceData, expected) &&
      expected.forms.any((item) => identical(item, form)) &&
      state.bank?.id == form.bankId &&
      _loadedRepository != null;

  /// Revalidate the specific record/form and terms, then issue at most one POST.
  Future<void> submitService({
    required BankServiceData expected,
    required BankServiceForm form,
    required Map<String, String> values,
  }) async {
    if (!isCurrentService(expected, form)) return;
    try {
      form.body(values);
    } on FormatException {
      return;
    }
    final snapshot = state;
    final uid = snapshot.uid!;
    final repo = _loadedRepository!;
    final bank = snapshot.bank!;
    final service = snapshot.service!;
    final generation = ++_generation;
    _submitting = true;
    _loadedRepository = null;
    emit(
      BankState(
        uid: uid,
        banks: snapshot.banks,
        bank: bank,
        service: service,
        servicePage: snapshot.servicePage,
        busy: true,
        submitting: true,
        unconfirmed: snapshot.unconfirmed,
      ),
    );
    var attempted = false;
    try {
      final fresh = await repo.fetchService(service, uid, bankId: bank.id, page: snapshot.servicePage);
      if (!_current(generation, uid)) return;
      final matches = fresh.forms.where(form.matches).toList();
      if (matches.length != 1 ||
          fresh.currency != expected.currency ||
          fresh.confirmationTerms != expected.confirmationTerms ||
          fresh.feeRate != expected.feeRate) {
        throw const FormatException('Bank service or terms changed before confirmation');
      }
      final currentForm = matches.single..body(values);
      attempted = true;
      try {
        await repo.submitService(currentForm, values);
      } on Object {
        // The server may already have accepted the action. Never send it twice.
      }
      if (!_current(generation, uid)) return;
      final data = await repo.fetchService(service, uid, bankId: bank.id, page: snapshot.servicePage);
      if (!_current(generation, uid)) return;
      var banks = snapshot.banks;
      var currentBank = bank;
      if (service == BankService.hall || service == BankService.account) {
        try {
          final directory = await repo.fetchDirectory(uid);
          if (!_current(generation, uid)) return;
          banks = directory.banks;
          currentBank = banks.where((item) => item.id == bank.id).firstOrNull ?? bank;
        } on Object {
          // A directory refresh cannot erase the operation result or trigger a retry.
        }
      }
      if (!_current(generation, uid)) return;
      _loadedRepository = repo;
      emit(
        BankState(
          uid: uid,
          banks: banks,
          bank: currentBank,
          service: service,
          serviceData: data,
          servicePage: snapshot.servicePage,
          unconfirmed: true,
        ),
      );
    } on Object {
      if (_current(generation, uid)) {
        emit(
          BankState(
            uid: uid,
            banks: snapshot.banks,
            bank: bank,
            service: service,
            servicePage: snapshot.servicePage,
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
