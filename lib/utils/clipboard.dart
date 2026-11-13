import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/features/open_in_app/clipboard_link_prompt.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart' as toast;

/// Copy [data] into system clipboard and show a snack bar if [showSnackBar] is
/// true.
///
/// Goes through [setClipboardText]: a forum link copied so is not offered again when the app comes back.
Future<void> copyToClipboard(BuildContext context, String data, {bool showSnackBar = true}) async {
  await setClipboardText(data);
  if (!context.mounted) {
    return;
  }
  if (showSnackBar) {
    toast.showSnackBar(context: context, message: context.t.general.copiedToClipboard);
  }
}

/// Put [text] into the system clipboard: the one place of the app writing to it.
///
/// A forum link in [text] is remembered as copied in the app ([rememberCopiedInApp]), so the clipboard prompt does not
/// offer it back when the app comes to the front.
Future<void> setClipboardText(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  await rememberCopiedInApp(text);
}

/// Get the plain text content in system clipboard.
Future<String?> getPlainTextFromClipboard() async {
  final data = await Clipboard.getData('text/plain');
  return data?.text;
}
