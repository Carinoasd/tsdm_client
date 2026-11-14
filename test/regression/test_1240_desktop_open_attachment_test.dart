/// "Open" of a downloaded attachment on the desktop hands the file to the shell (ShellExecute, `open`, `xdg-open`),
/// which runs a program, a script or a shortcut. The attachments are uploaded by anyone on the forum: those types are
/// shown in the file manager instead ([runsAsProgram], [openDownloadedFile], [revealDownloadedFile]). The phones keep
/// their way (the chooser of Android, the share sheet of iOS).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/attachment_download/utils/download_location.dart';
import 'package:tsdm_client/instance.dart';

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('the types that run', () {
    test('programs, scripts, shortcuts and installers of the three systems', () {
      for (final name in [
        // Windows.
        'a.exe', 'a.msi', 'a.bat', 'a.cmd', 'a.com', 'a.scr', 'a.pif', 'a.ps1', 'a.vbs', 'a.js', 'a.jse', 'a.wsf',
        'a.hta', 'a.lnk', 'a.url', 'a.reg', 'a.jar', 'a.cpl', 'a.msc', 'a.appref-ms', 'a.application', 'a.gadget',
        // macOS.
        'a.app', 'a.command', 'a.pkg', 'a.dmg', 'a.scpt', 'a.terminal',
        // Linux.
        'a.desktop', 'a.sh', 'a.run', 'a.AppImage',
      ]) {
        expect(runsAsProgram(name), isTrue, reason: name);
      }
    });

    test('whatever the case, the trailing dots and spaces Windows drops, the last of several extensions', () {
      for (final name in [
        'SETUP.EXE',
        'Setup.Exe',
        'a.appimage',
        'a.exe.',
        'a.exe ',
        'a.exe. . ',
        'a.exe\u3000',
        'photo.jpg.exe',
        'notes.txt.lnk',
        '.exe',
        r'C:\Users\x\Downloads\a.exe',
        '/srv/dl/a.sh',
      ]) {
        expect(runsAsProgram(name), isTrue, reason: name);
      }
    });

    test('documents, pictures, music, archives', () {
      for (final name in [
        'a.zip',
        'a.7z',
        'a.rar',
        'a.pdf',
        'a.jpg',
        'a.mp3',
        'a.txt',
        'a.docx',
        'a.torrent',
        'exe',
        'a',
        'a.exe.zip',
        'a.sh.txt',
        '',
      ]) {
        expect(runsAsProgram(name), isFalse, reason: name);
      }
    });
  });

  group('open on the desktop', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('tsdm_1240_open'));
    tearDown(() => dir.deleteSync(recursive: true));

    File fileOf(String name) => File(p.join(dir.path, name))..writeAsStringSync('1');

    test('a program is shown in the file manager, never handed to the shell', () async {
      final launched = <Uri>[];
      final revealed = <String>[];
      for (final name in ['setup.exe', 'run.BAT', 'x.lnk', 'x.desktop', 'x.sh', 'x.command', 'photo.jpg.exe']) {
        final file = fileOf(name);
        final opened = await openDownloadedFile(
          file.path,
          launch: (uri) async {
            launched.add(uri);
            return true;
          },
          reveal: (path) async {
            revealed.add(path);
            return true;
          },
        );
        expect(opened, isTrue, reason: name);
      }
      expect(launched, isEmpty);
      expect(revealed.map(p.basename), [
        'setup.exe',
        'run.BAT',
        'x.lnk',
        'x.desktop',
        'x.sh',
        'x.command',
        'photo.jpg.exe',
      ]);
    });

    test('anything else opens in its app as before', () async {
      final launched = <Uri>[];
      final revealed = <String>[];
      for (final name in ['a.zip', 'a.pdf', 'a.jpg', 'a.mp3']) {
        final file = fileOf(name);
        final opened = await openDownloadedFile(
          file.path,
          launch: (uri) async {
            launched.add(uri);
            return true;
          },
          reveal: (path) async {
            revealed.add(path);
            return true;
          },
        );
        expect(opened, isTrue, reason: name);
      }
      expect(revealed, isEmpty);
      expect(launched.map((e) => p.basename(e.toFilePath())), ['a.zip', 'a.pdf', 'a.jpg', 'a.mp3']);
    });

    test('a file that is gone opens nothing', () async {
      var asked = false;
      final opened = await openDownloadedFile(
        p.join(dir.path, 'gone.exe'),
        launch: (_) async => asked = true,
        reveal: (_) async => asked = true,
      );
      expect(opened, isFalse);
      expect(asked, isFalse);
    });
  });

  group('show in the file manager', () {
    late List<(String, List<String>)> runs;
    late List<Uri> launched;

    setUp(() {
      runs = [];
      launched = [];
    });

    Future<bool> reveal(String path, DesktopSystem system, {int exitCode = 0, bool missing = false}) =>
        revealDownloadedFile(
          path,
          system: system,
          run: (exe, args) async {
            runs.add((exe, args));
            if (missing) {
              throw ProcessException(exe, args, 'not found');
            }
            return exitCode;
          },
          launch: (uri) async {
            launched.add(uri);
            return true;
          },
        );

    test('Windows: Explorer with the file selected (its exit code tells nothing)', () async {
      const path = r'C:\Users\x\Downloads\a b.exe';
      expect(await reveal(path, DesktopSystem.windows, exitCode: 1), isTrue);
      expect(runs.single.$1, 'explorer.exe');
      expect(runs.single.$2, ['/select,', path]);
      expect(launched, isEmpty);
    });

    test('macOS: Finder with the file selected', () async {
      expect(await reveal('/Users/x/Downloads/a.command', DesktopSystem.macos), isTrue);
      expect(runs.single.$1, 'open');
      expect(runs.single.$2, ['-R', '/Users/x/Downloads/a.command']);
      expect(launched, isEmpty);
    });

    test('Linux: the file manager of the desktop asked to select it, a comma not splitting the name', () async {
      expect(await reveal('/srv/dl/a, b 名.sh', DesktopSystem.linux), isTrue);
      final (exe, args) = runs.single;
      expect(exe, 'dbus-send');
      expect(args, contains('org.freedesktop.FileManager1.ShowItems'));
      final items = args.singleWhere((e) => e.startsWith('array:string:'));
      expect(items.contains(','), isFalse);
      expect(Uri.parse(items.substring('array:string:'.length)).toFilePath(), '/srv/dl/a, b 名.sh');
      expect(launched, isEmpty);
    });

    test('without a way to select it: its folder is opened, never the file itself', () async {
      expect(await reveal('/srv/dl/a.sh', DesktopSystem.linux, exitCode: 1), isTrue);
      expect(await reveal('/Users/x/Downloads/a.app', DesktopSystem.macos, missing: true), isTrue);
      expect(await reveal(r'C:\x\a.exe', DesktopSystem.windows, missing: true), isTrue);
      expect(launched, [
        Uri.directory('/srv/dl', windows: false),
        Uri.directory('/Users/x/Downloads', windows: false),
        Uri.directory(r'C:\x', windows: true),
      ]);
      for (final uri in launched) {
        expect(uri.path.endsWith('/'), isTrue, reason: '$uri');
      }
    });
  });
}
