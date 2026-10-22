import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dart_bbcode_parser/dart_bbcode_parser.dart';
import 'package:flutter/foundation.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/smilies.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/parsing.dart';

/// How a floor is shown by the experimental app renderer: drawn from its bbcode ([PostBbcodeRender]) or, whenever
/// anything is not certain to look as the forum shows it, from the html the forum printed ([PostBbcodeFallback]).
sealed class PostBbcodeDecision {
  const PostBbcodeDecision();
}

/// Draw the floor's message from [nodes]; the rest of the floor's html (what the forum printed before and after the
/// message: the attachment list, the moderation notice, the comments…) stays html, [htmlBefore] and [htmlAfter],
/// empty when there is nothing to show.
final class PostBbcodeRender extends PostBbcodeDecision {
  /// Constructor.
  const PostBbcodeRender({required this.nodes, required this.htmlBefore, required this.htmlAfter});

  /// The message.
  final List<BbNode> nodes;

  /// The floor's html before the message.
  final String htmlBefore;

  /// The floor's html after the message.
  final String htmlAfter;
}

/// Show the floor's html as before; [reason] tells why (for logs and tests).
final class PostBbcodeFallback extends PostBbcodeDecision {
  /// Constructor.
  const PostBbcodeFallback(this.reason);

  /// Why: the answer's `message_reason` when it withholds the bbcode, `tag:NAME` for a tag the app does not draw,
  /// or what else was not certain.
  final String reason;

  @override
  String toString() => 'PostBbcodeFallback($reason)';
}

/// The style of a run of text: the switches of `[b]`, `[i]`, `[u]`, `[s]` and the raw values of `[color=]`,
/// `[backcolor=]` and `[size=]` (the renderer reads them as the html renderer reads the forum's `<font>`).
@immutable
final class BbStyle {
  /// Constructor.
  const BbStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.color,
    this.backgroundColor,
    this.size,
  });

  /// `[b]`.
  final bool bold;

  /// `[i]`.
  final bool italic;

  /// `[u]`.
  final bool underline;

  /// `[s]`.
  final bool strike;

  /// `[color=]`.
  final String? color;

  /// `[backcolor=]`.
  final String? backgroundColor;

  /// `[size=]`, `1` to `7`.
  final String? size;

  /// The style without [color]: a link's text, which is in the link's own color.
  BbStyle withoutColor() => BbStyle(
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    backgroundColor: backgroundColor,
    size: size,
  );

  /// Copy with the given values.
  BbStyle copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    String? color,
    String? backgroundColor,
    String? size,
  }) => BbStyle(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strike: strike ?? this.strike,
    color: color ?? this.color,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    size: size ?? this.size,
  );
}

/// A piece of a floor drawn from its bbcode.
sealed class BbNode {
  const BbNode();

  /// Whether the piece is a block: it takes lines of its own.
  bool get isBlock => false;
}

/// Text in [style]; `\n` breaks the line.
final class BbText extends BbNode {
  /// Constructor.
  const BbText(this.text, [this.style = const BbStyle()]);

  /// The text.
  final String text;

  /// Its style.
  final BbStyle style;
}

/// A smiley code turned into its image.
final class BbSmiley extends BbNode {
  /// Constructor.
  const BbSmiley(this.smiley);

  /// The smiley.
  final Smiley smiley;
}

/// `[img]` / `[img=w,h]`.
final class BbImage extends BbNode {
  /// Constructor.
  const BbImage(this.url, {this.width, this.height});

  /// Absolute url.
  final String url;

  /// Width the forum gives it, if any.
  final int? width;

  /// Height the forum gives it, if any.
  final int? height;
}

/// `[attach]aid[/attach]`: the floor's [attachment] with that id (a locked one is a placeholder, nothing fetched).
final class BbAttachment extends BbNode {
  /// Constructor.
  const BbAttachment(this.attachment);

  /// The attachment.
  final PostAttachment attachment;

  /// The id in the bbcode.
  int get aid => attachment.aid;
}

/// A link around [children]: `[url]`, or a bare url the forum would link ([auto]).
final class BbLink extends BbNode {
  /// Constructor.
  const BbLink(this.href, this.children, {this.auto = false});

  /// Where it goes.
  final String href;

  /// What it shows.
  final List<BbNode> children;

  /// A bare url linked by the app: shown as the html renderer shows such a url, without the link icon.
  final bool auto;
}

/// `[quote]`, and `[free]` (the forum shows both in the same quote box).
final class BbQuote extends BbNode {
  /// Constructor.
  const BbQuote(this.children);

  /// The quoted content.
  final List<BbNode> children;

  @override
  bool get isBlock => true;
}

/// `[code]`, as raw text.
final class BbCodeBlock extends BbNode {
  /// Constructor.
  const BbCodeBlock(this.code);

  /// The code.
  final String code;

  @override
  bool get isBlock => true;
}

/// `[spoiler=title]` (the forum's own tag).
final class BbSpoiler extends BbNode {
  /// Constructor.
  const BbSpoiler(this.title, this.children);

  /// The title on the button.
  final String title;

  /// The folded content.
  final List<BbNode> children;

  @override
  bool get isBlock => true;
}

/// `[list]`, `[list=1]`, `[list=a]`, `[list=A]`.
final class BbList extends BbNode {
  /// Constructor.
  const BbList(this.type, this.items);

  /// `1`, `a`, `A`, or null for bullets.
  final String? type;

  /// The items.
  final List<List<BbNode>> items;

  @override
  bool get isBlock => true;
}

/// `[align=left|center|right]`.
final class BbAlign extends BbNode {
  /// Constructor.
  const BbAlign(this.align, this.children);

  /// `left`, `center` or `right`.
  final String align;

  /// The aligned content.
  final List<BbNode> children;

  @override
  bool get isBlock => true;
}

