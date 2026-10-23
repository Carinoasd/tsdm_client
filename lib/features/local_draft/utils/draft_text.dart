import 'package:tsdm_client/i18n/strings.g.dart';

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

/// The hints the collapsed reply box shows instead of a reply ("thread closed", "need login") in each language of the
/// app (`threadPage.closed` / `threadPage.needLogin`); the languages other than the current one are not loaded.
const _replyBoxHints = {'帖子已关闭', '貼文已關閉', 'Thread is closed', '需要登录', '需要登入', 'Need login'};

/// Whether [body] is only a hint the reply box showed instead of a reply, not a draft (GitHub #235).
///
/// 1.47.0 kept "帖子已关闭" as the draft of a thread when the box of the quick reply page showed the closed hint before
/// the thread loaded: such a draft is dropped when read, and never written again.
bool isReplyBoxHint(String body) {
  final text = body.trim();
  if (text.isEmpty) {
    return false;
  }
  final t = LocaleSettings.instance.currentTranslations.threadPage;
  return _replyBoxHints.contains(text) || text == t.closed.trim() || text == t.needLogin.trim();
}
