part of 'models.dart';

/// Private personal message with other users.
///
/// Each instance represents a session with another user including a series of
/// messages.
///
/// All private messages have id "pmlist_${MESSAGE_ID}".
///
/// We do not distinguish latest message direction (send to or receive from),
/// act like other chat apps.
@MappableClass()
final class PersonalMessage with PersonalMessageMappable {
  /// Constructor.
  const PersonalMessage({
    required this.user,
    required this.message,
    required this.lastMessageTime,
    required this.count,
    required this.chatUrl,
  });

  /// The other user communicating with.
  final User user;

  /// Last message content.
  final String message;

  /// Datetime of latest message.
  final DateTime lastMessageTime;

  /// Count of messages with user.
  final int? count;

  /// Chat page url.
  final String chatUrl;

  /// Parse the last message text in the content node `dd.ptm.pm_c`.
  ///
  /// ```html
  /// <dd class="ptm pm_c">
  ///   <div class="o">...</div>
  ///   <a href="home.php?mod=space&uid=1104" class="xw1">Heidi</a> 对 <span class="xi2">您</span> 说 :<br />
  ///   MESSAGE_TEXT &nbsp;  <br />
  ///   <span class="xg1"><span title="2026-9-4 12:44">7&nbsp;小时前</span></span> &nbsp;
  ///   <span class="pm_o y">...</span>
  /// </dd>
  /// ```
  ///
  /// Message is all text between the first `<br>` and the following `<br>` (or the time node).
  static String? parseLastMessage(uh.Element contentNode) {
    final buffer = StringBuffer();
    var started = false;
    for (final node in contentNode.nodes) {
      if (node.nodeType == uh.Node.ELEMENT_NODE) {
        final e = node as uh.Element;
        if (e.localName == 'br') {
          if (started) {
            break;
          }
          started = true;
          continue;
        }
        if (started) {
          if (e.classes.contains('xg1') || e.classes.contains('pm_o')) {
            break;
          }
          buffer.write(e.innerText);
        }
      } else if (started && node.nodeType == uh.Node.TEXT_NODE) {
        buffer.write(node.text ?? '');
      }
    }
    if (!started) {
      // Fallback for X3 style: text right before the time node.
      return contentNode.querySelector('span.xg1')?.previousNode?.text?.split(':').elementAtOrNull(1)?.trim();
    }
    return buffer.toString().replaceAll(' ', ' ').trim();
  }

  /// Check whether current logged user is the sender of the last message.
  ///
  /// The first "user" node in content is the sender: `<span class="xi2 xw1">您</span>` when the sender is the current
  /// user or `<a class="xw1">USERNAME</a>` when the sender is the peer.
  static bool parseSentByMe(uh.Element contentNode) {
    for (final e in contentNode.children) {
      if (e.localName == 'div') {
        continue;
      }
      if (e.localName == 'span' && e.classes.contains('xi2')) {
        return true;
      }
      if (e.localName == 'a') {
        return false;
      }
    }
    return false;
  }

  /// Convert a `<dl id="pmlist_XXX">` node in the private message list page into [PersonalMessageV2].
  static PersonalMessageV2? toV2(uh.Element element) {
    if (!element.id.startsWith('pmlist')) {
      return null;
    }
    final contentNode = element.querySelector('dd.ptm.pm_c') ?? element.querySelector('dd.ptm');
    final peerNode = element.querySelector('dd.m.avt > a') ?? element.querySelector('dd.avt > a');
    final peerUid = peerNode?.attributes['href']?.unescapeHtml()?.tryParseAsUri().tryGetQueryParameters()?['uid'];
    final peerUsername =
        contentNode?.querySelector('a.xw1')?.innerText.trim() ??
        contentNode?.querySelector('a[href*="uid="]')?.innerText.trim();
    final time = contentNode?.querySelector('span.xg1')?.dateTime();
    final message = contentNode == null ? null : parseLastMessage(contentNode);
    if (contentNode == null || peerUid == null || peerUsername == null || time == null || message == null) {
      talker.error(
        'failed to build personal message v2: hasPeerUid=${peerUid != null}, hasPeerUsername=${peerUsername != null}, '
        'time=$time, hasMessage=${message != null}',
      );
      return null;
    }
    final sender = parseSentByMe(contentNode);
    return PersonalMessageV2(
      timestamp: time.millisecondsSinceEpoch ~/ 1000,
      data: message,
      peerUid: peerUid.parseToInt() ?? 0,
      peerUsername: peerUsername,
      sender: sender,
      alreadyRead: sender || !isUnreadNode(element),
    );
  }

