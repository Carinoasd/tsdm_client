import 'package:collection/collection.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/chat/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/html.dart' as uh;

/// Parsed info of the chat dialog (`home.php?mod=spacecp&ac=pm&op=showmsg&touid=UID&infloat=yes&inajax=1`).
typedef ChatDialogInfo = ({
  String username,
  bool? online,
  String uid,
  String chatHistoryUrl,
  String spaceUrl,
  ChatSendTarget sendTarget,
  List<ChatMessage> messageList,
});

/// Parsed info of the chat history page (`home.php?mod=space&do=pm&subop=view&touid=UID`).
typedef ChatHistoryInfo = ({
  String username,
  int messageCount,
  int? previousPage,
  int? nextPage,
  ChatHistorySendTarget? sendTarget,
  List<ChatMessage> messages,
});

final _pageRe = RegExp(r'page=(?<page>\d+)');

/// Parse the chat dialog [document] (html inside the ajax xml).
///
/// ```html
/// <div class="pm">
/// <h3 class="flb"><em>正在与Heidi聊天中……[离线]</em>...</h3>
/// <div class="pm_tac bbda cl">
/// <a href="home.php?mod=space&do=pm&subop=view&touid=1104#last" class="y">查看与Heidi的聊天记录</a>
/// <a href="home.php?mod=space&uid=1104">访问Heidi的空间</a>
/// </div>
/// <div class="c">
/// <ul class="pmb" id="msglist">
///   <li class="cl"><h4 class="xg1">2026-09-03</h4></li>
///   <li class="cl pmm"><div class="pmt">大和啦: </div><div class="pmd">MESSAGE</div></li>
///   <li class="cl"><div class="pmt">Heidi: </div><div class="pmd">MESSAGE</div></li>
/// </ul>
/// <div class="pmfm">
/// <form id="pmform_1104" method="post" action="home.php?mod=spacecp&ac=pm&op=send&touid=1104">
/// <input type="hidden" name="pmsubmit" value="true" />
/// <input type="hidden" name="touid" value="1104" />
/// <input type="hidden" name="formhash" value="XXXXXXXX" />
/// <input type="hidden" name="handlekey" value="showmsg_1104" />
/// <textarea name="message"></textarea>
/// <input type="hidden" name="messageappend" id="messageappend" value="" />
/// </form>
/// ```
///
/// Return null if failed to parse.
ChatDialogInfo? parseChatDialog(uh.Document document) {
  final titleText = document.querySelector('h3 > em')?.innerText.replaceFirst('正在与', '').split('聊天中');

  final username = titleText?.reversed.toList().slice(1).reversed.toList().join();
  final online = titleText?.elementAtOrNull(1)?.endsWith('[在线]');

  final chatHistoryUrl =
      (document.querySelector('div.pm_tac a[href*="subop=view"]') ??
              document.querySelector('div.pm_tac > a:nth-child(1)'))
          ?.attributes['href']
          ?.unescapeHtml()
          ?.prependHost();
  final userspaceUrl =
      (document.querySelector('div.pm_tac a[href*="mod=space&uid="]') ??
              document.querySelector('div.pm_tac > a:nth-child(2)'))
          ?.attributes['href']
          ?.unescapeHtml()
          ?.prependHost();
  if (username == null || chatHistoryUrl == null || userspaceUrl == null) {
    talker.error(
      'failed to build chat state: '
      'username=$username, userspaceUrl=$userspaceUrl, '
      'chatHistoryUrl=$chatHistoryUrl',
    );
    return null;
  }

  // Date separators `<li><h4>2026-09-03</h4></li>` carry the date of following messages.
  DateTime? currentDate;
  final messageList = <ChatMessage>[];
  for (final li in document.querySelectorAll('ul#msglist > li')) {
    final date = ChatMessage.parseDateLi(li);
    if (date != null) {
      currentDate = date;
      continue;
    }
    final message = ChatMessage.fromLi(li, date: currentDate);
    if (message != null) {
      messageList.add(message);
    }
  }

  final formNode = document.querySelector('div.pmfm > form');
  if (formNode == null) {
    talker.error('failed to build chat state: form node not found');
    return null;
  }
  final pmsubmit = formNode.querySelector('input[name="pmsubmit"]')?.attributes['value'];
  final touid = formNode.querySelector('input[name="touid"]')?.attributes['value'];
  final formHash = formNode.querySelector('input[name="formhash"]')?.attributes['value'];
  final handlekey = formNode.querySelector('input[name="handlekey"]')?.attributes['value'];
  final messageAppend = formNode.querySelector('input[name="messageappend"]')?.attributes['value'];

  if (touid == null || formHash == null) {
    talker.error('failed to build chat state: touid=$touid formHash=$formHash');
    return null;
  }

  // Some value will fallback to default value, it's ok.
  final chatSendTarget = ChatSendTarget(
    pmsubmit: pmsubmit ?? 'true',
    touid: touid,
    formHash: formHash,
    handleKey: handlekey ?? 'showmsg_$touid',
    messageAppend: messageAppend ?? '',
  );

  return (
    username: username,
    online: online,
    uid: touid,
    chatHistoryUrl: chatHistoryUrl,
    spaceUrl: userspaceUrl,
    sendTarget: chatSendTarget,
    messageList: messageList,
  );
}

