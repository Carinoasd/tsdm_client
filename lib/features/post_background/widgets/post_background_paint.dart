import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/post_background/models/post_background.dart';
import 'package:tsdm_client/features/post_background/utils/still_image.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/shared/models/data_saver_mode.dart';
import 'package:tsdm_client/shared/models/post_image_auto_load.dart';
import 'package:tsdm_client/utils/html/author_style.dart';
import 'package:tsdm_client/utils/network_usage.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/bounded_resize_image.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';

/// The least opacity of the veil over a floor's background, whatever the theme: the background stays decoration.
const postBackgroundMinVeilOpacity = 0.7;

/// The widest and highest a floor's background is decoded at (the pictures of the background shop are some hundred
/// pixels wide): one decoded picture per author and size, shared by the author's floors.
const postBackgroundMaxDecodeSide = 2048;

/// Contrast the body text keeps on the veiled background (on its darkest or lightest pixel): WCAG AA, AAA with the
/// platform's high contrast.
const double postBackgroundBodyContrast = readableContrast;

/// Contrast the secondary text (the time, the user group: the theme's `outline`) keeps there, more with the platform's
/// high contrast.
const postBackgroundSecondaryContrast = 3.0;

/// The opacity of a veil of [surface] (the floor's own color) over a background for [texts] to read on it, each with
/// the contrast paired with it, whatever the background's pixels are (from black to white): the least such opacity,
/// at least [postBackgroundMinVeilOpacity]; 1 when none less does. A text that does not reach its contrast on [surface]
/// itself needs only the contrast it has there.
double postBackgroundVeilOpacity(Color surface, List<(Color, double)> texts) {
  bool reads(double opacity) {
    final veil = surface.withValues(alpha: opacity);
    final darkest = Color.alphaBlend(veil, const Color(0xFF000000));
    final lightest = Color.alphaBlend(veil, const Color(0xFFFFFFFF));
    final low = relativeLuminance(darkest);
    final high = relativeLuminance(lightest);
    for (final (text, contrast) in texts) {
      final needed = math.min(contrast, contrastRatio(text, surface));
      final l = relativeLuminance(text);
      // A pixel between the two makes the veiled background as light as the text.
      if (l >= low && l <= high) {
        return false;
      }
      if (math.min(contrastRatio(text, darkest), contrastRatio(text, lightest)) < needed) {
        return false;
      }
    }
    return true;
  }

  for (var opacity = postBackgroundMinVeilOpacity; opacity < 1; opacity += 0.01) {
    if (reads(opacity)) {
      return opacity;
    }
  }
  return 1;
}

/// The veil over a floor's background in [theme]: the color of the floor's surface (a [Card]) at the opacity the
/// floor's texts need ([postBackgroundVeilOpacity]): the body text (`onSurface`), the name (`primary`) and the
/// secondary text (`outline`).
Color postBackgroundVeil(ThemeData theme, {bool highContrast = false}) {
  final scheme = theme.colorScheme;
  final surface = theme.cardTheme.color ?? scheme.surfaceContainerLow;
  final body = highContrast ? 7.0 : postBackgroundBodyContrast;
  final secondary = highContrast ? readableContrast : postBackgroundSecondaryContrast;
  final key = (surface, scheme.onSurface, scheme.primary, scheme.outline, highContrast);
  final cached = _veils[key];
  if (cached != null) {
    return cached;
  }
  final veil = surface.withValues(
    alpha: postBackgroundVeilOpacity(surface, [
      (scheme.onSurface, body),
      (scheme.primary, body),
      (scheme.outline, secondary),
    ]),
  );
  if (_veils.length > 16) {
    _veils.clear();
  }
  return _veils[key] = veil;
}

final _veils = <(Color, Color, Color, Color, bool), Color>{};

/// Which part of the floor a background is behind: the corners it shares with the floor's rounded surface.
enum PostBackgroundPart {
  /// The author row, at the top of the floor.
  top,

  /// The content and what follows it, down to the bottom of the floor.
  bottom,
}

/// [child] with the floor's background [layer] painted behind it, under a veil of the floor's own color
/// ([postBackgroundVeil]): decoration only, it never changes the size of [child] (a [DecoratedBox] takes the size of
/// its child) and draws nothing until (or unless) its picture loads. [child] itself is never built again for it: the
/// picture loading, failing, or the network changing only paint again.
///
/// The picture is fetched when the floor's pictures load by themselves (the data saver, the auto load setting: as the
/// pictures of the content); held back, a picture already cached still shows, as theirs. It is decoded at most
/// [postBackgroundMaxDecodeSide] on a side, a still of its first frame ([StillImage]). A picture that failed is not
/// asked again in this run ([PostBackgroundFailures]): a painted [DecorationImage] asks its picture on every paint.
///
/// Not [enabled] (the floor's card moved aside while floors are picked to be quoted), nothing is drawn: the same
/// widgets, so [child] keeps its state.
class PostBackgroundPaint extends StatefulWidget {
  /// Constructor.
  const PostBackgroundPaint({
    required this.layer,
    required this.part,
    required this.child,
    this.enabled = true,
    super.key,
  });

  /// The background; null: [child] alone.
  final PostBackgroundLayer? layer;

  /// Where in the floor [child] is.
  final PostBackgroundPart part;

  /// Whether the background is drawn now.
  final bool enabled;

  /// What the background is behind.
  final Widget child;

  @override
  State<PostBackgroundPaint> createState() => _PostBackgroundPaintState();
}

