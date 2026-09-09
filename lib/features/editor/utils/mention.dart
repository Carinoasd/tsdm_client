import 'package:universal_html/parsing.dart';

/// `[@]name[/@]`, the mention format of the retired `amucallme_dzx` plugin that the bbcode editor still emits.
///
/// The name may contain brackets (`[TSDM]Alice`), so it runs up to the first `[/@]` on the line; only another `[@]`
/// ends it early so a literal unpaired `[@]` does not swallow the next chip.
final RegExp _legacyMentionRe = RegExp(r'\[@\]((?:(?!\[@\])[^\r\n])+?)\[/@\]');

/// Rewrite editor mentions in [bbcode] to the official Discuz! format.
///
/// Discuz! X5 shows `[@]name[/@]` as plain text. The official mention is a bare `@name` followed by whitespace,
/// which the server turns into a profile link and a notice when the poster's user group is allowed to mention.
/// Every embed becomes `@name`, with a space appended unless whitespace already follows.
String toOfficialMentions(String bbcode) => bbcode.replaceAllMapped(_legacyMentionRe, (m) {
  final name = m.group(1)!.trim();
  final followedByWhitespace = m.end < bbcode.length && bbcode[m.end].trim().isEmpty;
  return followedByWhitespace ? '@$name' : '@$name ';
});

/// Usernames the current user may mention, from the official `misc.php?mod=getatuser&inajax=1`.
///
/// ```xml
/// <?xml version="1.0" encoding="utf-8"?>
/// <root><![CDATA[Alice,Bob]]></root>
/// ```
///
/// Returns an empty list when the response is not that document.
List<String> parseAtUserList(String xml) {
  final String text;
  try {
    final root = parseXmlDocument(xml).documentElement;
    if (root == null || root.localName != 'root') {
      return const [];
    }
    text = root.innerText;
  } on Exception {
    return const [];
  }
  return text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
}
