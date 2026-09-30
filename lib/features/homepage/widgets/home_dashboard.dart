import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/checkin/widgets/checkin_button.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/widgets/daily_red_packet_button.dart';
import 'package:tsdm_client/features/settings/widgets/support_development_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Corner radius of the homepage cards, the app wide [appSurfaceRadius].
const double homeCardRadius = appSurfaceRadius;

/// Shape shared by the homepage cards, the app wide [appSurfaceShape].
ShapeBorder homeCardShape(BuildContext context) => appSurfaceShape(context);

/// Least width left to the greeting beside the title badge; below it the badge goes to its own line.
const _minGreetingWidth = 168.0;

/// Gap between the greeting and the title badge.
const _greetingBadgeGap = 12.0;

/// Least width (at text scale 1) of the phone greeting card content showing check-in and red packet on one row.
const _dailyActionsRowWidth = 300.0;

/// Least width (at text scale 1) of the phone greeting card content showing all four actions of the day on one row
/// (check-in, red packet, activities, medals and titles): a phone in landscape (feedback 113).
const _allActionsRowWidth = 560.0;

/// Width of the title badge in the greeting card on wide layouts: the natural 184px of the image.
///
/// It was 240px for a day (user request of 2026-09-27): the forum only serves the 184x100 original, so the enlarged
/// image was blurry on desktop (user report of 2026-09-29).
const homeGreetingBadgeWideWidth = 184.0;

/// Least width of the title badge in the greeting card on phones, unless the card is narrower.
const homeGreetingBadgeCompactMinWidth = 160.0;

/// Largest width of the title badge in the greeting card on phones.
const homeGreetingBadgeCompactMaxWidth = 184.0;

/// Width of the title badge in the greeting card whose content is [available] wide.
///
/// Wide layouts show the image at its natural 184px; phones give it 160 to 184px depending on the room. The image
/// is never enlarged past its natural width (the forum serves 184x100 only, larger looked blurry); it stays contained
/// in its 184:100 box, never cropped nor stretched, and never wider than the card. When the
/// greeting would be left too little room beside it, the badge goes below the greeting ([homeGreetingBadgeBeside]).
double homeGreetingBadgeWidth(double available, {required bool compact}) {
  final preferred = compact
      ? (available * 0.45).clamp(homeGreetingBadgeCompactMinWidth, homeGreetingBadgeCompactMaxWidth)
      : homeGreetingBadgeWideWidth;
  return math.max<double>(0, math.min(available, preferred));
}

/// Whether the greeting leaves enough room beside a badge of [badgeWidth] in [available] width.
bool homeGreetingBadgeBeside(double available, double badgeWidth) =>
    available - badgeWidth - _greetingBadgeGap >= _minGreetingWidth;

/// Least width of the title badge beside the greeting on phones; with less room it goes below the greeting instead of
/// shrinking further.
const homeGreetingBadgeCompactBesideMinWidth = 144.0;

/// Least width (at text scale 1) the phone greeting keeps beside the title badge; its date line may wrap there.
const _minCompactGreetingWidth = 148.0;

/// Width of the title badge in the greeting header whose content is [available] wide, and whether it sits beside the
/// greeting.
///
/// Wide layouts: [homeGreetingBadgeWidth] and [homeGreetingBadgeBeside], unchanged. Phones: the greeting keeps
/// [_minCompactGreetingWidth] scaled by [textScale]; the badge takes its preferred 160–184px beside it, or the room
/// left when that is still at least [homeGreetingBadgeCompactBesideMinWidth] (a 384px phone used to put it below the
/// greeting, leaving the right half of the card empty, feedback 110). Only a narrower room or large text moves it
/// below, at its preferred width.
({double width, bool beside}) homeGreetingBadgeLayout(
  double available, {
  required bool compact,
  double textScale = 1,
}) {
  final preferred = homeGreetingBadgeWidth(available, compact: compact);
  if (!compact) {
    return (width: preferred, beside: homeGreetingBadgeBeside(available, preferred));
  }
  final room = available - _greetingBadgeGap - _minCompactGreetingWidth * textScale;
  if (room >= preferred) {
    return (width: preferred, beside: true);
  }
  if (room >= homeGreetingBadgeCompactBesideMinWidth) {
    return (width: room, beside: true);
  }
  return (width: preferred, beside: false);
}

/// Greeting text for the local [hour].
String homeGreeting(BuildContext context, int hour, String name) {
  final tr = context.t.homepage.greeting;
  return switch (hour) {
    >= 5 && < 11 => tr.morning(name: name),
    >= 11 && < 18 => tr.afternoon(name: name),
    >= 18 && < 23 => tr.evening(name: name),
    _ => tr.night(name: name),
  };
}

