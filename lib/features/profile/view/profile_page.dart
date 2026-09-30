import 'dart:async';
import 'dart:math' as math;

import 'package:dart_bbcode_web_colors/dart_bbcode_web_colors.dart';
import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/widgets/user_block_button.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/widgets/checkin_button.dart';
import 'package:tsdm_client/features/friend/widgets/add_friend_dialog.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/features/profile/bloc/profile_bloc.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/profile/utils/parse_profile.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/medal.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/html/adaptive_color.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/debounce_buttons.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/medal_group_view.dart';
import 'package:tsdm_client/widgets/notice_button.dart';
import 'package:tsdm_client/widgets/obscure_list_tile.dart';
import 'package:tsdm_client/widgets/single_line_text.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Padding is (kToolbarHeight * 0.8).floor().toDouble();
const _appBarBackgroundTopPadding = 44.0;
const _appBarBackgroundImageHeight = 80.0;
const _appBarAvatarHeight = 80.0;
const double _appBarExpandHeight = _appBarBackgroundImageHeight + _appBarAvatarHeight + _appBarBackgroundTopPadding;

/// All checking days required from current level to next level.
///
/// Data:
///
/// ``` text
/// lvMaster 伴坛终老 300天
/// lv10 以坛为家III  250天
/// lv9  以坛为家II   200天   3505
/// lv8  以坛为家III  150天   4288
/// lv7  常住居民III  100天   5392
/// lv6  常住居民II   60天    7072
/// lv5  长居居民I    30天    10007
/// lv4  偶尔看看III  15天    13925
/// lv3  偶尔看看II    7天    19191
/// lv2  偶尔看看I     3天
/// lv1  初来乍到      1天
/// ```
const List<int> _checkinNextLevelExp = [
  1 - 0,
  3 - 1,
  7 - 3,
  15 - 7,
  30 - 15,
  60 - 30,
  100 - 60,
  150 - 100,
  200 - 150,
  250 - 200,
  300 - 250,
];

enum _ProfileActions {
  viewNotification,
  checkin,
  viewPoints,
  switchUserGroup,
  switchTitle,
  editProfile,
  logout,
  editAvatar,
  blockedUsers,
}

/// Page of user profile.
class ProfilePage extends StatefulWidget {
  /// Constructor.
  const ProfilePage({this.uid, this.username, this.heroTag, super.key});

  /// Other user uid.
  final String? uid;

  /// Other user username.
  final String? username;

  /// Optional hero tag.
  final String? heroTag;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _refreshController = EasyRefreshController(controlFinishRefresh: true);
  late final ScrollController _scrollController;

  static final _checkinLevelNumberRe = RegExp(r'LV\.(?<level>\d+)');

  /// Flag indicating show app bar title or not.
  ///
  /// Only show title (with true value) when app bar is fully expanded.
  bool _showAppBarTitle = false;

  void _updateAppBarState() {
    if (_scrollController.offset > _appBarExpandHeight && !_showAppBarTitle) {
      setState(() {
        _showAppBarTitle = true;
      });
    } else if (_scrollController.offset < _appBarExpandHeight && _showAppBarTitle) {
      setState(() {
        _showAppBarTitle = false;
      });
    }
  }

