import 'package:collection/collection.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';

/// What the card of a link to a thread shows ([ThreadLinkCardInfo.ofPage]).
final class ThreadLinkCardInfo {
  /// Constructor.
  const ThreadLinkCardInfo({
    required this.tid,
    required this.title,
    this.author,
    this.forumName,
    this.replyCount,
    this.viewCount,
    this.publishTime,
  });

  /// The thread's first page [page] as a card: null when the account can not read the thread (no permission, a
  /// login prompt, the forum's message instead of the thread) or the page names no title.
  ///
  /// The author and the time are the first floor's, when the page holds it: floor 1, or the first floor of the page
  /// when it has no number (the web page may print "楼主" instead of 1; the page is asked oldest first). A first floor
  /// the page leaves out (an anonymous floor of the web page: the floor after it is numbered) names nobody.
  static ThreadLinkCardInfo? ofPage(int tid, ThreadPageInfo page) {
    final title = page.title?.trim() ?? '';
    if (!page.havePermission || page.needLogin || title.isEmpty) {
      return null;
    }
    final unnumbered = page.postList.firstOrNull;
    final first =
        page.postList.firstWhereOrNull((e) => e.postFloor == 1) ??
        (unnumbered != null && unnumbered.postFloor == null ? unnumbered : null);
    final author = first?.author.name.trim() ?? '';
    final forumName = page.forumName?.trim() ?? '';
    return ThreadLinkCardInfo(
      tid: tid,
      title: title,
      author: author.isEmpty ? null : author,
      forumName: forumName.isEmpty ? null : forumName,
      replyCount: page.replyCount,
      viewCount: page.viewCount,
      publishTime: first?.publishTime,
    );
  }

  /// Thread id.
  final int tid;

  /// Thread title.
  final String title;

  /// Who started the thread; null when the page does not name the author (an anonymous floor names nobody).
  final String? author;

  /// The forum the thread is in.
  final String? forumName;

  /// Replies of the thread.
  final int? replyCount;

  /// Views of the thread.
  final int? viewCount;

  /// When the thread was started.
  final DateTime? publishTime;
}
