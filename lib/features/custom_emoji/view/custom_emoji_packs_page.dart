import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/custom_emoji/models/custom_emoji.dart';
import 'package:tsdm_client/features/custom_emoji/repository/custom_emoji_store.dart';
import 'package:tsdm_client/features/custom_emoji/widgets/custom_emoji_image.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The largest image file read when adding images to a pack, in bytes.
const int _maxPickedBytes = 20 * 1024 * 1024;

CustomEmojiStore get _store => CustomEmojiStore.app ?? (throw StateError('no custom emoji store'));

/// Ask for the name of a pack, [initial] filled in; null when cancelled or left empty.
Future<String?> _askName(BuildContext context, {required String title, String initial = ''}) async {
  final controller = TextEditingController(text: initial);
  try {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: InputDecoration(labelText: context.t.customEmoji.name),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: Text(context.t.general.ok)),
        ],
      ),
    );
    final trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  } finally {
    controller.dispose();
  }
}

/// Save the zip of the packs [ids] (all when null) where the user picks.
Future<void> _export(BuildContext context, {Set<String>? ids, String name = 'emoji_packs'}) async {
  final tr = context.t.customEmoji;
  try {
    final data = await _store.exportArchive(ids);
    final fileName = 'tsdm_${name.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')}.zip';
    if (isDesktop) {
      final path = await FilePicker.platform.saveFile(dialogTitle: tr.export, fileName: fileName);
      if (path == null) return;
      await File(path).writeAsBytes(data, flush: true);
    } else {
      await FilePicker.platform.saveFile(dialogTitle: tr.export, fileName: fileName, bytes: data);
    }
  } on Object catch (e, st) {
    talker.handle(e, st, 'failed to export custom emoji packs');
    if (context.mounted) {
      showSnackBar(context: context, message: tr.exportFailed);
    }
  }
}

/// Read a zip the user picks into the packs.
Future<void> _import(BuildContext context) async {
  final tr = context.t.customEmoji;
  final picked = await FilePicker.platform.pickFiles(
    dialogTitle: tr.import,
    type: FileType.custom,
    allowedExtensions: const ['zip'],
  );
  final path = picked?.files.firstOrNull?.path;
  if (path == null || !context.mounted) return;
  int? added;
  try {
    added = await _store.importArchive(await File(path).readAsBytes());
  } on Object catch (e, st) {
    talker.handle(e, st, 'failed to import custom emoji packs');
  }
  if (!context.mounted) return;
  showSnackBar(
    context: context,
    message: added == null ? tr.importInvalid : tr.imported(count: added),
  );
}

