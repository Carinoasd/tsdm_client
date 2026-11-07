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

/// Ask the activity of a new activity thread with the fields of [info]; [initial] is the activity set so far.
///
/// Returns the activity, null when not set.
Future<ActivityEdits?> showActivityDialog(BuildContext context, ActivityFormInfo info, ActivityEdits? initial) async =>
    showDialog<ActivityEdits>(
      context: context,
      builder: (_) => RootPage(DialogPaths.activity, _ActivityDialog(info, initial)),
    );

/// What the activity dialog says about [issue] against [info].
String activityIssueText(BuildContext context, ActivityFormInfo info, ActivityIssue issue) {
  final tr = context.t.postEditPage.activityDialog.issue;
  return switch (issue) {
    ActivityIssue.classRequired => tr.classRequired,
    ActivityIssue.startRequired => tr.startRequired,
    ActivityIssue.endBeforeStart => tr.endBeforeStart,
    ActivityIssue.placeRequired => tr.placeRequired,
    ActivityIssue.extFieldsTooMany => tr.extFieldsTooMany(max: info.extNum),
  };
}

/// Pick a date and then a time, from [initial] (now when none); null when either is cancelled.
Future<DateTime?> pickDateTime(BuildContext context, DateTime? initial) async {
  final now = DateTime.now();
  final from = initial ?? now;
  final first = DateTime(now.year - 1);
  final date = await showDatePicker(
    context: context,
    initialDate: from.isBefore(first) ? first : from,
    firstDate: first,
    lastDate: DateTime(now.year + 10),
  );
  if (date == null || !context.mounted) {
    return null;
  }
  final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(from));
  if (time == null) {
    return null;
  }
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

/// A date and time field: tapped to pick ([pickDateTime]), cleared with its button when [onCleared] is given.
class DateTimeField extends StatelessWidget {
  /// Constructor.
  const DateTimeField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.onCleared,
    this.errorText,
    this.fallback,
    super.key,
  });

  /// Where the picker starts when nothing is set (the start, for an end), now when null.
  final DateTime? fallback;

  /// The name of the field.
  final String label;

  /// The date and time set, null for none.
  final DateTime? value;

  /// A date and time was picked.
  final ValueChanged<DateTime> onChanged;

  /// The value was cleared; null for a field that cannot be cleared.
  final VoidCallback? onCleared;

  /// What is wrong with the value, null when nothing.
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final value = this.value;
    return InkWell(
      onTap: () async {
        final picked = await pickDateTime(context, value ?? fallback);
        if (picked != null) {
          onChanged(picked);
        }
      },
      child: InputDecorator(
        isEmpty: value == null,
        decoration: InputDecoration(
          labelText: label,
          errorText: errorText,
          errorMaxLines: 2,
          suffixIcon: value != null && onCleared != null
              ? IconButton(icon: const Icon(Icons.clear), onPressed: onCleared)
              : const Icon(Icons.event_outlined),
        ),
        child: value == null ? null : Text(discuzDateTime(value)),
      ),
    );
  }
}

class _ActivityDialog extends StatefulWidget {
  const _ActivityDialog(this.info, this.initial);

  final ActivityFormInfo info;

  final ActivityEdits? initial;

  @override
  State<_ActivityDialog> createState() => _ActivityDialogState();
}

class _ActivityDialogState extends State<_ActivityDialog> {
  final formKey = GlobalKey<FormState>();

  late final TextEditingController category;
  late final TextEditingController place;
  late final TextEditingController city;
  late final TextEditingController number;
  late final TextEditingController credit;
  late final TextEditingController cost;
  late final TextEditingController extFields;
  DateTime? start;
  DateTime? end;
  DateTime? expiration;
  late String gender;
  late Set<String> userFields;

