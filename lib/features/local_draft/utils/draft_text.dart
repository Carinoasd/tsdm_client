final _tagRe = RegExp(r'\[/?[a-zA-Z*@]+(?:=[^\]\n]*)?\]');
final _emojiRe = RegExp(r'\{:\d+_\d+:\}');
final _spaceRe = RegExp(r'\s+');

/// The text of the BBCode [bbcode] in a few words, to recognize a draft by: tags taken out, emoji codes written as
/// [emoji], white space folded, at most [max] characters (an ellipsis after).
String draftSnippet(String bbcode, {String emoji = '', int max = 80}) {
  final text = bbcode.replaceAll(_emojiRe, emoji).replaceAll(_tagRe, '').replaceAll(_spaceRe, ' ').trim();
  final runes = text.runes.toList();
  return runes.length > max ? '${String.fromCharCodes(runes.take(max))}…' : text;
}

/// The quote of a floor the forum puts in front of a reply (`noticetrimstr`:
/// `[quote][size=2][url=…][color=#999999]Bob 发表于 2026-10-23 10:00[/color][/url][/size]\n…[/quote]`) as its head line
/// (`header`, who wrote it and when) and the quoted text (`body`, at most [maxLines] lines), tags taken out.
({String header, String body}) quotePreviewOf(String quote, {int maxLines = 3}) {
  var text = quote.trim();
  final open = RegExp(r'^\[quote\]', caseSensitive: false);
  final close = RegExp(r'\[/quote\]$', caseSensitive: false);
  text = text.replaceFirst(open, '').replaceFirst(close, '');
  final lines = text.split('\n');
  final header = lines.first.replaceAll(_tagRe, '').trim();
  final body = lines
      .skip(1)
      .map((e) => e.replaceAll(_tagRe, '').trim())
      .where((e) => e.isNotEmpty)
      .take(maxLines)
      .join('\n');
  return (header: header, body: body);
}
