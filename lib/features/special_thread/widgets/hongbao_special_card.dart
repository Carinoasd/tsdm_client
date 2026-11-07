part of 'special_thread_card.dart';

/// The red packet of a thread of the hongbao plugin (plugin 3.5.0): its sender, blessing, split, shares, conditions,
/// expiry, state and the account's own share; grabbing (asking the password first for a packet with one), the
/// records and, for its sender, withdrawing what is left. Without [onReload] (the post of a notice, an offline copy)
/// it only shows the packet.
class _HongbaoCard extends StatefulWidget {
  const _HongbaoCard(this.packet, {required this.onReload});

  final HongbaoSpecial packet;
  final VoidCallback? onReload;

  @override
  State<_HongbaoCard> createState() => _HongbaoCardState();
}

class _HongbaoCardState extends State<_HongbaoCard> {
  bool _busy = false;
  String? _refusal;

  HongbaoSpecial get _packet => widget.packet;

  @override
  void didUpdateWidget(covariant _HongbaoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The page read again: what the forum said of the packet before no longer holds.
    if (!identical(oldWidget.packet, widget.packet)) {
      _refusal = null;
    }
  }

  HongbaoRepository get _repository =>
      context.readOrNull<HongbaoRepository>() ?? HongbaoRepository.network(getIt.get<NetClientProvider>());

  /// The account in use is still the one the page was served to.
  bool get _sameAccount {
    final auth = context.readOrNull<AuthenticationRepository>();
    return auth == null || auth.effectiveCurrentUid == _packet.viewerUid;
  }

  String get _creditName => _packet.credit?.title ?? '';

  Future<void> _grab() async {
    String? passwordError;
    while (mounted) {
      var password = '';
      if (_packet.hasPassword) {
        final input = await _askPassword(error: passwordError);
        if (input == null || !mounted) {
          return;
        }
        password = input;
      }
      final request = _packet.grabRequest(password: password);
      if (request == null) {
        return;
      }
      final outcome = await _send(request, withdraw: false);
      if (outcome case HongbaoRefused(badPassword: true, :final message) when _packet.hasPassword && mounted) {
        setState(() => _refusal = null);
        passwordError = message;
        continue;
      }
      return;
    }
  }

  Future<void> _withdraw() async {
    final tr = context.t.specialThread.hongbao;
    final confirmed = await showQuestionDialog(
      context: context,
      title: tr.withdrawConfirmTitle,
      message: tr.withdrawConfirm(credit: _creditName),
      dangerous: true,
    );
    if (!mounted || !(confirmed ?? false)) {
      return;
    }
    if (_packet.withdrawRequest() case final request?) {
      await _send(request, withdraw: true);
    }
  }

  /// Send [request] for the account the page was served to: a done action says what the forum did and reloads the
  /// thread page, a refusal shows the forum's words (and reloads when the packet changed since), no verdict reloads.
  Future<HongbaoOutcome?> _send(SpecialRequest request, {required bool withdraw}) async {
    if (_busy) {
      return null;
    }
    final tr = context.t.specialThread;
    if (!_sameAccount) {
      setState(() => _refusal = tr.accountChanged);
      return null;
    }
    setState(() {
      _busy = true;
      _refusal = null;
    });
    final outcome = await _repository.submit(request, withdraw: withdraw);
    if (!mounted) {
      return outcome;
    }
    setState(() => _busy = false);
    switch (outcome) {
      case HongbaoGrabbed(:final amount, :final unit, :final best, :final already):
        final text = already
            ? tr.hongbao.already(amount: amount, unit: unit)
            : tr.hongbao.grabbed(amount: amount, unit: unit);
        showSnackBar(context: context, message: best ? '$text · ${tr.hongbao.best}' : text);
        widget.onReload?.call();
      case HongbaoWithdrawn(:final refunded):
        showSnackBar(
          context: context,
          message: tr.hongbao.withdrawn(amount: refunded, unit: _creditName),
        );
        widget.onReload?.call();
      case HongbaoRefused(badPassword: true) when !withdraw && _packet.hasPassword:
        // Asked again with the forum's words ([_grab]).
        break;
      case final HongbaoRefused refused when refused.reloads:
        showSnackBar(context: context, message: refused.message);
        widget.onReload?.call();
      case HongbaoRefused(:final message):
        setState(() => _refusal = message);
      case HongbaoUnknown():
        showSnackBar(context: context, message: tr.unknown);
        widget.onReload?.call();
    }
    return outcome;
  }

