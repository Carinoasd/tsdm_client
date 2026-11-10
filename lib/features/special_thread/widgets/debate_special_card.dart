part of 'special_thread_card.dart';

/// The debate: the verdict when the umpire gave one, both sides with their point, votes, debaters and the side the
/// account voted for, the share of the votes, voting (a GET, as the page's ajaxmenu), joining a side (the reply bar
/// with the side, [onJoin]: only the side the account took once it replied on one), the end time and the umpire; the
/// umpire's tools open the web page.
class _DebateCard extends StatefulWidget {
  const _DebateCard(this.debate, {required this.onReload, required this.onJoin});

  final DebateSpecial debate;
  final VoidCallback? onReload;
  final void Function(int stand)? onJoin;

  @override
  State<_DebateCard> createState() => _DebateCardState();
}

class _DebateCardState extends State<_DebateCard> with _SpecialActions {
  @override
  VoidCallback? get _reload => widget.onReload;

  Future<void> _vote(int stand) async {
    final tr = context.t.specialThread.debate;
    final request = widget.debate.voteRequest(stand);
    if (request == null) {
      return;
    }
    final confirmed = await showQuestionDialog(
      context: context,
      title: tr.voteConfirmTitle,
      message: tr.voteConfirm(side: stand == 1 ? tr.affirm : tr.nega),
    );
    if (!mounted || !(confirmed ?? false)) {
      return;
    }
    await _run(request);
  }

  /// A point of the debate: its [html] with the app's html renderer ([MunchedHtml]), else its plain [text].
  Widget _point(String html, String text) => html.trim().isNotEmpty
      ? MunchedHtml(html)
      : Text(context.displayText(text), style: Theme.of(context).textTheme.bodyMedium);

