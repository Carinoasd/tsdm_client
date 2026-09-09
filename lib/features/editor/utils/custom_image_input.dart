/// Helpers for the user's own image stickers (GitHub #5).
library;

final _imgTagRe = RegExp(r'^\[img(?:=[^\]]*)?\]\s*(.+?)\s*\[/img\]$', caseSensitive: false, dotAll: true);

/// Extract the image url from what the user pasted: a bare `http(s)://` url or an `[img]url[/img]` /
/// `[img=w,h]url[/img]` code (the "图床代码" hosting sites hand out). Null when neither.
String? parseCustomImageInput(String raw) {
  var text = raw.trim();
  final tag = _imgTagRe.firstMatch(text);
  if (tag != null) {
    text = tag.group(1)!.trim();
  }
  final uri = Uri.tryParse(text);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
    return null;
  }
  return text;
}

/// The BBCode inserted into the editor for a saved image [url].
String customImageBBCode(String url) => '[img]$url[/img]';

/// Whether an emoji picker result is a saved image (to insert as BBCode) rather than an emoji code.
bool isCustomImageBBCode(String? result) => result != null && result.startsWith('[img]');
