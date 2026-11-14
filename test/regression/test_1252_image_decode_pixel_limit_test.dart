/// A picture is never decoded at more than a limit of pixels ([maxDecodedImagePixels], [maxAvatarDecodePixels]).
///
/// A picture is decoded no wider than it is shown, but a narrow and very tall one (or an avatar, decoded whole) was
/// decoded at its full size: a PNG of a few hundred kilobytes declaring 30000 x 30000 pixels asked for 3.6 GB. The
/// provider of the pictures limits the pixels it is decoded at ([decodeWithinPixels]); the providers around it
/// (`BoundedResizeImage` in place of Flutter's `ResizeImage`, which refuses such a provider, and `CoverResizeImage`)
/// decode it at the size they ask for, made smaller still when that is over the limit ([composeTargetSize]): a
/// picture is never decoded larger than before. The size of a cached image (the gallery's details, the editor's image
/// dialog) is read from its header instead of decoding it whole.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_limits.dart';
import 'package:tsdm_client/widgets/cached_image/bounded_resize_image.dart';
import 'package:tsdm_client/widgets/cached_image/cover_resize_image.dart';

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
      // Sizes whose product overflows 64 bits.
      final huge = cappedDecodeSize(0xffffffff, 0xffffffff, maxPixels: maxDecodedImagePixels)!;
      expect(huge.width! * huge.height!, lessThanOrEqualTo(maxDecodedImagePixels));
      final avatar = cappedDecodeSize(16000, 16000, maxPixels: maxAvatarDecodePixels)!;
      expect(avatar.width! * avatar.height!, lessThanOrEqualTo(maxAvatarDecodePixels));
    });
  });

  group('a size asked for by a provider around the picture', () {
    final cap = decodeWithinPixels(1500000);

    test('is kept when it is within the limit', () {
      // A large picture shown 1080 wide: decoded 1080 wide, as before.
      final shown = composeTargetSize(const ui.TargetImageSize(width: 1080), 12000, 9000, inner: cap);
      expect((shown.width, shown.height), (1080, null));
      final none = composeTargetSize(const ui.TargetImageSize(), 1000, 1000, inner: cap);
      expect((none.width, none.height), (null, null));
    });

    test('is made smaller when it comes to more than the limit', () {
      // A narrow and very tall picture shown at its own width: within the limit.
      final tall = composeTargetSize(const ui.TargetImageSize(width: 1000), 1000, 200000, inner: cap);
      expect(tall.width! * tall.height!, lessThanOrEqualTo(1500000));
      final whole = composeTargetSize(const ui.TargetImageSize(), 3000, 2000, inner: cap);
      expect(whole.width! * whole.height!, lessThanOrEqualTo(1500000));
    });

    test('is the one asked for when the provider inside takes any', () {
      final asked = composeTargetSize(const ui.TargetImageSize(width: 10), 3000, 2000);
      expect((asked.width, asked.height), (10, null));
    });
  });

  testWidgets('a picture is decoded within the limit, at the size asked for when smaller', (tester) async {
    await tester.runAsync(() async {
      // 3000 x 2000 with a limit of 1.5 megapixels, as 30000 x 20000 with the limit of the app.
      final picture = _Picture(_png(3000, 2000), maxPixels: 1500000);
      final bare = await _decoded(picture);
      expect(bare.$1 * bare.$2, lessThanOrEqualTo(1500000));
      expect(bare.$1 / bare.$2, closeTo(1.5, 0.01));

      // Shown 300 wide: decoded 300 wide, not at the limit.
      expect(await _decoded(BoundedResizeImage(picture, width: 300)), (300, 200));
      // Fitted in a box larger than the limit: within the limit.
      final fitted = await _decoded(
        BoundedResizeImage(picture, width: 4096, height: 16384, policy: ResizeImagePolicy.fit),
      );
      expect(fitted.$1 * fitted.$2, lessThanOrEqualTo(1500000));
      // A narrow and tall picture shown at its width: within the limit, its proportions kept.
      final tall = await _decoded(BoundedResizeImage(_Picture(_png(200, 20000), maxPixels: 1500000), width: 1080));
      expect(tall.$1 * tall.$2, lessThanOrEqualTo(1500000));
      expect(tall.$2 / tall.$1, closeTo(100, 2));
      // A thumbnail covering a square: as before.
      expect(await _decoded(CoverResizeImage(picture, extent: 100)), (150, 100));
      // Smaller than the limit and than the size asked: its own size.
      expect(await _decoded(BoundedResizeImage(_Picture(_png(30, 20), maxPixels: 1500000), width: 300)), (30, 20));
    });
  });

  test('BoundedResizeImage decodes at the sizes ResizeImage decodes at', () {
    for (final (iw, ih) in [(3000, 2000), (200, 20000), (500, 400), (4096, 16384), (9000, 100)]) {
      for (final (w, h, policy) in [
        (1080, null, ResizeImagePolicy.exact),
        (300, 300, ResizeImagePolicy.exact),
        (4096, 16384, ResizeImagePolicy.fit),
        (1000, 1000, ResizeImagePolicy.fit),
      ]) {
        final ours = BoundedResizeImage.targetSize(iw, ih, width: w, height: h, policy: policy);
        expect(
          ours.width,
          policy == ResizeImagePolicy.exact ? (w > iw ? iw : w) : lessThanOrEqualTo(w),
          reason: '$iw x $ih',
        );
        if (policy == ResizeImagePolicy.fit) {
          expect(ours.height, lessThanOrEqualTo(h!));
        }
      }
    }
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
    expect(provider, contains('getTargetSize: decodeWithinPixels('));
  });

  test("no picture of the app is put in Flutter's ResizeImage, which refuses a provider limiting its decode size", () {
    final uses = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      // The replacement, telling what it replaces.
      if (!file.path.endsWith('.dart') || file.path.endsWith('bounded_resize_image.dart')) {
        continue;
      }
      final source = file.readAsStringSync();
      if (RegExp(r'(?<![A-Za-z])ResizeImage(\(|\.resizeIfNeeded)').hasMatch(source)) {
        uses.add(file.path);
      }
    }
    expect(uses, isEmpty);
  });
}

/// A picture of [bytes], decoded as `CachedImageProvider` decodes one: at most [maxPixels].
@immutable
final class _Picture extends ImageProvider<_Picture> {
  const _Picture(this.bytes, {required this.maxPixels});

  final Uint8List bytes;
  final int maxPixels;

  @override
  Future<_Picture> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Picture key, ImageDecoderCallback decode) => OneFrameImageStreamCompleter(
    () async {
      final codec = await decode(
        await ui.ImmutableBuffer.fromUint8List(bytes),
        getTargetSize: decodeWithinPixels(maxPixels),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      return ImageInfo(image: frame.image);
    }(),
  );
}

/// The size [provider] is decoded at.
Future<(int, int)> _decoded(ImageProvider provider) async {
  final done = Completer<(int, int)>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      done.complete((info.image.width, info.image.height));
      info.dispose();
      stream.removeListener(listener);
    },
    onError: done.completeError,
  );
  stream.addListener(listener);
  final size = await done.future.timeout(const Duration(seconds: 10));
  PaintingBinding.instance.imageCache.clear();
  return size;
}
