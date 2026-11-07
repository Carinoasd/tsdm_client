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

/// Ask the reward credits of a new reward thread within the limits of [info], or the raised price of an open one
/// ([RewardFormInfo.raising]); [initial] is the price set so far.
///
/// Returns the price, null when not set.
Future<int?> showRewardPriceDialog(BuildContext context, RewardFormInfo info, int? initial) async => showDialog<int>(
  context: context,
  builder: (_) => RootPage(DialogPaths.rewardPrice, _RewardPriceDialog(info, initial)),
);

/// What the reward price dialog says about [issue] against [info].
String rewardIssueText(BuildContext context, RewardFormInfo info, RewardPriceIssue issue) {
  final tr = context.t.postEditPage.rewardDialog.issue;
  return switch (issue) {
    RewardPriceIssue.empty => tr.empty,
    RewardPriceIssue.overflow => tr.overflow,
    RewardPriceIssue.belowMin => tr.belowMin(min: info.min),
    RewardPriceIssue.aboveMax => tr.aboveMax(max: info.max),
    RewardPriceIssue.shortage => tr.shortage,
    RewardPriceIssue.fall => tr.fall(current: info.current ?? 0),
  };
}

class _RewardPriceDialog extends StatefulWidget {
  const _RewardPriceDialog(this.info, this.initial);

  final RewardFormInfo info;

  final int? initial;

  @override
  State<_RewardPriceDialog> createState() => _RewardPriceDialogState();
}

class _RewardPriceDialogState extends State<_RewardPriceDialog> {
  final formKey = GlobalKey<FormState>();

  late final TextEditingController controller;

  int? price;

  @override
  void initState() {
    super.initState();
    price = widget.initial ?? widget.info.served;
    controller = TextEditingController(text: price == null ? '' : '$price')..addListener(_changed);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _changed() => setState(() => price = int.tryParse(controller.text.trim()));

  @override
  Widget build(BuildContext context) {
    final tr = context.t.postEditPage.rewardDialog;
    final info = widget.info;
    final credit = info.creditLabel;
    final real = price;
    final helper = [
      if (info.max > 0)
        tr.range(min: info.floor, max: info.max, credit: credit)
      else
        tr.min(min: info.floor, credit: credit),
      if (info.have case final int have) tr.balance(have: have, credit: credit),
      if (info.raising) ...[
        if (real != null && real > info.current! && real <= RewardFormInfo.overflow)
          tr.raiseCost(real: info.cost(real), credit: credit),
      ] else if (real != null && real > 0 && real <= RewardFormInfo.overflow)
        tr.afterTax(real: info.realPrice(real), credit: credit),
    ].join('\n');
    return CustomAlertDialog.sync(
      title: Row(
        children: [
          const AppIconTile(Icons.emoji_events_outlined, size: 36),
          sizedBoxW12H12,
          Expanded(child: Text(tr.title)),
        ],
      ),
      content: Form(
        key: formKey,
        child: TextFormField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr.price,
            suffixText: credit.isEmpty ? null : credit,
            helperText: helper,
            helperMaxLines: 3,
            errorMaxLines: 2,
          ),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          validator: (v) {
            final issue = info.check(int.tryParse((v ?? '').trim()));
            return issue == null ? null : rewardIssueText(context, info, issue);
          },
        ),
      ),
      actions: [
        TextButton(child: Text(context.t.general.cancel), onPressed: () => context.pop()),
        FilledButton(
          child: Text(context.t.general.ok),
          onPressed: () {
            if (formKey.currentState?.validate() ?? false) {
              context.pop(int.tryParse(controller.text.trim()));
            }
          },
        ),
      ],
    );
  }
}