/// `[hr]`.
final class BbDivider extends BbNode {
  /// Constructor.
  const BbDivider();

  @override
  bool get isBlock => true;
}

/// Whether the app renderer needs the smilies table for [post]: the forum turns its smiley codes into images
/// (`smileyoff` 0 — the forum stores 1 for a post without any smiley code — and the forum allows smilies), with tags
/// or without (`bbcodeoff` 1 does not stop the forum's smilies either).
bool postBbcodeNeedsSmilies(Post post) {
  final codes = post.bbcodeCodes;
  return post.messageBbcode != null && !post.smileyOff && codes != null && codes.allowSmilies;
}

/// The tags the app draws as the forum does; any other tag (`[table]`, `[media]`, `[flash]`, `[audio]`, `[email]`,
/// `[attachimg]`, `[sup]`, `[@]`, `[p=]`, `[float]`, `[indent]`, `[hide]`, a site's own tag…) keeps the floor on its
/// html. `[code]`, `[attach]`, `[font=]` and the edit note `[i=s]` are taken care of before.
const postBbcodeSupportedTags = {
  'b',
  'i',
  'u',
  's',
  'color',
  'backcolor',
  'size',
  'url',
  'img',
  'quote',
  'free',
  'spoiler',
  'list',
  '*',
  'hr',
  'align',
};

/// The tags of [postBbcodeSupportedTags] that are the site's own, not Discuz's: drawn only when the answer says the
/// forum expands them in the floor ([Post.customTags]).
const _siteTags = {'spoiler'};

/// Tag names that the forum reads whatever their case: a tag of them not in lower case keeps the floor on its html
/// (the forum turns some of them only in lower case, others in any case, which the app does not copy).
const Set<String> _caseSensitiveCheckTags = {
  ...postBbcodeSupportedTags,
  'code',
  'attach',
  'attachimg',
  'font',
  'hide',
  'password',
  'media',
  'audio',
  'flash',
  'table',
  'email',
};

/// A tag of bbcode: `[name]`, `[name=attr]`, `[/name]`.
final _tagRe = RegExp(r'\[(/?)([A-Za-z@*][A-Za-z0-9_]*)(?:=([^\]\n]*))?\]');

/// The forum's `\s` (ASCII whitespace).
const _ws = r'[ \t\n\r\f\v]';

final _codeRe = RegExp('$_ws?\\[code\\]([\\s\\S]+?)\\[/code\\]$_ws?');
final _editNoteRe = RegExp(r'\[i=s\][\s\S]*?\[/i\]');
final _fontHeadRe = RegExp(r'\[font=[^\[<\]]+?\]');
final _quoteRe = RegExp('$_ws?\\[quote\\][\\n\\r]*([\\s\\S]+?)[\\n\\r]*\\[/quote\\]$_ws?');
final _freeRe = RegExp('$_ws*\\[free\\][\\n\\r]*([\\s\\S]+?)[\\n\\r]*\\[/free\\]$_ws*');
final _bareUrlTagRe = RegExp(r'\[url\]([^\[]*?)\[/url\]');
final _imgSizeRe = RegExp(r'\[img=(\d{1,4})[x|,](\d{1,4})\]');
final _attachRe = RegExp(r'\[attach\](\d+)\[/attach\]');
final _privateUseRe = RegExp('[\uE000-\uE00F]');
final _placeholderRe = RegExp('\uE000(\\d+)\uE001|\uE002(\\d+)\uE003');

final _oldUrlAttrRe = RegExp(r'\[url=([^\]\r\n]+)\]');
final _oldUrlTagRe = RegExp(r'\[url\]\s*([^\[\r\n]+?)\s*\[/url\]');
final _oldImgRe = RegExp(r'\[img(=[^\]\r\n]*)?\]\s*([^\[\r\n]+?)\s*\[/img\]');

/// The forum's old domains and the current ones, the defaults of the forum's `oldlinkfix` plugin.
const _oldForumHosts = ['tsdm39.net', 'tsdm.me', 'tsdm.net', 'tsdm.love', 'tsdm.live'];
const _currentForumHosts = ['www.tsdm39.com', 'tsdm39.com', 'bbs.tsdm.vip'];
const _oldForumTarget = 'https://www.tsdm39.com/';

bool _forumHostIn(String host, List<String> hosts) => hosts.any((h) => host == h || host.endsWith('.$h'));

/// [url] as the forum's `oldlinkfix` plugin rewrites it in the html of a post: a url on an old domain of the forum
/// goes to the current one, an old style path (`thread-1-2-1.html`, `viewthread.php?tid=1`…) to the current page;
/// with [relative], a path without domain too. Anything else is returned as it is.
String fixOldForumUrl(String url, {bool relative = false}) {
  final t = url.trim();
  String scheme;
  String host;
  String port;
  String rest;
  final absolute = RegExp(r'^(https?:)?//([^/?#:]+)(:\d{1,5})?(/.*|[?#].*)?$', caseSensitive: false).firstMatch(t);
  final bare = RegExp(
    r'^([a-z0-9-]+(?:\.[a-z0-9-]+)+)(:\d{1,5})?(/.*|[?#].*)?$',
    caseSensitive: false,
  ).firstMatch(t);
  if (absolute != null) {
    scheme = absolute.group(1) ?? '';
    host = absolute.group(2)!.toLowerCase();
    port = absolute.group(3) ?? '';
    rest = absolute.group(4) ?? '';
  } else if (bare != null &&
      (_forumHostIn(bare.group(1)!.toLowerCase(), _oldForumHosts) ||
          _forumHostIn(bare.group(1)!.toLowerCase(), _currentForumHosts))) {
    scheme = 'http:';
    host = bare.group(1)!.toLowerCase();
    port = bare.group(2) ?? '';
    rest = bare.group(3) ?? '';
  } else {
    if (!relative || t.isEmpty || RegExp('^([a-z][a-z0-9+.-]*:|#)', caseSensitive: false).hasMatch(t)) {
      return url;
    }
    final path = t.replaceFirst(RegExp('^/+'), '');
    final mapped = _mapOldForumPath(path);
    return mapped == path ? url : mapped;
  }
  final path = rest.replaceFirst(RegExp('^/+'), '');
  if (_forumHostIn(host, _oldForumHosts)) {
    return '$_oldForumTarget${_mapOldForumPath(path)}';
  }
  if (_forumHostIn(host, _currentForumHosts)) {
    final mapped = _mapOldForumPath(path);
    return mapped == path ? url : '$scheme//$host$port/$mapped';
  }
  return url;
}

