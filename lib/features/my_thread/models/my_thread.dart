part of 'models.dart';

/// Current user's thread model in user's info page.
@MappableClass()
class MyThread with MyThreadMappable {
  /// Constructor.
  const MyThread({
    required this.title,
    required this.url,
    required this.threadID,
    required this.forumName,
    required this.forumUrl,
    required this.replyCount,
    required this.viewCount,
    required this.latestReplyAuthor,
    required this.latestReplyTime,
    required this.quotedMessage,
    required this.stateSet,
    this.latestReplyClock,
    this.preview,
  });

  /// Build a [MyThread] from a thread row [t] of a structured "my threads" answer of the forum's app API (plugin
  /// 2.4.0, `schema: 9`, see `myThreadsFromApi`).
  ///
  /// The row is the shared row shape of the list pages, read as [NormalThread.fromApi] reads it (a moved thread is
  /// the row of its target, as the page links it; the times are the forum's unix seconds): the forum from `fid` and
  /// `forum`, the last replier by name (`lastposter`: the list pages name no uid for them, as the web page links
  /// them by name) and `lastpost`, the states from the flags (closed, digest, attachment, poll, reward, the sticky
  /// level) with a draft told by its `displayorder` (-4, the page's "草稿箱" mark). A row that is one reply
  /// (`pid` > 0: the reply page lists one row per reply, as [buildReplyListFromTr] builds them) links the reply
  /// (`goto=findpost`) and quotes it (`summary`); a row of the reply page ([reply], the answer's `kind` `reply`)
  /// whose reply has no text quotes "......", as the page prints it then.
  ///
  /// The last reply is the real instant ([latestReplyTime], shown relative to now) and the forum's wall clock with
  /// [timeOffset] (the answer's `timeoffset`, [latestReplyClock], shown as a date), as the page prints it.
  ///
  /// The `preview` of a thread row (plugin 3.1.0) is the [preview]; a reply row has none (`null`): its quote is the
  /// reply itself.
  factory MyThread.fromApi(Map<String, dynamic> t, {num timeOffset = 8, bool reply = false}) {
    final fid = tsdmAppInt(t['fid']);
    final thread = NormalThread.fromApi(t, fid: fid, typePrefix: 0, timeOffset: timeOffset);
    final pid = tsdmAppInt(t['pid']);
    // The reply page prints the reply's text, or "......" when it has none (`space_thread`: the message, or a
    // numeric one such as "0", else "......").
    final summary = reply && pid > 0 && tsdmAppText(t['summary']).isEmpty ? '......' : tsdmAppText(t['summary']);
    return MyThread(
      title: thread.title,
      url: pid > 0 ? '$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=${thread.threadID}&pid=$pid' : thread.url,
      threadID: thread.threadID,
      forumName: tsdmAppText(t['forum']),
      forumUrl: '$baseUrl/forum.php?mod=forumdisplay&fid=$fid',
      replyCount: thread.replyCount,
      viewCount: thread.viewCount,
      latestReplyAuthor: thread.latestReplyAuthor,
      latestReplyTime: thread.latestReplyTime,
      latestReplyClock: tsdmAppWallClockTime(t['lastpost'], timeOffset),
      // A thread row with a preview: the preview stands for whatever excerpt the row carries.
      quotedMessage: summary.isEmpty || (pid <= 0 && thread.preview != null) ? null : summary,
      stateSet: {...thread.stateSet, if (tsdmAppInt(t['displayorder']) == -4) ThreadStateModel.draft},
      preview: pid > 0 ? null : thread.preview,
    );
  }

  /// Thread title.
  final String title;

  /// Thread url.
  final String url;

  /// Thread id.
  final String threadID;

  /// Forum name in this thread.
  final String forumName;

  /// Forum url in this thread.
  final String forumUrl;

  /// Thread reply count.
  ///
  /// >= 0.
  final int replyCount;

  /// Thread view times.
  ///
  /// >= 0.
  final int viewCount;

  /// Author of the latest reply.
  ///
  /// Actually can not be null.
  final User? latestReplyAuthor;

  /// Time of latest reply, with hour level time.
  ///
  /// e.g. "2023-03-04 00:11:22".
  /// Actually can not be null.
  final DateTime? latestReplyTime;

  /// The time of the latest reply as the forum's wall clock (a naive [DateTime] holding the clock the page prints),
  /// for the date the card shows; null for a row read from the web page, whose [latestReplyTime] is that clock already.
  final DateTime? latestReplyClock;

  /// Quoted message of last replied user that only exists in reply list.
  final String? quotedMessage;

  /// List of thread state.
  ///
  /// For example, a thread can be rated and marked pinned at the same time.
  final Set<ThreadStateModel> stateSet;

  /// The excerpt and the images of the first floor the forum's app API gave for a thread row (plugin 3.1.0), null
  /// when it gave none (a reply row never has one).
  final ThreadPreview? preview;