  /// The dialog was confirmed once: the issues of the date fields are shown from then on.
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    category = TextEditingController(text: initial?.category ?? '');
    place = TextEditingController(text: initial?.place ?? '');
    city = TextEditingController(text: initial?.city ?? '');
    number = TextEditingController(text: initial?.number == null ? '' : '${initial!.number}');
    credit = TextEditingController(text: initial?.credit == null ? '' : '${initial!.credit}');
    cost = TextEditingController(text: initial?.cost == null ? '' : '${initial!.cost}');
    extFields = TextEditingController(text: initial?.extFields ?? '');
    start = initial?.start;
    end = initial?.end;
    expiration = initial?.expiration;
    final genders = widget.info.genders;
    gender = genders.any((e) => e.$1 == initial?.gender) ? initial!.gender : (genders.firstOrNull?.$1 ?? '0');
    userFields = {...?initial?.userFields};
  }

  @override
  void dispose() {
    category.dispose();
    place.dispose();
    city.dispose();
    number.dispose();
    credit.dispose();
    cost.dispose();
    extFields.dispose();
    super.dispose();
  }

  /// The activity as the fields stand.
  ActivityEdits get edits => ActivityEdits(
    category: category.text.trim(),
    start: start,
    end: end,
    place: place.text.trim(),
    city: city.text.trim(),
    number: int.tryParse(number.text.trim()),
    gender: gender,
    userFields: [
      for (final (value, _) in widget.info.userFields)
        if (userFields.contains(value)) value,
    ],
    credit: int.tryParse(credit.text.trim()),
    cost: int.tryParse(cost.text.trim()),
    expiration: expiration,
    extFields: extFields.text,
  );

  /// The issue of the activity among [of] (the ones of a field), so every field shows its own at once.
  String? _issue(Set<ActivityIssue> of) {
    final issue = edits.issues(widget.info).where(of.contains).firstOrNull;
    return issue == null ? null : activityIssueText(context, widget.info, issue);
  }

  String? Function(String?) _validator(Set<ActivityIssue> of) =>
      (_) => _issue(of);

  @override
  Widget build(BuildContext context) {
    final tr = context.t.postEditPage.activityDialog;
    final info = widget.info;
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return CustomAlertDialog.sync(
      title: Row(
        children: [
          const AppIconTile(Icons.event_outlined, size: 36),
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
              controller: category,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr.category,
                suffixIcon: info.types.isEmpty
                    ? null
                    : PopupMenuButton<String>(
                        icon: const Icon(Icons.arrow_drop_down),
                        onSelected: (v) => setState(() => category.text = v),
                        itemBuilder: (_) => [
                          for (final type in info.types) PopupMenuItem(value: type, child: Text(type)),
                        ],
                      ),
              ),
              validator: _validator(const {ActivityIssue.classRequired}),
            ),
            sizedBoxW12H12,
            DateTimeField(
              label: tr.start,
              value: start,
              onChanged: (v) => setState(() => start = v),
              errorText: _checked ? _issue(const {ActivityIssue.startRequired}) : null,
            ),
            sizedBoxW12H12,
            DateTimeField(
              label: tr.end,
              value: end,
              fallback: start,
              onChanged: (v) => setState(() => end = v),
              onCleared: () => setState(() => end = null),
              errorText: _checked ? _issue(const {ActivityIssue.endBeforeStart}) : null,
            ),
            sizedBoxW12H12,
            TextFormField(
              controller: place,
              decoration: InputDecoration(labelText: tr.place),
              validator: _validator(const {ActivityIssue.placeRequired}),
            ),
            if (info.hasCity) ...[
              sizedBoxW12H12,
              TextFormField(
                controller: city,
                decoration: InputDecoration(labelText: tr.city),
              ),
            ],
            sizedBoxW12H12,
            TextFormField(
              controller: number,
              decoration: InputDecoration(labelText: tr.number),
              keyboardType: TextInputType.number,
              inputFormatters: digits,
            ),
            if (info.genders.isNotEmpty) ...[
              sizedBoxW12H12,
              DropdownButtonFormField<String>(
                initialValue: gender,
                decoration: InputDecoration(labelText: tr.gender),
                items: [for (final (value, label) in info.genders) DropdownMenuItem(value: value, child: Text(label))],
                onChanged: (v) => setState(() => gender = v ?? gender),
              ),
            ],
            if (info.credit case final String creditName) ...[
              sizedBoxW12H12,
              TextFormField(
                controller: credit,
                decoration: InputDecoration(labelText: tr.credit, suffixText: creditName.isEmpty ? null : creditName),
                keyboardType: TextInputType.number,
                inputFormatters: digits,
              ),
            ],
            sizedBoxW12H12,
            TextFormField(
              controller: cost,
              decoration: InputDecoration(labelText: tr.cost),
              keyboardType: TextInputType.number,
              inputFormatters: digits,
            ),
            sizedBoxW12H12,
            DateTimeField(
              label: tr.expiration,
              value: expiration,
              onChanged: (v) => setState(() => expiration = v),
              onCleared: () => setState(() => expiration = null),
            ),
            if (info.userFields.isNotEmpty) ...[
              sizedBoxW12H12,
              Text(tr.userFields, style: Theme.of(context).textTheme.labelLarge),
              Wrap(
                spacing: 8,
                children: [
                  for (final (value, label) in info.userFields)
                    FilterChip(
                      label: Text(label),
                      selected: userFields.contains(value),
                      onSelected: (on) => setState(() => on ? userFields.add(value) : userFields.remove(value)),
                    ),
                ],
              ),
            ],
            if (info.extNum > 0) ...[
              sizedBoxW12H12,
              TextFormField(
                controller: extFields,
                decoration: InputDecoration(labelText: tr.extFields, errorMaxLines: 2),
                minLines: 2,
                maxLines: 5,
                validator: _validator(const {ActivityIssue.extFieldsTooMany}),
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
            if (valid && edits.check(info) == null) {
              context.pop(edits);
            }
          },
        ),
      ],
    );
  }
}
