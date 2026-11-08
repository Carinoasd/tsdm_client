/// Custom emoji packs: the images saved in a pack (scaled down to a side of 512 at most, a GIF kept as it is), the
/// packs kept on the device ([CustomEmojiStore]) and their export to a zip and import from one, to move them to
/// another device.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/custom_emoji/models/custom_emoji.dart';
import 'package:tsdm_client/features/custom_emoji/repository/custom_emoji_store.dart';
import 'package:tsdm_client/features/custom_emoji/utils/custom_emoji_archive.dart';
import 'package:tsdm_client/features/custom_emoji/utils/custom_emoji_image.dart';
import 'package:tsdm_client/instance.dart';

Uint8List _png(int w, int h, {int r = 200}) {
  final image = img.Image(width: w, height: h)..clear(img.ColorRgb8(r, 40, 40));
  return img.encodePng(image);
}

Uint8List _gif(int w, int h) {
  final image = img.Image(width: w, height: h)..clear(img.ColorRgb8(10, 120, 200));
  return img.encodeGif(image);
}

Uint8List _jpg(int w, int h) {
  final image = img.Image(width: w, height: h)..clear(img.ColorRgb8(40, 200, 40));
  return img.encodeJpg(image);
}

CustomEmojiStore _store(Directory dir) => CustomEmojiStore(
  directory: () async => dir,
  prepare: (bytes) async => prepareCustomEmoji(bytes),
);

