part of 'special_thread_card.dart';

/// The activity: its details as the page prints them, the account's application, applying (the forum's form, every
/// field it asks drawn by [showSpecialFormDialog]; a form with a field the app cannot draw goes to the web page),
/// cancelling with a reason, managing (the web page), and the applicants the page shows.
class _ActivityCard extends StatefulWidget {
  const _ActivityCard(this.activity, {required this.onReload, required this.webUrl});

  final ActivitySpecial activity;
  final VoidCallback? onReload;

  /// The thread on the web page, for an application the app cannot fill.
  final String? webUrl;

  @override
  State<_ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<_ActivityCard> with _SpecialActions {
  @override
  VoidCallback? get _reload => widget.onReload;

  ActivitySpecial get _activity => widget.activity;

  Future<void> _apply() async {
    final tr = context.t.specialThread.activity;
    final form = _activity.apply;
    if (form == null) {
      return;
    }
    final values = await showSpecialFormDialog(
      context,
      title: _activity.applyMode == 'complete' ? tr.complete : tr.applyTitle,
      icon: Icons.how_to_reg_outlined,
      inputs: form.inputs,
      submitLabel: context.t.specialThread.submit,
    );
    if (values == null || !mounted) {
      return;
    }
    if (_activity.applyRequest(values) case final request?) {
      await _run(request);
    }
  }

  Future<void> _cancel() async {
    final tr = context.t.specialThread.activity;
    final form = _activity.cancel;
    if (form == null) {
      return;
    }
    final message = form.inputs.where((e) => e.name == 'message').firstOrNull;
    final values = await showSpecialFormDialog(
      context,
      title: tr.cancelTitle,
      icon: Icons.event_busy_outlined,
      inputs: [
        if (message != null)
          SpecialFormInput(
            name: message.name,
            title: tr.cancelReason,
            type: 'textarea',
            required: message.required,
            value: message.value,
            choices: const [],
            html: '',
          ),
      ],
      submitLabel: tr.cancel,
    );
    if (values == null || !mounted) {
      return;
    }
    if (_activity.cancelRequest(values['message'] is String ? values['message']! as String : '') case final request?) {
      await _run(request);
    }
  }

  List<Widget> _applicants(String title, List<ActivityApplicant> list) {
    final tr = context.t.specialThread.activity;
    return [
      sizedBoxW12H12,
      Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
      sizedBoxW8H8,
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final a in list)
            _UserPill(
              uid: a.uid,
              name: a.username,
              avatar: a.avatar,
              detail: [
                if (a.payment case final payment?) payment < 0 ? tr.selfPay : tr.pays(amount: payment),
                if (a.message.isNotEmpty) context.displayText(a.message),
              ].join(' · '),
            ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.specialThread.activity;
    final a = _activity;
    final actions = widget.onReload != null;
    final credit = a.credit;
    final start = a.startFrom;
    final end = a.startTo;
    final status = switch (a.verified) {
      0 when a.applied => tr.statusWaiting,
      1 => tr.statusAccepted,
      2 => tr.statusComplete,
      _ => null,
    };
    return AppEmbedCard(
      icon: Icons.event_outlined,
      title: tr.title,
      subtitle: a.activityClass.isEmpty ? null : context.displayText(a.activityClass),
      trailing: _busy ? const SizedBox(width: 20, height: 20, child: CircularIndicator()) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (a.image case final image?)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(appInnerRadius),
                child: CachedImage(image, maxHeight: 200, fit: BoxFit.contain),
              ),
            ),
          if (a.activityClass.isNotEmpty) _InfoRow(tr.type, context.displayText(a.activityClass)),
          if (start != null)
            _InfoRow(
              tr.time,
              end == null ? start.yyyyMMDDHHMM() : tr.timeRange(from: start.yyyyMMDDHHMM(), to: end.yyyyMMDDHHMM()),
            ),
          if (a.place.isNotEmpty) _InfoRow(tr.place, context.displayText(a.place)),
          _InfoRow(tr.gender, switch (a.gender) {
            1 => tr.genderMale,
            2 => tr.genderFemale,
            _ => tr.genderAny,
          }),
          if (a.cost > 0) _InfoRow(tr.cost, tr.costValue(cost: a.cost)),
          _InfoRow(tr.places, a.number > 0 ? '${a.number}' : tr.placesUnlimited),
          if (a.appliedCount case final applied?)
            _InfoRow(
              tr.applied,
              tr.appliedValue(count: applied, verified: a.verifiedCount, pending: a.pendingCount),
            ),
          if (a.remaining case final remaining?) _InfoRow(tr.remaining, '$remaining'),
          if (a.expiration case final expiration?) _InfoRow(tr.deadline, expiration.yyyyMMDDHHMM()),
          if (credit != null) _InfoRow(tr.credit, tr.creditValue(amount: credit.amount, credit: credit.credit.title)),
          if (a.closed) ...[
            sizedBoxW8H8,
            AppNoticeBanner(tone: AppNoticeTone.warning, icon: Icons.event_busy_outlined, message: tr.closed),
          ],
          if (status != null) ...[
            sizedBoxW8H8,
            AppNoticeBanner(icon: Icons.how_to_reg_outlined, message: status),
          ],
          if (credit != null && !credit.enough && a.viewerUid != null) ...[
            sizedBoxW8H8,
            AppNoticeBanner(
              tone: AppNoticeTone.warning,
              message: tr.creditNotEnough(credit: credit.credit.title),
            ),
          ],
          if (actions && a.canApply && a.applyNeedsWeb) ...[
            sizedBoxW8H8,
            AppNoticeBanner(message: tr.needsWeb),
          ],
          ?_refusalBanner(),
          if (actions && (a.canApply || a.canCancel || a.canManage)) ...[
            sizedBoxW8H8,
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (a.canApply && a.apply != null && !a.applyNeedsWeb)
                  FilledButton.icon(
                    onPressed: _busy ? null : _apply,
                    icon: const Icon(Icons.how_to_reg_outlined),
                    label: Text(a.applyMode == 'complete' ? tr.complete : tr.join),
                  ),
                if (a.canApply && a.applyNeedsWeb && widget.webUrl != null)
                  FilledButton.tonalIcon(
                    onPressed: () async => _openInBrowser(context, widget.webUrl!),
                    icon: const Icon(Icons.open_in_browser_outlined),
                    label: Text(tr.applyOnWeb),
                  ),
                if (a.canCancel && a.cancel != null)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _cancel,
                    icon: const Icon(Icons.event_busy_outlined),
                    label: Text(tr.cancel),
                  ),
                if (a.canManage && a.manageUrl != null)
                  TextButton.icon(
                    onPressed: () async => _openInBrowser(context, a.manageUrl!),
                    icon: const Icon(Icons.open_in_browser_outlined),
                    label: Text(tr.manage),
                  ),
              ],
            ),
          ],
          if (a.applyList.isNotEmpty) ..._applicants(tr.accepted(count: a.verifiedCount), a.applyList),
          if (a.applyListMore case final more?)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () async => _openInBrowser(context, more),
                icon: const Icon(Icons.open_in_browser_outlined),
                label: Text(tr.more),
              ),
            ),
          if (a.pending.isNotEmpty) ..._applicants(tr.waiting(count: a.pendingCount), a.pending),
        ],
      ),
    );
  }
}
