part of 'models.dart';

extension _ParseThreadState on uh.Element {
  /// Parse the [ThreadStateModel] represented by the image node.
  ///
  /// Return an empty set if current node is not <img> node.
  ///
  /// Till now a <img> node may only have one state, but not for sure, so
  /// returns a set of state.
  Set<ThreadStateModel> _parseThreadStateFromImg() {
    final ret = <ThreadStateModel>{};

    if (tagName != 'IMG') {
      return ret;
    }

    final src = attributes['src'];

    /// FIXME: Better checking state.
    if (src != null) {
      if (src.contains('folder_lock')) {
        ret.add(ThreadStateModel.closed);
      } else if (src.contains('poll')) {
        ret.add(ThreadStateModel.poll);
      } else if (src.contains('reward')) {
        ret.add(ThreadStateModel.rewarded);
      } else if (src.contains('pin_3')) {
        ret.add(ThreadStateModel.pinnedGlobally);
      } else if (src.contains('pin_2')) {
        ret.add(ThreadStateModel.pinnedInType);
      } else if (src.contains('pin_1')) {
        ret.add(ThreadStateModel.pinnedInSubreddit);
      }
    }

    final alt = attributes['alt'];
    switch (alt) {
      case 'agree':
        ret.add(ThreadStateModel.upVoted);
      case 'digest':
        ret.add(ThreadStateModel.digested);
      case 'attach_img':
        ret.add(ThreadStateModel.pictureAttached);
    }

    return ret;
  }

  /// Parse the [ThreadStateModel] represented by the font icon node `<i class="fico-xxx">` used in Discuz X5.
  ///
  /// * Thread icon: `<i class="fico-lock">`, `<i class="fico-reward">`, `<i class="fico-vote">`,
  ///   `<i class="tpin tpin3">` (pinned, 3: globally, 2: in type, 1: in subreddit).
  /// * Marks after thread title: `<i class="fico-thumbup" title="帖子被加分">`, `<i class="fico-image" title="图片附件">`,
  ///   `<i class="fico-attachment" title="附件">`.
  ///
  /// Return an empty set if current node is not <i> node.
  Set<ThreadStateModel> _parseThreadStateFromI() {
    final ret = <ThreadStateModel>{};
    if (tagName != 'I') {
      return ret;
    }

    for (final c in classes) {
      switch (c) {
        case 'fico-lock':
          ret.add(ThreadStateModel.closed);
        case 'fico-reward':
          ret.add(ThreadStateModel.rewarded);
        case 'fico-vote':
          ret.add(ThreadStateModel.poll);
        case 'tpin3':
          ret.add(ThreadStateModel.pinnedGlobally);
        case 'tpin2':
          ret.add(ThreadStateModel.pinnedInType);
        case 'tpin1':
          ret.add(ThreadStateModel.pinnedInSubreddit);
        case 'fico-thumbup':
          ret.add(ThreadStateModel.upVoted);
        case 'fico-image':
          ret.add(ThreadStateModel.pictureAttached);
        case 'fico-attachment':
          // Generic attachment, use the closest state available.
          ret.add(ThreadStateModel.pictureAttached);
      }
    }
    return ret;
  }

  /// Parse the [ThreadStateModel] from the `title` attribute on the icon link `<td class="icn"><a title="...">`.
  ///
  /// Title text is a `-` separated description, e.g. "全局置顶主题 - 关闭的主题 - 新窗口打开".
  ///
  /// Only one icon is rendered in the link but the title carries all states so parse states from it.
  Set<ThreadStateModel> _parseThreadStateFromIconLinkTitle() {
    final ret = <ThreadStateModel>{};
    final title = attributes['title'];
    if (title == null) {
      return ret;
    }
    for (final part in title.split('-').map((e) => e.trim())) {
      switch (part) {
        case '全局置顶主题':
          ret.add(ThreadStateModel.pinnedGlobally);
        case '分类置顶主题':
          ret.add(ThreadStateModel.pinnedInType);
        case '本版置顶主题':
          ret.add(ThreadStateModel.pinnedInSubreddit);
        case '关闭的主题':
          ret.add(ThreadStateModel.closed);
        case '悬赏':
          ret.add(ThreadStateModel.rewarded);
        case '投票':
          ret.add(ThreadStateModel.poll);
      }
    }
    return ret;
  }
}

/// Thread state shown on thread entry.
///
/// The definition of "state" is not clear, just added some related info that
/// can be displayed at the trailing of UI which going to display later.
enum ThreadStateModel {
  /// Closed and can not reply.
  closed(Icons.lock_outline),

  /// Up voted by other user.
  upVoted(Icons.thumb_up_outlined),

  /// Has attached pictures.
  pictureAttached(Icons.image_outlined),

