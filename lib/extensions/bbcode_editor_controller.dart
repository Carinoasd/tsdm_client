import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:tsdm_client/utils/bbcode/spoiler_normalizer.dart';

/// What leaves the editor for the forum, a template or the clipboard.
extension BBCodeEditorControllerForum on BBCodeEditorController {
  /// [toBBCode] with the nesting around block markers repaired, see [normalizeBlockMarkerNesting].
  String toForumBBCode() => normalizeBlockMarkerNesting(toBBCode());
}
