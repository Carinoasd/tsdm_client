import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/utils/forum_url.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Url of the privacy filter page holding every server-side ignore rule.
const privacyFilterUrl = '$baseUrl/home.php?mod=spacecp&ac=privacy&op=filter';

/// Url of the ignore form for notices of [type] from [authorId], the same one the notice's "屏蔽" link opens.
String noticeIgnoreFormUrl({required String type, required int authorId}) =>
    '$baseUrl/home.php?mod=spacecp&ac=common&op=ignore&authorid=$authorId&type=$type'
    '&handlekey=noticeignore&infloat=yes&inajax=1';

/// Categories of checkboxes in the privacy filter form.
enum PrivacyFilterCategory {
  /// Notice ignore rules, key `type|authorid`.
  note,

  /// Feed icon filters.
  icon,

  /// Friend group filters.
  gid,
}

/// One checkbox of the privacy filter form.
final class PrivacyFilterCheckbox {
  /// Constructor.
  const PrivacyFilterCheckbox({
    required this.name,
    required this.value,
    required this.checked,
    required this.category,
    required this.key,
    this.label,
  });

  /// Input name, sent as is.
  final String name;

  /// Input value, sent as is.
  final String value;

  /// Checked in the page.
  final bool checked;

  /// Category.
  final PrivacyFilterCategory category;

  /// Key inside the category, e.g. `post|1000`.
  final String key;

  /// Text of the enclosing label, if any.
  final String? label;
}

/// A parsed html form of the forum, only kept when every field is understood.
final class ParsedForumForm {
  const ParsedForumForm._({required this.action, required this.fields, required this.checkboxes});

  /// Absolute action url.
  final Uri action;

  /// Fields sent as they are: hidden, text, checked radios, selects, textareas and the submit button.
  final List<(String, String)> fields;

  /// Filter checkboxes of the privacy page, empty for other forms.
  final List<PrivacyFilterCheckbox> checkboxes;

  /// Notice ignore rules currently checked.
  List<NoticeIgnoreRule> get noteRules => checkboxes
      .where((e) => e.checked && e.category == PrivacyFilterCategory.note)
      .map((e) => NoticeIgnoreRule.tryParseKey(e.key, label: e.label))
      .whereType<NoticeIgnoreRule>()
      .toList();

  /// Build the request body of this form with every checked filter checkbox kept, except the note rule [removeKey].
  String encode({String? removeKey, List<(String, String)> extra = const []}) {
    final pairs = <(String, String)>[
      ...fields,
      for (final c in checkboxes)
        if (c.checked && !(c.category == PrivacyFilterCategory.note && c.key == removeKey)) (c.name, c.value),
      ...extra,
    ];
    return pairs.map((e) => '${Uri.encodeQueryComponent(e.$1)}=${Uri.encodeQueryComponent(e.$2)}').join('&');
  }
}

/// Parse error of a forum page, maps to a [NoticeIgnoreFailure].
final class _PageRejected implements Exception {
  const _PageRejected(this.failure, this.reason);

  final NoticeIgnoreFailure failure;
  final String reason;

  @override
  String toString() => '_PageRejected($failure, $reason)';
}

final _filterNameRe = RegExp(r'^(?:privacy\[)?filter_(note|icon|gid)\]?\[([^\]]+)\]$');

/// Whether [uri] (maybe relative) points to the forum's `home.php` with all [query] values.
///
/// Only the forum's own hosts on the default port of http or https, without user info, and exactly `/home.php`.
/// See [canonicalForumOperationUrl] for the url that is actually requested.
bool isForumOperationUrl(Uri uri, Map<String, String> query) => canonicalForumOperationUrl(uri, query) != null;

