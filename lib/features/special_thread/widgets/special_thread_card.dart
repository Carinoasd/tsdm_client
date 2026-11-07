import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/special_thread/repository/special_thread_repository.dart';
import 'package:tsdm_client/features/special_thread/widgets/special_form_dialog.dart';
import 'package:tsdm_client/features/thread/v1/utils/offline_floor.dart';
import 'package:tsdm_client/features/trade/models/trade_models.dart';
import 'package:tsdm_client/features/trade/view/trade_goods_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/card/poll_card.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

part 'activity_special_card.dart';
part 'debate_special_card.dart';
part 'reward_special_card.dart';
part 'trade_special_card.dart';

/// The special block of a thread (plugin 2.8.0, [ThreadSpecial]) as the app's own card in the first floor [pid],
/// instead of the forum's html of it (cut out of the floor, see `bodyHtmlWithoutSpecialBlock`).
///
/// * poll: the poll card ([PollCard]) fed with the fields;
/// * goods: the list, each goods opening its page in the app, where a goods sold for credit is bought;
/// * bounty: the bounty, its state, the accepted answer (accepting one is on the floors, [SpecialBestAnswerButton]);
/// * activity: the details, the account's application, applying (the forum's form, [showSpecialFormDialog]),
///   cancelling, the applicants; managing opens the web page;
/// * debate: both sides with their points, votes and debaters, the verdict, voting; the umpire's tools open the web
///   page.
///
/// The actions send the forum's own forms ([SpecialThreadRepository]) for the account the page was served to only;
/// the forum's verdict is shown with its message, and a done action reloads the thread page through [onReload]. Null
/// [onReload] (no thread page above: the post of a notice) shows no action but the poll's, which reads the poll again
/// itself as before.
class SpecialThreadCard extends StatelessWidget {
  /// Constructor.
  const SpecialThreadCard(
    this.special, {
    required this.pid,
    this.onReload,
    this.onJoinDebate,
    this.webUrl,
    super.key,
  });

  /// The block.
  final ThreadSpecial special;

  /// The first floor.
  final String pid;

  /// Reload the thread page after an action the forum did (or may have done).
  final VoidCallback? onReload;

  /// Reply on side `stand` of the debate (the reply bar with the side chosen); null where the account cannot reply.
  final void Function(int stand)? onJoinDebate;

  /// The thread on the web page (the first floor's share link), for what the app cannot do itself.
  final String? webUrl;

  /// Whether the card goes above the floor's content: the web page prints the bounty and the activity details before
  /// the content, the poll, the goods and the debate's sides after it.
  static bool aboveContent(ThreadSpecial special) => special is RewardSpecial || special is ActivitySpecial;

  @override
  Widget build(BuildContext context) {
    // A floor read back from an offline copy of the thread: the block as the page showed it, read only.
    final offline = isOfflineFloor(context);
    final reload = offline ? null : onReload;
    return switch (special) {
      final PollSpecial poll => PollCard(pid, fromSpecial: poll, onVoted: reload),
      final TradeSpecial trade => _TradeCard(trade, onReload: reload),
      final RewardSpecial reward => _RewardCard(reward),
      final ActivitySpecial activity => _ActivityCard(activity, onReload: reload, webUrl: webUrl),
      final DebateSpecial debate => _DebateCard(debate, onReload: reload, onJoin: offline ? null : onJoinDebate),
    };
  }
}

/// Send the action [request] of a special block for the account in use, when it is still the account the page was
/// served to; null when it is not (nothing sent).
Future<SpecialActionOutcome?> _sendSpecialAction(BuildContext context, SpecialRequest request) async {
  final auth = context.readOrNull<AuthenticationRepository>();
  if (auth != null && auth.effectiveCurrentUid != request.viewerUid) {
    return null;
  }
  final repository =
      context.readOrNull<SpecialThreadRepository>() ?? SpecialThreadRepository.network(getIt.get<NetClientProvider>());
  return repository.submit(request);
}

