import 'package:flutter/foundation.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// What a page of the moderation panel (`forum.php?mod=modcp`) answered: [T], the panel's login form, or its refusal.
sealed class ModcpAnswer<T> {
  const ModcpAnswer();
}

/// The page asked, read.
final class ModcpReady<T> extends ModcpAnswer<T> {
  /// Constructor.
  const ModcpReady(this.value);

  /// What the page holds.
  final T value;
}

/// The panel asks the moderator's password again (the first visit, or after an hour idle): its login form.
final class ModcpNeedsLogin<T> extends ModcpAnswer<T> {
  /// Constructor.
  const ModcpNeedsLogin({required this.formHash});

  /// The form hash of the login form.
  final String formHash;
}

/// The panel refused, in its own words [message] (no access, locked after too many wrong passwords, no permission for
/// this page); empty when it gave none.
final class ModcpRefused<T> extends ModcpAnswer<T> {
  /// Constructor.
  const ModcpRefused(this.message);

  /// The forum's message.
  final String message;
}

/// A forum the panel offers in its forum select (`select[name="fid"]`).
@immutable
final class ModcpForum {
  /// Constructor.
  const ModcpForum({required this.fid, required this.name});

  /// The forum.
  final int fid;

  /// Its name, as the select prints it.
  final String name;

  @override
  bool operator ==(Object other) => other is ModcpForum && other.fid == fid && other.name == name;

  @override
  int get hashCode => Object.hash(fid, name);
}

/// The forums of the panel's forum select on page [doc] (its "all" and "choose a forum" left out), in its order, and
/// the one selected (0 for none).
(List<ModcpForum>, int) modcpForums(uh.Document doc) {
  final select = doc.querySelector('select[name="fid"]');
  if (select == null) {
    return (const [], 0);
  }
  final forums = <ModcpForum>[];
  var selected = 0;
  for (final option in select.querySelectorAll('option')) {
    final fid = int.tryParse(option.attributes['value'] ?? '') ?? 0;
    if (fid <= 0) {
      continue;
    }
    forums.add(ModcpForum(fid: fid, name: (option.text ?? '').trim()));
    if (option.attributes.containsKey('selected')) {
      selected = fid;
    }
  }
  return (forums, selected);
}

/// The query of a link [url] of `forum.php`, null for anything else.
Map<String, String>? modcpQuery(String url) {
  final Uri uri;
  try {
    uri = Uri.parse(url.replaceAll('&amp;', '&'));
  } on FormatException {
    return null;
  }
  if (!isForumScriptUri(uri, 'forum.php')) {
    return null;
  }
  return uniqueQueryParameters(uri);
}

/// Whether [doc] is a page of the panel's [action] (its tab of the action shown, `ul.tb > li.a`).
bool _isPanelTab(uh.Document doc, String action) => doc
    .querySelectorAll('ul.tb > li.a > a')
    .map((e) => modcpQuery(e.attributes['href'] ?? ''))
    .any((q) => q != null && q['mod'] == 'modcp' && q['action'] == action);