  Widget _buildSliverAppBar(BuildContext context, ProfileState state, {required bool logout}) {
    final tr = context.t.profilePage;
    final userProfile = state.userProfile!;
    final colorScheme = Theme.of(context).colorScheme;

    if (!context.mounted) {
      return sizedBoxEmpty;
    }

    final inCheckin = context.read<CheckinBloc>().state is CheckinStateLoading;

    late final List<Widget> actions;
    if (widget.username == null && widget.uid == null) {
      // Current is current logged user's profile page.
      actions = [
        IconButton(
          icon: const Icon(Icons.emoji_events_outlined),
          tooltip: context.t.achievementsPage.title,
          onPressed: () async => context.pushNamed(ScreenPaths.achievements),
        ),
        IconButton(
          icon: const Icon(Icons.person_search_outlined),
          tooltip: tr.searchAsThreadAuthor,
          onPressed: () async => context.pushNamed(
            ScreenPaths.search,
            queryParameters: {'authorUid': ?userProfile.uid, 'authorName': ?userProfile.username},
          ),
        ),
        PopupMenuButton<_ProfileActions>(
          onSelected: (action) async {
            switch (action) {
              case _ProfileActions.viewNotification:
                await context.pushNamed(ScreenPaths.notice);
              case _ProfileActions.checkin:
                context.read<CheckinBloc>().add(const CheckinRequested());
              case _ProfileActions.viewPoints:
                await context.pushNamed(ScreenPaths.points);
              case _ProfileActions.switchUserGroup:
                if (logout) {
                  return;
                }
                await context.pushNamed(ScreenPaths.switchUserGroup);
              case _ProfileActions.switchTitle:
                if (logout) {
                  return;
                }
                await context.pushNamed(ScreenPaths.switchTitle);
              case .editProfile:
                if (logout) {
                  return;
                }
                await context.pushNamed(ScreenPaths.editUserProfile);
              case _ProfileActions.logout:
                final logout = await showQuestionDialog(
                  context: context,
                  title: tr.logout,
                  message: tr.areYouSureToLogout,
                );
                if (!context.mounted) {
                  return;
                }
                if (logout == null || !logout) {
                  return;
                }
                context.read<ProfileBloc>().add(ProfileLogoutRequested());
              case _ProfileActions.editAvatar:
                await context.pushNamed(ScreenPaths.editAvatar);
              case _ProfileActions.blockedUsers:
                await context.pushNamed(ScreenPaths.userBlock);
            }
          },
          // Same items and actions, grouped: activity, own profile, account level, then logout apart in the error
          // color.
          itemBuilder: (context) => [
            PopupMenuItem(
              value: _ProfileActions.viewNotification,
              child: Row(
                children: [const NoticeIcon(), sizedBoxPopupMenuItemIconSpacing, Text(context.t.noticePage.title)],
              ),
            ),
            PopupMenuItem(
              enabled: !inCheckin,
              value: _ProfileActions.checkin,
              child: Row(
                children: [
                  const CheckinButton(useIcon: true),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(tr.checkin.title),
                ],
              ),
            ),
            PopupMenuItem(
              value: _ProfileActions.viewPoints,
              child: Row(
                children: [
                  const Icon(Icons.show_chart_outlined),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(tr.statistics.title),
                ],
              ),
            ),
            const PopupMenuDivider(height: 8),
            PopupMenuItem(
              value: .editProfile,
              child: Row(
                children: [
                  const Icon(Symbols.person_edit),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(context.t.editUserProfilePage.title),
                ],
              ),
            ),
            PopupMenuItem(
              value: _ProfileActions.editAvatar,
              child: Row(
                children: [
                  const Icon(Symbols.familiar_face_and_zone),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(context.t.editAvatarPage.title),
                ],
              ),
            ),
            PopupMenuItem(
              value: _ProfileActions.switchUserGroup,
              child: Row(
                children: [
                  const Icon(Symbols.change_circle),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(context.t.switchUserGroupPage.title),
                ],
              ),
            ),
            PopupMenuItem(
              value: _ProfileActions.switchTitle,
              child: Row(
                children: [
                  const Icon(Symbols.badge),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(context.t.myTitlesPage.title),
                ],
              ),
            ),
            PopupMenuItem(
              value: _ProfileActions.blockedUsers,
              child: Row(
                children: [
                  const Icon(Icons.block_outlined),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(context.t.userBlock.manageEntry),
                ],
              ),
            ),
            const PopupMenuDivider(height: 8),
            PopupMenuItem(
              enabled: !logout,
              value: _ProfileActions.logout,
              child: Row(
                children: [
                  DebounceIcon(
                    icon: Icon(Icons.logout_outlined, color: colorScheme.error),
                    shouldDebounce: logout,
                  ),
                  sizedBoxPopupMenuItemIconSpacing,
                  Text(tr.logout, style: TextStyle(color: colorScheme.error)),
                ],
              ),
            ),
          ],
        ),
      ];
    } else {
      // Other user's profile page.
      actions = [
        IconButton(
          icon: const Icon(Icons.person_search_outlined),
          tooltip: tr.searchAsThreadAuthor,
          onPressed: () async => context.pushNamed(
            ScreenPaths.search,
            queryParameters: {'authorUid': ?userProfile.uid, 'authorName': ?userProfile.username},
          ),
        ),
        if ((widget.uid ?? userProfile.uid) != null)
          IconButton(
            icon: const Icon(Icons.person_add_alt_1_outlined),
            tooltip: context.t.friendPage.addFriend.tooltip,
            onPressed: () async =>
                showAddFriendDialog(context, uid: widget.uid ?? userProfile.uid!, username: userProfile.username),
          ),
        IconButton(
          icon: const Icon(Icons.email_outlined),
          tooltip: context.t.postCard.profileDialog.pmTooltip,
          onPressed: () async => context.pushNamed(
            ScreenPaths.chat,
            pathParameters: {'uid': widget.uid ?? userProfile.uid!},
            extra: <String, dynamic>{'username': userProfile.username},
          ),
        ),
        // Local and silent: nothing is sent to the forum.
        if (int.tryParse(widget.uid ?? userProfile.uid ?? '') case final int blockUid)
          UserBlockButton(uid: blockUid, username: userProfile.username ?? widget.username ?? '$blockUid'),
      ];
    }

    // Flexible space of the app bar: a background (the blurred avatar, or a tinted gradient when the user has no
    // avatar, which used to leave the expanded bar empty), the page ground under the avatar and the avatar itself.
    final Widget avatar = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: colorScheme.surfaceContainerLowest, width: 3),
        boxShadow: [BoxShadow(color: colorScheme.shadow.withValues(alpha: 0.12), blurRadius: 8)],
      ),
      child: HeroUserAvatar(
        username: userProfile.username ?? '',
        avatarUrl: userProfile.avatarUrl ?? noAvatarUrl,
        heroTag: widget.heroTag,
        maxRadius: _appBarAvatarHeight / 2,
        minRadius: _appBarAvatarHeight / 2,
      ),
    );
    final background = userProfile.avatarUrl != null
        ? Container(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: CachedImageProvider(userProfile.avatarUrl!),
                fit: .fitWidth,
                isAntiAlias: true,
              ),
            ),
            foregroundDecoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  colorScheme.surfaceContainerLowest.withValues(alpha: 0.6),
                  colorScheme.surfaceContainerLowest,
                ],
                begin: .topCenter,
                end: .bottomCenter,
                stops: const [0.0, 0.55],
              ),
            ),
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [colorScheme.primaryContainer, colorScheme.surfaceContainerLowest],
                begin: .topCenter,
                end: .bottomCenter,
                stops: const [0.0, 0.7],
              ),
            ),
          );
    final flexSpace = Stack(
      // Disable clip, let profile avatar show outside the stack.
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: background),
        // Background color under avatar, height is half of avatar height.
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: ColoredBox(
            color: colorScheme.surfaceContainerLowest,
            // Add 4 here because the avatar row (Positioned() below) has 4 padding at bottom.
            child: const SizedBox(height: _appBarAvatarHeight / 2 + 4),
          ),
        ),
        // Avatar, lined up with the centered content below.
        Positioned(
          bottom: 4,
          left: appCenteredPadding(MediaQuery.sizeOf(context).width, maxWidth: appFormMaxWidth, minPadding: 12).left,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              avatar,
              Tooltip(
                message: tr.online,
                child: Icon(
                  Icons.circle,
                  size: 16,
                  color: Theme.of(context).brightness == Brightness.dark ? Colors.green[400] : Colors.green[700],
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return SliverAppBar(
      title: _showAppBarTitle ? Text(state.userProfile?.username ?? '') : null,
      pinned: true,
      floating: true,
      actions: actions,
      expandedHeight: _appBarExpandHeight,
      flexibleSpace: FlexibleSpaceBar(background: flexSpace),
    );
  }

  /// Check-in level, progress to the next level and the check-in numbers, one surface.
  Widget? _buildCheckinSection(BuildContext context, ProfileState state) {
    final userProfile = state.userProfile;
    if (userProfile == null ||
        userProfile.checkinLevel == null ||
        userProfile.checkinDaysCount == null &&
            (!(userProfile.checkinLevel?.contains('Master') ?? false) || userProfile.checkinNextLevelDays == null)) {
      return null;
    }
    final tr = context.t.profilePage;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    int? totalDays;
    final double percent;
    final String description;

    // Parse checkin level number.
    final int? checkinLevelNumber;
    if (userProfile.checkinLevel == null) {
      checkinLevelNumber = null;
    } else if (userProfile.checkinLevel!.contains('Master')) {
      // Max level
      checkinLevelNumber = 11;
    } else {
      checkinLevelNumber = _checkinLevelNumberRe
          .firstMatch(userProfile.checkinLevel!)
          ?.namedGroup('level')
          ?.parseToInt();
    }
    if (userProfile.checkinNextLevelDays != null) {
      totalDays = userProfile.checkinDaysCount! + userProfile.checkinNextLevelDays!;
      if (checkinLevelNumber != null && checkinLevelNumber >= 0 && checkinLevelNumber < _checkinNextLevelExp.length) {
        // If checkin level is recognized, set the checkin progress percentage
        // to (checkin count in current level  /  all days count required to
        // next level).
        //
        // e.g. From level 5 to level 6 requires (60-30) days and user is 10
        //      days before step into level 6, so the percent is:
        //      1 - 10 / (60 - 30)
        percent = math.max(1 - userProfile.checkinNextLevelDays! / _checkinNextLevelExp[checkinLevelNumber], 0);
      } else {
        percent = userProfile.checkinDaysCount! / totalDays;
      }
      description = '${userProfile.checkinDaysCount}/$totalDays';
    } else {
      percent = 1;
      description = '${userProfile.checkinDaysCount}/-';
    }

    return _ProfileSection(
      title: tr.checkin.title,
      icon: Icons.event_available_outlined,
      children: [
        // Level and progress to the next level.
        AppInsetBlock(
          padding: edgeInsetsL12T12R12B12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    userProfile.checkinLevel!,
                    style: textTheme.titleSmall?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold),
                  ),
                  Text(description, style: textTheme.labelMedium?.copyWith(color: colorScheme.outline)),
                ],
              ),
              sizedBoxW8H8,
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: percent, minHeight: 8),
              ),
            ],
          ),
        ),
        _InfoGrid([
          if (userProfile.checkinDaysCount != null)
            (Icons.calendar_month_outlined, tr.checkinDaysCount, '${userProfile.checkinDaysCount}'),
          if (userProfile.checkinThisMonthCount != null)
            (Icons.calendar_today_outlined, tr.checkinDaysInThisMonth, userProfile.checkinThisMonthCount!),
          if (userProfile.checkinRecentTime != null)
            (Icons.history_outlined, tr.checkinRecentTime, userProfile.checkinRecentTime!),
          if (userProfile.checkinAllCoins != null)
            (FontAwesomeIcons.coins, tr.checkinAllCoins, userProfile.checkinAllCoins!),
          if (userProfile.checkinLastTimeCoin != null)
            (Icons.monetization_on_outlined, tr.checkinLastTimeCoins, userProfile.checkinLastTimeCoin!),
          if (userProfile.checkinTodayStatus != null)
            (Icons.today_outlined, tr.checkinTodayStatus, userProfile.checkinTodayStatus ?? '-'),
        ]),
      ],
    );
  }

  /// Name, uid, nickname and custom title, verification marks and the personal details, one surface.
  Widget _buildIdentitySection(BuildContext context, ProfileState state) {
    final tr = context.t.profilePage;
    final userProfile = state.userProfile!;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    // Friends count info.
    final (count: friendsCount, url: friendsPage) = parseFriendsInfo(userProfile.friendsCount);

    // Birthday.
    final birthDayText = [
      userProfile.birthdayYear,
      userProfile.birthdayMonth,
      userProfile.birthdayDay,
    ].whereType<String>().join('.');

    final subtitles = [?userProfile.nickname, ?userProfile.customTitle];

    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Username (tap to copy) and uid.
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              GestureDetector(
                child: SingleLineText(
                  userProfile.username ?? context.t.profilePage.title,
                  style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                onTap: () async => copyToClipboard(context, userProfile.username ?? ''),
              ),
              if (userProfile.uid != null) AppInfoPill(icon: Icons.tag, label: userProfile.uid!),
            ],
          ),
          if (subtitles.isNotEmpty) ...[
            sizedBoxW4H4,
            // Wraps instead of scrolling sideways.
            Text(subtitles.join(' · '), style: textTheme.titleSmall?.copyWith(color: colorScheme.outline)),
          ],
          sizedBoxW12H12,
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (userProfile.uid != null)
                // Email verify state.
                IconButton(
                  icon: const Icon(Icons.email_outlined),
                  tooltip: userProfile.emailVerified ?? false ? tr.emailVerified : tr.emailNotVerified,
                  onPressed: () async {
                    final content = userProfile.emailVerified ?? false ? tr.emailVerified : tr.emailNotVerified;
                    showSnackBar(context: context, message: content);
                  },
                  isSelected: userProfile.emailVerified ?? false,
                ),
              IconButton(
                icon: const Icon(Icons.photo_camera_outlined),
                tooltip: userProfile.videoVerified ?? false ? tr.videoVerified : tr.videoNotVerified,
                onPressed: () async {
                  final content = userProfile.videoVerified ?? false ? tr.videoVerified : tr.videoNotVerified;
                  showSnackBar(context: context, message: content);
                },
                isSelected: userProfile.videoVerified ?? false,
              ),
              TextButton.icon(
                icon: const Icon(Icons.group_outlined),
                label: Text(friendsCount),
                onPressed: friendsPage != null
                    ? () async {
                        await context.dispatchAsUrl(friendsPage);
                      }
                    : null,
              ),
              if (userProfile.gender != null) AppInfoPill(icon: Icons.face_2_outlined, label: userProfile.gender!),
              if (birthDayText.isNotEmpty) AppInfoPill(icon: Icons.cake_outlined, label: birthDayText),
              if (userProfile.zodiac != null) AppInfoPill(icon: MdiIcons.starCrescent, label: userProfile.zodiac!),
              if (userProfile.from != null) AppInfoPill(icon: Icons.location_on_outlined, label: userProfile.from!),
              if (userProfile.msn != null) AppInfoPill(icon: Icons.group_outlined, label: userProfile.msn!),
              if (userProfile.qq != null) AppInfoPill(icon: FontAwesomeIcons.qq, label: userProfile.qq!),
            ],
          ),
        ],
      ),
    );
  }

  /// The two group images with their colored names, side by side, each wrapping under the other when narrow.
  Widget? _buildUserGroupSection(BuildContext context, ProfileState state) {
    final tr = context.t.profilePage;
    final userProfile = state.userProfile!;
    final inDark = Theme.of(context).brightness == Brightness.dark;

    final moderatorGroupDoc = parseHtmlDocument(userProfile.moderatorGroup ?? '').body;
    final moderatorGroupImg = moderatorGroupDoc?.children.lastOrNull?.imageUrl();
    final moderatorGroupName = moderatorGroupDoc?.firstEndDeepText()?.trim();
    final Color? moderatorGroupNameColor;
    final moderatorColorValue = WebColors.fromString(
      moderatorGroupDoc?.querySelector('font')?.attributes['color'] ?? '',
    );
    if (moderatorColorValue.isValid) {
      moderatorGroupNameColor = inDark
          ? Color(moderatorColorValue.colorValue).adaptiveDark()
          : Color(moderatorColorValue.colorValue);
    } else {
      moderatorGroupNameColor = null;
    }

    final userGroupDoc = parseHtmlDocument(userProfile.userGroup ?? '').body;
    final userGroupImg = userGroupDoc?.children.lastOrNull?.imageUrl();
    final userGroupName = userGroupDoc?.firstEndDeepText()?.trim();
    final Color? userGroupNameColor;
    final userColorValue = WebColors.fromString(userGroupDoc?.querySelector('font')?.attributes['color'] ?? '');
    if (userColorValue.isValid) {
      userGroupNameColor = inDark ? Color(userColorValue.colorValue).adaptiveDark() : Color(userColorValue.colorValue);
    } else {
      userGroupNameColor = null;
    }

    if (moderatorGroupImg == null && userGroupImg == null) {
      return null;
    }

    Widget group(String image, String name, Color? color) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CachedImage(image, maxWidth: 200, height: profileBadgeHeight, fit: BoxFit.contain),
        sizedBoxW8H8,
        Text(
          name,
          textAlign: TextAlign.start,
          style: TextStyle(color: color, fontWeight: FontWeight.bold),
        ),
      ],
    );

    return _ProfileSection(
      title: tr.userGroup,
      icon: Icons.groups_outlined,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            if (moderatorGroupImg != null) group(moderatorGroupImg, moderatorGroupName ?? '', moderatorGroupNameColor),
            if (userGroupImg != null) group(userGroupImg, userGroupName ?? '-', userGroupNameColor),
          ],
        ),
      ],
    );
  }

  List<Widget> _buildSliverContent(BuildContext context, ProfileState state) {
    final tr = context.t.profilePage;
    final userProfile = state.userProfile!;

    // Introduction.
    //
    // Introduction is captured as raw html code when have multiple lines.
    uh.BodyElement? introductionContent;
    if (userProfile.introduction != null) {
      introductionContent = parseHtmlDocument(userProfile.introduction ?? '').body;
    }
    // Signature.
    //
    // Signature is captured as raw html code because server side provides some
    // rich text formats.
    uh.BodyElement? signatureContent;
    if (userProfile.signature != null) {
      signatureContent = parseHtmlDocument(userProfile.signature ?? '').body;
    }

    final userGroup = _buildUserGroupSection(context, state);
    final checkin = _buildCheckinSection(context, state);

    final activityItems = <_InfoItem>[
      if (userProfile.onlineTime != null) (Icons.timelapse_outlined, tr.onlineTime, userProfile.onlineTime!),
      if (userProfile.registerTime != null)
        (MdiIcons.timelineAlertOutline, tr.registerTime, userProfile.registerTime!.yyyyMMDDHHMM()),
      if (userProfile.lastVisitTime != null)
        (MdiIcons.timelineClockOutline, tr.lastVisitTime, userProfile.lastVisitTime!.yyyyMMDDHHMM()),
      if (userProfile.lastActiveTime != null)
        (MdiIcons.timelineCheckOutline, tr.lastActiveTime, userProfile.lastActiveTime!.yyyyMMDDHHMM()),
      if (userProfile.lastPostTime != null)
        (MdiIcons.timelinePlusOutline, tr.lastPostTime, userProfile.lastPostTime!.yyyyMMDDHHMM()),
      if (userProfile.timezone != null) (Symbols.globe_location_pin, tr.timezone, userProfile.timezone!),
    ];

    final statisticsItems = <_InfoItem>[
      if (userProfile.credits != null) (null, tr.statistics.credits, userProfile.credits!),
      if (userProfile.famous != null) (null, tr.statistics.famous, userProfile.famous!),
      if (userProfile.coins != null) (null, tr.statistics.coins, userProfile.coins!),
      if (userProfile.publicity != null) (null, tr.statistics.publicity, userProfile.publicity!),
      if (userProfile.natural != null) (null, tr.statistics.natural, userProfile.natural!),
      if (userProfile.scheming != null) (null, tr.statistics.scheming, userProfile.scheming!),
      if (userProfile.spirit != null) (null, tr.statistics.spirit, userProfile.spirit!),
      // Special attr changes over time.
      // Here is dynamic and not translated.
      if (userProfile.specialAttr != null && userProfile.specialAttrName != null)
        (null, userProfile.specialAttrName!, userProfile.specialAttr!),
      if (userProfile.specialAttr2 != null && userProfile.specialAttrName2 != null)
        (null, userProfile.specialAttrName2!, userProfile.specialAttr2!),
    ];

    final sections = <Widget>[
      _buildIdentitySection(context, state),

      // Self introduction and signature, rendered as the forum wrote them.
      if (introductionContent != null || signatureContent != null)
        _ProfileSection(
          title: introductionContent != null ? tr.introduction : tr.signature,
          icon: Icons.notes_outlined,
          children: [
            if (introductionContent != null)
              AppInsetBlock(padding: edgeInsetsL12T12R12B12, child: munchElement(context, introductionContent)),
            if (introductionContent != null && signatureContent != null)
              AppSectionHeader(tr.signature, icon: Icons.draw_outlined, padding: EdgeInsets.zero),
            if (signatureContent != null)
              AppInsetBlock(padding: edgeInsetsL12T12R12B12, child: munchElement(context, signatureContent)),
          ],
        ),

      ?userGroup,

      // Secondary title of the profile owner.
      _ProfileSecondaryTitle(parsedUrl: state.secondaryTitleUrl, profileUid: int.tryParse(userProfile.uid ?? '')),

      /// Medals, if any.
      if (userProfile.profileMedals?.isNotEmpty ?? false)
        _ProfileSection(
          title: tr.medals,
          icon: Icons.military_tech_outlined,
          children: [
            MedalGroupView(
              userProfile.profileMedals!
                  .map((e) => Medal(name: e.name, image: e.image, alter: e.alter, description: e.description))
                  .toList(),
            ),
          ],
        ),

      // Medal centre, own titles and title shop: all meant for the logged user (buy/apply/switch for themselves), so
      // the entry only shows on the user's own profile, like the achievements entry in the app bar.
      if (widget.username == null && widget.uid == null)
        AppSurface(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.workspace_premium_outlined),
                title: Text(context.t.medalTitleHub.title),
                subtitle: Text(context.t.medalTitleHub.entryDescription),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async => context.pushNamed(ScreenPaths.medalTitleHub),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.account_balance_outlined),
                title: Text(context.t.bank.title),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async => context.pushNamed(ScreenPaths.bank),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.catching_pokemon),
                title: Text(context.t.pokemon.title),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async => context.pushNamed(ScreenPaths.pokemon),
              ),
            ],
          ),
        ),

      if (userProfile.mangedForums?.isNotEmpty ?? false)
        _ProfileSection(
          title: tr.mangedForum,
          icon: Icons.admin_panel_settings_outlined,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: userProfile.mangedForums!
                  .map(
                    (e) => ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(e.name),
                      onPressed: () async => context.pushNamed(ScreenPaths.forum, pathParameters: {'fid': '${e.fid}'}),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),

      /// Checkin level.
      ?checkin,

      /// Activity
      _ProfileSection(
        title: tr.activityStatus,
        icon: Icons.timeline_outlined,
        children: [
          if (activityItems.isNotEmpty) _InfoGrid(activityItems),
          // IP addresses stay hidden until asked for.
          if (userProfile.registerIP != null)
            ObscureListTile(
              contentPadding: EdgeInsets.zero,
              minTileHeight: 0,
              leading: const Icon(Symbols.add_location_alt),
              title: Text(tr.registerIP),
              subtitle: Text(userProfile.registerIP!),
            ),
          if (userProfile.lastVisitIP != null)
            ObscureListTile(
              contentPadding: EdgeInsets.zero,
              minTileHeight: 0,
              leading: const Icon(Symbols.moved_location),
              title: Text(tr.lastVisitIP),
              subtitle: Text(userProfile.lastVisitIP!),
            ),
        ],
      ),

      /// Statistics: value blocks sized by their text, not a fixed 70 pixels grid cut at large text scales.
      if (statisticsItems.isNotEmpty)
        _ProfileSection(
          title: tr.statistics.title,
          icon: Icons.bar_chart_outlined,
          children: [_InfoGrid(statisticsItems, minTileWidth: 110, maxColumns: 4, emphasizeValue: true)],
        ),
    ];

    // All content widgets in profile main sliver list.
    return [
      for (var i = 0; i < sections.length; i++) ...[if (i > 0) const SizedBox(height: appSurfaceGap), sections[i]],
    ];
  }

  Widget _buildContent(
    BuildContext context,
    ProfileState state, {
    required Exception? failedToLogoutReason,
    required bool logout,
  }) {
    // Check whether have failed logout attempt.
    if (failedToLogoutReason != null) {
      showSnackBar(context: context, message: '$failedToLogoutReason');
    }

    _refreshController.finishRefresh();

    return EasyRefresh.builder(
      controller: _refreshController,
      scrollController: _scrollController,
      header: const MaterialHeader(),
      onRefresh: () {
        context.read<ProfileBloc>().add(ProfileRefreshRequested(uid: widget.uid, username: widget.username));
        // The own title comes from the titles page of the account, refresh it with the profile.
        final currentTitle = context.readOrNull<CurrentTitleCubit>();
        final currentUid = context.readOrNull<AuthenticationRepository>()?.currentUser?.uid;
        if (currentTitle != null && currentUid != null && '$currentUid' == state.userProfile?.uid) {
          unawaited(currentTitle.ensureLoaded(force: true));
        }
      },
      childBuilder: (context, physics) => CustomScrollView(
        controller: _scrollController,
        physics: physics,
        slivers: [
          // Real app bar when data loaded.
          _buildSliverAppBar(context, state, logout: logout),
          SliverPadding(
            // Centered and at most [appFormMaxWidth] wide on wide windows, room for the navigation bar at the end.
            padding: appCenteredPadding(
              MediaQuery.sizeOf(context).width,
              maxWidth: appFormMaxWidth,
              minPadding: 12,
            ).copyWith(top: 12, bottom: 24 + MediaQuery.paddingOf(context).bottom),
            sliver: SliverList(delegate: SliverChildListDelegate(_buildSliverContent(context, state))),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_updateAppBarState);
  }

  @override
  void dispose() {
    _refreshController.dispose();
    _scrollController
      ..removeListener(_updateAppBarState)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => ProfileBloc(
        profileRepository: RepositoryProvider.of<ProfileRepository>(context),
        authenticationRepository: RepositoryProvider.of<AuthenticationRepository>(context),
      )..add(ProfileLoadRequested(username: widget.username, uid: widget.uid)),
      child: BlocBuilder<ProfileBloc, ProfileState>(
        builder: (context, state) {
          // Default AppBar only use when loading data or failed to load data.
          // Keep this widget so that user can go back to the previous page in
          // some error state (e.g. network error).
          final appBar = switch (state.status) {
            ProfileStatus.initial ||
            ProfileStatus.loading ||
            ProfileStatus.needLogin ||
            ProfileStatus.failure => AppBar(title: Text(context.t.profilePage.title)),
            ProfileStatus.success || ProfileStatus.loggingOut => null,
          };

          // Main content of user profile.
          // Contain a sliver version app bar to show when data loaded.
          final body = switch (state.status) {
            ProfileStatus.initial || ProfileStatus.loading => const CenteredCircularIndicator(),
            ProfileStatus.needLogin => NeedLoginPage(
              backUri: GoRouterState.of(context).uri,
              needPop: true,
              popCallback: (context) {
                context.read<ProfileBloc>().add(ProfileRefreshRequested(uid: widget.uid, username: widget.username));
              },
            ),
            ProfileStatus.failure => buildRetryButton(context, () {
              context.read<ProfileBloc>().add(ProfileLoadRequested(username: widget.username, uid: widget.uid));
            }, message: state.failedToLogoutReason?.message),
            ProfileStatus.success || ProfileStatus.loggingOut => _buildContent(
              context,
              state,
              failedToLogoutReason: state.failedToLogoutReason,
              logout: state.status == ProfileStatus.loggingOut,
            ),
          };

          return Scaffold(
            appBar: appBar,
            body: SafeArea(top: false, bottom: false, child: body),
          );
        },
      ),
    );
  }
}

/// Secondary title of the profile owner.
///
/// * The image the profile page itself renders for its owner, when it has one ([parseProfileSecondaryTitleUrl]).
/// * Otherwise, on the profile of the logged in account only, the title read from that account's titles page
///   ([CurrentTitleCubit]). Other users never get the current account's title.
class _ProfileSecondaryTitle extends StatefulWidget {
  const _ProfileSecondaryTitle({required this.parsedUrl, required this.profileUid});

  /// Title image found in the profile page.
  final String? parsedUrl;

  /// Uid of the profile owner, as the profile page states it.
  final int? profileUid;

  @override
  State<_ProfileSecondaryTitle> createState() => _ProfileSecondaryTitleState();
}

class _ProfileSecondaryTitleState extends State<_ProfileSecondaryTitle> {
  CurrentTitleCubit? _cubit;

  /// The profile shown is the logged in account's.
  bool get _isOwn {
    final uid = widget.profileUid;
    return uid != null && uid == context.readOrNull<AuthenticationRepository>()?.currentUser?.uid;
  }

  @override
  void initState() {
    super.initState();
    _cubit = context.readOrNull<CurrentTitleCubit>();
    final cubit = _cubit;
    if (widget.parsedUrl == null && cubit != null && _isOwn) {
      unawaited(cubit.ensureLoaded());
    }
  }

  Widget _section(BuildContext context, Widget badge) => _ProfileSection(
    title: context.t.profilePage.secondaryTitle,
    icon: Icons.badge_outlined,
    children: [
      Align(alignment: AlignmentDirectional.centerStart, child: badge),
    ],
  );

  @override
  Widget build(BuildContext context) {
    // Match the group badge height while leaving room for the page and surface paddings.
    final width = SecondaryTitleBadge.fitWidth(
      math.min(MediaQuery.sizeOf(context).width, appFormMaxWidth) - 56,
      preferred: SecondaryTitleBadge.widthFor(profileBadgeHeight),
    );
    final parsedUrl = widget.parsedUrl;
    if (parsedUrl != null) {
      return _section(context, SecondaryTitleBadge(parsedUrl, width: width));
    }
    final cubit = _cubit;
    if (cubit == null || !_isOwn) {
      return sizedBoxEmpty;
    }
    return BlocBuilder<CurrentTitleCubit, CurrentTitleState>(
      bloc: cubit,
      builder: (context, state) {
        final url = state.imageUrlFor(widget.profileUid);
        if (url != null) {
          return _section(
            context,
            SecondaryTitleBadge(url, key: ValueKey(url), width: width, semanticLabel: state.title?.name),
          );
        }
        return switch (state.statusFor(widget.profileUid)) {
          CurrentTitleStatus.loading => _section(context, SecondaryTitlePlaceholder(width: width)),
          // Reading failed: say so and offer to try again, never claim that no title is in use.
          CurrentTitleStatus.failure => _section(
            context,
            SecondaryTitleRetry(width: width, onRetry: () => unawaited(cubit.ensureLoaded())),
          ),
          CurrentTitleStatus.initial || CurrentTitleStatus.success => sizedBoxEmpty,
        };
      },
    );
  }
}

/// A section of the profile: a surface with a header and its content stacked with a small gap.
class _ProfileSection extends StatelessWidget {
  const _ProfileSection({required this.title, required this.icon, required this.children});

  final String title;

  final IconData icon;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => AppSurface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        AppSectionHeader(title, icon: icon, padding: const EdgeInsets.only(bottom: 8)),
        for (var i = 0; i < children.length; i++) ...[if (i > 0) sizedBoxW8H8, children[i]],
      ],
    ),
  );
}

