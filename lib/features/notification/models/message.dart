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
        'failed to build personal message v2: peerUid=$peerUid, peerUsername=$peerUsername, time=$time, '
        'message=$message',
      );
      return null;
    }
    final sender = parseSentByMe(contentNode);
    final hasNewFlag = element.querySelector('div.newpm_avt') != null;
    return PersonalMessageV2(
      timestamp: time.millisecondsSinceEpoch ~/ 1000,
      data: message,
      peerUid: peerUid.parseToInt() ?? 0,
      peerUsername: peerUsername,
      sender: sender,
      alreadyRead: sender || !hasNewFlag,
    );
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
        'username=$username, lastMessageTime=$lastMessageTime, '
        'chatUrl=$chatUrl, message=$message',
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
    final hasNewFlag = element.querySelector('div.newpm_avt') != null || element.classes.contains('newpm');
    return BroadcastMessageV2(
      timestamp: time.millisecondsSinceEpoch ~/ 1000,
      data: _parseMessageText(infoNode),
      pmid: pmid,
      alreadyRead: !hasNewFlag,
    );
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
