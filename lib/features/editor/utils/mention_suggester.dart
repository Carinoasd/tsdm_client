import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/features/editor/utils/mention_suggestions.dart';

/// Completes a typed `@` with an author of the thread: what the suggestion bar over the editor shows and inserts.
///
/// Watches the controller like the mention trigger does (the only signal that works for soft keyboards too). The bar
/// opens when the document grew by exactly one character and the caret then sits right after an `@` that starts the
/// text or follows whitespace ([mentionFragmentAt]), so `a@b` and pasted text do not open it. It stays open while the
/// caret stays in that fragment, filtering the suggestions by what is typed after the `@`; a space, the caret leaving
/// the fragment, a selection, the focus going away or no suggestion matching closes it. Without any [suggestions]
/// (an editor outside a thread) nothing ever opens.
///
/// [pick] replaces the `@` and what was typed by the mention chip of the name, followed by a space, the same chip the
/// mention picker inserts (sent as the forum's `@` mention).
final class MentionSuggester extends ChangeNotifier {
  /// Constructor.
  MentionSuggester({required this.controller, required this.focusNode});

  /// The editor controller to watch and insert into.
  final BBCodeEditorController controller;

  /// Focus of the editor; the bar only shows while it has focus.
  final FocusNode focusNode;

  List<MentionSuggestion> _suggestions = const [];
  ({int atOffset, String query})? _fragment;
  List<MentionSuggestion> _visible = const [];
  int _lastLength = 0;
  bool _attached = false;

  /// Whether the last change grew the document by one character, see [_onChanged].
  bool _typed = false;

  /// Everyone who can be suggested, in order; set from the thread being read.
  List<MentionSuggestion> get suggestions => _suggestions;

  set suggestions(List<MentionSuggestion> value) {
    if (listEquals(value, _suggestions)) {
      return;
    }
    _suggestions = value;
    _update();
  }

  /// Whether there is anyone to suggest at all.
  bool get hasSuggestions => _suggestions.isNotEmpty;

  /// The suggestions matching what is typed after the `@`; empty while the bar is closed.
  List<MentionSuggestion> get visible => _visible;

  /// Whether the bar is showing.
  bool get isOpen => _visible.isNotEmpty;

  /// Start watching the controller and the focus.
  void attach() {
    if (_attached) {
      return;
    }
    _attached = true;
    _lastLength = controller.document.length;
    controller.addListener(_onChanged);
    focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    if (_attached) {
      controller.removeListener(_onChanged);
      focusNode.removeListener(_onFocusChanged);
      _attached = false;
    }
    super.dispose();
  }

  /// Close the bar, keeping the text as typed.
  void dismiss() {
    _fragment = null;
    _update();
  }

  /// Replace the `@` fragment by the mention chip of [suggestion] and a space, and close the bar.
  void pick(MentionSuggestion suggestion) {
    final fragment = _fragment;
    if (fragment == null) {
      return;
    }
    _fragment = null;
    final text = controller.document.toPlainText();
    final caret = controller.selection.baseOffset;
    final end = caret > fragment.atOffset ? caret : fragment.atOffset + 1;
    // The document may have changed under the bar; only replace the fragment that is still there.
    if (fragment.atOffset >= text.length || text[fragment.atOffset] != '@' || end > text.length) {
      _update();
      return;
    }
    controller
      ..replaceText(fragment.atOffset, end - fragment.atOffset, '', TextSelection.collapsed(offset: fragment.atOffset))
      ..insertMention(suggestion.username)
      ..insertTextAtCursor(' ');
    _lastLength = controller.document.length;
    _update();
  }

  void _onFocusChanged() {
    if (!focusNode.hasFocus && _fragment != null) {
      dismiss();
    }
  }

  void _onChanged() {
    final length = controller.document.length;
    final delta = length - _lastLength;
    _lastLength = length;
    // One character went in: the `@` may have been typed. The caret often moves in a change of its own right after
    // the text (the controller's own inserts do that), so the check also runs on the next change that keeps the
    // length.
    final typed = delta == 1 || (delta == 0 && _typed);
    _typed = delta == 1;
    if (_suggestions.isEmpty || controller.readOnly || !focusNode.hasFocus) {
      if (_fragment != null) {
        dismiss();
      }
      return;
    }
    final selection = controller.selection;
    final fragment = selection.isValid && selection.isCollapsed
        ? mentionFragmentAt(controller.document.toPlainText(), selection.baseOffset)
        : null;
    final open = _fragment;
    if (open == null) {
      // Opens only on the `@` just typed.
      if (typed && fragment != null && fragment.query.isEmpty) {
        _fragment = fragment;
        _update();
      }
      return;
    }
    _fragment = fragment != null && fragment.atOffset == open.atOffset ? fragment : null;
    _update();
  }

  void _update() {
    final fragment = _fragment;
    final visible = fragment == null
        ? const <MentionSuggestion>[]
        : filterMentionSuggestions(_suggestions, fragment.query);
    if (listEquals(visible, _visible)) {
      return;
    }
    _visible = visible;
    notifyListeners();
  }
}
