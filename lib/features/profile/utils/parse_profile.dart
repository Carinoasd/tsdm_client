import 'package:collection/collection.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/profile/models/managed_forum.dart';
import 'package:tsdm_client/features/profile/models/models.dart';
import 'package:tsdm_client/features/profile/models/profile_medal.dart';
import 'package:universal_html/html.dart' as uh;

final RegExp _qqRe = RegExp(r'uin=(?<qq>\d+)');

final RegExp _birthdayRe = RegExp(r'((?<y>\d+) 年)? ?((?<m>\d+) 月)? ?((?<d>\d+) 日)?');

/// Parse the avatar url of the user in profile page [document].
///
/// Discuz X5: `div#uhd div.icn.avt img` (lazy loaded with `data-src`).
/// Discuz X3: `div#ct.ct2 div.sd div.hm > p > a > img`.
String? parseProfileAvatarUrl(uh.Document document) {
  final node =
      document.querySelector('div#uhd div.icn.avt img') ??
      document.querySelector('div#wp.wp div#ct.ct2 div.sd div.hm > p > a > img');
  if (node == null) {
    return null;
  }
  final dataSrc = node.attributes['data-src'];
  if (dataSrc != null && dataSrc.isNotEmpty) {
    return dataSrc.startsWith('http') ? dataSrc : '$baseUrl/${dataSrc.replaceFirst('./', '')}';
  }
  return node.imageUrl();
}

/// Check whether the page [document] is rendered for a logged in user.
///
/// Logged in pages have the user block `div#um` with username in `strong.vwmy` while guest pages have the login form
/// `form#lsform` instead.
bool isLoggedInDocument(uh.Document document) =>
    document.querySelector('div#um strong.vwmy') != null ||
    (document.querySelector('form#lsform') == null && document.querySelector('a#myprompt') != null);

