/// Parse the `inajax` answers of `home.php?mod=spacecp&ac=friend&op=add`.
///
/// The answer is XML wrapping html in CDATA. A form comes back as html; a refusal or a result comes back as a script
/// calling `errorhandle_*('message')` or `succeedhandle_*('url', 'message', {...})` and `showDialog('message', 'type')`.
///
/// With the forum's app API (plugin 2.6.0) the answer is its write result instead ([tsdmAppWriteResultOf]): the form
/// as a `page` (its document), a refusal or a result as a `handle` with the forum's message and verdict.
library;

import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

final RegExp _cdataRe = RegExp(r'<!\[CDATA\[(.*)\]\]>', dotAll: true);
final RegExp _succeedRe = RegExp(r"succeedhandle_\w+\('[^']*',\s*'([^']*)'");
final RegExp _errorRe = RegExp(r"errorhandle_\w+\('([^']*)'");
final RegExp _dialogRe = RegExp(r"showDialog\('([^']*)',\s*'(\w+)'");
final RegExp _tagRe = RegExp('<[^>]+>');

String _payload(String xml) => _cdataRe.firstMatch(xml)?.group(1) ?? xml;

/// The visible text of the html [payload], whitespace collapsed.
String _plainText(String payload) => payload.replaceAll(_tagRe, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// The add-friend form, or the forum's refusal, in [answer]: the forum's AJAX answer or the app API's write result.
///
/// A refusal of the app API names the forum's message ([TsdmAppWriteResult.reason]), or the text of its page, or
/// the app's "could not be sent": never a field of the answer.
AddFriendFormResult parseAddFriendForm(Object? answer) {
  final result = tsdmAppWriteResultOf(answer);
  if (result != null && result.kind != TsdmAppWriteKind.page) {
    // The forum refused in the window (friends already, a request pending, the member himself, not logged in).
    return AddFriendRefused(
      result.reason.isNotEmpty ? result.reason : t.friendPage.addFriend.failed,
      fromForum: result.message.isNotEmpty,
    );
  }
  final xml = tsdmAppAnswerText(answer);
  final payload = result?.documentHtml ?? _payload(xml);
  if (result == null) {
    final refused = _errorRe.firstMatch(payload)?.group(1);
    if (refused != null && refused.isNotEmpty) {
      return AddFriendRefused(refused);
    }
  }
  return _parseAddFriendForm(
    result?.document ?? parseHtmlDocument(payload),
    payload: payload,
    raw: result == null ? xml : t.friendPage.addFriend.failed,
    rawFromForum: result == null,
  );
}

AddFriendFormResult _parseAddFriendForm(
  uh.Document document, {
  required String payload,
  required String raw,
  required bool rawFromForum,
}) {
  final formHash = document.querySelector('input[name="formhash"]')?.attributes['value'] ?? '';
  final targetName = document.querySelector('td strong')?.innerText.trim() ?? '';
  final noteHint = document.querySelector('p.mtn')?.innerText.trim();
  final groups = <FriendGroup>[];
  var selectedGid = '';
  for (final option in document.querySelectorAll('select[name="gid"] option')) {
    final gid = option.attributes['value']?.trim() ?? '';
    if (gid.isEmpty) {
      continue;
    }
    groups.add(FriendGroup(gid: gid, name: option.innerText.trim()));
    if (option.attributes.containsKey('selected')) {
      selectedGid = gid;
    }
  }
  if (selectedGid.isEmpty && groups.isNotEmpty) {
    selectedGid = groups.first.gid;
  }
  if (formHash.isEmpty) {
    // Neither a refusal nor a form: report whatever text there is.
    final text = _plainText(payload);
    return AddFriendRefused(text.isEmpty ? raw : text, fromForum: text.isNotEmpty || rawFromForum);
  }
  return AddFriendForm(
    formHash: formHash,
    targetName: targetName,
    groups: groups,
    selectedGid: selectedGid,
    noteHint: noteHint == null || noteHint.isEmpty ? null : noteHint,
  );
}

/// The forum's answer to a submitted add-friend (or approve) form, in [answer]: the forum's AJAX answer or the app
/// API's write result (sent when the forum's verdict is a success, whether shown as a success or a note: the request
/// `request_has_been_sent` is a note; refused with the forum's message otherwise).
///
/// The message of an app API result is the forum's ([TsdmAppWriteResult.reason]), or the text of its page, or the
/// app's "request sent" / "could not be sent": never a field of the answer.
AddFriendResult parseAddFriendResult(Object? answer) {
  if (tsdmAppWriteResultOf(answer) case final result?) {
    final success = result.kind != TsdmAppWriteKind.page && result.succeeded;
    final message = result.reason.isNotEmpty ? result.reason : _plainText(result.documentHtml);
    return AddFriendResult(
      success: success,
      message: message.isNotEmpty ? message : (success ? t.friendPage.addFriend.sent : t.friendPage.addFriend.failed),
      // The forum's message or its page's text; not the app's "log in first" nor its words for none.
      fromForum: result.message.isNotEmpty || (result.reason.isEmpty && message.isNotEmpty),
    );
  }
  final xml = tsdmAppAnswerText(answer);
  final payload = _payload(xml);
  final succeeded = _succeedRe.firstMatch(payload)?.group(1);
  if (succeeded != null && succeeded.isNotEmpty) {
    return AddFriendResult(success: true, message: succeeded);
  }
  final failed = _errorRe.firstMatch(payload)?.group(1);
  if (failed != null && failed.isNotEmpty) {
    return AddFriendResult(success: false, message: failed);
  }
  final dialog = _dialogRe.firstMatch(payload);
  if (dialog != null) {
    return AddFriendResult(success: dialog.group(2) != 'alert', message: dialog.group(1)!);
  }
  final text = _plainText(payload);
  return AddFriendResult(success: false, message: text.isEmpty ? xml : text);
}
