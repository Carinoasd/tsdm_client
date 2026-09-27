import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/blocking/models/notice_ignore.dart';
import 'package:tsdm_client/features/blocking/models/website_blocklist.dart';
import 'package:tsdm_client/features/blocking/repository/notice_ignore_repository.dart';
import 'package:tsdm_client/features/blocking/utils/forum_url.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Query of the website blacklist page, the `blockuser` plugin page linked from the forum settings.
const websiteBlocklistQuery = {'mod': 'spacecp', 'ac': 'plugin', 'id': 'blockuser:spacecp'};

/// Url of the website blacklist page.
const websiteBlocklistUrl = '$baseUrl/home.php?mod=spacecp&ac=plugin&id=blockuser:spacecp';

/// Url of the read-only member lookup of [uid] on the website blacklist page.
String websiteBlocklistLookupUrl(int uid) => '$websiteBlocklistUrl&bu_q=$uid';

/// Checked by a write just before its request is sent: false once the operation belongs to an account or a page
/// generation that is not current any more.
typedef WebsiteBlocklistStillCurrent = bool Function();

/// Rejection of a website blacklist page by [parseWebsiteBlocklistDocument].
final class WebsiteBlocklistRejected implements Exception {
  /// Constructor.
  const WebsiteBlocklistRejected(this.failure, this.reason, {this.message});

  /// Kind.
  final WebsiteBlocklistFailure failure;

  /// For logs: never contains page content.
  final String reason;

  /// Forum message for display, never logged.
  final String? message;

  /// The error shown for this rejection.
  WebsiteBlocklistError get error => WebsiteBlocklistError(failure, message: message);

  @override
  String toString() => 'WebsiteBlocklistRejected($failure, $reason)';
}

Never _unsupported(String reason) => throw WebsiteBlocklistRejected(WebsiteBlocklistFailure.unsupported, reason);

Never _mismatch(String reason) => throw WebsiteBlocklistRejected(WebsiteBlocklistFailure.targetMismatch, reason);

WebsiteBlocklistFailure _failureOf(NoticeIgnoreFailure f) => switch (f) {
  NoticeIgnoreFailure.network => WebsiteBlocklistFailure.network,
  NoticeIgnoreFailure.notLoggedIn => WebsiteBlocklistFailure.notLoggedIn,
  NoticeIgnoreFailure.accountMismatch => WebsiteBlocklistFailure.accountMismatch,
  NoticeIgnoreFailure.challenge => WebsiteBlocklistFailure.challenge,
  NoticeIgnoreFailure.forumError => WebsiteBlocklistFailure.forumError,
  NoticeIgnoreFailure.unknownForm || NoticeIgnoreFailure.ruleNotFound => WebsiteBlocklistFailure.unsupported,
  NoticeIgnoreFailure.unknownAfterSubmit => WebsiteBlocklistFailure.unknownAfterSubmit,
};

/// Text of the forum's message, whitespace collapsed and cut, for display only.
String? _displayMessage(String? raw) {
  final text = raw?.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  return text.length > 160 ? '${text.substring(0, 160)}…' : text;
}

