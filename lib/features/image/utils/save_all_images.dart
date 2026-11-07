import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tsdm_client/features/image/models/gallery_image.dart';
import 'package:tsdm_client/features/image/utils/batch_image_save.dart';
import 'package:tsdm_client/features/image/utils/image_actions.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Save the pictures of a floor ([floor]) or of its page ([page]): asks which when the page has more than the floor.
///
/// Returns once they are saved (or the user stopped, or picked nothing).
Future<void> saveImagesAskingScope(
  BuildContext context, {
  required List<GalleryImage> floor,
  List<GalleryImage>? page,
}) async {
  final floorImages = distinctGalleryImages(floor);
  final pageImages = distinctGalleryImages(page ?? const []);
  final List<GalleryImage> chosen;
  if (pageImages.length <= floorImages.length) {
    chosen = floorImages;
  } else if (floorImages.isEmpty) {
    chosen = pageImages;
  } else {
    final tr = context.t.imageBottomSheet;
    final picked = await showDialog<List<GalleryImage>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tr.saveAllImages),
        children: [
          _ScopeOption(label: tr.saveScopeFloor, count: floorImages.length, images: floorImages),
          _ScopeOption(label: tr.saveScopePage, count: pageImages.length, images: pageImages),
        ],
      ),
    );
    if (picked == null || !context.mounted) {
      return;
    }
    chosen = picked;
  }
  await saveAllImages(context, chosen);
}

class _ScopeOption extends StatelessWidget {
  const _ScopeOption({required this.label, required this.count, required this.images});

  final String label;
  final int count;
  final List<GalleryImage> images;

  @override
  Widget build(BuildContext context) {
    return SimpleDialogOption(
      onPressed: () => Navigator.of(context).pop(images),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text('$count', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        ],
      ),
    );
  }
}

/// Where the images saved by [saveAllImages] are kept on a phone before the system takes them (a folder of the
/// temporary directory, emptied by the next batch).
Future<Directory> _batchFolder() async {
  final folder = Directory(path.join((await getTemporaryDirectory()).path, 'saved_images_batch'));
  if (folder.existsSync()) {
    await folder.delete(recursive: true);
  }
  await folder.create(recursive: true);
  return folder;
}

/// Save every picture of [images] with a progress that can be stopped, then tell how many went and how many did not.
///
/// On desktop the user picks a folder once and the files are written there. A phone has no folder to write to
/// (scoped storage): the files are made in the app's temporary folder and handed to the system's share sheet together,
/// which saves them where the user chooses.
Future<void> saveAllImages(BuildContext context, List<GalleryImage> images) async {
  final pictures = distinctGalleryImages(images);
  if (pictures.isEmpty) {
    return;
  }
  final tr = context.t.imageBottomSheet;
  final navigator = Navigator.of(context, rootNavigator: true);
  final FolderImageSink sink;
  if (isDesktop) {
    final folder = await FilePicker.platform.getDirectoryPath(dialogTitle: tr.saveAllImages);
    if (folder == null) {
      return;
    }
    sink = FolderImageSink(folder);
  } else {
    sink = FolderImageSink((await _batchFolder()).path);
  }
  if (!context.mounted) {
    return;
  }
  final cancel = BatchSaveCancel();
  final progress = ValueNotifier<int>(0);
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _BatchProgressDialog(progress: progress, total: pictures.length, cancel: cancel),
    ),
  );
  final BatchSaveResult result;
  try {
    result = await saveImagesInBatch(
      images: pictures,
      fetch: imageBytesOf,
      sink: sink,
      cancel: cancel,
      onProgress: (done, total) => progress.value = done,
    );
  } finally {
    navigator.pop();
    progress.dispose();
  }
  if (!isDesktop && sink.savedPaths.isNotEmpty) {
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [for (final e in sink.savedPaths) XFile(e, mimeType: imageMimeTypeOf(e), name: path.basename(e))],
        ),
      );
    } on Exception catch (e, st) {
      talker.handle(e, st, 'failed to hand the saved images over');
    }
  }
  if (!context.mounted) {
    return;
  }
  showSnackBar(
    context: context,
    message: result.cancelled
        ? tr.saveAllCancelled(saved: result.saved)
        : tr.saveAllDone(saved: result.saved, failed: result.failed),
  );
}

class _BatchProgressDialog extends StatefulWidget {
  const _BatchProgressDialog({required this.progress, required this.total, required this.cancel});

  final ValueNotifier<int> progress;
  final int total;
  final BatchSaveCancel cancel;

  @override
  State<_BatchProgressDialog> createState() => _BatchProgressDialogState();
}

class _BatchProgressDialogState extends State<_BatchProgressDialog> {
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(context.t.imageBottomSheet.saveAllImages),
        content: ValueListenableBuilder<int>(
          valueListenable: widget.progress,
          builder: (context, done, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: done / widget.total),
              const SizedBox(height: 8),
              Text(context.t.imageGallery.counter(index: done, total: widget.total)),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('batch-save-cancel'),
            onPressed: widget.cancel.isCancelled ? null : () => setState(widget.cancel.cancel),
            child: Text(context.t.general.cancel),
          ),
        ],
      ),
    );
  }
}
