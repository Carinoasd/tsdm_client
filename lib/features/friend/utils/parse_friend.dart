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
/// Two shapes share `ul.buddy`. Another member's list has `<li class="bbda">` items. The owner's own list has
/// `<li id="friend_UID_li">` items whose `h4` starts with a "热度" link and carries the group icon, with a manage menu
/// (分组／备注／删除); when the owner has no friends yet the same shape lists "在线成员" suggestions instead, each with a
/// "加为好友" link, and those are not friends.
FriendListPage parseFriendListPage(uh.Document document) {
  final title = document.querySelector('title')?.text ?? '';
  final ownerName = _ownerRe.firstMatch(title)?.group(1)?.trim();
  final lists = document.querySelectorAll('ul.buddy');
  if (lists.isEmpty) {
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
  final items = <Friend>[];
  for (final list in lists) {
    for (final li in list.children.where((e) => e.localName == 'li')) {
      if (li.classes.contains('bbda') || (_isOwnListItem(li) && !_hasAddFriendLink(li))) {
        final friend = _parseItem(li);
        if (friend != null) {
          items.add(friend);
        }
      }
    }
  }
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

/// `<li id="friend_UID_li">`: the owner's own list, or the 在线成员 suggestions shown while it is empty.
bool _isOwnListItem(uh.Element li) => li.id.startsWith('friend_') && li.id.endsWith('_li');

/// A suggestion carries a "加为好友" link; a friend carries the manage menu instead.
bool _hasAddFriendLink(uh.Element li) => li.querySelectorAll('a').any((a) {
  final href = a.attributes['href'] ?? '';
  return href.contains('ac=friend') && href.contains('op=add');
});

/// The link into the member's space inside the `h4`; the owner's own list puts a "热度" link (into spacecp) first.
uh.Element? _nameLink(uh.Element li) {
  for (final a in li.querySelectorAll('h4 a')) {
    final href = a.attributes['href'] ?? '';
    if (href.contains('mod=space&') && href.contains('uid=') && !href.contains('mod=spacecp')) {
      return a;
    }
  }
  return null;
}

Friend? _parseItem(uh.Element li) {
  final nameNode = _nameLink(li);
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
    // The owner's own list keeps the group icon next to the name instead of in the info line.
    groupIconUrl: (infoNode?.querySelector('img') ?? li.querySelector('h4 img'))?.attributes['src']
        ?.trim()
        .prependHost(),
    credits: credits,
  );
}
