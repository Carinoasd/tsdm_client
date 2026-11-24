import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/checkin/widgets/checkin_button.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/utils/online_summary.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/widgets/daily_red_packet_button.dart';
import 'package:tsdm_client/features/settings/widgets/support_development_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/hour_ticker.dart';

/// Corner radius of the homepage cards, the app wide [appSurfaceRadius].
const double homeCardRadius = appSurfaceRadius;

/// Shape shared by the homepage cards, the app wide [appSurfaceShape].
ShapeBorder homeCardShape(BuildContext context) => appSurfaceShape(context);

/// Least width left to the greeting beside the title badge; below it the badge goes to its own line.
const _minGreetingWidth = 168.0;

/// Gap between the greeting and the title badge.
const _greetingBadgeGap = 12.0;

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

/// A tab of a homepage section with tabs (the forum guide, the pinned thread groups): bold when [selected], with a
/// bar in the primary color under it as wide as its label.
class HomeCardTab extends StatelessWidget {
  /// Constructor.
  const HomeCardTab({required this.label, required this.selected, required this.onTap, super.key});

  /// Tab label, never cut: the tab row scrolls instead.
  final String label;

  /// Whether this tab is the one shown.
  final bool selected;

  /// Select this tab.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: IntrinsicWidth(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: selected ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: selected ? colorScheme.primary : Colors.transparent,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                  ),
                  child: const SizedBox(height: 3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Room between two tabs of a homepage section ([HomeCardTab]).
const homeTabGap = 24.0;

/// Title of a homepage section on the page itself (the forum guide, the tools): 18, bold.
TextStyle? homeSectionTitleStyle(BuildContext context) =>
    Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 18, height: 1.3, fontWeight: FontWeight.w700);

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
    final hasStatus = forumStatus != const ForumStatus.empty();
    const tabular = [FontFeature.tabularFigures()];

    // The date and the greeting follow the clock: an app left open overnight showed yesterday's date (and "good
    // night" in the morning) until the page was built again.
    final greeting = HourTicker(
      builder: (context, now) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The kicker: the forum in the primary color, the date quieter after it.
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: context.t.appName,
                  style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.w700),
                ),
                TextSpan(text: ' · ${MaterialLocalizations.of(context).formatMediumDate(now)}'),
              ],
            ),
            // Phones keep the greeting narrower beside the title badge: the date wraps instead of being cut.
            maxLines: compact ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(
              fontSize: 12.5,
              height: 1.4,
              color: colorScheme.onSurfaceVariant,
              fontFeatures: tabular,
            ),
          ),
          sizedBoxW4H4,
          Text(
            homeGreeting(context, now.hour, username),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: textTheme.headlineMedium?.copyWith(
              fontSize: compact ? 28 : 30,
              height: 1.25,
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurface,
            ),
          ),
          if (hasStatus) ...[
            sizedBoxW4H4,
            _TodayCount(forumStatus.todayCount),
          ],
        ],
      ),
    );

    Widget actions(AppDayActionLook look) {
      // Always visible next to the check-in, with the state the homepage can tell (claimable, claimed in this run,
      // none to claim now, needs a login).
      final redPacket = DailyRedPacketEntry(
        uid: uid,
        config: dailyRedPacket,
        formHash: formHash,
        onCheck: onCheckDailyRedPacket,
        checking: checkingDailyRedPacket,
        claim: claimDailyRedPacket,
        look: look,
      );
      final activities = _QuickAction(
        icon: Icons.event_outlined,
        label: context.t.activitiesPage.title,
        look: look,
        onPressed: () async => context.pushNamed(ScreenPaths.activities),
      );
      final medals = _QuickAction(
        icon: Icons.workspace_premium_outlined,
        label: context.t.medalTitleHub.title,
        look: look,
        onPressed: () async => context.pushNamed(ScreenPaths.medalTitleHub),
      );
      final checkin = CheckinButton(enableSnackBar: true, label: context.t.homepage.welcome.checkin, look: look);
      return switch (look) {
        // Desktop: four pills after the today count, beside the title badge.
        AppDayActionLook.button => Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [checkin, redPacket, activities, medals],
        ),
        // Phones: the four actions on one row of tiles.
        AppDayActionLook.tile => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: checkin),
            sizedBoxW8H8,
            Expanded(child: redPacket),
            sizedBoxW8H8,
            Expanded(child: activities),
            sizedBoxW8H8,
            Expanded(child: medals),
          ],
        ),
        // Too narrow for four (large text, long labels): two columns, the icons before the labels.
        AppDayActionLook.row => Column(
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
        ),
      };
    }

    // The masthead of the page, not a panel: on the page itself, the check-in the one filled action.
    if (!compact) {
      return Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: HomeGreetingHeader(
          greeting: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [greeting, sizedBoxW16H16, actions(AppDayActionLook.button)],
          ),
          uid: uid,
          compact: compact,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeGreetingHeader(greeting: greeting, uid: uid, compact: compact),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) => actions(
              homeDayActionsFitOneRow(context, constraints.maxWidth) ? AppDayActionLook.tile : AppDayActionLook.row,
            ),
          ),
        ],
      ),
    );
  }
}