Future<Uint8List?> Function() _bytes(Uint8List data) =>
    () async => data;

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('custom_emoji_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('A. the saved image', () {
    test('a small PNG or JPEG is kept byte for byte', () {
      final png = _png(64, 32);
      final prepared = prepareCustomEmoji(png)!;
      expect(prepared.ext, 'png');
      expect(prepared.bytes, png);
      expect(prepared.sha256, sha256Hex(png));
      expect(prepareCustomEmoji(_jpg(100, 100))!.ext, 'jpg');
    });

    test('a larger one is scaled down to a longest side of 512, in its format', () {
      final wide = prepareCustomEmoji(_png(1024, 256))!;
      final decoded = img.decodePng(wide.bytes)!;
      expect((decoded.width, decoded.height), (512, 128));
      final tall = prepareCustomEmoji(_jpg(300, 900))!;
      expect(tall.ext, 'jpg');
      final t = img.decodeJpg(tall.bytes)!;
      expect((t.width, t.height), (171, 512));
      expect(tall.sha256, sha256Hex(tall.bytes));
    });

    test('a GIF is kept as it is, however large', () {
      final gif = _gif(800, 600);
      final prepared = prepareCustomEmoji(gif)!;
      expect(prepared.ext, 'gif');
      expect(prepared.bytes, gif);
    });

    test('another format the forum does not take becomes a PNG', () {
      final bmp = img.encodeBmp(img.Image(width: 20, height: 10));
      final prepared = prepareCustomEmoji(bmp)!;
      expect(prepared.ext, 'png');
      expect(customEmojiFormatOf(prepared.bytes), 'png');
    });

    test('an image whose header declares too many pixels is never decoded', () {
      // A real 1×1 PNG whose header (with its checksum) says 30000×30000.
      final png = _png(1, 1);
      final data = ByteData.sublistView(png)
        ..setUint32(16, 30000)
        ..setUint32(20, 30000)
        ..setUint32(29, getCrc32(png.sublist(12, 29)));
      expect(data.getUint32(16), 30000);
      expect(img.findDecoderForData(png)!.startDecode(png)!.width, 30000, reason: 'the header is read as declared');
      expect(prepareCustomEmoji(png), isNull);
    });

    test('an animated image: its first frame only', () {
      final frames = img.Image(width: 20, height: 10)..clear(img.ColorRgb8(1, 2, 3));
      for (var i = 0; i < 3; i++) {
        frames.addFrame(img.Image(width: 20, height: 10)..clear(img.ColorRgb8(i * 50, 0, 0)));
      }
      final apng = img.encodePng(frames);
      expect(img.decodePng(apng)!.numFrames, greaterThan(1), reason: 'an animated PNG');
      final prepared = prepareCustomEmoji(apng)!;
      expect(prepared.bytes, apng, reason: 'small enough: kept');
      final large = img.Image(width: 1024, height: 64);
      for (var i = 0; i < 3; i++) {
        large.addFrame(img.Image(width: 1024, height: 64));
      }
      final scaled = img.decodePng(prepareCustomEmoji(img.encodePng(large))!.bytes)!;
      expect((scaled.width, scaled.numFrames), (512, 1));
    });

    test('no image: null', () {
      expect(prepareCustomEmoji(Uint8List.fromList(utf8.encode('not an image'))), isNull);
      expect(prepareCustomEmoji(Uint8List(0)), isNull);
    });
  });

  group('B. the store', () {
    test('packs, their images and their order are kept on the device', () async {
      final store = _store(dir);
      final a = await store.createPack(' 貓 ');
      final b = await store.createPack('狗');
      expect(a.name, '貓');
      final red = _png(10, 10);
      final blue = _png(10, 10, r: 20);
      expect(await store.addImages(a.id, [_bytes(red), _bytes(blue), _bytes(red), () async => null]), 2);
      expect(
        await store.addImages(a.id, [
          _bytes(Uint8List.fromList([1, 2, 3])),
        ]),
        0,
        reason: 'no image',
      );
      await store.moveEmoji(a.id, 1, 0);
      await store.movePack(1, 0);
      await store.renamePack(b.id, '狗狗');
      await store.pendingWrites;

      final again = _store(dir);
      await again.load();
      final packs = again.packs.value;
      expect(packs.map((e) => e.name), ['狗狗', '貓']);
      expect(packs[1].emojis.map((e) => e.sha256), [sha256Hex(blue), sha256Hex(red)]);
      expect(again.fileOf(packs[1].emojis.first)!.readAsBytesSync(), blue);
    });

    test('an image is deleted with the last pack that has it', () async {
      final store = _store(dir);
      final a = await store.createPack('a');
      final b = await store.createPack('b');
      final red = _png(10, 10);
      await store.addImages(a.id, [_bytes(red)]);
      await store.addImages(b.id, [_bytes(red)]);
      final emoji = store.packs.value.first.emojis.single;
      final file = store.fileOf(emoji)!;
      await store.deletePack(a.id);
      await store.pendingWrites;
      expect(file.existsSync(), isTrue, reason: 'b still has it');
      await store.removeEmoji(b.id, emoji);
      await store.pendingWrites;
      expect(file.existsSync(), isFalse);
      expect(store.packs.value.single.emojis, isEmpty);
    });

    test('a file it cannot read is set aside, never overwritten', () async {
      File('${dir.path}/packs.json').writeAsStringSync('{oops');
      File('${dir.path}/uploads.json').writeAsStringSync(jsonEncode({'v': 99, 'accounts': <String, Object>{}}));
      final store = _store(dir);
      await store.load();
      expect(store.packs.value, isEmpty);
      await store.createPack('new');
      store.rememberUpload(35, 'a' * 64, 1);
      await store.pendingWrites;
      final names = dir.listSync().map((e) => e.uri.pathSegments.last).toList();
      final bad = names.where((e) => e.startsWith('packs.json.bad-')).single;
      expect(File('${dir.path}/$bad').readAsStringSync(), '{oops');
      expect(names.where((e) => e.startsWith('uploads.json.bad-')), hasLength(1), reason: 'a later version');
    });
  });

  group('C. export and import', () {
    test('a zip of the packs comes back the same on another device, merged by name', () async {
      final store = _store(dir);
      final a = await store.createPack('貓');
      final b = await store.createPack('動圖');
      final red = _png(10, 10);
      final gif = _gif(30, 30);
      await store.addImages(a.id, [_bytes(red), _bytes(_jpg(8, 8))]);
      await store.addImages(b.id, [_bytes(gif), _bytes(red)]);
      final zip = await store.exportArchive();

      final archive = ZipDecoder().decodeBytes(zip);
      // Every image once, whatever packs have it.
      expect(archive.files.where((e) => e.name.startsWith('images/')).length, 3);

      final other = Directory('${dir.path}/other')..createSync();
      final target = _store(other);
      final existing = await target.createPack('貓');
      await target.addImages(existing.id, [_bytes(red)]);
      expect(await target.importArchive(zip), 3, reason: 'the red one is in 貓 already');
      final packs = target.packs.value;
      expect(packs.map((e) => e.name), ['貓', '動圖']);
      expect(packs[0].emojis.length, 2);
      expect(packs[1].emojis.map((e) => e.ext), ['gif', 'png']);
      expect(target.fileOf(packs[1].emojis.first)!.readAsBytesSync(), gif);

      // Imported twice: nothing new.
      expect(await target.importArchive(zip), 0);
      await store.pendingWrites;
      await target.pendingWrites;
    });

    test('the packs of one pack only', () async {
      final store = _store(dir);
      final a = await store.createPack('a');
      final b = await store.createPack('b');
      await store.addImages(a.id, [_bytes(_png(4, 4))]);
      await store.addImages(b.id, [_bytes(_png(5, 5))]);
      final packs = decodeCustomEmojiArchive(await store.exportArchive({b.id}))!;
      expect(packs.single.name, 'b');
      await store.pendingWrites;
    });

    test('nothing of an archive is trusted', () {
      final good = _png(6, 6);
      final goodName = '${sha256Hex(good)}.png';
      final gif = _gif(6, 6);
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('images/$goodName', good))
        // A name that is not the hash of its bytes.
        ..addFile(ArchiveFile.bytes('images/${'0' * 64}.png', good))
        // Bytes of another format than the name says.
        ..addFile(ArchiveFile.bytes('images/${sha256Hex(gif)}.png', gif))
        // Out of images/, a path escaping the folder, a script.
        ..addFile(ArchiveFile.bytes(goodName, good))
        ..addFile(ArchiveFile.bytes('images/../../evil.png', good))
        ..addFile(ArchiveFile.bytes('images/run.sh', utf8.encode('rm -rf /')))
        ..addFile(
          ArchiveFile.bytes(
            'manifest.json',
            utf8.encode(
              jsonEncode({
                'format': customEmojiArchiveFormat,
                'v': 1,
                'packs': [
                  {
                    'name': 'x',
                    'emojis': [
                      goodName,
                      '${'0' * 64}.png',
                      '${sha256Hex(gif)}.png',
                      '../../evil.png',
                      'run.sh',
                      goodName,
                      '${'1' * 64}.png',
                    ],
                  },
                  {'name': 1, 'emojis': <String>[]},
                  'junk',
                ],
              }),
            ),
          ),
        );
      final packs = decodeCustomEmojiArchive(ZipEncoder().encodeBytes(archive))!;
      expect(packs.length, 1);
      expect(packs.single.emojis.map((e) => e.$1.fileName), [goodName]);
      expect(packs.single.emojis.single.$2, good);
    });

    test('an image of an archive is saved as one added by hand: scaled down', () async {
      final big = _png(1024, 512);
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('images/${sha256Hex(big)}.png', big))
        ..addFile(
          ArchiveFile.bytes(
            'manifest.json',
            utf8.encode(
              jsonEncode({
                'format': customEmojiArchiveFormat,
                'v': 1,
                'packs': [
                  {
                    'name': 'big',
                    'emojis': ['${sha256Hex(big)}.png'],
                  },
                ],
              }),
            ),
          ),
        );
      final store = _store(dir);
      expect(await store.importArchive(ZipEncoder().encodeBytes(archive)), 1);
      final emoji = store.packs.value.single.emojis.single;
      final saved = img.decodePng(store.fileOf(emoji)!.readAsBytesSync())!;
      expect((saved.width, saved.height), (512, 256));
      await store.pendingWrites;
    });

    test('an entry decompressing past the limit is not read', () {
      final huge = Uint8List(customEmojiArchiveMaxImageBytes + 1)
        ..setAll(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      final name = '${sha256Hex(huge)}.png';
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('images/$name', huge))
        ..addFile(
          ArchiveFile.bytes(
            'manifest.json',
            utf8.encode(
              jsonEncode({
                'format': customEmojiArchiveFormat,
                'v': 1,
                'packs': [
                  {
                    'name': 'x',
                    'emojis': [name],
                  },
                ],
              }),
            ),
          ),
        );
      final zip = ZipEncoder().encodeBytes(archive);
      expect(zip.length, lessThan(1024 * 1024), reason: 'zeros compress well');
      expect(decodeCustomEmojiArchive(zip)!.single.emojis, isEmpty);
    });

    test('an entry whose header lies about its size is cut at the limit while decompressing', () {
      final huge = Uint8List(customEmojiArchiveMaxImageBytes + 1)
        ..setAll(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      final name = '${sha256Hex(huge)}.png';
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('images/$name', huge))
        ..addFile(
          ArchiveFile.bytes(
            'manifest.json',
            utf8.encode(
              jsonEncode({
                'format': customEmojiArchiveFormat,
                'v': 1,
                'packs': [
                  {
                    'name': 'x',
                    'emojis': [name],
                  },
                ],
              }),
            ),
          ),
        );
      final zip = ZipEncoder().encodeBytes(archive);
      // Every header of the image (local 0x04034b50, central 0x02014b50) now declares 100 bytes.
      final view = ByteData.sublistView(zip);
      var patched = 0;
      for (var i = 0; i + 30 < zip.length; i++) {
        final sig = view.getUint32(i, Endian.little);
        final declared = sig == 0x04034b50 ? i + 22 : (sig == 0x02014b50 ? i + 24 : -1);
        if (declared >= 0 && view.getUint32(declared, Endian.little) == huge.length) {
          view.setUint32(declared, 100, Endian.little);
          patched++;
        }
      }
      expect(patched, 2);
      expect(ZipDecoder().decodeBytes(zip).files.firstWhere((e) => e.name == 'images/$name').size, 100);
      // The premise: the archive decompresses past the size it declares, only the limit stops it.
      final plain = OutputMemoryStream();
      ZipDecoder().decodeBytes(zip).files.firstWhere((e) => e.name == 'images/$name').writeContent(plain);
      expect(plain.length, huge.length);
      expect(decodeCustomEmojiArchive(zip)!.single.emojis, isEmpty);
    });

    test('no archive of packs: null', () {
      expect(decodeCustomEmojiArchive(Uint8List.fromList(utf8.encode('not a zip'))), isNull);
      final noManifest = Archive()..addFile(ArchiveFile.bytes('a.txt', utf8.encode('x')));
      expect(decodeCustomEmojiArchive(ZipEncoder().encodeBytes(noManifest)), isNull);
      final otherFormat = Archive()
        ..addFile(
          ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode({'format': 'x', 'v': 1, 'packs': <Object>[]}))),
        );
      expect(decodeCustomEmojiArchive(ZipEncoder().encodeBytes(otherFormat)), isNull);
      final newer = Archive()
        ..addFile(
          ArchiveFile.bytes(
            'manifest.json',
            utf8.encode(jsonEncode({'format': customEmojiArchiveFormat, 'v': 99, 'packs': <Object>[]})),
          ),
        );
      expect(decodeCustomEmojiArchive(ZipEncoder().encodeBytes(newer)), isNull);
    });

    test('the import of a file that is no archive adds nothing', () async {
      final store = _store(dir);
      expect(await store.importArchive(Uint8List.fromList([1, 2, 3])), isNull);
      expect(store.packs.value, isEmpty);
    });
  });

  test('the model drops what is not an image of a pack', () {
    final pack = CustomEmojiPack.fromJson({
      'id': 'p',
      'name': 'n',
      'emojis': [
        {'sha256': 'a' * 64, 'ext': 'png'},
        {'sha256': 'a' * 64, 'ext': 'png'},
        {'sha256': 'A' * 64, 'ext': 'png'},
        {'sha256': 'b' * 64, 'ext': 'webp'},
        {'sha256': '../x', 'ext': 'png'},
      ],
    })!;
    expect(pack.emojis, [CustomEmoji(sha256: 'a' * 64, ext: 'png')]);
    expect(CustomEmojiPack.fromJson({'id': '', 'name': 'n'}), isNull);
  });
}
