/// How the forum hands out an attachment, as seen on Discuz X5 (`source/app/forum/module/attachment.php`,
/// `child/attachment/check.php`, `child/misc/attachcredit.php`):
///
/// * The post links to `forum.php?mod=attachment&aid=<token>`, the token the base64 of `aid|key|time|uid|tid`. An
///   attachment the account has to buy links to `forum.php?mod=misc&action=attachpay&aid=…&tid=…` instead.
/// * The file comes with `Content-Disposition: attachment; filename="<rawurlencoded name>"` (and
///   `filename*=utf-8''<same>` when it is not plain ASCII). Everything else is a message page (`200 text/html`, the
///   words in `#messagetext > p`): no permission (`抱歉，只有特定用户可以下载本站附件`), the price not paid
///   (`附件需要付费，请您付费后下载`, its link the purchase), the attachment gone, the link expired.
/// * When a download costs credits, the forum answers `302` to `forum.php?mod=misc&action=attachcredit&aid=…&formhash=…`:
///   loading that page takes the credits, and it links to the download with a `ck` that is valid for an hour.
library;

import 'dart:convert';

import 'package:tsdm_client/extensions/string.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Whether [url] is the download address of an attachment (`forum.php?mod=attachment&aid=…`).
bool isAttachmentDownloadUrl(String url) {
  final uri = url.trim().tryParseAsUri();
  if (uri == null || (uri.hasScheme && uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  final query = uri.queryParameters;
  if (query['mod'] != 'attachment' || (query['aid'] ?? '').isEmpty || query.containsKey('findpost')) {
    return false;
  }
  final path = uri.path.toLowerCase();
  return path.isEmpty || path.endsWith('forum.php');
}

/// Whether [url] is the page that takes the credits of a download (`mod=misc&action=attachcredit`).
bool isAttachCreditUrl(String url) {
  final query = url.tryParseAsUri()?.queryParameters;
  return query != null && query['mod'] == 'misc' && query['action'] == 'attachcredit';
}

/// Whether [url] is the purchase of an attachment (`mod=misc&action=attachpay`).
bool isAttachPayUrl(String url) {
  final query = url.tryParseAsUri()?.queryParameters;
  return query != null && query['mod'] == 'misc' && query['action'] == 'attachpay';
}

/// The thread of the download address [url]: the last part of its token (`aid|key|time|uid|tid`), null when it has
/// none.
String? tidOfAttachmentUrl(String url) {
  try {
    final raw = url.tryParseAsUri()?.queryParameters['aid'];
    if (raw == null || raw.isEmpty || int.tryParse(raw) != null) {
      return null;
    }
    final parts = utf8.decode(base64.decode(base64.normalize(raw)), allowMalformed: true).split('|');
    if (parts.length < 5) {
      return null;
    }
    final tid = int.tryParse(parts[4]);
    return tid != null && tid > 0 ? '$tid' : null;
  } on FormatException {
    return null;
  }
}

final _sizeRe = RegExp(r'(\d+(?:\.\d+)?)\s?(Bytes|Byte|B|KB|MB|GB|TB)\b', caseSensitive: false);

/// The size the forum prints next to an attachment (`153 Bytes`, `36.73 KB`, `1.2 GB`) in bytes, null when [text] has
/// none.
int? attachmentSizeOf(String? text) {
  final match = _sizeRe.firstMatch(text ?? '');
  if (match == null) {
    return null;
  }
  final value = double.tryParse(match.group(1)!);
  if (value == null) {
    return null;
  }
  final unit = switch (match.group(2)!.toUpperCase()) {
    'KB' => 1024,
    'MB' => 1024 * 1024,
    'GB' => 1024 * 1024 * 1024,
    'TB' => 1024 * 1024 * 1024 * 1024,
    _ => 1,
  };
  return (value * unit).round();
}

/// The file name of the `Content-Disposition` header [value]: `filename*` first, then `filename`, both percent-decoded
/// (the forum percent-encodes the quoted one too). Null when it names none.
String? filenameOfContentDisposition(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  String? decode(String raw) {
    try {
      return Uri.decodeComponent(raw);
      // A malformed escape (an argument error) or bytes that are no UTF-8: the name as sent.
    } on Object {
      return raw;
    }
  }

  final extended = RegExp(r"""filename\*\s*=\s*([^']*)'[^']*'([^;]+)""", caseSensitive: false).firstMatch(value);
  if (extended != null) {
    final name = decode(extended.group(2)!.trim());
    if (name != null && name.isNotEmpty) {
      return name;
    }
  }
  final plain = RegExp(r'filename\s*=\s*("([^"]*)"|[^;]+)', caseSensitive: false).firstMatch(value);
  if (plain == null) {
    return null;
  }
  final name = decode((plain.group(2) ?? plain.group(1)!).trim());
  return name == null || name.isEmpty ? null : name;
}

/// Whether the `Content-Disposition` header [value] hands a file out: the forum's message pages have none.
bool isFileDisposition(String? value) {
  final kind = value?.split(';').first.trim().toLowerCase();
  return kind == 'attachment' || kind == 'inline';
}

/// A message page of the forum: its `message` and the link it leads to (`link`, absolute), if any.
typedef ForumAnswer = ({String message, String? link});

final _redirectRe = RegExp(r"""(?:window\.location\.href\s*=\s*|succeedhandle_\w*\(\s*)'([^']+)'""");

/// What the forum's message page [body] says: a whole page (`#messagetext`) or the AJAX one (`<root><![CDATA[…]]>`).
/// Null when [body] is no message page.
ForumAnswer? forumAnswerOf(String body, {required Uri base}) {
  var html = body;
  final cdata = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>').firstMatch(body);
  if (cdata != null) {
    html = cdata.group(1)!;
  }
  final uh.Document doc;
  try {
    doc = parseHtmlDocument(html);
  } on Object {
    return null;
  }
  final box =
      doc.querySelector('#messagetext') ??
      doc.querySelector('.alert_error') ??
      doc.querySelector('.alert_info') ??
      doc.querySelector('.alert_right');
  if (box == null) {
    return null;
  }
  // The script in the paragraph (the redirect) is not of the words.
  final scripts = box.querySelectorAll('script');
  final redirect = scripts.map((e) => _redirectRe.firstMatch(e.text ?? '')?.group(1)).nonNulls.firstOrNull;
  for (final e in scripts) {
    e.remove();
  }
  final paragraph = box.querySelector('p');
  final message = (paragraph ?? box).text?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
  if (message.isEmpty) {
    return null;
  }
  final href = box
      .querySelectorAll('.alert_btnleft a[href], p a[href]')
      .map((e) => e.attributes['href']!.trim())
      .where((e) => e.isNotEmpty && !e.startsWith('javascript:') && !e.startsWith('#'))
      .firstOrNull;
  final link = href ?? redirect;
  return (message: message, link: link == null ? null : _absolute(link, base));
}

String? _absolute(String link, Uri base) {
  final uri = Uri.tryParse(link.replaceAll('&amp;', '&'));
  return uri == null ? null : '${base.resolveUri(uri)}';
}

/// The name a download is saved as: [name] without what a file name may not hold, at most 180 characters (the
/// extension kept); [fallback] when nothing is left.
String safeDownloadFileName(String name, {required String fallback}) {
  var cleaned = name.replaceAll(RegExp(r'[\x00-\x1f\x7f/\\:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
  // A leading dot hides the file, trailing dots and spaces are dropped by Windows.
  cleaned = cleaned.replaceFirst(RegExp(r'^\.+'), '').replaceFirst(RegExp(r'[. ]+$'), '');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return fallback;
  }
  const max = 180;
  if (cleaned.length > max) {
    final dot = cleaned.lastIndexOf('.');
    final ext = dot > 0 && cleaned.length - dot <= 16 ? cleaned.substring(dot) : '';
    cleaned = cleaned.substring(0, max - ext.length) + ext;
  }
  return cleaned;
}

/// The name and the size text the forum prints with the attachment link [link]: its text, and the `(36.73 KB, 下载次数:
/// 0)` beside it (`em.xg1` in the post) or the line under it (`dd > p` in the list below the post).
({String filename, String? sizeText}) attachmentLinkInfoOf(uh.Element link) {
  final filename = (link.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  String? sizeText;
  final span = link.parent;
  if (span != null && span.localName == 'span') {
    sizeText = span.querySelector('em.xg1')?.text;
  }
  if (sizeText == null) {
    uh.Element? dd = link;
    while (dd != null && dd.localName != 'dd') {
      dd = dd.parent;
    }
    sizeText = dd?.querySelectorAll('p').map((e) => e.text ?? '').where((e) => attachmentSizeOf(e) != null).firstOrNull;
  }
  return (filename: filename, sizeText: sizeText);
}
