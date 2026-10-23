import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/network_usage.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/cached_image/cover_resize_image.dart';

/// The side of the thumbnail at the default text size, in logical pixels.
const threadPreviewThumbnailBaseExtent = 64.0;

/// The largest side of the thumbnail, reached with a large text size.
const threadPreviewThumbnailMaxExtent = 96.0;

/// The preview of a thread under its title in a thread card (the forum's app API, plugin 3.1.0): the excerpt of its
/// first floor in two lines, in the text size of the floors (the body text, which follows the app's text size) and
/// the secondary color, and one thumbnail of its images on the right, "+N" in its corner when the floor has more.
///
/// Nothing at all for a preview the plugin withheld ([ThreadPreview.withheld]: the reason is never told), nor when the
/// settings hide both parts ([showExcerpt], [thumbnailMode]). The thumbnail is an attachment of the floor, an image of
/// another site only with [externalImages] ([ThreadPreview.thumbnailOf]). The thumbnail "on Wi-Fi only" shows on a network the
/// system does not count as metered ([NetworkUsage]). The thumbnail has no gesture of its own: a tap on it is a tap on
/// the card, which opens the thread.
class ThreadPreviewSection extends StatelessWidget {
  /// Constructor.
  const ThreadPreviewSection(
    this.preview, {
    required this.showExcerpt,
    required this.thumbnailMode,
    this.externalImages = false,
    super.key,
  });

  /// The preview.
  final ThreadPreview preview;

  /// Whether the excerpt is shown ([SettingsKeys.threadCardShowExcerpt]).
  final bool showExcerpt;

  /// When the thumbnail is shown ([SettingsKeys.threadCardThumbnailMode]).
  final ThreadThumbnailMode thumbnailMode;

  /// Whether the thumbnail may be an image of another site ([SettingsKeys.threadCardExternalThumbnails]).
  final bool externalImages;

  /// Whether a card shows something of [preview] with these settings: the excerpt, or a thumbnail (which "on Wi-Fi
  /// only" still waits for the network). A card leaves the section out otherwise.
  static bool shows(
    ThreadPreview? preview, {
    required bool showExcerpt,
    required ThreadThumbnailMode thumbnailMode,
    bool externalImages = false,
  }) =>
      preview != null &&
      !preview.withheld &&
      ((showExcerpt && preview.excerptText.isNotEmpty) ||
          (thumbnailMode != ThreadThumbnailMode.never && preview.thumbnailOf(external: externalImages) != null));

  @override
  Widget build(BuildContext context) {
    if (!shows(preview, showExcerpt: showExcerpt, thumbnailMode: thumbnailMode, externalImages: externalImages)) {
      return sizedBoxEmpty;
    }
    final excerpt = showExcerpt ? preview.excerptText : '';
    final image = thumbnailMode == ThreadThumbnailMode.never ? null : preview.thumbnailOf(external: externalImages);
    final more = preview.moreImagesOf(external: externalImages);
    if (image == null || thumbnailMode == ThreadThumbnailMode.always) {
      return _PreviewRow(excerpt: excerpt, image: image, more: more);
    }
    return _OnUnmeteredNetwork(
      builder: (context, {required unmetered}) =>
          _PreviewRow(excerpt: excerpt, image: unmetered ? image : null, more: more),
    );
  }
}

/// Builds with whether the device is on a network that does not count the data ([NetworkUsage.unmetered]; false until
/// the first answer), and asks again when the last answer is old.
class _OnUnmeteredNetwork extends StatefulWidget {
  const _OnUnmeteredNetwork({required this.builder});

  final Widget Function(BuildContext context, {required bool unmetered}) builder;

  @override
  State<_OnUnmeteredNetwork> createState() => _OnUnmeteredNetworkState();
}