/// Parse the chat history page [document].
///
/// ```html
/// <div class="bm bw0">
/// <div class="tbmu pml pm_op_r cl">
///   <div class="xw1">共有 <span id="membernum" class="xi1">36</span> 条与 <a href="home.php?mod=space&uid=1104">Heidi</a> 的交谈记录</div>
/// </div>
/// <div id="pm_ul" class="xld xlda mbm pml">
///   <dl id="pmlist_431" class="bbda cl">...</dl>
///   ...
///   <dl><dd class="m avt">...</dd><dd class="ptm"><form id="pmform" action="home.php?mod=spacecp&ac=pm&op=send&pmid=431&daterange=0&handlekey=pmsend&pmsubmit=yes">
///     <textarea name="message"></textarea>
///     <input type="hidden" name="formhash" value="XXXXXXXX" />
///     <input type="hidden" name="topmuid" value="1104" />
///   </form></dd></dl>
/// </div>
/// ```
///
/// Return null if failed to parse.
ChatHistoryInfo? parseChatHistory(uh.Document document) {
  final rootNode = document.querySelector('div.bm.bw0');
  if (rootNode == null) {
    talker.error('failed to build chat history: root node not found');
    return null;
  }

  final emptyNode = rootNode.querySelector('div.emp');
  // Info node of the other user in chat.
  final userNode =
      rootNode.querySelector('div.tbmu.pml > div.xw1 > a') ?? rootNode.querySelector('div.tbmu > div.xw1 > a');
  if (userNode == null) {
    talker.error('failed to build chat history: user node not found');
    return null;
  }
  final username = userNode.innerText;
  if (emptyNode != null) {
    // Empty chat history.
    return (username: username, messageCount: 0, previousPage: null, nextPage: null, sendTarget: null, messages: []);
  }
  final messageCount = rootNode.querySelector('span#membernum')?.innerText.parseToInt();
  if (messageCount == null) {
    talker.error('failed to build chat history: message count not found');
    return null;
  }

  final previousPage = _pageRe
      .firstMatch(rootNode.querySelector('div.pg > span.pgb > a')?.attributes['href'] ?? '')
      ?.namedGroup('page')
      ?.parseToInt();
  final nextPage = _pageRe
      .firstMatch(rootNode.querySelector('div.pg > a.nxt')?.attributes['href'] ?? '')
      ?.namedGroup('page')
      ?.parseToInt();

  final messages = rootNode
      .querySelectorAll('div#pm_ul > dl')
      .map(ChatMessage.fromDl)
      .whereType<ChatMessage>()
      .toList()
      .reversed
      .toList();

  // Parse send target.
  ChatHistorySendTarget? target;
  final formNode = document.querySelector('form#pmform');
  if (formNode != null) {
    final targetUrl = formNode.attributes['action']
        ?.unescapeHtml()
        ?.prependHost()
        // Append "inajax=1" parameter to let server only return the content
        // xml.
        .append('&inajax=1');
    final formHash = formNode.querySelector('input[name="formhash"]')?.attributes['value'];
    final pmid = targetUrl?.tryParseAsUri().tryGetQueryParameters()?['pmid'];
    // Discuz X5 form carries the peer uid in a hidden input "topmuid", the server reads it from $_GET so append it
    // to the target url to keep the send parameters (formhash + message) unchanged.
    final topmuid = formNode.querySelector('input[name="topmuid"]')?.attributes['value'];
    if (targetUrl != null && formHash != null && pmid != null) {
      target = ChatHistorySendTarget(
        targetUrl: topmuid != null && !targetUrl.contains('topmuid=') ? '$targetUrl&topmuid=$topmuid' : targetUrl,
        pmid: pmid,
        formHash: formHash,
      );
    } else {
      talker.error(
        'failed to build send target in chat history page: '
        'targetUrl=$targetUrl, formHash=$formHash, pmid=$pmid',
      );
    }
  } else {
    talker.error(
      'failed to build send target in chat history page: '
      'form node not found',
    );
  }

  return (
    username: username,
    messageCount: messageCount,
    previousPage: previousPage,
    nextPage: nextPage,
    sendTarget: target,
    messages: messages,
  );
}
