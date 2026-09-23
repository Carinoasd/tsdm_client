/// Parse the `inajax` answers of the approval of a pending friend request (`home.php?mod=spacecp&ac=friend&op=add`
/// with `from=notice`).
///
/// The forum serves the approval form (`add2submit`, radio groups) instead of the add-friend form (`addsubmit`, a
/// group select and a note) when the member asked to be our friend. Anything that is not exactly that form fails
/// closed: a formhash alone, another form or a form sending elsewhere is never posted.
library;

import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart'
    show canonicalForumOperationUrl, isCloudflareChallengePage, unwrapAjax;
import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:tsdm_client/features/friend/models/approve_friend.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// A page that can not be used, with the reason to show.
final class ApproveFriendRejected implements Exception {
  /// Constructor.
  const ApproveFriendRejected(this.failure, this.reason);

  /// What to tell the user.
  final ApproveFriendFailure failure;

  /// What was wrong, for the log.
  final String reason;

  @override
  String toString() => 'ApproveFriendRejected($failure, $reason)';
}

/// Hidden fields the approval form may carry; any other field is an unknown form.
const _knownHidden = {'referer', 'add2submit', 'from', 'handlekey', 'formhash'};

final _gidRe = RegExp(r'^\d{1,4}$');
final _handleKeyRe = RegExp(r'^\w{1,64}$');
final _errorRe = RegExp(r"errorhandle_\w*\('([^']*)'");
final _alertRe = RegExp(r"showDialog\('([^']*)',\s*'(?:alert|error)'");
final _tagRe = RegExp('<[^>]+>');
final _spaceRe = RegExp(r'\s+');

bool _isAjax(String raw) => raw.contains('<![CDATA[');

bool _isLoginPage(uh.Document doc) =>
    (doc.querySelector('form#lsform') != null && doc.querySelector('div#um') == null) ||
    doc.querySelector('#messagelogin') != null ||
    doc.querySelector('form[name="login"]') != null;

/// A page that is not an ajax answer: a challenge, the login page or the forum's message page.
Never _rejectPage(String raw) {
  final doc = parseHtmlDocument(raw);
  if (isCloudflareChallengePage(doc)) {
    throw const ApproveFriendRejected(ApproveFriendFailure.challenge, 'cloudflare challenge');
  }
  if (_isLoginPage(doc)) {
    throw const ApproveFriendRejected(ApproveFriendFailure.notLoggedIn, 'login page');
  }
  throw const ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'not an ajax answer');
}

/// The approval form of the request of [targetUid], or the forum's refusal.
///
/// Throws [ApproveFriendRejected] for everything else.
ApproveFriendFormResult parseApproveFriendForm(String raw, {required int targetUid}) {
  try {
    return _parseApproveFriendForm(raw, targetUid: targetUid);
  } on ApproveFriendRejected {
    rethrow;
  } on Object catch (e) {
    throw ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'malformed approval form: $e');
  }
}

ApproveFriendFormResult _parseApproveFriendForm(String raw, {required int targetUid}) {
  if (!_isAjax(raw)) {
    _rejectPage(raw);
  }
  final payload = unwrapAjax(raw);
  final doc = parseHtmlDocument(payload);
  final forms = doc.querySelectorAll('form');
  if (forms.isEmpty) {
    // No form: the forum refused (the request is gone, the two are friends already, ...).
    final refused = _errorRe.firstMatch(payload)?.group(1) ?? _alertRe.firstMatch(payload)?.group(1);
    if (refused != null && refused.trim().isNotEmpty) {
      return ApproveFriendRefused(refused.trim());
    }
    throw const ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'no form and no message');
  }
  if (forms.length != 1) {
    throw ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'expected one form, got ${forms.length}');
  }
  final form = forms.single;
  _checkAction(form, targetUid);
  if ((form.attributes['method'] ?? 'get').toLowerCase() != 'post') {
    throw const ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'not a post form');
  }

  final fields = <(String, String)>[];
  final groups = <FriendGroup>[];
  final checked = <String>[];
  for (final e in form.querySelectorAll('input, select, textarea, button')) {
    final name = e.attributes['name'] ?? '';
    final tag = e.localName;
    final type = (e.attributes['type'] ?? (tag == 'button' ? 'submit' : 'text')).toLowerCase();
    if (name == 'addsubmit' || name == 'note') {
      // The add-friend form: sending it would ask for a new request instead of approving this one.
      throw ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'add-friend field $name');
    }
    if (tag == 'button' || type == 'submit' || type == 'button') {
      // Buttons are not sent: the forum checks the hidden add2submit.
      continue;
    }
    if (tag != 'input') {
      throw ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'unsupported field $tag $name');
    }
    final value = e.attributes['value'] ?? '';
    switch (type) {
      case 'hidden' when _knownHidden.contains(name):
        if (fields.any((f) => f.$1 == name)) {
          throw ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'repeated field $name');
        }
        fields.add((name, value));
      case 'radio' when name == 'gid':
        if (!_gidRe.hasMatch(value) || groups.any((g) => g.gid == value)) {
          throw ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'bad group $value');
        }
        final label = _labelOf(form, e);
        if (label.isEmpty) {
          throw ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'group $value without name');
        }
        groups.add(FriendGroup(gid: value, name: label));
        if (e.attributes.containsKey('checked')) {
          checked.add(value);
        }
      default:
        throw ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'unsupported field $type $name');
    }
  }

  String? hidden(String name) => fields.where((f) => f.$1 == name).firstOrNull?.$2;
  if (hidden('add2submit') != 'true') {
    throw const ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'add2submit not found');
  }
  if ((hidden('formhash') ?? '').isEmpty) {
    throw const ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'formhash not found');
  }
  if (!_handleKeyRe.hasMatch(hidden('handlekey') ?? '')) {
    throw const ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'handlekey not found');
  }
  if (groups.isEmpty) {
    throw const ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'no group offered');
  }
  if (checked.length > 1) {
    throw const ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'several groups checked');
  }

  // The form names the member in its avatar link: it must be the member of the notice.
  for (final a in form.querySelectorAll('a[href]')) {
    final href = Uri.tryParse(a.attributes['href']!.replaceAll('&amp;', '&'));
    final q = href?.queryParameters;
    if (q != null && q['mod'] == 'space' && q['uid'] != null && q['uid'] != '$targetUid') {
      throw const ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'form of another member');
    }
  }

  return ApproveFriendForm(
    targetUid: targetUid,
    targetName: form.querySelector('td p strong')?.text?.trim() ?? '',
    groups: groups,
    selectedGid: checked.firstOrNull ?? groups.first.gid,
    fields: fields,
  );
}