String _textOf(uh.Element e) => (e.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

bool _hasClass(uh.Element e, String name) => (e.attributes['class'] ?? '').split(RegExp(r'\s+')).contains(name);

bool _inside(uh.Element e, uh.Element ancestor) {
  for (uh.Element? p = e; p != null; p = p.parent) {
    if (identical(p, ancestor)) {
      return true;
    }
  }
  return false;
}

/// Query parameters of [uri] with every name at most once, null when one repeats or the query is malformed.
Map<String, String>? _singleQuery(Uri uri) {
  try {
    final all = uri.queryParametersAll;
    if (all.values.any((e) => e.length != 1)) {
      return null;
    }
    return all.map((k, v) => MapEntry(k, v.single));
  } on FormatException {
    return null;
  }
}

/// The url to send a plugin POST form to, null unless [raw] is exactly the plugin page: the forum's `home.php` with
/// `mod`, `ac` and `id` of [websiteBlocklistQuery], each once, and no other parameter. The observed forms carry the
/// target only in the `buid` field; an action with more parameters (a target, an operation) is not that form.
Uri? websiteBlocklistActionOf(String? raw) {
  if (raw == null) {
    return null;
  }
  final uri = Uri.tryParse(raw.replaceAll('&amp;', '&'));
  if (uri == null || uri.hasFragment) {
    return null;
  }
  final query = _singleQuery(uri);
  if (query == null || query.length != websiteBlocklistQuery.length) {
    return null;
  }
  return canonicalForumOperationUrl(uri, websiteBlocklistQuery);
}

/// Whether [form] is the plugin's lookup form `form#bu_qform` as observed: GET to the forum's bare `home.php`, the
/// plugin query as hidden `mod`, `ac` and `id` fields (each once) and one `bu_q` text box.
///
/// A GET form replaces the query of its action by its fields, so routing in the action as well would be ignored by a
/// browser or conflict with the hidden fields: an action with a query is refused.
bool _isLookupForm(uh.Element form) {
  if ((form.attributes['method'] ?? 'get').toLowerCase() != 'get') {
    return false;
  }
  final action = Uri.tryParse((form.attributes['action'] ?? '').replaceAll('&amp;', '&'));
  if (action == null || action.hasQuery || action.hasFragment) {
    return false;
  }
  if (canonicalForumOperationUrl(action, const {}) == null) {
    return false;
  }
  final routing = <String, String>{};
  var boxes = 0;
  for (final e in form.querySelectorAll('input, select, textarea')) {
    final name = e.attributes['name'] ?? '';
    if (name.isEmpty) {
      continue;
    }
    final type = (e.attributes['type'] ?? 'text').toLowerCase();
    if (e.localName == 'input' && type == 'hidden') {
      if (routing.containsKey(name)) {
        return false;
      }
      routing[name] = e.attributes['value'] ?? '';
    } else if (name == 'bu_q' && e.localName == 'input' && (type == 'text' || type == 'search')) {
      boxes++;
    } else {
      return false;
    }
  }
  return boxes == 1 &&
      routing.length == websiteBlocklistQuery.length &&
      websiteBlocklistQuery.entries.every((e) => routing[e.key] == e.value);
}

/// What a plugin POST form does: told by which form it is (`#bu_addform`, `form.bu-delform`) and by its flag.
enum _FormKind {
  add('blockuseradd'),
  remove('blockuserdel')
  ;

  const _FormKind(this.flag);

  /// Name of the operation flag the plugin checks.
  final String flag;
}

/// A plugin POST form of exactly one user, every field as served.
final class _PluginForm {
  const _PluginForm({required this.action, required this.fields, required this.target});

  final Uri action;

  /// `formhash`, the operation flag and `buid`, values as served.
  final Map<String, String> fields;

  /// The user of `buid`.
  final int target;

  Map<String, String> get payload => Map.of(fields);
}

/// Read [form] as the plugin's [kind] form in the observed shape, or reject it.
///
/// Accepted only: POST to exactly the plugin page ([websiteBlocklistActionOf]), hidden `formhash`, the flag of
/// [kind] and `buid` (a uid), each exactly once and not blank, and one unnamed submit button. Values are never made
/// up: they are sent as served. Another field, the other flag, a named or second button or a disabled field refuse
/// the form, so nothing is sent from a form this app does not fully understand.
_PluginForm _parsePluginForm(uh.Element form, _FormKind kind) {
  if ((form.attributes['method'] ?? '').toLowerCase() != 'post') {
    _unsupported('form is not post');
  }
  final action = websiteBlocklistActionOf(form.attributes['action']);
  if (action == null) {
    _unsupported('form action is not the plugin page');
  }
  final fields = <String, String>{};
  var submits = 0;
  for (final e in form.querySelectorAll('input, select, textarea, button')) {
    final name = e.attributes['name'] ?? '';
    final tag = e.localName;
    final type = (e.attributes['type'] ?? (tag == 'button' ? 'submit' : 'text')).toLowerCase();
    if (e.attributes.containsKey('disabled')) {
      _unsupported('disabled field');
    }
    if (type == 'submit') {
      if (name.isNotEmpty) {
        _unsupported('named submit button');
      }
      submits++;
      continue;
    }
    if (tag != 'input' || type != 'hidden') {
      _unsupported('unexpected field');
    }
    if (name.isEmpty) {
      // Never sent by a browser.
      continue;
    }
    if (fields.containsKey(name)) {
      _unsupported('repeated field');
    }
    fields[name] = e.attributes['value'] ?? '';
  }
  if (submits != 1) {
    _unsupported('submit button');
  }
  if (fields.length != 3 || !['formhash', kind.flag, 'buid'].every(fields.containsKey)) {
    _unsupported('form fields');
  }
  if (fields.values.any((e) => e.isEmpty)) {
    _unsupported('blank field');
  }
  final target = parseStrictUid(fields['buid']);
  if (target == null) {
    _unsupported('form target');
  }
  return _PluginForm(action: action, fields: Map.unmodifiable(fields), target: target);
}

/// One parsed website blacklist page: the list and, for a lookup, the member it found.
final class WebsiteBlocklistDocument {
  WebsiteBlocklistDocument._({
    required this.list,
    required this.lookup,
    required Map<int, _PluginForm> removers,
    required _PluginForm? adder,
  }) : _removers = removers,
       _adder = adder;

  /// The list shown on the page.
  final WebsiteBlocklist list;

  /// Member returned by a lookup, null when none was asked or found.
  final WebsiteBlocklistLookup? lookup;

  final Map<int, _PluginForm> _removers;
  final _PluginForm? _adder;

  _PluginForm? _formFor({required bool add, required int uid}) =>
      add ? (_adder?.target == uid ? _adder : null) : _removers[uid];

  /// Body of the remove form of [uid], null when the page offers none bound to exactly that user.
  Map<String, String>? removePayload(int uid) => _formFor(add: false, uid: uid)?.payload;

  /// Body of the add form of [uid], null when the page offers none bound to exactly that user.
  Map<String, String>? addPayload(int uid) => _formFor(add: true, uid: uid)?.payload;

  /// Action of the form [removePayload] / [addPayload] came from.
  Uri? actionOf({required bool add, required int uid}) => _formFor(add: add, uid: uid)?.action;
}

final _quotaRe = RegExp(r'(\d{1,6})\s*[/／]\s*(\d{1,6})');
final _rowIdRe = RegExp(r'^bu_row_(\d+)$');
final _uidLabelRe = RegExp(r'^UID\s*(\d+)$');

int? _uidLabel(uh.Element e) => parseStrictUid(_uidLabelRe.firstMatch(_textOf(e))?.group(1));

/// Quota of `#bu_quota` (`已屏蔽 1／10 人`, half or full width slash), null when the page prints none or not exactly one
/// pair. Both numbers come from the page.
WebsiteBlocklistQuota? _parseQuota(uh.Element page) {
  final boxes = page.querySelectorAll('#bu_quota');
  if (boxes.length != 1) {
    return null;
  }
  final pairs = _quotaRe.allMatches(_textOf(boxes.single)).toList();
  if (pairs.length != 1) {
    return null;
  }
  final used = int.parse(pairs.single.group(1)!);
  final limit = int.parse(pairs.single.group(2)!);
  return limit > 0 ? WebsiteBlocklistQuota(used: used, limit: limit) : null;
}

/// Rows of `table#bu_list`: each `tbody > tr#bu_row_N` names user N in its row id, its profile link
/// (`span.bu-name > a`) and its `span.bu-uid` label, all the same; the third cell may hold that user's
/// `form.bu-delform`. Any other row, a row naming several users, the account itself or a user twice rejects the page.
({List<WebsiteBlockedUser> rows, Map<int, _PluginForm> removers}) _parseRows(
  uh.Element table, {
  required int expectedUid,
}) {
  if (table.querySelector('table') != null) {
    _unsupported('nested table in the list');
  }
  final rows = <WebsiteBlockedUser>[];
  final removers = <int, _PluginForm>{};
  for (final tr in table.querySelectorAll('tr')) {
    final section = tr.parent;
    if (section?.localName == 'thead' && identical(section?.parent, table)) {
      continue;
    }
    if (section?.localName != 'tbody' || !identical(section?.parent, table)) {
      _unsupported('row outside the list body');
    }
    final uid = parseStrictUid(_rowIdRe.firstMatch(tr.attributes['id'] ?? '')?.group(1));
    if (uid == null) {
      _unsupported('row without a user id');
    }
    final cells = tr.children;
    if (cells.length != 3 || cells.any((e) => e.localName != 'td')) {
      _unsupported('row cells');
    }
    final links = cells.first.querySelectorAll('.bu-name a[href]');
    final labels = cells.first.querySelectorAll('.bu-uid');
    if (links.length != 1 || labels.length != 1) {
      _unsupported('row member');
    }
    if (parseStrictProfileUid(links.single.attributes['href']) != uid || _uidLabel(labels.single) != uid) {
      _unsupported('row identity does not match');
    }
    if (tr.querySelectorAll('a[href]').any((a) => (uidOfProfileUrl(a.attributes['href']) ?? uid) != uid)) {
      _unsupported('row links several users');
    }
    if (uid == expectedUid) {
      _unsupported('row of the account itself');
    }
    if (rows.any((e) => e.uid == uid)) {
      _unsupported('user listed twice');
    }
    final forms = tr.querySelectorAll('form');
    if (forms.length == 1 && _hasClass(forms.single, 'bu-delform') && _inside(forms.single, cells.last)) {
      try {
        final form = _parsePluginForm(forms.single, _FormKind.remove);
        if (form.target == uid) {
          removers[uid] = form;
        } else {
          talker.warning('website blacklist remove form names another user, skipped');
        }
      } on WebsiteBlocklistRejected catch (e) {
        talker.warning('website blacklist remove form skipped: ${e.reason}');
      }
    } else if (forms.isNotEmpty) {
      talker.warning('website blacklist row forms not understood, skipped');
    }
    rows.add(
      WebsiteBlockedUser(uid: uid, username: _textOf(links.single), removable: removers.containsKey(uid)),
    );
  }
  return (rows: rows, removers: removers);
}

/// The lookup result `#bu_confirm` of [lookupUid]: `b#bu_confirmname` is the name and `.bu-member .bu-uid` the uid
/// the forum returned, which must be [lookupUid]; `form#bu_addform` inside it must be for that same uid.
///
/// Without a confirmation the member is not found, unless the list already holds it.
({WebsiteBlocklistLookup? lookup, _PluginForm? adder}) _parseLookup(
  uh.Document doc,
  uh.Element page, {
  required WebsiteBlocklist list,
  required int lookupUid,
}) {
  final confirms = doc.querySelectorAll('#bu_confirm');
  final addForms = doc.querySelectorAll('#bu_addform');
  final listed = list.rowOf(lookupUid);
  if (confirms.isEmpty) {
    if (addForms.isNotEmpty) {
      _unsupported('add form outside the confirmation');
    }
    return (
      lookup: listed == null
          ? null
          : WebsiteBlocklistLookup(uid: lookupUid, username: listed.username, alreadyListed: true, canAdd: false),
      adder: null,
    );
  }
  if (confirms.length != 1 || !_inside(confirms.single, page)) {
    _unsupported('confirmation not understood');
  }
  final confirm = confirms.single;
  final names = confirm.querySelectorAll('#bu_confirmname');
  final labels = confirm.querySelectorAll('.bu-member .bu-uid');
  if (names.length != 1 || labels.length != 1) {
    _unsupported('confirmation member');
  }
  final shown = _uidLabel(labels.single);
  if (shown == null) {
    _unsupported('confirmation uid');
  }
  if (shown != lookupUid) {
    _mismatch('lookup shows another user');
  }
  final linked = confirm.querySelectorAll('a[href]').map((a) => uidOfProfileUrl(a.attributes['href']));
  if (linked.any((e) => e != null && e != lookupUid)) {
    _mismatch('lookup links another user');
  }
  _PluginForm? adder;
  if (addForms.length == 1 && _inside(addForms.single, confirm)) {
    try {
      adder = _parsePluginForm(addForms.single, _FormKind.add);
    } on WebsiteBlocklistRejected catch (e) {
      talker.warning('website blacklist add form skipped: ${e.reason}');
    }
    if (adder != null && adder.target != lookupUid) {
      _mismatch('add form of another user');
    }
  } else if (addForms.isNotEmpty) {
    talker.warning('website blacklist add forms not understood, skipped');
  }
  final canAdd = listed == null && adder != null;
  return (
    lookup: WebsiteBlocklistLookup(
      uid: lookupUid,
      username: _textOf(names.single),
      alreadyListed: listed != null,
      canAdd: canAdd,
    ),
    adder: canAdd ? adder : null,
  );
}

/// Parse a website blacklist page [raw] of account [expectedUid]; with [lookupUid], also the member lookup of it.
///
/// Only the observed `blockuser` plugin page is understood: one `div#bu_page` holding `table#bu_list`, optionally the
/// lookup form `form#bu_qform`, the quota `#bu_quota` and the lookup result `#bu_confirm`. Fails closed: a page that
/// is not a normal forum page of [expectedUid], a page without the list table (never read as an empty list), a row
/// that does not name exactly one user, the account itself or a user listed twice give an error instead of a list.
/// The list is only complete when the page prints a count that matches its rows and is not split into pages.
///
/// Never throws anything but [WebsiteBlocklistRejected].
WebsiteBlocklistDocument parseWebsiteBlocklistDocument(String raw, {required int expectedUid, int? lookupUid}) {
  try {
    return _parsePage(raw, expectedUid: expectedUid, lookupUid: lookupUid);
  } on WebsiteBlocklistRejected {
    rethrow;
  } on Object catch (e) {
    throw WebsiteBlocklistRejected(WebsiteBlocklistFailure.unsupported, 'malformed page: ${e.runtimeType}');
  }
}

WebsiteBlocklistDocument _parsePage(String raw, {required int expectedUid, int? lookupUid}) {
  final doc = parseHtmlDocument(raw);
  if (forumPageProblem(doc, expectedUid: expectedUid, requireIdentity: true) case final p?) {
    throw WebsiteBlocklistRejected(
      _failureOf(p.failure),
      'page rejected: ${p.failure}',
      message: _displayMessage(p.message),
    );
  }
  if (!raw.toLowerCase().contains('</html>')) {
    _unsupported('incomplete page');
  }
  final pages = doc.querySelectorAll('#bu_page');
  if (pages.length != 1) {
    _unsupported('plugin page not found');
  }
  final page = pages.single;
  final queryForms = doc.querySelectorAll('#bu_qform');
  if (queryForms.length > 1 || queryForms.any((f) => f.localName != 'form' || !_isLookupForm(f))) {
    _unsupported('lookup form not understood');
  }
  final tables = doc.querySelectorAll('#bu_list');
  if (tables.length != 1 || tables.single.localName != 'table' || !_inside(tables.single, page)) {
    _unsupported('list table not found');
  }
  final (:rows, :removers) = _parseRows(tables.single, expectedUid: expectedUid);

  final quota = _parseQuota(page);
  final paginated = page.querySelector('.pg') != null;
  final counted = quota?.used != null && quota!.used == rows.length;
  final list = WebsiteBlocklist(ownerUid: expectedUid, rows: rows, complete: !paginated && counted, quota: quota);

  if (lookupUid == null) {
    return WebsiteBlocklistDocument._(list: list, lookup: null, removers: removers, adder: null);
  }
  final (:lookup, :adder) = _parseLookup(doc, page, list: list, lookupUid: lookupUid);
  return WebsiteBlocklistDocument._(list: list, lookup: lookup, removers: removers, adder: adder);
}

/// Website blacklist of the forum's `blockuser` plugin: NOT the Discuz friend blacklist, NOT the notice ignore rules
/// (`filter_note`) and NOT the local block list.
///
/// Every operation takes the [NetClientProvider] of the account it acts for and that account's uid, and uses that one
/// client for reading, writing and verifying (the client drops requests once its account is not current any more).
///
/// A write is only sent after the user confirmed it, from a form read just before for exactly the chosen user, at
/// most once and without transport retries, and only while the caller's `stillCurrent` check passes right before
/// sending; the list is always read again afterwards, also when the answer to the write is lost, and only that list
/// decides whether the change is confirmed. Logs never contain page content or user names.
class WebsiteBlocklistRepository with LoggerMixin {
  /// Constructor.
  const WebsiteBlocklistRepository();

  Future<Either<WebsiteBlocklistError, WebsiteBlocklistDocument>> _read(
    NetClientProvider client,
    String url, {
    required int uid,
    int? lookupUid,
  }) async {
    final resp = await client.get(url, options: pageReadOptions()).run();
    switch (resp) {
      case Left(:final value):
        error('website blacklist read failed: ${value.runtimeType}');
        return left(const WebsiteBlocklistError(WebsiteBlocklistFailure.network));
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        final failure = _failureOf(failureOfPageStatus(value));
        error('website blacklist page answered ${value.statusCode}: $failure');
        return left(WebsiteBlocklistError(failure));
      case Right(:final value) when value.data is! String:
        return left(const WebsiteBlocklistError(WebsiteBlocklistFailure.unsupported));
      case Right(:final value):
        try {
          final raw = value.data as String;
          return right(parseWebsiteBlocklistDocument(raw, expectedUid: uid, lookupUid: lookupUid));
        } on WebsiteBlocklistRejected catch (e) {
          error('website blacklist page rejected: $e');
          return left(e.error);
        }
    }
  }

  /// Load the website blacklist of account [uid].
  Future<Either<WebsiteBlocklistError, WebsiteBlocklist>> fetchList(
    NetClientProvider client, {
    required int uid,
  }) async => (await _read(client, websiteBlocklistUrl, uid: uid)).map((e) => e.list);

  /// Read-only lookup of member [target] for account [uid]; never writes anything.
  Future<Either<WebsiteBlocklistError, WebsiteBlocklistLookup>> lookup(
    NetClientProvider client, {
    required int uid,
    required int target,
  }) async => switch (await _read(client, websiteBlocklistLookupUrl(target), uid: uid, lookupUid: target)) {
    Left(:final value) => left(value),
    Right(value: WebsiteBlocklistDocument(lookup: final found?)) => right(found),
    Right() => left(const WebsiteBlocklistError(WebsiteBlocklistFailure.notFound)),
  };

  static const _expired = WebsiteBlocklistWrite.failed(WebsiteBlocklistError(WebsiteBlocklistFailure.accountMismatch));

  /// Add [target] to the website blacklist of [uid], with a fresh lookup form of exactly that member.
  ///
  /// [expectedName] is the name the user confirmed; a lookup now showing another name sends nothing. Nothing is sent
  /// once [stillCurrent] fails, which is checked before the fresh read and again right before sending.
  Future<WebsiteBlocklistWrite> add(
    NetClientProvider client, {
    required int uid,
    required int target,
    String? expectedName,
    WebsiteBlocklistStillCurrent? stillCurrent,
  }) async {
    if (target <= 0 || target == uid) {
      return const WebsiteBlocklistWrite.failed(WebsiteBlocklistError(WebsiteBlocklistFailure.targetMismatch));
    }
    if (stillCurrent?.call() == false) {
      return _expired;
    }
    final WebsiteBlocklistDocument page;
    switch (await _read(client, websiteBlocklistLookupUrl(target), uid: uid, lookupUid: target)) {
      case Left(:final value):
        return WebsiteBlocklistWrite.failed(value);
      case Right(:final value):
        page = value;
    }
    final found = page.lookup;
    if (found == null) {
      return const WebsiteBlocklistWrite.failed(WebsiteBlocklistError(WebsiteBlocklistFailure.notFound));
    }
    final renamed = expectedName != null && expectedName.isNotEmpty && found.username != expectedName;
    if (renamed) {
      warning('website blacklist lookup names another member now, not sent');
      return const WebsiteBlocklistWrite.failed(WebsiteBlocklistError(WebsiteBlocklistFailure.targetMismatch));
    }
    if (found.alreadyListed) {
      // Nothing to send; read the whole list so the caller shows it.
      return switch (await _read(client, websiteBlocklistUrl, uid: uid)) {
        Left(:final value) => WebsiteBlocklistWrite.failed(value),
        Right(:final value) =>
          value.list.contains(target)
              ? WebsiteBlocklistWrite.success(list: value.list, alreadyApplied: true)
              : WebsiteBlocklistWrite.failed(
                  const WebsiteBlocklistError(WebsiteBlocklistFailure.notListed),
                  list: value.list,
                ),
      };
    }
    final data = page.addPayload(target);
    final action = page.actionOf(add: true, uid: target);
    if (data == null || action == null) {
      warning('website blacklist add form not usable, not sent');
      return WebsiteBlocklistWrite.failed(
        const WebsiteBlocklistError(WebsiteBlocklistFailure.unsupported),
        list: page.list.complete ? page.list : null,
      );
    }
    return _submitAndVerify(
      client,
      uid: uid,
      action: action,
      data: data,
      target: target,
      present: true,
      stillCurrent: stillCurrent,
    );
  }

  /// Remove [target] from the website blacklist of [uid], with the remove form of that row read just before.
  ///
  /// Nothing is sent once [stillCurrent] fails, which is checked before the fresh read and again right before sending.
  Future<WebsiteBlocklistWrite> remove(
    NetClientProvider client, {
    required int uid,
    required int target,
    WebsiteBlocklistStillCurrent? stillCurrent,
  }) async {
    if (stillCurrent?.call() == false) {
      return _expired;
    }
    final WebsiteBlocklistDocument page;
    switch (await _read(client, websiteBlocklistUrl, uid: uid)) {
      case Left(:final value):
        return WebsiteBlocklistWrite.failed(value);
      case Right(:final value):
        page = value;
    }
    if (!page.list.contains(target)) {
      return page.list.complete
          ? WebsiteBlocklistWrite.success(list: page.list, alreadyApplied: true)
          : WebsiteBlocklistWrite.failed(
              const WebsiteBlocklistError(WebsiteBlocklistFailure.notListed),
              list: page.list,
            );
    }
    final data = page.removePayload(target);
    final action = page.actionOf(add: false, uid: target);
    if (data == null || action == null) {
      warning('website blacklist remove form not usable, not sent');
      return WebsiteBlocklistWrite.failed(
        const WebsiteBlocklistError(WebsiteBlocklistFailure.unsupported),
        list: page.list,
      );
    }
    return _submitAndVerify(
      client,
      uid: uid,
      action: action,
      data: data,
      target: target,
      present: false,
      stillCurrent: stillCurrent,
    );
  }

  /// Send [data] once, then read the list again: confirmed only when [target] is [present] (absent: in a complete
  /// list). The state before is known not to match, so a match now is this request's change.
  ///
  /// [stillCurrent] is checked right before sending: an operation that expired while its form was read (an account
  /// switch, also A → B → A) sends nothing.
  Future<WebsiteBlocklistWrite> _submitAndVerify(
    NetClientProvider client, {
    required int uid,
    required Uri action,
    required Map<String, String> data,
    required int target,
    required bool present,
    required WebsiteBlocklistStillCurrent? stillCurrent,
  }) async {
    if (stillCurrent?.call() == false) {
      warning('website blacklist write expired before sending, not sent');
      return _expired;
    }
    WebsiteBlocklistError? refused;
    switch (await client.postForm(action.toString(), data: data, singleAttempt: true).run()) {
      case Left(value: HttpHandshakeFailedException(statusCode: 301 || 302 || 303)):
        // A form post the forum handled answers with a redirect, not followed for a single attempt: verify below.
        break;
      case Left(value: HttpHandshakeFailedException(statusCode: 403 || 503, :final headers))
          when headers?.value('cf-mitigated')?.toLowerCase() == 'challenge':
        warning('website blacklist write stopped by a site challenge');
        refused = const WebsiteBlocklistError(WebsiteBlocklistFailure.challenge);
      case Left(:final value):
        // The request may have reached the forum: never sent again, the list below tells.
        error('website blacklist write failed, result unknown: ${value.runtimeType}');
      case Right(:final value) when value.data is String:
        final doc = parseHtmlDocument(unwrapAjax(value.data as String));
        if (forumPageProblem(doc, expectedUid: uid, requireIdentity: false) case final p?) {
          warning('website blacklist write answered ${p.failure}');
          refused = WebsiteBlocklistError(_failureOf(p.failure), message: _displayMessage(p.message));
        }
      case Right():
        break;
    }
    switch (await _read(client, websiteBlocklistUrl, uid: uid)) {
      case Left():
        return WebsiteBlocklistWrite.failed(
          refused ?? const WebsiteBlocklistError(WebsiteBlocklistFailure.unknownAfterSubmit),
          sent: true,
        );
      case Right(value: WebsiteBlocklistDocument(:final list)):
        final ok = present ? list.contains(target) : (list.complete && !list.contains(target));
        if (refused != null) {
          // Refused but changed anyway, or refused and unchanged: never reported as done.
          return WebsiteBlocklistWrite.failed(
            ok ? const WebsiteBlocklistError(WebsiteBlocklistFailure.unknownAfterSubmit) : refused,
            list: list,
            sent: true,
          );
        }
        return ok
            ? WebsiteBlocklistWrite.success(list: list)
            : WebsiteBlocklistWrite.failed(
                const WebsiteBlocklistError(WebsiteBlocklistFailure.unknownAfterSubmit),
                list: list,
                sent: true,
              );
    }
  }
}