/// An old style path of the forum as the current page, as the forum's `oldlinkfix` plugin maps it.
String _mapOldForumPath(String path) {
  final m = RegExp(r'^((?:[^/?#]*/)*)([^/?#]*)(\?[^#]*)?(#.*)?$').firstMatch(path);
  if (m == null) {
    return path;
  }
  final file = m.group(2)!;
  var query = (m.group(3) ?? '').isEmpty ? '' : m.group(3)!.substring(1);
  final hash = m.group(4) ?? '';
  String join(String base, String q) {
    final rest = q.replaceFirst(RegExp('^&+'), '');
    return '$base${rest.isEmpty ? '' : '&$rest'}$hash';
  }

  final thread = RegExp(r'^thread-(\d+)-(\d+)-\d+\.html$', caseSensitive: false).firstMatch(file);
  if (thread != null) {
    final page = int.parse(thread.group(2)!);
    return join(
      'forum.php?mod=viewthread&tid=${thread.group(1)}',
      '${page > 1 ? 'page=$page' : ''}${query.isEmpty ? '' : '&$query'}',
    );
  }
  final forum = RegExp(r'^forum-(\d+)-(\d+)\.html$', caseSensitive: false).firstMatch(file);
  if (forum != null) {
    final page = int.parse(forum.group(2)!);
    return join(
      'forum.php?mod=forumdisplay&fid=${forum.group(1)}',
      '${page > 1 ? 'page=$page' : ''}${query.isEmpty ? '' : '&$query'}',
    );
  }
  final space = RegExp(r'^space-(uid|username)-([^./]+)\.html$', caseSensitive: false).firstMatch(file);
  if (space != null) {
    return join('home.php?mod=space&${space.group(1)!.toLowerCase()}=${space.group(2)}', query);
  }
  final base = switch (file.toLowerCase()) {
    'viewthread.php' => 'forum.php?mod=viewthread',
    'forumdisplay.php' => 'forum.php?mod=forumdisplay',
    'redirect.php' => 'forum.php?mod=redirect',
    'space.php' || 'viewpro.php' => 'home.php?mod=space',
    _ => null,
  };
  if (base == null) {
    return path;
  }
  if (base == 'home.php?mod=space') {
    query = query.replaceAll(RegExp(r'(^|&)action=viewpro(?=&|$)', caseSensitive: false), '');
  }
  return join(base, query);
}

/// The url schemes the forum takes in `[url]`.
final _urlSchemeRe = RegExp(
  r'^((https?|ftp|gopher|news|telnet|rtsp|mms|callto|bctp|thunder|qqdl|synacast)://|www\.|mailto:|tel:|magnet:)',
  caseSensitive: false,
);

/// A url in the text of an attribute-less `[url]`, as the forum finds it.
final _urlInTextRe = RegExp(
  r'''((https?|ftp|gopher|news|telnet|rtsp|mms|callto|bctp|thunder|qqdl|synacast)://|www\.)[^\["']+''',
  caseSensitive: false,
);

/// A bare url in text (the html renderer links the same).
final _bareUrlRe = RegExp(r'https?://[^\s<>"\u3000-\u303f\uff00-\uffef]+');
const _urlTrailingPunctuation = '.,;:!?)]}\'"';

/// What the forum prints for a tab.
const _tab = '\u00a0 \u00a0 \u00a0 \u00a0 ';

/// Decide how [post] is shown by the app renderer, with the forum's smilies table [smilies] (needed when
/// [postBbcodeNeedsSmilies]).
///
/// The floor is drawn from its bbcode only when everything in it is drawn as the forum shows it:
///
/// * the answer gives the bbcode (plugin 2.7.0: only when the account sees the whole content on the web page);
/// * the floor's html has the message cell (`td#postmessage_PID`) the bbcode replaces, the rest of the html stays;
/// * `bbcodeoff` 1: the text as it is, tags as text (no `[attach]` in it);
/// * every tag is one of [postBbcodeSupportedTags] in lower case, with an attribute the forum takes, balanced,
///   not crossed, no `[quote]` or `[spoiler]` in another, no block in a link, no `[*]` outside a list;
/// * `[img]` only where the forum shows images, on a host of its image whitelist when it has one; `[attach]aid[/attach]`
///   is the floor's attachment of that id (a locked one is drawn as a placeholder and nothing is fetched for it; an id
///   the answer does not list keeps the html), the first of the same id only, as the forum does; an id written with a
///   leading zero is dropped, as the forum drops it;
/// * `[spoiler]`, the site's own tag, only when the answer says the forum expands it for the floor (`customtags`);
/// * no attribute nor `[img]` holding a `[code]` or an `[attach]`, no `[` left open at the end, no empty `[quote]` or
///   `[free]` (the forum prints those as text);
/// * smiley codes are turned into the table's images, in the table's order, at most `maxsmilies` times each (no
///   limit when it is 0 or less, as the forum's settings cache makes it), not in `[code]`, when the forum does it
///   (`smileyoff` 0, smilies allowed);
/// * bare urls are linked, whatever `parseurloff` says (see [_linkBareUrls]).
///
/// Anything else, or an error while reading, is a [PostBbcodeFallback].
PostBbcodeDecision decidePostBbcode(Post post, {SmiliesTable? smilies}) {
  final message = post.messageBbcode;
  if (message == null) {
    final reason = post.messageReason;
    return PostBbcodeFallback(reason == null || reason.isEmpty ? 'no-bbcode' : reason);
  }
  final codes = post.bbcodeCodes;
  if (codes == null) {
    return const PostBbcodeFallback('no-codes');
  }
  final useSmilies = postBbcodeNeedsSmilies(post);
  if (useSmilies && smilies == null) {
    return const PostBbcodeFallback('smilies');
  }
  try {
    final split = splitPostBodyHtml(post.data, post.postID);
    if (split == null) {
      return const PostBbcodeFallback('no-message-cell');
    }
    final builder = _Builder(
      attachments: {for (final a in post.attachments) a.aid: a},
      allowImgCode: codes.allowImgCode,
      imgWhitelist: codes.imgWhitelist,
      customTags: post.customTags?.toSet(),
    );
    var nodes = post.bbcodeOff || !codes.allowBbcode
        ? builder.literal(message, tagsAllowed: post.bbcodeOff)
        : builder.tags(message);
    if (useSmilies) {
      nodes = _applySmilies(nodes, smilies!, codes.maxSmilies);
    }
    nodes = _linkBareUrls(nodes);
    return PostBbcodeRender(nodes: _trimEdges(nodes), htmlBefore: split.before, htmlAfter: split.after);
  } on _Fallback catch (e) {
    return PostBbcodeFallback(e.reason);
  } on Object catch (e) {
    // Anything the parser throws keeps the floor on its html.
    return PostBbcodeFallback('error: $e');
  }
}