/// The busy state and the forum's refusal of the actions of a card, and how an action's outcome is shown.
mixin _SpecialActions<T extends StatefulWidget> on State<T> {
  bool _busy = false;
  String? _refusal;

  /// Reload the thread page.
  VoidCallback? get _reload;

  /// Send [request]: a done action says the forum's message and reloads the thread page, a refused one shows the
  /// forum's message in the card, an action without a verdict reloads the page (only the page tells what happened).
  Future<void> _run(SpecialRequest request) async {
    if (_busy) {
      return;
    }
    final tr = context.t.specialThread;
    setState(() {
      _busy = true;
      _refusal = null;
    });
    final outcome = await _sendSpecialAction(context, request);
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case null:
        setState(() {
          _busy = false;
          _refusal = tr.accountChanged;
        });
      case SpecialActionRefused(:final message):
        setState(() {
          _busy = false;
          _refusal = message;
        });
      case SpecialActionDone(:final message):
        setState(() => _busy = false);
        showSnackBar(context: context, message: message.isEmpty ? tr.done : message);
        _reload?.call();
      case SpecialActionUnknown():
        setState(() => _busy = false);
        showSnackBar(context: context, message: tr.unknown);
        _reload?.call();
    }
  }

  /// The forum's refusal of the latest action, when there is one.
  Widget? _refusalBanner() => switch (_refusal) {
    final String message => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: AppNoticeBanner(tone: AppNoticeTone.error, message: message, selectable: true),
    ),
    null => null,
  };
}

/// "Set as best answer" on a floor of a bounty the account may accept ([Post.bestAnswerRequest]): asks first, sends
/// the forum's form, and reloads the thread page through [onReload] when the forum did it.
class SpecialBestAnswerButton extends StatefulWidget {
  /// Constructor.
  const SpecialBestAnswerButton(this.request, {required this.onReload, super.key});

  /// The forum's form for this floor.
  final SpecialRequest request;

  /// Reload the thread page.
  final VoidCallback onReload;

  @override
  State<SpecialBestAnswerButton> createState() => _SpecialBestAnswerButtonState();
}

class _SpecialBestAnswerButtonState extends State<SpecialBestAnswerButton> with _SpecialActions {
  @override
  VoidCallback? get _reload => widget.onReload;

  Future<void> _accept() async {
    final tr = context.t.specialThread.reward;
    final confirmed = await showQuestionDialog(
      context: context,
      title: tr.setBestConfirmTitle,
      message: tr.setBestConfirm,
    );
    if (!mounted || !(confirmed ?? false)) {
      return;
    }
    await _run(widget.request);
    if (mounted && _refusal != null) {
      showSnackBar(context: context, message: _refusal!);
    }
  }

  @override
  Widget build(BuildContext context) => isOfflineFloor(context)
      ? const SizedBox.shrink()
      : TextButton.icon(
          onPressed: _busy ? null : _accept,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularIndicator())
              : const Icon(Icons.verified_outlined),
          label: Text(context.t.specialThread.reward.setBest),
        );
}

/// What the page prints in a floor's header for a special thread: the accepted answer of a bounty ([Post.best]),
/// the floor's side in a debate ([Post.stand]) with its supporters ([Post.standVotes]), and the page's "支持" of that
/// side ([Post.debateVoteRequest]: asks first, sends the forum's GET, reloads the thread page through [onReload]; none
/// without a thread page above).
class SpecialFloorBadges extends StatefulWidget {
  /// Constructor.
  const SpecialFloorBadges(this.post, {this.onReload, super.key});

  /// The floor.
  final Post post;

  /// Reload the thread page after supporting the floor's side.
  final VoidCallback? onReload;

  /// Whether [post] has any badge.
  static bool any(Post post) => post.best || post.stand != null;

  @override
  State<SpecialFloorBadges> createState() => _SpecialFloorBadgesState();
}