/// First card of the homepage: greeting, the current account's secondary title and today's things to do.
///
/// Check-in, the daily red packet and activities used to crowd the app bar; they are the actions of the day here.
/// Only data the forum provides is shown: the today count of the forum status bar, no streaks or invented numbers.
class HomeGreetingCard extends StatelessWidget {
  /// Constructor.
  const HomeGreetingCard({
    required this.username,
    required this.uid,
    required this.forumStatus,
    required this.dailyRedPacket,
    required this.formHash,
    required this.compact,
    this.onCheckDailyRedPacket,
    this.checkingDailyRedPacket = false,
    this.claimDailyRedPacket,
    super.key,
  });

  /// Name of the logged in account.
  final String username;

  /// Uid of the logged in account, for its title badge.
  final int? uid;

  /// Forum statistics from the homepage, [ForumStatus.empty] when the page had none.
  final ForumStatus forumStatus;

  /// Today's red packet, null when there is none or it was claimed.
  final DailyRedPacketConfig? dailyRedPacket;

  /// Form hash required to claim [dailyRedPacket].
  final String? formHash;

  /// Narrow layout: actions stacked under the greeting.
  final bool compact;

  /// Check the daily red packet again, offered by its entry when the page had no packet; only the packet is updated.
  final VoidCallback? onCheckDailyRedPacket;

  /// The check of [onCheckDailyRedPacket] is running.
  final bool checkingDailyRedPacket;

  /// Claim request of the daily red packet, the plugin's endpoint when null (tests pass a fake).
  final DailyRedPacketClaim? claimDailyRedPacket;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final now = DateTime.now();
    final hasStatus = forumStatus != const ForumStatus.empty();

    final greeting = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${context.t.appName} · ${MaterialLocalizations.of(context).formatMediumDate(now)}',
          // Phones keep the greeting narrower beside the title badge: the date wraps instead of being cut.
          maxLines: compact ? 2 : 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.labelMedium?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.w600),
        ),
        sizedBoxW4H4,
        Text(
          homeGreeting(context, now.hour, username),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: (compact ? textTheme.titleLarge : textTheme.headlineSmall)?.copyWith(fontWeight: FontWeight.bold),
        ),
        if (hasStatus) ...[
          sizedBoxW4H4,
          Text(
            context.t.homepage.todayPosts(count: forumStatus.todayCount),
            style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );

    // Always visible next to the check-in, with the state the homepage can tell (claimable, claimed in this run, none
    // to claim now, needs a login).
    final redPacket = DailyRedPacketEntry(
      uid: uid,
      config: dailyRedPacket,
      formHash: formHash,
      onCheck: onCheckDailyRedPacket,
      checking: checkingDailyRedPacket,
      claim: claimDailyRedPacket,
    );
    final activities = _QuickAction(
      icon: Icons.event_outlined,
      label: context.t.activitiesPage.title,
      onPressed: () async => context.pushNamed(ScreenPaths.activities),
    );
    final medals = _QuickAction(
      icon: Icons.workspace_premium_outlined,
      label: context.t.medalTitleHub.title,
      onPressed: () async => context.pushNamed(ScreenPaths.medalTitleHub),
    );
    final quickActions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [if (!compact) redPacket, activities, medals],
    );

    final checkin = CheckinButton(enableSnackBar: true, label: context.t.homepage.welcome.checkin);

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: homeCardShape(context),
      color: colorScheme.surfaceContainerLow,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topRight,
            radius: 1.4,
            colors: [colorScheme.primaryContainer.withValues(alpha: 0.55), colorScheme.surfaceContainerLow],
            stops: const [0, 0.6],
          ),
        ),
        child: Padding(
          padding: compact ? edgeInsetsL16T16R16B16 : edgeInsetsL24T24R24B24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HomeGreetingHeader(greeting: greeting, uid: uid, compact: compact),
              SizedBox(height: compact ? 14 : 20),
              if (compact)
                // All four actions on one row when they fit (a phone in landscape); check-in and red packet side by
                // side with the two entries below them on a portrait phone; everything stacked when even those two do
                // not fit (narrow window, large text).
                LayoutBuilder(
                  builder: (context, constraints) {
                    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
                    if (constraints.maxWidth >= _allActionsRowWidth * textScale) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: checkin),
                          sizedBoxW8H8,
                          Expanded(child: redPacket),
                          sizedBoxW8H8,
                          activities,
                          sizedBoxW8H8,
                          medals,
                        ],
                      );
                    }
                    if (constraints.maxWidth >= _dailyActionsRowWidth * textScale) {
                      // The two entries share the second row half and half: as a wrap they went below each other on
                      // a 360dp phone (feedback on 1.29.1).
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: checkin),
                              sizedBoxW8H8,
                              Expanded(child: redPacket),
                            ],
                          ),
                          sizedBoxW8H8,
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: activities),
                              sizedBoxW8H8,
                              Expanded(child: medals),
                            ],
                          ),
                        ],
                      );
                    }
                    // The two entries stay side by side here too, their labels shrink a little when needed: the
                    // phone of the report (360dp, larger system font) lands in this layout.
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        checkin,
                        sizedBoxW8H8,
                        redPacket,
                        sizedBoxW8H8,
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: activities),
                            sizedBoxW8H8,
                            Expanded(child: medals),
                          ],
                        ),
                      ],
                    );
                  },
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ConstrainedBox(constraints: const BoxConstraints(minWidth: 180), child: checkin),
                    sizedBoxW12H12,
                    Expanded(child: quickActions),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Top of the greeting card: the [greeting] and the title badge of the account [uid], beside the greeting when both
