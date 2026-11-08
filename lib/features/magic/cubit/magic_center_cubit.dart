import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/magic/models/magic_models.dart';
import 'package:tsdm_client/features/magic/repository/magic_repository.dart';

/// What a buy or a use came to, as far as the app could tell.
final class MagicOperationResult {
  /// Constructor.
  const MagicOperationResult({required this.name, required this.buy, required this.kind, this.message = ''});

  /// The magic's name.
  final String name;

  /// A buy (or a use).
  final bool buy;

  /// The forum's verdict.
  final MagicResultKind kind;

  /// The forum's words.
  final String message;
}

/// Account-scoped snapshot of the shop and the account's magics.
final class MagicCenterState {
  /// Constructor.
  const MagicCenterState({
    this.uid,
    this.shop,
    this.box,
    this.shopUrl = magicShopUrl,
    this.boxUrl = magicBoxUrl,
    this.loading = false,
    this.failed = false,
    this.loginRequired = false,
    this.message,
    this.busy = false,
    this.result,
  });

  /// The account this snapshot belongs to.
  final int? uid;

  /// The shop page shown.
  final MagicListPage? shop;

  /// The account's magics page shown.
  final MagicListPage? box;

  /// Url of [shop].
  final String shopUrl;

  /// Url of [box].
  final String boxUrl;

  /// A GET is in progress.
  final bool loading;

  /// The last GET failed.
  final bool failed;

  /// Sign in to use the shop.
  final bool loginRequired;

  /// The forum answered a message instead of the shop (magics closed, no permission).
  final String? message;

  /// A window is being read or a form posted; every control is disabled meanwhile.
  final bool busy;

  /// The latest buy or use.
  final MagicOperationResult? result;

  /// A copy with the given fields replaced.
  MagicCenterState copyWith({
    MagicListPage? shop,
    MagicListPage? box,
    String? shopUrl,
    String? boxUrl,
    bool? loading,
    bool? failed,
    bool? busy,
    MagicOperationResult? result,
  }) => MagicCenterState(
    uid: uid,
    shop: shop ?? this.shop,
    box: box ?? this.box,
    shopUrl: shopUrl ?? this.shopUrl,
    boxUrl: boxUrl ?? this.boxUrl,
    loading: loading ?? this.loading,
    failed: failed ?? this.failed,
    loginRequired: loginRequired,
    message: message,
    busy: busy ?? this.busy,
    result: result ?? this.result,
  );
}

/// Loads the shop and the account's magics; reads one window and posts it at most once per confirmation, dropping
/// whatever completes for another account.
class MagicCenterCubit extends Cubit<MagicCenterState> {
  /// Constructor.
  MagicCenterCubit({required this.currentUid, required this.repository}) : super(const MagicCenterState());

  /// Active account, checked around every await.
  final int? Function() currentUid;

  /// Produces an identity-bound client.
  final MagicRepository Function() repository;

  int _generation = 0;
  MagicRepository? _repository;

  bool _current(int generation, int uid) => !isClosed && generation == _generation && uid == currentUid();

  /// Erase the snapshot immediately; anything pending becomes stale.
  void invalidate() {
    _generation++;
    _repository = null;
    if (!isClosed) emit(const MagicCenterState(loading: true));
  }

  /// Load both lists (GET only). [shopUrl] and [boxUrl] change the page of one list.
  Future<void> load({String? shopUrl, String? boxUrl}) async {
    if (isClosed || state.busy) return;
    final shop = magicListPageUrl(shopUrl ?? state.shopUrl, MagicList.shop) ?? magicShopUrl;
    final box = magicListPageUrl(boxUrl ?? state.boxUrl, MagicList.box) ?? magicBoxUrl;
    final generation = ++_generation;
    final uid = currentUid();
    if (uid == null || uid <= 0) {
      _repository = null;
      emit(const MagicCenterState(loginRequired: true));
      return;
    }
    final keep = state.uid == uid ? state : MagicCenterState(uid: uid);
    emit(
      MagicCenterState(
        uid: uid,
        shop: keep.shop,
        box: keep.box,
        shopUrl: shop,
        boxUrl: box,
        loading: true,
        result: keep.result,
      ),
    );
    await _fetch(generation, uid, shop, box, keep.result);
  }

  Future<void> _fetch(int generation, int uid, String shopUrl, String boxUrl, MagicOperationResult? result) async {
    try {
      final repo = _repository ?? repository();
      final pages = await Future.wait([
        repo.fetchList(shopUrl, MagicList.shop, uid),
        repo.fetchList(boxUrl, MagicList.box, uid),
      ]);
      if (!_current(generation, uid)) return;
      _repository = repo;
      emit(
        MagicCenterState(uid: uid, shop: pages[0], box: pages[1], shopUrl: shopUrl, boxUrl: boxUrl, result: result),
      );
    } on MagicIdentityException catch (e) {
      if (!_current(generation, uid)) return;
      _repository = null;
      emit(MagicCenterState(uid: uid, loginRequired: e.guest, failed: !e.guest, result: result));
    } on MagicForumMessage catch (e) {
      if (!_current(generation, uid)) return;
      emit(MagicCenterState(uid: uid, loginRequired: e.login, message: e.message, result: result));
    } on Object {
      if (_current(generation, uid)) {
        emit(
          MagicCenterState(
            uid: uid,
            shop: state.shop,
            box: state.box,
            shopUrl: shopUrl,
            boxUrl: boxUrl,
            failed: true,
            result: result,
          ),
        );
      }
    }
  }

  /// Whether a window may be opened now.
  bool get ready =>
      !isClosed &&
      !state.busy &&
      !state.loading &&
      state.uid != null &&
      state.uid == currentUid() &&
      _repository != null;

  /// Read the buy window of [item], or the use window of the account's [item]. Null when the account changed or the
  /// page is busy; throws the window's [MagicForumMessage] or [MagicFormUnsupported].
  Future<MagicForm?> openWindow(MagicItem item, {required bool buy}) async {
    if (!ready || (!buy && item.magicId == null)) return null;
    final uid = state.uid!;
    final repo = _repository!;
    final generation = _generation;
    emit(state.copyWith(busy: true));
    try {
      final form = buy ? await repo.buyWindow(item.identifier) : await repo.useWindow(item.magicId!);
      return _current(generation, uid) ? form : null;
    } finally {
      if (_current(generation, uid)) emit(state.copyWith(busy: false));
    }
  }

  /// Post [form] once with [values], then reload both lists to show what the forum did. Never sent again.
  Future<MagicOperationResult?> submit(MagicForm form, Map<String, String> values, {required String name}) async {
    if (!ready) return null;
    final uid = state.uid!;
    final repo = _repository!;
    final generation = ++_generation;
    final buy = form.hidden['operation'] == 'buy';
    emit(state.copyWith(busy: true));
    final answer = await repo.submit(form, values);
    if (!_current(generation, uid)) return null;
    final result = MagicOperationResult(name: name, buy: buy, kind: answer.kind, message: answer.message);
    emit(
      MagicCenterState(
        uid: uid,
        shop: state.shop,
        box: state.box,
        shopUrl: state.shopUrl,
        boxUrl: state.boxUrl,
        loading: true,
        result: result,
      ),
    );
    await _fetch(generation, uid, state.shopUrl, state.boxUrl, result);
    return result;
  }
}
