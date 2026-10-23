import 'package:collection/collection.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

class _LatestThreadInfo {
  const _LatestThreadInfo({
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
    this.threadAuthor,
    this.preview,
  });

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

  /// Quoted message of last replied user that only exists in reply list.
  final String? quotedMessage;

  /// Author of the thread itself, only known in the guide page layout.
  final User? threadAuthor;

  /// The excerpt and the images of the first floor, from a structured answer of plugin 3.1.0.
  final ThreadPreview? preview;
}

/// Latest thread model.
///
/// Since Discuz X5 the data source is the standard guide page (`forum.php?mod=guide&view=new` for latest replies and
/// `forum.php?mod=guide&view=newthread` for latest threads), see [LatestThread.fromTBody].
class LatestThread {
  /// Build from <li> node.
  ///
  /// Legacy layout used by the vanished `Kahrpba` plugin page.
  LatestThread.fromLi(uh.Element element) : _info = _buildFromLiNode(element);

  /// Build from `<tbody id="normalthread_xxx">` node in guide page.
  ///
  /// <tbody id="normalthread_1264906">
  ///   <tr>
  ///     <td class="icn">...</td>
  ///     <th class="common"><a href="forum.php?mod=viewthread&tid=1264906&extra=" class="xst">title</a>...</th>
  ///     <td class="by"><a href="forum.php?mod=forumdisplay&fid=4" target="_blank">若闲小阁</a></td>
  ///     <td class="by"><cite><a href="home.php?mod=space&uid=1116">author</a></cite><em>...</em></td>
  ///     <td class="num"><a class="xi2">11</a><em>76</em></td>
  ///     <td class="by"><cite><a href="home.php?mod=space&username=xxx">xxx</a></cite><em><a><span title="2026-9-4 20:25">29 分钟前</span></a></em></td>
  ///   </tr>
  /// </tbody>
  LatestThread.fromTBody(uh.Element element) : _info = _buildFromTBodyNode(element);

  /// Build from a thread row [row] of a structured guide list answer of the forum's app API (plugin 2.4.0,
  /// `schema: 7`, `latestThreadsFromApi`).
  ///
  /// The row is read as [NormalThread.fromApi] reads it (a moved thread is the row of its target, as the page links
  /// it; an anonymous author has no uid; the times are the forum's unix seconds): the forum from `fid` and `forum`,
  /// the last replier and time from `lastposter` / `lastpost` (the replier by name only: the list pages name no uid
  /// for them, as the web page links them by name), the thread's author as [threadAuthor], as [LatestThread.fromTBody] reads the
  /// guide page. A row that is one reply (`pid`: the guide's "my replies") links the reply (`goto=findpost`) and
  /// quotes it (`summary`); a row of the guide's reply list ([reply], the answer's `kind` `reply`) whose reply has no
  /// text quotes "...", as the page prints it then. The time ([latestReplyTime], shown as a date) is the forum's wall
  /// clock with [timeOffset] (the answer's `timeoffset`), as the page prints it. The `preview` of a thread row (plugin
  /// 3.1.0) is the [preview]; a reply row has none.
  LatestThread.fromApi(Map<String, dynamic> row, {num timeOffset = 8, bool reply = false})
    : _info = _buildFromApi(row, timeOffset: timeOffset, reply: reply);

  /// Build from a thread row [row] of the structured search results of 查看新帖 (`search.php?mod=forum&srchfrom=…`,
  /// plugin 2.4.0, `schema: 6`), which share the guide's row shape.
  ///
  /// As [LatestThread.fromApi], but the person and the time shown are the thread's author and its publish time (`author`,
  /// `dateline`), as the search layout prints them (`dateline - author`) and [LatestThread.fromLi] reads them; the last replier
  /// and the last reply are not shown there. The excerpt (`summary`) is quoted, as the layout's was, unless the row
  /// carries the `preview` of plugin 3.1.0: the [preview] stands for it then, and the search's own excerpt is not
  /// shown (the forum cuts it from the floor as stored, the hidden parts and a paid thread's content included).
  LatestThread.fromSearchApi(Map<String, dynamic> row, {num timeOffset = 8})
    : _info = _buildFromApi(row, search: true, timeOffset: timeOffset);

  final _LatestThreadInfo? _info;

  /// Whether this thread is successfully parsed.
  bool get isValid => _info != null;

  static final _re = RegExp(r'(?<count>\d+)');

  /// Thread title.
  String? get title => _info?.title;

  /// Thread url.
  String? get url => _info?.url;

  /// Thread id.
  String? get threadID => _info?.threadID;

  /// Forum name the thread belongs to.
  String? get forumName => _info?.forumName;

  /// Forum url the thread belongs to.
  String? get forumUrl => _info?.forumUrl;

  /// The user info of latest replied user.
  User? get latestReplyAuthor => _info?.latestReplyAuthor;

  /// Time of latest reply.
  DateTime? get latestReplyTime => _info?.latestReplyTime;

  /// Total replies count.
  int? get replyCount => _info?.replyCount;

  /// View times count.
  int? get viewCount => _info?.viewCount;

  /// Quoted message to show.
  String? get quotedMessage => _info?.quotedMessage;

  /// Author of the thread (not the latest reply), null when the layout does not tell.
  User? get threadAuthor => _info?.threadAuthor;

  /// The excerpt and the images of the first floor the forum's app API gave for the row (plugin 3.1.0), null when it
  /// gave none.
  ThreadPreview? get preview => _info?.preview;

