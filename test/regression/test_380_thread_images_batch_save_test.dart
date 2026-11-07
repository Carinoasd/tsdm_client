import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/image/models/gallery_image.dart';
import 'package:tsdm_client/features/image/utils/batch_image_save.dart';
import 'package:tsdm_client/features/image/utils/post_gallery_images.dart';

class _MemorySink implements ImageSaveSink {
  final saved = <String, Uint8List>{};
  final failOn = <String>{};

  @override
  Future<void> save(String fileName, Uint8List data) async {
    if (failOn.contains(fileName)) {
      throw const FileSystemException('disk full');
    }
    saved[fileName] = data;
  }
}

final _png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);
final _jpg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
final _html = Uint8List.fromList('<html>403</html>'.codeUnits);

List<GalleryImage> _images(List<String> urls) => [for (final e in urls) GalleryImage(e)];

void main() {
  group('collecting the pictures', () {
    test('a floor lists its pictures in order, without smilies, icons and repeats', () {
      const html = '''
<div>
  <img src="https://forum.test/data/attachment/a.png" />
  <img src="https://forum.test/static/image/common/none.gif" />
  <img src="https://forum.test/smiley/x.gif" smilieid="3" />
  <img src="https://forum.test/data/attachment/tiny.png" width="16" height="16" />
  <img src="https://forum.test/data/attachment/b.jpg" />
  <img src="https://forum.test/data/attachment/a.png" />
  <img file="https://forum.test/data/attachment/c.jpg" />
</div>''';
      expect(galleryImagesOfHtml(html).map((e) => e.url).toList(), [
        'https://forum.test/data/attachment/a.png',
        'https://forum.test/data/attachment/b.jpg',
        'https://forum.test/data/attachment/c.jpg',
      ]);
    });

    test('distinct keeps the first of a url', () {
      final images = distinctGalleryImages(_images(['a', 'b', 'a', 'c', 'b']));
      expect(images.map((e) => e.url), ['a', 'b', 'c']);
    });

    test('names that meet get a counter, whatever the case', () {
      final taken = <String>{'a.png', 'a (2).png'};
      expect(uniqueFileName('a.png', taken.contains), 'a (3).png');
      expect(uniqueFileName('b.png', taken.contains), 'b.png');
      expect(uniqueFileName('noext', (e) => e == 'noext'), 'noext (2)');
    });
  });

  group('saving in a batch', () {
    test('the same file name from different urls is numbered', () async {
      final sink = _MemorySink();
      final result = await saveImagesInBatch(
        images: _images(['https://forum.test/x/p.png', 'https://forum.test/y/p.png', 'https://forum.test/x/p.png']),
        fetch: (_) async => _png,
        sink: sink,
      );
      expect(result, const BatchSaveResult(total: 2, saved: 2, failed: 0, cancelled: false));
      expect(sink.saved.keys, unorderedEquals(['p.png', 'p (2).png']));
    });

    test('progress counts every picture done, failed ones too', () async {
      final progress = <(int, int)>[];
      await saveImagesInBatch(
        images: _images(['https://forum.test/a.png', 'https://forum.test/b.png', 'https://forum.test/c.png']),
        fetch: (url) async => url.endsWith('b.png') ? null : _png,
        sink: _MemorySink(),
        onProgress: (done, total) => progress.add((done, total)),
      );
      expect(progress, [(1, 3), (2, 3), (3, 3)]);
    });

    test('failures are skipped and counted: not fetched, not a picture, not written, thrown', () async {
      final sink = _MemorySink()..failOn.add('d.jpg');
      final result = await saveImagesInBatch(
        images: _images([
          'https://forum.test/a.png',
          'https://forum.test/gone.png',
          'https://forum.test/page.png',
          'https://forum.test/d.jpg',
          'https://forum.test/boom.png',
          'https://forum.test/e.jpg',
        ]),
        fetch: (url) async {
          if (url.endsWith('boom.png')) {
            throw const SocketException('timeout');
          }
          return switch (url.split('/').last) {
            'gone.png' => null,
            'page.png' => _html,
            'd.jpg' || 'e.jpg' => _jpg,
            _ => _png,
          };
        },
        sink: sink,
      );
      expect(result, const BatchSaveResult(total: 6, saved: 2, failed: 4, cancelled: false));
      expect(sink.saved.keys, unorderedEquals(['a.png', 'e.jpg']));
    });

    test('cancelling stops before the next picture', () async {
      final cancel = BatchSaveCancel();
      final sink = _MemorySink();
      final result = await saveImagesInBatch(
        images: _images(['https://forum.test/a.png', 'https://forum.test/b.png', 'https://forum.test/c.png']),
        fetch: (_) async => _png,
        sink: sink,
        cancel: cancel,
        onProgress: (done, total) {
          if (done == 1) {
            cancel.cancel();
          }
        },
      );
      expect(result, const BatchSaveResult(total: 3, saved: 1, failed: 0, cancelled: true));
      expect(sink.saved.keys, ['a.png']);
    });
  });

  group('folder sink', () {
    test('does not overwrite a file there already', () async {
      final dir = await Directory.systemTemp.createTemp('batch_save_test');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/p.png').writeAsBytesSync([9]);
      final sink = FolderImageSink(dir.path);
      await sink.save('p.png', _png);
      expect(File('${dir.path}/p.png').readAsBytesSync(), [9]);
      expect(File('${dir.path}/p (2).png').readAsBytesSync(), _png);
      expect(sink.savedPaths, ['${dir.path}/p (2).png']);
    });
  });
}
