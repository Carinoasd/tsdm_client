import 'package:tsdm_client/features/netdisk/models/netdisk_link.dart';
import 'package:universal_html/html.dart' as uh;

/// Every online storage service recognised, in the order they are tried. Add a service here to support it.
const netdiskProviders = <NetdiskProvider>[
  NetdiskProvider(name: '百度网盘', hosts: ['pan.baidu.com', 'yun.baidu.com'], codeParam: 'pwd'),
  NetdiskProvider(
    name: '蓝奏云',
    hosts: [
      'lanzou.com',
      'ilanzou.com',
      'lanzoux.com',
      'lanzn.com',
      'lanzoui.com',
      'lanzouw.com',
      'lanzouv.com',
      'lanzouy.com',
      'lanzouj.com',
      'lanzouk.com',
      'lanzoup.com',
      'lanzout.com',
      'lanzouf.com',
      'lanzouh.com',
      'lanzoub.com',
      'lanzouo.com',
      'lanzouq.com',
      'lanzour.com',
      'lanzous.com',
      'lanzouu.com',
    ],
  ),
  NetdiskProvider(name: '夸克网盘', hosts: ['pan.quark.cn']),
  NetdiskProvider(name: '阿里云盘', hosts: ['aliyundrive.com', 'alipan.com']),
  NetdiskProvider(name: '123云盘', hosts: ['123pan.com', '123pan.cn', '123865.com', '123684.com'], codeParam: 'pwd'),
  NetdiskProvider(name: '115网盘', hosts: ['115.com', '115cdn.com', 'anxia.com'], codeParam: 'password'),
  NetdiskProvider(name: '城通网盘', hosts: ['ctfile.com', '545c.com', '306t.com', '474b.com', '089u.com']),
  NetdiskProvider(name: '天翼云盘', hosts: ['cloud.189.cn']),
  NetdiskProvider(name: '迅雷云盘', hosts: ['pan.xunlei.com'], codeParam: 'pwd'),
  NetdiskProvider(name: 'Mega', hosts: ['mega.nz']),
  NetdiskProvider(name: 'Google Drive', hosts: ['drive.google.com']),
  NetdiskProvider(name: 'OneDrive', hosts: ['onedrive.live.com', '1drv.ms', 'sharepoint.com']),
  NetdiskProvider(name: 'MediaFire', hosts: ['mediafire.com']),
];

/// The provider of the host of [url], null when it is not an online storage link.
NetdiskProvider? netdiskProviderOf(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase();
  if (host == null || host.isEmpty) {
    return null;
  }
  for (final provider in netdiskProviders) {
    for (final h in provider.hosts) {
      if (host == h || host.endsWith('.$h')) {
        return provider;
      }
    }
  }
  return null;
}