  Future<String?> _askPassword({String? error}) => showDialog<String>(
    context: context,
    builder: (_) => _HongbaoPasswordDialog(error: error),
  );

  Future<void> _showRecords() async {
    final url = _packet.recordsUrl;
    if (url == null) {
      return;
    }
    final repository = _repository;
    final timeOffset = _packet.timeOffset;
    await showCustomBottomSheet<void>(
      context: context,
      title: context.t.specialThread.hongbao.records,
      builder: (context) => _HongbaoRecordsList(future: repository.records(url, timeOffset: timeOffset)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.specialThread.hongbao;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final p = _packet;
    final actions = widget.onReload != null;
    final active = p.status == HongbaoStatus.active;
    final statusColor = active ? colorScheme.error : colorScheme.outline;
    final why = switch (p.why) {
      'disabled' => tr.why.disabled,
      'login' => tr.why.login,
      'self' => tr.why.self,
      // The account's share says it, when told.
      'claimed' when p.mine == null => tr.why.claimed,
      'appoint' => tr.why.appoint,
      'needreply' => tr.why.needreply,
      // The state says it (withdrawn, expired, closed, done).
      _ => null,
    };
    final mine = p.mine;

    return AppEmbedCard(
      icon: Icons.redeem_outlined,
      title: tr.title,
      accent: colorScheme.error,
      trailing: Text(
        switch (p.status) {
          HongbaoStatus.active => tr.status.active,
          HongbaoStatus.done => tr.status.done,
          HongbaoStatus.withdrawn => tr.status.withdrawn,
          HongbaoStatus.expired => tr.status.expired,
          HongbaoStatus.closed => tr.status.closed,
        },
        style: textTheme.labelLarge?.copyWith(color: statusColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _UserPill(uid: p.senderUid, name: p.senderName, avatar: p.senderAvatar),
            ],
          ),
          if (p.blessing.isNotEmpty) ...[
            sizedBoxW12H12,
            SelectableText(p.blessing, style: textTheme.titleMedium),
          ],
          sizedBoxW12H12,
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _Badge(
                icon: p.even ? Icons.drag_handle : Icons.shuffle,
                label: p.even ? tr.even : tr.lucky,
                color: colorScheme.primary,
              ),
              _Badge(
                icon: Icons.pie_chart_outline,
                label: tr.shares(claimed: p.claimedShares, shares: p.shares),
                color: colorScheme.primary,
              ),
              if (p.needReply) _Badge(icon: Icons.reply_outlined, label: tr.needReply, color: colorScheme.tertiary),
              if (p.hasPassword) _Badge(icon: Icons.key_outlined, label: tr.password, color: colorScheme.tertiary),
              if (p.appoint) _Badge(icon: Icons.person_pin_outlined, label: tr.appoint, color: colorScheme.tertiary),
              _Badge(
                icon: Icons.schedule,
                label: switch (p.expireTime) {
                  final time? => tr.expireAt(time: time.yyyyMMDDHHMM()),
                  null => tr.noExpire,
                },
                color: colorScheme.outline,
              ),
            ],
          ),
          if (mine != null) ...[
            sizedBoxW12H12,
            AppInsetBlock(
              color: colorScheme.errorContainer,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.paid_outlined, size: 18, color: colorScheme.onErrorContainer),
                  sizedBoxW8H8,
                  Flexible(
                    child: Text(
                      tr.mine(amount: mine.amount, credit: _creditName.isEmpty ? '' : ' $_creditName'),
                      style: textTheme.bodyLarge?.copyWith(color: colorScheme.onErrorContainer),
                    ),
                  ),
                  if (mine.best) ...[
                    sizedBoxW8H8,
                    _Badge(icon: Icons.emoji_events_outlined, label: tr.best, color: colorScheme.onErrorContainer),
                  ],
                ],
              ),
            ),
          ],
          if (why != null) ...[
            sizedBoxW8H8,
            Text(why, style: textTheme.bodyMedium?.copyWith(color: colorScheme.outline)),
          ],
          if (actions && (p.canGrab || p.canViewRecords || p.canWithdraw)) ...[
            sizedBoxW12H12,
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (p.canGrab)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: colorScheme.error,
                      foregroundColor: colorScheme.onError,
                    ),
                    onPressed: _busy ? null : _grab,
                    icon: _busy
                        ? const SizedBox(width: 16, height: 16, child: CircularIndicator())
                        : const Icon(Icons.redeem),
                    label: Text(tr.grab),
                  ),
                if (p.canViewRecords && p.recordsUrl != null)
                  OutlinedButton.icon(
                    onPressed: _showRecords,
                    icon: const Icon(Icons.list_alt_outlined),
                    label: Text(tr.records),
                  ),
                if (p.canWithdraw)
                  TextButton.icon(
                    onPressed: _busy ? null : _withdraw,
                    icon: const Icon(Icons.undo),
                    label: Text(tr.withdraw),
                  ),
              ],
            ),
          ],
          if (_refusal case final message?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: AppNoticeBanner(tone: AppNoticeTone.error, message: message, selectable: true),
            ),
        ],
      ),
    );
  }
}

