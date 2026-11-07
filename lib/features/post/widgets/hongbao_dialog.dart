import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/post/models/special_thread_form.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Ask the red packet of a new red packet thread within the limits of [info]; [initial] is the packet set so far
/// (the form's defaults when none).
///
/// Returns the packet, null when not set.
Future<HongbaoEdits?> showHongbaoDialog(BuildContext context, HongbaoFormInfo info, HongbaoEdits? initial) async =>
    showDialog<HongbaoEdits>(
      context: context,
      builder: (_) => RootPage(DialogPaths.hongbao, _HongbaoDialog(info, initial ?? info.initial)),
    );

/// What the red packet dialog says about [issue] against [info] and the packet [edits].
String hongbaoIssueText(BuildContext context, HongbaoFormInfo info, HongbaoEdits edits, HongbaoIssue issue) {
  final tr = context.t.postEditPage.hongbaoDialog.issue;
  return switch (issue) {
    HongbaoIssue.totalRequired => tr.totalRequired,
    HongbaoIssue.sharesRequired => tr.sharesRequired,
    HongbaoIssue.sharesAboveMax => tr.sharesAboveMax(max: info.maxShares),
    HongbaoIssue.totalBelowShares => tr.totalBelowShares(min: info.minShare, need: info.minShare * (edits.shares ?? 0)),
    HongbaoIssue.notDivisible => tr.notDivisible,
    HongbaoIssue.shortage => tr.shortage,
    HongbaoIssue.blessingTooLong => tr.blessingTooLong(max: info.blessingMax ?? 0),
    HongbaoIssue.passwordTooLong => tr.passwordTooLong(max: info.passwordMax ?? 0),
  };
}

class _HongbaoDialog extends StatefulWidget {
  const _HongbaoDialog(this.info, this.initial);

  final HongbaoFormInfo info;

  final HongbaoEdits initial;

  @override
  State<_HongbaoDialog> createState() => _HongbaoDialogState();
}

class _HongbaoDialogState extends State<_HongbaoDialog> {
  final formKey = GlobalKey<FormState>();

  late final TextEditingController total;
  late final TextEditingController shares;
  late final TextEditingController password;
  late final TextEditingController appoint;
  late final TextEditingController blessing;
  late HongbaoSplit split;
  late bool condReply;
  late String expire;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    total = TextEditingController(text: initial.total == null ? '' : '${initial.total}');
    shares = TextEditingController(text: initial.shares == null ? '' : '${initial.shares}');
    password = TextEditingController(text: initial.password);
    appoint = TextEditingController(text: initial.appoint);
    blessing = TextEditingController(text: initial.blessing);
    split = initial.split;
    condReply = initial.condReply;
    expire = widget.info.expireChoices.any((e) => e.$1 == initial.expire) ? initial.expire : widget.info.expireDefault;
  }

  @override
  void dispose() {
    total.dispose();
    shares.dispose();
    password.dispose();
    appoint.dispose();
    blessing.dispose();
    super.dispose();
  }

  /// The packet as the fields stand.
  HongbaoEdits get edits => HongbaoEdits(
    total: int.tryParse(total.text.trim()),
    shares: int.tryParse(shares.text.trim()),
    split: split,
    condReply: condReply,
    password: password.text.trim(),
    appoint: appoint.text.trim(),
    expire: expire,
    blessing: blessing.text.trim(),
  );

  /// The validator of the field the issues [of] belong to: the first issue of the whole packet when it is one of
  /// them, so each field shows its own.
  String? Function(String?) _validator(Set<HongbaoIssue> of) => (_) {
    final current = edits;
    final issue = current.check(widget.info);
    return issue != null && of.contains(issue) ? hongbaoIssueText(context, widget.info, current, issue) : null;
  };

  @override
  Widget build(BuildContext context) {
    final tr = context.t.postEditPage.hongbaoDialog;
    final info = widget.info;
    final credit = info.creditLabel;
    return CustomAlertDialog.sync(
      title: Row(
        children: [
          const AppIconTile(Icons.card_giftcard_outlined, size: 36),
          sizedBoxW12H12,
          Expanded(child: Text(tr.title)),
        ],
      ),
      content: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: total,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr.total,
                suffixText: credit.isEmpty ? null : credit,
                // A printed 0 proves nothing (HongbaoEdits.check): not shown.
                helperText: switch (info.balance) {
                  final int balance when balance > 0 => tr.balance(balance: balance, credit: credit),
                  _ => null,
                },
                errorMaxLines: 2,
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: _validator(const {
                HongbaoIssue.totalRequired,
                HongbaoIssue.totalBelowShares,
                HongbaoIssue.notDivisible,
                HongbaoIssue.shortage,
              }),
            ),
            sizedBoxW12H12,
            TextFormField(
              controller: shares,
              decoration: InputDecoration(
                labelText: tr.shares,
                helperText: info.maxShares > 0
                    ? tr.sharesLimit(max: info.maxShares, min: info.minShare)
                    : tr.minShare(min: info.minShare),
                errorMaxLines: 2,
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: _validator(const {HongbaoIssue.sharesRequired, HongbaoIssue.sharesAboveMax}),
            ),
            sizedBoxW12H12,
            SegmentedButton<HongbaoSplit>(
              segments: [
                ButtonSegment(value: HongbaoSplit.lucky, label: Text(tr.lucky)),
                ButtonSegment(value: HongbaoSplit.even, label: Text(tr.even)),
              ],
              selected: {split},
              onSelectionChanged: (v) => setState(() => split = v.first),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(tr.condReply),
              value: condReply,
              onChanged: (v) => setState(() => condReply = v ?? false),
            ),
            DropdownButtonFormField<String>(
              initialValue: expire,
              decoration: InputDecoration(labelText: tr.expire),
              items: [
                for (final (value, label) in info.expireChoices) DropdownMenuItem(value: value, child: Text(label)),
              ],
              onChanged: (v) => setState(() => expire = v ?? info.expireDefault),
            ),
            sizedBoxW12H12,
            TextFormField(
              controller: blessing,
              decoration: InputDecoration(labelText: tr.blessing, errorMaxLines: 2),
              maxLength: info.blessingMax,
              validator: _validator(const {HongbaoIssue.blessingTooLong}),
            ),
            TextFormField(
              controller: password,
              decoration: InputDecoration(labelText: tr.password, errorMaxLines: 2),
              maxLength: info.passwordMax,
              validator: _validator(const {HongbaoIssue.passwordTooLong}),
            ),
            TextFormField(
              controller: appoint,
              decoration: InputDecoration(labelText: tr.appoint, hintText: tr.appointHint),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(child: Text(context.t.general.cancel), onPressed: () => context.pop()),
        FilledButton(
          child: Text(context.t.general.ok),
          onPressed: () {
            if (formKey.currentState?.validate() ?? false) {
              context.pop(edits);
            }
          },
        ),
      ],
    );
  }
}
