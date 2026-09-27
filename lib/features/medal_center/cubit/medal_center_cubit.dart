import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/medal_center/models/medal_catalog.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Result of a state-changing medal action.
final class MedalActionResult {
  /// Constructor.
  const MedalActionResult({required this.success, this.message});

  /// Whether the server accepted the action.
  final bool success;

  /// Human-readable server message, when supplied.
  final String? message;
}

/// An immutable, account-scoped catalogue page.
final class MedalCenterState {
  /// Constructor.
  const MedalCenterState({
    this.url = medalCenterUrl,
    this.catalog,
    this.loading = false,
    this.failed = false,
    this.needLogin = false,
    this.query,
    this.returnUrl,
    this.searchForm,
  });

  /// Requested safe catalogue URL. The first page of a search is the search form's POST target.
  final String url;

  /// Active keyword search, or null while browsing the ordinary catalogue.
  final String? query;

  /// The catalogue page shown before the search began; clearing the search returns there.
  final String? returnUrl;

  /// The last search form served to this account, kept across page loads so a failed page can still search.
  final MedalSearchForm? searchForm;

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
  MedalCenterCubit({required this.fetchPage, required this.currentUid, this.submitForm})
    : super(const MedalCenterState());

  /// GET transport for catalogue pages and action forms.
  final Future<String> Function(String url) fetchPage;

  /// Form POST transport for manual-review applications.
  final Future<String> Function(String url, Map<String, String> data)? submitForm;

  /// Current account identity (null when browsing as a guest).
  final int? Function() currentUid;
  int _generation = 0;

  /// Execute a server-provided acquisition action once.
  ///
  /// The remade plugin (3.x) takes every state change as a POST: catalogue actions carry their claim form, and a
  /// manual-review application first fetches its application page to obtain the session-bound claim form, then POSTs
  /// the reason. Legacy direct actions are GET requests; the legacy manual-review flow POSTs an `applyreason` to the
  /// form's own URL. The caller should reload the catalogue after success.
  Future<MedalActionResult> performAction(CatalogMedalAction action, {String? reason}) async {
    try {
      final String body;
      final post = submitForm;
      if (action.formData case final data?) {
        if (post == null) return const MedalActionResult(success: false, message: 'form submission unavailable');
        body = await post(action.url, data);
      } else if (action.type == MedalActionType.manualReview) {
        if (post == null) return const MedalActionResult(success: false, message: 'form submission unavailable');
        final form = parseHtmlDocument(await fetchPage(action.url));
        if (form.querySelector('div.applybox') case final box?) {
          // Remade plugin: the application page carries a claim form only when this account may apply now;
          // otherwise it states why (already owned, pending review, conditions not met).
          final claim = box.querySelectorAll('form').map(medalClaimForm).nonNulls.firstOrNull;
          if (claim == null) {
            final why = medalNodeText(box.querySelector('.emp'));
            return MedalActionResult(success: false, message: why.isEmpty ? 'application unavailable' : why);
          }
          body = await post(claim.url, {...claim.data, 'reason': reason ?? ''});
        } else {
          final formHash = form.querySelector('input[name="formhash"]')?.attributes['value'];
          if (formHash == null || formHash.isEmpty) {
            return const MedalActionResult(success: false, message: 'form hash not found');
          }
          body = await post(action.url, {
            'formhash': formHash,
            'applyreason': reason ?? '',
          });
        }
      } else {
        body = await fetchPage(action.url);
      }
      return _parseActionResult(body);
    } on Exception catch (error) {
      return MedalActionResult(success: false, message: error.toString());
    }
  }

  MedalActionResult _parseActionResult(String body) {
    final document = parseHtmlDocument(body);
    final errorNode = document.querySelector('.alert_error');
    final messageNode = document.querySelector('#messagetext');
    // The message paragraph carries a redirect script and is followed by a fallback link; keep the text only.
    String messageOf(uh.Element node) => medalNodeText(node.querySelector('p') ?? node);
    if (errorNode != null) {
      return MedalActionResult(success: false, message: messageOf(errorNode));
    }
    if (messageNode == null || messageOf(messageNode).isEmpty) {
      return const MedalActionResult(success: false, message: 'server returned an unrecognised response');
    }
    return MedalActionResult(success: true, message: messageOf(messageNode));
  }

  /// Clear account-specific eligibility while authentication changes.
  void invalidate() {
    _generation++;
    emit(const MedalCenterState(loading: true));
  }

  /// Fetch an allowed category/page; all purchase/apply URLs are rejected.
  ///
  /// Without [target] the current page is reloaded, including the first page of an active search. A category or
  /// ordinary page link leaves the search, as it does on the website; a search result page link keeps it.
  Future<void> load([String? target]) async {
    if (target == null && state.query != null && !_isSearchPage(state.url)) {
      await search(state.query!);
      return;
    }
    final url = medalCatalogUrl(target ?? state.url);
    if (url == null) return;
    final sq = Uri.parse(url).queryParameters['sq'];
    final query = sq == null ? null : medalSearchQuery(sq);
    await _fetch(
      url: url,
      query: query,
      returnUrl: query == null ? null : _returnUrl,
      request: () => fetchPage(url),
    );
  }

  /// Search the whole catalogue by medal name or description through the forum's own search form.
  ///
  /// Blank text returns to the ordinary catalogue.
  Future<void> search(String text) async {
    final query = text.trim();
    if (query.isEmpty) {
      await clearSearch();
      return;
    }
    final form = state.searchForm;
    final post = submitForm;
    if (form == null || post == null) {
      // No form to post (never served, or no transport): an active search degrades to the catalogue it came from.
      if (state.query != null) await load(_returnUrl);
      return;
    }
    await _fetch(
      url: form.url,
      query: query,
      returnUrl: _returnUrl,
      request: () => post(form.url, form.body(query)),
    );
  }

  /// Leave the search and show the category page that was open before it.
  Future<void> clearSearch() async {
    if (state.query == null) return;
    await load(_returnUrl);
  }

  bool _isSearchPage(String url) => Uri.parse(url).queryParameters.containsKey('sq');

  String get _returnUrl => state.returnUrl ?? (state.query == null ? state.url : medalCenterUrl);

  Future<void> _fetch({
    required String url,
    required String? query,
    required String? returnUrl,
    required Future<String> Function() request,
  }) async {
    final generation = ++_generation;
    final uid = currentUid();
    final form = state.searchForm;
    MedalCenterState next({
      MedalCatalog? catalog,
      bool loading = false,
      bool failed = false,
      bool needLogin = false,
    }) => MedalCenterState(
      url: url,
      query: query,
      returnUrl: returnUrl,
      searchForm: catalog?.searchForm ?? form,
      catalog: catalog,
      loading: loading,
      failed: failed,
      needLogin: needLogin,
    );
    emit(next(loading: true));
    try {
      final document = parseHtmlDocument(await request());
      if (isClosed || generation != _generation || currentUid() != uid) return;
      final servedUid = parseLoggedUidFromDocument(document);
      if (uid != null && servedUid == null) {
        emit(next(needLogin: true));
      } else if (servedUid != uid) {
        emit(next(failed: true));
      } else {
        emit(next(catalog: parseMedalCatalog(document)));
      }
    } on Exception {
      if (!isClosed && generation == _generation && currentUid() == uid) {
        emit(next(failed: true));
      }
    }
  }
}