/// fit and below it otherwise ([homeGreetingBadgeLayout]).
class HomeGreetingHeader extends StatelessWidget {
  /// Constructor.
  const HomeGreetingHeader({required this.greeting, required this.uid, required this.compact, super.key});

  /// Date line, greeting and today count.
  final Widget greeting;

  /// Logged in account, for its title badge.
  final int? uid;

  /// Phone layout.
  final bool compact;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final (width: badgeWidth, :beside) = homeGreetingBadgeLayout(
        constraints.maxWidth,
        compact: compact,
        textScale: MediaQuery.textScalerOf(context).scale(14) / 14,
      );
      if (beside) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: greeting),
            CurrentAccountTitleBadge(
              uid: uid,
              width: badgeWidth,
              padding: const EdgeInsetsDirectional.only(start: _greetingBadgeGap),
            ),
          ],
        );
      }
      // Too narrow for both side by side: the badge wraps below the greeting, the text keeps its width.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          greeting,
          CurrentAccountTitleBadge(
            uid: uid,
            width: badgeWidth,
            padding: const EdgeInsets.only(top: _greetingBadgeGap),
          ),
        ],
      );
    },
  );
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
    icon: Icon(icon),
    // One line: in a half width button the label shrinks a little instead of wrapping.
    label: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1)),
    onPressed: onPressed,
  );
}

/// The three counters of the forum status bar: today, yesterday and all posts.
class HomeForumStatsCard extends StatelessWidget {
  /// Constructor.
  const HomeForumStatsCard(this.forumStatus, {super.key});

  /// Forum statistics.
  final ForumStatus forumStatus;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.homepage.forumStatus;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    Widget cell(String label, String value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
    final divider = SizedBox(height: 40, child: VerticalDivider(width: 20, color: colorScheme.outlineVariant));

    return Card(
      margin: EdgeInsets.zero,
      shape: homeCardShape(context),
      child: Padding(
        padding: edgeInsetsL16T12R16B12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.t.homepage.forumActivity, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            sizedBoxW8H8,
            Row(
              children: [
                cell(tr.today, forumStatus.todayCount),
                divider,
                cell(tr.yesterday, forumStatus.yesterdayCount),
                divider,
                cell(tr.threads, forumStatus.threadCount),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Entry of the voluntary support dialog: visible, but not in the way of the threads.
class HomeSupportCard extends StatelessWidget {
  /// Constructor.
  const HomeSupportCard({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: homeCardShape(context),
      child: InkWell(
        onTap: () async => showDialog<void>(context: context, builder: (_) => const SupportDevelopmentDialog()),
        child: Padding(
          padding: edgeInsetsL16T12R16B12,
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: Icon(Icons.favorite_border, color: colorScheme.onTertiaryContainer),
                ),
              ),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        context.t.aboutPage.supportDevelopment,
                        maxLines: 1,
                        style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    sizedBoxW2H2,
                    Text(
                      context.t.aboutPage.supportDevelopmentSubtitle,
                      style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                    sizedBoxW2H2,
                    Text(
                      context.t.homepage.supportNote,
                      style: textTheme.labelSmall?.copyWith(color: colorScheme.tertiary),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fixed entries of pages that are not top level destinations, the medal & title hub first.
class HomeToolsCard extends StatelessWidget {
  /// Constructor.
  const HomeToolsCard({required this.columns, super.key});

  /// Number of entries per row.
  final int columns;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.homepage;
    final textTheme = Theme.of(context).textTheme;
    final entries = <(IconData, String, String)>[
      (Icons.workspace_premium_outlined, context.t.medalTitleHub.title, ScreenPaths.medalTitleHub),
      (Icons.article_outlined, tr.welcome.myThread, ScreenPaths.myThread),
      (Icons.star_outline, tr.welcome.favorite, ScreenPaths.favorite),
      (Icons.history_outlined, tr.welcome.history, ScreenPaths.threadVisitHistory),
      (Icons.account_balance_outlined, context.t.bank.title, ScreenPaths.bank),
      (Icons.catching_pokemon, context.t.pokemon.title, ScreenPaths.pokemon),
    ];
    return Card(
      margin: EdgeInsets.zero,
      shape: homeCardShape(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr.tools, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            sizedBoxW12H12,
            LayoutBuilder(
              builder: (context, constraints) {
                const spacing = 8.0;
                final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final (icon, label, path) in entries)
                      SizedBox(
                        width: width,
                        child: _ToolButton(icon: icon, label: label, onTap: () async => context.pushNamed(path)),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 20, color: colorScheme.primary),
                sizedBoxW8H8,
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