/// Cut the floor's html [html] around its message cell (`td#postmessage_PID` of floor [pid]): what comes before and
/// after it, each empty when it shows nothing. Null when the cell is not there once.
({String before, String after})? splitPostBodyHtml(String html, String pid) {
  const marker = '\uE00F';
  if (html.contains(marker)) {
    return null;
  }
  final body = parseHtmlDocument('<div id="tsdm-post-body">$html</div>').querySelector('div#tsdm-post-body');
  if (body == null) {
    return null;
  }
  final cells = body.querySelectorAll('[id="postmessage_$pid"]');
  if (cells.length != 1) {
    return null;
  }
  cells.single.innerHtml = marker;
  final parts = body.innerHtml!.split(marker);
  if (parts.length != 2) {
    return null;
  }
  String keep(String part) {
    final doc = parseHtmlDocument(part).body;
    final shows =
        (doc?.text?.trim().isNotEmpty ?? false) ||
        (doc?.querySelector('img, iframe, video, audio, hr, input, button') != null);
    return shows ? part : '';
  }

  return (before: keep(parts[0]), after: keep(parts[1]));
}

final class _Fallback implements Exception {
  const _Fallback(this.reason);

  final String reason;
}

Never _fail(String reason) => throw _Fallback(reason);

/// Turns a floor's bbcode into [BbNode]s.
final class _Builder {
  _Builder({required this.attachments, required this.allowImgCode, this.imgWhitelist, this.customTags});

  final Map<int, PostAttachment> attachments;
  final bool allowImgCode;

  /// The forum's image domain whitelist, null when it has none (or the answer does not say).
  final List<String>? imgWhitelist;

  /// The site's own tags the forum expands in this floor, null when the answer does not say.
  final Set<String>? customTags;

  /// The `[code]` blocks taken out before parsing, by index.
  final _codes = <String>[];

  /// The attachment ids already placed.
  final _placed = <int>{};

  /// A floor the forum prints literally (`bbcodeoff`, or a forum without bbcode).
  ///
  /// [tagsAllowed]: with `bbcodeoff` 1 any tag is shown as text; without bbcode allowed in the forum, the forum
  /// still turns `[img]` and `[attach]`, which the app does not copy, so a floor with any tag keeps its html.
  List<BbNode> literal(String message, {required bool tagsAllowed}) {
    if (_privateUseRe.hasMatch(message)) {
      _fail('private-use');
    }
    final lower = message.toLowerCase();
    if (lower.contains('[attach]')) {
      _fail('attach-in-literal');
    }
    if (lower.contains('ed2k://') || lower.contains('attach://')) {
      // The forum turns these into links (an ed2k file, an attachment) even without bbcode.
      _fail('special-url');
    }
    if (!tagsAllowed && _tagRe.hasMatch(message)) {
      _fail('bbcode-not-allowed');
    }
    return [BbText(_text(_newlines(message)))];
  }

