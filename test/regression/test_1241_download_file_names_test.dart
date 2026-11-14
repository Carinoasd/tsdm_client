/// The name a download is saved and shown as comes from the forum (`Content-Disposition`, the text of the post): the
/// marks of the text direction turn `photo<U+202E>gpj.exe` into what reads `photoexe.jpg`, the names Windows keeps
/// (`CON`, `NUL`, `COM1`…) open a device, a `..` or a separator would write out of the downloads folder. All of that is
/// taken out ([safeDownloadFileName], [displayDownloadName]), and the downloads keep to their folder.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/attachment_download/models/attachment_download.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_manager.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_store.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_fetcher.dart';
import 'package:tsdm_client/features/attachment_download/utils/attachment_protocol.dart';
import 'package:tsdm_client/instance.dart';

const _base = 'https://forum.test';

String _urlOf(int aid) =>
    '$_base/forum.php?mod=attachment&aid=${base64.encode(utf8.encode('$aid|f1f2f3f4|1700000000|31|1000'))}';

/// The forum: each address answers a file with the `Content-Disposition` given.
final class _FakeFetcher extends ChangeNotifier implements AttachmentFetcher {
  _FakeFetcher(this.dispositions);

  final Map<String, String> dispositions;

  @override
  Future<AttachmentFetchAnswer> fetch(
    String url,
    String savePath, {
    required int uid,
    required CancelToken cancelToken,
    void Function(int received, int? total)? onProgress,
  }) async {
    final disposition = dispositions[url];
    if (disposition == null) {
      throw const AttachmentFetchException('no route');
    }
    await File(savePath).writeAsString('bytes');
    onProgress?.call(5, 5);
    return (status: 200, location: null, disposition: disposition, length: 5);
  }

  @override
  Future<String> fetchPage(String url, {required int uid}) async => throw const AttachmentFetchException('no page');
}

Future<void> _until(AttachmentDownloadManager manager, bool Function() done) async {
  if (done()) {
    return;
  }
  final completer = Completer<void>();
  void listen() {
    if (done() && !completer.isCompleted) {
      completer.complete();
    }
  }

  manager.addListener(listen);
  try {
    await completer.future.timeout(const Duration(seconds: 10));
  } finally {
    manager.removeListener(listen);
  }
}

