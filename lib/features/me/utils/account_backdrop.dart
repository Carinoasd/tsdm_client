import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:tsdm_client/features/post_background/models/post_background.dart';

/// How the account card draws a background, from the picture itself.
enum AccountBackdropKind {
  /// A wide picture (at least [accountBackdropCoverWidth] pixels) on colors: covering the card, cut where the member
  /// aligns it.
  cover,

  /// A picture on white ([accountBackdropWhiteEdged]): blended into the card's color, as high as the card.
  blend,

  /// A smaller picture on colors: as high as the card at its right, its left edge faded out.
  side,

  /// The member has it repeat: tiled at its own size.
  tile,
}

/// The longest side the picture is sampled at to tell its kind.
const accountBackdropSampleSide = 64;

/// The least value of each of red, green and blue of a pixel taken for white (a JPEG's white is rarely 255).
const accountBackdropWhiteChannel = 235;

/// The least share of white pixels on the edge for a picture on white. Of the 147 pictures of the background plugin,
/// those meant to sit on the white of a post are 0.80 to 1 on their edge (a figure may touch it); those on colors (a
/// scene, a vignette) 0.67 at most, one on cream 0.76.
const accountBackdropWhiteEdgeShare = 0.78;

/// The share of the shorter side of the sample its edge is ([accountBackdropWhiteEdged]).
const accountBackdropEdgeShare = 0.06;

/// The least width (in the picture's own pixels) of a picture drawn covering the card.
const accountBackdropCoverWidth = 600;

/// The least share of the card's width a picture drawn as high as the card takes: a tall strip is drawn wider and cut
/// down instead of a sliver.
const accountBackdropMinWidthShare = 0.4;

/// Whether the picture sampled as [rgba] (`width` × `height`, straight RGBA bytes) is on white: at least
/// [accountBackdropWhiteEdgeShare] of the pixels of its edge (a band [accountBackdropEdgeShare] of its shorter side
/// wide, a pixel at least) are white ([accountBackdropWhiteChannel]) or transparent.
bool accountBackdropWhiteEdged(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
    return false;
  }
  final band = math.max(1, (math.min(width, height) * accountBackdropEdgeShare).round());
  var total = 0;
  var white = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (x >= band && y >= band && x < width - band && y < height - band) {
        continue;
      }
      total++;
      final i = (y * width + x) * 4;
      if (rgba[i + 3] < 32 ||
          (rgba[i] >= accountBackdropWhiteChannel &&
              rgba[i + 1] >= accountBackdropWhiteChannel &&
              rgba[i + 2] >= accountBackdropWhiteChannel)) {
        white++;
      }
    }
  }
  return total > 0 && white / total >= accountBackdropWhiteEdgeShare;
}

/// The kind of a picture [width] pixels wide, on white or not ([whiteEdged]), the member has [repeat].
AccountBackdropKind accountBackdropKind({
  required int width,
  required bool whiteEdged,
  required PostBackgroundRepeat repeat,
}) {
  if (repeat != PostBackgroundRepeat.none) {
    return AccountBackdropKind.tile;
  }
  if (whiteEdged) {
    return AccountBackdropKind.blend;
  }
  return width >= accountBackdropCoverWidth ? AccountBackdropKind.cover : AccountBackdropKind.side;
}

/// Where a picture of [image] size is drawn on a card of [card] size as high as the card ([AccountBackdropKind.blend],
/// [AccountBackdropKind.side]): scaled to the card's height, or wider for a tall strip
/// ([accountBackdropMinWidthShare]; not past its own size then), never wider than the card, at [alignX] across and
/// [alignY] down (where a tall strip is cut).
Rect accountBackdropSideRect(
  Size card,
  Size image, {
  required PostBackgroundAlignX alignX,
  PostBackgroundAlignY alignY = PostBackgroundAlignY.center,
}) {
  if (image.isEmpty || card.isEmpty) {
    return Rect.zero;
  }
  final scale = math.min(
    math.max(card.height / image.height, math.min(card.width * accountBackdropMinWidthShare / image.width, 1)),
    // Never cut across: a wide picture is drawn as wide as the card instead.
    card.width / image.width,
  );
  final width = image.width * scale;
  final height = image.height * scale;
  final left = switch (alignX) {
    PostBackgroundAlignX.left => 0.0,
    PostBackgroundAlignX.center => (card.width - width) / 2,
    PostBackgroundAlignX.right => card.width - width,
  };
  final top = switch (alignY) {
    PostBackgroundAlignY.top => 0.0,
    PostBackgroundAlignY.center => (card.height - height) / 2,
    PostBackgroundAlignY.bottom => card.height - height,
  };
  return Rect.fromLTWH(left, top, width, height);
}
