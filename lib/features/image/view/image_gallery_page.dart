import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/image/models/gallery_image.dart';
import 'package:tsdm_client/features/image/utils/image_actions.dart';
import 'package:tsdm_client/features/image/utils/image_sizes.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/copy_content_dialog.dart';

/// Open the gallery of [images] at [index] (the pictures of a floor, the one tapped).
///
/// The route is the one of the single picture ([ScreenPaths.imageDetail], its url in the path) with the pictures as
/// its extra: the route opened without them (a link, a page restored) shows that picture alone.
Future<void> openImageGallery(BuildContext context, List<GalleryImage> images, int index) async {
  if (images.isEmpty) {
    return;
  }
  final initial = index.clamp(0, images.length - 1);
  await context.pushNamed(
    ScreenPaths.imageDetail,
    pathParameters: {'imageUrl': images[initial].url},
    extra: ImageGalleryArgs(images, initial),
  );
}

/// The route of the gallery ([ScreenPaths.imageDetail]): the pictures of a floor and the one tapped as its extra
/// ([ImageGalleryArgs], see [openImageGallery]), the picture of its path alone without them (a link to the route).
///
/// Over the page it opened from, which shows through while a picture is dragged down to close it; it fades in and out.
final class ImageGalleryRoute extends GoRoute {
  /// Constructor.
  ImageGalleryRoute()
    : super(
        name: ScreenPaths.imageDetail,
        path: ScreenPaths.imageDetail,
        pageBuilder: (context, state) {
          final args = state.extra is ImageGalleryArgs ? state.extra! as ImageGalleryArgs : null;
          final images = args?.images ?? [GalleryImage(state.pathParameters['imageUrl']!)];
          return CustomTransitionPage<void>(
            name: ScreenPaths.imageDetail,
            arguments: state.pathParameters,
            opaque: false,
            transitionDuration: const Duration(milliseconds: 200),
            reverseTransitionDuration: const Duration(milliseconds: 200),
            transitionsBuilder: (context, animation, secondaryAnimation, child) =>
                FadeTransition(opacity: animation, child: child),
            child: RootPage(
              ScreenPaths.imageDetail,
              ImageGalleryPage(images: images, initialIndex: args?.initialIndex ?? 0),
            ),
          );
        },
      );
}

/// Height to width above which a picture is a long one: shown as wide as the screen from its top, scrolled down.
const _longImageRatio = 1.2;

/// How far the picture is dragged down (or how fast) to close the gallery when let go.
const _dismissDistance = 120.0;
const _dismissVelocity = 900.0;

/// The pictures of a floor, full screen on black: swipe between them, pinch or double tap to zoom, drag down to close.
///
/// The system bars are hidden while it is open. A tap shows or hides the bar on top: close, "3 / 12", save, share and
/// the image sheet (copy the url, open it in the browser, reload, save to the user's images, its cache statistics).
/// A picture taller than the screen (a long strip) fills the width from its top and scrolls down; it closes when
/// dragged down from its top.
///
/// The pictures load as they are shown, with their progress, and a failed one is tapped to try again.
class ImageGalleryPage extends StatefulWidget {
  /// Constructor.
  const ImageGalleryPage({required this.images, this.initialIndex = 0, super.key});

  /// The pictures.
  final List<GalleryImage> images;

  /// The picture shown first.
  final int initialIndex;

  @override
  State<ImageGalleryPage> createState() => _ImageGalleryPageState();
}

