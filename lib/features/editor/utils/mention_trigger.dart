import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';

/// Opens the mention picker when the user types `@` in the editor.
///
/// Watches the controller (the only signal that works for soft keyboards too: flutter_quill's character shortcuts
/// are hardware keyboard only) and fires when the document grew by exactly one character, the debounce passed, and
/// the caret then sits right after an `@` that starts the text or follows whitespace. So `a@b` and pasted text do
/// not fire, and a typist who continues past the `@` within the debounce is not interrupted.
///
/// When [pick] returns a name the `@` is replaced by the mention chip and the cursor moves after it; null keeps the
/// `@` as typed.
final class MentionTrigger {
  /// Constructor.
  MentionTrigger({
    required this.controller,
    required this.focusNode,
    required this.pick,
    this.debounce = const Duration(milliseconds: 250),
  });

  /// The editor controller to watch.
  final BBCodeEditorController controller;

  /// Focus of the editor; the trigger only fires while it has focus.
  final FocusNode focusNode;

  /// Ask the user for a name; the argument is where the typed `@` sits in the plain text.
  final Future<String?> Function(int atOffset) pick;

  /// How long to wait after the change before checking and firing.
  final Duration debounce;

  Timer? _timer;
  int _lastLength = 0;
  bool _picking = false;
  bool _attached = false;

  /// Whether the picker opened by this trigger is showing.
  bool get isPicking => _picking;

  /// Start watching the controller.
  void attach() {
    if (_attached) {
      return;
    }
    _attached = true;
    _lastLength = controller.document.length;
    controller.addListener(_onChanged);
  }

  /// Stop watching and drop a pending check.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    if (_attached) {
      controller.removeListener(_onChanged);
      _attached = false;
    }
  }

  void _onChanged() {
    final length = controller.document.length;
    final delta = length - _lastLength;
    _lastLength = length;
    if (delta == 0) {
      // A selection change only, or a change kept the length: leave a pending check alone.
      return;
    }
    _timer?.cancel();
    _timer = null;
    if (delta != 1 || _picking || controller.readOnly) {
      return;
    }
    _timer = Timer(debounce, () => unawaited(_fire()));
  }

  /// The offset of the typed `@` before the caret when every condition holds, else null.
  int? _atOffset() {
    if (controller.readOnly || !focusNode.hasFocus || _picking) {
      return null;
    }
    final selection = controller.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      return null;
    }
    final caret = selection.baseOffset;
    if (caret < 1) {
      return null;
    }
    final text = controller.document.toPlainText();
    if (caret > text.length || text[caret - 1] != '@') {
      return null;
    }
    if (caret >= 2 && text[caret - 2].trim().isNotEmpty) {
      return null;
    }
    return caret - 1;
  }

  Future<void> _fire() async {
    _timer = null;
    final atOffset = _atOffset();
    if (atOffset == null) {
      return;
    }
    _picking = true;
    try {
      final name = (await pick(atOffset))?.trim();
      if (name == null || name.isEmpty || !_attached) {
        return;
      }
      // The document may have changed while the picker was up; only replace the `@` that is still there.
      final text = controller.document.toPlainText();
      if (atOffset >= text.length || text[atOffset] != '@') {
        return;
      }
      controller
        ..replaceText(atOffset, 1, '', TextSelection.collapsed(offset: atOffset))
        ..insertMention(name);
    } finally {
      _picking = false;
      _lastLength = controller.document.length;
    }
  }
}
