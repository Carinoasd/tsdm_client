part of 'models.dart';

/// How far back a search looks (`srchfrom`, seconds before now, matched against the time of the last post of a
/// thread), the choices of the forum's own advanced search form (`template/default/search/forum_adv.php`).
@MappableEnum()
enum SearchTimeRange {
  /// Any time, `srchfrom` not sent.
  all(0),

  /// The last day.
  day(86400),

  /// The last week.
  week(604800),

  /// The last month (30 days).
  month(2592000),

  /// The last three months (90 days).
  threeMonths(7776000),

  /// The last half year (180 days).
  halfYear(15552000),

  /// The last year (365 days).
  year(31536000)
  ;

  const SearchTimeRange(this.seconds);

  /// Value of `srchfrom`.
  final int seconds;
}

/// The order of the results (`orderby`): the only ones the forum takes, any other value is the last post
/// (`app/search/module/forum.php`: `in_array($orderby, ['dateline', 'replies', 'views']) ? … : 'lastpost'`). There
/// is no order by relevance.
@MappableEnum()
enum SearchOrderBy {
  /// Time of the last post, the forum's default.
  lastpost,

  /// Time the thread was posted.
  dateline,

  /// Count of replies.
  replies,

  /// Count of views.
  views,
}

/// The filters of a search besides the keyword, the author and the forums: the time range, the order and whether
/// only the titles are searched.
///
/// The forum keeps the order out of the search itself (a new search in another order reuses the same search id), it
/// is sent with every page of the results instead.
@MappableClass()
final class SearchFilter with SearchFilterMappable {
  /// Constructor.
  const SearchFilter({
    this.timeRange = SearchTimeRange.all,
    this.orderBy = SearchOrderBy.lastpost,
    this.ascending = false,
    this.titleOnly = true,
  });

  /// How far back to look.
  final SearchTimeRange timeRange;

  /// Order of the results.
  final SearchOrderBy orderBy;

  /// Ascending order (`ascdesc=asc`), descending otherwise.
  final bool ascending;

  /// Search the titles only (`srchtype=title`, the forum's default). Off asks for the full text
  /// (`srchtype=fulltext`), which the forum turns back into a title search for a group without that permission.
  final bool titleOnly;

  /// Value of `orderby`.
  String get orderByValue => orderBy.name;

  /// Value of `ascdesc`.
  String get ascDescValue => ascending ? 'asc' : 'desc';
}
