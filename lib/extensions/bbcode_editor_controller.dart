import 'dart:convert';

import 'package:dart_bbcode_parser/dart_bbcode_parser.dart';
import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/bbcode/spoiler_normalizer.dart';

/// What leaves the editor for the forum, a template or the clipboard.
extension BBCodeEditorControllerForum on BBCodeEditorController {
  /// [toBBCode] with the nesting around block markers repaired, see [normalizeBlockMarkerNesting].
  String toForumBBCode() => normalizeBlockMarkerNesting(toBBCode());

  /// Insert a mention of [username] at the cursor (replacing the selection) and put the cursor after it.
  ///
  /// The same `bbcodeUserMention` embed the toolbar `@` button inserts, written straight into the document like that
  /// button does: a username is not BBCode, so it never goes through the parser, which would drop a chip whose name
  /// has an unclosed `[` (`x[y`). At send time `toOfficialMentions` turns the chip into the official `@username `.
  void insertMention(String username) {
    final position = selection.baseOffset;
    final length = selection.extentOffset - position;
    final delta = Delta()
      ..insert({
        'bbcodeUserMention': jsonEncode({'username': username}),
      });
    replaceText(position, length, delta, null);
    moveCursorToPosition(position + 1);
  }

  /// Insert the forum emoji [code] (`{:12_865:}`) at the cursor (replacing the selection) and put the cursor after it.
  ///
  /// The `bbcodeEmoji` embed the toolbar's emoji button inserts, written straight into the document like
  /// [insertMention] does: the BBCode parser leaves an emoji code as text.
  void insertEmoji(String code) {
    final position = selection.baseOffset;
    final length = selection.extentOffset - position;
    final delta = Delta()
      ..insert({
        'bbcodeEmoji': jsonEncode({'code': code}),
      });
    replaceText(position, length, delta, null);
    moveCursorToPosition(position + 1);
  }

  /// Put a kept draft back: the editor's own document [delta] (Quill delta JSON) when it loads, which keeps what BBCode
  /// does not carry, else [body] parsed into rich text ([parse], the editor's BBCode parser setting) or as raw text;
  /// the cursor goes to the end.
  void loadDraft(String body, {required bool parse, String? delta}) {
    var loaded = false;
    if (delta != null) {
      try {
        final json = jsonDecode(delta);
        if (json is List) {
          setDocumentFromJson(json);
          loaded = true;
        }
      } on Object catch (e) {
        talker.warning('editor: the kept document does not load, the text is parsed again: $e');
      }
    }
    if (!loaded) {
      if (parse) {
        setDocumentFromDelta(parseBBCodeTextToDelta(body));
      } else {
        setDocumentFromRawText(normalizeBlockMarkerNesting(body));
      }
    }
    moveCursorToEnd();
  }
}