  /// Whether the private message page rendered the conversation node [element] (`<dl id="pmlist_XXX">`) as unread.
  ///
  /// The forum adds the class `newpm` to the node of an unread conversation (`{if $value[isnew]} newpm{/if}`). The
  /// red dot `div.newpm_avt` in it is no marker: Discuz! X5 prints it in every node (`template/default/home/
  /// space_pm.php`) and its style only shows it inside `.newpm` (`.pml .newpm .newpm_avt`), so every conversation
  /// on the page was taken for unread.
  static bool isUnreadNode(uh.Element element) => element.classes.contains('newpm');

  /// The conversations of a `pmlist` answer [json] of the forum's app API (plugin 1.9.0) as [PersonalMessageV2];
  /// null when it is no usable answer (none, not `ok`, an unknown shape, no `timeoffset`, a conversation without
  /// `lastsummary_html`): the private message page is read instead.
  ///
  /// The list is the one of the private message page (`filter=privatepm`): every conversation, sent or received, read
  /// or not, newest first. See [toV2FromApi] for each one. A forum with private messages switched off answers
  /// `closed` 1 and no conversation, as its page lists none.
  static List<PersonalMessageV2>? listFromApi(Map<String, dynamic>? json) {
    final uid = json?['uid'];
    final rows = json?['pms'];
    final timeOffset = json?['timeoffset'];
    if (json == null || json['ok'] != 1 || uid is! int || rows is! List || timeOffset is! num) {
      return null;
    }
    final conversations = rows.whereType<Map<String, dynamic>>();
    if (conversations.any((e) => e['type'] == 1 && e['lastsummary_html'] is! String)) {
      talker.error('pmlist answered a conversation without lastsummary_html');
      return null;
    }
    return conversations
        .map((e) => toV2FromApi(e, uid: uid, timeOffset: timeOffset))
        .whereType<PersonalMessageV2>()
        .toList();
  }

  /// Convert a conversation [row] of a `pmlist` answer of the forum's app API (plugin 1.9.0) into
  /// [PersonalMessageV2], for the account [uid] the answer is for, the same as [toV2] gives for its node on the
  /// private message page.
  ///
  /// The current user sent the last message when its author is [uid]; such a conversation, and one the forum keeps
  /// as read (`new` 0), is read. The message is [summaryOfHtml] of `lastsummary_html`, the summary as the page prints
  /// it; `lastsummary`, the faithful text, is not what the page shows. The time is the one the page path reads
  /// ([apiTimeOf], with the [timeOffset] of the answer). A group chat (`type` 2) is dropped: [toV2] finds no peer in
  /// its node on the page either. So is a row without peer, time or summary.
  static PersonalMessageV2? toV2FromApi(Map<String, dynamic> row, {required int uid, required num timeOffset}) {
    if (row['type'] != 1) {
      return null;
    }
    final peerUid = row['touid'] is int ? row['touid'] as int : 0;
    final peerUsername = row['tousername'] is String ? row['tousername'] as String : '';
    final time = row['lastdateline'] is int ? row['lastdateline'] as int : 0;
    final summary = row['lastsummary_html'];
    final message = summary is String ? summaryOfHtml(summary) : null;
    if (peerUid <= 0 || peerUsername.isEmpty || time <= 0 || message == null) {
      talker.error(
        'failed to build personal message v2 from the app api: plid=${row['plid']}, peerUid=$peerUid, '
        'hasPeerUsername=${peerUsername.isNotEmpty}, time=$time, hasSummary=${message != null}',
      );
      return null;
    }
    final sender = row['lastauthorid'] == uid;
    return PersonalMessageV2(
      timestamp: apiTimeOf(time, timeOffset),
      data: message,
      peerUid: peerUid,
      peerUsername: peerUsername,
      sender: sender,
      alreadyRead: sender || row['new'] == 0,
    );
  }

