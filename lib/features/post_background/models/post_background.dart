import 'package:equatable/equatable.dart';
import 'package:tsdm_client/constants/url.dart';

/// How a floor's background repeats (`repeat` of the thread page answer, plugin 4.1.0).
enum PostBackgroundRepeat {
  /// `both`: tiled across and down.
  both,

  /// `none`: drawn once.
  none,

  /// `x`: tiled across only (stored by an admin or an older plugin; the member's form never picks it).
  x,

  /// `y`: tiled down only (as [x]).
  y,
}

/// Where a floor's background sits across (`align_x`).
enum PostBackgroundAlignX {
  /// `left`.
  left,

  /// `center`.
  center,

  /// `right`.
  right,
}

/// Where a floor's background sits down (`align_y`).
enum PostBackgroundAlignY {
  /// `top`.
  top,

  /// `center`.
  center,

  /// `bottom`.
  bottom,
}

/// How large a floor's background is drawn (`size`).
enum PostBackgroundSize {
  /// `natural`: the picture's own size.
  natural,

  /// `fit_width`: as wide as the area (the web page's "宽屏背景拉伸").
  fitWidth,

  /// `cover`: covering the area (admin or older plugin only).
  cover,

  /// `contain`: fully inside the area (admin or older plugin only).
  contain,
}

/// One of the two backgrounds of a floor's author: the content's or the author column's (`content` / `sidebar` of an
/// entry of `backgrounds`, plugin 4.1.0 thread page `schema` 78).
final class PostBackgroundLayer extends Equatable {
  /// Constructor.
  const PostBackgroundLayer({
    required this.imageUrl,
    this.repeat = PostBackgroundRepeat.none,
    this.alignX = PostBackgroundAlignX.center,
    this.alignY = PostBackgroundAlignY.center,
    this.size = PostBackgroundSize.natural,
  });

  /// The layer of [json], null when there is none or its picture is not one the app loads ([postBackgroundImageUrl]).
  /// A value of the style the app does not know is the web page's default (no repeat, centered, natural size).
  static PostBackgroundLayer? fromApi(Object? json) {
    if (json is! Map) {
      return null;
    }
    final url = postBackgroundImageUrl(json['image']);
    if (url == null) {
      return null;
    }
    return PostBackgroundLayer(
      imageUrl: url,
      repeat: switch (json['repeat']) {
        'both' => PostBackgroundRepeat.both,
        'x' => PostBackgroundRepeat.x,
        'y' => PostBackgroundRepeat.y,
        _ => PostBackgroundRepeat.none,
      },
      alignX: switch (json['align_x']) {
        'left' => PostBackgroundAlignX.left,
        'right' => PostBackgroundAlignX.right,
        _ => PostBackgroundAlignX.center,
      },
      alignY: switch (json['align_y']) {
        'top' => PostBackgroundAlignY.top,
        'bottom' => PostBackgroundAlignY.bottom,
        _ => PostBackgroundAlignY.center,
      },
      size: switch (json['size']) {
        'fit_width' => PostBackgroundSize.fitWidth,
        'cover' => PostBackgroundSize.cover,
        'contain' => PostBackgroundSize.contain,
        _ => PostBackgroundSize.natural,
      },
    );
  }

  /// The picture, an absolute url the app loads ([postBackgroundImageUrl]).
  final String imageUrl;

  /// How it repeats.
  final PostBackgroundRepeat repeat;

  /// Where it sits across.
  final PostBackgroundAlignX alignX;

  /// Where it sits down.
  final PostBackgroundAlignY alignY;

  /// How large it is drawn.
  final PostBackgroundSize size;

  @override
  List<Object?> get props => [imageUrl, repeat, alignX, alignY, size];
}

/// The backgrounds the author of a floor has on it: behind the content ([content], the web page's `td.plc`) and behind
/// the author column ([sidebar], the web page's `td.pls`; the app draws it behind the floor's author row).
final class PostBackground extends Equatable {
  /// Constructor.
  const PostBackground({this.content, this.sidebar});

  /// The backgrounds of a thread page answer [json] (plugin 4.1.0, `schema` 78) by the uid of their author: each entry
  /// of `backgrounds` with at least one layer the app draws. Empty for an answer without the key (plugin 4.0.x and
  /// older: nothing is drawn), an empty one (`{}`, or `[]` as PHP may give an empty array) or anything else.
  static Map<int, PostBackground> mapFromApi(Map<String, dynamic> json) {
    final raw = json['backgrounds'];
    if (raw is! Map) {
      return const {};
    }
    final out = <int, PostBackground>{};
    for (final MapEntry(:key, :value) in raw.entries) {
      final uid = int.tryParse('$key');
      if (uid == null || uid <= 0 || value is! Map) {
        continue;
      }
      final background = PostBackground(
        content: PostBackgroundLayer.fromApi(value['content']),
        sidebar: PostBackgroundLayer.fromApi(value['sidebar']),
      );
      if (background.content != null || background.sidebar != null) {
        out[uid] = background;
      }
    }
    return out;
  }

  /// Behind the content.
  final PostBackgroundLayer? content;

  /// Behind the author row.
  final PostBackgroundLayer? sidebar;

  @override
  List<Object?> get props => [content, sidebar];
}

/// The url of a background's picture [value] as the app loads it: an absolute `https` url of any host, or one of the
/// forum itself ([baseUrl], `http` too when the app runs against a forum without TLS); null for anything else (empty,
/// relative, another scheme, credentials in the url). The plugin gives only absolute `http(s)` urls it checked.
String? postBackgroundImageUrl(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return null;
  }
  final forum = Uri.parse(baseUrl);
  final sameForum = uri.scheme == forum.scheme && uri.host == forum.host && uri.port == forum.port;
  if (uri.scheme != 'https' && !sameForum) {
    return null;
  }
  return uri.toString();
}
