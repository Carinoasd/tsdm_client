import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/repository/model/models.dart';
import 'package:tsdm_client/features/points/repository/points_repository.dart';
import 'package:tsdm_client/features/points/utils/credit_page_api.dart';
import 'package:tsdm_client/features/points/utils/parse_points.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'points_bloc.mapper.dart';

part 'points_event.dart';

part 'points_state.dart';

/// Statistics emitter.
typedef PointsStatisticsEmitter = Emitter<PointsStatisticsState>;

/// Changelog emitter.
typedef PointsChangelogEmitter = Emitter<PointsChangelogState>;

/// Bloc of user points statistics page.
final class PointsStatisticsBloc extends Bloc<PointsStatisticsEvent, PointsStatisticsState> with LoggerMixin {
  /// Constructor.
  PointsStatisticsBloc({required PointsRepository pointsRepository})
    : _pointsRepository = pointsRepository,
      super(const PointsStatisticsState()) {
    on<PointsStatisticsRefreshRequested>(_onPointsStatisticsRefreshRequested);
  }

  final PointsRepository _pointsRepository;

  Future<void> _onPointsStatisticsRefreshRequested(
    PointsStatisticsRefreshRequested event,
    PointsStatisticsEmitter emit,
  ) async {
    // Points on screen stay while they are asked again, and when that fails (the page says so).
    final shown = state.status == PointsStatus.success && state.pointsMap.isNotEmpty;
    emit(
      shown
          ? state.copyWith(refreshing: true, failure: null)
          : state.copyWith(status: PointsStatus.loading, failure: null),
    );
    void failed(LoadFailure failure) => emit(
      shown
          ? state.copyWith(refreshing: false, failure: failure)
          : state.copyWith(status: PointsStatus.failed, failure: failure),
    );
    await _pointsRepository
        .fetchStatisticsPage()
        .match(
          (e) {
            handle(e);
            error('failed to fetch points statistics page: $e');
            failed(LoadFailure.of(e));
          },
          (v) {
            final document = v;
            final result = parseStatisticsDocument(document);
            if (result == null) {
              // The forum's page without the points: its message (a guest, a closed forum) when it has one.
              final message = document.querySelector('div#messagetext > p')?.innerText.trim();
              failed(
                message == null || message.isEmpty
                    ? LoadFailure(LoadFailureKind.unknown)
                    : LoadFailure.fromMessage(message),
              );
              return;
            }
            emit(
              state.copyWith(
                status: PointsStatus.success,
                pointsMap: result.$1,
                recentChangelog: result.$2,
                refreshing: false,
                failure: null,
              ),
            );
          },
        )
        .run();
  }
}

/// Bloc of the points changelog page.
final class PointsChangelogBloc extends Bloc<PointsChangelogEvent, PointsChangelogState> with LoggerMixin {
  /// Constructor.
  PointsChangelogBloc({required PointsRepository pointsRepository})
    : _pointsRepository = pointsRepository,
      super(const PointsChangelogState()) {
    on<PointsChangelogRefreshRequested>(_onPointsChangelogRefreshRequested);
    on<PointsChangelogLoadMoreRequested>(_onPointsChangelogLoadMoreRequested);
    on<PointsChangelogQueryRequested>(_onPointsChangelogQueryRequested);
  }

  /// Repository of changelog.
  final PointsRepository _pointsRepository;

  /// Bumped by every load of the first page (a refresh, a query): a next page asked for the list before is dropped
  /// instead of being added to the new one.
  int _generation = 0;

  Future<void> _onPointsChangelogRefreshRequested(
    PointsChangelogRefreshRequested event,
    PointsChangelogEmitter emit,
  ) async {
    // The records on screen stay while the first page is asked again, and when that fails (the page says so).
    final shown = state.status == PointsStatus.success && state.fullChangelog.isNotEmpty;
    if (shown && state.refreshing) {
      return;
    }
    await _loadFirstPage(emit, parameter: state.parameter, keep: shown);
  }

  Future<void> _onPointsChangelogLoadMoreRequested(
    PointsChangelogLoadMoreRequested event,
    PointsChangelogEmitter emit,
  ) async {
    // Nothing more, or already on its way: the end of the list may ask more than once.
    if (state.status != PointsStatus.success ||
        state.loadingMore ||
        state.refreshing ||
        state.currentPage >= state.totalPages) {
      return;
    }
    final generation = _generation;
    final pageNumber = state.currentPage + 1;
    emit(state.copyWith(loadingMore: true, loadMoreFailed: false));
    final result = await _pointsRepository.fetchChangelogPage(state.parameter.copyWith(pageNumber: pageNumber)).run();
    if (generation != _generation) {
      return;
    }
    // The records loaded before stay whatever happens; a failure is told at the end of the list.
    switch (result) {
      case Left(:final value):
        handle(value);
        error('failed to load more points changelog: $value');
        emit(state.copyWith(loadingMore: false, loadMoreFailed: true, failure: LoadFailure.of(value)));
      case Right(:final value):
        final page = _pageOf(value, pageNumber);
        if (page == null) {
          emit(state.copyWith(loadingMore: false, loadMoreFailed: true, failure: _unreadable(value)));
          return;
        }
        emit(
          state.copyWith(
            fullChangelog: [...state.fullChangelog, ...page.changes],
            currentPage: page.currentPage,
            totalPages: page.totalPages,
            loadingMore: false,
            failure: null,
          ),
        );
    }
  }

