import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// A video on a site the app can ask for its title, cover and length ([MediaPreview]).
///
/// Only the address of the video itself counts: a short link (`b23.tv`) is not expanded, that would take a request
/// to the site to follow it.
@immutable
sealed class MediaPreviewTarget {
  const MediaPreviewTarget();

  /// The video [url] is, null when it is no video of a site known here.
  ///
  /// * bilibili: `/video/BV…`, `/video/av…`, the player's `?bvid=` and `?aid=`, on `bilibili.com`, `www.`, `m.` and
  ///   `player.`.
  /// * YouTube: `watch?v=`, `/shorts/`, `/embed/`, `/live/` and `/v/` on `youtube.com`, `www.`, `m.` and
  ///   `youtube-nocookie.com`, and `youtu.be/`.
  static MediaPreviewTarget? tryParse(Uri? url) {
    if (url == null || !(url.isScheme('http') || url.isScheme('https'))) {
      return null;
    }
    try {
      final host = url.host.toLowerCase();
      if (_bilibiliHosts.contains(host)) {
        return _bilibili(url);
      }
      if (_youtubeHosts.contains(host) || host == 'youtu.be') {
        return _youtube(url, host);
      }
    } on FormatException {
      // A query that cannot be read (`%zz`).
    }
    return null;
  }

  static const _bilibiliHosts = {'bilibili.com', 'www.bilibili.com', 'm.bilibili.com', 'player.bilibili.com'};
  static const _youtubeHosts = {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'youtube-nocookie.com',
    'www.youtube-nocookie.com',
  };

  static final _bvRe = RegExp(r'^BV[1-9A-HJ-NP-Za-km-z]{10}$');
  static final _aidRe = RegExp(r'^[1-9][0-9]{0,15}$');
  static final _bilibiliPathRe = RegExp(r'^/video/(BV[1-9A-HJ-NP-Za-km-z]{10}|[aA][vV][1-9][0-9]{0,15})/?$');
  static final _youtubeIdRe = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final _youtubePathRe = RegExp(r'^/(?:shorts|embed|live|v)/([A-Za-z0-9_-]{11})/?$');

  static MediaPreviewTarget? _bilibili(Uri url) {
    final query = url.queryParameters;
    final bvid = query['bvid'];
    if (bvid != null && _bvRe.hasMatch(bvid)) {
      return BilibiliTarget.bvid(bvid);
    }
    final aid = query['aid'];
    if (aid != null && _aidRe.hasMatch(aid)) {
      return BilibiliTarget.aid(aid);
    }
    final id = _bilibiliPathRe.firstMatch(url.path)?.group(1);
    if (id == null) {
      return null;
    }
    return id.startsWith('BV') ? BilibiliTarget.bvid(id) : BilibiliTarget.aid(id.substring(2));
  }

  static MediaPreviewTarget? _youtube(Uri url, String host) {
    final String? id;
    if (host == 'youtu.be') {
      final segments = url.pathSegments;
      id = segments.length == 1 ? segments.first : null;
    } else if (url.path == '/watch') {
      id = url.queryParameters['v'];
    } else {
      id = _youtubePathRe.firstMatch(url.path)?.group(1);
    }
    return id != null && _youtubeIdRe.hasMatch(id) ? YoutubeTarget(id) : null;
  }

  /// Where the answer about the video is asked.
  Uri get apiUrl;

  /// The same for any address of the same video, the key of what is kept.
  String get key;

  /// [json] (what [apiUrl] answered) as a preview, null when it says there is no such video.
  MediaPreview? parse(Object? json);
}

/// A video of bilibili.
final class BilibiliTarget extends MediaPreviewTarget {
  /// A video by its `BV` id.
  const BilibiliTarget.bvid(String this.bvid) : aid = null;

  /// A video by its `av` number (digits only).
  const BilibiliTarget.aid(String this.aid) : bvid = null;

  /// The `BV` id, when that is how the video is told.
  final String? bvid;

  /// The `av` number, when that is how the video is told.
  final String? aid;

  @override
  Uri get apiUrl => Uri.https('api.bilibili.com', '/x/web-interface/view', {
    'bvid': ?bvid,
    'aid': ?aid,
  });

  @override
  String get key => bvid != null ? 'bili:$bvid' : 'bili:av$aid';

  @override
  MediaPreview? parse(Object? json) {
    if (json is! Map<String, dynamic> || json['code'] != 0) {
      return null;
    }
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      return null;
    }
    final title = _text(data['title']);
    if (title == null) {
      return null;
    }
    final owner = data['owner'];
    final seconds = data['duration'];
    return MediaPreview(
      title: title,
      author: owner is Map<String, dynamic> ? _text(owner['name']) : null,
      thumbnail: _imageUrl(data['pic']),
      duration: seconds is int && seconds > 0 ? Duration(seconds: seconds) : null,
    );
  }
}

/// A video of YouTube.
final class YoutubeTarget extends MediaPreviewTarget {
  /// A video by its id.
  const YoutubeTarget(this.id);

  /// The 11 characters id.
  final String id;

