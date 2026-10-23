import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fpdart/fpdart.dart' show None, Some;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
import 'package:tsdm_client/utils/browser_launcher.dart';
import 'package:tsdm_client/utils/image_file_name.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// The bytes of the image at [url]: from the cache, fetched when not cached. Null when it can not be had.
Future<Uint8List?> imageBytesOf(String url) async =>
    switch (await getIt.get<ImageCacheProvider>().getOrMakeCache(ImageCacheGeneralRequest(url))) {
      Some(:final value) => value,
      None() => null,
    };

/// Save the image at [url] where the user picks, named with the extension of its type ([imageFileNameOf]).
///
/// Tells the user where it went, or that it failed. Returns the path saved to, null when nothing was saved (failed, or
/// the user picked nothing).
Future<String?> saveImageOf(BuildContext context, String url) async {
  final tr = context.t.imageBottomSheet;
  final data = await imageBytesOf(url);
  if (data == null) {
    if (context.mounted) {
      showSnackBar(context: context, message: tr.failedToSaveImage);
    }
    return null;
  }
  final fileName = imageFileNameOf(url, data);
  final String? filePath;
  if (isDesktop) {
    // On desktop platforms, `saveFile` only returns the selected path.
    filePath = await FilePicker.platform.saveFile(dialogTitle: tr.saveImage, fileName: fileName);
    if (filePath == null) {
      return null;
    }
    await File(filePath).writeAsBytes(data, flush: true);
  } else {
    // Mobile in one step.
    filePath = await FilePicker.platform.saveFile(dialogTitle: tr.saveImage, fileName: fileName, bytes: data);
    if (filePath == null) {
      return null;
    }
  }
  if (context.mounted) {
    showSnackBar(
      context: context,
      message: tr.imageSaved(filePath: filePath),
    );
  }
  return filePath;
}

/// Whether an image can be shared as a file here: the share sheet of Linux only takes text.
bool get canShareImageFiles => debugCanShareImageFiles ?? !Platform.isLinux;

/// Overrides [canShareImageFiles] (tests run on Linux).
@visibleForTesting
bool? debugCanShareImageFiles;

/// How images are handed to the system's share sheet (tests look at what was shared).
@visibleForTesting
Future<ShareResult> Function(ShareParams params) shareImageFiles = SharePlus.instance.share;

/// The media type of an image file named [fileName], by its extension.
String imageMimeTypeOf(String fileName) => switch (fileName.split('.').last.toLowerCase()) {
  'jpg' || 'jpeg' || 'jpe' || 'jfif' => 'image/jpeg',
  'png' => 'image/png',
  'gif' => 'image/gif',
  'webp' => 'image/webp',
  'bmp' => 'image/bmp',
  'avif' => 'image/avif',
  _ => 'image/*',
};

/// Share the image at [url] as a file (its bytes, not its url), named with the extension of its type.
///
/// [origin] is where the share sheet points from on a tablet. Tells the user when the image could not be shared;
/// returns whether the share sheet was shown.
Future<bool> shareImageOf(BuildContext context, String url, {Rect? origin}) async {
  final tr = context.t.imageBottomSheet;
  final data = await imageBytesOf(url);
  if (data == null) {
    if (context.mounted) {
      showSnackBar(context: context, message: tr.failedToShareImage);
    }
    return false;
  }
  final fileName = imageFileNameOf(url, data);
  try {
    final file = await _sharedImageFile(fileName, data);
    final result = await shareImageFiles(
      ShareParams(
        files: [XFile(file.path, mimeType: imageMimeTypeOf(fileName), name: fileName)],
        sharePositionOrigin: origin,
      ),
    );
    if (result.status == ShareResultStatus.unavailable && context.mounted) {
      showSnackBar(context: context, message: tr.failedToShareImage);
    }
    return result.status != ShareResultStatus.unavailable;
  } on Exception catch (e, st) {
    talker.handle(e, st, 'failed to share an image');
    if (context.mounted) {
      showSnackBar(context: context, message: tr.failedToShareImage);
    }
    return false;
  }
}

/// The file an image shared is written to: [fileName] in a folder of the temporary directory, of which the images
/// shared before are deleted first (the share sheet is done with them by then).
///
/// Throws when the name would lead out of the folder: [imageFileNameOf] gives a plain name, this checks it again
/// before anything is written.
Future<File> _sharedImageFile(String fileName, Uint8List data) async {
  final folder = Directory(path.join((await getTemporaryDirectory()).path, 'shared_images'));
  if (folder.existsSync()) {
    await folder.delete(recursive: true);
  }
  await folder.create(recursive: true);
  final target = path.normalize(path.join(folder.path, fileName));
  if (!path.isWithin(folder.path, target) || path.dirname(target) != path.normalize(folder.path)) {
    throw FileSystemException('refuse to write a shared image outside its folder', fileName);
  }
  return File(target).writeAsBytes(data, flush: true);
}

/// Open the image at [url] in the browser (never in this app, which takes forum links itself). Only a web url
/// (`http`, `https`) is handed over.
Future<void> openImageInBrowser(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  var opened = false;
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    try {
      opened = await openInExternalBrowser(uri);
    } on PlatformException catch (e, st) {
      talker.handle(e, st, 'failed to open an image in the browser');
    }
  }
  if (!opened && context.mounted) {
    showSnackBar(context: context, message: context.t.imageBottomSheet.failedToOpenInBrowser);
  }
}

/// Where the share sheet of a tap on [context] (a button) points from, on a tablet.
Rect? shareOriginOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) {
    return null;
  }
  return box.localToGlobal(Offset.zero) & box.size;
}
