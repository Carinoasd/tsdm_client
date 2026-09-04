import 'package:collection/collection.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/thread/v1/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/card/post_card/post_medal_menu_info.dart';
import 'package:universal_html/html.dart' as uh;

/// All info parsed from a thread page document.
///
/// This is a pure data holder, the bloc composes its state from it.
final class ThreadPageInfo {
  /// Constructor.
  const ThreadPageInfo({
    required this.tid,
    required this.title,
    required this.fid,
    required this.forumName,
    required this.currentPage,
    required this.totalPages,
    required this.havePermission,
    required this.permissionDeniedMessage,
    required this.needLogin,
    required this.threadSoftClosed,
    required this.threadClosed,
    required this.postList,
    required this.replyParameters,
    required this.threadType,
    required this.isDraft,
    required this.latestModAct,
    required this.breadcrumbs,
    required this.postMedals,
    required this.viewCount,
    required this.replyCount,
  });

  /// Thread id.
  final String? tid;

  /// Thread title.
  final String? title;

  /// Forum id.
  final int? fid;

  /// Forum name.
  final String? forumName;

  /// Current page number.
  final int currentPage;

  /// Total pages count.
  final int totalPages;

  /// Have permission to view the thread or not.
  final bool havePermission;

  /// Message when permission denied.
  final uh.Element? permissionDeniedMessage;

  /// Need login to view the thread or not.
  final bool needLogin;

  /// Thread is marked as closed (soft closed).
  final bool threadSoftClosed;

  /// Reply form not found, can not reply.
  final bool threadClosed;

  /// All posts in current page.
  final List<Post> postList;

  /// Parameters used to reply the thread.
  final ReplyParameters? replyParameters;

  /// Thread type.
  final FilterType? threadType;

  /// Thread is in draft state or not.
  final bool isDraft;

  /// Latest moderator action.
  final String? latestModAct;

  /// Breadcrumbs.
  final List<ThreadBreadcrumb> breadcrumbs;

  /// Available medals menu info in page.
  final List<PostMedalMenuItem> postMedals;

  /// Thread view count.
  final int? viewCount;

  /// Thread reply count.
  final int? replyCount;
}

