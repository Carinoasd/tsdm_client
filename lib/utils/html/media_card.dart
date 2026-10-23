import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/url.dart';
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
  ///
  /// Whatever the html holds, this gives a player: one without an address when the address cannot be read.
  factory PostMedia.of(uh.Element element) {
    try {
      return PostMedia._of(element);
    } on Object {
      return const PostMedia(kind: PostMediaKind.video);
    }
  }

  factory PostMedia._of(uh.Element element) {
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
      // A frame loaded later puts `about:blank` in `src` and the address in `data-src`.
      _ => switch (_nonEmpty(element.attributes['src'])) {
        final String src when !src.trim().toLowerCase().startsWith('about:') => src,
        final src => _nonEmpty(element.attributes['data-src']) ?? src,
      },
    };
    final url = _httpUrl(raw);
    final audio = tag == 'audio' || (url != null && _audioFileRe.hasMatch(url.path));
    return PostMedia(kind: audio ? PostMediaKind.audio : PostMediaKind.video, url: url);
  }

  factory PostMedia._ofScript(String script) {
    if (_detectPlayerRe.firstMatch(script) case final match?) {
      final url = _httpUrl(match.namedGroup('url'));
      final audio =
          _audioPlayerTypes.contains(match.namedGroup('type')?.toLowerCase()) ||
          (url != null && _audioFileRe.hasMatch(url.path));
      return PostMedia(kind: audio ? PostMediaKind.audio : PostMediaKind.video, url: url);
    }
    final url = _httpUrl(
      _scriptIframeRe.firstMatch(script)?.namedGroup('url') ?? _flashSourceRe.firstMatch(script)?.namedGroup('url'),
    );
    return PostMedia(
      kind: url != null && _audioFileRe.hasMatch(url.path) ? PostMediaKind.audio : PostMediaKind.video,
      url: url,
    );
  }

  /// The player the forum's `[media]` and `[flash]` put in a post with a script ([script], its code), which the web page
  /// runs to make the player; null when the script is none of those.
  ///
  /// ```html
  /// <script type="text/javascript">detectPlayer("swf_u2n", "swf", "http://example.com/player.swf", "550", "400");</script>
  /// <script type="text/javascript" reload="1">document.getElementById('flv_NHr').innerHTML=(detectHtml5Support() ?
  ///   "<iframe src='https://player.example.com/embed/X' ...></iframe>" : AC_FL_RunContent(..., 'src', 'https://...', ...));</script>
  /// ```
  ///
  /// A player script whose address cannot be read gives a player without an address.
  static PostMedia? ofScript(String script) {
    final player = _detectPlayerRe.hasMatch(script) || _flashScriptRe.hasMatch(script);
    if (!player) {
      return null;
    }
    try {
      return PostMedia._ofScript(script);
    } on Object {
      return const PostMedia(kind: PostMediaKind.video);
    }
  }

  /// The id of the `div.media` the player of a `[media]` script ([ofScript]) is put in on the web page (into its
  /// `div.media_container`), null when the script does not say.
  static String? scriptPlayerTarget(String script) => _detectPlayerRe.firstMatch(script)?.namedGroup('id');

  /// The video of bilibili the player at the end of the message of a floor plays on the web page: the forum's
  /// `videohub` plugin puts one after the content of a floor's message cell ([message], `td#postmessage_PID`) when it
  /// links a video. Null when it links none.
  ///
  /// Found as the plugin finds it: in the order of the page, the first link (`<a href>`) or url in the text (bare urls
  /// are not linked when the floor turns that off) to a video of bilibili (`http(s)://bilibili.com/video/BV…`, also
  /// `www.` and `m.`, the `BV` id of 10 characters, at most one `p` for the part) that is seen: not in a quote, code,
  /// a hidden or locked block, a player, a script or a form's field, nor hidden ([isHidden]: by default, the `hidden`
  /// attribute and `display: none` or `visibility: hidden` in its `style`; the html renderer also knows the style
  /// sheets). It is opened as the plugin's link opens it, `https://www.bilibili.com/video/BV…/?p=N`.
  static PostMedia? bilibiliVideoOf(uh.Element message, {bool Function(uh.Element element)? isHidden}) {
    final hidden = isHidden ?? _hiddenByStyle;
    var budget = _videoNodeBudget;
    Uri? walk(uh.Node node) {
      for (final child in node.nodes) {
        if (--budget < 0) {
          return null;
        }
        if (child is uh.Element) {
          if (_videoSkipped(child) || hidden(child)) {
            continue;
          }
          if (child.localName == 'a') {
            // A link is its address, not its text.
            final video = _bilibiliVideo(child.attributes['href']);
            if (video != null) {
              return video;
            }
            continue;
          }
          final found = walk(child);
          if (found != null || budget < 0) {
            return found;
          }
        } else if (child.nodeType == uh.Node.TEXT_NODE) {
          for (final match in _videoTextUrlRe.allMatches(child.text ?? '')) {
            final video = _bilibiliVideo(match.group(0)!.replaceFirst(_videoTrailingRe, ''));
            if (video != null) {
              return video;
            }
          }
        }
      }
      return null;
    }

    try {
      if (hidden(message)) {
        return null;
      }
      final url = walk(message);
      return url == null ? null : PostMedia(kind: PostMediaKind.video, url: url);
    } on Object {
      return null;
    }
  }

  /// Most nodes of a message looked at for its video, as the plugin.
  static const _videoNodeBudget = 6000;

  /// Whether the plugin does not look for a video in [element] (nor in what it holds).
  static bool _videoSkipped(uh.Element element) =>
      _videoSkippedTags.contains(element.localName) ||
      element.classes.any(_videoSkippedClasses.contains) ||
      element.attributes.containsKey('hidden') ||
      element.attributes['aria-hidden'] == 'true' ||
      element.attributes['contenteditable'] == 'true';

  static const _videoSkippedTags = {
    'script',
    'style',
    'textarea',
    'input',
    'button',
    'iframe',
    'video',
    'audio',
    'pre',
    'code',
    'blockquote',
  };

  /// A quote, a code block, a locked or hidden block, the notice of attachments not allowed, the plugin's player.
  static const _videoSkippedClasses = {
    'quote',
    'blockcode',
    'locked',
    'showhide',
    'hidecontent',
    'attach_nopermission',
    'vh-post-embed',
  };

  static bool _hiddenByStyle(uh.Element element) => _hiddenStyleRe.hasMatch(element.attributes['style'] ?? '');

  static final _hiddenStyleRe = RegExp(
    r'(^|;)\s*(display\s*:\s*none|visibility\s*:\s*(hidden|collapse))\b',
    caseSensitive: false,
  );

  /// A url in text, as the plugin finds one.
  static final _videoTextUrlRe = RegExp(r"""https?://[^\s<>"'\[\]（）。，；！]+""");

  /// The punctuation a sentence puts after a url, not part of it.
  static final _videoTrailingRe = RegExp(r'[),.;!?]+$');

  /// The page of the video of bilibili [value] is (see [bilibiliVideoOf]), null when it is none.
  static Uri? _bilibiliVideo(String? value) {
    if (value == null || value.length > 2048 || _videoUnsafeRe.hasMatch(value)) {
      return null;
    }
    try {
      final uri = Uri.tryParse(value);
      if (uri == null ||
          !(uri.isScheme('http') || uri.isScheme('https')) ||
          !_bilibiliHosts.contains(uri.host.toLowerCase()) ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort) {
        return null;
      }
      final id = _bilibiliPathRe.firstMatch(uri.path)?.group(1);
      if (id == null) {
        return null;
      }
      final pages = uri.queryParametersAll['p'] ?? const <String>[];
      final page = pages.isEmpty ? '1' : pages.first;
      if (pages.length > 1 || !_bilibiliPageRe.hasMatch(page) || int.parse(page) > 65535) {
        return null;
      }
      return Uri.parse('https://www.bilibili.com/video/$id/?p=${int.parse(page)}');
    } on FormatException {
      // A query that cannot be read (`%zz`).
      return null;
    }
  }

  /// Control characters, white space and backslashes: an address with any is not taken.
  static final _videoUnsafeRe = RegExp(r'[\x00-\x20\x7f\\]');
  static const _bilibiliHosts = {'bilibili.com', 'www.bilibili.com', 'm.bilibili.com'};
  static final _bilibiliPathRe = RegExp(r'^/video/(BV[1-9A-HJ-NP-Za-km-z]{10})/?$');
  static final _bilibiliPageRe = RegExp(r'^[1-9][0-9]{0,4}$');

  /// Types of `[media]` (the second argument of its script) that play sound only.
  static const _audioPlayerTypes = {'mp3', 'wma', 'ra', 'rm', 'ram', 'm4a', 'ogg', 'wav'};

  static final _detectPlayerRe = RegExp(
    r'''detectPlayer\(\s*["'](?<id>[^"']*)["']\s*,\s*["'](?<type>[^"']*)["']\s*,\s*["'](?<url>[^"']+)["']''',
  );

  /// The forum's script of a flash or html5 player: `AC_FL_RunContent(…)`, `detectHtml5Support() ? … : …`.
  static final _flashScriptRe = RegExp(r'AC_FL_RunContent\s*\(|detectHtml5Support\s*\(\s*\)\s*\?');

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
      // Only an address of its own, the player is opened when a path is all that is there.
      final value = _decodeFlashvar(part.substring(i + 1).trim());
      if ((value.startsWith('//') || _schemeRe.hasMatch(value)) && _httpUrl(value) != null) {
        return value;
      }
    }
    return null;
  }

  /// A value of flashvars, url encoded as written by the forum's editor (`%E4%B8%AD`), by javascript's `escape()`
  /// (`%u4E2D`, common with old flash players), or not at all (`50%off`): as text, each escape that can be read read,
  /// the rest left as it is. [Uri.decodeComponent] throws on the last two, which took the whole floor with it.
  static String _decodeFlashvar(String value) {
    final unicode = value.replaceAllMapped(
      _jsUnicodeEscapeRe,
      (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
    );
    try {
      return Uri.decodeComponent(unicode);
    } on Object {
      return unicode;
    }
  }

  static final _jsUnicodeEscapeRe = RegExp('%u([0-9a-fA-F]{4})');

  static String? _nonEmpty(String? s) => (s == null || s.trim().isEmpty) ? null : s;

  /// [raw] as an absolute http(s) url, null when it is not one.
  ///
  /// Read as a browser reads it: tabs and line breaks anywhere and control characters and spaces around it are left
  /// out (`java\tscript:` is `javascript:`); a path is on the forum (`/x` is `https://www.tsdm39.com/x`).
  static Uri? _httpUrl(String? raw) {
    final s = raw?.replaceAll(_urlTabOrNewlineRe, '').replaceAll(_urlEdgeRe, '');
    if (s == null || s.isEmpty) {
      return null;
    }
    final Uri? uri;
    if (s.startsWith('//')) {
      uri = Uri.tryParse('https:$s');
    } else if (_schemeRe.hasMatch(s)) {
      uri = Uri.tryParse(s);
    } else {
      // A path on the forum.
      final reference = Uri.tryParse(s);
      uri = reference == null ? null : Uri.parse('$baseUrl/').resolveUri(reference);
    }
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  static final _urlTabOrNewlineRe = RegExp('[\t\n\r]');
  static final _urlEdgeRe = RegExp('^[\u0000-\u0020]+|[\u0000-\u0020]+\$');
  static final _schemeRe = RegExp('^[a-zA-Z][a-zA-Z0-9+.-]*:');
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
