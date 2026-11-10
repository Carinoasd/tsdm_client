import 'package:flutter/foundation.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/audio_player/utils/audio_attachment.dart' show aidOfAttachmentUrl;
import 'package:tsdm_client/utils/html/media_card.dart';
import 'package:universal_html/html.dart' as uh;

/// File name extensions of the video files the app plays itself: libmpv (media_kit) plays them on every platform.
const playableVideoExtensions = {'mp4', 'm4v', 'mov', 'webm', 'mkv'};

/// What is played from its address: the video files and HLS playlists (`.m3u8`).
const Set<String> _streamExtensions = {...playableVideoExtensions, 'm3u8'};

/// The extension of [name] (a file name or the path of a url), lower case; empty when it has none.
String _extensionOf(String name) {
  final slash = name.lastIndexOf('/');
  final base = name.substring(slash + 1).trim();
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) {
    return '';
  }
  return base.substring(dot + 1).toLowerCase();
}

/// Whether [filename] names a video file the app plays ([playableVideoExtensions]).
bool isPlayableVideoFile(String filename) => playableVideoExtensions.contains(_extensionOf(filename));

/// A video of a floor the app plays itself, in the floor.
///
/// * An attachment of the forum (`forum.php?mod=attachment&aid=…`, [aid] set): fetched with the account's cookie into a
///   file and played from there. The forum counts a download (and takes the credits the forum asks for one) for each
///   request of an attachment and does not serve a part of one, so it is not streamed: each seek would be another
///   download.
/// * Any other address of a video file or an HLS playlist: streamed from there, without a cookie.
///
/// A player of a site (bilibili, YouTube…) is none of these: its card opens it in the browser ([PostMediaCard]).
@immutable
final class PostVideo {
  /// Constructor.
  const PostVideo({required this.url, this.title, this.aid, this.sizeText, this.poster});

  /// The video a player of a post plays ([PostMedia]) when the app plays it itself, else null: a `<video>`, or a
  /// `[media]` (and any other player) of a video file or an HLS playlist; not the player of a known site.
  static PostVideo? ofMedia(PostMedia media) {
    if (media.kind != PostMediaKind.video || media.fromKnownSite) {
      return null;
    }
    return ofUrl(media.url, videoElement: media.videoElement, poster: media.poster);
  }

  /// The video at [url], null when the app does not play it: an attachment of the forum, or (unless [videoElement],
  /// an html5 `<video>` that plays whatever it points at) the address of a video file or an HLS playlist.
  static PostVideo? ofUrl(Uri? url, {bool videoElement = false, Uri? poster}) {
    if (url == null || !(url.isScheme('http') || url.isScheme('https')) || url.host.isEmpty) {
      return null;
    }
    if (_isAttachmentUrl(url)) {
      final aid = aidOfAttachmentUrl(url.toString());
      return aid == null ? null : PostVideo(url: url.toCanonicalForumUri(), aid: aid, poster: poster);
    }
    if (!videoElement && !_streamExtensions.contains(_extensionOf(url.path))) {
      return null;
    }
    final name = url.pathSegments.where((e) => e.isNotEmpty).lastOrNull;
    return PostVideo(url: url, title: name, poster: poster);
  }

  /// The video attachment the forum's block [element] (an `<ignore_js_op>`) holds, as the audio one
  /// (`PostAudioAttachment`): the inline one (`[attach]aid[/attach]`) and the one listed below the message.
  ///
  /// ```html
  /// <ignore_js_op>
  ///   <img src="static/image/filetype/av.gif" class="vm" />
  ///   <span id="attach_90004"><a href="forum.php?mod=attachment&amp;aid=…">clip.mp4</a> <em class="xg1">(23.95 KB, 下载次数: 0)</em></span>
  /// </ignore_js_op>
  /// ```
  ///
  /// Null when it holds anything else.
  static PostVideo? attachmentOf(uh.Element element) {
    try {
      return _attachmentOf(element);
    } on Object {
      return null;
    }
  }

  static PostVideo? _attachmentOf(uh.Element element) {
    // A block holding blocks: each of them is looked at on its own.
    if (element.querySelector('ignore_js_op') != null) {
      return null;
    }
    final links = element.querySelectorAll('a[href]').where((e) {
      final uri = e.attributes['href']!.trim().tryParseAsUri();
      return uri != null && _isAttachmentQuery(uri);
    }).toList();
    if (links.length != 1) {
      return null;
    }
    // Only the file type icon of the forum next to it: a picture in the block is a picture attachment.
    if (element.querySelectorAll('img').any((e) => !(e.attributes['src'] ?? '').contains('image/filetype/'))) {
      return null;
    }
    final link = links.single;
    final filename = link.text?.trim() ?? '';
    if (!isPlayableVideoFile(filename)) {
      return null;
    }
    final url = Uri.tryParse(link.attributes['href']!.trim().prependHost());
    if (url == null || !url.isForumHost) {
      return null;
    }
    final aid = aidOfAttachmentUrl(url.toString());
    if (aid == null) {
      return null;
    }
    final infoText = element
        .querySelectorAll('em.xg1, dd > p:not(.attnm):not(.xg2)')
        .map((e) => e.text ?? '')
        .join(' ');
    return PostVideo(
      url: url.toCanonicalForumUri(),
      title: filename,
      aid: aid,
      sizeText: _sizeRe.firstMatch(infoText)?.group(0),
    );
  }

  static final _sizeRe = RegExp(r'\d+(\.\d+)?\s?[KMG]?B\b');

  static bool _isAttachmentQuery(Uri uri) {
    try {
      return uri.queryParameters['mod'] == 'attachment' && (uri.queryParameters['aid']?.isNotEmpty ?? false);
    } on FormatException {
      return false;
    }
  }

  /// An attachment of the forum: on the forum's host, `mod=attachment` with an `aid`.
  static bool _isAttachmentUrl(Uri url) => url.isForumHost && _isAttachmentQuery(url);

  /// Where it is played from: the attachment's download address, or the address streamed.
  final Uri url;

  /// The file name, null when the address does not name one.
  final String? title;

  /// The attachment id when it is an attachment of the forum, fetched before it plays; null for a stream.
  final int? aid;

  /// The size as the forum prints it (`23.95 KB`), null when it does not.
  final String? sizeText;

  /// The picture shown before it plays (`<video poster>`), null without one.
  final Uri? poster;

  /// Whether it is an attachment of the forum, fetched with the account's cookie before it plays.
  bool get isAttachment => aid != null;

  @override
  bool operator ==(Object other) =>
      other is PostVideo &&
      other.url == url &&
      other.title == title &&
      other.aid == aid &&
      other.sizeText == sizeText &&
      other.poster == poster;

  @override
  int get hashCode => Object.hash(url, title, aid, sizeText, poster);

  @override
  String toString() => 'PostVideo($url, aid: $aid)';
}
