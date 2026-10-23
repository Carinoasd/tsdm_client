import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/color.dart';
import 'package:tsdm_client/features/cache/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/fallback_picture.dart';

/// Image that supports caching.
///
/// * First try to read from cache.
/// * If no cache available, fetch image from [imageUrl].
class CachedImage extends StatefulWidget {
  /// Constructor.
  CachedImage(
    this.imageUrl, {
    this.width,
    this.height,
    this.maxWidth,
    this.boundDecodeToDisplay = true,
    this.maxHeight,
    this.minWidth,
    this.minHeight,
    this.fit,
    this.tag,
    this.enableAnimation = true,
    this.cacheOnly = false,
    this.placeholderBuilder,
    this.errorBuilder,
    this.onImageSize,
    super.key,
  }) : _imageProvider = CachedImageProvider(imageUrl, cacheOnly: cacheOnly);

  /// Image to fetch url.
  ///
  /// Also the key to find cached image data.
  final String imageUrl;

  /// Fixed image width.
  final double? width;

  /// Fixed image height.
  final double? height;

  /// Max image width.
  final double? maxWidth;

  /// Decode at most as wide as the image is displayed (the screen by default). Off for viewers that zoom.
  final bool boundDecodeToDisplay;

  /// Max image height.
  final double? maxHeight;

  /// Min image width.
  final double? minWidth;

  /// Min image height.
  final double? minHeight;

  /// Fit type.
  final BoxFit? fit;

  /// Tag for hero animation.
  final String? tag;

  /// Enable animation between image loading states.
  ///
  /// Default is true.
  final bool enableAnimation;

  /// Only show the image when it is cached already, never fetch it ([CachedImageProvider.cacheOnly]); [errorBuilder]
  /// shows what is there instead when it is not.
  final bool cacheOnly;

  /// What shows until the image is there instead of the default placeholder, with the progress of its download: null
  /// before the first bytes arrived, and while it is read from the cache.
  ///
  /// With it the image is only built once its first frame is decoded, then at once: the placeholder keeps its place
  /// until then.
  final Widget Function(BuildContext context, ImageChunkEvent? progress)? placeholderBuilder;

  /// What shows when the image did not load, with [placeholderBuilder]; `retry` loads it again (a failed load stays in
  /// the image cache, nothing would ask again otherwise).
  final Widget Function(BuildContext context, Object error, VoidCallback retry)? errorBuilder;

  /// Told the size of the image once its first frame is decoded, with [placeholderBuilder]: its pixels as decoded, and
  /// whether it was decoded narrower than it is (no wider than shown, [boundDecodeToDisplay]). May be called while
  /// building: it must not rebuild anything.
  final void Function(Size size, {required bool downscaled})? onImageSize;

  /// Image provider to render the content.
  late final CachedImageProvider _imageProvider;

  @override
  State<CachedImage> createState() => _CachedImageState();
}

class _CachedImageState extends State<CachedImage> with LoggerMixin {
  Widget _buildPlaceholder(BuildContext context) => Shimmer.fromColors(
    baseColor: Theme.of(context).colorScheme.primary.withOpacityA(0.3),
    highlightColor: Theme.of(context).colorScheme.primary.withOpacityA(0.2),
    child: FallbackPicture(
      fit: widget.fit,
      width: widget.width ?? widget.maxWidth,
      height: widget.height ?? widget.maxHeight,
    ),
  );

  StreamSubscription<ImageCacheResponse>? imageSub;

  Future<void> onImageResponse(ImageCacheResponse resp) async {
    if (mounted && resp is ImageCacheLoadingResponse) {
      // Loaded again while shown (reloaded from the image sheet): what comes is shown, see below.
      _reloading = _loaded;
      await widget._imageProvider.evict();
    }
    if (!mounted || widget.placeholderBuilder == null || resp is! ImageCacheSuccessResponse) {
      return;
    }
    // The image is in the cache now: read again when it was reloaded while shown, or did not load here (a picture only
    // shown when cached, loaded by another widget meanwhile).
    if (_reloading || _error != null) {
      _reloading = false;
      await _reload();
    }
  }

