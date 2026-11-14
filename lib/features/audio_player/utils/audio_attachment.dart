import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/attachment_download/utils/attachment_protocol.dart';
import 'package:tsdm_client/features/audio_player/models/audio_track.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// File name extensions of the sound files the app plays itself.
///
/// The players of every platform play these; Ogg and Opus are left out on Apple's, whose player does not.
Set<String> playableAudioExtensions({bool apple = false}) => apple ? _appleAudioExtensions : _audioExtensions;

const _audioExtensions = {'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'oga', 'opus'};
const _appleAudioExtensions = {'mp3', 'm4a', 'aac', 'flac', 'wav'};

/// Whether [filename] names a sound file the app plays ([playableAudioExtensions]).
bool isPlayableAudioFile(String filename, {bool apple = false}) {
  final name = filename.trim();
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) {
    return false;
  }
  return playableAudioExtensions(apple: apple).contains(name.substring(dot + 1).toLowerCase());
}

/// An audio attachment of a floor, as the forum prints it in the floor's html: the inline one (`[attach]aid[/attach]`
/// in the message) and the one listed below the message (`div.pattl`), each in an `<ignore_js_op>` of its own.
///
/// ```html
/// <ignore_js_op>
///   <img src="static/image/filetype/av.gif" class="vm" />
///   <span id="attach_1610"><a href="forum.php?mod=attachment&amp;aid=…">song.mp3</a> <em class="xg1">(36.73 KB, 下载次数: 0)</em></span>
///   <div class="tip tip_4" id="attach_1610_menu" style="display: none">…</div>
/// </ignore_js_op>
/// <ignore_js_op>
///   <dl class="tattl"><dt><img src="static/image/filetype/av.gif" /></dt>
///     <dd><p class="attnm"><a href="forum.php?mod=attachment&amp;aid=…" id="aid1609">song.m4a</a>…</p>
///       <p>35.23 KB, 下载次数: 0</p><p class="xg2">description</p></dd></dl>
/// </ignore_js_op>
/// ```
///
/// An attachment the account has to buy links to the purchase (`mod=misc&action=attachpay`) and one it may not have
/// is not printed: neither is one of these, they stay as the forum prints them.
@immutable
final class PostAudioAttachment {
  /// Constructor.
  const PostAudioAttachment({
    required this.aid,
    required this.filename,
    required this.url,
    this.sizeText,
    this.description,
  });

  /// The audio attachment the forum's block [element] (an `<ignore_js_op>`) holds; null when it holds anything else.
  ///
  /// [apple] leaves out the files Apple's player does not play ([playableAudioExtensions]).
  static PostAudioAttachment? of(uh.Element element, {bool apple = false}) {
    try {
      return _of(element, apple: apple);
    } on Object {
      return null;
    }
  }

  static PostAudioAttachment? _of(uh.Element element, {required bool apple}) {
    // A block holding blocks: each of them is looked at on its own.
    if (element.querySelector('ignore_js_op') != null) {
      return null;
    }
    final links = element.querySelectorAll('a[href]').where((e) => _isAttachmentUrl(e.attributes['href']!)).toList();
    if (links.length != 1) {
      return null;
    }
    // Only the file type icon of the forum next to it: a picture in the block is a picture attachment.
    if (element.querySelectorAll('img').any((e) => !(e.attributes['src'] ?? '').contains('image/filetype/'))) {
      return null;
    }
    final link = links.single;
    final filename = link.text?.trim() ?? '';
    if (!isPlayableAudioFile(filename, apple: apple)) {
      return null;
    }
    final href = link.attributes['href']!;
    final aid =
        _aidOfId(link.id, 'aid') ??
        _aidOfId(element.querySelector('span[id^="attach_"]')?.id ?? '', 'attach_') ??
        aidOfAttachmentUrl(href);
    if (aid == null) {
      return null;
    }
    final infoText = element
        .querySelectorAll('em.xg1, dd > p:not(.attnm):not(.xg2)')
        .map((e) => e.text ?? '')
        .join(' ');
    final size = _sizeRe.firstMatch(infoText)?.group(0);
    final description = element.querySelector('p.xg2')?.text?.trim();
    return PostAudioAttachment(
      aid: aid,
      filename: filename,
      url: canonicalAttachmentUrl(href),
      sizeText: size,
      description: description == null || description.isEmpty ? null : description,
    );
  }