  Widget _side(int stand) {
    final tr = context.t.specialThread.debate;
    final d = widget.debate;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final affirm = stand == 1;
    final color = affirm ? colorScheme.primary : colorScheme.error;
    final avatars = affirm ? d.affirmAvatars : d.negaAvatars;
    final canVote = widget.onReload != null && d.voteRequest(stand) != null;
    // The page's "加入": a reply on this side, while the debate runs; the forum keeps the side of a first reply.
    final canJoin = widget.onJoin != null && d.viewerUid != null && !d.ended && d.replySides.contains(stand);
    return AppInsetBlock(
      color: colorScheme.surfaceContainerHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(affirm ? Icons.thumb_up_alt_outlined : Icons.thumb_down_alt_outlined, size: 18, color: color),
              sizedBoxW8H8,
              Expanded(
                child: Text(
                  affirm ? tr.affirm : tr.nega,
                  style: textTheme.titleSmall?.copyWith(color: color, fontWeight: FontWeight.bold),
                ),
              ),
              if (d.voted == stand)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.how_to_vote, size: 18, color: color, semanticLabel: tr.voted),
                ),
              Text(tr.votes(count: affirm ? d.affirmVotes : d.negaVotes), style: textTheme.labelLarge),
            ],
          ),
          sizedBoxW4H4,
          // The point as the forum renders it (links, line breaks, formatting), as the content of a floor is shown;
          // its plain text when the answer gives no html.
          _point(affirm ? d.affirmPointHtml : d.negaPointHtml, affirm ? d.affirmPoint : d.negaPoint),
          sizedBoxW8H8,
          if (affirm ? d.affirmDebaters : d.negaDebaters case final debaters?)
            Text(
              tr.debaters(count: debaters),
              style: textTheme.labelMedium?.copyWith(color: colorScheme.outline),
            ),
          if (avatars.isNotEmpty) ...[
            sizedBoxW4H4,
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final u in avatars)
                  Tooltip(
                    message: u.username,
                    child: GestureDetector(
                      onTap: u.uid > 0
                          ? () async => context.dispatchAsUrl('$baseUrl/home.php?mod=space&uid=${u.uid}')
                          : null,
                      child: _Avatar(u.avatar, u.username),
                    ),
                  ),
              ],
            ),
          ],
          if (canVote || canJoin) ...[
            sizedBoxW8H8,
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (canVote)
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : () async => _vote(stand),
                    icon: const Icon(Icons.how_to_vote_outlined),
                    label: Text(tr.voteFor(side: affirm ? tr.affirm : tr.nega)),
                  ),
                if (canJoin)
                  OutlinedButton.icon(
                    onPressed: () => widget.onJoin!(stand),
                    icon: const Icon(Icons.add_comment_outlined),
                    label: Text(tr.join(side: affirm ? tr.affirm : tr.nega)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.specialThread.debate;
    final d = widget.debate;
    final colorScheme = Theme.of(context).colorScheme;
    final result = d.result;
    final total = d.affirmVotes + d.negaVotes;
    final subtitle = [
      if (d.ended) tr.ended else if (d.endTime case final end?) tr.endTime(time: end.yyyyMMDDHHMM()),
      if (d.umpire.isNotEmpty) tr.umpire(name: d.umpire),
    ].join(' · ');
    return AppEmbedCard(
      icon: Icons.forum_outlined,
      title: tr.title,
      subtitle: subtitle.isEmpty ? null : subtitle,
      trailing: _busy ? const SizedBox(width: 20, height: 20, child: CircularIndicator()) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (result != null) ...[
            AppNoticeBanner(
              icon: Icons.gavel_outlined,
              title: switch (result.winner) {
                1 => tr.winnerAffirm,
                2 => tr.winnerNega,
                0 => null,
                _ => tr.winnerDraw,
              },
              // The umpire's point as the forum renders it goes under its label, rendered as the sides' points are;
              // its plain text in the message when the answer gives no html.
              message: [
                if (result.umpirePointHtml.trim().isNotEmpty)
                  '${tr.umpirePoint}:'
                else if (result.umpirePoint.isNotEmpty)
                  '${tr.umpirePoint}: ${result.umpirePoint}',
                if (result.umpirePointHtml.trim().isEmpty && result.bestDebater.isNotEmpty)
                  tr.bestDebater(name: result.bestDebater),
              ].join('\n'),
              child: result.umpirePointHtml.trim().isEmpty
                  ? null
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        MunchedHtml(result.umpirePointHtml),
                        if (result.bestDebater.isNotEmpty) ...[
                          sizedBoxW4H4,
                          Text(
                            tr.bestDebater(name: result.bestDebater),
                            style: Theme.of(
                              context,
                            ).textTheme.bodyMedium?.copyWith(color: colorScheme.onSecondaryContainer),
                          ),
                        ],
                      ],
                    ),
            ),
            sizedBoxW8H8,
          ],
          if (total > 0) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(appInnerRadius),
              child: SizedBox(
                height: 8,
                child: Row(
                  children: [
                    if (d.affirmVotes > 0)
                      Expanded(
                        flex: d.affirmVotes,
                        child: ColoredBox(color: colorScheme.primary),
                      ),
                    if (d.negaVotes > 0)
                      Expanded(
                        flex: d.negaVotes,
                        child: ColoredBox(color: colorScheme.error),
                      ),
                  ],
                ),
              ),
            ),
            sizedBoxW8H8,
          ],
          LayoutBuilder(
            builder: (context, constraints) {
              final sides = [_side(1), _side(2)];
              if (constraints.maxWidth < 480) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [sides[0], sizedBoxW8H8, sides[1]],
                );
              }
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: sides[0]),
                    sizedBoxW8H8,
                    Expanded(child: sides[1]),
                  ],
                ),
              );
            },
          ),
          ?_refusalBanner(),
          if (widget.onReload != null && d.canUmpire && d.umpireUrl != null) ...[
            sizedBoxW8H8,
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () async => _openInBrowser(context, d.umpireUrl!),
                icon: const Icon(Icons.open_in_browser_outlined),
                label: Text(tr.umpireAction),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