/// Every mark of the text direction the names may not hold.
const _bidi = [
  '\u202a',
  '\u202b',
  '\u202c',
  '\u202d',
  '\u202e',
  '\u2066',
  '\u2067',
  '\u2068',
  '\u2069',
  '\u200e',
  '\u200f',
  '\u061c',
];

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('the name a file is saved as', () {
    String safe(String name) => safeDownloadFileName(name, fallback: 'fallback');

    test('the marks of the text direction are taken out: the extension reads as it is', () {
      expect(safe('photo\u202egpj.exe'), 'photogpj.exe');
      for (final mark in _bidi) {
        expect(safe('a${mark}b.zip'), 'ab.zip', reason: 'U+${mark.codeUnitAt(0).toRadixString(16)}');
      }
      expect(safe('\u202e\u2066\u200f'), 'fallback');
    });

    test('the characters of no width or blank are taken out, the joiners of emoji kept', () {
      for (final c in [
        '\u00ad',
        '\u200b',
        '\u2060',
        '\u2064',
        '\u206a',
        '\u206f',
        '\u2800',
        '\u3164',
        '\ufeff',
      ]) {
        expect(safe('a${c}b.zip'), 'ab.zip', reason: 'U+${c.codeUnitAt(0).toRadixString(16)}');
      }
      const family = '\u{1F468}\u200d\u{1F469}\u200d\u{1F467}';
      expect(safe('$family.png'), '$family.png');
      expect(safe('a\u200cb.zip'), 'a\u200cb.zip');
    });

    test('the controls (C0, C1, delete) are taken out', () {
      expect(safe('a\u0000b\u0007c\u001fd.zip'), 'abcd.zip');
      expect(safe('a\u0080b\u0085c\u009fd\u007f.zip'), 'abcd.zip');
      // A line break is no space in a name either.
      expect(safe('a\nb\r\tc.zip'), 'abc.zip');
    });

    test('the names Windows keeps for its devices are not used as they are', () {
      for (final name in [
        'CON',
        'con.txt',
        'Nul.tar.gz',
        'PRN.zip',
        'aux',
        'COM1.exe',
        'com9',
        'LPT1.txt',
        'lpt9.log',
        r'CONIN$',
        r'conout$.txt',
        'CON .txt',
      ]) {
        final saved = safe(name);
        final stem = saved.split('.').first.trim().toUpperCase();
        expect(
          RegExp(r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9]|CONIN\$|CONOUT\$)$').hasMatch(stem),
          isFalse,
          reason: '$name -> $saved',
        );
        expect(saved.toUpperCase().contains(name.split('.').first.trim().toUpperCase()), isTrue, reason: saved);
      }
      // Only the name itself: these are free.
      for (final name in ['console.txt', 'nullable.zip', 'COM10.txt', 'a.con', 'auxiliary']) {
        expect(safe(name), name);
      }
    });

    test('no separator, no trailing dot or space, no way up', () {
      expect(safe(r'..\..\evil.exe'), '_.._evil.exe');
      expect(safe('../../etc/passwd'), '_.._etc_passwd');
      expect(safe('/etc/passwd'), '_etc_passwd');
      expect(safe(r'C:\Windows\x.exe'), 'C__Windows_x.exe');
      expect(safe('a.exe. . '), 'a.exe');
      expect(safe('..'), 'fallback');
      expect(safe('.'), 'fallback');
      for (final name in ['../x', r'..\x', '/x', 'a/../../b', '\u202e../x']) {
        final saved = safe(name);
        expect(saved.contains('/'), isFalse, reason: saved);
        expect(saved.contains(r'\'), isFalse, reason: saved);
        expect(p.split(saved), [saved], reason: saved);
      }
    });

    test('cut short without breaking a character, nor ending in a dot or space', () {
      // 179 units of text, then a character of two units across the cut.
      final cut = safe('${'a' * 179}\u{1F600}${'b' * 50}');
      expect(cut.length, lessThanOrEqualTo(180));
      expect(cut.runes.every((r) => r < 0xd800 || r > 0xdfff), isTrue);
      final dotted = safe('${'a' * 178}. ${'b' * 50}');
      expect(dotted.endsWith('.') || dotted.endsWith(' '), isFalse, reason: dotted);
    });
  });

  test('the name shown is the one without the marks of the text direction', () {
    expect(displayDownloadName('photo\u202egpj.exe'), 'photogpj.exe');
    expect(displayDownloadName('a\u0000b\u0085  c.zip'), 'ab c.zip');
    expect(displayDownloadName('平常的 名字.zip'), '平常的 名字.zip');
    // A download kept by an older version (its name as the post had it) is shown the same way.
    final old = AttachmentDownload(
      id: '1',
      uid: 31,
      url: _urlOf(1),
      filename: 'photo\u202egpj.exe',
      createdAt: DateTime(2026),
    );
    expect(old.shownName, 'photogpj.exe');
  });

  group('downloads', () {
    late Directory root;
    late Directory dir;
    late Directory parts;

    setUp(() {
      root = Directory.systemTemp.createTempSync('tsdm_1241');
      dir = Directory(p.join(root.path, 'deep', 'downloads'))..createSync(recursive: true);
      parts = Directory(p.join(root.path, 'parts'))..createSync();
    });

    tearDown(() => root.deleteSync(recursive: true));

    AttachmentDownloadManager managerOf(_FakeFetcher fetcher) => AttachmentDownloadManager(
      fetcher: fetcher,
      store: AttachmentDownloadStore.memory({}),
      directory: () async => dir,
      partDirectory: () async => parts,
      progressInterval: Duration.zero,
    );

    test('a name from the post is kept without the marks while it waits', () async {
      final url = _urlOf(40);
      final manager = managerOf(_FakeFetcher({url: 'attachment; filename="a.zip"'}));
      final item = await manager.start(uid: 31, url: url, filename: 'photo\u202egpj.exe');
      expect(item.filename, 'photogpj.exe');
      await _until(manager, () => !manager.find(31, item.id)!.status.active);
    });

    test('whatever name the forum sends, the file is written in the downloads folder', () async {
      final names = <int, String>{
        41: '../../evil.sh',
        42: '..%2F..%2Fevil2.sh',
        43: '%2e%2e%5cevil3.exe',
        44: '/etc/passwd',
        45: r'C:\Windows\evil4.exe',
        46: '..',
        47: 'photo%E2%80%AEgpj.exe',
        48: 'CON.txt',
      };
      final dispositions = {
        for (final MapEntry(:key, :value) in names.entries) _urlOf(key): 'attachment; filename="$value"',
      };
      // The extended form too.
      dispositions[_urlOf(49)] = "attachment; filename*=utf-8''..%2F..%2F..%2Fevil5.sh";
      final manager = managerOf(_FakeFetcher(dispositions));
      final items = [
        for (final url in dispositions.keys) await manager.start(uid: 31, url: url, filename: 'x.zip'),
      ];
      await _until(manager, () => manager.itemsOf(31).every((e) => !e.status.active));
      for (final item in items) {
        final done = manager.find(31, item.id)!;
        expect(done.status, AttachmentDownloadStatus.completed, reason: done.url);
        expect(p.dirname(done.path!), dir.path, reason: done.path);
        expect(p.basename(done.path!), done.filename);
        expect(done.filename.contains('\u202e'), isFalse);
        expect(done.filename.split('.').first.toUpperCase() == 'CON', isFalse);
      }
      // Nothing beside or above the downloads folder.
      expect(dir.parent.listSync().map((e) => p.basename(e.path)), ['downloads']);
      // The part files' folder goes once empty.
      expect(root.listSync().map((e) => p.basename(e.path)).toSet().difference({'parts'}), {'deep'});
      expect(File('/etc/passwd').readAsStringSync(), isNot('bytes'));
      final saved = dir.listSync().map((e) => p.basename(e.path)).toList();
      expect(saved, hasLength(dispositions.length));
      expect(saved, contains('photogpj.exe'));
    });
  });
}