  /// Marked as essential thread.
  digested(Icons.recommend_outlined),

  /// Globally pinned across the forum.
  pinnedGlobally(Icons.looks_3_outlined),

  /// Pinned in current thread type.
  pinnedInType(Icons.looks_two_outlined),

  /// Pinned in current subreddit.
  pinnedInSubreddit(Icons.looks_one_outlined),

  /// Has poll (also called "rate").
  poll(Icons.poll_outlined),

  /// Asks for help and provides reward.
  rewarded(Icons.live_help_outlined),

  /// Thread in draft.
  ///
  /// Only used in MyThread page.
  draft(Icons.drafts_outlined);

  const ThreadStateModel(this.icon);

  /// Build a [Set] of [ThreadStateModel].
  ///
  /// This factory function in only useful when:
  ///
  /// * In forum page.
  /// * In my thread page.
  ///
  /// In both usage, [threadElement] is the `<tr>` node parent of the thread
  /// row.
  static Set<ThreadStateModel> buildSetFromTr(uh.Element threadElement) {
    final stateSet = <ThreadStateModel>{};

    // Legacy: <td><a><img src="..." alt="..."></a></td>
    final threadIconNode = threadElement.querySelector('td > a > img');
    if (threadIconNode != null) {
      stateSet.addAll(threadIconNode._parseThreadStateFromImg());
    }

    // X5: <td class="icn"><a title="全局置顶主题 - 关闭的主题 - 新窗口打开"><i class="fico-lock ..."></i></a></td>
    final iconLinkNode = threadElement.querySelector('td.icn > a');
    if (iconLinkNode != null) {
      stateSet.addAll(iconLinkNode._parseThreadStateFromIconLinkTitle());
      final iconNode = iconLinkNode.querySelector('i');
      if (iconNode != null) {
        stateSet.addAll(iconNode._parseThreadStateFromI());
      }
    }

    // Parse thread state from images following title text.
    final stateList = threadElement
        .querySelectorAll('th > img')
        .map((e) => e._parseThreadStateFromImg())
        .toList()
        .flattened
        .toList();
    // X5: font icons following title text.
    final iconStateList = threadElement.querySelectorAll('th > i').map((e) => e._parseThreadStateFromI()).flattened;
    stateSet
      ..addAll(stateList)
      ..addAll(iconStateList);

    // X5: <span class="tbox tdigest">精华1</span>
    if (threadElement.querySelector('th > span.tdigest') != null) {
      stateSet.add(ThreadStateModel.digested);
    }

    return stateSet;
  }

  /// Icon of thread.
  final IconData icon;
}

/// Model of normal thread, widely used in forum.
@MappableClass()
class NormalThread with NormalThreadMappable {
  /// Constructor.
  const NormalThread({
    required this.title,
    required this.url,
    required this.threadID,
    required this.author,
    required this.publishDate,
    required this.latestReplyAuthor,
    required this.latestReplyTime,
    required this.iconUrl,
    required this.threadType,
    required this.replyCount,
    required this.viewCount,
    required this.price,
    required this.privilege,
    required this.css,
    required this.stateSet,
    required this.isRecentThread,
  });

  /// Thread title.
  final String title;

  /// Thread url.
  final String url;

  /// Thread id.
  final String threadID;

  /// Thread author, contains username and user page url.
  final User author;

  /// Thread publish date, without publish hour level time.
  ///
  /// e.g. "2023-03-04".
  final DateTime? publishDate;

  /// Author of the latest reply.
  ///
  /// If no reply in thread, also is the [author].
  final User latestReplyAuthor;

  /// Time of latest reply, with hour level time.
  ///
  /// e.g. "2023-03-04 00:11:22".
  final DateTime? latestReplyTime;

  /// Icon url of this thread.
  ///
  /// May be null.
  final String iconUrl;

  /// Thread type: 动漫音乐、其他...
  ///
  /// May be null.
  final ThreadType? threadType;

  /// Thread reply count.
  ///
  /// >= 0.
  final int replyCount;

  /// Thread view times.
  ///
  /// >= 0.
  final int viewCount;

  /// Thread price.
  ///
  /// May be null, >= 0.
  final int? price;

  /// Required read privilege.
  ///
  /// User has privilege less than this value is not allowed to the this thread.
  ///
  /// May be null, >= 0.
  final int? privilege;

  /// Css decoration on thread entry.
  final CssTypes? css;

  /// List of thread state.
  ///
  /// For example, a thread can be rated and marked pinned at the same time.
  final Set<ThreadStateModel> stateSet;

  /// Published in recent 24 hours or not.
  ///
  /// If so, thread name is highlighted.
  final bool isRecentThread;

