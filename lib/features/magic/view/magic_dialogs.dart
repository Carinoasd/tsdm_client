import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/magic/models/magic_models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Show the buy or use window [form] of [item]; the values to post when the user confirms, null when cancelled.
Future<Map<String, String>?> showMagicFormDialog(
  BuildContext context, {
  required MagicForm form,
  required MagicItem item,
  required Widget image,
}) => showDialog<Map<String, String>>(
  context: context,
  builder: (context) => _MagicFormDialog(form: form, item: item, image: image),
);

/// Tell that [item] can only be used on the website, with a way there.
Future<void> showMagicUnsupportedDialog(BuildContext context, {required MagicItem item, required Widget image}) {
  final tr = context.t.magicCenter;
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: _DialogTitle(name: item.name, image: image),
      content: Text(tr.unsupported),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton.icon(
          onPressed: () async {
            Navigator.of(context).pop();
            await context.dispatchAsUrl(magicBoxUrl, external: true);
          },
          icon: const Icon(Icons.open_in_browser_outlined),
          label: Text(tr.openBrowser),
        ),
      ],
    ),
  );
}

class _DialogTitle extends StatelessWidget {
  const _DialogTitle({required this.name, required this.image});

  final String name;
  final Widget image;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      AppInsetBlock(padding: const EdgeInsets.all(6), child: image),
      sizedBoxW12H12,
      Expanded(child: Text(name)),
    ],
  );
}

class _MagicFormDialog extends StatefulWidget {
  const _MagicFormDialog({required this.form, required this.item, required this.image});

  final MagicForm form;
  final MagicItem item;
  final Widget image;

  @override
  State<_MagicFormDialog> createState() => _MagicFormDialogState();
}

class _MagicFormDialogState extends State<_MagicFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _text = {
    for (final f in widget.form.fields)
      if (f.role != MagicFieldRole.choice) f.name: TextEditingController(text: f.value),
  };
  late final Map<String, String> _choice = {
    for (final f in widget.form.fields)
      if (f.role == MagicFieldRole.choice) f.name: f.value,
  };

  bool get _buy => widget.form.hidden['operation'] == 'buy';

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  int get _count => int.tryParse(_text['magicnum']?.text ?? '') ?? 0;

  void _setCount(int value) {
    final max = widget.form.maxCount;
    final clamped = value < 1 ? 1 : (max != null && max > 0 && value > max ? max : value);
    setState(() => _text['magicnum']!.text = '$clamped');
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop({
      for (final f in widget.form.fields)
        f.name: switch (f.role) {
          MagicFieldRole.choice => _choice[f.name] ?? f.value,
          MagicFieldRole.thread => magicThreadIdOf(_text[f.name]!.text),
          _ => _text[f.name]!.text.trim(),
        },
    });
  }

  Widget _countField(MagicField field, TranslationsMagicCenterEn tr) {
    final max = widget.form.maxCount;
    final price = widget.form.unitPrice;
    return Row(
      children: [
        IconButton.filledTonal(
          key: const ValueKey('magic-count-minus'),
          onPressed: _count <= 1 ? null : () => _setCount(_count - 1),
          icon: const Icon(Icons.remove),
        ),
        sizedBoxW8H8,
        Expanded(
          child: TextFormField(
            key: const ValueKey('magic-field-magicnum'),
            controller: _text[field.name],
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: tr.fieldCount,
              suffixText: price == null ? null : '× $price',
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            validator: (v) {
              final n = int.tryParse(v ?? '') ?? 0;
              if (n < 1 || (max != null && n > max)) return max == null ? tr.required : '1 – $max';
              return null;
            },
          ),
        ),
        sizedBoxW8H8,
        IconButton.filledTonal(
          key: const ValueKey('magic-count-plus'),
          onPressed: max != null && _count >= max ? null : () => _setCount(_count + 1),
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }

  Widget _field(MagicField field, TranslationsMagicCenterEn tr) {
    if (field.role == MagicFieldRole.number && _buy) return _countField(field, tr);
    if (field.role == MagicFieldRole.choice) {
      return DropdownButtonFormField<String>(
        key: ValueKey('magic-field-${field.name}'),
        initialValue: field.options.any((o) => o.value == _choice[field.name]) ? _choice[field.name] : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: field.label.isEmpty ? null : field.label,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final o in field.options)
            DropdownMenuItem(
              value: o.value,
              child: Text(o.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => setState(() => _choice[field.name] = v ?? field.value),
      );
    }
    // The three common inputs get the app's short label and keyboard; any other keeps the forum's own label.
    final (String? label, IconData? icon, TextInputType keyboard, bool required) = switch (field.role) {
      MagicFieldRole.thread => (tr.fieldThread, Icons.article_outlined, TextInputType.url, true),
      MagicFieldRole.user => (tr.fieldUser, Icons.person_outline, TextInputType.text, true),
      MagicFieldRole.newName => (tr.fieldNewName, Icons.badge_outlined, TextInputType.text, true),
      MagicFieldRole.number => (field.label.isEmpty ? tr.fieldCount : field.label, null, TextInputType.number, true),
      MagicFieldRole.multiline => (field.label.isEmpty ? null : field.label, null, TextInputType.multiline, false),
      _ => (field.label.isEmpty ? null : field.label, null, TextInputType.text, false),
    };
    return TextFormField(
      key: ValueKey('magic-field-${field.name}'),
      controller: _text[field.name],
      keyboardType: keyboard,
      minLines: field.role == MagicFieldRole.multiline ? 3 : 1,
      maxLines: field.role == MagicFieldRole.multiline ? 6 : 1,
      inputFormatters: field.role == MagicFieldRole.number ? [FilteringTextInputFormatter.digitsOnly] : null,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: icon == null ? null : Icon(icon),
        border: const OutlineInputBorder(),
      ),
      validator: (v) {
        final text = (v ?? '').trim();
        if (required && text.isEmpty) return tr.required;
        if (field.role == MagicFieldRole.thread && !RegExp(r'^\d+$').hasMatch(magicThreadIdOf(text))) {
          return tr.fieldThread;
        }
        return null;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.magicCenter;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final form = widget.form;
    final muted = textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant);
    return AlertDialog(
      scrollable: true,
      title: _DialogTitle(name: form.title.isEmpty ? widget.item.name : form.title, image: widget.image),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final note in form.notes) ...[Text(note, style: muted), sizedBoxW8H8],
            if (form.facts.isNotEmpty) ...[
              AppInsetBlock(
                outlined: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (i, fact) in form.facts.indexed)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                        child: Text(fact, style: textTheme.bodyMedium),
                      ),
                  ],
                ),
              ),
              sizedBoxW12H12,
            ],
            for (final (i, field) in form.fields.indexed) ...[
              if (i > 0) sizedBoxW12H12,
              _field(field, tr),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton(
          key: const ValueKey('magic-submit'),
          onPressed: _buy && form.maxCount == 0 ? null : _submit,
          child: Text(_buy ? tr.buy : tr.use),
        ),
      ],
    );
  }
}