  /// <tbody>
  ///   <tr>                                 <- or <tr class="bw0_all"> in reply list, followed by reply rows.
  ///     <td class="icn">
  ///       <a href="..." title="新窗口打开"><i class="fico-lock fic6 fc-s"></i></a>   <- X5: font icon
  ///     </td>
  ///     <th>
  ///       <a href="forum.php?mod=viewthread&tid=xxx">${THREAD_TITLE}</a>
  ///       <span class="xg1">已关闭</span>
  ///       <i class="fico-image fic4 fc-p fnmr vm" title="图片附件"></i>   <- X5
  ///       <span class="tps">...</span>
  ///     </th>
  ///     <td><a href="forum.php?mod=forumdisplay&fid=33" class="xg1">forum name</a></td>
  ///     <td class="num"><a class="xi2">12</a><em>98</em></td>
  ///     <td class="by">
  ///       <cite><a href="home.php?mod=space&username=xxx">xxx</a></cite>
  ///       <em><a href="forum.php?mod=redirect&tid=xxx&goto=lastpost#lastpost"><span title="2026-9-4 19:50">半小时前</span></a></em>
  ///     </td>
  ///   </tr>
  ///   <tr><td colspan="5" class="xg1"> <a href="forum.php?mod=redirect&goto=findpost&ptid=xxx&pid=xxx">reply text</a></td></tr>
  ///   <tr><td colspan="5" class="xg1"> ... </td></tr>     <- one row per reply, in reply list only
  /// </tbody>
  ///
  /// For the reply list, use [buildReplyListFromTr] to get one [MyThread] per reply row.
  static MyThread? fromTr(uh.Element element) {
    final titleNode = element.querySelector('th > a');
    if (titleNode == null) {
      talker.info('title node not found in page. Maybe user has never posted');
      return null;
    }
    final title = titleNode.firstEndDeepText()?.trim();
    final url = titleNode.firstHref();
    final threadID = url?.uriQueryParameter('tid') ?? url?.uriQueryParameter('ptid');

    final forumNode =
        element.querySelector('td:nth-child(3) > a') ??
        element.querySelectorAll('td > a').firstWhereOrNull((e) => e.attributes['href']?.contains('fid=') ?? false);
    final forumName = forumNode?.firstEndDeepText()?.trim();
    final forumUrl = forumNode?.firstHref();

    final replyCount = element.querySelector('td.num > a')?.firstEndDeepText()?.parseToInt();
    final viewCount = element.querySelector('td.num > em')?.firstEndDeepText()?.parseToInt();

    final latestReplyNode = element.querySelector('td.by');
    final latestReplyAuthorName = latestReplyNode?.querySelector('cite > a')?.firstEndDeepText();
    final latestReplyAuthorUrl = latestReplyNode?.querySelector('cite > a')?.firstHref();
    final latestReplyTime = latestReplyNode?.querySelector('em > a')?.dateTime();
    String? quotedMessage;
    if (element.classes.contains('bw0_all')) {
      quotedMessage = element.nextElementSibling?.querySelector('td.xg1')?.innerText.trim();
    }

    if (title == null ||
        threadID == null ||
        url == null ||
        forumName == null ||
        forumUrl == null ||
        replyCount == null ||
        viewCount == null ||
        latestReplyAuthorName == null ||
        latestReplyAuthorUrl == null ||
        latestReplyTime == null) {
      talker.error('''
failed to parse MyThread node: {
  title=$title,
  threadID=$threadID,
  url=$url,
  forumName=$forumName,
  forumUrl=$forumUrl,
  replyCount=$replyCount;
  viewCount=$viewCount;
  latestReplyAuthorName=$latestReplyAuthorName,
  latestReplyAuthorUrl=$latestReplyAuthorUrl,
  latestReplyTime=$latestReplyTime,
}
''');
      return null;
    }

    // Unfortunately here we can not parse trailing thread state as what we do
    // in parsing normal thread because the state here only contains text not
    // image at the tail of thread title.
    final stateSet = ThreadStateModel.buildSetFromTr(element);
    for (final stateText in element.querySelectorAll('th > span.xg1')) {
      switch (stateText.innerText.trim()) {
        case '草稿箱':
          stateSet.add(ThreadStateModel.draft);
        case '已关闭':
          stateSet.add(ThreadStateModel.closed);
      }
    }

    return MyThread(
      title: title,
      threadID: threadID,
      url: url,
      forumName: forumName,
      forumUrl: forumUrl,
      replyCount: replyCount,
      viewCount: viewCount,
      latestReplyAuthor: User(name: latestReplyAuthorName, url: latestReplyAuthorUrl),
      latestReplyTime: latestReplyTime,
      quotedMessage: quotedMessage,
      stateSet: stateSet,
    );
  }

  /// Build a list of [MyThread] from the thread row `<tr class="bw0_all">` [element] in the reply list.
  ///
  /// In reply list, each thread row is followed by one or more reply rows:
  ///
  /// <tr class="bw0_all">...thread info...</tr>
  /// <tr><td colspan="5" class="xg1"> <a href="forum.php?mod=redirect&goto=findpost&ptid=xxx&pid=111">reply 1</a></td></tr>
  /// <tr><td colspan="5" class="xg1"> <a href="forum.php?mod=redirect&goto=findpost&ptid=xxx&pid=222">reply 2</a></td></tr>
  ///
  /// Returns one [MyThread] per reply row, with [quotedMessage] set to the reply text and [url] pointing to the reply
  /// (`goto=findpost&pid=xxx`). If no reply rows found, returns the thread itself only.
  static List<MyThread> buildReplyListFromTr(uh.Element element) {
    final thread = fromTr(element);
    if (thread == null) {
      return const [];
    }

    final ret = <MyThread>[];
    var next = element.nextElementSibling;
    while (next != null && !next.classes.contains('bw0_all')) {
      final replyNode = next.querySelector('td.xg1');
      if (replyNode == null) {
        break;
      }
      final replyLinkNode = replyNode.querySelector('a');
      ret.add(
        thread.copyWith(
          quotedMessage: replyNode.innerText.trim(),
          url: replyLinkNode?.firstHref() ?? thread.url,
        ),
      );
      next = next.nextElementSibling;
    }

    if (ret.isEmpty) {
      return [thread];
    }
    return ret;
  }
}