  /// A floor with tags.
  List<BbNode> tags(String message) {
    if (_privateUseRe.hasMatch(message)) {
      _fail('private-use');
    }
    // A tag the forum reads in any case, not in lower case.
    for (final m in _tagRe.allMatches(message)) {
      final name = m.group(2)!;
      if (name != name.toLowerCase() && _caseSensitiveCheckTags.contains(name.toLowerCase())) {
        _fail('case:$name');
      }
    }
    final lower = message.toLowerCase();
    if (lower.contains('[hide') || lower.contains('[password')) {
      // Never given by the forum: they hide content. Kept away all the same.
      _fail('hidden');
    }
    if (lower.contains('ed2k://') || lower.contains('attach://')) {
      _fail('special-url');
    }

    // The forum takes `[code]` out first, as raw text.
    var s = message.replaceAllMapped(_codeRe, (m) {
      final code = m.group(1)!;
      if (code.toLowerCase().contains('[attach]')) {
        _fail('attach-in-code');
      }
      _codes.add(code);
      return '\uE002${_codes.length - 1}\uE003';
    });
    s = s
        // The links and images on the forum's old domains, as the forum's `oldlinkfix` plugin rewrites them in the
        // html (the bbcode keeps them as written).
        .replaceAllMapped(_oldUrlAttrRe, (m) => '[url=${fixOldForumUrl(m.group(1)!, relative: true)}]')
        .replaceAllMapped(_oldUrlTagRe, (m) {
          final fixed = fixOldForumUrl(m.group(1)!);
          return fixed == m.group(1) ? m.group(0)! : '[url=$fixed]${m.group(1)}[/url]';
        })
        .replaceAllMapped(_oldImgRe, (m) => '[img${m.group(1) ?? ''}]${fixOldForumUrl(m.group(2)!)}[/img]')
        // The edit note the forum adds, which the html renderer skips too (the card shows the last edit).
        .replaceAll(_editNoteRe, '')
        // Font faces, which the html renderer does not use either.
        .replaceAll(_fontHeadRe, '')
        .replaceAll('[/font]', '')
        // What the forum's patterns take around quotes and free blocks.
        .replaceAllMapped(_quoteRe, (m) => '[quote]${m.group(1)}[/quote]')
        .replaceAllMapped(_freeRe, (m) => '[free]${m.group(1)}[/free]')
        .replaceAllMapped(_bareUrlTagRe, (m) => _bareUrlTag(m.group(1)!))
        .replaceAllMapped(_imgSizeRe, (m) => '[img=${m.group(1)},${m.group(2)}]')
        .replaceAllMapped(_attachRe, (m) => '\uE000${m.group(1)}\uE001');
    s = _newlines(s);

    for (final m in _tagRe.allMatches(s)) {
      final name = m.group(2)!;
      if (!postBbcodeSupportedTags.contains(name)) {
        _fail('tag:$name');
      }
      if (_siteTags.contains(name) && !(customTags?.contains(name) ?? false)) {
        // The site's own tag, expanded only when the forum says it does for this floor.
        _fail('custom:$name');
      }
      final attr = m.group(3);
      if (attr != null && _privateUseRe.hasMatch(attr)) {
        // A `[code]` or an `[attach]` inside an attribute: the forum never expands them there.
        _fail('placeholder-in-attribute');
      }
      if (m.group(1)!.isEmpty && name == 'list' && attr != null && !const ['1', 'a', 'A'].contains(attr)) {
        _fail('list:$attr');
      }
    }
    return _parse(s, const _Context());
  }

  /// `[url]X[/url]` as the forum links it: the url found in X, shortened when long.
  ///
  /// The forum reads the message it has escaped for html (`&` as `&amp;`, `"` `<` `>` as theirs) and counts and cuts
  /// the url in bytes (`strlen`, `substr`): the escapes count, the cut can fall in the middle of one, which the web
  /// page then shows as text (`rum.php ... amp;fromuid=1`), and a character cut in its bytes shows as `\uFFFD`.
  String _bareUrlTag(String text) {
    // PHP's `trim()`: ASCII white space and NUL only, not U+3000 nor a no-break space.
    final m = _urlInTextRe.firstMatch(
      _escapeHtml(text).replaceAll(RegExp('^[ \t\n\r\x00\x0B]+|[ \t\n\r\x00\x0B]+\$'), ''),
    );
    if (m == null) {
      _fail('url-without-url');
    }
    final escaped = m.group(0)!;
    final url = _unescapeHtml(escaped);
    var shown = text;
    final bytes = utf8.encode(escaped);
    if (bytes.length > 65) {
      String part(List<int> b) => _unescapeHtml(utf8.decode(b, allowMalformed: true));
      shown = '${part(bytes.sublist(0, 32))} ... ${part(bytes.sublist(bytes.length - 19))}';
    }
    // A `"` the forum keeps in the link (`&quot;` in its href) goes as `%22`, as a browser sends it; the `[url=]` it is
    // put back in takes no quote.
    final href = (url.toLowerCase().startsWith('www.') ? 'http://$url' : url).replaceAll('"', '%22');
    if (href.contains(']') || shown.contains('[') || shown.contains(']')) {
      _fail('url-text');
    }
    return '[url=$href]$shown[/url]';
  }

  List<BbNode> _parse(String source, _Context ctx) {
    final open = source.lastIndexOf('[');
    if (open >= 0 && !source.contains(']', open)) {
      // A `[name=value` left open at the end: the parser drops the value, the forum prints it.
      _fail('unclosed-bracket');
    }
    final ast = parseBBCodeTextToTags(source).map((e) => e.toJson()).toList();
    return _convert(ast, source, ctx);
  }

