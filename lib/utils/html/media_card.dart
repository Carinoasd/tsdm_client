import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:url_launcher/url_launcher.dart';

/// What an embedded player plays.
enum PostMediaKind {
  /// A video, or a player of any kind.
  video,

  /// Sound only.
  audio,
}

/// An embedded player in a post (`<iframe>`, `<embed>`, `<object>`, `<video>`, `<audio>`), which the app does not
/// play itself: what it plays and where from, to open in the browser.
@immutable
final class PostMedia {
  /// Constructor.
  const PostMedia({required this.kind, this.url});

  /// The player of the [element], see [PostMedia].
  ///
  /// The url is the player's address (`src`, `data`, the first `<source>`), or, for a flash player of a sound file
  /// (`dewplayer.swf` with `flashvars="son=…mp3"`), the file it plays: the flash player itself opens nowhere any more.
  /// A url of the page's own site is made absolute, one starting with `//` takes https. Only an http(s) url is kept.
  factory PostMedia.of(uh.Element element) {
    final tag = element.localName;
    String? raw;
    String? param(String name) => element
        .querySelectorAll('param')
        .firstWhereOrNull((e) => e.attributes['name']?.toLowerCase() == name)
        ?.attributes['value'];
    if (tag == 'embed' || tag == 'object') {
      raw =
          _playedFile(element.attributes['flashvars']) ??
          _playedFile(param('flashvars')) ??
          _playedFile(element.querySelector('embed')?.attributes['flashvars']);
    }
    raw ??= switch (tag) {
      'object' =>
        _nonEmpty(element.attributes['data']) ??
            param('movie') ??
            param('src') ??
            element.querySelector('embed')?.attributes['src'],
      'video' ||
      'audio' => _nonEmpty(element.attributes['src']) ?? element.querySelector('source[src]')?.attributes['src'],
      _ => _nonEmpty(element.attributes['src']) ?? element.attributes['data-src'],
    };
    final url = _httpUrl(raw);
    final audio = tag == 'audio' || (url != null && _audioFileRe.hasMatch(url.path));
    return PostMedia(kind: audio ? PostMediaKind.audio : PostMediaKind.video, url: url);
  }

  /// The player the forum's `[media]` and `[flash]` put in a post with a script ([script], its code), which the web page
  /// runs to make the player; null when the script is none of those.
  ///
  /// ```html
  /// <script type="text/javascript">detectPlayer("swf_u2n", "swf", "http://example.com/player.swf", "550", "400");</script>
  /// <script type="text/javascript" reload="1">document.getElementById('flv_NHr').innerHTML=(detectHtml5Support() ?
  ///   "<iframe src='https://player.example.com/embed/X' ...></iframe>" : AC_FL_RunContent(..., 'src', 'https://...', ...));</script>
  /// ```
  static PostMedia? ofScript(String script) {
    if (_detectPlayerRe.firstMatch(script) case final match?) {
      final url = _httpUrl(match.namedGroup('url'));
      final audio =
          _audioPlayerTypes.contains(match.namedGroup('type')?.toLowerCase()) ||
          (url != null && _audioFileRe.hasMatch(url.path));
      return PostMedia(kind: audio ? PostMediaKind.audio : PostMediaKind.video, url: url);
    }
    if (!script.contains('detectHtml5Support') && !script.contains('AC_FL_RunContent')) {
      return null;
    }
    final raw =
        _scriptIframeRe.firstMatch(script)?.namedGroup('url') ?? _flashSourceRe.firstMatch(script)?.namedGroup('url');
    if (raw == null) {
      return null;
    }
    final url = _httpUrl(raw);
    return PostMedia(
      kind: url != null && _audioFileRe.hasMatch(url.path) ? PostMediaKind.audio : PostMediaKind.video,
      url: url,
    );
  }

  /// The id of the `div.media` the player of a `[media]` script ([ofScript]) is put in on the web page (into its
  /// `div.media_container`), null when the script does not say.
  static String? scriptPlayerTarget(String script) => _detectPlayerRe.firstMatch(script)?.namedGroup('id');

  /// Types of `[media]` (the second argument of its script) that play sound only.
  static const _audioPlayerTypes = {'mp3', 'wma', 'ra', 'rm', 'ram', 'm4a', 'ogg', 'wav'};

  static final _detectPlayerRe = RegExp(
    r'''detectPlayer\(\s*["'](?<id>[^"']*)["']\s*,\s*["'](?<type>[^"']*)["']\s*,\s*["'](?<url>[^"']+)["']''',
  );
  static final _scriptIframeRe = RegExp(r'''<iframe[^>]*\ssrc=\\?["'](?<url>[^"'\\]+)''', caseSensitive: false);
  static final _flashSourceRe = RegExp(r'''['"]src['"]\s*,\s*['"](?<url>[^'"]+)['"]''');