  void _listenToCache() {
    unawaited(imageSub?.cancel());
    imageSub = getIt
        .get<ImageCacheProvider>()
        .response
        .where((e) => e.respType == ImageCacheResponseType.general && e.imageId == widget.imageUrl)
        .listen((resp) async => onImageResponse(resp));
  }

  /// The image was asked again since it was shown ([onImageResponse]).
  bool _reloading = false;

  /// The image as resolved for [CachedImage.placeholderBuilder]: its stream, and what it told so far.
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageProvider? _provider;
  bool _loaded = false;
  ImageChunkEvent? _progress;
  Object? _error;

  /// The listener is being added: what it is told at once (an image or an error in the image cache already) comes while
  /// building, only the fields are set.
  bool _adding = false;

  /// Load the image again: the load in the image cache goes first, a failed one would only fail again.
  Future<void> _reload() async {
    final provider = _provider;
    await provider?.evict();
    await widget._imageProvider.evict();
    if (!mounted) {
      return;
    }
    setState(_unwatch);
  }

  void _unwatch() {
    if (_listener case final listener?) {
      _stream?.removeListener(listener);
    }
    _stream = null;
    _listener = null;
    _provider = null;
    _loaded = false;
    _progress = null;
    _error = null;
  }

  /// Follow the loading of [provider]: what [CachedImage.placeholderBuilder] shows, and the size of the image.
  ///
  /// Called while building: a listener called at once (an image already in the image cache) only sets the fields.
  void _watch(ImageProvider provider) {
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (_stream != null && stream.key == _stream!.key) {
      return;
    }
    _unwatch();
    _provider = provider;
    final decodeWidth = provider is ResizeImage ? provider.width : null;
    final listener = ImageStreamListener(
      (info, synchronousCall) {
        final image = info.image;
        final first = !_loaded;
        if (first) {
          widget.onImageSize?.call(
            Size(image.width.toDouble(), image.height.toDouble()),
            downscaled: decodeWidth != null && image.width >= decodeWidth,
          );
        }
        info.dispose();
        if (!first || !mounted) {
          return;
        }
        if (synchronousCall || _adding) {
          _loaded = true;
          _progress = null;
        } else {
          setState(() {
            _loaded = true;
            _progress = null;
          });
        }
      },
      onChunk: (event) {
        if (!mounted || _loaded) {
          return;
        }
        if (_adding) {
          _progress = event;
        } else {
          setState(() => _progress = event);
        }
      },
      onError: (e, st) {
        if (!mounted) {
          return;
        }
        if (widget.cacheOnly) {
          // Not cached is all it says. The image cache keeps a failed load: a thread of pictures only shown when cached
          // would leave one there for each.
          scheduleMicrotask(() async => provider.evict());
        } else {
          handleRaw(e, st);
        }
        if (_adding) {
          _error = e;
        } else {
          setState(() => _error = e);
        }
      },
    );
    _stream = stream;
    _listener = listener;
    _adding = true;
    try {
      stream.addListener(listener);
    } finally {
      _adding = false;
    }
  }

  /// [image] once it is there, [CachedImage.placeholderBuilder] until then, [CachedImage.errorBuilder] when it did not
  /// load.
  Widget _buildWatched(BuildContext context, Image image) {
    // A failed load is only tried again on purpose ([_reload]): asked again at every build, it would fail again.
    if (_error == null) {
      _watch(image.image);
    }
    if (_error case final error?) {
      return widget.errorBuilder?.call(context, error, _reload) ??
          FallbackPicture(
            fit: widget.fit,
            width: widget.width ?? widget.maxWidth,
            height: widget.height ?? widget.maxHeight,
          );
    }
    if (!_loaded) {
      return widget.placeholderBuilder!(context, _progress);
    }
    return image;
  }