/// The url to send a form of [uri] to: always `https://` + [baseHost] + `/home.php` with the query of [uri], or null
/// when [uri] is not exactly a forum `home.php` url with all [query] values (see [isForumOperationUrl]).
///
/// Legacy `http://` and bare-host links of the forum are sent over https to the main host; any other port, host or
/// path is refused, so a crafted form action can never receive an authenticated write.
Uri? canonicalForumOperationUrl(Uri uri, Map<String, String> query) {
  try {
    final abs = Uri.parse('$baseUrl/').resolveUri(uri);
    if (abs.scheme != 'https' && abs.scheme != 'http') {
      return null;
    }
    if (abs.host != baseHost && abs.host != baseHostAlt) {
      return null;
    }
    if (abs.userInfo.isNotEmpty || abs.port != (abs.scheme == 'https' ? 443 : 80)) {
      return null;
    }
    if (abs.path != '/home.php') {
      return null;
    }
    final params = abs.queryParameters;
    if (!query.entries.every((e) => params[e.key] == e.value)) {
      return null;
    }
    return Uri(scheme: 'https', host: baseHost, path: '/home.php', query: abs.query);
  } on FormatException {
    return null;
  }
}

/// Parse the `action` attribute of [form] into the url to send it to, null when it is not a forum operation with all
/// [query] values.
Uri? _formAction(uh.Element form, Map<String, String> query) {
  final raw = form.attributes['action'];
  if (raw == null) {
    return null;
  }
  final uri = Uri.tryParse(raw.replaceAll('&amp;', '&'));
  return uri == null ? null : canonicalForumOperationUrl(uri, query);
}

/// Reject pages that are not a normal forum answer for the logged in account [expectedUid].
///
/// Set [requireIdentity] to false for ajax fragments which carry no page header.
void checkForumPage(uh.Document doc, String raw, {required int expectedUid, required bool requireIdentity}) {
  final title = doc.querySelector('title')?.text ?? '';
  if (title.contains('Just a moment') ||
      raw.contains('challenge-platform') ||
      raw.contains('cf-chl') ||
      doc.querySelector('#challenge-form') != null) {
    throw const _PageRejected(NoticeIgnoreFailure.challenge, 'cloudflare challenge');
  }
  final isGuest =
      (doc.querySelector('form#lsform') != null && doc.querySelector('div#um') == null) ||
      doc.querySelector('#messagelogin') != null ||
      doc.querySelector('form[name="login"]') != null;
  if (isGuest) {
    throw const _PageRejected(NoticeIgnoreFailure.notLoggedIn, 'guest page');
  }
  if (doc.querySelector('div.alert_error') != null || doc.querySelector('#messagetext.alert_error') != null) {
    throw _PageRejected(NoticeIgnoreFailure.forumError, doc.querySelector('div.alert_error')?.text?.trim() ?? '');
  }
  if (!requireIdentity) {
    return;
  }
  // The shared parser knows every forum style (header node, inner_stat, block_name, `discuz_uid` script); the plain
  // `div#um strong.vwmy` link is the minimal header of pages without the full layout.
  final uid =
      parseLoggedUidFromDocument(doc) ??
      uidOfProfileUrl(doc.querySelector('div#um strong.vwmy > a')?.attributes['href']);
  if (uid == null) {
    throw const _PageRejected(NoticeIgnoreFailure.unknownForm, 'current account not found in page');
  }
  if (uid != expectedUid) {
    throw const _PageRejected(NoticeIgnoreFailure.accountMismatch, 'page of another account');
  }
}

