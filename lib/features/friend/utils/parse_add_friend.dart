/// Parse the `inajax` answers of `home.php?mod=spacecp&ac=friend&op=add`.
///
/// The answer is XML wrapping html in CDATA. A form comes back as html; a refusal or a result comes back as a script
/// calling `errorhandle_*('message')` or `succeedhandle_*('url', 'message', {...})` and `showDialog('message', 'type')`.
library;

import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:universal_html/parsing.dart';

final RegExp _cdataRe = RegExp(r'<!\[CDATA\[(.*)\]\]>', dotAll: true);
final RegExp _succeedRe = RegExp(r"succeedhandle_\w+\('[^']*',\s*'([^']*)'");
final RegExp _errorRe = RegExp(r"errorhandle_\w+\('([^']*)'");
final RegExp _dialogRe = RegExp(r"showDialog\('([^']*)',\s*'(\w+)'");
final RegExp _tagRe = RegExp('<[^>]+>');

String _payload(String xml) => _cdataRe.firstMatch(xml)?.group(1) ?? xml;

/// The add-friend form, or the forum's refusal.
AddFriendFormResult parseAddFriendForm(String xml) {
  final payload = _payload(xml);
  final refused = _errorRe.firstMatch(payload)?.group(1);
  if (refused != null && refused.isNotEmpty) {
    return AddFriendRefused(refused);
  }
  final document = parseHtmlDocument(payload);
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
    final text = payload.replaceAll(_tagRe, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return AddFriendRefused(text.isEmpty ? xml : text);
  }
  return AddFriendForm(
    formHash: formHash,
    targetName: targetName,
    groups: groups,
    selectedGid: selectedGid,
    noteHint: noteHint == null || noteHint.isEmpty ? null : noteHint,
  );
}

/// The forum's answer to a submitted add-friend (or approve) form.
AddFriendResult parseAddFriendResult(String xml) {
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
  final text = payload.replaceAll(_tagRe, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return AddFriendResult(success: false, message: text.isEmpty ? xml : text);
}
