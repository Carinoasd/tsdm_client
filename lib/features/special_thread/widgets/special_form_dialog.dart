import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Let the user fill the fields [inputs] of a form of the forum (the activity's application, its cancel), each drawn
/// as the forum's form type asks: a text field (`text`), a text area (`textarea`), a drop down (`select`), radio
/// buttons (`radio`), check boxes (`checkbox`), prefilled with the account's own values the forum gives. Pops with
/// the values by field name (text, or the list of a check box), null when cancelled. [inputs] are all drawn types
/// ([SpecialFormInput.drawn]): the caller sends a form with any other to the web page instead.
///
/// The submit button waits for every required field. The forum's pair of the activity's cost (`payment` 1 "支付"
/// with its amount `payvalue`) is kept: the amount is only taken when paying is chosen.
Future<Map<String, Object>?> showSpecialFormDialog(
  BuildContext context, {
  required String title,
  required IconData icon,
  required List<SpecialFormInput> inputs,
  required String submitLabel,
}) => showDialog<Map<String, Object>>(
  context: context,
  builder: (_) => RootPage(
    DialogPaths.specialThreadForm,
    SpecialFormDialog(title: title, icon: icon, inputs: inputs, submitLabel: submitLabel),
  ),
);

/// The dialog of [showSpecialFormDialog].
class SpecialFormDialog extends StatefulWidget {
  /// Constructor.
  const SpecialFormDialog({
    required this.title,
    required this.icon,
    required this.inputs,
    required this.submitLabel,
    super.key,
  });

  /// Title.
  final String title;

  /// Icon of the title.
  final IconData icon;

  /// The fields.
  final List<SpecialFormInput> inputs;

  /// The submit button.
  final String submitLabel;

  @override
  State<SpecialFormDialog> createState() => _SpecialFormDialogState();
}

class _SpecialFormDialogState extends State<SpecialFormDialog> {
  /// Text and text area fields.
  final _texts = <String, TextEditingController>{};

  /// Drop downs and radio buttons.
  final _choices = <String, String?>{};

  /// Check boxes.
  final _checks = <String, Set<String>>{};

  @override
  void initState() {
    super.initState();
    for (final input in widget.inputs) {
      switch (input.type) {
        case 'select' || 'radio':
          _choices[input.name] = input.choices.any((c) => c.value == input.value) ? input.value : null;
        case 'checkbox':
          // The forum keeps several values as one text joined by commas (`implode(',')`).
          final values = input.value.split(RegExp(r'[,\n\r]+')).map((e) => e.trim()).toSet();
          _checks[input.name] = {
            for (final c in input.choices)
              if (values.contains(c.value)) c.value,
          };
        default:
          _texts[input.name] = TextEditingController(text: input.value)..addListener(() => setState(() {}));
      }
    }
  }

  @override
  void dispose() {
    for (final c in _texts.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// The amount of the cost is only asked when paying is chosen (`payment` 1).
  bool _enabled(SpecialFormInput input) {
    if (input.name != 'payvalue' || !_choices.containsKey('payment')) {
      return true;
    }
    return _choices['payment'] == '1';
  }

  bool _filled(SpecialFormInput input) => switch (input.type) {
    'select' || 'radio' => (_choices[input.name] ?? '').isNotEmpty,
    'checkbox' => _checks[input.name]?.isNotEmpty ?? false,
    _ => _texts[input.name]!.text.trim().isNotEmpty,
  };

  bool get _complete => widget.inputs.every((e) => !e.required || !_enabled(e) || _filled(e));

  void _submit() {
    if (!_complete) {
      return;
    }
    Navigator.of(context).pop(<String, Object>{
      for (final input in widget.inputs)
        input.name: switch (input.type) {
          'select' || 'radio' => _choices[input.name] ?? '',
          'checkbox' => [
            for (final c in input.choices)
              if (_checks[input.name]!.contains(c.value)) c.value,
          ],
          _ => _enabled(input) ? _texts[input.name]!.text.trim() : '',
        },
    });
  }

  String _label(SpecialFormInput input) {
    final tr = context.t.specialThread.activity;
    final title = input.title.isNotEmpty ? input.title : (input.name == 'payvalue' ? tr.payValue : input.name);
    return input.required ? '$title *' : title;
  }

  Widget _field(SpecialFormInput input) {
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius));
    final textTheme = Theme.of(context).textTheme;
    switch (input.type) {
      case 'select':
        return DropdownButtonFormField<String>(
          style: AppTheme.dropdownStyle(context),
          initialValue: _choices[input.name],
          isExpanded: true,
          borderRadius: BorderRadius.circular(appInnerRadius),
          decoration: InputDecoration(labelText: _label(input), filled: true, border: border),
          items: [
            for (final c in input.choices)
              DropdownMenuItem(
                value: c.value,
                child: Text(c.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() => _choices[input.name] = v),
        );
      case 'radio':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_label(input), style: textTheme.labelLarge),
            RadioGroup<String>(
              groupValue: _choices[input.name],
              onChanged: (v) => setState(() => _choices[input.name] = v),
              child: Column(
                children: [
                  for (final c in input.choices)
                    RadioListTile<String>(value: c.value, contentPadding: EdgeInsets.zero, title: Text(c.label)),
                ],
              ),
            ),
          ],
        );
      case 'checkbox':
        final checked = _checks[input.name]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_label(input), style: textTheme.labelLarge),
            for (final c in input.choices)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(c.label),
                value: checked.contains(c.value),
                onChanged: (v) => setState(() => (v ?? false) ? checked.add(c.value) : checked.remove(c.value)),
              ),
          ],
        );
      default:
        final area = input.type == 'textarea';
        return TextField(
          controller: _texts[input.name],
          enabled: _enabled(input),
          minLines: area ? 3 : 1,
          maxLines: area ? 6 : 1,
          // The forum takes at most 200 characters of the applicant's message.
          maxLength: input.name == 'message' ? 200 : null,
          keyboardType: input.name == 'payvalue' ? TextInputType.number : null,
          decoration: InputDecoration(labelText: _label(input), filled: true, border: border),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.specialThread;
    final complete = _complete;
    return AlertDialog(
      scrollable: true,
      title: AppDialogTitle(icon: widget.icon, title: widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final input in widget.inputs) ...[_field(input), sizedBoxW12H12],
          if (!complete) AppNoticeBanner(message: tr.activity.fillRequired),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton(onPressed: complete ? _submit : null, child: Text(widget.submitLabel)),
      ],
    );
  }
}
