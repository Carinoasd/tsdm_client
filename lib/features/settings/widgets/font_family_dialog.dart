import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/settings/repositories/custom_font_store.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Dialog for choosing font family.
class FontFamilyDialog extends StatefulWidget {
  /// Constructor.
  const FontFamilyDialog(this.initialFont, {this.store, super.key});

  /// Where imported fonts are kept, the app's own store when null.
  final CustomFontStore? store;

  /// Initial font family
  final String initialFont;

  @override
  State<FontFamilyDialog> createState() => _FontFamilyDialogState();
}

class _FontFamilyDialogState extends State<FontFamilyDialog> {
  late TextEditingController _fontController;
  CustomFontStore? _store;
  List<String> _imported = const [];
  bool _importFailed = false;

  @override
  void initState() {
    super.initState();
    _fontController = TextEditingController(text: widget.initialFont);
    unawaited(_loadStore());
  }

  Future<void> _loadStore() async {
    final store = widget.store ?? await CustomFontStore.open();
    // Register them all so every row can be previewed.
    await store.loadAll();
    final imported = await store.list();
    if (!mounted) {
      return;
    }
    setState(() {
      _store = store;
      _imported = imported;
    });
  }

  Future<void> _import() async {
    final store = _store;
    if (store == null) {
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: context.t.settingsPage.appearanceSection.fontFamily.importFile,
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) {
      return;
    }
    setState(() => _importFailed = false);
    String? family;
    try {
      family = await store.import(File(path));
    } on Object {
      family = null;
    }
    if (!mounted) {
      return;
    }
    final imported = await store.list();
    if (!mounted) {
      return;
    }
    setState(() {
      _importFailed = family == null;
      _imported = imported;
      if (family != null) {
        _fontController.text = family;
      }
    });
  }

  Future<void> _delete(String family) async {
    final store = _store;
    if (store == null) {
      return;
    }
    await store.delete(family);
    final imported = await store.list();
    if (!mounted) {
      return;
    }
    setState(() {
      _imported = imported;
      if (_fontController.text.trim() == family) {
        _fontController.clear();
      }
    });
  }

  @override
  void dispose() {
    _fontController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.fontFamily;
    final textTheme = Theme.of(context).textTheme;
    final font = _fontController.text.trim();
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.font_download_outlined, title: tr.dialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            // Room for the floating label of the filled field.
            padding: edgeInsetsT4,
            child: TextField(
              controller: _fontController,
              autofocus: true,
              decoration: appFieldDecoration(label: tr.title, icon: Icons.text_fields_outlined),
              onChanged: (_) => setState(() {}),
            ),
          ),
          sizedBoxW12H12,
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.file_open_outlined),
              label: Text(tr.importFile),
              onPressed: _store == null ? null : _import,
            ),
          ),
          if (_importFailed)
            Text(tr.importFailed, style: textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
          for (final family in _imported)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              selected: family == font,
              title: Text(family),
              onTap: () => setState(() => _fontController.text = family),
              trailing: IconButton(
                tooltip: tr.deleteFont,
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(family),
              ),
            ),
          sizedBoxW12H12,
          // Preview of the typed family; an unknown family falls back to the default font like the app does.
          AppInsetBlock(
            outlined: true,
            padding: edgeInsetsL12T12R12B12,
            child: Text(
              '${context.t.appName}\nAa Bb Cc 0123',
              style: textTheme.titleMedium?.copyWith(fontFamily: font.isEmpty ? null : font),
            ),
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.restart_alt_outlined),
          label: Text(context.t.general.reset),
          onPressed: () => context.pop(''),
        ),
        FilledButton(child: Text(context.t.general.ok), onPressed: () => context.pop(_fontController.text)),
      ],
    );
  }
}
