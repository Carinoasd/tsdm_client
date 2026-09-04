part of 'models.dart';

/// A brief user profile shows along with user's post in thread page.
@MappableClass()
final class UserBriefProfile with UserBriefProfileMappable {
  /// Constructor.
  const UserBriefProfile({
    required this.username,
    required this.avatarUrl,
    required this.uid,
    required this.nickname,
    required this.userGroup,
    required this.userGroupColor,
    required this.title,
    required this.recommended,
    required this.threadCount,
    required this.postCount,
    required this.famous,
    required this.coins,
    required this.publicity,
    required this.natural,
    required this.scheming,
    required this.spirit,
    required this.specialAttr,
    required this.specialAttrName,
    required this.specialAttr2,
    required this.specialAttrName2,
    required this.couple,
    required this.privilege,
    required this.registrationDate,
    required this.comeFrom,
    required this.online,
  });

  /// Username.
  ///
  /// 用户名
  final String username;

  /// User avatar url.
  ///
  /// Actually should not be empty but we notice it.
  final String? avatarUrl;

  /// User id.
  ///
  /// UID
  final String uid;

  /// Custom nickname.
  ///
  /// 昵称
  final String? nickname;

  /// Name of user group.
  ///
  /// 用户组
  final String userGroup;

  /// Additional color on user group.
  ///
  /// Presents or not.
  final Color? userGroupColor;

  /// Custom user title.
  ///
  /// 自定义头衔
  final String? title;

  /// Recommended thread count.
  ///
  /// 精华
  final String recommended;

  /// Thread posted count.
  ///
  /// 主题
  final String threadCount;

  /// Posts posted count.
  ///
  /// 帖子
  final String postCount;

  /// User attr score3.
  ///
  /// 威望
  final String famous;

  /// Coins count.
  ///
  /// 天使币
  final String coins;

  /// User attr.
  ///
  /// 宣传
  final String publicity;

  /// User attr score4
  ///
  /// 天然
  final String natural;

  /// User attr score5
  ///
  /// 腹黑
  final String scheming;

  /// User attr score
  ///
  /// 精灵
  final String spirit;

  /// Special attr that changes over time.
  final String specialAttr;

  /// Name of [specialAttr].
  final String specialAttrName;

  /// Special attr that changes over time.
  final String? specialAttr2;

  /// Name of [specialAttr].
  final String? specialAttrName2;

  // TODO: Reserve as link.
  /// Couple username.
  ///
  /// CP
  final String? couple;

  /// User privilege value.
  ///
  /// 阅读权限
  final String privilege;

  /// Date of account registration.
  ///
  /// 注册时间
  final String registrationDate;

  /// Place come from
  ///
  /// 来自
  final String? comeFrom;

  /// Now online or not.
  ///
  /// 状态
  final bool online;