/// The custom emoji packs: their order (drag), a new one, import and export; a tap opens one.
class CustomEmojiPacksPage extends StatelessWidget {
  /// Constructor.
  const CustomEmojiPacksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = context.t.customEmoji;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.title),
        actions: [
          IconButton(
            key: const ValueKey('custom-emoji-import'),
            icon: const Icon(Icons.file_download_outlined),
            tooltip: tr.import,
            onPressed: () async => _import(context),
          ),
          ValueListenableBuilder<List<CustomEmojiPack>>(
            valueListenable: _store.packs,
            builder: (context, packs, _) => IconButton(
              key: const ValueKey('custom-emoji-export'),
              icon: const Icon(Icons.file_upload_outlined),
              tooltip: tr.export,
              onPressed: packs.isEmpty ? null : () async => _export(context),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('custom-emoji-new-pack'),
        tooltip: tr.newPack,
        onPressed: () async {
          final name = await _askName(context, title: tr.newPack);
          if (name == null || !context.mounted) return;
          final pack = await _store.createPack(name);
          if (!context.mounted) return;
          await context.pushNamed(ScreenPaths.customEmojiPack, pathParameters: {'packId': pack.id});
        },
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        child: ValueListenableBuilder<List<CustomEmojiPack>>(
          valueListenable: _store.packs,
          builder: (context, packs, _) {
            if (packs.isEmpty) {
              return AppStateView(icon: Icons.emoji_emotions_outlined, message: tr.empty);
            }
            return ReorderableListView.builder(
              padding: edgeInsetsT8.copyWith(bottom: 88),
              itemCount: packs.length,
              onReorder: (from, to) async => _store.movePack(from, to),
              itemBuilder: (context, index) {
                final pack = packs[index];
                final cover = pack.emojis.firstOrNull;
                return ListTile(
                  key: ValueKey('custom-emoji-pack-${pack.id}'),
                  leading: SizedBox.square(
                    dimension: 40,
                    child: cover == null
                        ? const Icon(Icons.emoji_emotions_outlined)
                        : CustomEmojiImage(cover, size: 40),
                  ),
                  title: Text(pack.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Padding(
                    // Room for the drag handle of desktop.
                    padding: isDesktop ? const EdgeInsets.only(right: 32) : EdgeInsets.zero,
                    child: Text(tr.count(count: pack.emojis.length)),
                  ),
                  onTap: () async =>
                      context.pushNamed(ScreenPaths.customEmojiPack, pathParameters: {'packId': pack.id}),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// One custom emoji pack: its images in a grid, dragged to reorder, a tap removes one; adding images, renaming,
/// exporting and deleting the pack.
class CustomEmojiPackPage extends StatefulWidget {
  /// Constructor.
  const CustomEmojiPackPage({required this.packId, super.key});

  /// The pack.
  final String packId;

  @override
  State<CustomEmojiPackPage> createState() => _CustomEmojiPackPageState();
}

enum _PackAction { rename, export, delete }

class _CustomEmojiPackPageState extends State<CustomEmojiPackPage> {
  bool _adding = false;

  Future<void> _addImages() async {
    final tr = context.t.customEmoji;
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: tr.addImages,
      type: FileType.image,
      allowMultiple: true,
    );
    final paths = picked?.files.map((e) => e.path).nonNulls.toList() ?? const [];
    if (paths.isEmpty || !mounted) return;
    setState(() => _adding = true);
    var added = 0;
    try {
      added = await _store.addImages(widget.packId, [
        for (final path in paths)
          () async {
            final file = File(path);
            if (await file.length() > _maxPickedBytes) return null;
            return Uint8List.fromList(await file.readAsBytes());
          },
      ]);
    } finally {
      if (mounted) {
        setState(() => _adding = false);
        showSnackBar(
          context: context,
          message: added == 0 ? tr.noneAdded : tr.added(count: added),
        );
      }
    }
  }

  Future<void> _onAction(_PackAction action, CustomEmojiPack pack) async {
    final tr = context.t.customEmoji;
    switch (action) {
      case _PackAction.rename:
        final name = await _askName(context, title: tr.rename, initial: pack.name);
        if (name != null) await _store.renamePack(pack.id, name);
      case _PackAction.export:
        await _export(context, ids: {pack.id}, name: pack.name);
      case _PackAction.delete:
        final ok = await showQuestionDialog(
          context: context,
          title: tr.delete,
          message: tr.deleteConfirm(name: pack.name),
          dangerous: true,
        );
        if (ok != true || !mounted) return;
        context.pop();
        await _store.deletePack(pack.id);
    }
  }

  Widget _tile(BuildContext context, CustomEmojiPack pack, int index) {
    final emoji = pack.emojis[index];
    final image = CustomEmojiImage(emoji, size: 72);
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) async =>
          _store.moveEmoji(pack.id, details.data, details.data < index ? index + 1 : index),
      builder: (context, candidates, _) => LongPressDraggable<int>(
        data: index,
        feedback: Material(
          type: MaterialType.transparency,
          child: SizedBox.square(dimension: 72, child: image),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: image),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(appInnerRadius),
            border: candidates.isEmpty ? null : Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: ValueKey('custom-emoji-item-${emoji.sha256}'),
              borderRadius: BorderRadius.circular(appInnerRadius),
              onTap: () async {
                final ok = await showQuestionDialog(
                  context: context,
                  title: context.t.customEmoji.removeTitle,
                  message: context.t.customEmoji.remove,
                  dangerous: true,
                );
                if (ok ?? false) await _store.removeEmoji(pack.id, emoji);
              },
              child: Padding(padding: const EdgeInsets.all(4), child: image),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.customEmoji;
    return ValueListenableBuilder<List<CustomEmojiPack>>(
      valueListenable: _store.packs,
      builder: (context, packs, _) {
        final pack = packs.where((e) => e.id == widget.packId).firstOrNull;
        return Scaffold(
          appBar: AppBar(
            title: Text(pack?.name ?? tr.title),
            bottom: _adding
                ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
                : null,
            actions: [
              if (pack != null)
                PopupMenuButton<_PackAction>(
                  key: const ValueKey('custom-emoji-pack-menu'),
                  onSelected: (action) async => _onAction(action, pack),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: _PackAction.rename,
                      child: ListTile(leading: const Icon(Icons.edit_outlined), title: Text(tr.rename)),
                    ),
                    PopupMenuItem(
                      value: _PackAction.export,
                      enabled: pack.emojis.isNotEmpty,
                      child: ListTile(leading: const Icon(Icons.file_upload_outlined), title: Text(tr.export)),
                    ),
                    PopupMenuItem(
                      value: _PackAction.delete,
                      child: ListTile(
                        leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                        title: Text(tr.delete, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          floatingActionButton: pack == null
              ? null
              : FloatingActionButton(
                  key: const ValueKey('custom-emoji-add-images'),
                  tooltip: tr.addImages,
                  onPressed: _adding ? null : _addImages,
                  child: const Icon(Icons.add_photo_alternate_outlined),
                ),
          body: SafeArea(
            child: pack == null || pack.emojis.isEmpty
                ? AppStateView(icon: Icons.add_photo_alternate_outlined, message: tr.addImages)
                : GridView.builder(
                    padding: edgeInsetsL12T12R12B12.copyWith(bottom: 88),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 88,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                    ),
                    itemCount: pack.emojis.length,
                    itemBuilder: (context, index) => _tile(context, pack, index),
                  ),
          ),
        );
      },
    );
  }
}