  @override
  Uri get apiUrl => Uri.https('www.youtube.com', '/oembed', {
    'url': 'https://www.youtube.com/watch?v=$id',
    'format': 'json',
  });

  @override
  String get key => 'yt:$id';

  /// oEmbed knows no length of the video.
  @override
  MediaPreview? parse(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final title = _text(json['title']);
    if (title == null) {
      return null;
    }
    return MediaPreview(title: title, author: _text(json['author_name']), thumbnail: _imageUrl(json['thumbnail_url']));
  }
}

String? _text(Object? value) {
  if (value is! String) {
    return null;
  }
  final text = value.trim();
  return text.isEmpty ? null : text;
}

/// [value] as an https url (bilibili answers `http://` and `//` for a cover), null when it is none.
Uri? _imageUrl(Object? value) {
  final text = _text(value);
  if (text == null) {
    return null;
  }
  final uri = Uri.tryParse(text.startsWith('//') ? 'https:$text' : text);
  if (uri == null || uri.host.isEmpty || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return null;
  }
  return uri.replace(scheme: 'https');
}

/// What a site tells about a video.
@immutable
final class MediaPreview {
  /// Constructor.
  const MediaPreview({required this.title, this.author, this.thumbnail, this.duration});

  /// Title of the video.
  final String title;

  /// Who made it.
  final String? author;

  /// The cover.
  final Uri? thumbnail;

  /// How long it plays; null when the site does not say.
  final Duration? duration;

  /// [duration] as `m:ss`, or `h:mm:ss` from an hour; null without it.
  String? get durationText {
    final d = duration;
    if (d == null) {
      return null;
    }
    String two(int n) => n.toString().padLeft(2, '0');
    final s = two(d.inSeconds % 60);
    return d.inHours > 0 ? '${d.inHours}:${two(d.inMinutes % 60)}:$s' : '${d.inMinutes}:$s';
  }
}

/// Gets the answer of [url] as json, null when there is none.
typedef MediaPreviewFetcher = Future<Object?> Function(Uri url);

/// Asks the sites for the previews of [MediaPreviewTarget]s, each video once for as long as the app runs.
///
/// A request gives up after [timeout], a failed one is asked again after [retryAfter] (not on every redraw of the
/// card).
class MediaPreviewRepository {
  /// Constructor.
  MediaPreviewRepository({
    MediaPreviewFetcher? fetcher,
    this.timeout = const Duration(seconds: 5),
    this.retryAfter = const Duration(minutes: 2),
    this.capacity = 200,
    DateTime Function()? now,
  }) : _fetcher = fetcher ?? _dioFetcher(timeout),
       _now = now ?? DateTime.now;

  /// The one the cards use.
  static MediaPreviewRepository instance = MediaPreviewRepository();

  /// The longest a request takes.
  final Duration timeout;

  /// How long a failure is remembered.
  final Duration retryAfter;

  /// Most videos kept; the one asked longest ago goes first.
  final int capacity;

  final MediaPreviewFetcher _fetcher;
  final DateTime Function() _now;
  final _entries = <String, _Entry>{};

  /// The preview of [target], null when it cannot be had.
  Future<MediaPreview?> preview(MediaPreviewTarget target) {
    final kept = _entries.remove(target.key);
    if (kept != null && (!kept.failed || _now().difference(kept.at) < retryAfter)) {
      // Asked again: now the newest.
      _entries[target.key] = kept;
      return kept.result;
    }
    final entry = _Entry(_load(target), _now());
    _entries[target.key] = entry;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
    unawaited(
      entry.result.then((preview) {
        entry.failed = preview == null;
      }),
    );
    return entry.result;
  }

  Future<MediaPreview?> _load(MediaPreviewTarget target) async {
    try {
      final json = await _fetcher(target.apiUrl).timeout(timeout);
      return target.parse(json);
    } on Object {
      // No cover is no harm: the card stays as it was.
      return null;
    }
  }

  /// Forget everything kept.
  void clear() => _entries.clear();

  static MediaPreviewFetcher _dioFetcher(Duration timeout) {
    // Not the app's client: it carries the forum's cookies and checks, and these are other sites.
    final dio = Dio(
      BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
        responseType: ResponseType.plain,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
          'Accept': 'application/json',
        },
      ),
    );
    // bilibili answers 412 to a client without a `buvid3`; any value is taken.
    final buvid = '${_hex(math.Random.secure(), 32)}infoc';
    return (url) async {
      final bilibili = url.host.endsWith('bilibili.com');
      final response = await dio.getUri<String>(
        url,
        options: Options(
          headers: {
            if (bilibili) 'Cookie': 'buvid3=$buvid',
            if (bilibili) 'Referer': 'https://www.bilibili.com/',
          },
        ),
      );
      return jsonDecode(response.data ?? '');
    };
  }

  static String _hex(math.Random random, int length) =>
      List.generate(length, (_) => random.nextInt(16).toRadixString(16)).join();
}

class _Entry {
  _Entry(this.result, this.at);

  final Future<MediaPreview?> result;
  final DateTime at;
  bool failed = false;
}
