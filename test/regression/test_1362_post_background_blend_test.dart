/// A floor's background blends into the floor (the pictures of the background shop are mostly drawings on white):
/// the picture's white is exactly the floor's color, no plate and no edge, only the drawing shows, faintly, under the
/// veil.
///
/// 1. pixels: a white picture tiled over the whole area paints every pixel the color of the floor without a
///    background (within one step), in the light and the dark theme; a colored picture leaves a measurable difference
///    in both, red still reddish in the dark theme, black lines dark in the light theme and light in the dark one;
/// 2. the blend: multiply on a light floor, the lightness turned over (hue kept) and screen on a dark one, chosen by
///    the floor color's luminance; one color matrix, no blend mode, no layer.
///
/// Pictures from memory; nothing is sent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/post_background/models/post_background.dart';
import 'package:tsdm_client/features/post_background/widgets/post_background_paint.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/utils/html/author_style.dart';

final class _FakeContext extends Fake implements BuildContext {}

/// 16 by 16, white.
final Uint8List _white = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAGUlEQVR4nGP8//8/AymAiSTVoxpGNQwpDQBVbQMdPVIhQwAAAABJRU5ErkJggg==',
);

/// 16 by 16: the left half red (220, 30, 30), the top right quarter near black (20, 20, 20), the rest white.
final Uint8List _drawing = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAKklEQVR4nGO8IyfHgA1YfPuGVZwJqygeMKqBGMCCS+L169fUsWFUAzEAANW5Bh/hb0'
  'MiAAAAAElFTkSuQmCC',
);

final Map<String, ThemeData> _themes = {
  'light': AppTheme.makeLight(_FakeContext(), seedColor: null, fontFamily: ''),
  'dark': AppTheme.makeDark(_FakeContext(), seedColor: null, fontFamily: ''),
  // A light floor of a stronger tint: the plate of an unblended white picture shows on it.
  'light pink': AppTheme.makeLight(_FakeContext(), seedColor: Colors.pink, fontFamily: '').copyWith(
    cardTheme: const CardThemeData(color: Color(0xFFF3E4EA)),
  ),
};

const _box = Size(64, 64);

/// The pixels (RGBA) of the floor's area [_box] painted as the floor paints it: the background [layer] of [bytes]
/// (none when null) under the veil of [theme].
Future<Uint8List> _paint(WidgetTester tester, ThemeData theme, PostBackgroundLayer? layer, Uint8List? bytes) async {
  final key = GlobalKey();
  final surface = postBackgroundSurface(theme);
  final image = bytes == null ? null : MemoryImage(bytes);
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          // The floor: its card color, then (with a background) the picture and the veil, as PostBackgroundPaint.
          child: ColoredBox(
            color: surface,
            child: SizedBox.fromSize(
              size: _box,
              child: image == null
                  ? null
                  : DecoratedBox(
                      decoration: postBackgroundDecoration(layer!, image, surface: surface),
                      child: DecoratedBox(decoration: BoxDecoration(color: postBackgroundVeil(theme))),
                    ),
            ),
          ),
        ),
      ),
    ),
  );
  if (image != null) {
    await tester.runAsync(() => _loaded(image));
    await tester.pump();
  }
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final shot = await boundary.toImage();
    final data = await shot.toByteData();
    shot.dispose();
    return data!.buffer.asUint8List();
  }))!;
}

/// [image] loaded (or failed).
Future<void> _loaded(ImageProvider image) {
  final done = Completer<void>();
  final stream = image.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  void finish() {
    stream.removeListener(listener);
    if (!done.isCompleted) done.complete();
  }

  listener = ImageStreamListener((_, _) => finish(), onError: (_, _) => finish());
  stream.addListener(listener);
  return done.future.timeout(const Duration(seconds: 5));
}

/// The pixel at ([x], [y]) of [pixels] painted [_box] wide.
List<int> _at(Uint8List pixels, int x, int y) {
  final i = (y * _box.width.toInt() + x) * 4;
  return pixels.sublist(i, i + 3);
}

int _channel(double c) => (c * 255).round();

void main() {
  for (final MapEntry(key: name, value: theme) in _themes.entries) {
    group('$name theme', () {
      final surface = postBackgroundSurface(theme);
      final card = [_channel(surface.r), _channel(surface.g), _channel(surface.b)];

      testWidgets('a white picture over the whole area: every pixel the floor color without a background', (
        tester,
      ) async {
        final plain = await _paint(tester, theme, null, null);
        expect(_at(plain, 0, 0), card);
        for (final size in PostBackgroundSize.values) {
          final pixels = await _paint(
            tester,
            theme,
            PostBackgroundLayer(imageUrl: 'https://cdn.example/w.png', repeat: PostBackgroundRepeat.both, size: size),
            _white,
          );
          var worst = 0;
          for (var i = 0; i < pixels.length; i += 4) {
            for (var c = 0; c < 3; c++) {
              final d = (pixels[i + c] - plain[i + c]).abs();
              if (d > worst) worst = d;
            }
          }
          expect(worst, lessThanOrEqualTo(1), reason: '$size: the white of the picture is the floor color');
        }
      });

      testWidgets('a drawing: its colors stay measurable, its white is the floor', (tester) async {
        final pixels = await _paint(
          tester,
          theme,
          const PostBackgroundLayer(imageUrl: 'https://cdn.example/d.png', size: PostBackgroundSize.cover),
          _drawing,
        );
        final red = _at(pixels, 8, 32);
        final line = _at(pixels, 56, 8);
        final white = _at(pixels, 56, 56);
        int distance(List<int> a, List<int> b) => [for (var c = 0; c < 3; c++) (a[c] - b[c]).abs()].reduce(max);
        expect(distance(white, card), lessThanOrEqualTo(1), reason: 'white is the floor');
        expect(distance(red, card), greaterThanOrEqualTo(8), reason: 'red shows');
        expect(distance(line, card), greaterThanOrEqualTo(8), reason: 'the line shows');
        expect(red[0] - red[1], greaterThan(card[0] - card[1]), reason: 'red still reddish');
        final dark = relativeLuminance(surface) < postBackgroundLightSurface;
        expect(dark, name.startsWith('dark'));
        // Light: a dark line darker than the floor; dark: lighter than it (the lightness turned over).
        final lineLum = line.reduce((a, b) => a + b);
        final cardLum = card.reduce((a, b) => a + b);
        expect(dark ? lineLum > cardLum : lineLum < cardLum, isTrue, reason: 'line $line on $card');
      });
    });
  }

  test('one color matrix, no blend mode: the picture is drawn opaque over the floor color', () {
    for (final theme in _themes.values) {
      final surface = postBackgroundSurface(theme);
      final decoration = postBackgroundDecoration(
        const PostBackgroundLayer(imageUrl: 'https://cdn.example/w.png'),
        MemoryImage(_white),
        surface: surface,
      );
      expect(decoration.color, surface, reason: 'the floor color first, in the same painter');
      expect(decoration.backgroundBlendMode, isNull);
      expect(decoration.image!.colorFilter, postBackgroundBlend(surface));
      expect(decoration.image!.opacity, 1);
    }
  });

  test('the veil is the one of before: the pixels still run within black and white', () {
    for (final theme in _themes.values) {
      expect(postBackgroundVeil(theme).a, greaterThanOrEqualTo(postBackgroundMinVeilOpacity));
    }
  });
}