  /// Build a [UserBriefProfile] instance from user node [element].
  ///
  /// User node must be:
  ///
  /// ```html
  /// <td id="userinfo_${UID}", ...> ... </td>
  /// ```
  ///
  /// [author] is the post author parsed from the post header, used as fallback of username, uid and avatar when they
  /// are not available in [element].
  static UserBriefProfile? buildFromUserProfileNode(uh.Element element, {User? author}) {
    final postId = element.id.split('_').lastOrNull;
    if (postId == null) {
      talker.error('failed to build UserBriefProfile: uid not found');
      return null;
    }
    final avatarNode = element.querySelector('div#ts_avatar_$postId');
    if (avatarNode == null && author == null) {
      talker.error('failed to build UserBriefProfile: avatar node not found');
      return null;
    }
    // Username, in priority:
    //
    // 1. Hidden user info popup `<div id="userinfo${PID}"><strong><a>${USERNAME}</a></strong>`.
    // 2. Author parsed from post header.
    // 3. Legacy `<div class="post_username_${N}">${USERNAME}</div>`.
    final popupNameNode = element.querySelector('div#userinfo$postId strong > a');
    final username =
        popupNameNode?.innerText.trim() ??
        author?.name ??
        avatarNode?.querySelector('div[class^="post_username"]')?.innerText.trim() ??
        avatarNode?.querySelector('div:nth-child(1)')?.innerText.trim();
    // Allow empty value.
    final nicknameRaw =
        avatarNode?.querySelector('div.post_nickname')?.innerText.trim() ??
        avatarNode?.querySelector('div:nth-child(2)')?.innerText.trim();
    final nickname = (nicknameRaw?.isEmpty ?? true) ? null : nicknameRaw;
    final avatarImgNode = avatarNode?.querySelector('div.avatar img') ?? avatarNode?.querySelector('img');
    final avatarUrl = avatarImgNode?._lazyImageUrl() ?? author?.avatarUrl;
    if (username == null || avatarUrl == null) {
      talker.info('warning when build UserBriefProfile: username or avatarUrl not found');
    }

    final statBarNode = element.querySelector('div.tsdm_statbar');
    if (statBarNode == null) {
      talker.error('failed to build UserBriefProfile: statBarNode not found');
      return null;
    }

    // User group name.
    //
    // `<em><a class="stat_authortitle"><font color="blue">${GROUP_NAME}</font></a></em>`
    //
    // The `<em>` node is not always present, fallback to the user group badge image.
    final userGroupNode = statBarNode.querySelector('em');
    final badgeImgNode = avatarNode?.querySelector('div.tsdm_norm_title img');
    final badgeAlt = badgeImgNode?.attributes['alt']?.trim();
    final badgeFileName = badgeImgNode?.attributes['src']?.split('/').lastOrNull?.split('.').firstOrNull;
    final userGroup =
        userGroupNode?.innerText.trim() ?? ((badgeAlt?.isNotEmpty ?? false) ? badgeAlt : null) ?? badgeFileName;
    final userGroupColorRaw = WebColors.fromString(userGroupNode?.querySelector('font')?.attributes['color']);
    final Color? userGroupColor;
    if (userGroupColorRaw.isValid) {
      userGroupColor = Color(userGroupColorRaw.colorValue);
    } else {
      userGroupColor = null;
    }

    String? uid;
    String? title;
    String? recommended;
    String? threadCount;
    String? postCount;
    String? famous;
    String? coins;
    String? publicity;
    String? natural;
    String? scheming;
    String? spirit;
    String? specialAttr;
    String? specialAttrName;
    String? specialAttr2;
    String? specialAttrName2;
    String? couple;
    String? privilege;
    String? registrationDate;
    String? comeFrom;

    bool? online;

    // Each attribute is a pair of `<span class="tsstat_icn_c">${NAME}:</span><span class="tsstat_txt_c">${VALUE}</span>`.
    //
    // The "状态:" row is followed by an `<a>` node rather than `<span>`, so do not simply slice all spans by 2.
    final keyNodes = statBarNode.children.where(
      (e) => e.localName == 'span' && (e.classes.contains('tsstat_icn_c') || e.innerText.trim().endsWith(':')),
    );
    for (final keyNode in keyNodes) {
      final valueNode = keyNode.nextElementSibling;
      if (valueNode == null || valueNode.localName != 'span') {
        continue;
      }
      final data = valueNode.innerText.trim();
      final _ = switch (keyNode.innerText.trim()) {
        'UID:' => uid = data,
        '头衔:' => title = data,
        '精华:' => recommended = data,
        '主题:' => threadCount = data,
        '帖子:' => postCount = data,
        '威望:' => famous = data,
        '天使币:' => coins = data,
        '宣传度:' => publicity = data,
        '天然°:' => natural = data,
        '腹黑°:' => scheming = data,
        '精灵:' => spirit = data,
        'CP:' => couple = data,
        '阅读权限:' => privilege = data,
        '注册时间:' => registrationDate = data,
        '来自:' => comeFrom = data,
        '状态:' => () {
          /* Do nothing */
        }(),
        final String v => () {
          if (specialAttr == null) {
            specialAttr = data;
            specialAttrName = v.replaceFirst(':', '');
          } else if (specialAttr2 == null) {
            specialAttr2 = data;
            specialAttrName2 = v.replaceFirst(':', '');
          }
        }(),
      };
    }

    // Online state.
    //
    // `<a title="性别:ひみつ-当前在线">` in stat bar, or `<em>当前在线</em>` in the hidden user info popup.
    online =
        statBarNode.querySelectorAll('a[title]').any((e) => e.attributes['title']?.contains('当前在线') ?? false) ||
        (element.querySelector('div#userinfo$postId em')?.innerText.contains('当前在线') ?? false);

    return UserBriefProfile(
      username: username ?? '',
      avatarUrl: avatarUrl,
      uid: uid ?? author?.uid ?? '',
      nickname: nickname,
      userGroup: userGroup ?? '',
      userGroupColor: userGroupColor,
      title: title,
      recommended: recommended ?? '',
      threadCount: threadCount ?? '',
      postCount: postCount ?? '',
      famous: famous ?? '',
      coins: coins ?? '',
      publicity: publicity ?? '',
      natural: natural ?? '',
      scheming: scheming ?? '',
      spirit: spirit ?? '',
      specialAttr: specialAttr ?? '',
      specialAttrName: specialAttrName ?? '',
      specialAttr2: specialAttr2,
      specialAttrName2: specialAttrName2,
      couple: couple ?? '',
      privilege: privilege ?? '',
      registrationDate: registrationDate ?? '',
      comeFrom: comeFrom,
      online: online,
    );
  }
}
