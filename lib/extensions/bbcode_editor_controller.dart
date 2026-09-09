import 'dart:convert';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
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
}
