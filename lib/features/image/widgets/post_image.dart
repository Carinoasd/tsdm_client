import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/int.dart';
import 'package:tsdm_client/features/image/models/gallery_image.dart';
import 'package:tsdm_client/features/image/utils/image_sizes.dart';
import 'package:tsdm_client/features/image/view/image_gallery_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/post_image_auto_load.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/utils/network_usage.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';

/// Width to height of a picture whose size is not known before it loads: the one of most photos.
const double defaultImageAspectRatio = 4 / 3;

/// A picture no larger than this on both sides is an icon, not a picture of the post: it stays out of the gallery.
const smallImageMaxSide = 48.0;

/// Whether a picture of [width] by [height] (either may be unknown) is an icon by its size ([smallImageMaxSide]).
bool isSmallImage({double? width, double? height}) {
  if (width != null && height != null) {
    return width <= smallImageMaxSide && height <= smallImageMaxSide;
  }
  // Only one side given: a narrow one is an icon in a line of text.
  return (width ?? height ?? double.infinity) <= smallImageMaxSide * 2 / 3;
}

/// Whether the image at [url] is one of the forum's own (a smiley, an icon of a file type, a button): not a picture of
/// the post, never in the gallery.
bool isForumStaticImage(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  return path.contains('/static/image/') || path.contains('/smiley/');
}

/// The box a picture of a post takes before it is there, to keep its place: the floor does not move when it comes.
///
/// Known, best first: the size it was decoded at in this run ([known], the picture the floor shows), the size of the
/// attachment the forum gives (the [image] itself; only its aspect ratio for a thumbnail), the `width` and `height`
/// of the `<img>` ([declaredWidth], [declaredHeight]). Otherwise [defaultImageAspectRatio] as wide as there is room
/// (or as [declaredWidth]).
({double aspectRatio, double? width}) reservedImageBoxOf(
  GalleryImage image, {
  KnownImageSize? known,
  double? declaredWidth,
  double? declaredHeight,
}) {
  if (known != null) {
    return (aspectRatio: known.aspectRatio, width: known.width);
  }
  final width = image.width;
  final height = image.height;
  if (width != null && height != null && width > 0 && height > 0) {
    return (aspectRatio: width / height, width: image.hasThumbnail ? null : width.toDouble());
  }
  if (declaredWidth != null && declaredHeight != null && declaredWidth > 0 && declaredHeight > 0) {
    return (aspectRatio: declaredWidth / declaredHeight, width: declaredWidth);
  }
  return (aspectRatio: defaultImageAspectRatio, width: declaredWidth);
}

/// The pictures of the content of one floor shown now, for the gallery a tap on one opens ([PostImageScope]).
///
/// Each [PostImage] adds itself while it is built: the pictures in the floor's quotes are there, those in a fold only
/// once it is opened. A picture munched from the floor knows its place in its part of the floor (`order`), and the part
/// is told by [PostImagePart]: the gallery lists them in the order of the floor, whenever they were built.
final class FloorImages {
  /// Constructor.
  FloorImages([List<PostAttachment> attachments = const []]) {
    updateAttachments(attachments);
  }

  /// The attachments of the floor, by id: their thumbnail and size for its pictures munched from its html.
  Map<int, PostAttachment> _attachments = const {};

  /// The floor's attachments are [value] now (the floor was edited).
  void updateAttachments(List<PostAttachment> value) => _attachments = {for (final e in value) e.aid: e};

  /// The attachment [aid] of the floor, null when the floor has none such.
  PostAttachment? attachmentOf(int aid) => _attachments[aid];

  final _shown = <_PostImageState>{};

  /// Pictures shown now.
  int get length => _shown.length;

  void _add(_PostImageState image) => _shown.add(image);

  void _remove(_PostImageState image) => _shown.remove(image);

  /// The gallery a tap on [tapped] opens: the pictures shown now in the floor's order, without those known small (an
  /// icon whose size said nothing before it loaded), and where [tapped] is in them.
  ({List<GalleryImage> images, int index}) _galleryFor(_PostImageState tapped) {
    final shown = [
      for (final image in _shown)
        if (identical(image, tapped) || !image._knownSmall) image,
    ]..sort((a, b) => a._part != b._part ? a._part.compareTo(b._part) : a.widget.order.compareTo(b.widget.order));
    return (images: [for (final e in shown) e.widget.image], index: math.max(0, shown.indexOf(tapped)));
  }
}

/// The pictures of a floor's content ([FloorImages]) and when they load by themselves ([autoLoad]), for the
/// [PostImage]s in it.
class PostImageScope extends InheritedWidget {
  /// Constructor.
  const PostImageScope({required this.images, required this.autoLoad, required super.child, super.key});

