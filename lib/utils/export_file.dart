import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Hand [data] to the user as the file [fileName]: the system share sheet with the file ([share]), or saved where the
/// user picks.
///
/// Returns where it was saved; null when it was shared or the user cancelled the save. Errors are thrown.
/// [shareOrigin] is where the share sheet points from on an iPad (global coordinates of the widget tapped).
Future<String?> shareOrSaveFile(
  Uint8List data, {
  required String fileName,
  required String mimeType,
  required bool share,
  required String dialogTitle,
  Rect? shareOrigin,
}) async {
  if (share) {
    final folder = Directory(path.join((await getTemporaryDirectory()).path, 'shared_exports'));
    // Files of earlier shares go once a day old: the app that received one may still be reading it (a content uri
    // read later), whichever export made it (a thread, the diagnostics).
    if (folder.existsSync()) {
      final dayAgo = DateTime.now().subtract(const Duration(days: 1));
      for (final old in folder.listSync(followLinks: false).whereType<File>()) {
        try {
          if (old.statSync().modified.isBefore(dayAgo)) {
            old.deleteSync();
          }
        } on FileSystemException {
          // Gone already, or in use: the next share tries again.
        }
      }
    } else {
      await folder.create(recursive: true);
    }
    final file = await File(path.join(folder.path, fileName)).writeAsBytes(data, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mimeType, name: fileName)],
        sharePositionOrigin: shareOrigin,
      ),
    );
    return null;
  }
  if (isDesktop) {
    // On desktop platforms, `saveFile` only returns the selected path.
    final filePath = await FilePicker.platform.saveFile(dialogTitle: dialogTitle, fileName: fileName);
    if (filePath == null) {
      return null;
    }
    await File(filePath).writeAsBytes(data, flush: true);
    return filePath;
  }
  // Mobile in one step.
  return FilePicker.platform.saveFile(dialogTitle: dialogTitle, fileName: fileName, bytes: data);
}
