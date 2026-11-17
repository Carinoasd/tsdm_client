import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/zone_identifier.dart';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  const file = r'C:\Users\someone\Downloads\tsdm\setup.exe';

  test('Windows: zone 3 written to the Zone.Identifier stream of the file', () async {
    final writes = <(String, String)>[];
    await markDownloadedFromInternet(file, windows: true, writer: (path, content) async => writes.add((path, content)));
    expect(writes, [(r'C:\Users\someone\Downloads\tsdm\setup.exe:Zone.Identifier', '[ZoneTransfer]\r\nZoneId=3\r\n')]);
  });

  test('no HostUrl, nothing of a link left on the disk', () {
    expect(zoneIdentifierContent, isNot(contains('HostUrl')));
    expect(zoneIdentifierContent, isNot(contains('http')));
  });

  test('other platforms: nothing written', () async {
    var called = false;
    await markDownloadedFromInternet(file, windows: false, writer: (_, _) async => called = true);
    expect(called, isFalse);
  });

  test('a volume without alternate data streams: no throw, the download still counts', () async {
    await expectLater(
      markDownloadedFromInternet(
        file,
        windows: true,
        writer: (path, _) async => throw FileSystemException('The parameter is incorrect.', path),
      ),
      completes,
    );
    await expectLater(
      markDownloadedFromInternet(file, windows: true, writer: (_, _) async => throw StateError('anything')),
      completes,
    );
  });

  test('the default writer failing (no such folder) does not throw', () async {
    final dir = Directory.systemTemp.createTempSync('motw');
    addTearDown(() => dir.deleteSync(recursive: true));
    await expectLater(markDownloadedFromInternet('${dir.path}/missing/a.zip', windows: true), completes);
    expect(File('${dir.path}/missing/a.zip:Zone.Identifier').existsSync(), isFalse);
  });

  test('the default writer writes the stream path with the content', () async {
    // On Linux `a.zip:Zone.Identifier` is a plain file next to it; on Windows the same path opens the stream.
    final dir = Directory.systemTemp.createTempSync('motw');
    addTearDown(() => dir.deleteSync(recursive: true));
    final target = File('${dir.path}/a.zip')..writeAsBytesSync([1, 2, 3]);
    await markDownloadedFromInternet(target.path, windows: true);
    expect(File('${target.path}:Zone.Identifier').readAsStringSync(), '[ZoneTransfer]\r\nZoneId=3\r\n');
    expect(target.readAsBytesSync(), [1, 2, 3]);
  });
}