/// Room between the four action tiles of the phone greeting.
const _dayActionGap = 8.0;

/// Horizontal padding inside an action tile around its label.
const _dayActionTilePadding = 4.0;

/// Whether the four action tiles of the phone greeting fit on one row [width] wide: the widest label any of them may
/// show (every state of the check-in and the red packet, so claiming one does not change the layout), in the label
/// style of the tiles at the text scale in effect, fits in a quarter of the row.
bool homeDayActionsFitOneRow(BuildContext context, double width) {
  final tr = context.t;
  final labels = [
    tr.homepage.welcome.checkin,
    tr.homepage.welcome.checkedIn,
    tr.redPacket.daily.tooltip,
    tr.redPacket.daily.claimedToday,
    tr.redPacket.daily.unavailable,
    tr.redPacket.daily.needLogin,
    tr.activitiesPage.title,
    tr.medalTitleHub.title,
  ];
  final style = appDayActionLabelStyle(context);
  final scaler = MediaQuery.textScalerOf(context);
  final direction = Directionality.of(context);
  var widest = 0.0;
  for (final label in labels) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    widest = math.max(widest, painter.width);
    painter.dispose();
  }
  final tile = (width - _dayActionGap * 3) / 4;
  return widest + _dayActionTilePadding * 2 <= tile;
}

/// "N new posts today", the number bold in the primary color.
class _TodayCount extends StatelessWidget {
  const _TodayCount(this.count);

  final String count;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // The words around the number, as the translation puts them.
    const mark = '\u0000';
    final parts = context.t.homepage.todayPosts(count: mark).split(mark);
    final style = Theme.of(context).textTheme.bodyLarge?.copyWith(
      fontSize: 15,
      height: 1.4,
      color: colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Text.rich(
      TextSpan(
        children: [
          for (final (i, part) in parts.indexed) ...[
            if (i > 0)
              TextSpan(
                text: count,
                style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.w700),
              ),
            TextSpan(text: part),
          ],
        ],
      ),
      style: style,
    );
  }
}

/// Top of the greeting: the [greeting] and the title badge of the account [uid], beside the greeting and centered on
/// it when both fit, below it otherwise ([homeGreetingBadgeLayout]).
class HomeGreetingHeader extends StatelessWidget {
  /// Constructor.
  const HomeGreetingHeader({required this.greeting, required this.uid, required this.compact, super.key});

  /// Date line, greeting and today count (and, on desktop, the actions under them).
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
  const _QuickAction({required this.icon, required this.label, required this.look, required this.onPressed});