  List<BbNode> _convert(List<Map<String, dynamic>> ast, String source, _Context ctx) {
    final out = <BbNode>[];
    var i = 0;
    while (i < ast.length) {
      final node = ast[i];
      if (node.containsKey('text')) {
        out.addAll(_textNodes(node['text'] as String, ctx));
        i++;
        continue;
      }
      final name = node['name'] as String;
      final attr = node['attribute'] as String?;
      final children = (node['children'] as List? ?? const []).cast<Map<String, dynamic>>();
      final atTail = node['selfClosedAtTail'] == true;
      switch (name) {
        case 'spoiler' || 'free':
          if (atTail) {
            _fail('$name-tail-alone');
          }
          // The parser keeps these as a head and a tail beside the content: the tail must be among the siblings.
          final end = ast.indexWhere(
            (e) => !e.containsKey('text') && e['name'] == name && e['selfClosedAtTail'] == true,
            i + 1,
          );
          if (end < 0) {
            _fail('$name-unclosed');
          }
          final inner = ast.sublist(i + 1, end);
          if (inner.isEmpty) {
            // The forum prints an empty block as text.
            _fail('$name-empty');
          }
          if (inner.any((e) => !e.containsKey('text') && (e['name'] == 'spoiler' || e['name'] == 'free'))) {
            _fail('$name-nested');
          }
          if (ctx.inSpoiler || ctx.inLink) {
            _fail('$name-nested');
          }
          final content = _convert(inner, source, ctx.copyWith(inSpoiler: true));
          // The forum's spoiler keeps the line breaks of its content (the one after its head is an empty first line
          // of the folded part); the free block takes them, as a quote.
          out.add(
            name == 'spoiler' ? BbSpoiler(attr ?? '', _blockContent(content)) : BbQuote(_trimNewlines(content)),
          );
          i = end + 1;
          continue;
        case 'b':
          out.addAll(_convert(children, source, ctx.withStyle(ctx.style.copyWith(bold: true))));
        case 'i':
          out.addAll(_convert(children, source, ctx.withStyle(ctx.style.copyWith(italic: true))));
        case 'u':
          out.addAll(_convert(children, source, ctx.withStyle(ctx.style.copyWith(underline: true))));
        case 's':
          out.addAll(_convert(children, source, ctx.withStyle(ctx.style.copyWith(strike: true))));
        case 'color':
          out.addAll(_convert(children, source, ctx.withStyle(ctx.style.copyWith(color: attr))));
        case 'backcolor':
          out.addAll(_convert(children, source, ctx.withStyle(ctx.style.copyWith(backgroundColor: attr))));
        case 'size':
          out.addAll(_convert(children, source, ctx.withStyle(ctx.style.copyWith(size: attr))));
        case 'url':
          if (ctx.inLink) {
            _fail('url-nested');
          }
          // The link in its own color, as on the web page (`.t_f a`): a `[color]` around it does not color it, one in it
          // does.
          final content = _convert(children, source, ctx.copyWith(inLink: true, style: ctx.style.withoutColor()));
          if (content.any((e) => e.isBlock)) {
            _fail('block-in-url');
          }
          out.add(BbLink(_href(attr ?? ''), content));
        case 'img':
          out.add(_image(attr, children));
        case 'quote':
          if (ctx.inQuote) {
            _fail('quote-nested');
          }
          if (ctx.inLink) {
            _fail('block-in-url');
          }
          if (children.isEmpty) {
            _fail('quote-empty');
          }
          out.add(BbQuote(_trimNewlines(_convert(children, source, ctx.copyWith(inQuote: true)))));
        case 'align':
          if (ctx.inLink) {
            _fail('block-in-url');
          }
          out.add(BbAlign(attr ?? 'left', _blockContent(_convert(children, source, ctx))));
        case 'hr':
          if (ctx.inLink) {
            _fail('block-in-url');
          }
          out.add(const BbDivider());
        case 'list':
          if (ctx.inLink) {
            _fail('block-in-url');
          }
          out.add(_list(node, source, ctx));
        default:
          _fail('tag:$name');
      }
      i++;
    }
    return out;
  }

  /// Text of the source, with the code blocks and attachments put back.
  List<BbNode> _textNodes(String text, _Context ctx) {
    if (_tagRe.hasMatch(text)) {
      // A tag the parser left as text: unbalanced, crossed, or an attribute it does not take.
      _fail('literal-tag:${_tagRe.firstMatch(text)!.group(0)}');
    }
    final out = <BbNode>[];
    var last = 0;
    for (final m in _placeholderRe.allMatches(text)) {
      if (m.start > last) {
        out.add(BbText(_text(text.substring(last, m.start)), ctx.style));
      }
      last = m.end;
      if (m.group(1) != null) {
        final id = m.group(1)!;
        // An id with a leading zero matches no attachment of the forum, which then drops the tag: nothing shown.
        if (id.startsWith('0')) {
          continue;
        }
        final aid = int.parse(id);
        final attachment = attachments[aid];
        if (attachment == null) {
          // Not loaded for this request (no permission, not printed by the web page…): the html shows what the forum
          // decided for it.
          _fail('attach-unlisted');
        }
        // The forum puts an attachment at its first `[attach]` and drops the others of the same id.
        if (_placed.add(aid)) {
          out.add(BbAttachment(attachment));
        }
      } else {
        if (ctx.inLink) {
          _fail('block-in-url');
        }
        out.add(BbCodeBlock(_codeText(_codes[int.parse(m.group(2)!)])));
      }
    }
    if (last < text.length) {
      out.add(BbText(_text(text.substring(last)), ctx.style));
    }
    return out;
  }

  BbNode _image(String? attr, List<Map<String, dynamic>> children) {
    if (!allowImgCode) {
      _fail('img-not-allowed');
    }
    final text = children.singleOrNull?['text'];
    if (text is! String) {
      _fail('img-content');
    }
    var url = text.trim();
    if (url.isEmpty ||
        url.contains('<') ||
        url.contains('\n') ||
        url.contains('file:') ||
        url.startsWith('data:') ||
        _privateUseRe.hasMatch(url)) {
      _fail('img-url');
    }
    if (attr != null && !RegExp(r'^\d{1,4},\d{1,4}$').hasMatch(attr)) {
      _fail('img-size');
    }
    final whitelist = imgWhitelist;
    if (whitelist != null) {
      // As the forum's `iswhitelist()`: a host ending with a whitelisted domain, or the forum's own host; an url
      // without host is not checked.
      final host = Uri.tryParse(url)?.host ?? '';
      if (host.isNotEmpty && host != baseHost && !whitelist.any(host.endsWith)) {
        _fail('img-not-whitelisted');
      }
    }
    if (url.length > 1 && url[1] == ':') {
      _fail('img-url');
    }
    final lower = url.toLowerCase();
    if (lower.startsWith('static/') || lower.startsWith('data/')) {
      url = url.prependHost();
    } else if (!const ['http:/', 'https:', 'ftp://', 'rtsp:/', 'mms://'].any(lower.startsWith)) {
      url = 'http://$url';
    }
    final size = attr?.split(',');
    final width = size == null ? null : int.tryParse(size.first);
    final height = size == null || size.length < 2 ? null : int.tryParse(size[1]);
    return BbImage(
      url,
      width: width != null && width > 0 ? width : null,
      height: height != null && height > 0 ? height : null,
    );
  }