class _ImageGalleryPageState extends State<ImageGalleryPage>
    with SingleTickerProviderStateMixin, LoggerMixin, RouteAware {
  late final PageController _pageController;
  late int _index;

  /// The zoom of each page, by index.
  final _zooms = <int, _PageZoom>{};

  /// The bar on top is shown.
  bool _chromeVisible = true;

  /// Pointers on the screen: with two, a pinch zooms and the pages do not turn.
  int _pointers = 0;

  /// The picture shown is zoomed in: it pans, the pages do not turn.
  bool _zoomed = false;

  /// How far the picture is dragged to close the gallery, and where the drag started.
  Offset _dragOffset = Offset.zero;
  Offset? _dragStart;
  late final AnimationController _dragBack;
  Animation<Offset>? _dragBackAnimation;

  /// The system bars are shown (the gallery left, or a page opened over it).
  bool _systemUiRestored = false;

  /// Leaving: the bars stay shown whatever comes.
  bool _leaving = false;

  PageRoute<dynamic>? _route;

  _PageZoom _zoomOf(int index) => _zooms.putIfAbsent(index, _PageZoom.new);

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, math.max(0, widget.images.length - 1));
    _pageController = PageController(initialPage: _index);
    _dragBack = AnimationController(vsync: this, duration: const Duration(milliseconds: 200))
      ..addListener(() {
        final animation = _dragBackAnimation;
        if (animation != null) {
          setState(() => _dragOffset = animation.value);
        }
      });
    _zoomOf(_index).transform.addListener(_onTransform);
    _hideSystemUi();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      if (_route != null) {
        routeObserver.unsubscribe(this);
      }
      _route = route;
      routeObserver.subscribe(this, route);
    }
  }

  /// The bars were given back to a page opened over the gallery.
  bool _shownForNext = false;

  // A page opened over the gallery (a link of the image sheet) has the bars of the app; they go again when it is back.
  // A sheet or a menu over it keeps them hidden: it is part of the gallery, the bars would only flash.
  @override
  void didPushNext() {
    final next = popupRouteObserver.lastPushed;
    if (next is PopupRoute<dynamic> || next is ModalSheetRoute<dynamic>) {
      return;
    }
    _shownForNext = true;
    _restoreSystemUi();
  }

  @override
  void didPopNext() {
    if (_shownForNext && !_leaving) {
      _shownForNext = false;
      _hideSystemUi();
    }
  }

  void _hideSystemUi() {
    _systemUiRestored = false;
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
  }

  @override
  void dispose() {
    _leaving = true;
    if (_route != null) {
      routeObserver.unsubscribe(this);
    }
    _restoreSystemUi();
    _zoomOf(_index).transform.removeListener(_onTransform);
    for (final zoom in _zooms.values) {
      zoom.dispose();
    }
    _dragBack.dispose();
    _pageController.dispose();
    super.dispose();
  }

  /// The system bars as the rest of the app has them (both shown), once.
  void _restoreSystemUi() {
    if (_systemUiRestored) {
      return;
    }
    _systemUiRestored = true;
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values));
  }

  void _onTransform() {
    final zoomed = _zoomOf(_index).zoomed;
    if (zoomed != _zoomed) {
      setState(() => _zoomed = zoomed);
    }
  }

  void _onPageChanged(int index) {
    _zoomOf(_index)
      ..transform.removeListener(_onTransform)
      // A page left goes back to its fit: it shows from the start when swiped back to.
      ..reset();
    _zoomOf(index).transform.addListener(_onTransform);
    setState(() {
      _index = index;
      _zoomed = _zoomOf(index).zoomed;
    });
  }

  /// Whether a drag down by [dy] starts closing the gallery: one finger, the picture not zoomed in and showing its top.
  bool _mayDismiss(double dy) {
    if (dy <= 0 || _pointers > 1) {
      return false;
    }
    final zoom = _zoomOf(_index);
    return !zoom.zoomed && zoom.atTop;
  }

  void _onDragStart(DragStartDetails details) {
    _dragBack.stop();
    _dragStart = details.globalPosition - _dragOffset;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final start = _dragStart;
    if (start == null) {
      return;
    }
    setState(() => _dragOffset = details.globalPosition - start);
  }

  void _onDragEnd(DragEndDetails details) {
    _dragStart = null;
    if (_dragOffset.dy > _dismissDistance || details.velocity.pixelsPerSecond.dy > _dismissVelocity) {
      _leaving = true;
      _restoreSystemUi();
      context.pop();
      return;
    }
    _dragBackAnimation = Tween<Offset>(
      begin: _dragOffset,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _dragBack, curve: Curves.easeOutCubic));
    unawaited(_dragBack.forward(from: 0));
  }

  void _onDragCancel() {
    _dragStart = null;
    if (_dragOffset != Offset.zero) {
      _onDragEnd(DragEndDetails());
    }
  }

  Future<void> _showStatistics(GalleryImage image) async {
    final tr = context.t.imageDetailPage;
    await showCopyContentDialogFutureBuilder(
      context: context,
      // Calling `then` is better than nested callback.
      // ignore: prefer_async_await
      contentFuture: getIt.get<ImageCacheProvider>().getEnsureCachedFullInfo(image.url).then((imageInfo) {
        if (imageInfo == null) {
          return const [];
        }
        return <CopyableContent>[
          CopyableContent(name: tr.url, data: imageInfo.url),
          CopyableContent(name: tr.cacheName, data: imageInfo.fileName),
          CopyableContent(name: tr.cacheSize, data: imageInfo.cacheSize),
          CopyableContent(
            name: tr.sizeTitle,
            data: tr.sizeValue(width: imageInfo.width, height: imageInfo.height),
          ),
        ];
      }),
      errorBuilder: (_, err) => Center(child: Text(tr.failedToLoadWithReason(reason: '$err'))),
      title: tr.statistics,
      route: DialogPaths.imageDetail,
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final tr = context.t.imageBottomSheet;
    final image = widget.images[_index];
    const foreground = Colors.white;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x99000000), Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: edgeInsetsL4R4.add(const EdgeInsets.only(bottom: 16)),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('image-gallery-close'),
                icon: const Icon(Icons.close, color: foreground),
                tooltip: context.t.general.close,
                onPressed: () {
                  _leaving = true;
                  _restoreSystemUi();
                  context.pop();
                },
              ),
              Expanded(
                child: Text(
                  context.t.imageGallery.counter(index: _index + 1, total: widget.images.length),
                  key: const ValueKey('image-gallery-counter'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(color: foreground),
                ),
              ),
              IconButton(
                key: const ValueKey('image-gallery-save'),
                icon: const Icon(Icons.save_alt_outlined, color: foreground),
                tooltip: tr.saveImage,
                onPressed: () async => saveImageOf(context, image.url),
              ),
              if (canShareImageFiles)
                Builder(
                  builder: (context) => IconButton(
                    key: const ValueKey('image-gallery-share'),
                    icon: const Icon(Icons.share_outlined, color: foreground),
                    tooltip: tr.shareImage,
                    onPressed: () async => shareImageOf(context, image.url, origin: shareOriginOf(context)),
                  ),
                ),
              IconButton(
                key: const ValueKey('image-gallery-more'),
                icon: const Icon(Icons.more_vert, color: foreground),
                tooltip: tr.title,
                onPressed: () async => showImageActionBottomSheet(
                  context: context,
                  imageUrl: image.url,
                  hrefUrl: image.linkUrl,
                  showCheckDetail: false,
                  onShowStatistics: () async => _showStatistics(image),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final progress = (_dragOffset.dy / (size.height * 0.4)).clamp(0.0, 1.0);
    final dragging = _dragOffset != Offset.zero;
    final pages = PageView.builder(
      controller: _pageController,
      // A pinch, or a picture zoomed in: the fingers move the picture, not the pages.
      physics: _pointers > 1 || _zoomed ? const NeverScrollableScrollPhysics() : null,
      itemCount: widget.images.length,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, index) => _GalleryImageView(
        key: ValueKey('image-gallery-page-$index'),
        image: widget.images[index],
        zoom: _zoomOf(index),
        onTap: () => setState(() => _chromeVisible = !_chromeVisible),
      ),
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Light icons on black, when the system bars are shown for a moment.
      value: SystemUiOverlayStyle.light,
      child: PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            _leaving = true;
            _restoreSystemUi();
          }
        },
        child: Material(
          color: Colors.black.withValues(alpha: 1 - progress * 0.85),
          child: Listener(
            onPointerDown: (_) => setState(() => _pointers++),
            onPointerUp: (_) => setState(() => _pointers = math.max(0, _pointers - 1)),
            onPointerCancel: (_) => setState(() => _pointers = math.max(0, _pointers - 1)),
            child: Stack(
              children: [
                Positioned.fill(
                  child: RawGestureDetector(
                    gestures: {
                      _DismissDragRecognizer: GestureRecognizerFactoryWithHandlers<_DismissDragRecognizer>(
                        () => _DismissDragRecognizer(mayStart: _mayDismiss, debugOwner: this),
                        (instance) => instance
                          ..dragStartBehavior = DragStartBehavior.down
                          ..onStart = _onDragStart
                          ..onUpdate = _onDragUpdate
                          ..onEnd = _onDragEnd
                          ..onCancel = _onDragCancel,
                      ),
                    },
                    child: Transform.translate(
                      key: const ValueKey('image-gallery-drag'),
                      offset: _dragOffset,
                      child: Transform.scale(scale: 1 - progress * 0.25, child: pages),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: IgnorePointer(
                    ignoring: !_chromeVisible || dragging,
                    child: AnimatedOpacity(
                      opacity: _chromeVisible && !dragging ? 1 : 0,
                      duration: duration100,
                      child: _buildTopBar(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A vertical drag that only starts closing the gallery when [mayStart] says so for how far the finger went down:
/// otherwise the picture takes the drag (a long one scrolls, a zoomed one pans).
class _DismissDragRecognizer extends VerticalDragGestureRecognizer {
  _DismissDragRecognizer({required this.mayStart, super.debugOwner});

  final bool Function(double dy) mayStart;

  Offset? _down;
  double _dy = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _down ??= event.position;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final down = _down;
    if (event is PointerMoveEvent && down != null) {
      _dy = event.position.dy - down.dy;
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) =>
      super.hasSufficientGlobalDistanceToAccept(pointerDeviceKind, deviceTouchSlop) && mayStart(_dy);

  @override
  void didStopTrackingLastPointer(int pointer) {
    _down = null;
    _dy = 0;
    super.didStopTrackingLastPointer(pointer);
  }
}

/// The zoom of a page of the gallery: its transform, and the size of what it shows.
final class _PageZoom {
  final transform = TransformationController();

  /// The scale the page is zoomed in to (1: fitted).
  double get scale => transform.value.getMaxScaleOnAxis();

  /// Zoomed in.
  bool get zoomed => scale > 1.01;

  /// The top of the picture is shown (one taller than the screen scrolled to its top, or one that fits).
  bool get atTop => transform.value.getTranslation().y > -0.5;

  /// Back to the picture fitted, from its top.
  void reset() => transform.value = Matrix4.identity();

  void dispose() => transform.dispose();
}

/// A picture of the gallery: fitted to the screen (a long one to its width, from its top), zoomed by a pinch or a
/// double tap.
class _GalleryImageView extends StatefulWidget {
  const _GalleryImageView({required this.image, required this.zoom, required this.onTap, super.key});

  final GalleryImage image;
  final _PageZoom zoom;
  final VoidCallback onTap;

  @override
  State<_GalleryImageView> createState() => _GalleryImageViewState();
}

class _GalleryImageViewState extends State<_GalleryImageView> with SingleTickerProviderStateMixin, LoggerMixin {
  /// Tallest a picture is decoded: the largest texture the GPUs of phones take.
  static const _maxDecodeHeight = 16384;

  /// Widest a picture is decoded: twice the longest side of the screen (it stays sharp zoomed in), from 2048 to 4096
  /// pixels. A photo of 20 megapixels decoded whole took 80 MB.
  int get _maxDecodeWidth {
    final screen = MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
    return (math.max(screen.width, screen.height) * 2).clamp(2048, 4096).round();
  }

  /// The picture, no larger than [_maxDecodeWidth] by [_maxDecodeHeight].
  ImageProvider get _provider => ResizeImage(
    CachedImageProvider(widget.image.url),
    width: _maxDecodeWidth,
    height: _maxDecodeHeight,
    policy: ResizeImagePolicy.fit,
  );

  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _imageSize;
  ImageChunkEvent? _progress;
  Object? _error;

  late final AnimationController _zoomAnimation;
  Animation<Matrix4>? _zoomTween;
  Offset? _doubleTapAt;

  /// The size of the page and of the picture fitted in it, of the last layout.
  Size _viewport = Size.zero;
  Size _content = Size.zero;

  @override
  void initState() {
    super.initState();
    _zoomAnimation = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
      ..addListener(() {
        final tween = _zoomTween;
        if (tween != null) {
          widget.zoom.transform.value = tween.value;
        }
      });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_GalleryImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.url != widget.image.url) {
      _unresolve();
      _resolve();
    }
  }

  @override
  void dispose() {
    _unresolve();
    _zoomAnimation.dispose();
    super.dispose();
  }

  void _resolve() {
    final provider = _provider;
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (_stream != null && stream.key == _stream!.key) {
      return;
    }
    _unresolve();
    final maxWidth = provider is ResizeImage ? provider.width : null;
    var adding = true;
    void update(VoidCallback change) => adding ? change() : setState(change);
    final listener = ImageStreamListener(
      (info, synchronousCall) {
        final size = Size(info.image.width.toDouble(), info.image.height.toDouble());
        info.dispose();
        if (!mounted || size == _imageSize) {
          return;
        }
        // The floor showing it again takes its place at once.
        ImageSizes.record(
          widget.image.url,
          size,
          // Exactly as wide as the bound may be its own width: taken as its own (wider than any floor anyway).
          downscaled: (maxWidth != null && size.width > maxWidth) || size.height > _maxDecodeHeight,
        );
        update(() {
          _imageSize = size;
          _progress = null;
          _error = null;
        });
      },
      onChunk: (event) {
        if (mounted && _imageSize == null) {
          update(() => _progress = event);
        }
      },
      onError: (e, st) {
        if (!mounted) {
          return;
        }
        handleRaw(e, st);
        update(() => _error = e);
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
    adding = false;
  }

  void _unresolve() {
    if (_listener case final listener?) {
      _stream?.removeListener(listener);
    }
    _stream = null;
    _listener = null;
  }

  /// Load the picture again: the failed load goes from the image cache first.
  Future<void> _retry() async {
    await _provider.evict();
    if (!mounted) {
      return;
    }
    _unresolve();
    setState(() {
      _error = null;
      _progress = null;
      _imageSize = null;
    });
    _resolve();
  }

  /// [image] fitted in [viewport]: as wide as it when the picture is long, whole in it otherwise.
  static Size _fit(Size image, Size viewport, {required bool long}) {
    final aspectRatio = image.width / image.height;
    if (long || aspectRatio > viewport.width / viewport.height) {
      return Size(viewport.width, viewport.width / aspectRatio);
    }
    return Size(viewport.height * aspectRatio, viewport.height);
  }

  /// Zoom in where double tapped, or back to the picture fitted (a long one stays where it was scrolled to).
  void _toggleZoom() {
    final zoom = widget.zoom;
    final current = zoom.transform.value.clone();
    final Matrix4 target;
    if (zoom.zoomed) {
      final scale = zoom.scale;
      final top = math.min<double>(0, _viewport.height - _content.height);
      final y = (current.getTranslation().y / scale).clamp(top, 0).toDouble();
      target = Matrix4.identity()..translateByDouble(0, y, 0, 1);
    } else {
      // Twice as large at least, or as large as the screen for a picture narrower than it.
      final fill = _content.width > 0 && _content.height > 0
          ? math.max(_viewport.width / _imageFittedWidth, _viewport.height / _imageFittedHeight)
          : 2.0;
      final scale = math.max<double>(2.5, math.min<double>(fill, 4));
      final at = _doubleTapAt ?? _viewport.center(Offset.zero);
      final scene = zoom.transform.toScene(at);
      final left = math.min<double>(0, _viewport.width - _content.width * scale);
      final top = math.min<double>(0, _viewport.height - _content.height * scale);
      final x = (at.dx - scene.dx * scale).clamp(left, 0).toDouble();
      final y = (at.dy - scene.dy * scale).clamp(top, 0).toDouble();
      target = Matrix4.identity()
        ..translateByDouble(x, y, 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    }
    _zoomTween = Matrix4Tween(
      begin: current,
      end: target,
    ).animate(CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeOutCubic));
    unawaited(_zoomAnimation.forward(from: 0));
  }

  double _imageFittedWidth = 1;
  double _imageFittedHeight = 1;

  Widget _buildStatus(BuildContext context) {
    final tr = context.t.imageGallery;
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white70);
    if (_error != null) {
      final message = getIt.get<ImageCacheProvider>().htmlMessageOf(widget.image.url);
      return Center(
        child: InkWell(
          key: const ValueKey('image-gallery-retry'),
          borderRadius: BorderRadius.circular(12),
          onTap: _retry,
          child: Padding(
            padding: edgeInsetsL16T16R16B16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.refresh, color: Colors.white70, size: 40),
                sizedBoxW8H8,
                Text(tr.failedTapToRetry, style: textStyle, textAlign: TextAlign.center),
                if (message != null && message.isNotEmpty) ...[
                  sizedBoxW4H4,
                  Text(message, style: textStyle, textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
        ),
      );
    }
    final progress = _progress;
    final total = progress?.expectedTotalBytes;
    final value = progress != null && total != null && total > 0
        ? (progress.cumulativeBytesLoaded / total).clamp(0.0, 1.0)
        : null;
    return Center(
      child: Column(
        key: const ValueKey('image-gallery-loading'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 40,
            child: CircularProgressIndicator(
              value: value,
              color: Colors.white,
              backgroundColor: Colors.white24,
              strokeWidth: 3,
            ),
          ),
          if (value != null) ...[
            sizedBoxW8H8,
            Text(tr.percent(value: (value * 100).floor()), style: textStyle),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final imageSize = _imageSize;
    final Widget body;
    if (imageSize == null) {
      body = _buildStatus(context);
    } else {
      body = LayoutBuilder(
        builder: (context, constraints) {
          final viewport = constraints.biggest;
          final widthFitted = viewport.width * imageSize.height / imageSize.width;
          final long = widthFitted > viewport.height * _longImageRatio;
          final fitted = _fit(imageSize, viewport, long: long);
          final content = Size(viewport.width, math.max(viewport.height, fitted.height));
          _viewport = viewport;
          _content = content;
          _imageFittedWidth = fitted.width;
          _imageFittedHeight = fitted.height;
          // Up to the picture's own pixels twice over, at least three times the screen.
          final maxScale = (imageSize.width / fitted.width * 2).clamp(3, 8).toDouble();
          return InteractiveViewer(
            transformationController: widget.zoom.transform,
            constrained: false,
            minScale: 1,
            maxScale: maxScale,
            child: SizedBox.fromSize(
              size: content,
              child: Align(
                alignment: long ? Alignment.topCenter : Alignment.center,
                child: SizedBox.fromSize(
                  size: fitted,
                  child: Image(
                    image: _provider,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          );
        },
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTapDown: imageSize == null ? null : (details) => _doubleTapAt = details.localPosition,
      onDoubleTap: imageSize == null ? null : _toggleZoom,
      child: body,
    );
  }
}