/// Build a user profile [UserProfile] from given html [document].
///
/// Marked as public for testing.
TaskEither<AppException, UserProfile> buildProfile(uh.Document document) {
  final errorText = document.querySelector('div#messagetext > p')?.innerText;
  if (errorText != null) {
    return TaskEither.left(ServerRespondedErrorException(errorText));
  }

  // Discuz X5: div.bm_c.u_profile, Discuz X3: div#pprl > div.bm.bbda.
  final profileRootNode =
      document.querySelector('div.bm_c.u_profile') ?? document.querySelector('div#pprl > div.bm.bbda');

  if (profileRootNode == null) {
    return TaskEither.left(ProfileStatusNotFoundException());
  }

  final avatarUrl = parseProfileAvatarUrl(document);

  // Basic info
  final username = profileRootNode.querySelector('h2.mbn')?.nodes.firstOrNull?.text?.trim();
  final uid = profileRootNode.querySelector('h2.mbn > span.xw0')?.text?.split(': ').lastOrNull?.split(')').firstOrNull;

  ///////////  Basic status ///////////

  bool? emailVerified;
  bool? videoVerified;
  String? customTitle;
  String? signature;
  String? friendsCount;
  final online =
      profileRootNode.querySelector('h2.mbn > img.vm[alt="online"]') != null ||
      profileRootNode.querySelector('h2.mbn > span.olicon') != null;

  ///////////  Some other basic status ///////////

  String? birthdayYear;
  String? birthdayMonth;
  String? birthdayDay;
  String? zodiac;
  String? msn;
  String? introduction;
  String? nickname;
  String? gender;
  String? from;
  String? qq;

  // The first `div.pbm` block holds all basic info.
  final basicInfoList = (profileRootNode.querySelector('div.pbm')?.querySelectorAll('li') ?? <uh.Element>[])
      .map((e) => e.parseLiEmNode())
      .whereType<(String, String)>();

  for (final attr in basicInfoList) {
    switch (attr.$1) {
      case '邮箱状态':
        emailVerified = attr.$2 == '已验证';
      case '视频认证':
        videoVerified = attr.$2 == '已验证';
      case '自定义头衔':
        customTitle = attr.$2;
      case '个人签名':
        signature = attr.$2;
      case '统计信息':
        // Expect to have html fragment.
        friendsCount = attr.$2;
      case '生日':
        {
          final match = _birthdayRe.firstMatch(attr.$2);
          if (match != null) {
            birthdayYear = match.namedGroup('y');
            birthdayMonth = match.namedGroup('m');
            birthdayDay = match.namedGroup('d');
          }
        }

      case '星座':
        zodiac = attr.$2;
      case 'MSN':
        msn = attr.$2;
      case '自我介绍':
        introduction = attr.$2;
      case '昵称':
        nickname = attr.$2;
      case '性别':
        gender = attr.$2;
      case '来自':
        from = attr.$2;
      case 'QQ':
        // <a href="//wpa.qq.com/msgrd?v=3&uin=3586605849&site=..."><img src="static/image/common/qq.gif"></a>
        qq = _qqRe.firstMatch(attr.$2)?.namedGroup('qq') ?? attr.$2;
    }
  }

  final profileMedals = profileRootNode
      .querySelectorAll('p.md_ctrl img')
      .map((e) {
        final tipId = ProfileMedal.tipNodeId(e);
        return ProfileMedal.fromImg(e, tipNode: tipId == null ? null : document.getElementById(tipId));
      })
      .whereType<ProfileMedal>()
      .toList();

  // Block with title "管理以下版块".
  final managedForums = profileRootNode
      .querySelectorAll('div.pbm > h2.mbn')
      .firstWhereOrNull((e) => e.innerText.trim() == '管理以下版块')
      ?.parent
      ?.querySelectorAll('a')
      .map(ManagedForum.fromA)
      .whereType<ManagedForum>()
      .toList();

  // Check in status
  final checkinNode = profileRootNode.querySelector('div.pbm.mbm.bbda.c');
  final checkinDaysCount = checkinNode?.querySelector('p:nth-child(2)')?.firstEndDeepText()?.parseToInt();
  final checkinThisMonthCount = checkinNode?.querySelector('p:nth-child(3)')?.firstEndDeepText();
  final checkinRecentTime = checkinNode?.querySelector('p:nth-child(4)')?.firstEndDeepText();
  final checkinAllCoins = checkinNode?.querySelector('p:nth-child(5) font:nth-child(1)')?.firstEndDeepText();
  final checkinLastTimeCoin = checkinNode?.querySelector('p:nth-child(5) font:nth-child(2)')?.firstEndDeepText();
  final checkinLevel = checkinNode?.querySelector('p:nth-child(6) font:nth-child(1)')?.firstEndDeepText();
  final checkinNextLevel = checkinNode?.querySelector('p:nth-child(6) font:nth-child(2)')?.firstEndDeepText();
  final checkinNextLevelDays = checkinNode
      ?.querySelector('p:nth-child(6) font:nth-child(3)')
      ?.firstEndDeepText()
      ?.parseToInt();
  final checkinTodayStatus = checkinNode?.querySelector('p:nth-child(7)')?.firstEndDeepText();

  ///////////  User group status ///////////

  String? moderatorGroup;
  String? userGroup;

  final userGroupInfoList = profileRootNode
      .querySelector('ul#pbbs')
      ?.previousElementSibling
      ?.querySelectorAll('li')
      .map((e) => e.parseLiEmNode())
      .whereType<(String, String)>();
  if (userGroupInfoList != null) {
    for (final info in userGroupInfoList) {
      switch (info.$1) {
        case '用户组':
          userGroup = _absoluteImageUrls(info.$2);
        case '管理组':
          moderatorGroup = _absoluteImageUrls(info.$2);
      }
    }
  }

  ///////////  Activity status ///////////

  String? onlineTime;
  DateTime? registerTime;
  DateTime? lastVisitTime;
  DateTime? lastActiveTime;
  String? registerIP;
  String? lastVisitIP;
  DateTime? lastPostTime;
  String? timezone;

  // Activity overview
  // TODO: Parse manager groups and user groups belonged to, here.
  final activityNode = profileRootNode.querySelector('ul#pbbs');
  final activityInfoList =
      activityNode?.querySelectorAll('li').map((e) => e.parseLiEmNode()).whereType<(String, String)>().toList() ?? [];

  for (final info in activityInfoList) {
    switch (info.$1) {
      case '在线时间':
        onlineTime = info.$2;
      case '注册时间':
        registerTime = info.$2.parseToDateTimeUtc8();
      case '最后访问':
        lastVisitTime = info.$2.parseToDateTimeUtc8();
      case '上次活动时间':
        lastActiveTime = info.$2.parseToDateTimeUtc8();
      case '上次发表时间':
        lastPostTime = info.$2.parseToDateTimeUtc8();
      case '所在时区':
        timezone = info.$2;
      case '注册 IP': // Privacy info
        registerIP = info.$2;
      case '上次访问 IP': // Privacy info
        lastVisitIP = info.$2;
    }
  }

  ///////////  Statistics status ///////////
  String? credits;
  String? famous;
  String? coins;
  String? publicity;
  String? natural;
  String? scheming;
  String? spirit;
  // Special attr that changes over time.
  String? specialAttr;
  // Name of special attr.
  String? specialAttrName;
  // Special attr that changes over time. Optionally used.
  String? specialAttr2;
  // Name of special attr. Optionally used.
  String? specialAttrName2;

  final statisticsInfoList = profileRootNode
      .querySelectorAll('div#psts > ul > li')
      .map((e) => e.parseLiEmNode())
      .whereType<(String, String)>();
  for (final stat in statisticsInfoList) {
    switch (stat.$1) {
      case '积分':
        credits = stat.$2;
      case '威望':
        famous = stat.$2;
      case '天使币':
        coins = stat.$2;
      case '宣传':
        publicity = stat.$2;
      case '天然':
        natural = stat.$2;
      case '腹黑':
        scheming = stat.$2;
      case '精灵':
        spirit = stat.$2;
      case '已用空间':
        // Not interested.
        break;
      default:
        {
          if (specialAttr == null) {
            specialAttr = stat.$2;
            specialAttrName = stat.$1.trim().replaceFirst(':', '');
          } else {
            specialAttr2 = stat.$2;
            specialAttrName2 = stat.$1.trim().replaceFirst(':', '');
          }
        }
    }
  }

  final profile = UserProfile(
    avatarUrl: avatarUrl,
    username: username,
    uid: uid,

    ///////////  Basic status ///////////
    emailVerified: emailVerified,
    videoVerified: videoVerified,
    customTitle: customTitle,
    signature: signature,
    friendsCount: friendsCount,
    online: online,
    birthdayYear: birthdayYear,
    birthdayMonth: birthdayMonth,
    birthdayDay: birthdayDay,
    zodiac: zodiac,
    msn: msn,
    introduction: introduction,
    nickname: nickname,
    gender: gender,
    from: from,
    qq: qq,
    profileMedals: profileMedals,
    mangedForums: managedForums,

    ///////////  Checkin status ///////////
    checkinDaysCount: checkinDaysCount == 0 ? null : checkinDaysCount,
    checkinThisMonthCount: checkinThisMonthCount,
    checkinRecentTime: checkinRecentTime,
    checkinAllCoins: checkinAllCoins,
    checkinLastTimeCoin: checkinLastTimeCoin,
    checkinLevel: checkinLevel,
    checkinNextLevel: checkinNextLevel,
    checkinNextLevelDays: checkinNextLevelDays == 0 ? null : checkinNextLevelDays,
    checkinTodayStatus: checkinTodayStatus,

    ///////////  User group status ///////////
    moderatorGroup: moderatorGroup,
    userGroup: userGroup,

    ///////////  Activity status ///////////
    onlineTime: onlineTime,
    registerTime: registerTime,
    lastVisitTime: lastVisitTime,
    lastActiveTime: lastActiveTime,
    registerIP: registerIP,
    lastVisitIP: lastVisitIP,
    lastPostTime: lastPostTime,
    timezone: timezone,

    ///////////  Statistics status ///////////
    credits: credits,
    famous: famous,
    coins: coins,
    publicity: publicity,
    natural: natural,
    scheming: scheming,
    spirit: spirit,
    specialAttr: specialAttr,
    specialAttrName: specialAttrName,
    specialAttr2: specialAttr2,
    specialAttrName2: specialAttrName2,
  );

  return TaskEither.right(profile);
}

/// Convert relative `<img src="data/...">` urls in html fragment [html] to absolute ones.
String _absoluteImageUrls(String html) =>
    html.replaceAllMapped(RegExp('src="(?!http)([^"]+)"'), (m) => 'src="$baseUrl/${m.group(1)}"');

/// Parse unread notice count and unread message flag from the page header.
///
/// Marked as public for testing.
(int unreadNoticeCount, bool hasUnreadMessage) buildUnreadInfoStatus(uh.Document document) {
  // Check notice status.
  var hasUnreadNotice = 0;
  final noticeNode = document.querySelector('a#myprompt');
  if (noticeNode?.classes.contains('new') ?? false) {
    hasUnreadNotice = noticeNode?.innerText.split('(').lastOrNull?.split(')').firstOrNull?.parseToInt() ?? 0;
  }

  final hasUnreadMessage = document.querySelector('a#pm_ntc')?.classes.contains('new') ?? false;

  return (hasUnreadNotice, hasUnreadMessage);
}
