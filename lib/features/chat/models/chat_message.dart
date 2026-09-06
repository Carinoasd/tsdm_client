part of 'models.dart';

/// Chat message model.
///
/// Represent a single chat message with corresponding info including:
///
/// * Author.
/// * Time (Optional).
/// * Message content.
@MappableClass()
final class ChatMessage with ChatMessageMappable {
  /// Constructor.
  const ChatMessage({
    required this.author,
    required this.authorUid,
    required this.authorAvatarUrl,
    required this.message,
    required this.dateTime,
    this.dateOnly = false,
  });

  /// Username of message author.
  ///
  /// Optional because it's null when current sent the message.
  final String? author;

  /// Uid of message author.
  ///
  /// Required as it is used to visit user space page.
  final String? authorUid;

  /// Avatar url of author.
  final String? authorAvatarUrl;

  /// Message content.
  ///
  /// Html fragment.
  final String message;

  /// Optional message send time.
  ///
  /// Make this field optional because we do not have it in the chat dialog.
  final DateTime? dateTime;

  /// True when [dateTime] only carries a day: the chat dialog on Discuz! X5 groups messages under date separators and
  /// shows no time per message, so the time of day must not be displayed for it.
  final bool dateOnly;

  /// Parse the message html in the content node `dd.ptm` of the chat history page.
  ///
  /// ```html
  /// <dd class="ptm">
  ///   <a href="home.php?mod=space&uid=1104" class="xw1">Heidi</a>
  ///    &nbsp;
  ///   <br />
  ///   MESSAGE LINE 1<br />
  ///   MESSAGE LINE 2<br />
  ///   <span class="xg1"><span title="2026-9-3 23:40">昨天&nbsp;23:40</span></span>
  /// </dd>
  /// ```
  ///
  /// The message is everything after the first `<br>` and before the trailing time node.
  static String? _parseHistoryMessage(uh.Element contentNode) {
    final buffer = StringBuffer();
    var started = false;
    for (final node in contentNode.nodes) {
      if (node.nodeType == uh.Node.ELEMENT_NODE) {
        final e = node as uh.Element;
        if (!started) {
          if (e.localName == 'br') {
            started = true;
          }
          continue;
        }
        if (e.localName == 'span' && e.classes.contains('xg1')) {
          break;
        }
        buffer.write(e.outerHtml ?? '');
      } else if (started && node.nodeType == uh.Node.TEXT_NODE) {
        buffer.write(node.text ?? '');
      }
    }
    if (!started) {
      return null;
    }
    // Remove trailing <br>.
    return buffer.toString().trim().replaceFirst(RegExp(r'(<br\s*/?>\s*)+$'), '').trim();
  }

  /// Build from node `<dl>` with id starts with "pmlist_".
  static ChatMessage? fromDl(uh.Element element) {
    if (element.querySelector('form') != null) {
      // The last dl in chat history page is the reply form, not a message.
      return null;
    }
    final contentNode = element.querySelector('dd.ptm');
    // Not null when another user sent the message.
    final username = contentNode?.querySelector('a')?.innerText.trim();
    // Not null when current logged user sent the message.
    final currentUsername = contentNode?.querySelector('span.xi2')?.innerText.trim();
    if (username == null && currentUsername == null) {
      talker.error('failed to build chat message: author not found');
      return null;
    }

    final avatarNode = element.querySelector('dd.m.avt > a') ?? element.querySelector('dd.avt > a');
    final uid = avatarNode?.attributes['href']?.unescapeHtml()?.tryParseAsUri()?.queryParameters['uid'];

    final message = _parseHistoryMessage(contentNode!) ?? element.querySelector('dd:nth-child(4)')?.innerHtml;
    if (message == null) {
      talker.error('failed to build chat message: message not found');
      return null;
    }

    final dateTime = contentNode.querySelector('span.xg1')?.dateTime();

    final authorAvatarUrl = _imgUrl(avatarNode?.querySelector('img'));

    return ChatMessage(
      author: username ?? currentUsername,
      authorUid: uid,
      authorAvatarUrl: authorAvatarUrl,
      message: message,
      dateTime: dateTime,
    );
  }

  /// Build from node `<li class="cl pmm">`.
  ///
  /// Chat page, not chat history page.
  ///
  /// With username, without avatar and uid.
  ///
  /// Return null for the date separator `<li class="cl"><h4 class="xg1">2026-09-03</h4></li>`, use [parseDateLi] to
  /// get the date in it. [date] is the date of the message if known.
  static ChatMessage? fromLi(uh.Element element, {DateTime? date}) {
    final usernameNode = element.querySelector('div.pmt');
    if (usernameNode == null && element.querySelector('h4') != null) {
      // Date separator.
      return null;
    }
    final username = usernameNode?.innerText.split(':').first.trim();
    final message = element.querySelector('div.pmd')?.innerHtml;
    if (username == null || message == null) {
      talker.error(
        'failed to build chat message: '
        'hasUsername=${username != null}, hasMessage=${message != null}',
      );
      return null;
    }

    return ChatMessage(
      author: username,
      authorUid: null,
      authorAvatarUrl: null,
      message: message,
      dateTime: date,
      dateOnly: date != null,
    );
  }

  /// Parse the date in date separator `<li class="cl"><h4 class="xg1">2026-09-03</h4></li>`.
  ///
  /// Return null if [element] is not a date separator.
  static DateTime? parseDateLi(uh.Element element) =>
      element.querySelector('h4')?.innerText.trim().parseToDateTimeUtc8();
}

/// Get the image url of an `<img>` node, lazy loaded images use `data-src`.
String? _imgUrl(uh.Element? element) {
  if (element == null) {
    return null;
  }
  final dataSrc = element.attributes['data-src'];
  if (dataSrc != null && dataSrc.isNotEmpty) {
    return dataSrc.startsWith('http') ? dataSrc : '$baseUrl/${dataSrc.replaceFirst('./', '')}';
  }
  return element.imageUrl();
}
