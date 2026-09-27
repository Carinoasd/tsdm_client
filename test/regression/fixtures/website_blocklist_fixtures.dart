import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

// Synthetic pages of the website blacklist (the forum's `blockuser` plugin page), in the DOM structure and with the
// field names observed read-only on the forum (2026-09-27): `div#bu_page`, `#bu_quota` with a full width slash, the
// GET `form#bu_qform` with hidden `mod` / `ac` / `id` and `bu_q`, the lookup result `#bu_confirm` with
// `b#bu_confirmname`, `span.bu-uid` and `form#bu_addform`, and `table#bu_list` rows `tr#bu_row_N` with a
// `form.bu-delform`. Both POST forms carry hidden `formhash`, `blockuseradd` / `blockuserdel` and `buid` and an
// unnamed submit button.
//
// The browser showed no hidden VALUES, so every value here (token, flags, uids, names, dates) is made up. These pages
// test that the served values are preserved; they are not a live round trip.

/// Account the pages belong to.
const blocklistOwner = 1000;

/// Synthetic form token.
const blocklistToken = 'synthetic-hash-01';

/// Synthetic value of the add flag `blockuseradd`.
const blocklistAddFlag = 'synthetic-add';

/// Synthetic value of the remove flag `blockuserdel`.
const blocklistRemoveFlag = 'synthetic-remove';

/// Action of both POST forms, as the page serves it.
const blocklistAction = 'home.php?mod=spacecp&amp;ac=plugin&amp;id=blockuser:spacecp';

/// A full page of account [uid] around [content], with layout links that are not the list.
String blocklistDocument(String content, {int uid = blocklistOwner}) =>
    '''
<html><head><title>黑名單</title></head><body>
<div id="hd"><div id="um"><p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=$uid">owner</a></strong></p></div></div>
<div id="ct"><div class="mn"><div class="bm bw0">
$content
</div></div>
<div class="appl"><a href="home.php?mod=space&amp;uid=4242">sidebar friend</a></div>
</div>
<div id="ft">footer</div>
</body></html>''';

/// Quota text as printed: numbers from the page, full width slash.
String blocklistQuota(int used, int limit) => '已屏蔽 $used／$limit 人';

/// The lookup form `form#bu_qform` as observed.
const blocklistLookupForm = '''
<form id="bu_qform" method="get" action="home.php">
<input type="hidden" name="mod" value="spacecp" />
<input type="hidden" name="ac" value="plugin" />
<input type="hidden" name="id" value="blockuser:spacecp" />
<input type="text" id="bu_q" name="bu_q" maxlength="200" value="" />
<button type="submit" id="bu_qbtn">查詢</button>
</form>''';

/// The plugin page: quota, lookup form, lookup result [confirmation] and the list of [rows]; [quota] null prints none.
String blocklistPage({
  List<String> rows = const [],
  String? quota,
  String confirmation = '',
  String lookupForm = blocklistLookupForm,
  String extra = '',
  int uid = blocklistOwner,
}) => blocklistDocument('''
<div id="bu_page" class="bu-page">
${quota == null ? '' : '<div id="bu_quota" class="bu-quota">$quota</div>'}
$lookupForm
$confirmation
${blocklistTable(rows)}
$extra
</div>''', uid: uid);

/// The list table `table#bu_list` of [rows] (see [blocklistRow]).
String blocklistTable(List<String> rows) =>
    '''
<table id="bu_list" class="bu-list"><thead><tr><th>會員</th><th>加入時間</th><th>操作</th></tr></thead>
<tbody>
${rows.join('\n')}
</tbody></table>''';

/// A POST form of the plugin with every field as given; blank arguments print the field with an empty value.
String blocklistForm({
  required String attributes,
  required String flagName,
  required String flagValue,
  required String target,
  required String button,
  String token = blocklistToken,
  String action = blocklistAction,
  String extraFields = '',
}) =>
    '''
<form $attributes method="post" action="$action">
<input type="hidden" name="formhash" value="$token" />
<input type="hidden" name="$flagName" value="$flagValue" />
<input type="hidden" name="buid" value="$target" />
$extraFields$button
</form>''';

/// One list row `tr#bu_row_N` of user [uid] with its remove form.
///
/// [rowUid], [linkUid] and [labelUid] replace the uid in the row id, the profile link and the `UID N` label;
/// [targetValue] replaces `buid`.
String blocklistRow(
  int uid,
  String name, {
  String token = blocklistToken,
  String? targetValue,
  String flagName = 'blockuserdel',
  String flagValue = blocklistRemoveFlag,
  String action = blocklistAction,
  String extraFields = '',
  String button = '<button type="submit">解除</button>',
  bool withForm = true,
  String? rowUid,
  String? linkUid,
  String? labelUid,
}) =>
    '''
<tr id="bu_row_${rowUid ?? uid}"><td><span class="bu-name"><a href="home.php?mod=space&amp;uid=${linkUid ?? uid}">$name</a></span>
<span class="bu-uid">UID ${labelUid ?? uid}</span></td><td>2026-09-01</td><td>
${withForm ? blocklistForm(attributes: 'class="bu-delform" data-confirm="synthetic"', flagName: flagName, flagValue: flagValue, target: targetValue ?? '$uid', button: button, token: token, action: action, extraFields: extraFields) : ''}
</td></tr>''';

