import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/medal_center/models/medal_catalog.dart';
import 'package:universal_html/parsing.dart';

/// An immutable, account-scoped catalogue page.
final class MedalCenterState {
  /// Constructor.
  const MedalCenterState({
    this.url = medalCenterUrl,
    this.catalog,
    this.loading = false,
    this.failed = false,
    this.needLogin = false,
  });

  /// Requested safe catalogue URL.
  final String url;

  /// Fresh catalogue, never reused across account changes.
  final MedalCatalog? catalog;

  /// Loading state.
  final bool loading;

  /// Failed GET, retryable without side effects.
  final bool failed;

  /// The previously authenticated account's session expired.
  final bool needLogin;
}

/// Read-only loader with request-generation and server identity checks.
class MedalCenterCubit extends Cubit<MedalCenterState> {
  /// [fetchPage] must use the app's identity-bound network client.
  MedalCenterCubit({required this.fetchPage, required this.currentUid}) : super(const MedalCenterState());

  /// GET transport. There is deliberately no submission transport.
  final Future<String> Function(String url) fetchPage;

  /// Current account identity (null when browsing as a guest).
  final int? Function() currentUid;
  int _generation = 0;

  /// Clear account-specific eligibility while authentication changes.
  void invalidate() {
    _generation++;
    emit(const MedalCenterState(loading: true));
  }

  /// Fetch an allowed category/page; all purchase/apply URLs are rejected.
  Future<void> load([String? target]) async {
    final url = medalCatalogUrl(target ?? state.url);
    if (url == null) return;
    final generation = ++_generation;
    final uid = currentUid();
    emit(MedalCenterState(url: url, loading: true));
    try {
      final document = parseHtmlDocument(await fetchPage(url));
      if (isClosed || generation != _generation || currentUid() != uid) return;
      final servedUid = parseLoggedUidFromDocument(document);
      if (uid != null && servedUid == null) {
        emit(MedalCenterState(url: url, needLogin: true));
      } else if (servedUid != uid) {
        emit(MedalCenterState(url: url, failed: true));
      } else {
        emit(MedalCenterState(url: url, catalog: parseMedalCatalog(document)));
      }
    } on Exception {
      if (!isClosed && generation == _generation && currentUid() == uid) {
        emit(MedalCenterState(url: url, failed: true));
      }
    }
  }
}