/// Collect every field of [form]; unknown kinds of fields fail closed.
///
/// The operation flag [requiredSubmit] (`privacy2submit`, `ignoresubmit`: the name the forum checks to run the
/// operation) must be present, either as a hidden field or as submit buttons. The privacy page repeats the same
/// `privacy2submit` button under each group of one form: identical repeated buttons are accepted and the flag is
/// sent once; buttons of that name with different values are refused. Other submit buttons are not sent (a browser
/// only sends the one clicked). A non-empty `formhash` is required. Set [privacyFilter] to sort the `filter_note` /
/// `filter_icon` / `filter_gid` checkboxes out of the plain fields.
ParsedForumForm parseForumForm(
  uh.Element form, {
  required Uri action,
  required String requiredSubmit,
  bool privacyFilter = false,
}) {
  final fields = <(String, String)>[];
  final checkboxes = <PrivacyFilterCheckbox>[];
  final flagValues = <String>{};
  for (final e in form.querySelectorAll('input, select, textarea, button')) {
    final name = e.attributes['name'];
    final tag = e.localName;
    final type = (e.attributes['type'] ?? (tag == 'button' ? 'submit' : 'text')).toLowerCase();
    if (e.attributes.containsKey('disabled')) {
      continue;
    }
    if (type == 'submit' || type == 'image') {
      if (name == requiredSubmit) {
        flagValues.add(e.attributes['value'] ?? '');
      }
      continue;
    }
    if (type == 'button' || type == 'reset') {
      continue;
    }
    if (name == null || name.isEmpty) {
      continue;
    }
    if (tag == 'select') {
      if (e.attributes.containsKey('multiple')) {
        // Sending one of several selected values would change the setting: refuse instead.
        throw _PageRejected(NoticeIgnoreFailure.unknownForm, 'unsupported multiple select $name');
      }
      final option = e.querySelector('option[selected]') ?? e.querySelector('option');
      if (option != null) {
        fields.add((name, option.attributes['value'] ?? option.text ?? ''));
      }
      continue;
    }
    if (tag == 'textarea') {
      fields.add((name, e.text ?? ''));
      continue;
    }
    final value = e.attributes['value'] ?? (type == 'checkbox' || type == 'radio' ? 'on' : '');
    final checked = e.attributes.containsKey('checked');
    switch (type) {
      case 'hidden' || 'text' || 'number' || 'email' || 'search' || 'tel' || 'url':
        fields.add((name, value));
      case 'radio':
        if (checked) {
          fields.add((name, value));
        }
      case 'checkbox':
        final m = privacyFilter ? _filterNameRe.firstMatch(name) : null;
        if (m != null) {
          final category = switch (m.group(1)) {
            'note' => PrivacyFilterCategory.note,
            'icon' => PrivacyFilterCategory.icon,
            _ => PrivacyFilterCategory.gid,
          };
          checkboxes.add(
            PrivacyFilterCheckbox(
              name: name,
              value: value,
              checked: checked,
              category: category,
              key: m.group(2)!,
              label: e.parent?.localName == 'label' ? e.parent?.text?.trim() : null,
            ),
          );
        } else if (checked) {
          fields.add((name, value));
        }
      default:
        throw _PageRejected(NoticeIgnoreFailure.unknownForm, 'unsupported field $type');
    }
  }
  if (!fields.any((e) => e.$1 == 'formhash' && e.$2.isNotEmpty)) {
    throw const _PageRejected(NoticeIgnoreFailure.unknownForm, 'formhash not found');
  }
  final hiddenFlag = fields.where((e) => e.$1 == requiredSubmit).map((e) => e.$2).toSet();
  if (hiddenFlag.length > 1 || flagValues.length > 1) {
    throw _PageRejected(NoticeIgnoreFailure.unknownForm, 'conflicting values of $requiredSubmit');
  }
  if (hiddenFlag.isEmpty && flagValues.isEmpty) {
    throw _PageRejected(NoticeIgnoreFailure.unknownForm, '$requiredSubmit not found');
  }
  if (hiddenFlag.isNotEmpty && flagValues.isNotEmpty && hiddenFlag.single != flagValues.single) {
    throw _PageRejected(NoticeIgnoreFailure.unknownForm, 'conflicting values of $requiredSubmit');
  }
  if (hiddenFlag.isEmpty && flagValues.single.isEmpty) {
    throw _PageRejected(NoticeIgnoreFailure.unknownForm, 'empty $requiredSubmit');
  }
  return ParsedForumForm._(
    action: action,
    fields: [...fields, if (hiddenFlag.isEmpty) (requiredSubmit, flagValues.single)],
    checkboxes: checkboxes,
  );
}