class _OnUnmeteredNetworkState extends State<_OnUnmeteredNetwork> {
  @override
  void initState() {
    super.initState();
    NetworkUsage.refreshIfStale();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool?>(
    valueListenable: NetworkUsage.unmetered,
    builder: (context, unmetered, _) => widget.builder(context, unmetered: unmetered ?? false),
  );
}

/// The excerpt, and the thumbnail on its right.
class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.excerpt, required this.image, required this.more});

  final String excerpt;
  final ThreadPreviewImage? image;
  final int more;

  @override
  Widget build(BuildContext context) {
    final image = this.image;
    if (excerpt.isEmpty && image == null) {
      return sizedBoxEmpty;
    }
    final theme = Theme.of(context);
    if (excerpt.isEmpty) {
      // The pictures of a floor without text: the thumbnail under the title, where the text would start.
      return Padding(
        padding: edgeInsetsL16R16B12,
        child: LayoutBuilder(
          builder: (context, constraints) => Align(
            alignment: AlignmentDirectional.centerStart,
            child: ThreadPreviewThumbnail(
              image!,
              extent: threadPreviewThumbnailExtent(context, constraints.maxWidth),
              more: more,
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: edgeInsetsL16R16B12,
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                excerpt,
                key: const ValueKey('thread-preview-excerpt'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ),
            if (image != null) ...[
              sizedBoxW12H12,
              ThreadPreviewThumbnail(
                image,
                extent: threadPreviewThumbnailExtent(context, constraints.maxWidth),
                more: more,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The side of the thumbnail of a preview in a row [width] wide: [threadPreviewThumbnailBaseExtent] at the default
/// text size, growing with the text size up to [threadPreviewThumbnailMaxExtent], and never more than a third of the
/// row, so a narrow screen with a large text size keeps most of the row for the excerpt.
double threadPreviewThumbnailExtent(BuildContext context, double width) {
  final scaled = MediaQuery.textScalerOf(
    context,
  ).scale(threadPreviewThumbnailBaseExtent).clamp(threadPreviewThumbnailBaseExtent, threadPreviewThumbnailMaxExtent);
  return width.isFinite ? math.min(scaled, width / 3) : scaled;
}

/// The thumbnail of a preview [image]: a square of [extent] with rounded corners, the picture covering it, decoded no
/// larger than the square on this screen ([CoverResizeImage]), and "+[more]" in its lower right corner when the
/// floor has more images.
///
/// Loaded and cached as the images of the floors are ([CachedImageProvider]); a tinted square until it arrives, an
/// icon when it fails. An image without url (the example of the settings) is drawn as a picture placeholder.
class ThreadPreviewThumbnail extends StatelessWidget {
  /// Constructor.
  const ThreadPreviewThumbnail(this.image, {required this.extent, this.more = 0, super.key});

  /// The image.
  final ThreadPreviewImage image;

  /// The side of the square, in logical pixels.
  final double extent;

  /// How many images the floor has besides this one.
  final int more;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final Widget picture;
    if (image.url.isEmpty) {
      picture = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [colorScheme.primaryContainer, colorScheme.tertiaryContainer],
          ),
        ),
        child: Icon(Icons.landscape_outlined, color: colorScheme.onPrimaryContainer, size: extent / 2),
      );
    } else {
      picture = Image(
        image: CoverResizeImage(
          CachedImageProvider(image.url),
          extent: (extent * MediaQuery.devicePixelRatioOf(context)).ceil(),
        ),
        fit: BoxFit.cover,
        width: extent,
        height: extent,
        excludeFromSemantics: true,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) => wasSynchronouslyLoaded
            ? child
            : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: duration100, child: child),
        errorBuilder: (context, error, stackTrace) => Center(
          child: Icon(Icons.broken_image_outlined, color: colorScheme.outline, size: extent / 3),
        ),
      );
    }
    return Semantics(
      image: true,
      label: context.t.threadCard.previewImages(count: more + 1),
      child: ClipRRect(
        key: const ValueKey('thread-preview-thumbnail'),
        borderRadius: BorderRadius.circular(8),
        child: SizedBox.square(
          dimension: extent,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: colorScheme.surfaceContainerHighest),
              picture,
              if (more > 0) Positioned(right: 4, bottom: 4, child: _MoreImages(more)),
            ],
          ),
        ),
      ),
    );
  }
}

/// "+N" on a thumbnail: white on a dark scrim, readable on any picture in both themes.
class _MoreImages extends StatelessWidget {
  const _MoreImages(this.count);

  final int count;

  @override
  Widget build(BuildContext context) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: 1.4,
    child: DecoratedBox(
      key: const ValueKey('thread-preview-more'),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62), borderRadius: BorderRadius.circular(6)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          '+$count',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );
}
