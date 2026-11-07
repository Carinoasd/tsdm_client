import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/post/models/special_thread_form.dart';
import 'package:tsdm_client/features/post/widgets/activity_dialog.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Ask the debate of a new debate thread with the fields of [info]; [initial] is the debate set so far.
///
/// Returns the debate, null when not set.
Future<DebateEdits?> showDebateDialog(BuildContext context, DebateFormInfo info, DebateEdits? initial) async =>
    showDialog<DebateEdits>(
      context: context,
      builder: (_) => RootPage(DialogPaths.debate, _DebateDialog(info, initial)),
    );

/// What the debate dialog says about [issue].
String debateIssueText(BuildContext context, DebateIssue issue) {
  final tr = context.t.postEditPage.debateDialog.issue;
  return switch (issue) {
    DebateIssue.pointsRequired => tr.pointsRequired,
    DebateIssue.endPassed => tr.endPassed,
  };
}

class _DebateDialog extends StatefulWidget {
  const _DebateDialog(this.info, this.initial);

  final DebateFormInfo info;

  final DebateEdits? initial;

  @override
  State<_DebateDialog> createState() => _DebateDialogState();
}

class _DebateDialogState extends State<_DebateDialog> {
  final formKey = GlobalKey<FormState>();

  late final TextEditingController affirm;
  late final TextEditingController negate;
  late final TextEditingController umpire;
  DateTime? end;

  /// The dialog was confirmed once: the issue of the end is shown from then on.
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    affirm = TextEditingController(text: initial?.affirm ?? '');
    negate = TextEditingController(text: initial?.negate ?? '');
    umpire = TextEditingController(text: initial?.umpire ?? '');
    end = initial?.end;
  }

  @override
  void dispose() {
    affirm.dispose();
    negate.dispose();
    umpire.dispose();
    super.dispose();
  }

  /// The debate as the fields stand.
  DebateEdits get edits =>
      DebateEdits(affirm: affirm.text.trim(), negate: negate.text.trim(), end: end, umpire: umpire.text.trim());

  String? _issue(DebateIssue of) {
    final issue = edits.check(DateTime.now());
    return issue == of ? debateIssueText(context, issue!) : null;
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.postEditPage.debateDialog;
    final info = widget.info;
    return CustomAlertDialog.sync(
      title: Row(
        children: [
          const AppIconTile(Icons.balance_outlined, size: 36),
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
              controller: affirm,
              autofocus: true,
              decoration: InputDecoration(labelText: tr.affirm),
              minLines: 1,
              maxLines: 4,
              validator: (v) => (v ?? '').trim().isEmpty ? debateIssueText(context, DebateIssue.pointsRequired) : null,
            ),
            sizedBoxW12H12,
            TextFormField(
              controller: negate,
              decoration: InputDecoration(labelText: tr.negate),
              minLines: 1,
              maxLines: 4,
              validator: (v) => (v ?? '').trim().isEmpty ? debateIssueText(context, DebateIssue.pointsRequired) : null,
            ),
            if (info.hasEnd) ...[
              sizedBoxW12H12,
              DateTimeField(
                label: tr.end,
                value: end,
                onChanged: (v) => setState(() => end = v),
                onCleared: () => setState(() => end = null),
                errorText: _checked ? _issue(DebateIssue.endPassed) : null,
              ),
            ],
            if (info.hasUmpire) ...[
              sizedBoxW12H12,
              TextFormField(
                controller: umpire,
                decoration: InputDecoration(labelText: tr.umpire),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(child: Text(context.t.general.cancel), onPressed: () => context.pop()),
        FilledButton(
          child: Text(context.t.general.ok),
          onPressed: () {
            setState(() => _checked = true);
            final valid = formKey.currentState?.validate() ?? false;
            if (valid && edits.check(DateTime.now()) == null) {
              context.pop(edits);
            }
          },
        ),
      ],
    );
  }
}