  Future<void> _onPointsChangelogQueryRequested(
    PointsChangelogQueryRequested event,
    PointsChangelogEmitter emit,
  ) async {
    // Another query: the records of the previous one go.
    await _loadFirstPage(emit, parameter: event.parameter, keep: false);
  }

  /// Load the first page of the records with [parameter]: in place of the records shown when [keep] (a refresh, which
  /// keeps them when it fails), else from an empty list.
  Future<void> _loadFirstPage(
    PointsChangelogEmitter emit, {
    required ChangelogParameter parameter,
    required bool keep,
  }) async {
    final generation = ++_generation;
    emit(
      keep
          ? state.copyWith(refreshing: true, loadingMore: false, loadMoreFailed: false, failure: null)
          : state.copyWith(
              status: PointsStatus.loading,
              fullChangelog: [],
              parameter: parameter,
              refreshing: false,
              loadingMore: false,
              loadMoreFailed: false,
              failure: null,
            ),
    );
    final result = await _pointsRepository.fetchChangelogPage(parameter.copyWith(pageNumber: 1)).run();
    if (generation != _generation) {
      return;
    }
    void failed(LoadFailure failure) => emit(
      keep
          ? state.copyWith(refreshing: false, failure: failure)
          : state.copyWith(status: PointsStatus.failed, failure: failure),
    );
    switch (result) {
      case Left(:final value):
        handle(value);
        error('failed to load the first page of the points changelog: $value');
        failed(LoadFailure.of(value));
      case Right(:final value):
        final page = _pageOf(value, 1);
        if (page == null) {
          failed(_unreadable(value));
          return;
        }
        emit(
          state.copyWith(
            status: PointsStatus.success,
            fullChangelog: page.changes,
            currentPage: page.currentPage,
            totalPages: page.totalPages,
            allParameters: _allParametersOf(value),
            refreshing: false,
            failure: null,
          ),
        );
    }
  }

  /// The records of the page [answer] and where it is in the list: the structured answer of the forum's app API
  /// (plugin 2.5.0) built from its fields ([pointsChangelogFromApi]), the web page (or an older plugin's answer)
  /// parsed as before. [pageNumber] is the page asked, the fallback when the answer names none. Null for a page
  /// without the records (the forum's message to a guest, another page).
  ({List<PointsChange> changes, int currentPage, int totalPages})? _pageOf(TsdmAppPageAnswer answer, int pageNumber) {
    switch (answer) {
      case TsdmAppStructuredPage(:final json):
        final page = pointsChangelogFromApi(json, fallbackPage: pageNumber);
        if (page == null) {
          error('points change log not in the answer');
          return null;
        }
        return (changes: page.changes, currentPage: page.currentPage, totalPages: page.totalPages);
      case TsdmAppWebPage(:final document):
        final tableNode = document.querySelector('table.dt');
        if (tableNode == null) {
          error('points change table not found');
          return null;
        }
        return (
          changes: buildChangeListFromTable(tableNode),
          currentPage: document.currentPage() ?? pageNumber,
          totalPages: document.totalPages() ?? pageNumber,
        );
    }
  }

  /// Why the page [answer] has no records: the forum's message when it gave one (a guest asked to log in), else an
  /// answer the app could not read.
  LoadFailure _unreadable(TsdmAppPageAnswer answer) {
    final message = switch (answer) {
      TsdmAppStructuredPage(:final json) => tsdmAppText(json['message']),
      TsdmAppWebPage(:final document) => document.querySelector('div#messagetext > p')?.innerText.trim() ?? '',
    };
    return message.isEmpty
        ? LoadFailure(LoadFailureKind.unknown, details: 'points changelog not in the answer')
        : LoadFailure.fromMessage(message);
  }

  /// The filters of the query form of the page [answer]: of the structured answer, or of the web page as before.
  ChangelogAllParameters _allParametersOf(TsdmAppPageAnswer answer) => switch (answer) {
    TsdmAppStructuredPage(:final json) => changelogParametersFromApi(json),
    TsdmAppWebPage(:final document) => parseAllParameters(document),
  };
}
