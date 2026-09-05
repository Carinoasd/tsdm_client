import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// Parsed friends list page.
final class FriendListPage {
  /// Constructor.
  const FriendListPage({
    required this.items,
    this.nextPageUrl,
    this.totalCount,
    this.ownerName,
    this.message,
    this.needLogin = false,
  });

  /// Friends in this page.
  final List<Friend> items;

  /// Absolute url of the next page, null when this is the last page.
  final String? nextPageUrl;

  /// Total friends count told by the page ("当前共有 N 个好友").
  final int? totalCount;

  /// Name of the user whose friends are listed, from the page title "NAME的好友".
  final String? ownerName;

  /// Notice shown instead of the list, e.g. the privacy message "抱歉！由于 NAME 的隐私设置，您不能访问当前内容".
  final String? message;

  /// The server asked to login.
  final bool needLogin;
}

final _ownerRe = RegExp('^(.*?)的好友');
final _creditsRe = RegExp(r'积分数:\s*(\d+)');
final _cssColorRe = RegExp(r'color\s*:\s*([^;]+)');

/// Parse a friends list page.
///
/// ```html
/// <p class="tbmu">当前共有 <span class="xw1">91</span> 个好友</p>
/// <ul class="buddy cl">
///   <li class="bbda cl">
///     <div class="avt"><a href="home.php?mod=space&uid=UID"><img data-src="AVATAR" class="_avt user_avatar"></a></div>
///     <h4><a href="home.php?mod=space&uid=UID" title="NAME" style="color:Red;">NAME</a></h4>
///     <p class="maxh"><font color="Red">GROUP</font> <img src="data/attachment/common/group/x.gif" />&nbsp;积分数: 625876</p>
///     <div class="xg1">...互动 | 关注TA...</div>
///   </li>
/// </ul>
/// <div class="pg">...<a href="...&page=2" class="nxt">下一页</a></div>
/// ```
///
/// The owner's own page lists "在线成员" suggestions in the same `ul.buddy` as `<li id="friend_UID_li">` without the
/// `bbda` class; they are not friends and are skipped.
FriendListPage parseFriendListPage(uh.Document document) {
  final title = document.querySelector('title')?.text ?? '';
  final ownerName = _ownerRe.firstMatch(title)?.group(1)?.trim();
  final listNode = document.querySelector('ul.buddy');
  if (listNode == null) {
    final privacyMessage = document.querySelector('div.nfl h2.xs2')?.innerText.trim();
    final noticeMessage = document.querySelector('div#messagetext')?.innerText.trim();
    final message = privacyMessage ?? noticeMessage;
    return FriendListPage(
      items: const [],
      ownerName: ownerName,
      message: message == null || message.isEmpty ? null : message,
      needLogin:
          document.querySelector('div#messagelogin') != null ||
          (noticeMessage?.contains('登录') ?? false) ||
          (noticeMessage?.contains('登入') ?? false),
    );
  }
  final items = listNode.querySelectorAll('li.bbda').map(_parseItem).whereType<Friend>().toList();
  final totalCount = (document.querySelector('p.tbmu span.xw1') ?? document.querySelector('div.tbmu span.xw1'))
      ?.innerText
      .trim()
      .parseToInt();
  final nextPageUrl = document.querySelector('div.pg > a.nxt')?.attributes['href']?.prependHost();
  return FriendListPage(items: items, nextPageUrl: nextPageUrl, totalCount: totalCount, ownerName: ownerName);
}

String? _colorInStyle(String? style) {
  if (style == null) {
    return null;
  }
  final color = _cssColorRe.firstMatch(style)?.group(1)?.trim();
  return color == null || color.isEmpty ? null : color;
}

Friend? _parseItem(uh.Element li) {
  final nameNode = li.querySelector('h4 > a');
  final uid = nameNode?.attributes['href']?.uriQueryParameter('uid');
  if (nameNode == null || uid == null || uid.isEmpty) {
    return null;
  }
  var username = nameNode.innerText.trim();
  if (username.isEmpty) {
    username = nameNode.attributes['title']?.trim() ?? '';
  }
  if (username.isEmpty) {
    return null;
  }

  final avatarUrl = li.querySelector('div.avt img')?.dataOriginalOrSrcImgUrl()?.trim();

  final infoNode = li.querySelector('p.maxh');
  final groupNode = infoNode?.querySelector('font');
  String? groupName;
  String? groupColor;
  if (groupNode != null) {
    groupName = groupNode.innerText.trim();
    groupColor = groupNode.attributes['color']?.trim() ?? _colorInStyle(groupNode.attributes['style']);
  } else if (infoNode != null) {
    // Plain text group name followed by the icon and the credits.
    groupName = infoNode.innerText.replaceAll(_creditsRe, '').replaceAll(' ', ' ').trim();
  }
  final credits = infoNode == null ? null : _creditsRe.firstMatch(infoNode.innerText)?.group(1);

  return Friend(
    uid: uid,
    username: username,
    avatarUrl: avatarUrl == null || avatarUrl.isEmpty ? null : avatarUrl.prependHost(),
    nameColor: _colorInStyle(nameNode.attributes['style']),
    groupName: groupName == null || groupName.isEmpty ? null : groupName,
    groupColor: groupColor == null || groupColor.isEmpty ? null : groupColor,
    groupIconUrl: infoNode?.querySelector('img')?.attributes['src']?.trim().prependHost(),
    credits: credits,
  );
}