/// Parse the privacy filter page [raw] of account [expectedUid].
///
/// Saving this form replaces all three filter groups (notices, feed icons, friend groups) with what is sent, so a
/// page that is cut off (no closing `</form>` / `</html>`) is refused instead of sending a part of the groups.
///
/// Never throws anything but the internal rejection: malformed pages give [NoticeIgnoreFailure.unknownForm].
ParsedForumForm parsePrivacyFilterPage(String raw, {required int expectedUid}) {
  try {
    return _parsePrivacyFilterPage(raw, expectedUid: expectedUid);
  } on _PageRejected {
    rethrow;
  } on Object catch (e) {
    throw _PageRejected(NoticeIgnoreFailure.unknownForm, 'malformed privacy page: $e');
  }
}

ParsedForumForm _parsePrivacyFilterPage(String raw, {required int expectedUid}) {
  final doc = parseHtmlDocument(raw);
  checkForumPage(doc, raw, expectedUid: expectedUid, requireIdentity: true);
  const query = {'mod': 'spacecp', 'ac': 'privacy', 'op': 'filter'};
  final forms = doc.querySelectorAll('form').where((f) => _formAction(f, query) != null).toList();
  if (forms.length != 1) {
    throw _PageRejected(NoticeIgnoreFailure.unknownForm, 'expected one privacy filter form, got ${forms.length}');
  }
  final lower = raw.toLowerCase();
  if (!lower.contains('</form>') || !lower.contains('</html>')) {
    throw const _PageRejected(NoticeIgnoreFailure.unknownForm, 'incomplete privacy page');
  }
  final form = forms.first;
  if ((form.attributes['method'] ?? 'get').toLowerCase() != 'post') {
    throw const _PageRejected(NoticeIgnoreFailure.unknownForm, 'privacy filter form is not a post form');
  }
  return parseForumForm(
    form,
    action: _formAction(form, query)!,
    requiredSubmit: 'privacy2submit',
    privacyFilter: true,
  );
}

/// Extract the html of an ajax (`inajax=1`) answer, or return [raw] when it is a normal page.
String unwrapAjax(String raw) {
  final start = raw.indexOf('<![CDATA[');
  if (start < 0) {
    return raw;
  }
  final end = raw.lastIndexOf(']]>');
  if (end < start) {
    return raw;
  }
  return raw.substring(start + '<![CDATA['.length, end);
}

/// Parse the ignore form [raw] for [target]; the author radio must offer exactly [target]'s author and everybody (0).
///
/// For a system notice (author 0) both choices of the forum's form are 0: the only rule is the one for everybody.
///
/// Never throws anything but the internal rejection: malformed pages give [NoticeIgnoreFailure.unknownForm].
ParsedForumForm parseNoticeIgnoreForm(String raw, {required NoticeIgnoreTarget target, required int expectedUid}) {
  try {
    return _parseNoticeIgnoreForm(raw, target: target, expectedUid: expectedUid);
  } on _PageRejected {
    rethrow;
  } on Object catch (e) {
    throw _PageRejected(NoticeIgnoreFailure.unknownForm, 'malformed ignore form: $e');
  }
}

ParsedForumForm _parseNoticeIgnoreForm(String raw, {required NoticeIgnoreTarget target, required int expectedUid}) {
  final html = unwrapAjax(raw);
  final doc = parseHtmlDocument(html);
  checkForumPage(doc, html, expectedUid: expectedUid, requireIdentity: false);
  final query = {'mod': 'spacecp', 'ac': 'common', 'op': 'ignore', 'type': target.type};
  final forms = doc.querySelectorAll('form').where((f) => _formAction(f, query) != null).toList();
  if (forms.length != 1) {
    throw _PageRejected(NoticeIgnoreFailure.unknownForm, 'expected one ignore form, got ${forms.length}');
  }
  final form = forms.first;
  if ((form.attributes['method'] ?? 'get').toLowerCase() != 'post') {
    throw const _PageRejected(NoticeIgnoreFailure.unknownForm, 'ignore form is not a post form');
  }
  final radios = form
      .querySelectorAll('input[type="radio"][name="authorid"]')
      .map((e) => e.attributes['value'])
      .toSet();
  if (!setEquals(radios, {'${target.authorId}', '0'})) {
    throw const _PageRejected(NoticeIgnoreFailure.ruleNotFound, 'author choices do not match the notice');
  }
  final parsed = parseForumForm(form, action: _formAction(form, query)!, requiredSubmit: 'ignoresubmit');
  if (!parsed.fields.any((e) => e.$1 == 'authorid')) {
    throw const _PageRejected(NoticeIgnoreFailure.unknownForm, 'author choice not found');
  }
  return parsed;
}