  /// The pictures of the floor.
  final FloorImages images;

  /// When they load by themselves.
  final PostImageAutoLoad autoLoad;

  /// The scope above [context], without depending on it (the muncher reading the attachments).
  static PostImageScope? find(BuildContext context) => context.getInheritedWidgetOfExactType<PostImageScope>();

  /// The scope above [context], null when the picture is not in a floor (a message, a notice).
  static PostImageScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PostImageScope>();

  @override
  bool updateShouldNotify(PostImageScope oldWidget) =>
      !identical(images, oldWidget.images) || autoLoad != oldWidget.autoLoad;
}

/// Which part of a floor its content below is ([PostImage]s in a lower part come first in the gallery): the html before
/// a message drawn from its bbcode, the message, the html after it (the attachments listed below).
class PostImagePart extends InheritedWidget {
  /// Constructor.
  const PostImagePart({required this.part, required super.child, super.key});

  /// The part.
  final int part;

  /// The part of [context], 0 when none is told.
  static int of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PostImagePart>()?.part ?? 0;

  @override
  bool updateShouldNotify(PostImagePart oldWidget) => part != oldWidget.part;
}

/// A picture of a post: it keeps its place before it is there ([reservedImageBoxOf]), shows the progress of its
/// download, and a failed one is tapped to load again.
///
/// A tap opens the gallery of its floor at it ([PostImageScope], the picture alone outside a floor); a picture in a
/// link to a page opens the link. A long press (a secondary tap on desktop) opens the image sheet.
///
/// In a floor, it loads by itself as the reader set it ([PostImageAutoLoad]): a picture that does not shows a
/// placeholder to tap (with its size when the forum tells it), unless it is cached already. The floor shows the
/// thumbnail the forum made of an attachment, the gallery the attachment itself.
class PostImage extends StatefulWidget {
  /// Constructor.
  const PostImage(this.image, {required this.order, this.declaredWidth, this.declaredHeight, super.key});

  /// The picture.
  final GalleryImage image;

  /// Its place in the part of the floor it was munched from.
  final int order;

  /// The `width` of the `<img>` (`[img=w,h]`): the picture is shown at most this wide.
  final double? declaredWidth;

  /// The `height` of the `<img>`: the picture is shown at most this tall.
  final double? declaredHeight;

  @override
  State<PostImage> createState() => _PostImageState();
}

class _PostImageState extends State<PostImage> {
  FloorImages? _floor;
  PostImageAutoLoad _autoLoad = PostImageAutoLoad.always;
  int _part = 0;

  /// Tapped to load while it would not load by itself.
  bool _requested = false;

  /// Its size is known to be an icon's (it loaded, or loaded before in this run).
  bool get _knownSmall {
    final known = ImageSizes.of(widget.image.floorUrl);
    final width = known?.width;
    return known != null && width != null && isSmallImage(width: width, height: width / known.aspectRatio);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = PostImageScope.maybeOf(context);
    _part = PostImagePart.of(context);
    final floor = scope?.images;
    if (!identical(floor, _floor)) {
      _floor?._remove(this);
      _floor = floor?.._add(this);
    }
    final autoLoad = scope?.autoLoad ?? PostImageAutoLoad.always;
    if (autoLoad != _autoLoad) {
      _autoLoad = autoLoad;
      _listenToNetwork();
    } else if (autoLoad == PostImageAutoLoad.wifiOnly) {
      NetworkUsage.refreshIfStale();
    }
  }

  /// Listening to [NetworkUsage] (the pictures load by themselves on Wi-Fi only).
  bool _listening = false;

  void _listenToNetwork() {
    if (_autoLoad == PostImageAutoLoad.wifiOnly) {
      NetworkUsage.refreshIfStale();
      if (!_listening) {
        NetworkUsage.unmetered.addListener(_onNetworkCost);
        _listening = true;
      }
    } else if (_listening) {
      NetworkUsage.unmetered.removeListener(_onNetworkCost);
      _listening = false;
    }
  }