/// Parse thread page info from [document].
///
/// [pageNumber] is the fallback page number when not found in document.
ThreadPageInfo parseThreadDocument(uh.Document document, int pageNumber) {
  // Reset the thread id from document.
  final threadLink = document.querySelector('head > link')?.attributes['href'];
  final tid = threadLink?.tryParseAsUri().tryGetQueryParameters()?['tid'];

  // Thread closed mark, legacy style is `<img title="关闭">`, Discuz X5 uses font icon `<i class="fico-lock" title="关闭">`.
  final threadSoftClosed =
      document.querySelector('div#postlist h1.ts img[title="关闭"]') != null ||
      document.querySelector('div#postlist td.vwthd i[title="关闭"]') != null ||
      document.querySelector('div#postlist h1.ts i[title="关闭"]') != null;
  final threadClosed = document.querySelector('form#fastpostform') == null;
  final threadDataNode = document.querySelector('div#postlist');
  final postList = Post.buildListFromThreadDataNode(threadDataNode, document.currentPage() ?? 1);
  // Title node ALWAYS has a node with id `thread_subject`.
  // It's an `<a>` node in legacy styles (invisible in most styles and visible in 爱丽丝 style) and a `<span>` node on
  // Discuz X5.
  //
  // Prefer the one in thread header `h1.ts` because the footer may contain another node with the same id.
  final title =
      document.querySelector('div#postlist h1.ts #thread_subject')?.text?.trim() ??
      document.querySelector('h1.ts #thread_subject')?.text?.trim() ??
      document.querySelector('a#thread_subject')?.text?.trim() ??
      document.querySelector('span#thread_subject')?.text?.trim();

  final allLinksInBreadCrumb = document.querySelectorAll('div#pt a');
  final forumName = switch (allLinksInBreadCrumb.length < 2) {
    true => null,
    false => allLinksInBreadCrumb.elementAtOrNull(allLinksInBreadCrumb.length - 2)?.innerText.trim(),
  };

  final currentPage = document.currentPage() ?? pageNumber;
  final totalPages = document.totalPages() ?? pageNumber;

  var needLogin = false;
  var havePermission = true;
  uh.Element? permissionDeniedMessage;
  if (postList.isEmpty) {
    // Here both normal thread list and subreddit is empty,
    // check permission.
    final docMessage = document.getElementById('messagetext');
    final docLogin = document.getElementById('messagelogin');
    if (docLogin != null) {
      needLogin = true;
    } else if (docMessage != null) {
      havePermission = false;
      permissionDeniedMessage = docMessage.querySelector('p');
    }
  }

  /// Parse thread type from thread page document.
  /// This should only run once.
  final filterTypeNode = document.querySelector('div#postlist h1.ts > a');
  final threadTypeName = filterTypeNode?.firstEndDeepText()?.replaceFirst('[', '').replaceFirst(']', '');
  final threadTypeID = filterTypeNode?.attributes['href']?.tryParseAsUri().tryGetQueryParameters()?['typeid'];
  final FilterType? threadType;
  if (threadTypeName != null) {
    threadType = FilterType(name: threadTypeName, typeID: threadTypeID);
  } else {
    threadType = null;
  }

  // Update reply parameters.
  // These reply parameters should be sent to [ReplyBar] later.
  //
  // In some themes without search bar we can not find fid by the global input with name 'srhfid',
  // parse fid from the query parameters in form action url instead.
  final fid =
      document.querySelector('input[name="srhfid"]')?.attributes['value']?.parseToInt() ??
      document
          .querySelector('#fastpostform')
          ?.attributes['action']
          ?.prependHost()
          .tryParseAsUri()
          .tryGetQueryParameters()?['fid']
          ?.parseToInt();
  final postTime = document.querySelector('input[name="posttime"]')?.attributes['value'];
  final formHash = document.querySelector('input[name="formhash"]')?.attributes['value'];
  final subject = document.querySelector('input[name="subject"]')?.attributes['value'];

  // If the post time parameter is null, only warn in log.
  // Because some subreddits do not have it.
  if (postTime == null) {
    talker.warning('null post time found in thread, reply parameter may be invalid');
  }

  ReplyParameters? replyParameters;
  if (fid == null || formHash == null || subject == null || tid == null) {
    talker.error('failed to get reply form hash: tid=$tid fid=$fid formHash=$formHash subject=$subject');
  } else {
    replyParameters = ReplyParameters(
      fid: '$fid',
      tid: tid,
      postTime: postTime,
      formHash: formHash,
      subject: subject,
    );
  }

  // Draft mark: `<span>[草稿]</span>` in title node, exclude the subject node itself.
  final isDraft =
      document
          .querySelectorAll('div#postlist h1.ts > span')
          .where((e) => e.id != 'thread_subject')
          .any((e) => e.innerText.contains('草稿')) ||
      postList.any((e) => e.isDraft);

  final latestModAct = document.querySelector('div.modact')?.innerText;

  // Parse breadcrumb.
  final breadcrumbs = document
      .querySelectorAll('div#pt > div.z > a')
      .map((e) => (e.innerText, Uri.tryParse(e.attributes['href']!.prependHost())))
      .whereType<(String, Uri)>()
      .skipWhile((e) => !(e.$2.tryGetQueryParameters()?.containsKey('gid') ?? false))
      .map((e) => ThreadBreadcrumb(description: e.$1, link: e.$2))
      .toList();
  if (breadcrumbs.isNotEmpty) {
    breadcrumbs.removeLast();
  }

  // Parse available medals. and designation-card
  final medalsAvailable = document
      .querySelectorAll(r'div[id^="md_"][id$="_menu"]')
      .map(PostMedalMenuItem.fromDiv)
      .whereType<PostMedalMenuItem>()
      .toList();

  final statisticsInfo = document
      .querySelectorAll('div#postlist > table:nth-child(1) span.xi1')
      .map((e) => e.firstEndDeepText()?.parseToInt())
      .whereType<int>();
  final int? viewCount;
  final int? replyCount;

  if (statisticsInfo.length == 2) {
    viewCount = statisticsInfo.first;
    replyCount = statisticsInfo.elementAt(1);
  } else {
    viewCount = null;
    replyCount = null;
  }

  return ThreadPageInfo(
    tid: tid,
    title: title,
    fid: fid,
    forumName: forumName,
    currentPage: currentPage,
    totalPages: totalPages,
    havePermission: havePermission,
    permissionDeniedMessage: permissionDeniedMessage,
    needLogin: needLogin,
    threadSoftClosed: threadSoftClosed,
    threadClosed: threadClosed,
    postList: postList,
    replyParameters: replyParameters,
    threadType: threadType,
    isDraft: isDraft,
    latestModAct: latestModAct,
    breadcrumbs: breadcrumbs,
    postMedals: medalsAvailable,
    viewCount: viewCount,
    replyCount: replyCount,
  );
}