  /// Build a [NormalThread] model with the given [uh.Element]
  ///
  /// Discuz X5 layout (forum page, guide page `forum.php?mod=guide&view=new`):
  ///
  /// <tbody id="normalthread_xxxxxxx">
  ///   <tr>
  ///     <td class="icn">
  ///       <a href="forum.php?mod=viewthread&tid=xxx" title="关闭的主题 - 新窗口打开"><i class="fico-lock fic6 fc-s"></i></a>
  ///     </td>
  ///     <td class="o">...</td>                                   <- moderator only, checkbox
  ///     <th class="common">
  ///       <a href="javascript:;" class="showcontent y"></a>      <- optional
  ///       <em>[<a href="forum.php?mod=forumdisplay&fid=200&filter=typeid&typeid=4552">版务</a>]</em>
  ///       <a href="forum.php?mod=viewthread&tid=xxx" style="color: #EE1B2E;" class="s xst">title</a>
  ///       - [售价 <span class="xw1">15</span> 天使币]
  ///       - [阅读权限 <span class="xw1">10</span>]
  ///       <span class="tbox tdigest">精华1</span>
  ///       <i class="fico-thumbup fic4 fc-l fnmr vm" title="帖子被加分"></i>
  ///       <i class="fico-image fic4 fc-p fnmr vm" title="图片附件"></i>
  ///       <span class="tps">...<a>2</a><a>3</a></span>
  ///       <a href="forum.php?mod=redirect&tid=xxx&goto=lastpost#lastpost" class="xi1">New</a>
  ///     </th>
  ///     <td class="by"><a href="forum.php?mod=forumdisplay&fid=4">forum name</a></td>  <- guide page only
  ///     <td class="by">
  ///       <cite><a href="home.php?mod=space&uid=2" c="1">author</a></cite>
  ///       <em><span class="xi1"><span title="2026-8-31">4 天前</span></span></em>
  ///     </td>
  ///     <td class="num"><a href="forum.php?mod=viewthread&tid=xxx" class="xi2">1271</a><em>5522</em></td>
  ///     <td class="by">
  ///       <cite><a href="home.php?mod=space&username=xxx" c="1">xxx</a></cite>
  ///       <em><a href="forum.php?mod=redirect&tid=xxx&goto=lastpost#lastpost"><span title="2026-9-4 20:34">6 分钟前</span></a></em>
  ///     </td>
  ///   </tr>
  /// </tbody>
  ///
  /// Legacy layout (Discuz X3):
  ///
  /// <tbody id="normalthread_xxxxxxx" class="tsdm_normalthread" name="tsdm_normalthread">
  static NormalThread? fromTBody(uh.Element threadElement) {
    // X5 uses font icons `<i class="fico-thread">` as thread icon, no image url available. Allow empty.
    final threadIconNode = threadElement.querySelector('tr > td > a > img');
    final threadIconUrl = threadIconNode?.dataOriginalOrSrcImgUrl()?.prependHost() ?? '';

    // Allow not found.
    final threadTypeNode = threadElement.querySelector('tr > th > em > a');
    final threadTypeUrl = threadTypeNode?.attributes['href'];
    final threadTypeName = threadTypeNode?.firstEndDeepText()?.trim();

    final threadUrlNode =
        // X5: forum page `<a class="s xst">`, guide page `<a class="xst">`.
        threadElement.querySelector('tr > th > a.xst') ??
        // Legacy.
        threadElement.querySelector('tr > th > span > a');
    final threadUrl = threadUrlNode?.attributes['href'];
    final threadTitle = threadUrlNode?.firstEndDeepText()?.trim();
    final css = parseCssString(threadUrlNode?.attributes['style'] ?? '');
    if (threadUrl == null || threadTitle == null) {
      talker.error('failed to build thread: url or title not found, tbody=${threadElement.id}');
      return null;
    }

    int? threadPrice;
    int? privilege;
    for (final node in threadElement.querySelectorAll('tr > th > span.xw1')) {
      final prevText = node.previousNode?.text;
      if (prevText == null) {
        continue;
      }
      if (prevText.contains('售价')) {
        threadPrice = node.firstEndDeepText()?.trim().parseToInt();
      } else if (prevText.contains('阅读权限')) {
        privilege = node.firstEndDeepText()?.trim().parseToInt();
      }
    }

    // Two (or three in guide page) <td class="by"> nodes:
    //
    // 0. Forum node, only in guide page, without <cite>.
    // 1. Thread author node. <- need this one, the first one with <cite>.
    // 2. Last reply author node.
    final threadByNodeList = threadElement.querySelectorAll('tr > td.by').toList();
    final threadAuthorNode = threadByNodeList.firstWhereOrNull((e) => e.querySelector('cite > a') != null);
    final threadAuthorUrl = threadAuthorNode?.querySelector('cite > a')?.attributes['href'];
    final threadAuthorUid = threadAuthorUrl?.uriQueryParameter('uid');
    final threadAuthorName = threadAuthorNode?.querySelector('cite > a')?.firstEndDeepText()?.trim();
    final threadPublishDateNode = threadAuthorNode?.querySelector('em');
    final threadPublishDate =
        // In recent 7 days: <em><span><span title="2026-8-31">4 天前</span></span></em>
        threadPublishDateNode?.querySelector('span[title]')?.attributes['title']?.parseToDateTimeUtc8() ??
        // <em><span>2019-4-1</span></em>
        threadPublishDateNode?.querySelector('span')?.firstEndDeepText()?.trim().parseToDateTimeUtc8() ??
        threadPublishDateNode?.innerText.trim().parseToDateTimeUtc8();

    // Thread published in 24 hours get highlight on its publish time with
    // css class `xi1`.
    final isRecentThread = threadPublishDateNode?.querySelector('span.xi1') != null;

    if (threadAuthorUrl == null || threadAuthorName == null || threadPublishDate == null) {
      talker.error(
        'failed to build thread: invalid author or thread publish '
        'date not found, tbody=${threadElement.id}',
      );
      return null;
    }

    final threadStatisticsNode = threadElement.querySelector('tr > td.num');
    final threadReplyCount = threadStatisticsNode?.querySelector('a.xi2')?.firstEndDeepText()?.parseToInt();
    final threadViewCount = threadStatisticsNode?.querySelector('em')?.firstEndDeepText()?.parseToInt();

    // Two <td class="by"> nodes:
    //
    // 1. Thread author node.
    // 2. Last reply author node. <- need this one.
    //
    // Never drop the whole thread because this cell is incomplete: an anonymous or deleted last replier has no
    // link (`<cite>匿名</cite>`) and the reply time may be rendered without `<a>`. Fall back to plain text / null.
    final threadLastReplyNode = threadByNodeList.lastOrNull;
    final threadLastReplyCite = threadLastReplyNode?.querySelector('cite');
    final threadLastReplyAuthorUrl = threadLastReplyCite?.querySelector('a')?.attributes['href'] ?? '';
    // We only have username here.
    final threadLastReplyAuthorName =
        threadLastReplyCite?.querySelector('a')?.firstEndDeepText()?.trim() ?? threadLastReplyCite?.innerText.trim() ?? '';
    final threadLastReplyTimeNode = threadLastReplyNode?.querySelector('em');
    final threadLastReplyTime =
        threadLastReplyTimeNode?.querySelector('a')?.dateTime() ??
        threadLastReplyTimeNode?.querySelector('span[title]')?.attributes['title']?.parseToDateTimeUtc8() ??
        threadLastReplyTimeNode?.innerText.trim().parseToDateTimeUtc8();

    final threadID = threadUrl.uriQueryParameter('tid');
    if (threadID == null) {
      talker.error('failed to build thread: thread ID not found, url=$threadUrl');
      return null;
    }
    if (threadLastReplyAuthorName.isEmpty || threadLastReplyTime == null) {
      talker.warning(
        'thread $threadID: incomplete last reply info, name="$threadLastReplyAuthorName" '
        'time=$threadLastReplyTime, keep the thread',
      );
    }

    final stateTrNode = threadElement.querySelector('tr');
    final stateSet = <ThreadStateModel>{};
    if (stateTrNode != null) {
      stateSet.addAll(ThreadStateModel.buildSetFromTr(stateTrNode));
    }

    return NormalThread(
      title: threadTitle,
      url: threadUrl,
      threadID: threadID,
      author: User(
        name: threadAuthorName,
        uid: threadAuthorUid,
        url: threadAuthorUrl,
        // The thread list carries no avatar at all, only the author's uid, so build the url of the avatar file the
        // forum stores for that uid. Null for anonymous or deleted authors, and the file is missing for users who set
        // an external avatar url: both keep the text placeholder in the card.
        avatarUrl: avatarUrlOfUid(threadAuthorUid),
      ),
      publishDate: threadPublishDate,
      latestReplyAuthor: User(name: threadLastReplyAuthorName, url: threadLastReplyAuthorUrl),
      latestReplyTime: threadLastReplyTime,
      iconUrl: threadIconUrl,
      threadType: ThreadType.parse(threadTypeName, threadTypeUrl),
      replyCount: threadReplyCount ?? 0,
      viewCount: threadViewCount ?? 0,
      price: threadPrice,
      privilege: privilege,
      css: css,
      stateSet: stateSet,
      isRecentThread: isRecentThread,
    );
  }
}