  void _onNetworkCost() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _floor?._remove(this);
    if (_listening) {
      NetworkUsage.unmetered.removeListener(_onNetworkCost);
    }
    super.dispose();
  }

  /// Whether the picture is fetched now when not cached; null while the network is being asked about.
  bool? get _fetches {
    if (_requested || _floor == null) {
      return true;
    }
    return switch (_autoLoad) {
      PostImageAutoLoad.always => true,
      PostImageAutoLoad.never => false,
      PostImageAutoLoad.wifiOnly => NetworkUsage.unmetered.value,
    };
  }

  /// The link the picture is in leads to a page, not to a picture: a tap opens it, as a link.
  bool get _linksToPage {
    final link = widget.image.linkUrl;
    if (link == null || link == widget.image.url || link == widget.image.floorUrl) {
      return false;
    }
    final uri = Uri.tryParse(link);
    if (uri == null) {
      return false;
    }
    if (uri.queryParameters['mod'] == 'attachment') {
      return false;
    }
    final path = uri.path.toLowerCase();
    return !const ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.avif'].any(path.endsWith);
  }

  Future<void> _openGallery() async {
    final floor = _floor;
    if (floor == null) {
      await openImageGallery(context, [widget.image], 0);
      return;
    }
    final gallery = floor._galleryFor(this);
    await openImageGallery(context, gallery.images, gallery.index);
  }

  Future<void> _onTap() async {
    if (_linksToPage) {
      await context.dispatchAsUrl(widget.image.linkUrl!);
      return;
    }
    if (_knownSmall) {
      await _showSheet();
      return;
    }
    await _openGallery();
  }

  Future<void> _showSheet() async => showImageActionBottomSheet(
    context: context,
    imageUrl: widget.image.url,
    hrefUrl: widget.image.linkUrl,
    onCheckDetail: _openGallery,
  );

  void _load() => setState(() => _requested = true);

  @override
  Widget build(BuildContext context) {
    final image = widget.image;
    final box = reservedImageBoxOf(
      image,
      known: ImageSizes.of(image.floorUrl),
      declaredWidth: widget.declaredWidth,
      declaredHeight: widget.declaredHeight,
    );
    final fetches = _fetches;
    final cached = NetworkIndicatorImage(
      image.floorUrl,
      cacheOnly: fetches != true,
      placeholderBuilder: (context, progress) => ImageReservedBox(
        aspectRatio: box.aspectRatio,
        width: box.width,
        child: _ImageLoading(progress),
      ),
      errorBuilder: (context, error, retry) => ImageReservedBox(
        aspectRatio: box.aspectRatio,
        width: box.width,
        child: switch (fetches) {
          // Not cached, and the network is being asked about: tapping comes once it answered.
          null => const _ImageLoading(null),
          false => _TapToLoad(image: image, onTap: _load),
          true => _ImageFailed(url: image.floorUrl, onRetry: retry),
        },
      ),
      onImageSize: (size, {required downscaled}) => ImageSizes.record(image.floorUrl, size, downscaled: downscaled),
    );
    return MouseRegion(
      cursor: _linksToPage ? SystemMouseCursors.click : SystemMouseCursors.zoomIn,
      child: GestureDetector(
        onTap: _onTap,
        onLongPress: _showSheet,
        onSecondaryTap: isDesktop ? _showSheet : null,
        // At most as large as the `<img>` says, the placeholder too; decoded as wide as the floor shows it.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: widget.declaredWidth ?? double.infinity,
            maxHeight: widget.declaredHeight ?? double.infinity,
          ),
          child: cached,
        ),
      ),
    );
  }
}

/// The placeholder of a picture loading: the progress of its download once bytes arrive.
class _ImageLoading extends StatelessWidget {
  const _ImageLoading(this.progress);

  final ImageChunkEvent? progress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final progress = this.progress;
    final Widget content;
    if (progress == null) {
      content = Icon(Icons.image_outlined, size: 32, color: colorScheme.outlineVariant);
    } else {
      final total = progress.expectedTotalBytes;
      final value = total != null && total > 0 ? progress.cumulativeBytesLoaded / total : null;
      content = Column(
        key: const ValueKey('post-image-progress'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 32,
            child: CircularProgressIndicator(value: value, strokeWidth: 3, color: colorScheme.primary),
          ),
          const SizedBox(height: 6),
          Text(
            value == null
                ? progress.cumulativeBytesLoaded.withSizeHint()
                : context.t.imageGallery.percent(value: (value * 100).floor()),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ],
      );
    }
    return _PlaceholderSurface(child: content);
  }
}

/// The placeholder of a picture that did not load: tapped, it loads again.
class _ImageFailed extends StatelessWidget {
  const _ImageFailed({required this.url, required this.onRetry});

  final String url;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // When the server answered with a page (e.g. attachments in a paid thread) show its message.
    final message = getIt.get<ImageCacheProvider>().htmlMessageOf(url);
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant);
    return GestureDetector(
      key: const ValueKey('post-image-retry'),
      behavior: HitTestBehavior.opaque,
      onTap: onRetry,
      child: _PlaceholderSurface(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.refresh, size: 28, color: colorScheme.primary),
            const SizedBox(height: 4),
            Text(context.t.imageGallery.failedTapToRetry, style: style, textAlign: TextAlign.center),
            if (message != null && message.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(message, style: style, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ],
        ),
      ),
    );
  }
}

