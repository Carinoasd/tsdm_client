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

/// Ask the poll settings of the first post of a poll edited, with the options and settings of [info]; [initial] is
/// what is set so far.
///
/// Returns the settings, null when not changed.
Future<PollEdits?> showPollSettingsDialog(BuildContext context, PollEditFormInfo info, PollEdits initial) async =>
    showDialog<PollEdits>(
      context: context,
      builder: (_) => RootPage(DialogPaths.pollSettings, _PollSettingsDialog(info, initial)),
    );

/// What the poll settings dialog says about [issue] against [info].
String pollEditIssueText(BuildContext context, PollEditFormInfo info, PollEditIssue issue) {
  final tr = context.t.pollCreate.issues;
  return switch (issue) {
    PollEditIssue.optionEmpty => context.t.postEditPage.pollDialog.optionEmpty,
    PollEditIssue.optionLineBreak => tr.optionLineBreak,
    PollEditIssue.optionTooLong => tr.optionTooLong,
    PollEditIssue.tooManyOptions => tr.tooManyOptions(max: info.maxOptions),
    PollEditIssue.maxChoicesInvalid => tr.maxChoicesInvalid,
    PollEditIssue.expiryInvalid => tr.expiryInvalid,
  };
}

class _PollSettingsDialog extends StatefulWidget {
  const _PollSettingsDialog(this.info, this.initial);

  final PollEditFormInfo info;

  final PollEdits initial;

  @override
  State<_PollSettingsDialog> createState() => _PollSettingsDialogState();
}

class _PollSettingsDialogState extends State<_PollSettingsDialog> {
  late final Map<int, TextEditingController> texts;
  late final List<TextEditingController> added;
  late final TextEditingController maxChoices;
  late final TextEditingController expiration;
  late bool visibleAfterVote;
  late bool overt;

  /// The dialog was confirmed once: the issues are shown from then on.
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    texts = {
      for (final option in widget.info.options)
        option.id: TextEditingController(text: initial.texts[option.id] ?? option.text),
    };
    added = [for (final option in initial.added) TextEditingController(text: option)];
    maxChoices = TextEditingController(text: initial.maxChoices);
    expiration = TextEditingController(text: initial.expiration);
    visibleAfterVote = initial.visibleAfterVote;
    overt = initial.overt;
  }

  @override
  void dispose() {
    for (final controller in [...texts.values, ...added, maxChoices, expiration]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The settings as the fields stand.
  PollEdits get edits => PollEdits(
    texts: {for (final MapEntry(:key, :value) in texts.entries) key: value.text},
    added: [for (final option in added) option.text],
    maxChoices: maxChoices.text,
    expiration: expiration.text,
    visibleAfterVote: visibleAfterVote,
    overt: overt,
  );

  @override
  Widget build(BuildContext context) {
    final tr = context.t.pollCreate;
    final info = widget.info;
    final issues = _checked ? edits.issues(info) : null;
    String? text(PollEditIssue? issue) => issue == null ? null : pollEditIssueText(context, info, issue);
    final count = info.options.length + added.length;
    return CustomAlertDialog.sync(
      title: Row(
        children: [
          const AppIconTile(Icons.poll_outlined, size: 36),
          sizedBoxW12H12,
          Expanded(child: Text(context.t.postEditPage.pollDialog.title)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, option) in info.options.indexed) ...[
            if (i > 0) sizedBoxW8H8,
            TextField(
              controller: texts[option.id],
              readOnly: option.readonly,
              decoration: InputDecoration(
                labelText: tr.optionLabel(index: i + 1),
                errorText: text(issues?.options[option.id]),
                errorMaxLines: 4,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
          for (final (i, controller) in added.indexed) ...[
            sizedBoxW8H8,
            Row(
              key: ObjectKey(controller),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    autofocus: controller.text.isEmpty,
                    decoration: InputDecoration(
                      labelText: tr.optionLabel(index: info.options.length + i + 1),
                      errorText: text(issues?.added[i]),
                      errorMaxLines: 4,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                IconButton(
                  tooltip: tr.removeOption,
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => setState(() => added.removeAt(i).dispose()),
                ),
              ],
            ),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add),
              label: Text(tr.addOption),
              onPressed: info.maxOptions > 0 && count >= info.maxOptions
                  ? null
                  : () => setState(() => added.add(TextEditingController())),
            ),
          ),
          if (issues?.poll.contains(PollEditIssue.tooManyOptions) ?? false)
            Text(
              text(PollEditIssue.tooManyOptions)!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          sizedBoxW12H12,
          TextField(
            controller: maxChoices,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: tr.maxChoices,
              errorMaxLines: 3,
              errorText: (issues?.poll.contains(PollEditIssue.maxChoicesInvalid) ?? false)
                  ? text(PollEditIssue.maxChoicesInvalid)
                  : null,
            ),
          ),
          sizedBoxW12H12,
          TextField(
            controller: expiration,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: tr.expiry,
              errorMaxLines: 3,
              errorText: (issues?.poll.contains(PollEditIssue.expiryInvalid) ?? false)
                  ? text(PollEditIssue.expiryInvalid)
                  : null,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr.visibleAfterVote),
            value: visibleAfterVote,
            onChanged: (value) => setState(() => visibleAfterVote = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr.publicVoters),
            value: overt,
            onChanged: (value) => setState(() => overt = value),
          ),
        ],
      ),
      actions: [
        TextButton(child: Text(context.t.general.cancel), onPressed: () => context.pop()),
        FilledButton(
          child: Text(context.t.general.ok),
          onPressed: () {
            setState(() => _checked = true);
            if (edits.check(info) == null) {
              context.pop(edits);
            }
          },
        ),
      ],
    );
  }
}