/// The action of [form] must be the forum's own `home.php` approval operation of exactly [targetUid].
void _checkAction(uh.Element form, int targetUid) {
  final raw = form.attributes['action'];
  final uri = raw == null ? null : Uri.tryParse(raw.replaceAll('&amp;', '&'));
  final action = uri == null
      ? null
      : canonicalForumOperationUrl(uri, {'mod': 'spacecp', 'ac': 'friend', 'op': 'add', 'uid': '$targetUid'});
  if (action == null) {
    throw const ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'action is not the approval of the member');
  }
  final all = action.queryParametersAll;
  if (all.values.any((e) => e.length != 1)) {
    throw const ApproveFriendRejected(ApproveFriendFailure.unknownForm, 'action repeats a parameter');
  }
}

/// Text of the label of the radio [input]: its enclosing label, or the label pointing at its id.
String _labelOf(uh.Element form, uh.Element input) {
  String clean(String? s) => (s ?? '').replaceAll(_spaceRe, ' ').trim();
  final parent = input.parent;
  if (parent != null && parent.localName == 'label') {
    return clean(parent.text);
  }
  final id = input.attributes['id'];
  if (id != null && id.isNotEmpty) {
    for (final label in form.querySelectorAll('label')) {
      if (label.attributes['for'] == id) {
        return clean(label.text);
      }
    }
  }
  return '';
}

final _succeedRe = RegExp(r"succeedhandle_(\w+)\('[^']*',\s*'([^']*)'(?:,\s*\{([^}]*)\})?");
final _valueUidRe = RegExp(r"'uid'\s*:\s*'(\d+)'");

/// The forum's answer to a posted approval sent with [handleKey] for [targetUid].
///
/// Only the success callback of that very handle key (and, when it names one, of that member) is a success. An
/// explicit refusal is a failed [AddFriendResult] with the forum's message. Throws [ApproveFriendRejected] for anything
/// else: a challenge, the login page, a page that is not an ajax answer or an answer that is not understood.
AddFriendResult parseApproveFriendResult(String raw, {required String handleKey, required int targetUid}) {
  if (!_isAjax(raw)) {
    try {
      _rejectPage(raw);
    } on ApproveFriendRejected catch (e) {
      if (e.failure == ApproveFriendFailure.unknownForm) {
        throw ApproveFriendRejected(ApproveFriendFailure.unknownAfterSubmit, e.reason);
      }
      rethrow;
    }
  }
  final payload = unwrapAjax(raw);
  for (final m in _succeedRe.allMatches(payload)) {
    if (m.group(1) != handleKey) {
      continue;
    }
    final uid = _valueUidRe.firstMatch(m.group(3) ?? '')?.group(1);
    if (uid != null && uid != '$targetUid') {
      throw const ApproveFriendRejected(ApproveFriendFailure.unknownAfterSubmit, 'success for another member');
    }
    return AddFriendResult(success: true, message: m.group(2)!.trim());
  }
  final refused = _errorRe.firstMatch(payload)?.group(1) ?? _alertRe.firstMatch(payload)?.group(1);
  if (refused != null) {
    final text = refused.replaceAll(_tagRe, ' ').replaceAll(_spaceRe, ' ').trim();
    return AddFriendResult(success: false, message: text);
  }
  throw const ApproveFriendRejected(ApproveFriendFailure.unknownAfterSubmit, 'answer not understood');
}
