import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/title_shop/models/title_shop.dart';
import 'package:tsdm_client/features/title_shop/repository/title_shop_repository.dart';

/// How a confirmed purchase ended, as far as the app could verify.
enum TitlePurchaseOutcome {
  /// The shop now lists the title as owned by this account.
  purchased,

  /// The forum refused the purchase and the title is still not owned.
  rejected,

  /// The POST was sent but ownership could not be confirmed; check My titles before trying again.
  unconfirmed,

  /// Name, price or confirmation changed before sending; nothing was posted, confirm again.
  termsChanged,

  /// The title is no longer purchasable (already owned or withdrawn); nothing was posted.
  unavailable,
}

/// A purchase result bound to the title it concerns.
final class TitlePurchaseResult {
  /// Constructor.
  const TitlePurchaseResult({required this.titleId, required this.name, required this.outcome, this.message});

  /// Title id.
  final int titleId;

  /// Title name when confirmed.
  final String name;

  /// Verified outcome.
  final TitlePurchaseOutcome outcome;

  /// Server wording, quoted as served.
  final String? message;
}

/// Account-scoped shop snapshot.
final class TitleShopState {
  /// Constructor.
  const TitleShopState({
    this.url = titleShopUrl,
    this.uid,
    this.page,
    this.loading = false,
    this.failed = false,
    this.loginRequired = false,
    this.purchasingId,
    this.result,
  });

  /// Current safe shop page URL.
  final String url;

  /// The account this snapshot belongs to.
  final int? uid;

  /// Loaded page.
  final TitleShopCatalog? page;

  /// A GET is in progress.
  final bool loading;

  /// The last GET failed; retry is a GET only.
  final bool failed;

  /// Sign in to use the shop.
  final bool loginRequired;

  /// Title being purchased; every purchase control is disabled meanwhile.
  final int? purchasingId;

  /// Latest purchase result for this account.
  final TitlePurchaseResult? result;
}

/// Loads shop pages and performs at most one POST per confirmation, discarding completions of another account.
class TitleShopCubit extends Cubit<TitleShopState> {
  /// Constructor.
  TitleShopCubit({required this.currentUid, required this.repository}) : super(const TitleShopState());

  /// Active account, checked around every await.
  final int? Function() currentUid;

  /// Produces an identity-bound client for a page load.
  final TitleShopRepository Function() repository;

  int _generation = 0;
  bool _purchasing = false;
  TitleShopRepository? _loadedRepository;

  bool _current(int generation, int uid) => !isClosed && generation == _generation && uid == currentUid();

  /// Erase the snapshot immediately; any pending confirmation or completion becomes stale.
  void invalidate() {
    _generation++;
    _purchasing = false;
    _loadedRepository = null;
    if (!isClosed) emit(const TitleShopState(loading: true));
  }

  /// Load a shop page (GET only). Without [target] the current page is refreshed and the last result kept.
  Future<void> load([String? target]) async {
    if (_purchasing || isClosed) return;
    final url = titleShopPageUrl(target ?? state.url);
    if (url == null) return;
    final generation = ++_generation;
    final uid = currentUid();
    _loadedRepository = null;
    if (uid == null || uid <= 0) {
      emit(TitleShopState(url: url, loginRequired: true));
      return;
    }
    final result = target == null && state.uid == uid ? state.result : null;
    emit(TitleShopState(url: url, uid: uid, loading: true, result: result));
    try {
      final repo = repository();
      final page = await repo.fetchPage(url, uid);
      if (!_current(generation, uid)) return;
      _loadedRepository = repo;
      emit(TitleShopState(url: url, uid: uid, page: page, result: result));
    } on TitleShopIdentityException catch (e) {
      if (_current(generation, uid)) {
        emit(TitleShopState(url: url, uid: uid, loginRequired: e.guest, failed: !e.guest, result: result));
      }
    } on Object {
      if (_current(generation, uid)) emit(TitleShopState(url: url, uid: uid, failed: true, result: result));
    }
  }

  /// Whether a confirmation for [item] still refers to the displayed page and account.
  bool canPurchase(TitleShopCatalog expected, TitleShopItem item) =>
      !isClosed &&
      !_purchasing &&
      !state.loading &&
      state.uid != null &&
      state.uid == currentUid() &&
      identical(state.page, expected) &&
      expected.items.any((i) => identical(i, item)) &&
      item.status == TitleShopStatus.purchasable &&
      item.form != null &&
      _loadedRepository != null;

  /// Revalidate [item] on a fresh page, then post its purchase form exactly once and verify ownership by GET.
  ///
  /// Nothing is posted when the title changed name, price or confirmation, is no longer purchasable, or the account
  /// changed. A failed or ambiguous POST is never repeated.
  Future<void> purchase({required TitleShopCatalog expected, required TitleShopItem item}) async {
    if (!canPurchase(expected, item)) return;
    final uid = state.uid!;
    final url = state.url;
    final repo = _loadedRepository!;
    final generation = ++_generation;
    _purchasing = true;
    _loadedRepository = null;
    emit(TitleShopState(url: url, uid: uid, page: expected, purchasingId: item.id));
    TitlePurchaseResult result(TitlePurchaseOutcome outcome, [String? message]) =>
        TitlePurchaseResult(titleId: item.id, name: item.name, outcome: outcome, message: message);
    var attempted = false;
    try {
      final fresh = await repo.fetchPage(url, uid);
      if (!_current(generation, uid)) return;
      final current = fresh.items.where((i) => i.id == item.id).firstOrNull;
      if (current == null || current.status != TitleShopStatus.purchasable || current.form == null) {
        _loadedRepository = repo;
        emit(
          TitleShopState(
            url: url,
            uid: uid,
            page: fresh,
            result: result(TitlePurchaseOutcome.unavailable, current?.statusText),
          ),
        );
        return;
      }
      if (!current.sameTerms(item)) {
        _loadedRepository = repo;
        emit(TitleShopState(url: url, uid: uid, page: fresh, result: result(TitlePurchaseOutcome.termsChanged)));
        return;
      }
      attempted = true;
      ({bool error, String? message})? answer;
      try {
        answer = await repo.buy(current.form!);
      } on Object {
        // The forum may already have taken the credits. Never send it again.
      }
      if (!_current(generation, uid)) return;
      TitleShopCatalog? verified;
      try {
        verified = await repo.fetchPage(url, uid);
      } on Object {
        verified = null;
      }
      if (!_current(generation, uid)) return;
      final after = verified?.items.where((i) => i.id == item.id).firstOrNull;
      final outcome = after?.status == TitleShopStatus.owned
          ? TitlePurchaseOutcome.purchased
          : verified != null && (answer?.error ?? false)
          ? TitlePurchaseOutcome.rejected
          : TitlePurchaseOutcome.unconfirmed;
      _loadedRepository = verified == null ? null : repo;
      emit(
        TitleShopState(
          url: url,
          uid: uid,
          page: verified,
          failed: verified == null,
          result: result(outcome, answer?.message),
        ),
      );
    } on Object {
      if (_current(generation, uid)) {
        emit(
          TitleShopState(
            url: url,
            uid: uid,
            failed: true,
            result: attempted ? result(TitlePurchaseOutcome.unconfirmed) : null,
          ),
        );
      }
    } finally {
      if (generation == _generation) _purchasing = false;
    }
  }
}