/// Optional icon, caption and value of a profile number or date.
typedef _InfoItem = (IconData? icon, String label, String value);

/// Value blocks laid out in as many columns as fit the room at the current text scale (at most [maxColumns]); the
/// blocks of a row share its height, nothing is cut.
class _InfoGrid extends StatelessWidget {
  const _InfoGrid(this.items, {this.minTileWidth = 160, this.maxColumns = 3, this.emphasizeValue = false});

  final List<_InfoItem> items;

  /// Narrowest a block gets at text scale 1.
  final double minTileWidth;

  final int maxColumns;

  /// Show the value larger than the caption (numbers).
  final bool emphasizeValue;

  Widget _tile(BuildContext context, _InfoItem item) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final (icon, label, value) = item;
    return AppInsetBlock(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[Icon(icon, size: 18, color: colorScheme.primary), sizedBoxW8H8],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: textTheme.labelSmall?.copyWith(color: colorScheme.outline)),
                Text(
                  value,
                  style: (emphasizeValue ? textTheme.titleMedium : textTheme.bodyMedium)?.copyWith(
                    fontWeight: emphasizeValue ? FontWeight.bold : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final columns = (constraints.maxWidth / (minTileWidth * scale)).floor().clamp(1, maxColumns);
      final rows = appRowCount(items.length, columns);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var row = 0; row < rows; row++) ...[
            if (row > 0) sizedBoxW8H8,
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var column = 0; column < columns; column++) ...[
                    if (column > 0) sizedBoxW8H8,
                    Expanded(
                      child: row * columns + column < items.length
                          ? _tile(context, items[row * columns + column])
                          : sizedBoxEmpty,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      );
    },
  );
}
