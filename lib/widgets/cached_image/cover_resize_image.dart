import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// [provider] decoded just large enough to cover a square of [extent] physical pixels (`BoxFit.cover`): the shorter
/// side of the picture at [extent], the longer side in proportion, but at most [maxAspect] times [extent] (a very long
/// picture is then decoded a little smaller than the square needs, instead of whole); a picture smaller than that is
/// decoded as it is, never enlarged.
///
/// [ResizeImage] bounds the width, or fits the picture inside a box: a landscape picture decoded to the width of a
/// square thumbnail is too short to cover it, and is enlarged (blurred) on screen.
@immutable
final class CoverResizeImage extends ImageProvider<CoverResizeImageKey> {
  /// Constructor.
  const CoverResizeImage(this.provider, {required this.extent, this.maxAspect = 3});

  /// The picture.
  final ImageProvider<Object> provider;

  /// The side of the square to cover, in physical pixels.
  final int extent;

  /// How many times [extent] the longer side of the picture may be decoded at.
  final double maxAspect;

  /// The size to decode a picture of [width] by [height] at, to cover a square of [extent] (see [CoverResizeImage]);
  /// the picture's own size (no resize) when it is not larger than that, or when a size is unknown.
  static ui.TargetImageSize targetSize(int width, int height, int extent, {double maxAspect = 3}) {
    if (width <= 0 || height <= 0 || extent <= 0) {
      return const ui.TargetImageSize();
    }
    final longer = math.max(width, height);
    var scale = extent / math.min(width, height);
    final longerBound = extent * maxAspect;
    if (longer * scale > longerBound) {
      scale = longerBound / longer;
    }
    if (scale >= 1) {
      return const ui.TargetImageSize();
    }
    return ui.TargetImageSize(
      width: math.max(1, (width * scale).round()),
      height: math.max(1, (height * scale).round()),
    );
  }

  @override
  Future<CoverResizeImageKey> obtainKey(ImageConfiguration configuration) {
    // As ResizeImage: a provider that answers its key at once (a SynchronousFuture) is answered at once here too, so
    // an image already in the cache shows in the first frame.
    Completer<CoverResizeImageKey>? completer;
    SynchronousFuture<CoverResizeImageKey>? result;
    unawaited(
      provider.obtainKey(configuration).then((key) {
        final coverKey = CoverResizeImageKey._(key, extent, maxAspect);
        if (completer == null) {
          result = SynchronousFuture<CoverResizeImageKey>(coverKey);
        } else {
          completer.complete(coverKey);
        }
      }),
    );
    if (result != null) {
      return result!;
    }
    completer = Completer<CoverResizeImageKey>();
    return completer.future;
  }

  @override
  ImageStreamCompleter loadImage(CoverResizeImageKey key, ImageDecoderCallback decode) {
    Future<ui.Codec> decodeCover(ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) =>
        decode(buffer, getTargetSize: (width, height) => targetSize(width, height, extent, maxAspect: maxAspect));
    return provider.loadImage(key._providerKey, decodeCover);
  }

  @override
  String toString() => '${objectRuntimeType(this, 'CoverResizeImage')}($provider, extent: $extent)';
}

/// The key of a [CoverResizeImage] in the image cache: the picture's own key and the size it is decoded for.
@immutable
final class CoverResizeImageKey {
  const CoverResizeImageKey._(this._providerKey, this._extent, this._maxAspect);

  final Object _providerKey;
  final int _extent;
  final double _maxAspect;

  @override
  bool operator ==(Object other) =>
      other is CoverResizeImageKey &&
      other._providerKey == _providerKey &&
      other._extent == _extent &&
      other._maxAspect == _maxAspect;

  @override
  int get hashCode => Object.hash(_providerKey, _extent, _maxAspect);
}