/// The panel's note in place of a list (`p.xi1`: choose a forum), empty when there is none.
String modcpNote(uh.Document doc) =>
    (doc.querySelector('div.mn p.xi1')?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

// ---------------------------------------------------------------------------------------------------------------------
// Recycle bin
// ---------------------------------------------------------------------------------------------------------------------

/// The two recycle bins of the panel: deleted threads (`action=recyclebin`) and deleted replies
/// (`action=recyclebinpost`).
enum RecycleBinKind {
  /// Threads (主题回收站).
  threads('recyclebin'),

  /// Replies (回帖回收站).
  posts('recyclebinpost')
  ;

  const RecycleBinKind(this.action);

  /// The panel's `action`.
  final String action;
}

/// What a moderator does to the items picked in a recycle bin (`op`).
enum RecycleBinAction {
  /// Put them back where they were (`restore`).
  restore,

  /// Delete them for good (`delete`); the forum offers it only to a group allowed to (`allowclearrecycle`), and does
  /// nothing for the others, without a word.
  delete,
}

/// One deleted thread or reply, as the recycle bin lists it.
final class RecycleBinItem {
  /// Constructor.
  const RecycleBinItem({
    required this.id,
    required this.title,
    required this.author,
    required this.time,
    this.authorUid,
    this.tid,
    this.reason = '',
    this.replies = '',
    this.views = '',
  });

  /// The thread id (threads) or the post id (replies), the `moderate[]` of the item.
  final String id;

  /// The thread's subject, or the reply's text as the bin lists it.
  final String title;

  /// The author's name, as listed.
  final String author;

  /// The author's uid when the list links the author.
  final int? authorUid;

  /// When it was posted, as the forum printed it.
  final String time;

  /// The thread a reply is in (`ptid`); null for a thread.
  final String? tid;

  /// Why it was deleted, as the thread bin lists it (理由); empty for a reply.
  final String reason;

  /// The thread's replies and views (回复/查看), as listed; empty for a reply.
  final String replies;

  /// See [replies].
  final String views;
}

/// The hidden fields of the bin's form (`form#moderate`) sent back with an operation.
const recycleBinServedFields = {'formhash', 'posttableid'};

/// One page of a recycle bin of the panel, served to [uid].
///
/// [fid] is 0 when no forum is chosen (none asked, or one whose recycle bin is off): then only [forums] are read.
final class RecycleBinList {
  /// Constructor.
  const RecycleBinList({
    required this.kind,
    required this.fid,
    required this.forums,
    required this.items,
    required this.fields,
    required this.uid,
    this.canDelete = false,
    this.page = 1,
    this.hasNext = false,
    this.note = '',
  });

  /// The bin.
  final RecycleBinKind kind;

  /// The forum, 0 for none.
  final int fid;

  /// The forums whose bin the panel offers (the forums the account moderates that keep one).
  final List<ModcpForum> forums;

  /// What is in the bin, in the forum's order.
  final List<RecycleBinItem> items;

  /// The hidden fields of the bin's form ([recycleBinServedFields]); empty when the bin is empty.
  final Map<String, String> fields;

  /// The account the page was served to.
  final int uid;

  /// The bin offers deleting for good (its 删除 button).
  final bool canDelete;

  /// The page number.
  final int page;

  /// The forum links a next page.
  final bool hasNext;

  /// The panel's note in place of the bin when no forum is chosen (`p.xi1`: choose a forum to manage).
  final String note;

  /// The url of page [page] of bin [kind] of forum [fid] (none for 0).
  static String url(RecycleBinKind kind, {int fid = 0, int page = 1}) =>
      '$baseUrl/forum.php?mod=modcp&action=${kind.action}'
      '${fid > 0 ? '&fid=$fid' : ''}${page > 1 ? '&page=$page' : ''}';

  /// The url the bin's operations are posted to. The forum answers with the first page of the bin again (no
  /// message): what is still listed was not done.
  String get submitUrl => '$baseUrl/forum.php?mod=modcp&action=${kind.action}&fid=$fid&page=1';

  /// The form body of [action] on the items [ids].
  Map<String, String> body(RecycleBinAction action, List<String> ids) => {
    ...fields,
    'op': action.name,
    'oldop': 'list',
    'dosubmit': 'submit',
    for (final (i, id) in ids.indexed) 'moderate[$i]': id,
  };
}

/// Bin [kind] on page [doc], served to [uid]; null when [doc] is not that bin (another page, the form of another
/// forum).
///
/// A forum other than [fid] selected, or none, is the bin without a forum (its [RecycleBinList.fid] 0): the forum
/// asked keeps no bin, or is not the account's.
RecycleBinList? parseRecycleBin(
  uh.Document doc,
  RecycleBinKind kind, {
  required int fid,
  required int uid,
  int page = 1,
}) {
  if (!_isPanelTab(doc, kind.action)) {
    return null;
  }
  final (forums, selected) = modcpForums(doc);
  if (fid <= 0 || selected != fid) {
    return RecycleBinList(
      kind: kind,
      fid: 0,
      forums: forums,
      items: const [],
      fields: const {},
      uid: uid,
      note: modcpNote(doc),
    );
  }
  final form = doc.querySelector('form#moderate');
  if (form == null) {
    // The bin is empty: no form, only the forum's "no result".
    return RecycleBinList(
      kind: kind,
      fid: fid,
      forums: forums,
      items: const [],
      fields: const {},
      uid: uid,
      page: page,
    );
  }
  final fields = <String, String>{};
  for (final input in form.querySelectorAll('input[type="hidden"]')) {
    final name = input.attributes['name'] ?? '';
    if (recycleBinServedFields.contains(name)) {
      fields[name] = input.attributes['value'] ?? '';
    }
  }
  final target = modcpQuery(form.attributes['action'] ?? '');
  if ((fields['formhash'] ?? '').isEmpty ||
      target == null ||
      target['action'] != kind.action ||
      target['fid'] != '$fid') {
    return null;
  }
  final items = <RecycleBinItem>[];
  for (final row in form.querySelectorAll('tbody > tr')) {
    final id = row.querySelector('input[type="checkbox"][name="moderate[]"]')?.attributes['value'] ?? '';
    if (int.tryParse(id) == null) {
      continue;
    }
    items.add(switch (kind) {
      RecycleBinKind.threads => _threadItem(row, id),
      RecycleBinKind.posts => _postItem(row, id),
    });
  }
  return RecycleBinList(
    kind: kind,
    fid: fid,
    forums: forums,
    items: items,
    fields: fields,
    uid: uid,
    // The template's `<button onclick="modthreads('delete')">`, printed for a group allowed to (`allowclearrecycle`,
    // `forum/modcp_recyclebin.htm` and `modcp_recyclebinpost.htm`).
    canDelete: form.querySelectorAll('button').any((e) => (e.attributes['onclick'] ?? '').contains("'delete'")),
    page: page,
    hasNext: doc.querySelector('div.pg a.nxt') != null,
  );
}

String _text(uh.Element? e) => (e?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

int? _uidOf(uh.Element? link) {
  final match = RegExp(r'[?&]uid=(\d+)').firstMatch(link?.attributes['href'] ?? '');
  return match == null ? null : int.tryParse(match.group(1)!);
}

RecycleBinItem _threadItem(uh.Element row, String id) {
  final cells = row.querySelectorAll('td.by');
  final authorLink = cells.firstOrNull?.querySelector('cite a');
  final counts = row.querySelector('td.num');
  return RecycleBinItem(
    id: id,
    title: _text(row.querySelector('span#thread_$id a') ?? row.querySelector('th a')),
    author: _text(authorLink ?? cells.firstOrNull?.querySelector('cite')),
    authorUid: _uidOf(authorLink),
    time: _text(cells.firstOrNull?.querySelector('em')),
    reason: cells.length >= 3 ? _text(cells.last) : '',
    replies: _text(counts?.querySelector('strong')),
    views: _text(counts?.querySelector('em')),
  );
}

RecycleBinItem _postItem(uh.Element row, String id) {
  final cells = row.querySelectorAll('td');
  final link = row.querySelector('a[href*="goto=findpost"]');
  final by = row.querySelectorAll('td.by');
  final authorLink = by.firstOrNull?.querySelector('a');
  final tid = RegExp(r'[?&;]ptid=(\d+)').firstMatch((link?.attributes['href'] ?? '').replaceAll('&amp;', '&'));
  return RecycleBinItem(
    id: id,
    title: _text(link ?? (cells.length > 1 ? cells[1] : null)),
    author: _text(authorLink ?? by.firstOrNull),
    authorUid: _uidOf(authorLink),
    // The last column is the time it was posted.
    time: by.length >= 2 ? _text(by.last) : '',
    tid: tid?.group(1),
  );
}

/// How the panel answered an operation on a recycle bin.
sealed class RecycleBinOutcome {
  const RecycleBinOutcome();
}

/// The bin no longer lists any of the items sent: all [count] were done.
final class RecycleBinDone extends RecycleBinOutcome {
  /// Constructor.
  const RecycleBinDone(this.count);

  /// How many.
  final int count;
}

/// The bin still lists [remaining] of the items sent: not done (no permission, the forum does it without a word), the
/// others were.
final class RecycleBinNotDone extends RecycleBinOutcome {
  /// Constructor.
  const RecycleBinNotDone({required this.done, required this.remaining});

  /// How many were done; at most that many when a later page could not be read again (the items picked on it are
  /// counted done).
  final int done;

  /// The items still in the bin.
  final List<String> remaining;
}

/// Sent, and the panel answered, but whether all were done is not known: a later page an item was picked on could not
/// be read again.
final class RecycleBinUnknown extends RecycleBinOutcome {
  /// Constructor.
  const RecycleBinUnknown();
}

/// The panel showed its login form: its session ended, nothing was done.
final class RecycleBinSessionEnded extends RecycleBinOutcome {
  /// Constructor.
  const RecycleBinSessionEnded();
}

/// The panel refused, in its own words [message].
final class RecycleBinRefused extends RecycleBinOutcome {
  /// Constructor.
  const RecycleBinRefused(this.message);

  /// The forum's message.
  final String message;
}

// ---------------------------------------------------------------------------------------------------------------------
// Log
// ---------------------------------------------------------------------------------------------------------------------

/// One line of the panel's log (管理日志, `action=log`), as the forum prints it.
final class ModcpLogEntry {
  /// Constructor.
  const ModcpLogEntry({
    required this.time,
    required this.operator,
    required this.group,
    required this.ip,
    required this.action,
    required this.op,
    required this.forum,
    required this.other,
    this.reason = '',
    this.targets = const [],
  });

  /// The line [e] of the log of the forum's app API (plugin 3.8.0, `entries[]` of a `modcp_log` answer), the same
  /// fields the page's row gives: `dateline` as the forum's wall clock with [timeOffset], printed as the page prints
  /// it (`y-n-j H:i`), the operator (`username`, `group`, `ip`: empty unless the account may see addresses), the page
  /// of the panel in the forum's words (`action_text`, `action` without them), `op`, `forum` and `other`; and what
  /// the page does not tell apart: the `reason` given and the threads, posts and members acted on ([targets]).
  factory ModcpLogEntry.fromApi(Map<String, dynamic> e, {num timeOffset = 8}) {
    final at = tsdmAppWallClockTime(e['dateline'], timeOffset);
    final actionText = tsdmAppText(e['action_text']).trim();
    List<int> ids(Object? value) => value is List ? value.whereType<num>().map((e) => e.toInt()).toList() : const [];
    return ModcpLogEntry(
      time: at == null
          ? ''
          : '${(at.year % 100).toString().padLeft(2, '0')}-${at.month}-${at.day} '
                '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
      operator: tsdmAppText(e['username']).trim(),
      group: tsdmAppText(e['group']).trim(),
      ip: tsdmAppText(e['ip']).trim(),
      action: actionText.isNotEmpty ? actionText : tsdmAppText(e['action']).trim(),
      op: tsdmAppText(e['op']).trim(),
      forum: tsdmAppText(e['forum']).trim(),
      other: tsdmAppText(e['other']).trim(),
      reason: tsdmAppText(e['reason']).trim(),
      targets: [
        for (final tid in ids(e['tids'])) 'tid $tid',
        for (final pid in ids(e['pids'])) 'pid $pid',
        if (e['usernames'] case final List<dynamic> names) ...names.whereType<String>().where((e) => e.isNotEmpty),
        // A member named is not listed again by uid.
        if (e['usernames'] is! List || (e['usernames'] as List).isEmpty)
          for (final uid in ids(e['uids'])) 'uid $uid',
      ],
    );
  }

  /// When, as printed (`y-n-j H:i`).
  final String time;

  /// Who did it.
  final String operator;

  /// The operator's group as printed (管理员, 超级版主, 版主, `GID N`).
  final String group;

  /// From where.
  final String ip;

  /// The page of the panel used (操作), in the forum's words when it has them.
  final String action;

  /// The operation on that page (`op`), empty when none.
  final String op;

  /// The forum, empty when none.
  final String forum;

  /// The rest (其他): the request's fields as the forum cut them.
  final String other;

  /// The reason the moderator gave with the operation, as the forum's app API tells it (plugin 3.8.0); empty when
  /// none was given and for a line read from the page, which keeps it in [other] at best.
  final String reason;

  /// What the operation acted on, as the forum's app API tells it (plugin 3.8.0): `tid N` for a thread, `pid N` for
  /// a post, a member's name (`uid N` when the line names none). Empty for a line that only opened a page of the
  /// panel and for a line read from the page.
  final List<String> targets;
}

/// One page of the panel's log, served to [uid].
final class ModcpLogPage {
  /// Constructor.
  const ModcpLogPage({
    required this.entries,
    required this.uid,
    this.keyword = '',
    this.page = 1,
    this.hasNext = false,
  });

  /// The lines, newest first.
  final List<ModcpLogEntry> entries;

  /// The account the page was served to.
  final int uid;

  /// The keyword the lines were filtered by.
  final String keyword;

  /// The page number.
  final int page;

  /// The forum links a next page.
  final bool hasNext;

  /// The url of page [page] of the log, the lines containing [keyword] only when not empty.
  static String url({String keyword = '', int page = 1}) =>
      '$baseUrl/forum.php?mod=modcp&action=log'
      '${keyword.isNotEmpty ? '&keyword=${Uri.encodeQueryComponent(keyword)}' : ''}'
      '${page > 1 ? '&page=$page' : ''}';
}

/// The log in the answer [json] of the forum's app API (plugin 3.8.0: `type: modcp_log`, `schema` 24) asked for
/// [keyword], served to the account the answer names; null when [json] is not that answer (an older plugin leaves the
/// panel's pages as they are: the web page is parsed, [parseModcpLog]).
///
/// X5 writes the panel's operations to its database while its page still reads the log files of older versions and
/// lists nothing: this answer is where the lines are. The times are the forum's wall clock with the answer's
/// `timeoffset` (the forum's own when it names none); there is a next page while `page` is below `pages`.
ModcpLogPage? modcpLogFromApi(Map<String, dynamic> json, {String keyword = ''}) {
  if (json['ok'] != 1 || json['type'] != 'modcp_log' || json['entries'] is! List) {
    return null;
  }
  final page = tsdmAppInt(json['page']);
  final timeOffset = tsdmAppTimeOffset(json);
  return ModcpLogPage(
    entries: [for (final e in tsdmAppList(json['entries'])) ModcpLogEntry.fromApi(e, timeOffset: timeOffset)],
    uid: tsdmAppInt(json['uid']),
    keyword: json['keyword'] is String ? json['keyword'] as String : keyword,
    page: page > 0 ? page : 1,
    hasNext: page > 0 && page < tsdmAppInt(json['pages']),
  );
}

/// The log on page [doc], served to [uid]; null when [doc] is not the log (no search form of the log).
ModcpLogPage? parseModcpLog(uh.Document doc, {required int uid, String keyword = '', int page = 1}) {
  final form = doc.querySelectorAll('div.mn form').where((e) {
    final query = modcpQuery(e.attributes['action'] ?? '');
    return query != null && query['mod'] == 'modcp' && query['action'] == 'log';
  }).firstOrNull;
  if (form == null || form.querySelector('input[name="keyword"]') == null) {
    return null;
  }
  final entries = <ModcpLogEntry>[];
  for (final row in doc.querySelectorAll('table#list_modcp_logs tr')) {
    final cells = row.querySelectorAll('td');
    if (cells.length < 6) {
      // The header, or the "no result" row.
      continue;
    }
    // 操作: the page, a line break, the operation.
    final actionCell = cells[3];
    final parts = <String>[''];
    for (final node in actionCell.nodes) {
      if (node is uh.Element && node.localName == 'br') {
        parts.add('');
      } else {
        parts.last += node.text ?? '';
      }
    }
    String clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
    entries.add(
      ModcpLogEntry(
        time: _text(cells[0]),
        operator: _text(cells[1].querySelector('.xi2') ?? cells[1]),
        group: _text(cells[1].querySelector('.xg1')),
        ip: _text(cells[2]),
        action: clean(parts.first),
        op: clean(parts.skip(1).join(' ')),
        forum: _text(cells[4]),
        other: _text(cells[5]),
      ),
    );
  }
  return ModcpLogPage(
    entries: entries,
    uid: uid,
    keyword: keyword,
    page: page,
    hasNext: doc.querySelector('div.pg a.nxt') != null,
  );
}
