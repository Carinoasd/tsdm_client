/// A picture is never decoded at more than a limit of pixels ([maxDecodedImagePixels], [maxAvatarDecodePixels]).
///
/// A picture is decoded no wider than it is shown, but a narrow and very tall one (or an avatar, decoded whole) was
/// decoded at its full size: a PNG of a few hundred kilobytes declaring 30000 x 30000 pixels asked for 3.6 GB. A
/// picture declaring more pixels than the limit is decoded smaller, its proportions kept; any other picture is
/// decoded as before. The size of a cached image (the gallery's details, the editor's image dialog) is read from its
/// header instead of decoding it whole.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_limits.dart';

/// A PNG of [width] by [height] pixels, of one color.
Uint8List _png(int width, int height) {
  int crc(List<int> bytes) {
    var c = 0xffffffff;
    for (final b in bytes) {
      c ^= b;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
      }
    }
    return c ^ 0xffffffff;
  }

  List<int> u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
  List<int> chunk(String type, List<int> data) {
    final body = [...type.codeUnits, ...data];
    return [...u32(data.length), ...body, ...u32(crc(body))];
  }

  // Grey, 8 bits: a filter byte and a pixel byte per pixel.
  final raw = Uint8List((width + 1) * height);
  return Uint8List.fromList([
    0x89,
    ...'PNG'.codeUnits,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
    ...chunk('IHDR', [...u32(width), ...u32(height), 8, 0, 0, 0, 0]),
    ...chunk('IDAT', zlib.encode(raw)),
    ...chunk('IEND', []),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the size a picture is decoded at', () {
    test('is its own within the limit', () {
      expect(cappedDecodeSize(1080, 20000, maxPixels: maxDecodedImagePixels), isNull);
      expect(cappedDecodeSize(4096, 16384, maxPixels: maxDecodedImagePixels), isNull);
    });

    test('over the limit, is within it, its proportions kept, no wider than 4096', () {
      final square = cappedDecodeSize(30000, 30000, maxPixels: maxDecodedImagePixels)!;
      expect(square.width, 4096);
      expect(square.height, 4096);
      final tall = cappedDecodeSize(2000, 200000, maxPixels: maxDecodedImagePixels)!;
      expect(tall.width! * tall.height!, lessThanOrEqualTo(maxDecodedImagePixels));
      expect(tall.height! / tall.width!, closeTo(100, 1));
      // One pixel wide: still within the limit.
      final line = cappedDecodeSize(1, 1 << 30, maxPixels: maxDecodedImagePixels)!;
      expect(line.width! * line.height!, lessThanOrEqualTo(maxDecodedImagePixels));
      final avatar = cappedDecodeSize(16000, 16000, maxPixels: maxAvatarDecodePixels)!;
      expect(avatar.width! * avatar.height!, lessThanOrEqualTo(maxAvatarDecodePixels));
    });
  });

  testWidgets('a picture declaring more pixels than the limit is decoded within it', (tester) async {
    await tester.runAsync(() async {
      // 3000 x 2000 with a limit of 1.5 megapixels, as 30000 x 20000 with the limit of the app.
      final bytes = _png(3000, 2000);
      var askedTheDecoder = 0;
      Future<ui.Codec> decode(ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) {
        askedTheDecoder++;
        return ui.instantiateImageCodecWithSize(buffer, getTargetSize: getTargetSize);
      }

      final codec = await decodeWithinPixelLimit(
        await ui.ImmutableBuffer.fromUint8List(bytes),
        decode,
        maxPixels: 1500000,
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width * frame.image.height, lessThanOrEqualTo(1500000));
      expect(frame.image.width / frame.image.height, closeTo(1.5, 0.01));
      expect(askedTheDecoder, 0, reason: 'decoded at the size within the limit, not the one asked');
      frame.image.dispose();
      codec.dispose();

      // Within the limit: decoded as it was asked for, by the decoder given (a ResizeImage's).
      final small = await decodeWithinPixelLimit(
        await ui.ImmutableBuffer.fromUint8List(_png(30, 20)),
        decode,
        maxPixels: 1500000,
      );
      final smallFrame = await small.getNextFrame();
      expect((smallFrame.image.width, smallFrame.image.height), (30, 20));
      expect(askedTheDecoder, 1);
      smallFrame.image.dispose();
      small.dispose();

      // Not an image: the decoder given reports it, as before.
      await expectLater(
        decodeWithinPixelLimit(await ui.ImmutableBuffer.fromUint8List(utf8.encode('<html>')), decode),
        throwsA(anything),
      );
    });
  });

  testWidgets('the size of a cached picture is read without decoding it', (tester) async {
    await tester.runAsync(() async {
      expect(await encodedImageSize(_png(3000, 2000)), (width: 3000, height: 2000));
      expect(await encodedImageSize(Uint8List.fromList(utf8.encode('<html>'))), isNull);
    });
  });

  test('the image cache and the editor read the size of a picture without decoding it', () {
    for (final path in [
      'lib/shared/providers/image_cache_provider/image_cache_provider.dart',
      'lib/features/editor/widgets/image_dialog.dart',
    ]) {
      expect(File(path).readAsStringSync(), isNot(contains('decodeImageFromList(')), reason: path);
    }
    final provider = File('lib/widgets/cached_image/cached_image_provider.dart').readAsStringSync();
    expect(provider, contains('decodeWithinPixelLimit('));
    expect(PaintingBinding.instance, isNotNull);
  });
}