  @override
  void initState() {
    super.initState();
    if (tmpImpellerWorkaroundUrls.contains(widget.imageUrl)) {
      return;
    }
    _listenToCache();
  }

  @override
  void didUpdateWidget(CachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.cacheOnly != widget.cacheOnly ||
        (oldWidget.placeholderBuilder == null) != (widget.placeholderBuilder == null)) {
      _unwatch();
      _reloading = false;
    }
    if (oldWidget.imageUrl != widget.imageUrl && !tmpImpellerWorkaroundUrls.contains(widget.imageUrl)) {
      _listenToCache();
    }
  }

  @override
  void dispose() {
    unawaited(imageSub?.cancel());
    _unwatch();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Show an icon instead of the original image.
    if (tmpImpellerWorkaroundUrls.contains(widget.imageUrl)) {
      return Icon(Icons.navigate_before_outlined, color: Theme.of(context).colorScheme.tertiary);
    }

    final Widget body;
    if (widget.imageUrl.isEmpty) {
      body = FallbackPicture(
        fit: widget.fit,
        width: widget.width ?? widget.maxWidth,
        height: widget.height ?? widget.maxHeight,
      );
    } else {
      final image = Image(
        // Decode no larger than the image is shown: a 4000px picture in a post used to be decoded whole and
        // uploaded to the GPU at full size, which stuttered the scroll and ate memory.
        image: ResizeImage.resizeIfNeeded(
          widget.boundDecodeToDisplay
              ? decodeWidthFor(
                  width: widget.width,
                  maxWidth: widget.maxWidth,
                  displayWidth: MediaQuery.sizeOf(context).width,
                  devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                )
              : null,
          null,
          widget._imageProvider,
        ),
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        errorBuilder: (context, e, st) {
          handleRaw(e, st);
          final picture = FallbackPicture(
            fit: widget.fit,
            width: widget.width ?? widget.maxWidth,
            height: widget.height ?? widget.maxHeight,
          );
          // When the server answered with a page (e.g. attachments in a paid thread) show its message.
          final message = getIt.get<ImageCacheProvider>().htmlMessageOf(widget.imageUrl);
          if (message == null || message.isEmpty) {
            return picture;
          }
          return Stack(
            alignment: Alignment.bottomCenter,
            children: [
              picture,
              Padding(
                padding: const EdgeInsets.all(4),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: edgeInsetsL4R4,
                    child: Text(
                      message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded) {
            return child;
          }
          if (!widget.enableAnimation) {
            return frame != null ? child : _buildPlaceholder(context);
          }
          return AnimatedSwitcher(
            duration: duration100,
            // Use layoutBuilder to let child image "maximized".
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                alignment: Alignment.center,
                children: <Widget>[...previousChildren, ?currentChild],
              );
            },
            // Return the same placeholder until built finished to avoid size
            // change.
            child: frame != null ? child : _buildPlaceholder(context),
          );
        },
      );
      body = widget.placeholderBuilder == null ? image : _buildWatched(context, image);
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: widget.maxWidth ?? double.infinity,
        maxHeight: widget.maxHeight ?? double.infinity,
        minWidth: widget.minWidth ?? 0,
        minHeight: widget.minHeight ?? 0,
      ),
      child: body,
    );
  }
}

/// Pixel width to decode an image at so it is no larger than it will be shown: the smallest of the requested
/// [width], [maxWidth] and the [displayWidth], in physical pixels. Null when nothing bounds it.
int? decodeWidthFor({
  required double? width,
  required double? maxWidth,
  required double displayWidth,
  required double devicePixelRatio,
}) {
  double? bound;
  for (final candidate in [width, maxWidth, displayWidth]) {
    if (candidate == null || !candidate.isFinite || candidate <= 0) {
      continue;
    }
    bound = bound == null ? candidate : (candidate < bound ? candidate : bound);
  }
  if (bound == null) {
    return null;
  }
  return (bound * devicePixelRatio).ceil();
}