  /// The message [parseLastMessage] reads from a conversation node of the private message page that prints [html]
  /// as its summary (`template/default/home/space_pm.php`: `$value[lastsummary] &nbsp;  <br />` after the line naming
  /// the sender): the text of that html, entities decoded, the no-break space as a space, trimmed, the spaces and
  /// line breaks inside kept.
  static String? summaryOfHtml(String html) {
    const who = '<a href="home.php?mod=space&amp;uid=0" class="xw1">-</a> 对 <span class="xi2">您</span> 说 :';
    final node = parseHtmlDocument(
      '<html><body><div class="xld xlda pml"><dl id="pmlist_0" class="bbda cur1 cl"><dd class="ptm pm_c">\n'
      '<div class="o"></div>$who<br />\n$html &nbsp;  <br />\n<span class="xg1"></span></dd></dl></div></body></html>',
    ).querySelector('dd.ptm.pm_c');
    return node == null ? null : parseLastMessage(node);
  }

  /// Build from dl with id "pmlist_XXXX".
  static PersonalMessage? fromDl(uh.Element element) {
    if (!element.id.startsWith('pmlist')) {
      return null;
    }
    final messageId = element.id.split('_').elementAtOrNull(1);
    if (messageId == null) {
      talker.error('failed to parse private message: message id not found');
      return null;
    }

    // Parse N from "共 N 条"
    final count = (element.querySelector('span.pm_o > span.xg1') ?? element.querySelector('dd.y.mtm.pm_o > span.xg1'))
        ?.innerText
        .split(' ')
        .elementAtOrNull(1)
        ?.parseToInt();

    final avatarNode = element.querySelector('dd.m.avt > a') ?? element.querySelector('dd.avt > a');
    final avatarUrl = _imgUrl(avatarNode?.querySelector('img'));
    final spaceUrl = avatarNode?.attributes['href']?.unescapeHtml()?.prependHost();

    if (avatarUrl == null || spaceUrl == null) {
      talker.error(
        'failed to parse private message: '
        'avatarUrl=$avatarUrl, spaceUrl=$spaceUrl',
      );
      return null;
    }

    final contentNode = element.querySelector('dd.ptm.pm_c') ?? element.querySelector('dd.ptm');
    if (contentNode == null) {
      talker.error('failed to parse private message: content node not found');
      return null;
    }

    final username = contentNode.querySelector('a.xw1')?.innerText.trim() ?? contentNode.querySelector('a')?.innerText;
    final lastMessageTime = contentNode.querySelector('span.xg1')?.dateTime();
    final chatUrl = element.querySelector('a#pmlist_${messageId}_a')?.attributes['href']?.unescapeHtml()?.prependHost();
    final message = parseLastMessage(contentNode);
    if (username == null || lastMessageTime == null || chatUrl == null || message == null) {
      talker.error(
        'failed to parse private message: '
        'hasUsername=${username != null}, lastMessageTime=$lastMessageTime, '
        'hasChatUrl=${chatUrl != null}, hasMessage=${message != null}',
      );
      return null;
    }

    return PersonalMessage(
      user: User(avatarUrl: avatarUrl, name: username, url: spaceUrl),
      message: message,
      lastMessageTime: lastMessageTime,
      count: count,
      chatUrl: chatUrl,
    );
  }
}

/// Broadcast messages received from system.
///
/// All broadcast messages have id "gpmlist_${MESSAGE_ID}".
@MappableClass()
final class BroadcastMessage with BroadcastMessageMappable {
  /// Constructor.
  const BroadcastMessage({required this.message, required this.messageTime, required this.redirectUrl});

  /// Message content text.
  final String message;

  /// Datetime of message.
  final DateTime messageTime;

  /// Url to redirect, usually is a thread page.
  ///
  /// Maybe some broadcast messages have no corresponding url
  /// so make it nullable.
  final String? redirectUrl;

  /// Find the content node in the broadcast message `<dl>`.
  static uh.Element? _findInfoNode(uh.Element element) =>
      element.querySelector('dd.ptm') ??
      element.querySelector('dd:nth-child(3)') ??
      element.querySelectorAll('dd').lastOrNull;

  /// Parse the message text in the content node, the datetime and menu part are removed.
  static String _parseMessageText(uh.Element infoNode) {
    final clone = infoNode.clone(true) as uh.Element;
    clone.querySelectorAll('span.xg1, span.pm_o, div.o, div.p_pop').forEach((e) => e.remove());
    return clone.innerText.replaceAll(' ', ' ').trim();
  }

