/// An AVIF image is decoded one frame only, and not at all when its declared size is over the limit of pixels
/// ([maxDecodedImagePixels]).
///
/// The image cache turned an AVIF answer into a PNG with `decodeAvif`, which decodes every frame of an animation into
/// memory (and never let them go) to keep the first one: a small file of many large frames took gigabytes. The size
/// is read from the file before decoding (its `ispe` properties, the `tkhd` of an image sequence): the decoder of the
/// package tells no size before it decodes.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_limits.dart';

/// A box of [type] holding [payload].
Uint8List _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  return Uint8List.fromList([
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    ...type.codeUnits,
    ...payload,
  ]);
}

List<int> _u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

/// An `ispe` property of [width] by [height].
Uint8List _ispe(int width, int height) => _box('ispe', [0, 0, 0, 0, ..._u32(width), ..._u32(height)]);

/// A still AVIF: `ftyp`, then `meta` > `iprp` > `ipco` holding the [ispe]s, then the data.
Uint8List _still(List<Uint8List> ispe, {int dataBytes = 64}) => Uint8List.fromList([
  ..._box('ftyp', [...'avif'.codeUnits, 0, 0, 0, 0, ...'avifmif1'.codeUnits]),
  ..._box('meta', [
    0, 0, 0, 0, // version and flags
    ..._box('hdlr', List.filled(24, 0)),
    ..._box('iprp', [
      ..._box('ipco', [for (final p in ispe) ...p]),
    ]),
  ]),
  ..._box('mdat', List.filled(dataBytes, 0)),
]);

/// A `tkhd` of version [version] for a track of [width] by [height] (16.16 fixed point).
Uint8List _tkhd(int width, int height, {int version = 0}) {
  final times = version == 1 ? 8 + 8 + 4 + 4 + 8 : 4 + 4 + 4 + 4 + 4;
  return _box('tkhd', [
    version,
    0,
    0,
    3,
    ...List.filled(times, 0),
    ...List.filled(8 + 2 + 2 + 2 + 2 + 36, 0),
    ..._u32(width << 16),
    ..._u32(height << 16),
  ]);
}

/// An AVIF image sequence: `ftyp`, `moov` > `trak` > [tkhd].
Uint8List _sequence(Uint8List tkhd) => Uint8List.fromList([
  ..._box('ftyp', [...'avis'.codeUnits, 0, 0, 0, 0, ...'avismsf1'.codeUnits]),
  ..._box('moov', [
    ..._box('mvhd', List.filled(100, 0)),
    ..._box('trak', [...tkhd]),
  ]),
  ..._box('mdat', List.filled(16, 0)),
]);

void main() {
  group('the declared size of an AVIF', () {
    test('is its ispe, the largest one when there are several (a grid and its tiles, an alpha plane)', () {
      expect(avifDeclaredSize(_still([_ispe(800, 600)])), (width: 800, height: 600));
      expect(avifDeclaredSize(_still([_ispe(512, 512), _ispe(4096, 3072), _ispe(512, 512)])), (
        width: 4096,
        height: 3072,
      ));
    });

    test('of an image sequence is the size of its track, version 0 or 1', () {
      expect(avifDeclaredSize(_sequence(_tkhd(1920, 1080))), (width: 1920, height: 1080));
      expect(avifDeclaredSize(_sequence(_tkhd(640, 360, version: 1))), (width: 640, height: 360));
    });

    test('is none for a file telling none, a truncated or a broken one', () {
      expect(avifDeclaredSize(Uint8List(0)), isNull);
      expect(avifDeclaredSize(_still([])), isNull);
      final whole = _still([_ispe(800, 600)]);
      expect(avifDeclaredSize(Uint8List.sublistView(whole, 0, 40)), isNull);
      // A box claiming to go on past the end of the file.
      final broken = Uint8List.fromList(whole)..[3] = 0xff;
      expect(() => avifDeclaredSize(broken), returnsNormally);
      // A box of size 0 to 7 (not even its header) ends the walk.
      expect(avifDeclaredSize(Uint8List.fromList([0, 0, 0, 1, ...'meta'.codeUnits, ...List.filled(32, 0)])), isNull);
    });

    test('is read from the boxes, not from bytes of the data looking like one', () {
      final fake = Uint8List.fromList([
        ..._still([_ispe(100, 100)]),
        ..._box('mdat', [..._ispe(60000, 60000)]),
      ]);
      expect(avifDeclaredSize(fake), (width: 100, height: 100));
    });
  });

  group('an AVIF answer', () {
    test('within the limit is decoded one frame, the frame let go', () async {
      final decoded = <int>[];
      final frame = await _image(2, 3);
      final png = await avifToPng(
        _still([_ispe(2, 3)]),
        firstFrame: (bytes) async {
          decoded.add(bytes.length);
          return frame;
        },
      );
      expect(decoded, hasLength(1));
      expect(png, isNotNull);
      expect(png!.sublist(1, 4), 'PNG'.codeUnits);
      expect(frame.debugDisposed, isTrue);
    });

    test('over the limit of pixels, or telling no size, is not decoded', () async {
      var decoded = 0;
      Future<ui.Image> decode(Uint8List _) async {
        decoded++;
        return _image(1, 1);
      }

      // 4096 x 16384 is the most a picture is decoded at in the gallery.
      expect(maxDecodedImagePixels, 4096 * 16384);
      expect(await avifToPng(_still([_ispe(8192, 8193)]), firstFrame: decode), isNull);
      expect(await avifToPng(_sequence(_tkhd(30000, 30000)), firstFrame: decode), isNull);
      expect(await avifToPng(_still([]), firstFrame: decode), isNull);
      expect(decoded, 0);
    });
  });
}

Future<ui.Image> _image(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff336699),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  return image;
}