/// The lookup result `#bu_confirm` of member [uid] with its add form.
///
/// [shownUid] replaces the uid in the `UID N` label, [targetValue] replaces `buid`.
String blocklistConfirmation(
  int uid,
  String name, {
  String token = blocklistToken,
  String? targetValue,
  String? shownUid,
  String flagName = 'blockuseradd',
  String flagValue = blocklistAddFlag,
  String action = blocklistAction,
  String extraFields = '',
  String button = '<button type="submit" id="bu_addbtn">確定屏蔽</button>',
  bool withForm = true,
}) =>
    '''
<div id="bu_confirm" class="bu-confirm"><h3>確認屏蔽</h3>
<div class="bu-member"><span class="bu-name"><b id="bu_confirmname">$name</b></span><span class="bu-uid">UID ${shownUid ?? uid}</span></div>
${withForm ? blocklistForm(attributes: 'id="bu_addform"', flagName: flagName, flagValue: flagValue, target: targetValue ?? '$uid', button: button, token: token, action: action, extraFields: extraFields) : ''}
<a href="home.php?mod=spacecp&amp;ac=plugin&amp;id=blockuser:spacecp">取消</a>
</div>''';

/// A forum holding the website blacklist of one account; answers the list page, the lookup and the two forms.
///
/// Writes change [listed] unless told otherwise; every request is recorded.
class BlocklistForum implements HttpClientAdapter {
  /// Constructor.
  BlocklistForum({Map<int, String>? listed, this.limit = 10}) : listed = listed ?? {};

  /// Users on the list, uid to name.
  final Map<int, String> listed;

  /// Members the lookup knows, uid to name.
  final members = <int, String>{2001: 'Alpha', 2002: 'Bravo', 2003: 'Charlie', 2004: 'Delta'};

  /// Quota limit printed on the page.
  int limit;

  /// Uid printed in the page header.
  int pageUid = blocklistOwner;

  /// Replace every list page answer.
  String? listOverride;

  /// Replace every lookup answer.
  String? lookupOverride;

  /// Fail POST requests at the transport level, after the forum applied them when [applyBeforeFailing].
  bool failPost = false;
  bool applyBeforeFailing = false;

  /// Accept a POST but change nothing.
  bool ignoreWrites = false;

  /// Answer every POST with this forum error (and change nothing).
  String? refuseWith;

  /// Answer a POST with a redirect, like Discuz `showmessage` with a quick forward.
  bool redirectWrites = false;

  /// Fail list reads (after the first [failListAfter] ones).
  int? failListAfter;

  /// GETs of the list page wait for this when set.
  Completer<void>? listGate;

  /// GETs of the lookup wait for this when set.
  Completer<void>? lookupGate;

  /// POSTs wait for this when set.
  Completer<void>? postGate;

  final posts = <({Uri uri, Map<String, String> form})>[];
  final gets = <Uri>[];
  int _listReads = 0;

  List<String> get _rows => [for (final e in listed.entries) blocklistRow(e.key, e.value)];

  String get _quota => blocklistQuota(listed.length, limit);

  String listPage() => blocklistPage(rows: _rows, quota: _quota, uid: pageUid);

  String lookupPage(int uid) {
    final name = members[uid];
    return blocklistPage(
      rows: _rows,
      quota: _quota,
      confirmation: name == null || listed.containsKey(uid) ? '' : blocklistConfirmation(uid, name),
      uid: pageUid,
    );
  }

  static ResponseBody html(String body, {int status = 200}) => ResponseBody.fromString(
    body,
    status,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=utf-8'],
    },
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final q = uri.queryParameters;
    if (options.method == 'GET') {
      gets.add(uri);
      final lookup = int.tryParse(q['bu_q'] ?? '');
      if (lookup != null) {
        await lookupGate?.future;
        return html(lookupOverride ?? lookupPage(lookup));
      }
      await listGate?.future;
      _listReads++;
      if (failListAfter != null && _listReads > failListAfter!) {
        throw DioException.connectionError(requestOptions: options, reason: 'reset');
      }
      return html(listOverride ?? listPage());
    }
    var body = '';
    if (requestStream != null) {
      body = utf8.decode(await requestStream.fold<List<int>>([], (a, b) => a..addAll(b)));
    }
    final form = Uri.splitQueryString(body);
    posts.add((uri: uri, form: form));
    await postGate?.future;
    void apply() {
      final target = int.tryParse(form['buid'] ?? '');
      if (target == null || form['formhash'] != blocklistToken) {
        return;
      }
      if (form['blockuseradd'] == blocklistAddFlag) {
        listed[target] = members[target] ?? 'UID $target';
      } else if (form['blockuserdel'] == blocklistRemoveFlag) {
        listed.remove(target);
      }
    }

    if (failPost) {
      if (applyBeforeFailing) {
        apply();
      }
      throw DioException.connectionError(requestOptions: options, reason: 'reset');
    }
    if (refuseWith != null) {
      return html(
        blocklistDocument('<div id="messagetext" class="alert_error"><p>$refuseWith</p></div>', uid: pageUid),
      );
    }
    if (!ignoreWrites) {
      apply();
    }
    if (redirectWrites) {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['home.php?mod=spacecp&ac=plugin&id=blockuser:spacecp'],
        },
      );
    }
    return html(blocklistDocument('<div id="messagetext" class="alert_right"><p>操作成功</p></div>', uid: pageUid));
  }

  @override
  void close({bool force = false}) {}
}