  /// `[list]`: the items are cut from the source (the parser flattens what it holds), each parsed on its own.
  BbNode _list(Map<String, dynamic> node, String source, _Context ctx) {
    final start = node['start'] as int;
    final end = node['end'] as int;
    final attr = node['attribute'] as String?;
    final head = attr == null ? '[list]' : '[list=$attr]';
    const tail = '[/list]';
    if (start < 0 ||
        end > source.length ||
        end - start < head.length + tail.length ||
        !source.startsWith(head, start) ||
        source.substring(end - tail.length, end) != tail) {
      _fail('list-position');
    }
    final inner = source.substring(start + head.length, end - tail.length);
    final pieces = <String>[];
    var depth = 0;
    var from = -1;
    for (final m in RegExp(r'\[list(?:=[^\]]*)?\]|\[/list\]|\[\*\]').allMatches(inner)) {
      final token = m.group(0)!;
      if (token == '[/list]') {
        depth--;
      } else if (token.startsWith('[list')) {
        depth++;
      } else if (depth == 0) {
        if (from < 0) {
          if (inner.substring(0, m.start).trim().isNotEmpty) {
            _fail('list-text-before-item');
          }
        } else {
          pieces.add(inner.substring(from, m.start));
        }
        from = m.end;
      }
    }
    if (from < 0) {
      if (inner.trim().isNotEmpty) {
        _fail('list-without-item');
      }
      return BbList(attr, const []);
    }
    pieces.add(inner.substring(from));
    final items = [for (final piece in pieces) _trimNewlines(_parse(piece, ctx.copyWith(inLink: false)))];
    return BbList(attr, items);
  }

  /// Where `[url=attr]` goes, as the forum makes it.
  String _href(String attr) {
    if (attr.contains('"') || attr.contains("'") || attr.contains('\n') || attr.contains('\r') || attr.contains('[')) {
      _fail('url-attr');
    }
    // Not trimmed: the forum takes the attribute as it is.
    final url = attr;
    if (url.toLowerCase().startsWith('www.')) {
      return 'http://$url';
    }
    if (!_urlSchemeRe.hasMatch(url)) {
      // A link inside the forum: the forum puts its own url in front.
      return '$baseUrl/$url';
    }
    return url;
  }

  static String _codeText(String code) =>
      code.replaceAll(r'\"', '"').replaceAll('\t', _tab).split('\n').map((e) => e.trimRight()).join('\n');

  static String _newlines(String s) => s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  /// [s] as the forum escapes a message for html (`dhtmlspecialchars`: `&`, `"`, `<`, `>`; not `'`).
  static String _escapeHtml(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  /// The text a web page shows for [s], a piece of what [_escapeHtml] made: its escapes read back, also one cut before
  /// its `;` (`&amp` is `&` in html text); what is left of one cut after its `&` (`amp;`) is text.
  static String _unescapeHtml(String s) => s.replaceAllMapped(
    RegExp('&(amp|quot|lt|gt);?'),
    (m) => const {'amp': '&', 'quot': '"', 'lt': '<', 'gt': '>'}[m.group(1)]!,
  );

  static String _text(String s) => s.replaceAll('\t', _tab);
}

@immutable
final class _Context {
  const _Context({this.style = const BbStyle(), this.inLink = false, this.inQuote = false, this.inSpoiler = false});

  final BbStyle style;
  final bool inLink;
  final bool inQuote;
  final bool inSpoiler;

  _Context withStyle(BbStyle style) => copyWith(style: style);