/// The url at the start of [href] as [parseNetdiskLinks] reads it (it stops at a full-width character and drops the
/// punctuation a sentence appends), null when it is no online storage link.
String? netdiskUrlOf(String href) {
  final match = _urlRe.matchAsPrefix(href.trim());
  if (match == null) {
    return null;
  }
  var url = match.group(0)!;
  while (url.isNotEmpty && _trailingPunctuation.contains(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }
  return netdiskProviderOf(url) == null ? null : url;
}

final _urlRe = RegExp(r'https?://[^\s<>"　-〿一-鿿＀-￯]+');
const _trailingPunctuation = '.,;:!?)]}\'"';

/// Words naming the archive password come first so that `解压密码` is not read as a plain `密码`.
final _labelRe = RegExp(
  r'(?<unzip>解[压壓][缩縮]?包?密?[码碼]|[压壓][缩縮]包?密?[码碼]|unzip\s*(?:password|pwd|code)|zip\s*(?:password|pwd))'
  r'|(?<extract>提取密?[码碼]|提取[码碼]|访问[码碼]|訪問[码碼]|密[码碼]|(?<![A-Za-z])(?:pwd|password|passcode|extract\s*code|code)(?![A-Za-z]))',
  caseSensitive: false,
);

/// Separator between the label and its value: a colon or equal sign, or just white space.
final _sepRe = RegExp(r'\s*[:：=＝]\s*|[ \t　]+');

/// English words are labels only with a colon or equal sign: `QR code here` is no code.
final _strictSepRe = RegExp(r'\s*[:：=＝]\s*');
final _extractValueRe = RegExp('[A-Za-z0-9]{3,8}(?![A-Za-z0-9])');
final _unzipValueRe = RegExp(r'''[^\s,，;；。、)）\]】」』>》"'”’]{1,48}''');

final _latinRe = RegExp('[A-Za-z]');
final _noneRe = RegExp(r'^(无|無|没有|沒有|none|null|nil|-+)$', caseSensitive: false);

/// How far from a link, in characters, a label still belongs to it.
const _reach = 200;

/// A code written near a link, before or after it get claimed by the nearest link.
typedef _Label = ({int start, int end, bool unzip, String value});

/// Find every online storage link in [text] and the codes written near it.
///
/// A code belongs to the closest link within [_reach] characters; a code right after a link is preferred over one
/// right before the next. A `pwd` of the url itself is the extract code.
List<NetdiskLink> parseNetdiskLinks(String text) {
  final links = <({int start, int end, String url, NetdiskProvider provider})>[];
  for (final match in _urlRe.allMatches(text)) {
    var url = match.group(0)!;
    while (url.isNotEmpty && _trailingPunctuation.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    final provider = netdiskProviderOf(url);
    if (provider == null) {
      continue;
    }
    links.add((start: match.start, end: match.start + url.length, url: url, provider: provider));
  }
  if (links.isEmpty) {
    return const [];
  }

  // Any url, not only an online storage one: `https://example.com/a?code=1234` holds no code of a share.
  final urlRanges = [for (final m in _urlRe.allMatches(text)) (start: m.start, end: m.end)];
  bool insideLink(int start, int end) => urlRanges.any((r) => start < r.end && end > r.start);

  final labels = <_Label>[];
  for (final m in _labelRe.allMatches(text)) {
    if (insideLink(m.start, m.end)) {
      continue;
    }
    final unzip = m.namedGroup('unzip') != null;
    final sep = (_latinRe.hasMatch(m.group(0)!) ? _strictSepRe : _sepRe).matchAsPrefix(text, m.end);
    if (sep == null) {
      continue;
    }
    final valueMatch = (unzip ? _unzipValueRe : _extractValueRe).matchAsPrefix(text, sep.end);
    if (valueMatch == null) {
      continue;
    }
    var value = valueMatch.group(0)!;
    if (unzip) {
      // `解压密码：无` and the like say there is none.
      if (_noneRe.hasMatch(value)) {
        continue;
      }
      // The next label is not the value.
      if (_labelRe.matchAsPrefix(value) != null) {
        continue;
      }
      // A value glued to the next url stops before it.
      final cut = value.indexOf('http');
      if (cut > 0) {
        value = value.substring(0, cut);
      }
    }
    if (insideLink(valueMatch.start, valueMatch.end)) {
      continue;
    }
    labels.add((start: m.start, end: valueMatch.end, unzip: unzip, value: value));
  }

  final extract = List<({int distance, String value})?>.filled(links.length, null);
  final unzip = List<({int distance, String value})?>.filled(links.length, null);
  for (final label in labels) {
    int? best;
    var bestDistance = _reach + 1;
    for (var i = 0; i < links.length; i++) {
      final link = links[i];
      final int distance;
      if (label.start >= link.end) {
        distance = label.start - link.end;
      } else if (label.end <= link.start) {
        // Written before the link: a little farther than the same gap after it, unless it starts a line and the link
        // follows right behind it (`提取码：abcd https://…`): then it is meant for that link.
        distance = _startsLineRightBefore(text, label, link.start) ? 0 : link.start - label.end + 20;
      } else {
        continue;
      }
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    if (best == null || bestDistance > _reach) {
      continue;
    }
    final slot = label.unzip ? unzip : extract;
    final current = slot[best];
    if (current == null || bestDistance < current.distance) {
      slot[best] = (distance: bestDistance, value: label.value);
    }
  }

  return [
    for (var i = 0; i < links.length; i++)
      NetdiskLink(
        url: links[i].url,
        provider: links[i].provider,
        extractCode: extract[i]?.value ?? _codeOfUrl(links[i].url, links[i].provider),
        unzipPassword: unzip[i]?.value,
      ),
  ];
}

bool _startsLineRightBefore(String text, _Label label, int linkStart) {
  if (text.substring(label.end, linkStart).trim().isNotEmpty) {
    return false;
  }
  final lineStart = (label.start == 0 ? -1 : text.lastIndexOf('\n', label.start - 1)) + 1;
  return text.substring(lineStart, label.start).trim().isEmpty;
}

String? _codeOfUrl(String url, NetdiskProvider provider) {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    return null;
  }
  final code = uri.queryParameters[provider.codeParam ?? 'pwd'] ?? uri.queryParameters['pwd'];
  return code == null || code.isEmpty ? null : code;
}

/// The text of [root] as the reader sees it, with the target of every link whose text does not show it, for
/// [parseNetdiskLinks].
String netdiskTextOf(uh.Node root) {
  final buffer = StringBuffer();
  void walk(uh.Node node) {
    switch (node.nodeType) {
      case uh.Node.TEXT_NODE:
        buffer.write(node.text);
      case uh.Node.ELEMENT_NODE:
        final element = node as uh.Element;
        final tag = element.tagName.toLowerCase();
        if (tag == 'script' || tag == 'style') {
          return;
        }
        if (tag == 'br') {
          buffer.write('\n');
          return;
        }
        final isBlock = const {'p', 'div', 'li', 'tr', 'blockquote', 'pre', 'h1', 'h2', 'h3', 'h4'}.contains(tag);
        if (isBlock) {
          buffer.write('\n');
        }
        if (tag == 'a') {
          final href = element.attributes['href'];
          final inner = (element.text ?? '').trim();
          if (href != null && netdiskProviderOf(href) != null) {
            // The target is what is opened; the text is kept when it says something else than the url.
            if (inner.isNotEmpty && !inner.startsWith('http')) {
              buffer
                ..write(inner)
                ..write(' ');
            }
            buffer
              ..write(href)
              ..write(' ');
            return;
          }
        }
        node.childNodes.forEach(walk);
        if (isBlock) {
          buffer.write('\n');
        }
    }
  }

  walk(root);
  return buffer.toString();
}

/// Plain text of [links] to copy: the name, the link and the codes of each, a blank line between.
String netdiskLinksToText(
  List<NetdiskLink> links, {
  required String extractCodeLabel,
  required String unzipPasswordLabel,
}) => links
    .map(
      (l) => [
        l.provider.name,
        l.url,
        if (l.extractCode != null) '$extractCodeLabel: ${l.extractCode}',
        if (l.unzipPassword != null) '$unzipPasswordLabel: ${l.unzipPassword}',
      ].join('\n'),
    )
    .join('\n\n');