class _SpecialFloorBadgesState extends State<SpecialFloorBadges> with _SpecialActions {
  @override
  VoidCallback? get _reload => widget.onReload;

  Future<void> _support(SpecialRequest request) async {
    final tr = context.t.specialThread.debate;
    final confirmed = await showQuestionDialog(
      context: context,
      title: tr.supportConfirmTitle,
      message: tr.supportConfirm,
    );
    if (!mounted || !(confirmed ?? false)) {
      return;
    }
    await _run(request);
    if (mounted && _refusal != null) {
      showSnackBar(context: context, message: _refusal!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.specialThread;
    final colorScheme = Theme.of(context).colorScheme;
    final post = widget.post;
    final support = widget.onReload == null || isOfflineFloor(context) ? null : post.debateVoteRequest;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (post.best) _Badge(icon: Icons.verified, label: tr.reward.badge, color: colorScheme.tertiary),
        if (post.stand case final stand?)
          _Badge(
            icon: switch (stand) {
              1 => Icons.thumb_up_alt_outlined,
              2 => Icons.thumb_down_alt_outlined,
              _ => Icons.horizontal_rule,
            },
            label: [
              switch (stand) {
                1 => tr.debate.affirm,
                2 => tr.debate.nega,
                _ => tr.debate.neutral,
              },
              if (stand == 1 || stand == 2) tr.debate.standVotes(count: post.standVotes),
            ].join(' · '),
            color: switch (stand) {
              1 => colorScheme.primary,
              2 => colorScheme.error,
              _ => colorScheme.outline,
            },
          ),
        if (support != null)
          SizedBox(
            height: 28,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _busy ? null : () async => _support(support),
              icon: _busy
                  ? const SizedBox(width: 14, height: 14, child: CircularIndicator())
                  : const Icon(Icons.thumb_up_alt_outlined, size: 16),
              label: Text(tr.debate.support),
            ),
          ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: color.withValues(alpha: 0.6)),
      borderRadius: BorderRadius.circular(appInnerRadius),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          sizedBoxW4H4,
          Flexible(
            child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
          ),
        ],
      ),
    ),
  );
}

/// A row "label: value" of the details of a card; the value wraps.
class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 88, maxWidth: 120),
            child: Text(label, style: textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.outline)),
          ),
          sizedBoxW8H8,
          Expanded(child: Text(value, style: textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// A user's avatar, the forum's default when there is none.
class _Avatar extends StatelessWidget {
  const _Avatar(this.url, this.name, {this.radius = 14});

  final String? url;
  final String name;
  final double radius;

  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: radius,
    backgroundImage: CachedImageProvider(
      url ?? noAvatarUrl,
      fallbackImageUrl: noAvatarUrl,
      usage: ImageUsageInfoUserAvatar(name),
    ),
  );
}

/// A user as a small pill: avatar and name; opens the profile when the uid is known.
class _UserPill extends StatelessWidget {
  const _UserPill({required this.uid, required this.name, required this.avatar, this.detail});

  final int uid;
  final String name;
  final String? avatar;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final pill = AppInsetBlock(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Avatar(avatar, name, radius: 12),
          sizedBoxW8H8,
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name, style: textTheme.labelLarge),
                if (detail case final detail? when detail.isNotEmpty)
                  Text(detail, style: textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
              ],
            ),
          ),
        ],
      ),
    );
    if (uid <= 0) {
      return pill;
    }
    return GestureDetector(
      onTap: () async => context.dispatchAsUrl('$baseUrl/home.php?mod=space&uid=$uid'),
      child: pill,
    );
  }
}

/// A forum page opened in the browser (the pages the app has no screen for: goods, managing, the umpire's tools).
Future<void> _openInBrowser(BuildContext context, String url) async => context.dispatchAsUrl(url, external: true);

/// A number as the page prints it: no trailing `.0`.
String _number(num value) => value == value.roundToDouble() ? '${value.toInt()}' : '$value';