  _Context copyWith({BbStyle? style, bool? inLink, bool? inQuote, bool? inSpoiler}) => _Context(
    style: style ?? this.style,
    inLink: inLink ?? this.inLink,
    inQuote: inQuote ?? this.inQuote,
    inSpoiler: inSpoiler ?? this.inSpoiler,
  );
}

/// [nodes], the content of a block (`[align]`, `[spoiler]`), without the line break it ends with: the web page does
/// not show the `<br>` ending the last line of a block, where the app's rich text would show one more empty line. The
/// others stay, as on the web page: the empty lines at its start and before its end.
///
/// Line breaks on lines of their own are kept: after a block in it (`[quote]q[/quote]\r\n[/align]`, the forum's quote
/// takes the `\r` only), or all the block holds (`[spoiler=t]\r\n[/spoiler]`). The web page shows each as an empty
/// line, and so does the view (`_SpanBuilder.build`).
List<BbNode> _blockContent(List<BbNode> nodes) {
  final last = nodes.lastOrNull;
  if (last is! BbText || !last.text.endsWith('\n')) {
    return nodes;
  }
  // The line breaks it ends with, in one text or several (the parser cuts the text at the tags it drops).
  final breaks = RegExp(r'^\n+$');
  var start = nodes.length;
  while (start > 0 && nodes[start - 1] is BbText && breaks.hasMatch((nodes[start - 1] as BbText).text)) {
    start--;
  }
  if (start < nodes.length && (start == 0 || nodes[start - 1].isBlock)) {
    final count = nodes.skip(start).fold(0, (n, e) => n + (e as BbText).text.length);
    return [...nodes.take(start), BbText('\n' * count, last.style)];
  }
  final text = last.text.substring(0, last.text.length - 1);
  return [...nodes.take(nodes.length - 1), if (text.isNotEmpty) BbText(text, last.style)];
}

/// [nodes] without the line breaks at the start and the end of the content.
List<BbNode> _trimNewlines(List<BbNode> nodes) {
  final out = [...nodes];
  while (out.isNotEmpty && out.first is BbText) {
    final first = out.first as BbText;
    final text = first.text.replaceFirst(RegExp(r'^\n+'), '');
    if (text.isEmpty) {
      out.removeAt(0);
      continue;
    }
    out[0] = BbText(text, first.style);
    break;
  }
  while (out.isNotEmpty && out.last is BbText) {
    final last = out.last as BbText;
    final text = last.text.replaceFirst(RegExp(r'\n+$'), '');
    if (text.isEmpty) {
      out.removeLast();
      continue;
    }
    out[out.length - 1] = BbText(text, last.style);
    break;
  }
  return out;
}

/// The whole message without the empty lines it starts and ends with, nor the whitespace it ends with (the html
/// renderer skips the line breaks before the first content and after the last).
List<BbNode> _trimEdges(List<BbNode> nodes) {
  final out = _trimNewlines(nodes);
  while (out.isNotEmpty && out.last is BbText) {
    final last = out.last as BbText;
    final text = last.text.trimRight();
    if (text.isEmpty) {
      out.removeLast();
      continue;
    }
    out[out.length - 1] = BbText(text, last.style);
    break;
  }
  return out;
}

/// Map every [BbText] of [nodes] (not those of code blocks, which are not text nodes) with [map], keeping the
/// structure; [inLink] tells whether the text is inside a link.
List<BbNode> _mapTexts(
  List<BbNode> nodes,
  List<BbNode> Function(BbText text, {required bool inLink}) map, {
  bool inLink = false,
}) {
  final out = <BbNode>[];
  for (final node in nodes) {
    switch (node) {
      case final BbText t:
        out.addAll(map(t, inLink: inLink));
      case BbLink(:final href, :final children, :final auto):
        out.add(BbLink(href, _mapTexts(children, map, inLink: true), auto: auto));
      case BbQuote(:final children):
        out.add(BbQuote(_mapTexts(children, map, inLink: inLink)));
      case BbSpoiler(:final title, :final children):
        out.add(BbSpoiler(title, _mapTexts(children, map, inLink: inLink)));
      case BbAlign(:final align, :final children):
        out.add(BbAlign(align, _mapTexts(children, map, inLink: inLink)));
      case BbList(:final type, :final items):
        out.add(BbList(type, [for (final item in items) _mapTexts(item, map, inLink: inLink)]));
      case BbSmiley() || BbImage() || BbAttachment() || BbCodeBlock() || BbDivider():
        out.add(node);
    }
  }
  return out;
}

/// Every [BbText] of [nodes] in document order.
void _collectTexts(List<BbNode> nodes, List<BbText> into) {
  for (final node in nodes) {
    switch (node) {
      case final BbText t:
        into.add(t);
      case BbLink(:final children) ||
          BbQuote(:final children) ||
          BbSpoiler(:final children) ||
          BbAlign(:final children):
        _collectTexts(children, into);
      case BbList(:final items):
        for (final item in items) {
          _collectTexts(item, into);
        }
      case BbSmiley() || BbImage() || BbAttachment() || BbCodeBlock() || BbDivider():
        break;
    }
  }
}

/// Turn the smiley codes of the text of [nodes] into [BbSmiley]s as the forum does: each smiley of [table] in turn,
/// in the table's order, over the whole message from its start, at most [limit] times (no limit when it is 0 or less:
/// the forum's settings cache turns such a `maxsmilies` into -1, which `preg_replace` takes as no limit).
List<BbNode> _applySmilies(List<BbNode> nodes, SmiliesTable table, int limit) {
  final max = limit > 0 ? limit : -1;
  final texts = <BbText>[];
  _collectTexts(nodes, texts);
  // The pieces of each text: a String not turned yet, or a Smiley.
  final pieces = Map<BbText, List<Object>>.identity();
  for (final t in texts) {
    pieces[t] = <Object>[t.text];
  }
  for (final smiley in table.smilies) {
    var count = 0;
    for (final t in texts) {
      if (max >= 0 && count >= max) {
        break;
      }
      final list = pieces[t]!;
      final next = <Object>[];
      for (final piece in list) {
        if (piece is! String || (max >= 0 && count >= max) || !piece.contains(smiley.code)) {
          next.add(piece);
          continue;
        }
        var rest = piece;
        while (true) {
          final at = rest.indexOf(smiley.code);
          if (at < 0 || (max >= 0 && count >= max)) {
            break;
          }
          if (at > 0) {
            next.add(rest.substring(0, at));
          }
          next.add(smiley);
          count++;
          rest = rest.substring(at + smiley.code.length);
        }
        if (rest.isNotEmpty) {
          next.add(rest);
        }
      }
      pieces[t] = next;
    }
  }
  return _mapTexts(nodes, (t, {required inLink}) {
    final list = pieces[t];
    if (list == null || (list.length == 1 && list.single is String)) {
      return [t];
    }
    return [
      for (final piece in list)
        if (piece is Smiley) BbSmiley(piece) else BbText(piece as String, t.style),
    ];
  });
}

/// Link the bare `http(s)://` urls of the text of [nodes] that is not in a link already.
///
/// Whatever the floor's `parseurloff` says: the forum itself does not link bare urls when it shows a post (it is its
/// editor that wraps them in `[url]` when posting), but the html renderer links every bare url it meets, so readers
/// are used to tapping them; switching renderers must not take that away.
List<BbNode> _linkBareUrls(List<BbNode> nodes) => _mapTexts(nodes, (t, {required inLink}) {
  if (inLink || !t.text.contains('://')) {
    return [t];
  }
  final out = <BbNode>[];
  var last = 0;
  for (final match in _bareUrlRe.allMatches(t.text)) {
    var url = match.group(0)!;
    while (url.isNotEmpty && _urlTrailingPunctuation.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    if (url.length <= 'https://'.length) {
      continue;
    }
    if (match.start > last) {
      out.add(BbText(t.text.substring(last, match.start), t.style));
    }
    out.add(BbLink(url, [BbText(url, t.style)], auto: true));
    last = match.start + url.length;
  }
  if (out.isEmpty) {
    return [t];
  }
  if (last < t.text.length) {
    out.add(BbText(t.text.substring(last), t.style));
  }
  return out;
});
