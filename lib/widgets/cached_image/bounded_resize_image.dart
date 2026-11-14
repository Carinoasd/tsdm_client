import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_limits.dart';

/// [provider] decoded at most [width] wide and [height] high, as [ResizeImage] decodes it (the same sizes for the same
/// [policy], never enlarged), and never at more pixels than [provider] itself takes ([composeTargetSize]).
///
/// [ResizeImage] refuses a provider limiting the size it is decoded at (it asserts), and the pictures of the app do:
/// `CachedImageProvider` limits the pixels a picture is decoded at, whatever it is shown at.
@immutable
final class BoundedResizeImage extends ImageProvider<BoundedResizeImageKey> {
  /// Constructor.
  const BoundedResizeImage(this.provider, {this.width, this.height, this.policy = ResizeImagePolicy.exact})
    : assert(width != null || height != null, 'a width or a height to bound');

  /// [provider] bounded to [width] and [height], [provider] itself when both are null (as
  /// [ResizeImage.resizeIfNeeded]).
  static ImageProvider<Object> resizeIfNeeded(int? width, int? height, ImageProvider<Object> provider) =>
      width == null && height == null ? provider : BoundedResizeImage(provider, width: width, height: height);

  /// The picture.
  final ImageProvider<Object> provider;

  /// The widest the picture is decoded, null for any width.
  final int? width;

  /// The highest the picture is decoded, null for any height.
  final int? height;

  /// How [width] and [height] bound the picture, as [ResizeImage.policy].
  final ResizeImagePolicy policy;

  /// The size [ResizeImage] (not enlarging) decodes a picture of [intrinsicWidth] by [intrinsicHeight] at.
  static ui.TargetImageSize targetSize(
    int intrinsicWidth,
    int intrinsicHeight, {
    int? width,
    int? height,
    ResizeImagePolicy policy = ResizeImagePolicy.exact,
  }) {
    switch (policy) {
      case ResizeImagePolicy.exact:
        return ui.TargetImageSize(
          width: width != null && width > intrinsicWidth ? intrinsicWidth : width,
          height: height != null && height > intrinsicHeight ? intrinsicHeight : height,
        );
      case ResizeImagePolicy.fit:
        final aspectRatio = intrinsicWidth / intrinsicHeight;
        final maxWidth = width ?? intrinsicWidth;
        final maxHeight = height ?? intrinsicHeight;
        var targetWidth = intrinsicWidth;
        var targetHeight = intrinsicHeight;
        if (targetWidth > maxWidth) {
          targetWidth = maxWidth;
          targetHeight = targetWidth ~/ aspectRatio;
        }
        if (targetHeight > maxHeight) {
          targetHeight = maxHeight;
          targetWidth = (targetHeight * aspectRatio).floor();
        }
        return ui.TargetImageSize(width: targetWidth, height: targetHeight);
    }
  }

  @override
  Future<BoundedResizeImageKey> obtainKey(ImageConfiguration configuration) {
    // As ResizeImage: a provider that answers its key at once (a SynchronousFuture) is answered at once here too, so
    // an image already in the cache shows in the first frame.
    Completer<BoundedResizeImageKey>? completer;
    SynchronousFuture<BoundedResizeImageKey>? result;
    unawaited(
      provider.obtainKey(configuration).then((key) {
        final boundedKey = BoundedResizeImageKey._(key, width, height, policy);
        if (completer == null) {
          result = SynchronousFuture<BoundedResizeImageKey>(boundedKey);
        } else {
          completer.complete(boundedKey);
        }
      }),
    );
    if (result != null) {
      return result!;
    }
    completer = Completer<BoundedResizeImageKey>();
    return completer.future;
  }

  @override
  ImageStreamCompleter loadImage(BoundedResizeImageKey key, ImageDecoderCallback decode) {
    Future<ui.Codec> decodeBounded(ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) => decode(
      buffer,
      getTargetSize: (w, h) => composeTargetSize(
        targetSize(w, h, width: width, height: height, policy: policy),
        w,
        h,
        inner: getTargetSize,
      ),
    );
    // As ResizeImage: a picture that failed leaves the image cache, it is loaded again next time.
    return provider.loadImage(key._providerKey, decodeBounded)..addEphemeralErrorListener((_, _) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
  }

  @override
  bool operator ==(Object other) =>
      other is BoundedResizeImage &&
      other.provider == provider &&
      other.width == width &&
      other.height == height &&
      other.policy == policy;

  @override
  int get hashCode => Object.hash(provider, width, height, policy);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'BoundedResizeImage')}($provider, width: $width, height: $height, policy: $policy)';
}

/// The key of a [BoundedResizeImage] in the image cache: the picture's own key and the size it is decoded for.
@immutable
final class BoundedResizeImageKey {
  const BoundedResizeImageKey._(this._providerKey, this._width, this._height, this._policy);

  final Object _providerKey;
  final int? _width;
  final int? _height;
  final ResizeImagePolicy _policy;

  @override
  bool operator ==(Object other) =>
      other is BoundedResizeImageKey &&
      other._providerKey == _providerKey &&
      other._width == _width &&
      other._height == _height &&
      other._policy == _policy;

  @override
  int get hashCode => Object.hash(_providerKey, _width, _height, _policy);
}
