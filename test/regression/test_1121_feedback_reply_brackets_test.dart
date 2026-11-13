import 'package:dart_bbcode_parser/dart_bbcode_parser.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/features/diagnostics/feedback.dart';

/// F2-2: the reply to the feedback thread is put into the reply bar as BBCode (`insertBBCode`, the editor's parser)
/// and sent to the forum as BBCode, so a `[b]`, `[url=…]` or `[/quote]` the user wrote became formatting, a link, or
/// broke the reply. A zero width space after each `[` of the description ([escapeBBCodeBrackets]) keeps both parsers
/// from reading a tag: the text shows as written. The environment line is left as it is.
///
/// Protocol fact (test forum, a moderator account outside the group the forum's tag filter applies to): a reply
/// `[​b]x[​/b] [b]y[/b]` was stored as sent and rendered `[​b]x[​/b] <strong>y</strong>`; the plugin's
/// JSON `message` keeps the zero width spaces. The forum's own tag filter (`pmfilter`) does the same thing.

const _zw = '​';
const _env = 'tsdm_client 1.57.1+173 · android 14 (API 34)';

const _description =
    'Quoting breaks: [quote]a[/quote]\n'
    'This shows bold: [b]x[/b], a link [url=https://forum.test]y[/url], [img]https://forum.test/a.png[/img]\n'
    'Log: [ERROR] [2026-11-16] empty list []';

/// The reply as the editor has it after the thread page put it in, and as it is sent.
String _sent(String reply) {
  final controller = buildBBCodeEditorController()..insertBBCode(reply);
  return controller.toForumBBCode();
}

void main() {
  test('every [ of the description is followed by a zero width space; nothing else changes', () {
    final escaped = escapeBBCodeBrackets(_description);
    expect(escaped.replaceAll(_zw, ''), _description);
    expect(RegExp('\\[(?!$_zw)').hasMatch(escaped), isFalse);
    expect('['.allMatches(escaped).length, '['.allMatches(_description).length);
    expect(escapeBBCodeBrackets(escaped), escaped, reason: 'idempotent');
    expect(escapeBBCodeBrackets('no brackets'), 'no brackets');
  });

  test('the reply: the description escaped, the environment line untouched', () {
    final reply = feedbackReplyText(_description, _env);
    expect(reply, '${escapeBBCodeBrackets(_description)}\n\n$_env');
    expect(reply, endsWith('\n\n$_env'));
  });

  test("the editor's parser reads no tag in it: plain text, no attribute", () {
    final reply = feedbackReplyText(_description, _env);
    final delta = parseBBCodeTextToDelta(reply);
    for (final op in delta.operations) {
      expect(op.attributes, anyOf(isNull, isEmpty), reason: '$op');
      expect(op.data, isA<String>(), reason: 'no embed (image, ...): $op');
    }
    // Before: the same text unescaped turns into formatting and embeds.
    final before = parseBBCodeTextToDelta('$_description\n\n$_env');
    expect(before.operations.any((op) => (op.attributes?.isNotEmpty ?? false) || op.data is! String), isTrue);
  });

  test('what is sent is what was written, the zero width spaces kept', () {
    final reply = feedbackReplyText(_description, _env);
    final sent = _sent(reply);
    expect(sent.trimRight(), reply);
    expect(sent.replaceAll(_zw, '').trimRight(), '$_description\n\n$_env');
    for (final tag in ['[b]', '[/b]', '[url=', '[img]', '[quote]']) {
      expect(sent, isNot(contains(tag)), reason: tag);
    }
  });
}