  /// Every audio attachment of the floor html [html], in the order of the page, once each.
  static List<PostAudioAttachment> allOf(String html, {bool apple = false}) {
    try {
      final doc = parseHtmlDocument(html);
      final seen = <int>{};
      return doc
          .querySelectorAll('ignore_js_op')
          .map((e) => of(e, apple: apple))
          .whereType<PostAudioAttachment>()
          .where((e) => seen.add(e.aid))
          .toList();
    } on Object {
      return const [];
    }
  }

  /// The attachment id.
  final int aid;

  /// File name.
  final String filename;

  /// The download address, absolute.
  final String url;

  /// The size as the forum prints it (`36.73 KB`), null when it does not.
  final String? sizeText;

  /// What the uploader wrote of it, null when nothing.
  final String? description;

  /// As a track of the thread [tid] titled [threadTitle].
  AudioTrack toTrack({String? tid, String? threadTitle}) =>
      AudioTrack.attachment(aid: aid, filename: filename, url: url, tid: tid, threadTitle: threadTitle);

  static final _sizeRe = RegExp(r'\d+(\.\d+)?\s?[KMG]?B\b');

  /// A download address of this forum's attachment ([isAttachmentDownloadUrl]): the request carries the account's
  /// session.
  static bool _isAttachmentUrl(String href) => isAttachmentDownloadUrl(href);

  static int? _aidOfId(String id, String prefix) {
    if (!id.startsWith(prefix)) {
      return null;
    }
    final aid = int.tryParse(id.substring(prefix.length));
    return aid != null && aid > 0 ? aid : null;
  }
}

/// The attachment id of a download address of the forum (`forum.php?mod=attachment&aid=…`): its `aid` is the base64 of
/// `aid|key|time|uid|tid`, or the id itself. Null when it names none.
int? aidOfAttachmentUrl(String url) {
  try {
    final raw = url.tryParseAsUri()?.queryParameters['aid'];
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final plain = int.tryParse(raw);
    if (plain != null) {
      return plain > 0 ? plain : null;
    }
    final decoded = utf8.decode(base64.decode(base64.normalize(raw)), allowMalformed: true);
    final aid = int.tryParse(decoded.split('|').first);
    return aid != null && aid > 0 ? aid : null;
  } on FormatException {
    return null;
  }
}

/// The audio attachments of the floors [posts], in the order of the floors, as tracks of the thread [tid] titled
/// [threadTitle]: what plays one after another.
List<AudioTrack> audioTracksOfPosts(
  Iterable<Post> posts, {
  String? tid,
  String? threadTitle,
  bool apple = false,
}) => audioTracksOfHtml(posts.map((e) => e.data), tid: tid, threadTitle: threadTitle, apple: apple);

/// The audio attachments of the floor htmls [htmls] ([PostAudioAttachment.allOf]), in their order, once each, as
/// tracks of the thread [tid] titled [threadTitle].
List<AudioTrack> audioTracksOfHtml(
  Iterable<String> htmls, {
  String? tid,
  String? threadTitle,
  bool apple = false,
}) {
  final seen = <int>{};
  return htmls
      .expand((html) => PostAudioAttachment.allOf(html, apple: apple))
      .where((e) => seen.add(e.aid))
      .map((e) => e.toTrack(tid: tid, threadTitle: threadTitle))
      .toList();
}

/// The song id of a link to a song of NetEase Cloud Music (`https://music.163.com/song?id=1`,
/// `https://music.163.com/#/song?id=1`, also `y.music.163.com` and the mobile `/m/song?id=`), null for anything else.
String? neteaseSongIdOf(String url) {
  final uri = url.trim().tryParseAsUri();
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return null;
  }
  if (!const {'music.163.com', 'y.music.163.com'}.contains(uri.host.toLowerCase())) {
    return null;
  }
  // The single page site keeps its route in the fragment: `#/song?id=1`.
  final route = uri.fragment.startsWith('/') ? Uri.tryParse(uri.fragment) : null;
  final target = route ?? uri;
  if (!_neteaseSongPathRe.hasMatch(target.path)) {
    return null;
  }
  final id = target.queryParameters['id']?.trim();
  return id != null && _neteaseIdRe.hasMatch(id) ? id : null;
}

final _neteaseSongPathRe = RegExp(r'^/(m/)?song/?$');
final _neteaseIdRe = RegExp(r'^[1-9][0-9]{0,15}$');
