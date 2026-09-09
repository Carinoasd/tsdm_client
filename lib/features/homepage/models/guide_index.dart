part of 'models.dart';

/// One module on the Discuz! guide index page (`forum.php?mod=guide&view=index`, GitHub #12).
///
/// The page lists four modules in order: 最新热门 (`hot`), 最新精华 (`digest`), 最新回复 (`new`) and 最新发表
/// (`newthread`). Each one is a `div.bm.bmw` block whose `div.bm_h` header carries the title and the 更多 » link to
/// the full list page (`forum.php?mod=guide&view=$view`).
@MappableClass()
final class GuideModule with GuideModuleMappable {
  /// Constructor.
  const GuideModule({
    required this.title,
    required this.view,
    required this.moreUrl,
    required this.items,
    this.emptyMessage,
  });

  /// Module title as written on the page, e.g. 最新热门.
  final String title;

  /// The `view` query parameter of the full list page: `hot`, `digest`, `new` or `newthread`.
  final String view;

  /// Absolute url of the full list page behind the 更多 » link.
  final String moreUrl;

  /// Threads listed in the module, in page order.
  final List<GuideItem> items;

  /// The message the page shows instead of items when the module is empty (`p.emp`, e.g. 暂时还没有帖子).
  final String? emptyMessage;
}

/// One thread row in a [GuideModule].
///
/// <li>
///   <em><span class="xi1">4人参与</span></em>
///   <i>· <a href="forum.php?mod=viewthread&tid=1264935&extra=" style="font-weight: bold;color: #EE1B2E;">TITLE</a></i>
///   <span class="xg1"><a href="forum.php?mod=forumdisplay&fid=4">FORUM</a></span>
/// </li>
@MappableClass()
final class GuideItem with GuideItemMappable {
  /// Constructor.
  const GuideItem({
    required this.tid,
    required this.title,
    required this.url,
    this.fid,
    this.forumName,
    this.extra,
    this.highlighted = false,
  });

  /// Thread id.
  final String tid;

  /// Thread title.
  final String title;

  /// Absolute thread url.
  final String url;

  /// Id of the forum the thread belongs to, null when the row has no forum link.
  final String? fid;

  /// Name of the forum the thread belongs to.
  final String? forumName;

  /// The text in `<em>`, which differs per module: `4人参与` in 最新热门, the reply time in 最新回复, nothing in
  /// 最新发表. Null when empty.
  final String? extra;

  /// The title link carries an inline style (bold / colored title set by a moderator).
  final bool highlighted;
}
