// The clipboard hook of flutter_quill is marked experimental; it is the one place every paste goes through (the
// shortcut, the desktop context menu and the mobile selection menu all call `QuillController.clipboardPaste`).
// ignore_for_file: experimental_member_use

import 'package:flutter/services.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show Document, QuillClipboardConfig, QuillController, QuillControllerConfig;

/// An empty editor controller as [buildBBCodeEditorController] builds one, which asks [onPaste] first on every paste:
/// true when it took the paste itself, false to paste as before (text, rich text).
BBCodeEditorController buildPasteAwareEditorController({required Future<bool> Function() onPaste}) => QuillController(
  document: Document(),
  selection: const TextSelection.collapsed(offset: 0),
  config: QuillControllerConfig(clipboardConfig: QuillClipboardConfig(onClipboardPaste: onPaste)),
);