/// Asks the password of a red packet; [error] is the forum's words about the one tried before.
class _HongbaoPasswordDialog extends StatefulWidget {
  const _HongbaoPasswordDialog({this.error});

  final String? error;

  @override
  State<_HongbaoPasswordDialog> createState() => _HongbaoPasswordDialogState();
}

class _HongbaoPasswordDialogState extends State<_HongbaoPasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.specialThread.hongbao;
    return AlertDialog(
      title: AppDialogTitle(icon: Icons.key_outlined, title: tr.passwordTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: tr.password, errorText: widget.error, filled: true),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton(onPressed: () => Navigator.of(context).pop(_controller.text), child: Text(tr.grab)),
      ],
    );
  }
}

/// The records of a red packet: who grabbed what and when, the luckiest share marked; the forum's words when it
/// refuses to show them.
class _HongbaoRecordsList extends StatelessWidget {
  const _HongbaoRecordsList({required this.future});

  final Future<HongbaoRecordsOutcome> future;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.specialThread.hongbao;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return FutureBuilder<HongbaoRecordsOutcome>(
      future: future,
      builder: (context, snapshot) {
        final body = switch (snapshot.data) {
          null => const Padding(
            padding: edgeInsetsL24T24R24B24,
            child: Center(child: CircularIndicator()),
          ),
          HongbaoRecordsRefused(:final message) => Padding(
            padding: edgeInsetsL12T8R12B8,
            child: AppNoticeBanner(tone: AppNoticeTone.error, message: message, selectable: true),
          ),
          HongbaoRecordsFailed() => Padding(
            padding: edgeInsetsL12T8R12B8,
            child: AppNoticeBanner(tone: AppNoticeTone.error, message: tr.recordsFailed),
          ),
          HongbaoRecords(:final records) when records.isEmpty => Padding(
            padding: edgeInsetsL24T24R24B24,
            child: Center(
              child: Text(tr.recordsEmpty, style: TextStyle(color: colorScheme.outline)),
            ),
          ),
          HongbaoRecords(:final records, :final credit) => ListView(
            shrinkWrap: true,
            padding: context.safePadding(),
            children: [
              for (final r in records)
                ListTile(
                  leading: _Avatar(r.avatar, r.username, radius: 18),
                  title: Text(r.username),
                  subtitle: r.time == null ? null : Text(r.time!.yyyyMMDDHHMM()),
                  onTap: r.uid > 0
                      ? () async => context.dispatchAsUrl('$baseUrl/home.php?mod=space&uid=${r.uid}')
                      : null,
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        [_number(r.amount), ?credit?.title].join(' '),
                        style: textTheme.titleMedium?.copyWith(color: colorScheme.error),
                      ),
                      if (r.best) Text(tr.best, style: textTheme.labelSmall?.copyWith(color: colorScheme.tertiary)),
                    ],
                  ),
                ),
            ],
          ),
        };
        return body;
      },
    );
  }
}
