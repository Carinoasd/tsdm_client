/// Custom emoji packs: the images saved in a pack (scaled down to a side of 512 at most, a GIF kept as it is), the
/// packs kept on the device ([CustomEmojiStore]) and their export to a zip and import from one, to move them to
/// another device.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:image/image.dart' as img;
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

    test('a broken file reads as no packs', () async {
      File('${dir.path}/packs.json').writeAsStringSync('{oops');
      final store = _store(dir);
      await store.load();
      expect(store.packs.value, isEmpty);
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
