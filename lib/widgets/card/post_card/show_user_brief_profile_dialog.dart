import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/widgets/user_block_button.dart';
import 'package:tsdm_client/features/friend/widgets/add_friend_dialog.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/medal.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/html/adaptive_color.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/bubble.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/card/post_card/checkin.dart';
import 'package:tsdm_client/widgets/card/post_card/pokemon.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/medal_group_view.dart';
import 'package:universal_html/parsing.dart';

/// Width available to the content of the brief profile dialog in a window [windowWidth] wide.
///
/// Mirrors the constraint of [CustomAlertDialog] (70% of the window, at most 400) without its 24px side paddings.
double briefProfileDialogContentWidth(double windowWidth) => math.min(windowWidth * 0.7, 400) - 48;

/// Height the stacked dialog header needs: the avatar row, the name and the pills under it.
const _stackedHeaderHeight = 132.0;

/// Show a dialog to display user brief profile.
///
/// Data only available in thread page on all replied users.
Future<void> showUserBriefProfileDialog(
  BuildContext context,
  UserBriefProfile userBriefProfile,
  String userSpaceUrl, {
  // Hero tag for user avatar.
  required String avatarHeroTag,
  // Hero tag for user name.
  required String nameHeroTag,
  required List<Medal> medals,
  required String? badge,
  required String? secondBadge,
  required String? signature,
  required PostFloorPokemon? pokemon,
  required PostCheckinStatus? checkin,
}) async {
  await showHeroDialog<void>(
    context,
    (context, _, _) => _UserBriefProfileDialog(
      userBriefProfile,
      userSpaceUrl,
      avatarHeroTag,
      nameHeroTag,
      medals,
      badge,
      secondBadge,
      signature,
      pokemon,
      checkin,
    ),
  );
}

class _UserBriefProfileDialog extends StatefulWidget {
  const _UserBriefProfileDialog(
    this.profile,
    this.userSpaceUrl,
    this.avatarHeroTag,
    this.nameHeroTag,
    this.medals,
    this.badge,
    this.secondBadge,
    this.signature,
    this.pokemon,
    this.checkin,
  );

  final UserBriefProfile profile;

  final String userSpaceUrl;

  final String avatarHeroTag;
  final String nameHeroTag;

  /// User medals.
  final List<Medal> medals;

  /// User group title badge image url, usually presents.
  final String? badge;

  /// User group title badge image url, optional.
  final String? secondBadge;

  /// Html format user signature.
  final String? signature;

  /// Pokemon info.
  final PostFloorPokemon? pokemon;

  /// Checkin info.
  final PostCheckinStatus? checkin;

  @override
  State<_UserBriefProfileDialog> createState() => _UserBriefProfileDialogState();
}