/// The placeholder of a picture that does not load by itself (the data saver): tapped, it loads. Tells its size and
/// its dimensions when the forum gives them (an attachment shown whole).
class _TapToLoad extends StatelessWidget {
  const _TapToLoad({required this.image, required this.onTap});

  final GalleryImage image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.imageGallery;
    final colorScheme = Theme.of(context).colorScheme;
    final fileSize = image.hasThumbnail ? null : image.fileSize;
    final width = image.width;
    final height = image.height;
    final details = [
      if (fileSize != null && fileSize > 0) fileSize.withSizeHint(),
      if (!image.hasThumbnail && width != null && height != null && width > 0 && height > 0) '$width × $height',
    ].join(' · ');
    return GestureDetector(
      key: const ValueKey('post-image-tap-to-load'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: _PlaceholderSurface(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_outlined, size: 28, color: colorScheme.primary),
            const SizedBox(height: 4),
            Text(
              tr.tapToLoad,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(color: colorScheme.primary),
              textAlign: TextAlign.center,
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                details,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The surface of a placeholder: its content scaled down to fit a small one.
class _PlaceholderSurface extends StatelessWidget {
  const _PlaceholderSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Center(
        child: FittedBox(fit: BoxFit.scaleDown, child: child),
      ),
    ),
  );
}

/// The box a picture takes before it is there: [aspectRatio] (width to height), as wide as there is room or as
/// [width], whichever is narrower; [child] fills it.
///
/// Asked how wide it is (a table working out its columns), it is [width], or [fallbackWidth] when that is not known; in
/// an unbounded width it takes that too. Laid out its own way, not with a `LayoutBuilder`, which a paragraph asking its
/// spans for their width would break.
class ImageReservedBox extends SingleChildRenderObjectWidget {
  /// Constructor.
  const ImageReservedBox({required this.aspectRatio, this.width, super.child, super.key});

  /// Width to height.
  final double aspectRatio;

  /// The width at most; null: as wide as there is room.
  final double? width;

  /// Width of a box whose [width] is not known where it is asked or there is no limit to it.
  static const double fallbackWidth = 320;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderImageReservedBox(aspectRatio, width);

  @override
  void updateRenderObject(BuildContext context, RenderImageReservedBox renderObject) => renderObject
    ..aspectRatio = aspectRatio
    ..width = width;
}

/// The render object of [ImageReservedBox].
class RenderImageReservedBox extends RenderProxyBox {
  /// Constructor.
  RenderImageReservedBox(this._aspectRatio, this._width);

  /// Width to height.
  double get aspectRatio => _aspectRatio;
  double _aspectRatio;
  set aspectRatio(double value) {
    if (value != _aspectRatio) {
      _aspectRatio = value;
      markNeedsLayout();
    }
  }

  /// The width at most; null: as wide as there is room.
  double? get width => _width;
  double? _width;
  set width(double? value) {
    if (value != _width) {
      _width = value;
      markNeedsLayout();
    }
  }

  double get _ratio => _aspectRatio.isFinite && _aspectRatio > 0 ? _aspectRatio : defaultImageAspectRatio;

  double get _preferredWidth => _width ?? ImageReservedBox.fallbackWidth;

  Size _sizeFor(BoxConstraints constraints) {
    final maxWidth = constraints.maxWidth;
    var width = _width ?? (maxWidth.isFinite ? maxWidth : ImageReservedBox.fallbackWidth);
    if (maxWidth.isFinite) {
      width = math.min(width, maxWidth);
    }
    var height = width / _ratio;
    if (height > constraints.maxHeight) {
      height = constraints.maxHeight;
      width = height * _ratio;
    }
    return constraints.constrain(Size(width, height));
  }

  @override
  double computeMinIntrinsicWidth(double height) => height.isFinite ? height * _ratio : _preferredWidth;

  @override
  double computeMaxIntrinsicWidth(double height) => height.isFinite ? height * _ratio : _preferredWidth;

  @override
  double computeMinIntrinsicHeight(double width) => (width.isFinite ? width : _preferredWidth) / _ratio;

  @override
  double computeMaxIntrinsicHeight(double width) => (width.isFinite ? width : _preferredWidth) / _ratio;

  @override
  Size computeDryLayout(BoxConstraints constraints) => _sizeFor(constraints);

  @override
  void performLayout() {
    size = _sizeFor(constraints);
    child?.layout(BoxConstraints.tight(size));
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DoubleProperty('aspectRatio', _aspectRatio))
      ..add(DoubleProperty('width', _width));
  }
}
