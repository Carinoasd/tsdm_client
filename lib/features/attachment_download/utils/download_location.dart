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
  try {
    if (await getDownloadsDirectory() case final downloads?) {
      return downloads;
    }
  } on Object catch (e) {
    // A platform without one (the downloads folder is asked of macOS only through the plugin's channel).
    talker.warning('no downloads folder: $e');
  }
  return getApplicationDocumentsDirectory();
}

/// Where the part files of the downloads are written: on the volume of [attachmentDownloadDirectory] so they are
/// renamed into place, never in a folder that is shared or shown as it is.
///
/// * Android, iOS: `attachment_parts` beside the `attachments` folder (outside of what the file provider serves).
/// * Windows: the app's temporary folder (a leading dot hides nothing in the downloads folder there).
/// * macOS, Linux: `.attachment_parts` in the downloads folder.
Future<Directory> attachmentPartDirectory() async {
  if (Platform.isWindows) {
    return Directory(p.join((await getTemporaryDirectory()).path, 'attachment_parts'));
  }
  final downloads = await attachmentDownloadDirectory();
  if (Platform.isAndroid || Platform.isIOS) {
    return Directory(p.join(downloads.parent.path, 'attachment_parts'));
  }
  return Directory(p.join(downloads.path, '.attachment_parts'));
}

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

/// The extensions of the files the shell of a desktop runs rather than opens: programs, scripts, shortcuts, installers
/// and disk images of Windows, macOS and Linux. Kept together for all three (a program of one system runs on another
/// through Wine, a script opens in a terminal). Lower case, without the dot.
const desktopProgramExtensions = <String>{
  // Windows.
  'exe', 'msi', 'msp', 'msix', 'appx', 'appinstaller', 'bat', 'cmd', 'com', 'scr', 'pif', 'ps1', 'psm1', 'vbs', 'vbe',
  'js', 'jse', 'wsf', 'wsh', 'hta', 'lnk', 'url', 'scf', 'reg', 'inf', 'chm', 'jar', 'cpl', 'msc', 'appref-ms',
  'application', 'gadget', 'settingcontent-ms',
  // macOS.
  'app', 'command', 'pkg', 'mpkg', 'dmg', 'scpt', 'terminal', 'workflow', 'fileloc', 'inetloc', 'webloc',
  // Linux.
  'desktop', 'sh', 'run', 'appimage',
};

/// Whether the file [name] (or path) is one the shell of a desktop runs ([desktopProgramExtensions]): its last
/// extension, whatever its case, the trailing dots and spaces Windows drops ignored.
bool runsAsProgram(String name) {
  final base = name.split(RegExp(r'[/\\]')).last.replaceFirst(RegExp(r'[\s.]+$'), '');
  final dot = base.lastIndexOf('.');
  return dot >= 0 && desktopProgramExtensions.contains(base.substring(dot + 1).toLowerCase());
}

/// Hand the downloaded file at [path] to the system: the app that opens its type (Android asks which one; when no app
/// takes it, or on iOS, the share sheet is shown instead), the default app of the desktop. A file the desktop would run
/// ([runsAsProgram]) is shown in the file manager instead ([revealDownloadedFile]). [origin] is where the share sheet
/// points from on a tablet. Returns whether something was opened.
///
/// [launch] and [reveal] stand for the system in tests.
Future<bool> openDownloadedFile(
  String path, {
  Rect? origin,
  @visibleForTesting Future<bool> Function(Uri uri)? launch,
  @visibleForTesting Future<bool> Function(String path)? reveal,
}) async {
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
  if (runsAsProgram(path)) {
    return (reveal ?? revealDownloadedFile)(path);
  }
  return (launch ?? launchUrl)(Uri.file(path));
}

/// The desktop systems, for [revealDownloadedFile].
enum DesktopSystem {
  /// Windows.
  windows,

  /// macOS.
  macos,

  /// Linux.
  linux,
}

DesktopSystem get _currentDesktopSystem => Platform.isWindows
    ? DesktopSystem.windows
    : Platform.isMacOS
    ? DesktopSystem.macos
    : DesktopSystem.linux;

Future<int> _runProcess(String executable, List<String> arguments) async =>
    (await Process.run(executable, arguments)).exitCode;

/// Show the downloaded file at [path] selected in the file manager (desktop): Explorer, Finder, the file manager of
/// the Linux desktop (`org.freedesktop.FileManager1`). When that cannot be done its folder is opened; the file itself
/// is never handed to the shell. Returns whether something was shown.
///
/// [system], [run] and [launch] stand for the system in tests.
Future<bool> revealDownloadedFile(
  String path, {
  @visibleForTesting DesktopSystem? system,
  @visibleForTesting Future<int> Function(String executable, List<String> arguments)? run,
  @visibleForTesting Future<bool> Function(Uri uri)? launch,
}) async {
  final os = system ?? _currentDesktopSystem;
  final runner = run ?? _runProcess;
  final windows = os == DesktopSystem.windows;
  try {
    switch (os) {
      case DesktopSystem.windows:
        // Explorer answers 1 when it did select the file: its exit code tells nothing.
        await runner('explorer.exe', ['/select,', path]);
        return true;
      case DesktopSystem.macos:
        if (await runner('open', ['-R', path]) == 0) {
          return true;
        }
      case DesktopSystem.linux:
        // `dbus-send` splits an array at its commas.
        final item = Uri.file(path, windows: false).toString().replaceAll(',', '%2C');
        final code = await runner('dbus-send', [
          '--session',
          '--print-reply',
          '--dest=org.freedesktop.FileManager1',
          '--type=method_call',
          '/org/freedesktop/FileManager1',
          'org.freedesktop.FileManager1.ShowItems',
          'array:string:$item',
          'string:',
        ]);
        if (code == 0) {
          return true;
        }
    }
  } on Object catch (e) {
    talker.warning('failed to show the downloaded file in its folder: $e');
  }
  final context = windows ? p.windows : p.posix;
  return (launch ?? launchUrl)(Uri.directory(context.dirname(path), windows: windows));
}

/// Show the downloaded file at [path] in its folder (desktop), selected where the file manager can.
Future<bool> showDownloadedFileFolder(String path) async => revealDownloadedFile(path);

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
