import 'dart:convert';

/// Subject limit every post form submission is checked against, whatever the forum's settings, the thread type or the
/// member's group (`checkpost()`: `dstrlen($subject) > 255`, counted with [discuzStrLen] on the escaped subject).
const discuzSubjectServerLimit = 255;

/// Discuz `dstrlen` on UTF-8: an ASCII character counts 1, any other Unicode scalar (CJK, emoji) counts 2.
int discuzStrLen(String value) => value.runes.fold(0, (sum, rune) => sum + (rune <= 0x7F ? 1 : 2));

/// Upstream `dhtmlspecialchars` with default flags: only `&`, `"`, `<` and `>` are escaped, entities included.
String discuzEscape(String value) =>
    value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// Length of a thread [subject] as the forum checks it when the form is submitted: the subject is trimmed and escaped
/// (`dhtmlspecialchars`, `&` takes 5) before `dstrlen` counts it ([discuzStrLen]).
int discuzSubjectLength(String subject) => discuzStrLen(discuzEscape(subject.trim()));

/// Bytes of a post [message] the forum checks against its maximum post size (`strlen`, UTF-8 bytes).
int discuzMessageBytes(String message) => utf8.encode(message).length;

final _quoteRe = RegExp(r'\[quote\].+?\[/quote\]', caseSensitive: false, dotAll: true);
final _postbgRe = RegExp(r'\[postbg\].+?\[/postbg\]', caseSensitive: false, dotAll: true);

/// Whether a post [message] is shorter than the forum's minimum post size [min] (UTF-8 bytes) as `checkpost()` counts
/// it: without the quoted part (`[quote]…[/quote]`), and without the post background (`[postbg]…[/postbg]`), either
/// being too short is enough.
bool discuzMessageTooShort(String message, int min) =>
    discuzMessageBytes(message.replaceAll(_quoteRe, '')) < min ||
    discuzMessageBytes(message.replaceAll(_postbgRe, '')) < min;
