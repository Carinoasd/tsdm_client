part of 'models.dart';

/// Result of a search action.
@MappableClass()
class SearchResult with SearchResultMappable {
  /// Constructor.
  const SearchResult({
    required this.currentPage,
    required this.totalPages,
    required this.count,
    required this.data,
    this.fullText,
  });

  /// Current search result page number.
  final int currentPage;

  /// Total search result page numbers.
  final int totalPages;

  /// Search result count;
  final int? count;

  /// Thread list.
  final List<SearchedThread>? data;

  /// Whether the forum searched the full text (the `fulltext` of a structured answer): false when it searched the
  /// titles only, also when the full text was asked for and the user group may not search it. Null when the answer
  /// does not tell (the web page, an older plugin).
  final bool? fullText;

  /// Parse the search result page.
  ///
  /// Discuz X5 built-in search:
  ///
  /// ```html
  /// <div class="sttl mbn"><h2>结果: <em>找到 “<span class="emfont">天使</span>” 相关内容 1500 个</em></h2></div>
  /// <div class="slst mtw" id="threadlist"><ul><li class="pbw" id="TID">...</li></ul></div>
  /// <div class="pgs cl mbm"><div class="pg">...</div></div>
  /// ```
  // ignore: prefer_constructors_over_static_methods
  static SearchResult fromDocument(uh.Document document) {
    var threadList = document
        .querySelectorAll('div#threadlist li.pbw')
        .map(SearchedThread.fromLiNode)
        .whereType<SearchedThread>()
        .toList();
    if (threadList.isEmpty) {
      // Old plugin layout.
      threadList = document
          .querySelectorAll('div#ct > div#ct_shell > div#left_s > div.ts_se_rs')
          .map(SearchedThread.fromDivNode)
          .whereType<SearchedThread>()
          .toList();
    }

    // "找到 “天使” 相关内容 1500 个"
    final countText = document.querySelector('div.sttl h2 > em')?.innerText;
    final count =
        (countText == null ? null : _countRe.firstMatch(countText)?.namedGroup('count')?.parseToInt()) ??
        // Old plugin: filter out "Results about: ".
        document.querySelector('h3')?.firstEndDeepText()?.split(' ').firstOrNull?.parseToInt();

    final currentPage = document.currentPage() ?? 1;
    final totalPages = document.totalPages() ?? currentPage;

    return SearchResult(currentPage: currentPage, totalPages: totalPages, count: count, data: threadList);
  }

  static final _countRe = RegExp(r'相关内容 (?<count>\d+) 个');

  static final _searchIdRe = RegExp(r'searchid=(?<id>\d+)');

  /// Parse the search id in [document].
  ///
  /// Found in pagination links or the advanced search link:
  ///
  /// ```html
  /// <a href="search.php?mod=forum&searchid=766&orderby=lastpost&ascdesc=desc&searchsubmit=yes&amp;page=2">2</a>
  /// <a href="search.php?mod=forum&amp;adv=yes&orderby=lastpost&ascdesc=desc&searchid=766&searchsubmit=yes">高级</a>
  /// ```
  ///
  /// Marked as public for testing.
  static String? parseSearchId(uh.Document document) {
    for (final a in document.querySelectorAll('a[href*="searchid="]')) {
      final id = _searchIdRe.firstMatch(a.attributes['href'] ?? '')?.namedGroup('id');
      if (id != null) {
        return id;
      }
    }
    return null;
  }
}