class _UserBriefProfileDialogState extends State<_UserBriefProfileDialog> {
  @override
  Widget build(BuildContext context) {
    final tr = context.t.postCard.profileDialog;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final primaryColor = colorScheme.primary;
    final pokemon = widget.pokemon;
    final checkin = widget.checkin;

    const sectionSeparator = sizedBoxW16H16;
    const titleContentSeparator = sizedBoxW4H4;
    Widget sectionTitle(String title, IconData icon) =>
        AppSectionHeader(title, icon: icon, padding: const EdgeInsets.symmetric(vertical: 4));

    final inDarkTheme = Theme.of(context).brightness == Brightness.dark;
    final colorOffset = inDarkTheme ? 300 : 700;
    // Measured like the badges below: the dialog content has no layout builder (the dialog sizes to intrinsics).
    final contentWidth = briefProfileDialogContentWidth(MediaQuery.sizeOf(context).width);
    final statWidth = (contentWidth - 8) / 2;
    final secondBadgeWidth = SecondaryTitleBadge.fitWidth(
      contentWidth,
      preferred: SecondaryTitleBadge.widthFor(profileBadgeHeight),
    );
    final authorUid = int.tryParse(widget.profile.uid);
    final auth = context.readOrNull<AuthenticationRepository>();
    // The actions follow the account the device acts as, also before the stored session was verified (an offline
    // start, a thread opened from a link): the own floor must not offer "add friend" then.
    final accountUid = auth?.effectiveCurrentUid;
    final isSelf = authorUid != null && authorUid == accountUid;
    // The title badge needs a verified current account; the uid is compared again by the badge against the title it
    // holds.
    final ownFloor = widget.secondBadge == null && authorUid != null && authorUid == auth?.currentUser?.uid;

    final avatar = Hero(
      tag: widget.avatarHeroTag,
      child: CircleAvatar(
        radius: 30,
        backgroundImage: CachedImageProvider(
          widget.profile.avatarUrl ?? noAvatarUrl,
          usage: ImageUsageInfoUserAvatar(widget.profile.username),
        ),
      ),
    );

    // Fix text style lost.
    // ref: https://github.com/flutter/flutter/issues/30647#issuecomment-480980280
    final name = Hero(
      tag: widget.nameHeroTag,
      flightShuttleBuilder: (_, _, _, _, toHeroContext) =>
          DefaultTextStyle(style: DefaultTextStyle.of(toHeroContext).style, child: toHeroContext.widget),
      child: Text(widget.profile.username, style: textTheme.titleLarge?.copyWith(color: primaryColor)),
    );

    // Uid and online state as small pills next to the name.
    final pills = Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        AppInfoPill(icon: Icons.tag, label: 'UID ${widget.profile.uid}'),
        AppInfoPill(
          icon: widget.profile.online ? Icons.circle : Icons.circle_outlined,
          label: widget.profile.online ? tr.status.online : tr.status.offline,
          tooltip: tr.status.title,
        ),
      ],
    );

    final headerActions = <Widget>[
      IconButton.filledTonal(
        icon: const Icon(Icons.email_outlined),
        tooltip: tr.pmTooltip,
        onPressed: () => context.pushNamed(
          ScreenPaths.chat,
          pathParameters: {'uid': widget.profile.uid},
          extra: <String, dynamic>{'username': widget.profile.username},
        ),
      ),
      IconButton.filledTonal(
        icon: const Icon(Icons.person_outlined),
        tooltip: tr.profileTooltip,
        onPressed: () async => context.dispatchAsUrl(widget.userSpaceUrl),
      ),
    ];

    // The title of an AlertDialog is not flexible and CustomAlertDialog keeps it within 30% of the window height, so
    // stacking the avatar, the name and the pills cut the pills off on a phone in landscape. One row fits there.
    final titleContent = MediaQuery.sizeOf(context).height * 0.3 >= _stackedHeaderHeight
        ? <Widget>[
            Row(children: [avatar, const Spacer(), ...headerActions]),
            sizedBoxW12H12,
            name,
            sizedBoxW4H4,
            pills,
          ]
        : <Widget>[
            Row(
              children: [
                avatar,
                sizedBoxW12H12,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [name, sizedBoxW4H4, pills],
                  ),
                ),
                ...headerActions,
              ],
            ),
          ];

    // Numbers of the author, two per row: value first (in its color), name under it.
    Widget stat(IconData icon, String name, String? value, Color? color) => SizedBox(
      width: statWidth,
      child: AppInsetBlock(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color ?? colorScheme.secondary),
            sizedBoxW8H8,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value ?? '-',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleSmall?.copyWith(color: color, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall?.copyWith(color: colorScheme.outline),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final profileContent = [
      // What to do with the author, before the details; nothing to open without a uid and a name.
      if (_AuthorActions.hasAny(uid: authorUid, username: widget.profile.username)) ...[
        _AuthorActions(
          uid: authorUid,
          username: widget.profile.username,
          isSelf: isSelf,
          hasAccount: accountUid != null,
          width: contentWidth,
        ),
        sectionSeparator,
      ],

      // Who the author is: group, titles, names and dates, one line each.
      sectionTitle(tr.tabName.info, Icons.badge_outlined),
      titleContentSeparator,
      AppInsetBlock(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            _UserProfilePair(
              Icons.group_outlined,
              tr.group,
              widget.profile.userGroup,
              inDarkTheme ? widget.profile.userGroupColor?.adaptiveDark() : widget.profile.userGroupColor,
            ),
            if (widget.profile.title != null)
              _UserProfilePair(Icons.badge_outlined, tr.title, widget.profile.title, Colors.blue[colorOffset]),
            _UserProfilePair(MdiIcons.idCard, tr.nickname, widget.profile.nickname, Colors.blue[colorOffset]),
            if (widget.profile.couple != null && widget.profile.couple!.isNotEmpty)
              _UserProfilePair(Icons.diversity_1_outlined, tr.cp, widget.profile.couple, Colors.pink[colorOffset]),
            _UserProfilePair(
              Icons.feedback_outlined,
              tr.privilege,
              widget.profile.privilege,
              Colors.orange[colorOffset],
            ),
            _UserProfilePair(
              Icons.event_note_outlined,
              tr.registration,
              widget.profile.registrationDate,
              Colors.blue[colorOffset],
            ),
            if (widget.profile.comeFrom != null)
              _UserProfilePair(Icons.pin_drop_outlined, tr.from, widget.profile.comeFrom, Colors.teal[colorOffset]),
            // The online state is the pill under the name.
          ],
        ),
      ),
      sizedBoxW8H8,
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          stat(Icons.thumb_up_outlined, tr.recommended, widget.profile.recommended, Colors.red[colorOffset]),
          stat(Icons.book_outlined, tr.thread, widget.profile.threadCount, Colors.green[colorOffset]),
          stat(MdiIcons.commentEditOutline, tr.post, widget.profile.postCount, Colors.cyan[colorOffset]),
          stat(Icons.emoji_people_outlined, tr.famous, widget.profile.famous, Colors.purple[colorOffset]),
          stat(FontAwesomeIcons.coins, tr.coins, widget.profile.coins, Colors.purple[colorOffset]),
          stat(Icons.campaign_outlined, tr.publicity, widget.profile.publicity, Colors.purple[colorOffset]),
          stat(Icons.water_drop_outlined, tr.natural, widget.profile.natural, Colors.purple[colorOffset]),
          stat(MdiIcons.dominoMask, tr.scheming, widget.profile.scheming, Colors.purple[colorOffset]),
          stat(Icons.stream_outlined, tr.spirit, widget.profile.spirit, Colors.purple[colorOffset]),
          // Special attr, dynamic and not translated.
          stat(
            MdiIcons.heartOutline,
            widget.profile.specialAttrName,
            widget.profile.specialAttr,
            Colors.purple[colorOffset],
          ),
          // Optional special attr, dynamic and not tranlsated.
          if (widget.profile.specialAttr2 != null && widget.profile.specialAttrName2 != null)
            stat(
              MdiIcons.heartOutline,
              widget.profile.specialAttrName2!,
              widget.profile.specialAttr2,
              Colors.purple[colorOffset],
            ),
        ],
      ),

      sectionSeparator,

      // Badges from this author's own floor: the user group badge and the secondary title. Both keep their natural
      // aspect ratio and share a display height; narrow dialogs wrap instead of squeezing either image.
      //
      // When the floor carries no secondary title and the author is the current account, the title that account
      // uses is shown instead (CurrentTitleCubit: read-only title page of that account, keyed by uid and dropped on
      // account changes). The floor of anybody else never gets it: no data there means no second badge.
      if (widget.badge != null || widget.secondBadge != null || ownFloor) ...[
        sectionTitle(tr.badges, Icons.military_tech_outlined),
        titleContentSeparator,
        Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (widget.badge != null)
              CachedImage(
                widget.badge!,
                key: const ValueKey('brief-profile-group-badge'),
                maxWidth: contentWidth,
                height: profileBadgeHeight,
                fit: BoxFit.contain,
              ),
            if (widget.secondBadge != null)
              SecondaryTitleBadge(
                widget.secondBadge!,
                key: const ValueKey('brief-profile-floor-title'),
                width: secondBadgeWidth,
              )
            else if (ownFloor)
              CurrentAccountTitleBadge(
                key: const ValueKey('brief-profile-account-title'),
                uid: authorUid,
                width: secondBadgeWidth,
              ),
          ],
        ),
        sectionSeparator,
      ],

      // Medal
      if (widget.medals.isNotEmpty) ...[
        sectionTitle(tr.medals, Icons.workspace_premium_outlined),
        titleContentSeparator,
        MedalGroupView(widget.medals),
        sectionSeparator,
      ],

      // Signature, if any. Size is unpredicted; the dialog body scrolls, so it is laid out at its natural height.
      if (widget.signature != null) ...[
        sectionTitle(tr.tabName.signature, Icons.draw_outlined),
        titleContentSeparator,
        AppInsetBlock(child: munchElement(context, parseHtmlDocument(widget.signature!).body!)),
        sectionSeparator,
      ],

      // Pokemon: the primary one large, the others as small chips.
      if (pokemon != null) ...[
        sectionTitle(tr.pokemon, Icons.catching_pokemon),
        titleContentSeparator,
        AppInsetBlock(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CachedImage(
                    pokemon.primaryPokemon.image,
                    width: pokemonPrimaryImageSize.width,
                    height: pokemonPrimaryImageSize.height,
                  ),
                  sizedBoxW8H8,
                  Expanded(
                    child: Text(
                      pokemon.primaryPokemon.name,
                      style: textTheme.titleSmall?.copyWith(color: colorScheme.secondary, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              if (pokemon.otherPokemon != null && pokemon.otherPokemon!.isNotEmpty) ...[
                sizedBoxW8H8,
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: pokemon.otherPokemon!
                      .map(
                        (e) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CachedImage(
                              e.image,
                              width: pokemonNotPrimaryImageSize.width,
                              height: pokemonNotPrimaryImageSize.height,
                            ),
                            sizedBoxW4H4,
                            Text(e.name, style: textTheme.bodySmall),
                          ],
                        ),
                      )
                      .toList(),
                ),
              ],
            ],
          ),
        ),
        sectionSeparator,
      ],

      // Checkin status: feeling on the start side, the words in a bubble, statistics under them.
      if (checkin != null) ...[
        sectionTitle(tr.checkin, Icons.event_available_outlined),
        titleContentSeparator,
        AppInsetBlock(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      CachedImage(
                        checkin.feelingImage,
                        width: feelingImageSize.width,
                        height: feelingImageSize.height,
                      ),
                      sizedBoxW4H4,
                      Text(checkin.feelingName, style: textTheme.bodyMedium?.copyWith(color: colorScheme.secondary)),
                    ],
                  ),
                  sizedBoxW8H8,
                  Flexible(
                    child: CustomPaint(
                      painter: BubblePainter(
                        color: colorScheme.primaryContainer,
                        alignment: Alignment.topLeft,
                        tail: true,
                      ),
                      child: Container(
                        margin: const EdgeInsets.fromLTRB(14, 7, 7, 7),
                        child: Text(
                          checkin.words,
                          style: textTheme.bodyMedium?.copyWith(color: colorScheme.onPrimaryContainer),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              sizedBoxW8H8,
              // Checkin statistics info.
              Text(checkin.statistics, style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    ];

    return CustomAlertDialog.sync(
      clipBehavior: Clip.antiAlias,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: titleContent,
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: profileContent, //profileContent,
      ), //profileContent,
    );
  }
}

/// Chips opening the threads and replies of the author, adding the author as a friend and blocking the author.
///
/// Friend and block are for other accounts only, need a uid and an account in use; without a uid the lists are opened
/// by name. Block is left out where the app provides no [UserBlockCubit] and while the list of the current account is
/// not known.
///
/// Compact, and friend and block are icons only. On a phone the dialog content is about 200 wide (a 360 wide window:
/// 204, see [briefProfileDialogContentWidth]), too narrow for the chips to wrap into two rows by themselves: there the
/// two list chips share the first row and the actions take the second. Wider content lets the chips wrap naturally.
class _AuthorActions extends StatelessWidget {
  const _AuthorActions({
    required this.uid,
    required this.username,
    required this.isSelf,
    required this.hasAccount,
    required this.width,
  });

  /// Parsed author uid, null if the floor carries no number.
  final int? uid;

  final String username;

  final bool isSelf;

  /// Whether the device acts as an account: friend and block need one.
  final bool hasAccount;

  /// Width of the dialog content.
  final double width;

  /// Content narrower than this gets the fixed two rows.
  static const _wrapWidth = 300.0;

  /// Whether the author offers anything to open: a uid or a name.
  static bool hasAny({required int? uid, required String username}) => _validUid(uid) != null || username.isNotEmpty;

  static int? _validUid(int? uid) => uid != null && uid > 0 ? uid : null;

  @override
  Widget build(BuildContext context) {
    final uid = _validUid(this.uid);
    // Same state as the block button of the profile page: the list of the current account has to be known. The
    // selector exists only where the cubit does; uid and isSelf are fixed for the life of the dialog.
    if (uid != null && hasAccount && !isSelf && context.readOrNull<UserBlockCubit>() != null) {
      return BlocSelector<UserBlockCubit, UserBlockList, (bool, bool)>(
        selector: (state) => (
          state.ownerUid != null && state.ownerUid != uid && state.status == UserBlockListStatus.ready,
          state.isBlocked(uid),
        ),
        builder: (context, state) => _build(context, uid, canBlock: state.$1, blocked: state.$2),
      );
    }
    return _build(context, uid, canBlock: false, blocked: false);
  }

  Widget _build(BuildContext context, int? uid, {required bool canBlock, required bool blocked}) {
    final tr = context.t.postCard.profileDialog;

    // Label padding halved: at 204 wide the label of a list chip sharing a row gets 72, "TA的主題" needs about 60.
    Widget chip(String key, String label, VoidCallback onPressed) => ActionChip(
      key: ValueKey('brief-profile-action-$key'),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );

    Widget iconChip(String key, IconData icon, String tooltip, VoidCallback onPressed) => ActionChip(
      key: ValueKey('brief-profile-action-$key'),
      label: Icon(icon, size: 18),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );

    void openMemberThreads(String? tab) => unawaited(
      context.pushNamed(
        ScreenPaths.memberThread,
        queryParameters: {
          if (uid != null) 'uid': '$uid' else if (username.isNotEmpty) 'username': username,
          'tab': ?tab,
        },
      ),
    );

    final lists = <Widget>[
      if (uid != null || username.isNotEmpty) ...[
        chip('threads', isSelf ? tr.myThreads : tr.memberThreads, () => openMemberThreads(null)),
        chip('replies', isSelf ? tr.myReplies : tr.memberReplies, () => openMemberThreads('reply')),
      ],
    ];
    final actions = <Widget>[
      if (uid != null && hasAccount && !isSelf)
        iconChip(
          'friend',
          Icons.person_add_alt_1_outlined,
          context.t.friendPage.addFriend.tooltip,
          () => unawaited(showAddFriendDialog(context, uid: '$uid', username: username)),
        ),
      if (canBlock)
        iconChip(
          'block',
          blocked ? Icons.remove_moderator_outlined : Icons.block_outlined,
          blocked ? context.t.userBlock.unblock : context.t.userBlock.block,
          () => unawaited(toggleUserBlock(context, uid: uid!, username: username, blocked: blocked)),
        ),
    ];

    if (width >= _wrapWidth) {
      return Wrap(spacing: 8, runSpacing: 8, children: [...lists, ...actions]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        if (lists.isNotEmpty) Row(spacing: 8, children: lists.map((e) => Expanded(child: e)).toList()),
        if (actions.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    );
  }
}

class _UserProfilePair extends StatelessWidget {
  const _UserProfilePair(this.iconData, this.name, this.value, this.valueColor);

  final IconData iconData;
  final String name;
  final String? value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // Name in a muted label, value in its own color; long values wrap under themselves.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(iconData, size: 16, color: colorScheme.outline),
        sizedBoxW8H8,
        Text(name, style: textTheme.bodySmall?.copyWith(color: colorScheme.outline)),
        sizedBoxW12H12,
        Expanded(
          child: Text(value ?? '', style: textTheme.bodyMedium?.copyWith(color: valueColor)),
        ),
      ],
    );
  }
}
