import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/features/cache/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';

////////////////////////////////////////////////////////////////////////
///
/// All widgets in this file are add functionality on [Hero] animation.
///
////////////////////////////////////////////////////////////////////////

/// Like [CircleAvatar], display user avatar but with hero animation support.
final class HeroUserAvatar extends StatefulWidget {
  // Can no be a const constructor.
  // ignore: prefer_const_constructor_declarations
  /// Constructor.
  HeroUserAvatar({
    required this.username,
    required this.avatarUrl,
    this.heroTag,
    this.maxRadius,
    this.minRadius,
    this.disableHero = false,
    super.key,
  }) {
    _imageProvider = CachedImageProvider(
      // FIXME: Fix nullable arg.
      avatarUrl ?? '',
      usage: ImageUsageInfoUserAvatar(username),
    );
  }

  /// Optional override of the tag used in [Hero].
  final String? heroTag;

  /// Username
  final String username;

  /// User avatar
  final String? avatarUrl;

  /// Max avatar border radius.
  final double? minRadius;

  /// Min avatar border radius.
  final double? maxRadius;

  /// Disable hero animation.
  ///
  /// Use in absolutely multi-hero-tag pages.
  final bool disableHero;

  late final CachedImageProvider _imageProvider;

  @override
  State<HeroUserAvatar> createState() => _HeroUserAvatarState();
}

class _HeroUserAvatarState extends State<HeroUserAvatar> {
  bool hasError = false;

  /// The avatar was not there when this widget asked (not cached yet, loading, failed): the image shown may be the
  /// placeholder, so it is loaded again once the avatar is cached.
  bool _missed = false;

  /// Bumped when the avatar is loaded again: the circle is painted anew, which asks the image again (an evicted image
  /// is asked again only when painted, and nothing else of the circle changes then).
  int _loads = 0;

  StreamSubscription<ImageCacheResponse>? imageCacheSub;

  Future<void> onImageCachedResponse(ImageCacheResponse resp) async {
    if (!mounted) {
      return;
    }

    switch (resp) {
      case ImageCacheSuccessResponse() || ImageCacheStatusResponse(status: ImageCacheStatus2.cached):
        // Now the image is cached.
        if (hasError) {
          setState(() => hasError = false);
        }
        // Loaded again from the cache only when it was missing before (here, or anywhere the placeholder was loaded
        // for it). Evicted at every answer, every avatar was decoded again each time its floor was built, and the
        // decoded image shared by the other floors of the same author with it (the floors are built again when
        // scrolled back to).
        if (_missed || widget._imageProvider.loadedAsPlaceholder) {
          _missed = false;
          await widget._imageProvider.evict();
          if (mounted) {
            setState(() => _loads++);
          }
        }
      case ImageCacheLoadingResponse() || ImageCacheStatusResponse(status: ImageCacheStatus2.loading):
        _missed = true;
        if (hasError) {
          setState(() => hasError = false);
        }
      case ImageCacheFailedResponse() || ImageCacheStatusResponse(status: ImageCacheStatus2.notCached):
        _missed = true;
        if (!hasError) {
          setState(() => hasError = true);
        }
    }
  }

  @override
  void initState() {
    super.initState();
    imageCacheSub = getIt
        .get<ImageCacheProvider>()
        .response
        .where((e) => e.respType == ImageCacheResponseType.userAvatar && e.imageId == widget.username)
        .listen((resp) async => onImageCachedResponse(resp));
    unawaited(
      getIt.get<ImageCacheProvider>().queryUserAvatarCacheState(
        ImageCacheUserAvatarRequest(username: widget.username, imageUrl: widget.avatarUrl ?? ''),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(imageCacheSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget avatar;
    avatar = CircleAvatar(
      key: ValueKey(_loads),
      backgroundImage: widget._imageProvider,
      maxRadius: widget.maxRadius,
      minRadius: widget.minRadius,
      child: hasError ? Text(widget.username.isEmpty ? ' ' : widget.username[0]) : null,
    );
    if (widget.disableHero) {
      return avatar;
    }
    return Hero(
      tag: widget.heroTag ?? 'UserAvatar_${widget.username}',
      flightShuttleBuilder: (_, _, _, _, toHeroContext) =>
          DefaultTextStyle(style: DefaultTextStyle.of(toHeroContext).style, child: toHeroContext.widget),
      child: avatar,
    );
  }
}

/// Show a dialog with hero animation support.
///
/// The dialog content is built by the parameter [builder].
Future<T?> showHeroDialog<T>(BuildContext context, RoutePageBuilder builder) async {
  return Navigator.push<T>(
    context,
    PageRouteBuilder(
      opaque: false,
      // Fix barrier color.
      // ref: flutter/lib/src/material/dialog.dart: showDialog()
      barrierColor: Theme.of(context).dialogTheme.barrierColor ?? Colors.black54,
      barrierDismissible: true,
      pageBuilder: (context, animation, secondaryAnimation) => builder(context, animation, secondaryAnimation),
      // fullscreenDialog: true,
      transitionsBuilder: (context, ani1, ani2, child) {
        return FadeTransition(
          opacity: CurveTween(curve: Curves.easeIn).animate(ani1),
          child: child,
        );
      },
    ),
  );
}
