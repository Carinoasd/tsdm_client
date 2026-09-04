import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

final _typeIDRe = RegExp(r'&typeid=(?<id>\d+)');
final _specialTypeRe = RegExp('&specialtype=(?<type>[a-z]+)');
final _orderByRe = RegExp('&orderby=(?<orderby>[a-z]+)');
final _datelineRe = RegExp(r'&dateline=(?<dateline>\d+)');

/// Data parsed from a forum page html document (`forum.php?mod=forumdisplay&fid=xxx`).
///
/// Pure data, the bloc merges it into its state.
final class ForumPageData {
  /// Constructor.
  const ForumPageData({
    required this.title,
    required this.rulesElement,
    required this.normalThreadList,
    required this.stickThreadList,
    required this.subredditList,
    required this.needLogin,
    required this.havePermission,
    required this.permissionDeniedMessage,
    required this.canLoadMore,
    required this.currentPage,
    required this.totalPages,
    required this.filterTypeList,
    required this.filterSpecialTypeList,
    required this.filterOrderList,
    required this.filterDatelineList,
  });

  /// Forum title.
  final String? title;

  /// Html element of forum rules node.
  final uh.Element? rulesElement;

  /// Normal threads in current page.
  final List<NormalThread> normalThreadList;

  /// Pinned threads in current page.
  final List<StickThread> stickThreadList;

  /// Subreddits in current forum.
  final List<Forum> subredditList;

  /// Need login to access this forum.
  final bool needLogin;

  /// Have permission to access this forum.
  final bool havePermission;

  /// Message node when permission denied.
  final uh.Element? permissionDeniedMessage;

  /// Can load more pages.
  final bool canLoadMore;

  /// Current page number, null if not found.
  final int? currentPage;

  /// Total pages count, null if not found.
  final int? totalPages;

  /// Available thread type filters.
  final List<FilterType> filterTypeList;

  /// Available special type filters.
  final List<FilterSpecialType> filterSpecialTypeList;

  /// Available order filters.
  final List<FilterOrder> filterOrderList;

  /// Available dateline filters.
  final List<FilterDateline> filterDatelineList;
}

/// Parse the forum page [document] of forum [fid].
ForumPageData parseForumPage(uh.Document document, String fid) {
  final rulesElement = document.querySelector('div#forum_rules_$fid');
  final title = document.querySelector('div#ct h1.xs2 > a')?.innerText.trim();
  final normalThreadList = _buildThreadList<NormalThread>(document, 'normalthread', NormalThread.fromTBody);

  // Always parse the latest result of pinned contents.
  // As we allow direct access from url and thread page header, where has no complete pinned contents recorded
  // before first visit, it becomes much more complex if we still want to preserve the old behavior which reserved
  // the complete result when accessing without filters.
  //
  // Always parse it and use it if necessary.
  final stickThreadList = _buildThreadList<StickThread>(document, 'stickthread', StickThread.fromTBody);
  final subredditList = _buildForumList(document, fid);

  var needLogin = false;
  var havePermission = true;
  uh.Element? permissionDeniedMessage;
  if (normalThreadList.isEmpty && subredditList.isEmpty) {
    // Here both normal thread list and subreddit is empty, check permission.
    //
    // <div id="messagetext" class="alert_info"><p>抱歉，您尚未登录，没有权限访问该版块</p></div>
    // <div id="messagelogin"></div>   <- Only present when need login.
    final docMessage = document.getElementById('messagetext');
    final docLogin = document.getElementById('messagelogin');
    if (docLogin != null) {
      needLogin = true;
    } else if (docMessage != null) {
      havePermission = false;
      permissionDeniedMessage = docMessage.querySelector('p');
    }
  }

  final canLoadMore = checkCanLoadMore(document);
  final currentPage = document.currentPage();
  final totalPages = document.totalPages();

  // Update thread filter config.
  final filterTypeList =
      document
          .querySelector('ul#thread_types')
          ?.querySelectorAll('li > a')
          .where((e) => e.innerText.isNotEmpty)
          .map(
            (e) => FilterType(
              name: e.innerText.trim(),
              typeID: _typeIDRe.firstMatch(e.attributes['href'] ?? '')?.namedGroup('id'),
            ),
          )
          .toList() ??
      const [];

  final filterSpecialTypeList =
      document
          .querySelector('div#filter_special_menu')
          ?.querySelectorAll('ul > li > a')
          .where((e) => e.innerText.isNotEmpty)
          .map(
            (e) => FilterSpecialType(
              name: e.innerText.trim(),
              specialType: _specialTypeRe.firstMatch(e.attributes['href'] ?? '')?.namedGroup('type'),
            ),
          )
          .toList() ??
      const [];

  final filterOrderList =
      document
          .querySelector('div#filter_orderby_menu')
          ?.querySelectorAll('ul > li > a')
          .where((e) => e.innerText.isNotEmpty)
          .map(
            (e) => FilterOrder(
              name: e.innerText.trim(),
              orderBy: _orderByRe.firstMatch(e.attributes['href'] ?? '')?.namedGroup('orderby'),
            ),
          )
          .toList() ??
      const [];

  // X5: the dateline menu also carries a row of "排序" (order by) links (filter=author/reply), only keep the
  // dateline ones (filter=dateline).
  final filterDatelineList =
      document
          .querySelector('div#filter_dateline_menu')
          ?.querySelectorAll('ul > li > a')
          .where((e) => e.innerText.isNotEmpty)
          .where((e) => e.attributes['href']?.contains('filter=dateline') ?? true)
          .map(
            (e) => FilterDateline(
              name: e.innerText.trim(),
              dateline: _datelineRe.firstMatch(e.attributes['href'] ?? '')?.namedGroup('dateline'),
            ),
          )
          .toList() ??
      const [];

  return ForumPageData(
    title: title,
    rulesElement: rulesElement,
    normalThreadList: normalThreadList,
    stickThreadList: stickThreadList,
    subredditList: subredditList,
    needLogin: needLogin,
    havePermission: havePermission,
    permissionDeniedMessage: permissionDeniedMessage,
    canLoadMore: canLoadMore,
    currentPage: currentPage,
    totalPages: totalPages,
    filterTypeList: filterTypeList,
    filterSpecialTypeList: filterSpecialTypeList,
    filterOrderList: filterOrderList,
    filterDatelineList: filterDatelineList,
  );
}