  /// Convert a `<dl id="gpmlist_XXX">` node in the broadcast message list page into [BroadcastMessageV2].
  static BroadcastMessageV2? toV2(uh.Element element) {
    if (!element.id.startsWith('gpmlist_')) {
      return null;
    }
    final pmid = element.id.split('_').elementAtOrNull(1)?.parseToInt();
    final infoNode = _findInfoNode(element);
    final time = infoNode?.querySelector('span.xg1')?.dateTime();
    if (pmid == null || infoNode == null || time == null) {
      talker.error('failed to build broadcast message v2: pmid=$pmid, time=$time, hasInfo=${infoNode != null}');
      return null;
    }
    return BroadcastMessageV2(
      timestamp: time.millisecondsSinceEpoch ~/ 1000,
      data: _parseMessageText(infoNode),
      pmid: pmid,
      alreadyRead: !isUnreadNode(element),
    );
  }

  /// Whether the broadcast message page rendered the message node [element] (`<dl id="gpmlist_XXX">`) as unread: the
  /// class `newpm` (`{if !$gpmstatus[$grouppm[id]]} newpm{/if}`). As on the private message page, the red dot
  /// `div.newpm_avt` is printed in every node and is no marker ([PersonalMessage.isUnreadNode]).
  static bool isUnreadNode(uh.Element element) => element.classes.contains('newpm');

  /// Convert an unread broadcast message of the `notify` answer of the forum's app API (`announces`) into
  /// [BroadcastMessageV2]: its plain text (at most 300 characters), the time it was written (not when it reached the
  /// account, GitHub #154) as the page path reads it ([apiTimeOf], with the [timeOffset] of the answer) and the
  /// answer's `new`. Return null if id or time is missing.
  static BroadcastMessageV2? toV2FromApi(Map<String, dynamic> json, {required num timeOffset}) {
    final pmid = json['id'];
    final dateline = json['dateline'];
    if (pmid is! int || dateline is! int) {
      talker.error('failed to build broadcast message v2 from the app api: pmid=$pmid, dateline=$dateline');
      return null;
    }
    return BroadcastMessageV2(
      timestamp: apiTimeOf(dateline, timeOffset),
      data: json['text'] is String ? json['text'] as String : '',
      pmid: pmid,
      alreadyRead: json['new'] == 0,
    );
  }

  /// The broadcast messages of the answer [json] of `pmlist&filter=announce` (plugin 4.0.0), the read ones too, as
  /// the broadcast message page lists them (its first page: 20, newest first; the whole text, the page prints the
  /// first 100 characters), with the times read as the page path reads them ([toV2FromApi], the answer's
  /// `timeoffset`). The forum with private messages switched off (`closed` 1) lists none, as its page shows none.
  ///
  /// Null when the answer is not that list (no answer, an older plugin's `pmlist` without `filter`, the login prompt),
  /// or was served to another account than [uid] (the account `notify` was served to; null: not checked): the page is
  /// read instead.
  static List<BroadcastMessageV2>? listFromApi(Map<String, dynamic>? json, {required int? uid}) {
    if (json == null ||
        json['ok'] != 1 ||
        json['filter'] != 'announce' ||
        json['announces'] is! List ||
        (uid != null && json['uid'] != uid)) {
      return null;
    }
    final timeOffset = tsdmAppTimeOffset(json);
    return (json['announces'] as List)
        .whereType<Map<String, dynamic>>()
        .map((e) => toV2FromApi(e, timeOffset: timeOffset))
        .whereType<BroadcastMessageV2>()
        .toList();
  }

  /// Build a [BroadcastMessage] instance from dl node [element].
  ///
  /// Node MUST have id in format "gpmlist_${ID}".
  static BroadcastMessage? fromDl(uh.Element element) {
    if (!element.id.startsWith('gpmlist_')) {
      talker.error('failed to build broadcast message: id not found');
      return null;
    }

    final infoNode = _findInfoNode(element);
    if (infoNode == null) {
      talker.error('failed to build broadcast message: info node not found');
      return null;
    }
    final message = _parseMessageText(infoNode);
    final messageTime = infoNode.querySelector('span.xg1')?.dateTime();
    final redirectUrl = (infoNode.querySelector('a[href*="subop=viewg"]') ?? infoNode.querySelector('a[href]'))
        ?.attributes['href']
        ?.unescapeHtml()
        ?.prependHost();
    if (messageTime == null) {
      talker.error(
        'failed to build broadcast message: '
        'redirectUrl=$redirectUrl, messageTime=$messageTime',
      );
      return null;
    }

    return BroadcastMessage(message: message, messageTime: messageTime, redirectUrl: redirectUrl);
  }
}