class _PostBackgroundPaintState extends State<PostBackgroundPaint> {
  /// The picture [url] failed (or, [cacheOnly], was not cached): not asked again, drawn without it once built again.
  /// Told while painting maybe: built again after the frame.
  void _failed(String url, {required bool cacheOnly}) {
    PostBackgroundFailures.add(url, cacheOnly: cacheOnly);
    scheduleMicrotask(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final layer = widget.layer;
    if (layer == null) {
      return widget.child;
    }
    final autoLoad = PostImageAutoLoad.fromIndex(
      context.select<SettingsBloc, int>((e) => e.state.settingsMap.postImageAutoLoad),
    );
    final dataSaver = DataSaverMode.fromIndex(
      context.select<SettingsBloc, int>((e) => e.state.settingsMap.dataSaverMode),
    );
    final theme = Theme.of(context);
    final veil = postBackgroundVeil(theme, highContrast: MediaQuery.maybeHighContrastOf(context) ?? false);
    final corners = switch (widget.part) {
      PostBackgroundPart.top => const BorderRadius.vertical(top: Radius.circular(appSurfaceRadius)),
      PostBackgroundPart.bottom => const BorderRadius.vertical(bottom: Radius.circular(appSurfaceRadius)),
    };
    final enabled = widget.enabled;
    return ValueListenableBuilder<bool?>(
      valueListenable: NetworkUsage.unmetered,
      child: widget.child,
      builder: (context, unmetered, child) {
        final fetches = switch (DataSaver.holdsBack(context, dataSaver)) {
          true || null => false,
          false => switch (autoLoad) {
            PostImageAutoLoad.always => true,
            PostImageAutoLoad.never => false,
            PostImageAutoLoad.wifiOnly => unmetered ?? false,
          },
        };
        final url = layer.imageUrl;
        // A veil the picture would not show through (the platform's high contrast in some themes): none asked.
        final drawn = enabled && veil.a < 1 && !PostBackgroundFailures.failed(url, cacheOnly: !fetches);
        return DecoratedBox(
          key: const ValueKey('post-background-image'),
          decoration: BoxDecoration(
            borderRadius: corners,
            image: !drawn
                ? null
                : DecorationImage(
                    image: postBackgroundImage(url, cacheOnly: !fetches),
                    repeat: switch (layer.repeat) {
                      PostBackgroundRepeat.both => ImageRepeat.repeat,
                      PostBackgroundRepeat.none => ImageRepeat.noRepeat,
                      PostBackgroundRepeat.x => ImageRepeat.repeatX,
                      PostBackgroundRepeat.y => ImageRepeat.repeatY,
                    },
                    alignment: Alignment(
                      switch (layer.alignX) {
                        PostBackgroundAlignX.left => -1,
                        PostBackgroundAlignX.center => 0,
                        PostBackgroundAlignX.right => 1,
                      },
                      switch (layer.alignY) {
                        PostBackgroundAlignY.top => -1,
                        PostBackgroundAlignY.center => 0,
                        PostBackgroundAlignY.bottom => 1,
                      },
                    ),
                    fit: switch (layer.size) {
                      // The picture's own size, as the web page's `background-size: auto` (not scaled down to fit).
                      PostBackgroundSize.natural => BoxFit.none,
                      PostBackgroundSize.fitWidth => BoxFit.fitWidth,
                      PostBackgroundSize.cover => BoxFit.cover,
                      PostBackgroundSize.contain => BoxFit.contain,
                    },
                    // A picture that fails is no background: nothing drawn, nothing reported, not asked again.
                    onError: (_, _) => _failed(url, cacheOnly: !fetches),
                  ),
          ),
          child: DecoratedBox(
            key: const ValueKey('post-background-veil'),
            decoration: BoxDecoration(color: enabled ? veil : null, borderRadius: corners),
            child: child,
          ),
        );
      },
    );
  }
}

/// The pictures of the floors' backgrounds that failed in this run: never asked again (a painted [DecorationImage]
/// asks its picture on every paint, and a failed one is out of the image cache). Those that failed from the network,
/// and apart those not in the cache when only the cache was asked (the data saver): they are fetched once the pictures
/// load by themselves again. At most [max] of each, the oldest forgotten first.
abstract final class PostBackgroundFailures {
  /// The most pictures remembered, of each kind.
  static const max = 256;

  static final _fetched = <String>{};
  static final _notCached = <String>{};

  /// Remember [url] failed, asked from the cache only with [cacheOnly].
  static void add(String url, {required bool cacheOnly}) {
    final set = (cacheOnly ? _notCached : _fetched)..remove(url);
    if (set.length >= max) {
      set.remove(set.first);
    }
    set.add(url);
  }

  /// Whether [url] asked so ([cacheOnly]) failed before: one that failed from the network fails from the cache too.
  static bool failed(String url, {required bool cacheOnly}) =>
      _fetched.contains(url) || (cacheOnly && _notCached.contains(url));

  /// Forget them all (for tests).
  @visibleForTesting
  static void clear() {
    _fetched.clear();
    _notCached.clear();
  }
}

/// The picture of a floor's background at [url] as it is painted: cached as the pictures of the posts, decoded within
/// [postBackgroundMaxDecodeSide], still ([StillImage]); from the cache only with [cacheOnly].
ImageProvider<Object> postBackgroundImage(String url, {bool cacheOnly = false}) => StillImage(
  BoundedResizeImage(
    CachedImageProvider(url, cacheOnly: cacheOnly),
    width: postBackgroundMaxDecodeSide,
    height: postBackgroundMaxDecodeSide,
    policy: ResizeImagePolicy.fit,
  ),
);