/// Server-side notice ignore rules (Discuz `filter_note`), NOT the forum blacklist and NOT the local block list.
///
/// Every operation takes the [NetClientProvider] of the account it acts for and that account's uid, and uses that
/// one client for reading the form, writing and verifying, so a switch of account in between can never write into
/// another account (the client drops requests once its account is not current any more).
///
/// Nothing is retried: a write request is sent at most once per call and only after the user asked for it.
class NoticeIgnoreRepository with LoggerMixin {
  /// Constructor.
  const NoticeIgnoreRepository();

  Future<Either<NoticeIgnoreFailure, ParsedForumForm>> _fetchPrivacyForm(NetClientProvider client, int uid) async {
    final resp = await client.get(privacyFilterUrl).run();
    switch (resp) {
      case Left(:final value):
        error('failed to fetch privacy filter form: $value');
        return left(NoticeIgnoreFailure.network);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(NoticeIgnoreFailure.network);
      case Right(:final value) when value.data is! String:
        return left(NoticeIgnoreFailure.unknownForm);
      case Right(:final value):
        try {
          return right(parsePrivacyFilterPage(value.data as String, expectedUid: uid));
        } on _PageRejected catch (e) {
          error('privacy filter form rejected: $e');
          return left(e.failure);
        }
    }
  }

  /// Load the rules of account [uid] from the forum.
  Future<NoticeIgnoreResult> fetchRules(NetClientProvider client, {required int uid}) async =>
      switch (await _fetchPrivacyForm(client, uid)) {
        Left(:final value) => NoticeIgnoreResult.failed(value),
        Right(:final value) => NoticeIgnoreResult.success(value.noteRules),
      };

  /// Add a rule ignoring notices of [target]'s type from its author, or from everybody when [everybody] is true.
  Future<NoticeIgnoreResult> addRule(
    NetClientProvider client, {
    required int uid,
    required NoticeIgnoreTarget target,
    required bool everybody,
  }) async {
    // Read the privacy page first: proves the client acts for [uid] (the ajax form carries no header).
    final before = await _fetchPrivacyForm(client, uid);
    final List<NoticeIgnoreRule> rulesBefore;
    switch (before) {
      case Left(:final value):
        return NoticeIgnoreResult.failed(value);
      case Right(:final value):
        rulesBefore = value.noteRules;
    }
    if (!everybody && !target.hasUserAuthor) {
      // A system notice has no user to ignore.
      return const NoticeIgnoreResult.failed(NoticeIgnoreFailure.ruleNotFound);
    }
    final rule = NoticeIgnoreRule(type: target.type, authorId: everybody ? 0 : target.authorId);
    if (rulesBefore.contains(rule)) {
      // Nothing to do: reported as applied without sending anything.
      return NoticeIgnoreResult.success(rulesBefore, alreadyApplied: true);
    }
    final ParsedForumForm form;
    final resp = await client.get(noticeIgnoreFormUrl(type: target.type, authorId: target.authorId)).run();
    switch (resp) {
      case Left():
        return const NoticeIgnoreResult.failed(NoticeIgnoreFailure.network);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return const NoticeIgnoreResult.failed(NoticeIgnoreFailure.network);
      case Right(:final value) when value.data is! String:
        return const NoticeIgnoreResult.failed(NoticeIgnoreFailure.unknownForm);
      case Right(:final value):
        try {
          form = parseNoticeIgnoreForm(value.data as String, target: target, expectedUid: uid);
        } on _PageRejected catch (e) {
          error('notice ignore form rejected: $e');
          return NoticeIgnoreResult.failed(e.failure);
        }
    }
    final fields = [
      for (final f in form.fields)
        if (f.$1 != 'authorid') f,
      ('authorid', '${rule.authorId}'),
    ];
    final body = fields.map((e) => '${Uri.encodeQueryComponent(e.$1)}=${Uri.encodeQueryComponent(e.$2)}').join('&');
    return _submitAndVerify(client, uid: uid, action: form.action, body: body, expect: (rules) => rules.contains(rule));
  }

