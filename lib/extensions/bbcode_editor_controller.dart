import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:tsdm_client/utils/bbcode/spoiler_normalizer.dart';

/// What leaves the editor for the forum, a template or the clipboard.
extension BBCodeEditorControllerForum on BBCodeEditorController {
  /// [toBBCode] with the nesting around block markers repaired, see [normalizeBlockMarkerNesting].
  String toForumBBCode() => normalizeBlockMarkerNesting(toBBCode());

  /// Insert a mention of [username] at the cursor (replacing the selection) and put the cursor after it.
  ///
  /// The same chip the toolbar `@` button inserts: `[@]username[/@]` goes through the BBCode parser, which yields the
  /// `bbcodeUserMention` embed. At send time `toOfficialMentions` turns it into the official `@username `.
  void insertMention(String username) {
    final position = selection.baseOffset;
    insertBBCode('[@]$username[/@]');
    moveCursorToPosition(position + 1);
  }
}
