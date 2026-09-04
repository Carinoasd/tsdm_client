part of 'models.dart';

/// Thread in search result.
@MappableClass()
class SearchedThread with SearchedThreadMappable {
  /// Constructor.
  const SearchedThread({
    required this.tid,
    required this.title,
    required this.url,
    required this.author,
    required this.publishTime,
    required this.forumName,
    required this.forumUrl,
  });

  static final _tidRe = RegExp(r'tid=(?<tid>\d+)');

  /// Build a [SearchedThread] from [element] `<li class="pbw" id="TID">` in Discuz built-in search result page.
  ///
  /// ```html
  /// <li class="pbw" id="1264475">
  ///   <h3 class="xs3"><a href="forum.php?mod=viewthread&tid=1264475&highlight=xxx" target="_blank">TITLE</a></h3>
  ///   <p class="xg1">1272 个回复 - 5534 次查看</p>
  ///   <p>EXCERPT ...</p>
  ///   <p>
  ///     <span>2026-8-31 08:43</span>
  ///     -
  ///     <span><a href="home.php?mod=space&uid=2" target="_blank">USERNAME</a></span>
  ///     -
  ///     <span><a href="forum.php?mod=forumdisplay&fid=6" target="_blank" class="xi1">FORUM</a></span>
  ///   </p>
  /// </li>
  /// ```
  static SearchedThread? fromLiNode(uh.Element element) {
    final threadTitleNode = element.querySelector('h3.xs3 > a') ?? element.querySelector('h3 > a');
    // Title contains highlight nodes: <strong><font color="#ff0000">KEYWORD</font></strong>.
    final title = threadTitleNode?.innerText.trim();
    final url = threadTitleNode?.attributes['href']?.unescapeHtml()?.prependHost();

    // The last <p> holds time, author and forum.
    final infoNode = element.querySelectorAll('p').lastOrNull;
    final userNode = infoNode?.querySelector('span > a[href*="mod=space"]');
    final username = userNode?.innerText.trim();
    final userUrl = userNode?.attributes['href']?.unescapeHtml()?.prependHost();
    final userUid = userUrl?.tryParseAsUri().tryGetQueryParameters()?['uid'];

    final publishTime = infoNode?.querySelector('span')?.innerText.trim().parseToDateTimeUtc8();

    final forumNode = infoNode?.querySelector('span > a[href*="mod=forumdisplay"]');
    final forumName = forumNode?.innerText.trim();
    final forumUrl = forumNode?.attributes['href']?.unescapeHtml()?.prependHost();

    final tid = url == null ? null : _tidRe.firstMatch(url)?.namedGroup('tid')?.parseToInt();

    if (title == null ||
        url == null ||
        tid == null ||
        username == null ||
        userUrl == null ||
        publishTime == null ||
        forumName == null ||
        forumUrl == null) {
      talker.error(
        'invalid searched thread: $title, $url, $tid, $username, $userUrl, '
        '$publishTime, $forumName, $forumUrl',
      );
      return null;
    }

    return SearchedThread(
      tid: tid,
      title: title,
      url: url,
      author: User(name: username, url: userUrl, uid: userUid),
      publishTime: publishTime,
      forumName: forumName,
      forumUrl: forumUrl,
    );
  }

  /// Build a [SearchedThread] from [element] <div class="ts_se_rs">.
  ///
  /// The old plugin `Kahrpba:search` layout, the plugin is gone since Discuz X5, kept for compatibility.
  static SearchedThread? fromDivNode(uh.Element element) {
    if (element.classes.contains('pbw')) {
      return fromLiNode(element);
    }
    final threadTitleNode = element.querySelector('p:nth-child(1) > a');
    final title = threadTitleNode?.firstEndDeepText();
    final url = threadTitleNode?.firstHref();

    final userNode = element.querySelector('p:nth-child(2) > a');
    final username = userNode?.firstEndDeepText();
    final userUrl = userNode?.firstHref();

    final publishTime = element
        .querySelector('p:nth-child(2) > span.dateshow')
        ?.firstEndDeepText()
        ?.trim()
        .substring(2)
        .parseToDateTimeUtc8();

    final forumNode = element.querySelector('p:nth-child(2) > span.fid > a.forum_l');
    final forumName = forumNode?.firstEndDeepText();
    final forumUrl = forumNode?.firstHref();

    if (title == null ||
        url == null ||
        username == null ||
        userUrl == null ||
        publishTime == null ||
        forumName == null ||
        forumUrl == null) {
      talker.error(
        'invalid searched thread: $title, $url, $username, $userUrl, '
        '$publishTime, $forumName, $forumUrl',
      );
      return null;
    }

    final tid = _tidRe.firstMatch(url)!.namedGroup('tid')?.parseToInt();

    return SearchedThread(
      tid: tid!,
      title: title,
      url: url,
      author: User(name: username, url: userUrl),
      publishTime: publishTime,
      forumName: forumName,
      forumUrl: forumUrl,
    );
  }

  /// Thread id.
  final int tid;

  /// Getter of thread id.
  int get threadID => tid;

  /// Thread title.
  final String title;

  /// Thread url.
  final String url;

  /// Thread author, including username and user space url.
  final User author;

  /// Thread publish date.
  final DateTime publishTime;

  /// Forum name this thread belongs to.
  final String forumName;

  /// Forum url this thread belongs to.
  final String forumUrl;
}
