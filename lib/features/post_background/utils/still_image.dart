import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// [provider] as a still picture: the first frame of an animated one (a GIF background), the picture itself
/// otherwise.
///
/// A background is decoration: an animated one would repaint its floor (the whole content above it) every frame.
@immutable
final class StillImage extends ImageProvider<StillImageKey> {
  /// Constructor.
  const StillImage(this.provider);

  /// The picture.
  final ImageProvider<Object> provider;

  @override
  Future<StillImageKey> obtainKey(ImageConfiguration configuration) {
    Completer<StillImageKey>? completer;
    // A synchronous key of [provider] stays synchronous, as [ResizeImage] keeps it.
    SynchronousFuture<StillImageKey>? result;
    unawaited(
      provider.obtainKey(configuration).then((key) {
        if (completer == null) {
          result = SynchronousFuture<StillImageKey>(StillImageKey._(key));
        } else {
          completer.complete(StillImageKey._(key));
        }
      }),
    );
    if (result != null) {
      return result!;
    }
    completer = Completer<StillImageKey>();
    return completer.future;
  }

  @override
  ImageStreamCompleter loadImage(StillImageKey key, ImageDecoderCallback decode) {
    Future<ui.Codec> decodeStill(ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) async =>
        _FirstFrameCodec(await decode(buffer, getTargetSize: getTargetSize));
    // A picture that failed leaves the image cache: it is loaded again next time (as ResizeImage).
    return provider.loadImage(key._providerKey, decodeStill)..addEphemeralErrorListener((_, _) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
  }

  @override
  bool operator ==(Object other) => other is StillImage && other.provider == provider;

  @override
  int get hashCode => provider.hashCode;

  @override
  String toString() => '${objectRuntimeType(this, 'StillImage')}($provider)';
}

/// The key of a [StillImage] in the image cache: the picture's own key, apart from the animated picture's.
@immutable
final class StillImageKey {
  const StillImageKey._(this._providerKey);

  final Object _providerKey;

  @override
  bool operator ==(Object other) => other is StillImageKey && other._providerKey == _providerKey;

  @override
  int get hashCode => Object.hash(StillImageKey, _providerKey);
}

/// A codec giving the first frame of [_inner] only: the image stream shows it and never animates.
final class _FirstFrameCodec implements ui.Codec {
  _FirstFrameCodec(this._inner);

  final ui.Codec _inner;

  @override
  int get frameCount => 1;

  @override
  int get repetitionCount => 0;

  @override
  Future<ui.FrameInfo> getNextFrame() => _inner.getNextFrame();

  @override
  void dispose() => _inner.dispose();
}
