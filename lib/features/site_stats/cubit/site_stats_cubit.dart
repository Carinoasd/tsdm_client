import 'package:bloc/bloc.dart';
import 'package:tsdm_client/features/site_stats/models/site_stats.dart';
import 'package:tsdm_client/features/site_stats/repository/site_stats_repository.dart';
import 'package:tsdm_client/utils/load_failure.dart';

/// Status of a statistics page.
enum SiteStatsStatus {
  /// First load of the url on its way.
  loading,

  /// Loaded.
  success,

  /// Failed, nothing shown: the forum's message (no permission) or a failed request.
  failed,
}

/// State of a statistics page.
final class SiteStatsState {
  /// Constructor.
  const SiteStatsState({
    required this.url,
    this.status = SiteStatsStatus.loading,
    this.page,
    this.failure,
    this.refreshing = false,
    this.tabs = const [],
  });

  /// The url shown.
  final String url;

  /// Status.
  final SiteStatsStatus status;

  /// The page shown.
  final SiteStatsData? page;

  /// Why the last load failed: the whole page ([SiteStatsStatus.failed]) or a refresh that kept [page] shown.
  final LoadFailure? failure;

  /// [page] is asked again while it stays on screen.
  final bool refreshing;

  /// The tabs of the last page loaded: kept while another tab loads, and when the forum refuses that one, so that
  /// the others stay a tap away.
  final List<SiteStatsLink> tabs;
}

/// Loads a page of the forum's statistics, and the other pages it links to in its place (its tabs, months, pages).
final class SiteStatsCubit extends Cubit<SiteStatsState> {
  /// Constructor.
  SiteStatsCubit({required String url, required SiteStatsRepository repository})
    : _repository = repository,
      super(SiteStatsState(url: url));

  final SiteStatsRepository _repository;

  /// Bumped by every load: an answer to an older one is dropped.
  int _generation = 0;

  /// Load the url shown; the page shown stays while it is asked again, and when that fails.
  Future<void> load() async {
    final generation = ++_generation;
    final shown = state.status == SiteStatsStatus.success;
    emit(
      shown
          ? SiteStatsState(url: state.url, status: state.status, page: state.page, refreshing: true, tabs: state.tabs)
          : SiteStatsState(url: state.url, tabs: state.tabs),
    );
    final result = await _repository.fetch(state.url).run();
    if (isClosed || generation != _generation) {
      return;
    }
    result.match(
      (e) => emit(
        shown
            ? SiteStatsState(
                url: state.url,
                status: state.status,
                page: state.page,
                failure: LoadFailure.of(e),
                tabs: state.tabs,
              )
            : SiteStatsState(
                url: state.url,
                status: SiteStatsStatus.failed,
                failure: LoadFailure.of(e),
                tabs: state.tabs,
              ),
      ),
      (page) => emit(
        SiteStatsState(
          url: state.url,
          status: SiteStatsStatus.success,
          page: page,
          tabs: page.tabs.isNotEmpty ? page.tabs : state.tabs,
        ),
      ),
    );
  }

  /// Show [url] in place of the page shown (another tab, month or page of the same list).
  Future<void> open(String url) async {
    if (url == state.url && state.status != SiteStatsStatus.failed) {
      return;
    }
    // Another page: the one shown is not kept while it loads.
    emit(SiteStatsState(url: url, tabs: state.tabs));
    await load();
  }
}
