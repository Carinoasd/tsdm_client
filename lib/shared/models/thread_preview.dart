part of 'models.dart';

/// The preview of a thread in a list: a plain text excerpt of its first floor and some of its images, as the forum's
/// app API gives it for every thread row of a list page asked with `tsdmpreview=1` (plugin 3.1.0: the forum page, the
/// guide lists, the search results, the "my threads" pages and a member's threads).
///
/// The plugin judges every row again as the thread page would judge the viewer, and stricter: what the viewer could
/// not read on the thread page is never in a preview. A row whose first floor is not given has a [reason] then (paid,
/// read permission, password, a hidden forum, a moved thread…), no excerpt and no image; a list shows the title alone
/// for it, as before, and never tells the reason.
@MappableClass()
final class ThreadPreview with ThreadPreviewMappable {
  /// Constructor.
  const ThreadPreview({
    required this.excerpt,
    required this.images,
    this.reason,
    this.imageTotal = 0,
    this.partial = false,
  });

  /// The preview of the `preview` [value] of a thread row, null when the row carries none: an older plugin, a list
  /// asked without the parameter, a reply row or a comment row (`null`), anything that is not an object.
  ///
  /// * `excerpt` is plain text, never html (a member's `<b>` is text): kept as it came, line breaks included.
  /// * `reason` withholds the preview: there is no excerpt and no image then, whatever the answer carries.
  /// * `images` keeps the images of an absolute http(s) url only, in the order of the answer (at most three).
  /// * `image_total` is the number of images the thread page shows, at least the images given.
  static ThreadPreview? fromApi(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final reason = value['reason'];
    if (reason is String && reason.isNotEmpty) {
      return ThreadPreview(excerpt: null, images: const [], reason: reason);
    }
    final images = switch (value['images']) {
      final List<dynamic> list => list.map(ThreadPreviewImage.fromApi).nonNulls.toList(),
      _ => const <ThreadPreviewImage>[],
    };
    final total = _apiInt(value['image_total']);
    return ThreadPreview(
      excerpt: _apiText(value['excerpt']),
      images: images,
      imageTotal: total > images.length ? total : images.length,
      partial: _apiInt(value['partial']) == 1,
    );
  }

  /// The excerpt as the plugin gave it, plain text with its line breaks (`\r\n`); null when the preview is withheld
  /// ([reason]), empty for a first floor without text.
  final String? excerpt;

  /// Why the plugin gives no preview of the row (`price`, `readperm`, `password`, `forum`, `moved`, `hide`…), null when
  /// it gives one. Never shown: a withheld preview shows nothing.
  final String? reason;

  /// The images of the first floor, at most three, in the order of the floor.
  final List<ThreadPreviewImage> images;

  /// How many images the thread page shows; at least the number of [images].
  final int imageTotal;

  /// The first floor is longer than the part the plugin read: the excerpt and the images come from its start.
  final bool partial;

  /// Whether the plugin withheld the preview ([reason]): nothing is shown for the row.
  bool get withheld => reason != null;

  /// [excerpt] for a list: one flowing text, each run of line breaks (and the blanks around it) as one space, trimmed.
  /// Empty when withheld or without text.
  String get excerptText => withheld ? '' : (excerpt ?? '').replaceAll(_lineBreaks, ' ').trim();

  static final _lineBreaks = RegExp(r'[ \t　]*(?:\r\n|\r|\n)(?:[ \t　]*(?:\r\n|\r|\n))*[ \t　]*');

  /// The image a list shows, null when there is none (or when withheld): among the attachments of the floor
  /// ([ThreadPreviewImage.attachment]), and the images of other sites too when [external] (off by default: a list
  /// loading them would tell the author's site about everyone who only scrolls past the thread, which the web page
  /// only does once the thread is opened). A thumbnail the forum made ([ThreadPreviewImage.thumb]) first, then the
  /// first one over https (Android and iOS refuse plain http), then the first one.
  ThreadPreviewImage? thumbnailOf({bool external = false}) {
    if (withheld) {
      return null;
    }
    final candidates = external ? images : images.where((e) => e.attachment).toList();
    if (candidates.isEmpty) {
      return null;
    }
    return candidates.firstWhereOrNull((e) => e.thumb) ??
        candidates.firstWhereOrNull((e) => e.secure) ??
        candidates.first;
  }

  /// How many images there are besides the thumbnail [thumbnailOf] picks with [external] (the "+N" on it); 0 when
  /// there is no thumbnail.
  int moreImagesOf({bool external = false}) {
    if (thumbnailOf(external: external) == null) {
      return 0;
    }
    final total = imageTotal > images.length ? imageTotal : images.length;
    return total - 1;
  }
}

/// One image of a [ThreadPreview].
@MappableClass()
final class ThreadPreviewImage with ThreadPreviewImageMappable {
  /// Constructor.
  ///
  /// An image without [url] is drawn as a picture placeholder: the app's own examples (the settings page) use it, an
  /// answer never gives one ([ThreadPreviewImage.fromApi] drops it).
  const ThreadPreviewImage({
    required this.url,
    this.thumb = false,
    this.width = 0,
    this.height = 0,
    this.source = '',
  });

  /// The image of an entry [value] of `preview.images`, null when it is not an object or its `url` is not an absolute
  /// http or https url with a host.
  static ThreadPreviewImage? fromApi(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final url = _apiText(value['url']).trim();
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http') || uri.host.isEmpty) {
      return null;
    }
    return ThreadPreviewImage(
      url: url,
      thumb: _apiInt(value['thumb']) == 1,
      width: _apiInt(value['width']),
      height: _apiInt(value['height']),
      source: _apiText(value['source']),
    );
  }

  /// Absolute url of the image: a thumbnail the forum made ([thumb]), or the image itself.
  final String url;

  /// [url] is a thumbnail the forum made of an attachment (`*.thumb.jpg`), not the picture itself.
  final bool thumb;

  /// Width of the picture itself, 0 when unknown.
  final int width;

  /// Height of the picture itself, 0 when unknown.
  final int height;

  /// Where the image comes from: `attach` (an attachment of the floor) or `img` (an `[img]` of another site).
  final String source;

  /// Whether [url] is an https one.
  bool get secure => url.startsWith('https://');

  /// Whether the image is an attachment of the floor (`source: attach`), served by the forum itself; an image without
  /// url (the app's own example) counts as one.
  bool get attachment => source == 'attach' || url.isEmpty;
}

/// When the thread lists show the thumbnail of a [ThreadPreview] ([SettingsKeys.threadCardThumbnailMode] holds the
/// index).
enum ThreadThumbnailMode {
  /// On any network.
  always,

  /// On Wi-Fi (or another network the system does not count as metered) only: the default.
  wifiOnly,

  /// Never.
  never
  ;

  /// The mode of a stored [index]; the default ([wifiOnly]) for an index out of range.
  static ThreadThumbnailMode fromIndex(int index) =>
      index >= 0 && index < values.length ? values[index] : ThreadThumbnailMode.wifiOnly;
}
