/// Cloudflare "email address obfuscation" support.
///
/// The forum sits behind Cloudflare, which rewrites every email address in a page so scrapers can not read it:
///
/// * a `mailto:` link (`[email=addr]text[/email]`) becomes `<a href="/cdn-cgi/l/email-protection#HASH">text</a>`;
/// * an address in the link text (`[email]addr[/email]`) additionally gets its text replaced by
///   `<span class="__cf_email__" data-cfemail="HASH">[email&#160;protected]</span>`;
/// * a bare address in text becomes
///   `<a href="/cdn-cgi/l/email-protection" class="__cf_email__" data-cfemail="HASH">[email&#160;protected]</a>`.
///
/// A browser undoes this with Cloudflare's `email-decode.min.js`; the app undoes it here, the same way and only for
/// the page being read. The hash is hex: the first byte is the key, every following byte is XORed with it, the
/// result is UTF-8 text.
///
/// Safety: a post can carry any hash, so the decoded text is accepted only when it looks like an email address and
/// the only thing ever built from it is a `mailto:` link to that address. Anything else stays as it came.
library;

import 'dart:convert';

import 'package:universal_html/html.dart' as uh;

const _emailProtectionPath = '/cdn-cgi/l/email-protection';

/// Plausible address: RFC 5322 local part characters, a dotted domain, no whitespace, no query or fragment characters.
final _emailRe = RegExp(
  r"^[A-Za-z0-9.!#$%&'*+/=^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$",
);
final _hexRe = RegExp(r'^[0-9a-fA-F]+$');

/// Decode a Cloudflare email-protection [hash] into the address it hides.
///
/// Returns null unless [hash] is well formed and the decoded text is an email address.
String? decodeCloudflareEmail(String hash) {
  final h = hash.trim();
  // Key byte plus at least "a@b.c", at most 254 characters of address.
  if (h.length < 12 || h.length.isOdd || h.length > 2 + 254 * 2 * 2 || !_hexRe.hasMatch(h)) {
    return null;
  }
  final key = int.parse(h.substring(0, 2), radix: 16);
  final bytes = <int>[];
  for (var i = 2; i < h.length; i += 2) {
    bytes.add(int.parse(h.substring(i, i + 2), radix: 16) ^ key);
  }
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return null;
  }
  if (text.length > 254 || !_emailRe.hasMatch(text)) {
    return null;
  }
  return text;
}

/// The address hidden in an email-protection [url] (`…/cdn-cgi/l/email-protection#HASH`, relative or absolute).
///
/// Returns null for any other url, or when the hash does not decode to an address.
String? cloudflareEmailFromUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.path.endsWith(_emailProtectionPath) || uri.fragment.isEmpty) {
    return null;
  }
  return decodeCloudflareEmail(uri.fragment);
}

/// Whether [url] is an email-protection link.
bool isCloudflareEmailUrl(String url) => Uri.tryParse(url.trim())?.path.endsWith(_emailProtectionPath) ?? false;

/// Turn every email-protection node under [root] back into what the author wrote: `mailto:` links and readable
/// addresses. Nodes whose hash does not decode to an address are left untouched.
///
/// Returns the number of nodes rewritten. Idempotent.
int rewriteCloudflareEmails(uh.Element root) {
  var count = 0;
  for (final a in root.querySelectorAll('a')) {
    final href = a.attributes['href'];
    if (href == null || !isCloudflareEmailUrl(href)) {
      continue;
    }
    // The text placeholder, on the link itself (bare address) or inside it (address as link text).
    final placeholder = a.attributes.containsKey('data-cfemail')
        ? a
        : a.querySelectorAll('.__cf_email__').firstOrNull;
    final address =
        cloudflareEmailFromUrl(href) ?? decodeCloudflareEmail(placeholder?.attributes['data-cfemail'] ?? '');
    if (address == null) {
      continue;
    }
    a.attributes['href'] = 'mailto:$address';
    if (placeholder != null) {
      _reveal(placeholder, decodeCloudflareEmail(placeholder.attributes['data-cfemail'] ?? '') ?? address);
    }
    count++;
  }
  // Placeholders outside such links.
  for (final e in root.querySelectorAll('.__cf_email__')) {
    final address = decodeCloudflareEmail(e.attributes['data-cfemail'] ?? '');
    if (address == null) {
      continue;
    }
    _reveal(e, address);
    count++;
  }
  return count;
}

void _reveal(uh.Element placeholder, String address) {
  placeholder
    ..text = address
    ..attributes.remove('data-cfemail')
    ..classes.remove('__cf_email__');
}
