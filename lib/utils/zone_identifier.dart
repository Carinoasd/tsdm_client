import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tsdm_client/instance.dart';

/// What goes into the `Zone.Identifier` stream: the file came from the internet (zone 3).
///
/// No `HostUrl`: a download link of the forum can carry the session (a resolved attachment link), which is not left
/// on the disk.
const zoneIdentifierContent = '[ZoneTransfer]\r\nZoneId=3\r\n';

/// The alternate data stream holding the mark of the web of [path].
String zoneIdentifierPathOf(String path) => '$path:Zone.Identifier';

/// Writes [content] to the file at [path].
typedef ZoneIdentifierWriter = Future<void> Function(String path, String content);

Future<void> _write(String path, String content) async {
  await File(path).writeAsString(content, flush: true);
}

/// Mark the file at [path], fetched from the internet and handed to the user, as coming from there (the mark of the
/// web), so Windows warns before it is run or opened. Nothing on other platforms.
///
/// Never throws: a volume without alternate data streams (FAT, some network drives) keeps the file unmarked, which is
/// only logged. [windows] and [writer] are for tests.
Future<void> markDownloadedFromInternet(String path, {bool? windows, ZoneIdentifierWriter? writer}) async {
  if (!(windows ?? Platform.isWindows)) {
    return;
  }
  try {
    await (writer ?? _write)(zoneIdentifierPathOf(path), zoneIdentifierContent);
  } on FileSystemException catch (e) {
    // Only the name and the system's error: the full path (and the exception, which holds it) names the user's folder.
    talker.warning(
      'failed to mark ${p.windows.basename(path)} as downloaded from the internet: ${e.osError ?? e.message}',
    );
  } on Object catch (e) {
    talker.warning('failed to mark ${p.windows.basename(path)} as downloaded from the internet: ${e.runtimeType}');
  }
}