  final IconData icon;
  final String label;
  final AppDayActionLook look;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => look == AppDayActionLook.button
      ? FilledButton.icon(
          style: appHeroActionStyle(context, height: 44),
          icon: Icon(icon),
          // One line: the label shrinks a little instead of wrapping.
          label: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1)),
          onPressed: onPressed,
        )
      : appDayAction(context, look: look, icon: Icon(icon), label: label, onPressed: onPressed);
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

/// The members online now: the "在线会员" line of the forum's homepage when the page carried it ([summary], the parts
/// the forum prints between its dashes; or its numbers [online], which the forum's app API gives, in the app's words),
/// and the list of them a tap away.
class HomeOnlineCard extends StatelessWidget {
  /// Constructor.
  const HomeOnlineCard({required this.summary, this.online, super.key});

  /// The parts of the "在线会员" line, empty when the page carried none.
  final List<String> summary;

  /// The numbers of the line, null when the page gave none.
  final HomeOnline? online;

  /// The lines under the title: the page's own, else the numbers.
  List<String> _lines(BuildContext context) {
    if (summary.isNotEmpty) {
      return summary.map(context.displayText).toList();
    }
    final online = this.online;
    if (online == null) {
      return const [];
    }
    final tr = context.t.homepage.online;
    return [
      tr.total(count: online.total),
      tr.members(members: online.members, invisible: online.invisible, guests: online.guests),
      if (online.record > 0)
        online.recordDate.isEmpty
            ? tr.record(count: online.record)
            : tr.recordAt(count: online.record, date: online.recordDate),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      key: const ValueKey('home-online'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: homeCardShape(context),
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: () async => context.pushNamed(ScreenPaths.friend, queryParameters: const {'view': 'online'}),
          child: Padding(
            padding: edgeInsetsL16T12R16B12,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.t.friendPage.online.title,
                        style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      for (final part in _lines(context)) ...[
                        sizedBoxW2H2,
                        Text(part, style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
              ],
            ),
          ),
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(appTileRadius))),
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: () async => showDialog<void>(context: context, builder: (_) => const SupportDevelopmentDialog()),
          child: Padding(
            padding: edgeInsetsL16T12R16B12,
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(color: colorScheme.tertiaryContainer, shape: BoxShape.circle),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(Icons.favorite, size: 20, color: colorScheme.onTertiaryContainer),
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
                          style: textTheme.titleSmall?.copyWith(fontSize: 14.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                      sizedBoxW2H2,
                      Text(
                        context.t.aboutPage.supportDevelopmentSubtitle,
                        style: textTheme.bodySmall?.copyWith(fontSize: 12.5, color: colorScheme.onSurfaceVariant),
                      ),
                      Text(
                        context.t.homepage.supportNote,
                        style: textTheme.bodySmall?.copyWith(fontSize: 12.5, color: AppSurfaces.of(context).muted),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
              ],
            ),
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
    final entries = <(IconData, String, String)>[
      (Icons.workspace_premium_outlined, context.t.medalTitleHub.title, ScreenPaths.medalTitleHub),
      (Icons.article_outlined, tr.welcome.myThread, ScreenPaths.myThread),
      (Icons.star_outline, tr.welcome.favorite, ScreenPaths.favorite),
      (Icons.history_outlined, tr.welcome.history, ScreenPaths.threadVisitHistory),
      (Icons.account_balance_outlined, context.t.bank.title, ScreenPaths.bank),
      (Icons.catching_pokemon, context.t.pokemon.title, ScreenPaths.pokemon),
    ];
    // A titled group on the page, each entry a panel of its own.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 12),
          child: Text(tr.tools, style: homeSectionTitleStyle(context)),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 8.0;
            // A hair narrower: the rounding of the division must not push the last tile of a row to the next one.
            final width = (constraints.maxWidth - spacing * (columns - 1)) / columns - 0.01;
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
      color: AppSurfaces.of(context).card,
      borderRadius: BorderRadius.circular(appTileRadius),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: colorScheme.primary),
                  sizedBoxW4H4,
                  Text(
                    label,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: appDayActionLabelStyle(context)?.copyWith(fontWeight: FontWeight.w400),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