  /// Kind of what is played.
  final PostMediaKind kind;

  /// Where it plays from, an http(s) url; null when the player has none the browser could open.
  final Uri? url;

  /// The name of the site the player is from: the name of a known video or music site, else the host without `www.`;
  /// null without [url].
  String? get site {
    final host = url?.host.toLowerCase();
    if (host == null || host.isEmpty) {
      return null;
    }
    for (final MapEntry(key: domain, value: name) in _knownSites.entries) {
      if (host == domain || host.endsWith('.$domain')) {
        return name;
      }
    }
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  /// Names of sites whose players are embedded in posts, by domain. Brand names, the same in every language.
  static const _knownSites = {
    'bilibili.com': 'Bilibili',
    'b23.tv': 'Bilibili',
    'youtube.com': 'YouTube',
    'youtube-nocookie.com': 'YouTube',
    'youtu.be': 'YouTube',
    'nicovideo.jp': 'niconico',
    'acfun.cn': 'AcFun',
    'youku.com': 'Youku',
    'iqiyi.com': 'iQIYI',
    'v.qq.com': 'Tencent Video',
    'music.163.com': 'NetEase Cloud Music',
    'y.qq.com': 'QQ Music',
    'vimeo.com': 'Vimeo',
    'soundcloud.com': 'SoundCloud',
    'twitch.tv': 'Twitch',
  };

  static final _audioFileRe = RegExp(r'\.(mp3|m4a|aac|ogg|oga|opus|wav|flac|wma)$', caseSensitive: false);

  /// The sound file a flash player plays, from its [flashvars] (`son=`, `mp3=`, `file=`, `url=`, `src=`).
  static String? _playedFile(String? flashvars) {
    if (flashvars == null) {
      return null;
    }
    for (final part in flashvars.split('&')) {
      final i = part.indexOf('=');
      if (i <= 0) {
        continue;
      }
      final key = part.substring(0, i).trim().toLowerCase();
      if (!const {'son', 'mp3', 'file', 'url', 'src', 'sound'}.contains(key)) {
        continue;
      }
      final value = Uri.decodeComponent(part.substring(i + 1).trim());
      if (_httpUrl(value) != null) {
        return value;
      }
    }
    return null;
  }

  static String? _nonEmpty(String? s) => (s == null || s.trim().isEmpty) ? null : s;

  /// [raw] as an absolute http(s) url, null when it is not one.
  static Uri? _httpUrl(String? raw) {
    final s = raw?.trim();
    if (s == null || s.isEmpty) {
      return null;
    }
    final String absolute;
    if (s.startsWith('//')) {
      absolute = 'https:$s';
    } else if (RegExp('^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(s)) {
      absolute = s;
    } else {
      // A path on the forum.
      absolute = s.prependHost();
    }
    final uri = Uri.tryParse(absolute);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
      return null;
    }
    return uri;
  }
}

/// An embedded player of a post ([PostMedia]), which the app does not play: a small inline card naming the site,
/// opening the player's address in the browser on tap. On the web page the player takes the place of the
/// `<iframe>`; before, the app showed nothing there and the reader did not know anything was there.
class PostMediaCard extends StatelessWidget {
  /// Constructor.
  const PostMediaCard(this.media, {super.key});

  /// The player.
  final PostMedia media;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.mediaCard;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final site = media.site;
    final url = media.url;
    final label = site == null ? tr.title : tr.titleOf(site: site);
    // Rich text only, no row: it lays out in any width, also in the cell of a table working out its columns.
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Icon(
                media.kind == PostMediaKind.audio ? Icons.music_note_outlined : Icons.play_circle_outline,
                size: 18,
                color: colorScheme.primary,
              ),
            ),
            TextSpan(
              text: ' $label',
              style: TextStyle(color: colorScheme.primary),
            ),
            if (url != null)
              TextSpan(
                text: '  ${tr.open}',
                style: textTheme.bodySmall?.copyWith(color: colorScheme.outline),
              ),
          ],
        ),
        style: textTheme.bodyMedium,
      ),
    );
    final shape = RoundedRectangleBorder(
      side: BorderSide(color: colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(8),
    );
    final box = DecoratedBox(
      decoration: ShapeDecoration(shape: shape),
      child: content,
    );
    return Semantics(
      link: url != null,
      label: label,
      excludeSemantics: true,
      child: url == null
          ? box
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: shape,
                onTap: () async => launchUrl(url, mode: LaunchMode.externalApplication),
                child: box,
              ),
            ),
    );
  }
}