  /// Remove [rule] of account [uid], keeping every other checked filter of the privacy form.
  Future<NoticeIgnoreResult> removeRule(
    NetClientProvider client, {
    required int uid,
    required NoticeIgnoreRule rule,
  }) async {
    final ParsedForumForm form;
    switch (await _fetchPrivacyForm(client, uid)) {
      case Left(:final value):
        return NoticeIgnoreResult.failed(value);
      case Right(:final value):
        form = value;
    }
    if (!form.noteRules.contains(rule)) {
      return NoticeIgnoreResult.failed(NoticeIgnoreFailure.ruleNotFound, rules: form.noteRules);
    }
    final kept = form.checkboxes
        .where((c) => c.checked && !(c.category == PrivacyFilterCategory.note && c.key == rule.key))
        .map((c) => (c.category, c.key))
        .toSet();
    return _submitAndVerify(
      client,
      uid: uid,
      action: form.action,
      body: form.encode(removeKey: rule.key),
      expect: (_) => true,
      expectForm: (after) {
        final now = after.checkboxes.where((c) => c.checked).map((c) => (c.category, c.key)).toSet();
        return !after.noteRules.contains(rule) && now.containsAll(kept);
      },
    );
  }

  Future<NoticeIgnoreResult> _submitAndVerify(
    NetClientProvider client, {
    required int uid,
    required Uri action,
    required String body,
    required bool Function(List<NoticeIgnoreRule>) expect,
    bool Function(ParsedForumForm)? expectForm,
  }) async {
    final resp = await client.postForm(action.toString(), data: body).run();
    if (resp case Left(:final value)) {
      // The request may have reached the forum: do not claim either outcome.
      error('notice ignore submit failed, result unknown: $value');
      return const NoticeIgnoreResult.failed(NoticeIgnoreFailure.unknownAfterSubmit);
    }
    final raw = resp.getOrElse((_) => throw StateError('unreachable')).data;
    NoticeIgnoreFailure? refused;
    if (raw is String) {
      try {
        final html = unwrapAjax(raw);
        checkForumPage(parseHtmlDocument(html), html, expectedUid: uid, requireIdentity: false);
      } on _PageRejected catch (e) {
        // Explicit refusal from the forum: never reported as success. The list is still reloaded below so the page
        // shows the real state.
        warning('notice ignore submit answered $e');
        refused = e.failure;
      } on Object catch (e) {
        warning('notice ignore submit answer not understood: $e');
      }
    }
    // Verify with the same client. The callers only get here when the state before did not match [expect], so a
    // match now is a change made by this request.
    switch (await _fetchPrivacyForm(client, uid)) {
      case Left():
        return NoticeIgnoreResult.failed(refused ?? NoticeIgnoreFailure.unknownAfterSubmit);
      case Right(:final value):
        final ok = expect(value.noteRules) && (expectForm?.call(value) ?? true);
        if (refused != null) {
          return NoticeIgnoreResult.failed(
            ok ? NoticeIgnoreFailure.unknownAfterSubmit : refused,
            rules: value.noteRules,
          );
        }
        return ok
            ? NoticeIgnoreResult.success(value.noteRules)
            : NoticeIgnoreResult.failed(NoticeIgnoreFailure.unknownAfterSubmit, rules: value.noteRules);
    }
  }
}
