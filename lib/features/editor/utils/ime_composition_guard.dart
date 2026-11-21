import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_quill/flutter_quill.dart' show QuillRawEditorState;

/// Ends the composition of the input method when the editor changes under it, on Windows.
///
/// While an input method composes (Zhuyin or Pinyin not confirmed yet), the editor changing by anything but the
/// input method (a selection dragged with the mouse, a caret put elsewhere, text inserted by a button) leaves the
/// two apart on Windows: the editor tells the engine its new state without a composing range, the engine forgets its
/// composition for that, yet never tells the input method, which still holds its string. The next key the input
/// method takes makes it send the whole string again, and the editor inserts it as new text: the text is there twice.
///
/// The engine only tells the input method to drop its composition when the input connection closes. So that is what
/// happens here: the connection is closed at once and opened again after the frame, unless the editor opens it by
/// itself before that (a tap asks for the keyboard when it is done). The composed text stays in the document as
/// typed, like on a loss of focus.
///
/// Watches the controller. The input method's own updates reach the controller as well; they are told apart by the
/// editor's record of what the input method knows, which then already agrees with the controller.
final class ImeCompositionGuard {
  /// Constructor.
  ImeCompositionGuard({required this.controller, required this.focusNode});

  /// The editor controller to watch.
  final BBCodeEditorController controller;

  /// Focus of the editor, the way to its state; the connection only opens again while it has focus.
  FocusNode focusNode;

  bool _attached = false;
  bool _reopenScheduled = false;

  /// Only the Windows engine keeps the input method's composition alive behind the editor's back.
  static bool get _enabled => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Start watching the controller.
  ///
  /// Call before the editor is built on the controller where possible: a listener ahead of the editor's own sees
  /// what the input method knows before the editor overwrites it, which is what catches a caret moved inside the
  /// composing text. A listener behind it still catches a selection and a caret outside of the composing text.
  void attach() {
    if (_attached) {
      return;
    }
    _attached = true;
    controller.addListener(_onChanged);
  }

  /// Stop watching.
  void dispose() {
    if (_attached) {
      controller.removeListener(_onChanged);
      _attached = false;
    }
  }

  QuillRawEditorState? get _editorState {
    final state = focusNode.context?.findAncestorStateOfType<QuillRawEditorState>();
    return state != null && state.mounted ? state : null;
  }

  void _onChanged() {
    if (!_enabled) {
      return;
    }
    final state = _editorState;
    // What the input method knows; null without a connection.
    final remote = state?.currentTextEditingValue;
    if (state == null || remote == null) {
      return;
    }
    final composing = remote.composing;
    if (!composing.isValid || composing.isCollapsed) {
      return;
    }
    final local = state.textEditingValue;
    final selection = local.selection;
    final fromInputMethod =
        remote.text == local.text &&
        remote.selection.baseOffset == selection.baseOffset &&
        remote.selection.extentOffset == selection.extentOffset;
    final caretInComposing =
        selection.isCollapsed && selection.baseOffset >= composing.start && selection.baseOffset <= composing.end;
    if (fromInputMethod && caretInComposing) {
      return;
    }

    state.closeConnectionIfNeeded();
    if (_reopenScheduled) {
      return;
    }
    _reopenScheduled = true;
    // Not at once where it is up to the guard (a drag, a key, a button): the editor's per-frame updates of the old
    // connection stop at the frame in between, and whatever the input method still sends for its cancel finds no
    // client, so it cannot touch the new selection. After a tap the editor has opened it again by then (with a
    // collapsed selection, or an extended one for a shift click), and it is left as it is.
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _reopenScheduled = false;
        if (!_attached || !focusNode.hasFocus) {
          return;
        }
        final state = _editorState;
        if (state != null && !state.hasConnection) {
          state.openConnectionIfNeeded();
        }
      })
      ..ensureVisualUpdate();
  }
}
