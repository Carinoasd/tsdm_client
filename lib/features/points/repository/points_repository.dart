import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/repository/model/models.dart';
import 'package:tsdm_client/features/points/utils/changelog_range.dart';
import 'package:tsdm_client/features/points/utils/credit_page_api.dart';
import 'package:tsdm_client/features/points/utils/parse_points.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

/// Repository of points statistics page and points changelog page.
///
/// Both pages are asked in the JSON mode of the forum's app API (plugin 1.7.0): the forum answers the blocks the parsers
/// read (the main column `#ct` with the points, the changelog table, its filters and pages) without header, footer and
/// sidebar. With an older plugin the parameter is ignored and the web page comes back, parsed as before. Plugin 2.5.0
/// answers the changelog page (`op=log`) as structured fields (`schema: 12`, [creditApiAnswerOf]), kept as a
/// [TsdmAppStructuredPage] for `pointsChangelogFromApi`; the statistics page (`op=base`) is still read from its
/// blocks.
final class PointsRepository with LoggerMixin {
  /// Constructor.
  PointsRepository({this.currentUid});

  static const _statisticsPageUrl = '$baseUrl/home.php?mod=spacecp&ac=credit&op=base';
  static const _changelogPageUrl = '$baseUrl/home.php?mod=spacecp&op=log&ac=credit';

  /// Fetch the points statistics page.
  ///
  /// A JSON answer without a page ([tsdmAppAnswerWithoutPage]: the plugin failed to build it, or an empty body) is a
  /// failed request, not a page without points ([TsdmAppPageHttpExt.mapHttpPage]).
  AsyncEither<uh.Document> fetchStatisticsPage() =>
      getIt.get<NetClientProvider>().get(withTsdmAppJson(_statisticsPageUrl)).mapHttpPage((document) => document);

  /// Fetch the points statistics: the structured page of plugin 4.0.0 (`credit_base`, `schema` 52,
  /// [pointsStatisticsFromApi]) when the forum's plugin lists it, the web page ([fetchStatisticsPage],
  /// `parseStatisticsDocument`) otherwise and whenever the plugin's answer is not that page. The right of the result is
  /// the statistics, or the forum's message instead of them (empty when it printed none).
  AsyncEither<Either<String, PointsStatistics>> fetchStatistics() => AsyncEither(() async {
    final client = getIt.get<NetClientProvider>();
    await TsdmAppApi.ensureStatus(client);
    if (TsdmAppV4.has(TsdmAppV4Group.creditPages, 'credit_base')) {
      final uid = (currentUid ?? currentLoginUid)();
      switch (await fetchTsdmAppV4Page(client, _statisticsPageUrl, type: 'credit_base', schema: 52, uid: uid).run()) {
        case Left(:final value):
          return left(value);
        case Right(value: TsdmAppV4Page(:final json)):
          return right(right(pointsStatisticsFromApi(json)));
        case Right(value: TsdmAppV4Message(:final reason)) when reason.isNotEmpty:
          return right(left(reason));
        case Right():
          break;
      }
    }
    return fetchStatisticsPage().map((document) {
      if (parseStatisticsDocument(document) case (final points, final changes)) {
        return right<String, PointsStatistics>((points: points, changes: changes));
      }
      // The forum's page without the points: its message (a guest, a closed forum) when it has one.
      return left<String, PointsStatistics>(document.querySelector('div#messagetext > p')?.innerText.trim() ?? '');
    }).run();
  });

  /// The account the pages are asked for, the one logged in when null (tests inject their own).
  final int Function()? currentUid;

  /// Fetch the points changelog page with given [parameter]: the structured answer ([TsdmAppStructuredPage]) or the
  /// web page ([TsdmAppWebPage]), which parses as before. An answer without a page is a failed request, not a page
  /// without changes ([TsdmAppPageHttpExt.mapHttpPageAnswer]).
  AsyncEither<TsdmAppPageAnswer> fetchChangelogPage(ChangelogParameter parameter) => getIt
      .get<NetClientProvider>()
      .get(withTsdmAppJson('$_changelogPageUrl$parameter'))
      .mapHttpPageAnswer(creditApiAnswerOf);

  /// Fetch the records of the days [start] to [end] (both included, the forum's calendar days), newest first: the
  /// pages of the changelog filtered by that range, at most [maxPages] of them. `complete` of the result tells
  /// whether the last page was reached.
  ///
  /// The changelog has no filter for one kind of record (a check-in names no operation), so a chart of one kind reads
  /// the range and picks from it.
  Future<Either<LoadFailure, RangedChangelog>> fetchChangelogRange({
    required DateTime start,
    required DateTime end,
    int maxPages = 30,
  }) async {
    final base = const ChangelogParameter.empty().copyWith(
      startTime: changelogQueryDate(start),
      endTime: changelogQueryDate(end),
    );
    final changes = <PointsChange>[];
    var page = 1;
    var totalPages = 1;
    while (page <= totalPages && page <= maxPages) {
      final result = await fetchChangelogPage(base.copyWith(pageNumber: page)).run();
      switch (result) {
        case Left(:final value):
          handle(value);
          return Left(LoadFailure.of(value));
        case Right(:final value):
          final records = changelogRecordsOf(value, page);
          if (records == null) {
            return Left(LoadFailure(LoadFailureKind.unknown, details: 'points changelog not in the answer'));
          }
          changes.addAll(records.changes);
          totalPages = records.totalPages;
      }
      page += 1;
    }
    DateTime? oldest;
    for (final change in changes) {
      if (oldest == null || change.time.isBefore(oldest)) {
        oldest = change.time;
      }
    }
    return Right((changes: changes, complete: page > totalPages, oldest: oldest));
  }
}

/// The records of a range of the points changelog, newest first.
///
/// `oldest` is the time of the oldest record read (null without any): when the range was cut at the page limit,
/// whatever is older than it is missing.
typedef RangedChangelog = ({List<PointsChange> changes, bool complete, DateTime? oldest});
