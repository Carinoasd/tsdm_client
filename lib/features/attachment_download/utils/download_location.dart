import 'dart:io';
import 'dart:ui' show Rect;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/method_channel.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:url_launcher/url_launcher.dart';

/// The name of the folder of the downloads in the app's own directory (Android, iOS).
const attachmentFolderName = 'attachments';

/// Whether the folder of the downloads can be chosen here: Windows and Linux. On macOS the app may only write the
/// folders the user picked in this run (no bookmark of it is kept), on Android and iOS the downloads stay in the app's
/// own directory and are saved elsewhere one by one ([saveDownloadedFileAs]).
bool get canChooseDownloadDirectory => !kIsWeb && (Platform.isWindows || Platform.isLinux);

/// Where the attachments are downloaded to:
///
/// * Android: the app's directory on the shared storage (`Android/data/<package>/files/attachments`, no permission
///   needed), the app's own files when there is none.
/// * iOS: the app's documents (`attachments`).
/// * macOS: the downloads folder of the app's container.
/// * Windows, Linux: the folder chosen in the settings (`SettingsKeys.attachmentDownloadDirectory`) when it exists,
///   otherwise the user's downloads folder. [chosen] stands for the setting.
Future<Directory> attachmentDownloadDirectory({String? chosen}) async {
  if (Platform.isAndroid) {
    final base = await getExternalStorageDirectory() ?? await getApplicationSupportDirectory();
    return Directory(p.join(base.path, attachmentFolderName));
  }
  if (Platform.isIOS) {
    return Directory(p.join((await getApplicationDocumentsDirectory()).path, attachmentFolderName));
  }
  if (canChooseDownloadDirectory) {
    final folder =
        chosen ??
        (getIt.isRegistered<SettingsRepository>()
            ? getIt.get<SettingsRepository>().currentSettings.attachmentDownloadDirectory
            : '');
    if (folder.isNotEmpty && Directory(folder).existsSync()) {
      return Directory(folder);
    }
  }
  return await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
}

/// Where the part files of the downloads are written: the app's temporary folder, apart from the downloads folder.
Future<Directory> attachmentPartDirectory() async =>
    Directory(p.join((await getTemporaryDirectory()).path, 'attachment_parts'));

/// The file called [name] in [dir], or `name (1).ext`, `name (2).ext`… when one of that name is there already or its
/// path is [taken].
File uniqueFileIn(Directory dir, String name, {Set<String> taken = const {}}) {
  bool free(File f) => !taken.contains(f.path) && !f.existsSync();
  var file = File(p.join(dir.path, name));
  if (free(file)) {
    return file;
  }
  final ext = p.extension(name);
  final stem = name.substring(0, name.length - ext.length);
  for (var i = 1; i < 10000; i++) {
    file = File(p.join(dir.path, '$stem ($i)$ext'));
    if (free(file)) {
      return file;
    }
  }
  return File(p.join(dir.path, '$stem (${DateTime.now().millisecondsSinceEpoch})$ext'));
}

/// The size of [bytes] to show: `153 B`, `36.7 KB`, `1.2 MB`.
String formatDownloadSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

/// Whether a downloaded file can be shared as a file here: the share sheet of Linux only takes text.
bool get canShareDownloadedFile => !kIsWeb && !Platform.isLinux;

/// Hand the downloaded file at [path] to the system: the app that opens its type (Android asks which one; when no app
/// takes it, or on iOS, the share sheet is shown instead), the default app of the desktop. [origin] is where the share
/// sheet points from on a tablet. Returns whether something was opened.
Future<bool> openDownloadedFile(String path, {Rect? origin}) async {
  if (!File(path).existsSync()) {
    return false;
  }
  if (isAndroid) {
    try {
      if (await androidOpenFile(path)) {
        return true;
      }
    } on Object catch (e) {
      talker.warning('failed to open downloaded attachment: $e');
    }
    return shareDownloadedFile(path, origin: origin);
  }
  if (isIOS) {
    return shareDownloadedFile(path, origin: origin);
  }
  return launchUrl(Uri.file(path));
}

/// Show the folder holding the downloaded file at [path] (desktop).
Future<bool> showDownloadedFileFolder(String path) async => launchUrl(Uri.directory(p.dirname(path)));

/// Share the downloaded file at [path] through the system's share sheet; [origin] is where it points from on a
/// tablet. Returns whether the sheet was shown.
Future<bool> shareDownloadedFile(String path, {Rect? origin}) async {
  final result = await SharePlus.instance.share(
    ShareParams(files: [XFile(path)], sharePositionOrigin: origin),
  );
  return result.status != ShareResultStatus.unavailable;
}

/// Save a copy of the downloaded file at [path] where the user picks (the downloads folder, a cloud drive) as [name].
/// Returns where it went, null when the user picked nothing.
Future<String?> saveDownloadedFileAs(String path, String name) async {
  final file = File(path);
  if (isDesktop) {
    final target = await FilePicker.platform.saveFile(fileName: name);
    if (target == null) {
      return null;
    }
    await file.copy(target);
    return target;
  }
  // Android and iOS write the bytes themselves (the storage access framework, the files app).
  return FilePicker.platform.saveFile(fileName: name, bytes: await file.readAsBytes());
}