  static _LatestThreadInfo _buildFromApi(
    Map<String, dynamic> row, {
    required num timeOffset,
    bool search = false,
    bool reply = false,
  }) {
    final fid = tsdmAppInt(row['fid']);
    final thread = NormalThread.fromApi(row, fid: fid, typePrefix: 0, timeOffset: timeOffset);
    final pid = tsdmAppInt(row['pid']);
    // The guide's reply list prints the reply's text, or "..." when it has none (`guide_list_row`: `$post[message]`
    // is empty or "0").
    final text = tsdmAppText(row['summary']);
    final summary = reply && pid > 0 && (text.isEmpty || text == '0') ? '...' : text;
    // A reply row quotes the reply, it has no preview of the thread.
    final preview = pid > 0 ? null : thread.preview;
    return _LatestThreadInfo(
      title: thread.title,
      url: pid > 0 ? '$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=${thread.threadID}&pid=$pid' : thread.url,
      threadID: thread.threadID,
      forumName: tsdmAppText(row['forum']),
      forumUrl: '$baseUrl/forum.php?mod=forumdisplay&fid=$fid',
      replyCount: thread.replyCount,
      viewCount: thread.viewCount,
      latestReplyAuthor: search ? thread.author : thread.latestReplyAuthor,
      // Shown as a date: the forum's wall clock, as the page prints it.
      latestReplyTime: search ? thread.publishDate : tsdmAppWallClockTime(row['lastpost'], timeOffset),
      quotedMessage: summary.isEmpty || preview != null ? null : summary,
      threadAuthor: thread.author,
      preview: preview,
    );
  }

  static _LatestThreadInfo? _buildFromTBodyNode(uh.Element element) {
    final thread = NormalThread.fromTBody(element);
    if (thread == null) {
      talker.error('failed to parse LatestThread from tbody: invalid thread row');
      return null;
    }

    // The forum cell is the first <td class="by"> which has no <cite>.
    final forumNode = element
        .querySelectorAll('tr > td.by > a')
        .firstWhereOrNull((e) => e.attributes['href']?.contains('mod=forumdisplay') ?? false);
    final forumName = forumNode?.firstEndDeepText()?.trim();
    final forumUrl = forumNode?.firstHref()?.prependHost();
    if (forumName == null || forumUrl == null) {
      talker.error('failed to parse LatestThread from tbody: forum not found: name=$forumName, url=$forumUrl');
      return null;
    }

    return _LatestThreadInfo(
      title: thread.title,
      url: thread.url.prependHost(),
      threadID: thread.threadID,
      forumName: forumName,
      forumUrl: forumUrl,
      replyCount: thread.replyCount,
      viewCount: thread.viewCount,
      latestReplyAuthor: thread.latestReplyAuthor,
      latestReplyTime: thread.latestReplyTime,
      quotedMessage: null,
      threadAuthor: thread.author,
    );
  }

  /// <div id="threadlist">
  ///   <ul>
  ///     <li>
  ///       <h3 class="xs3">${TITLE}</h3>
  ///       <p class="xg1"></p>
  ///       <p></p>
  ///       ...
  ///     </li>
  ///   </ul>
  /// </div>
  ///
  /// Parse from the "li" tag node.
  static _LatestThreadInfo? _buildFromLiNode(uh.Element element) {
    final titleNode = element.querySelector('h3 > a');
    final title = titleNode?.firstEndDeepText();
    final url = titleNode?.firstHref()?.prependHost();
    final threadID = url?.uriQueryParameter('tid');

    final statisticsText = element.querySelector('p:nth-child(2)')?.firstEndDeepText();
    final matches = _re.allMatches(statisticsText ?? '').toList();
    final replyCount = matches.elementAtOrNull(0)?.namedGroup('count')?.parseToInt();
    final viewCount = matches.elementAtOrNull(1)?.namedGroup('count')?.parseToInt();

    final quotedMessage = element.querySelector('p:nth-child(3)')?.firstEndDeepText();

    final infoNode = element.querySelector('p:nth-child(4)');
    final publishTime = infoNode?.querySelector('span:nth-child(1)')?.firstEndDeepText()?.parseToDateTimeUtc8();
    final username = infoNode?.querySelector('span:nth-child(2) > a')?.firstEndDeepText();
    final userUrl = infoNode?.querySelector('span:nth-child(2) > a')?.firstHref()?.prependHost();
    final forumName = infoNode?.querySelector('span:nth-child(3) > a')?.firstEndDeepText();
    final forumUrl = infoNode?.querySelector('span:nth-child(3) > a')?.firstHref()?.prependHost();

    if (title == null ||
        url == null ||
        threadID == null ||
        replyCount == null ||
        viewCount == null ||
        quotedMessage == null ||
        publishTime == null ||
        username == null ||
        userUrl == null ||
        forumName == null ||
        forumUrl == null) {
      talker.error('''
failed to parse LatestThread node: {
  title=$title,
  threadID=$threadID,
  url=$url,
  forumName=$forumName,
  forumUrl=$forumUrl,
  replyCount=$replyCount;
  viewCount=$viewCount;
  latestReplyAuthorName=$username,
  latestReplyAuthorUrl=$userUrl,
  latestReplyTime=$publishTime,
  quotedMessage=$quotedMessage,
}
''');
      return null;
    }
    return _LatestThreadInfo(
      title: title,
      threadID: threadID,
      url: url,
      forumName: forumName,
      forumUrl: forumUrl,
      replyCount: replyCount,
      viewCount: viewCount,
      latestReplyAuthor: User(name: username, url: userUrl),
      latestReplyTime: publishTime,
      quotedMessage: quotedMessage,
    );
  }
}