/// Build a list of thread from given html [document].
///
/// [threadKind] is "normalthread" or "stickthread".
///
/// * X5: `<tbody id="normalthread_xxx">`.
/// * Legacy: `<tbody id="normalthread_xxx" class="tsdm_normalthread">`.
List<T> _buildThreadList<T extends NormalThread>(
  uh.Document document,
  String threadKind,
  T? Function(uh.Element element) threadBuilder,
) {
  var tbodyList = document.querySelectorAll('tbody[id^="${threadKind}_"]');
  if (tbodyList.isEmpty) {
    tbodyList = document.querySelectorAll('tbody.tsdm_$threadKind');
  }
  return tbodyList.map((e) => threadBuilder(e)).whereType<T>().toList();
}

/// Build a list of [Forum] from given [document].
///
/// <div id="subforum_702" class="bm_c">
///   <table class="fl_tb">
///     <tr><td class="fl_icn">...</td><td><h2>...</h2></td><td class="fl_i">...</td><td class="fl_by">...</td></tr>
///     <tr class="fl_row"></tr>   <- X5 has an empty trailing row
///   </table>
/// </div>
List<Forum> _buildForumList(uh.Document document, String fid) {
  final subredditRootNode = document.querySelector('div#subforum_$fid');
  if (subredditRootNode == null) {
    return [];
  }

  return subredditRootNode
      .querySelectorAll('table > tbody > tr')
      .where((e) => e.children.isNotEmpty)
      .map(Forum.fromFlRowNode)
      .whereType<Forum>()
      .toList();
}

/// Check whether in the last page in a web page (consists a series of pages).
///
/// X5: a "next page" link exists in pagination indicator node when not in the last page.
///
/// <div class="pgt">
///   <div class="pg">
///     <strong>1</strong><a>2</a><a>3</a>
///     <label><input name="custompage"/><span title="共 3 页"> / 3 页</span></label>
///     <a class="nxt">下一页</a>     <- Absent when in the last page
///   </div>
/// </div>
///
/// Legacy: when already in the last page, current page mark (the <strong> node) is
/// the last child of pagination indicator node.
///
/// <div class="pgt">
///   <div class="pg">
///     <a class="url_to_page1"></a>
///     <a class="url_to_page2"></a>
///     <a class="url_to_page3"></a>
///     <strong>4</strong>           <-  Here we are in the last page
///   </div>
/// </div>
///
/// Typically when the web page only have one page, there is no pg node:
///
/// <div class="pgt">
///   <span>...</span>
/// </div>
///
/// Indicating can not load more.
bool checkCanLoadMore(uh.Document document) {
  final barNode = document.getElementById('pgt');

  if (barNode == null) {
    talker.error('failed to check can load more: node not found');
    return false;
  }

  final paginationNode = barNode.querySelector('div.pg');
  if (paginationNode == null) {
    // Only one page, can not load more.
    return false;
  }

  return paginationNode.hasNextPage();
}
