part of 'special_thread_card.dart';

/// The bounty: its price and credit, resolved or not, the accepted answer (its author, the forum's excerpt or a note
/// when the account may not read it, a way to its floor), and for the thread's author how to accept one (on the
/// floors, [SpecialBestAnswerButton]).
class _RewardCard extends StatelessWidget {
  const _RewardCard(this.reward);

  final RewardSpecial reward;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.specialThread.reward;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final credit = reward.credit;
    final best = reward.bestPost;
    return AppEmbedCard(
      icon: Icons.emoji_events_outlined,
      title: tr.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    reward.resolved ? Icons.done : Icons.pending_outlined,
                    color: reward.resolved ? colorScheme.secondary : colorScheme.tertiary,
                  ),
                  sizedBoxW4H4,
                  Text(
                    reward.resolved ? tr.resolved : tr.unresolved,
                    style: textTheme.bodyMedium?.copyWith(
                      color: reward.resolved ? colorScheme.secondary : colorScheme.tertiary,
                    ),
                  ),
                ],
              ),
              AppInsetBlock(
                color: colorScheme.surfaceContainerHigh,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.paid_outlined, size: 18, color: colorScheme.primary),
                    sizedBoxW8H8,
                    Flexible(
                      child: Text(
                        tr.price(
                          price: reward.price,
                          credit: [?credit?.title, if (credit?.unit.isNotEmpty ?? false) credit!.unit].join(' '),
                        ),
                        style: textTheme.bodyLarge,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (best != null) ...[
            sizedBoxW12H12,
            Text(tr.bestAnswer, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            sizedBoxW8H8,
            Row(
              children: [
                if (best.anonymous)
                  _Avatar(null, tr.anonymous)
                else
                  GestureDetector(
                    onTap: () async => context.dispatchAsUrl('$baseUrl/home.php?mod=space&uid=${best.authorId}'),
                    child: _Avatar(best.avatar, best.author),
                  ),
                sizedBoxW8H8,
                Expanded(
                  child: Text(
                    best.anonymous ? tr.anonymous : best.author,
                    style: textTheme.titleSmall?.copyWith(color: colorScheme.primary),
                  ),
                ),
                if (best.url case final url?)
                  TextButton.icon(
                    onPressed: () async => context.dispatchAsUrl(url),
                    icon: const Icon(Icons.north_east),
                    label: Text(tr.jumpToFloor),
                  ),
              ],
            ),
            sizedBoxW8H8,
            SizedBox(
              width: double.infinity,
              child: AppInsetBlock(
                color: colorScheme.surfaceContainerHigh,
                child: switch (best.excerpt) {
                  final String excerpt => Text(context.displayText(excerpt), style: textTheme.bodyMedium),
                  null => Row(
                    children: [
                      Icon(Icons.lock_outline, size: 18, color: colorScheme.outline),
                      sizedBoxW8H8,
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tr.hiddenContent, style: textTheme.titleSmall),
                            Text(
                              switch (best.excerptReason) {
                                'locked' => tr.hiddenLocked,
                                'hide' => tr.hiddenHide,
                                'password' => tr.hiddenPassword,
                                'banned' => tr.hiddenBanned,
                                'moderate' => tr.hiddenModerate,
                                'json' || 'imgcontent' => tr.hiddenFormat,
                                'spoofed' => tr.hiddenSpoofed,
                                _ => tr.hiddenOther,
                              },
                              style: textTheme.bodySmall?.copyWith(color: colorScheme.outline),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                },
              ),
            ),
          ],
          if (reward.canSetBest && (reward.setBest?.pids.isNotEmpty ?? false)) ...[
            sizedBoxW8H8,
            AppNoticeBanner(message: tr.setBestHint, icon: Icons.verified_outlined),
          ],
        ],
      ),
    );
  }
}
