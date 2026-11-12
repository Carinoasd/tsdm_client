import 'package:flutter/foundation.dart' show immutable;
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/thread_perms.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

/// The pages of the moderation panel the forum's app API (plugin 3.9.0, second round) answers as fields: the panel's
/// first page with the moderators' notes (`modcp_home`, `schema` 39), the thread management (`modcp_thread`, 36), the
/// post management (`modcp_post`, 37) and the members' special permissions in a forum (`modcp_forumaccess`, 38).
///
/// Each form an answer describes is used only when it posts to the panel's own page of this forum with field names of
/// the shape the panel reads, so a tampered answer can never send a write elsewhere.

String _str(Object? v) => v == null ? '' : '$v';

List<Map<String, dynamic>> _list(Object? v) => v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];

/// The forums an answer offers (`forums[]`).
List<ModcpForum> _forums(Object? v) => [
  for (final f in _list(v))
    if (tsdmAppInt(f['fid']) > 0) ModcpForum(fid: tsdmAppInt(f['fid']), name: _str(f['name'])),
];

/// The answer [json] is page [type] of `schema` [schema] or later.
bool _isPage(Map<String, dynamic> json, String type, int schema) =>
    json['ok'] == 1 && json['type'] == type && tsdmAppInt(json['schema']) >= schema;

/// The name of a field the panel reads: `name`, `name[]` or `name[key]`.
final _fieldName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(\[[A-Za-z0-9_]*\])?$');

/// The fields choosing the page the panel draws: never taken from an answer but as expected.
const _guarded = {'mod', 'action', 'op', 'do'};

/// The bare name of field [field] (`delete[]` → `delete`).
String _bare(String field) => field.contains('[') ? field.substring(0, field.indexOf('[')) : field;

/// A form of the panel as an answer describes it: the page it is sent to and its fixed fields.
@immutable
final class ModcpPanelForm {
  /// Constructor.
  const ModcpPanelForm({required this.url, required this.fields});

  /// The form [json] (`url`, `fields`) of the panel's page [action] (and [op] when given); null unless it is sent to
  /// that page of this forum, its query no more than [query] allows, its fixed fields of the panel's shape. The fixed
  /// fields never carry those the app fills ([filled]: bare names), nor choose the page: the panel reads the body's
  /// fields over the URL's (Discuz merges `$_POST` into `$_GET`), so `mod` and `action` are refused there, and `op`,
  /// `do` (and the others of [expect]) must be exactly what [expect] gives.
  static ModcpPanelForm? parse(
    Object? json, {
    required String action,
    String? op,
    Set<String> query = const {},
    Set<String> filled = const {},
    Map<String, String> expect = const {},
  }) {
    if (json is! Map) {
      return null;
    }
    final raw = _str(json['url']).trim();
    final fields = json['fields'];
    if (raw.isEmpty || (fields != null && fields is! Map)) {
      return null;
    }
    final uri = Uri.parse('$baseUrl/').resolve(raw);
    final q = uri.queryParameters;
    if (uri.origin != Uri.parse(baseUrl).origin ||
        uri.path != '/forum.php' ||
        uri.fragment.isNotEmpty ||
        q['mod'] != 'modcp' ||
        q['action'] != action ||
        (op != null && q['op'] != op) ||
        q.keys.any((k) => !{'mod', 'action', if (op != null) 'op', ...query}.contains(k))) {
      return null;
    }
    final given = (fields as Map?) ?? const {};
    if (expect.entries.any((e) => _str(given[e.key]) != e.value || !given.containsKey(e.key))) {
      return null;
    }
    final fixed = <String, String>{};
    for (final MapEntry(:key, :value) in given.entries) {
      final name = '$key';
      if (!_fieldName.hasMatch(name) || value is Map || value is List) {
        return null;
      }
      if (_guarded.contains(_bare(name)) && !expect.containsKey(name)) {
        return null;
      }
      if (!filled.contains(_bare(name))) {
        fixed[name] = _str(value);
      }
    }
    return ModcpPanelForm(url: uri.toString(), fields: Map.unmodifiable(fixed));
  }

  /// Absolute URL the form is sent to.
  final String url;

  /// Its fixed fields (form hash, submit flags).
  final Map<String, String> fields;

  /// The URL of a GET of this form with [params] after its fixed fields, in the JSON mode.
  String getUrl(Map<String, String> params) {
    final uri = Uri.parse(url);
    return withTsdmAppJson(
      uri.replace(queryParameters: {...uri.queryParameters, ...fields, ...params}).toString(),
    );
  }

  /// The URL a POST of this form is sent to, in the JSON mode.
  String get postUrl => withTsdmAppJsonWrite(url);
}

/// Field name [json] of an answer when it is of the panel's shape ([_fieldName]); null otherwise.
String? _field(Object? json) {
  final name = _str(json).trim();
  return _fieldName.hasMatch(name) ? name : null;
}

/// Field name [json] of a list (`name[]`); null otherwise.
String? _listField(Object? json) {
  final name = _field(json);
  return name != null && name.endsWith('[]') ? name : null;
}

/// [values] as the indexed fields of list [field] (`delete[]` → `delete[0]`, `delete[1]`…, as PHP reads a list: a
/// map can not hold the same key twice).
Map<String, String> _indexed(String field, Iterable<String> values) {
  final name = field.substring(0, field.length - 2);
  return {for (final (i, v) in values.indexed) '$name[$i]': v};
}

/// The panel's relative list URL [raw] of page [action]／[op] (`do=list`), absolute; null unless it is that list on
/// this forum.
String? _listUrl(Object? raw, {required String action, required String op}) {
  final text = _str(raw).trim();
  if (text.isEmpty) {
    return null;
  }
  final uri = Uri.parse('$baseUrl/').resolve(text);
  final q = uri.queryParameters;
  if (uri.origin != Uri.parse(baseUrl).origin ||
      uri.path != '/forum.php' ||
      q['mod'] != 'modcp' ||
      q['action'] != action ||
      q['op'] != op ||
      q['do'] != 'list' ||
      q.keys.any((k) => !const {'mod', 'action', 'op', 'do', 'fid', 'posttableid'}.contains(k))) {
    return null;
  }
  return uri.toString();
}

/// What a page of the panel always carries: the account it was served to, the forum shown and those offered.
@immutable
abstract base class ModcpJsonPage {
  /// Constructor.
  const ModcpJsonPage({
    required this.uid,
    required this.fid,
    required this.forum,
    required this.forums,
    required this.isModerator,
    this.messageKey = '',
  });

  /// The account it was served to.
  final int uid;

  /// The forum shown, 0 for none.
  final int fid;

  /// Its name; empty when the panel does not list it among [forums] (not one the account moderates).
  final String forum;

  /// The forums the panel offers the account.
  final List<ModcpForum> forums;

  /// The account moderates [fid].
  final bool isModerator;

  /// The forum's language key of what it said of the form just sent (`message_key`), empty when it said nothing or
  /// nothing was sent.
  final String messageKey;

  /// The name of [fid]: its own, or the one [forums] gives it.
  String get forumName => forum.isNotEmpty ? forum : (forums.where((f) => f.fid == fid).firstOrNull?.name ?? '');
}

// ---------------------------------------------------------------------------------------------------------------------
// The panel's first page and the notes (schema 39)
// ---------------------------------------------------------------------------------------------------------------------

/// A note the moderators leave each other on the panel's first page.
@immutable
final class ModcpNote {
  /// Constructor.
  const ModcpNote({
    required this.id,
    required this.admin,
    required this.dateline,
    required this.expiration,
    required this.message,
    required this.toSupermod,
    required this.toModerator,
    required this.canDelete,
  });

  /// Note id.
  final int id;

  /// Who left it.
  final String admin;

  /// When (seconds).
  final int dateline;

  /// When it goes (seconds).
  final int expiration;

  /// The note (plain text).
  final String message;

  /// The super moderators see it.
  final bool toSupermod;

  /// The moderators see it.
  final bool toModerator;

  /// The account may delete it (its own; any for an administrator).
  final bool canDelete;
}

/// The form adding a note: the message, who sees it and for how many days.
@immutable
final class ModcpNoteAddForm {
  /// Constructor.
  const ModcpNoteAddForm({
    required this.form,
    required this.messageField,
    required this.supermodField,
    required this.moderatorField,
    required this.daysField,
    required this.daysDefault,
  });

  /// The `add` of an answer; null when it is not one to use.
  static ModcpNoteAddForm? parse(Object? json) {
    if (json is! Map) {
      return null;
    }
    final message = _field(json['message_field']);
    final supermod = _field(json['supermod_field']);
    final moderator = _field(json['moderator_field']);
    final days = _field(json['days_field']);
    if (message == null || supermod == null || moderator == null || days == null) {
      return null;
    }
    final form = ModcpPanelForm.parse(
      json,
      action: 'home',
      filled: {_bare(message), _bare(supermod), _bare(moderator), _bare(days)},
      expect: const {'op': 'addnote'},
    );
    if (form == null) {
      return null;
    }
    final daysDefault = tsdmAppInt(json['days_default']);
    return ModcpNoteAddForm(
      form: form,
      messageField: message,
      supermodField: supermod,
      moderatorField: moderator,
      daysField: days,
      daysDefault: daysDefault > 0 ? daysDefault : 30,
    );
  }

  /// The panel's form.
  final ModcpPanelForm form;

  /// The note (`newmessage`).
  final String messageField;

  /// The super moderators see it (`newaccess[2]`).
  final String supermodField;

  /// The moderators see it (`newaccess[3]`).
  final String moderatorField;

  /// How many days it is kept (`newexpiration`).
  final String daysField;

  /// The days offered first.
  final int daysDefault;

  /// The body adding [message] for [days] days, seen by the super moderators when [toSupermod] and the moderators
  /// when [toModerator] (the administrators always).
  Map<String, String> body({
    required String message,
    required bool toSupermod,
    required bool toModerator,
    required int days,
  }) => {
    ...form.fields,
    messageField: message.trim(),
    if (toSupermod) supermodField: '1',
    if (toModerator) moderatorField: '1',
    daysField: '${days > 0 ? days : daysDefault}',
  };
}

/// A form of the panel sending the ids picked of a list ([idsField], `delete[]`).
@immutable
final class ModcpIdsForm {
  /// Constructor.
  const ModcpIdsForm({required this.form, required this.idsField});

  /// The form [json] of page [action] (and [op]); null when it is not one to use.
  static ModcpIdsForm? parse(
    Object? json, {
    required String action,
    required Map<String, String> expect,
    String? op,
    Set<String> filled = const {},
  }) {
    if (json is! Map) {
      return null;
    }
    final ids = _listField(json['ids_field']);
    if (ids == null) {
      return null;
    }
    final form = ModcpPanelForm.parse(json, action: action, op: op, filled: {_bare(ids), ...filled}, expect: expect);
    return form == null ? null : ModcpIdsForm(form: form, idsField: ids);
  }

  /// The panel's form.
  final ModcpPanelForm form;

  /// The ids sent (`delete[]`).
  final String idsField;

  /// The body sending [ids], indexed.
  Map<String, String> body(Iterable<String> ids) => {...form.fields, ..._indexed(idsField, ids)};
}

/// The panel's first page: what waits, the notes, and their forms.
final class ModcpHome extends ModcpJsonPage {
  /// Constructor.
  const ModcpHome({
    required super.uid,
    required super.forums,
    required this.moderateCount,
    required this.noteCount,
    required this.forumCount,
    required this.notes,
    this.addForm,
    this.deleteForm,
    super.messageKey,
  }) : super(fid: 0, forum: '', isModerator: false);

  /// The threads and replies (and new members) waiting for moderation; null when the forum does not count them.
  final int? moderateCount;

  /// The notes.
  final int noteCount;

  /// The forums the account manages.
  final int forumCount;

  /// The notes the account sees.
  final List<ModcpNote> notes;

  /// Adding a note, null when the answer has none to use.
  final ModcpNoteAddForm? addForm;

  /// Deleting notes, null when the answer has none to use.
  final ModcpIdsForm? deleteForm;
}

/// The panel's first page in answer [json] (`type: modcp_home`, `schema` 39); null when it is not one.
ModcpHome? modcpHomeFromApi(Map<String, dynamic> json) {
  if (!_isPage(json, 'modcp_home', 39)) {
    return null;
  }
  final counts = json['counts'] is Map ? json['counts'] as Map : const <String, Object?>{};
  return ModcpHome(
    uid: tsdmAppInt(json['uid']),
    forums: _forums(json['forums']),
    moderateCount: counts['moderate'] == null ? null : tsdmAppInt(counts['moderate']),
    noteCount: tsdmAppInt(counts['notes']),
    forumCount: tsdmAppInt(counts['forums']),
    notes: [
      for (final n in _list(json['notes']))
        if (tsdmAppInt(n['id']) > 0)
          ModcpNote(
            id: tsdmAppInt(n['id']),
            admin: _str(n['admin']),
            dateline: tsdmAppInt(n['dateline']),
            expiration: tsdmAppInt(n['expiration']),
            message: _str(n['message']).trim(),
            toSupermod: n['to_supermod'] == 1,
            toModerator: n['to_moderator'] == 1,
            canDelete: n['can_delete'] == 1,
          ),
    ],
    addForm: ModcpNoteAddForm.parse(json['add']),
    deleteForm: ModcpIdsForm.parse(json['delete'], action: 'home', expect: const {'op': 'delete'}),
    messageKey: _str(json['message_key']),
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Thread management (schema 36)
// ---------------------------------------------------------------------------------------------------------------------

/// A choice of a select of the panel (`value`, `label`).
typedef ModcpOption = ({String value, String label});

List<ModcpOption> _options(Object? v) => [
  for (final o in _list(v)) (value: _str(o['value']), label: _str(o['label'])),
];

/// The search form of the thread or the post management (`search`): a GET of the panel's page with the conditions.
@immutable
final class ModcpSearchForm {
  /// Constructor.
  const ModcpSearchForm({required this.form, required this.fidField});

  /// The `search` [json] of page `thread`／[op]; null when it is not one to use.
  static ModcpSearchForm? parse(Object? json, {required String op, required Set<String> conditions}) {
    if (json is! Map) {
      return null;
    }
    final fid = _field(json['fid_field']);
    if (fid == null || fid.contains('[')) {
      return null;
    }
    final form = ModcpPanelForm.parse(
      json,
      action: 'thread',
      op: op,
      filled: {fid, ...conditions},
      expect: const {'do': 'search'},
    );
    return form == null ? null : ModcpSearchForm(form: form, fidField: fid);
  }

  /// The panel's form.
  final ModcpPanelForm form;

  /// The forum searched (`fid`).
  final String fidField;

  /// The URL searching forum [fid] for [conditions] (those not empty).
  String url(int fid, Map<String, String> conditions) => form.getUrl({
    fidField: '$fid',
    for (final MapEntry(:key, :value) in conditions.entries)
      if (value.trim().isNotEmpty) key: value.trim(),
  });
}

/// The conditions of a thread search, the panel's parameters.
abstract final class ModcpThreadQuery {
  /// The type of thread (`threadoptions[]`).
  static const threadOption = 'threadoption';

  /// The authors, comma separated.
  static const users = 'users';

  /// The words.
  static const keywords = 'keywords';

  /// Posted from (`YYYY-MM-DD`).
  static const startTime = 'starttime';

  /// Posted until (`YYYY-MM-DD`).
  static const endTime = 'endtime';

  /// More views than.
  static const viewsMore = 'viewsmore';

  /// Fewer views than.
  static const viewsLess = 'viewsless';

  /// More replies than.
  static const repliesMore = 'repliesmore';

  /// Fewer replies than.
  static const repliesLess = 'repliesless';

  /// No reply for that many days.
  static const noReplyDays = 'noreplydays';

  /// The forum's thread category.
  static const typeId = 'typeid';

  /// Every condition.
  static const all = <String>{
    threadOption,
    users,
    keywords,
    startTime,
    endTime,
    viewsMore,
    viewsLess,
    repliesMore,
    repliesLess,
    noReplyDays,
    typeId,
  };

  /// Whether [conditions] hold one the panel searches by: a type of thread other than "all", or any other value.
  static bool hasCondition(Map<String, String> conditions) => conditions.entries.any(
    (e) => all.contains(e.key) && e.value.trim().isNotEmpty && !(e.key == threadOption && e.value.trim() == '0'),
  );
}

/// A thread of the panel's thread list.
@immutable
final class ModcpThreadRow {
  /// Constructor.
  const ModcpThreadRow({
    required this.tid,
    required this.subject,
    required this.author,
    required this.authorId,
    required this.dateline,
    required this.lastPost,
    required this.replies,
    required this.views,
    required this.digest,
    required this.displayOrder,
    required this.closed,
    required this.special,
  });

  /// Thread id.
  final int tid;

  /// Title.
  final String subject;

  /// Author's name (empty for an anonymous one).
  final String author;

  /// Author's uid.
  final int authorId;

  /// Posted (seconds).
  final int dateline;

  /// Last reply (seconds).
  final int lastPost;

  /// Replies.
  final int replies;

  /// Views.
  final int views;

  /// Digest level, 0 none.
  final int digest;

  /// Stick level, 0 none.
  final int displayOrder;

  /// Closed.
  final bool closed;

  /// Special thread (poll, trade, reward…), 0 none.
  final int special;
}

/// A page of the panel's thread management: the threads of a forum, or the results of a search.
final class ModcpThreadPage extends ModcpJsonPage {
  /// Constructor.
  const ModcpThreadPage({
    required super.uid,
    required super.fid,
    required super.forum,
    required super.forums,
    required super.isModerator,
    required this.needForum,
    required this.isSearch,
    required this.filters,
    required this.threadOptions,
    required this.threadClasses,
    required this.page,
    required this.pages,
    required this.count,
    required this.threads,
    this.perms,
    this.search,
    this.listUrl,
    this.canModerate = false,
  });

  /// A forum the account moderates must be chosen first: nothing is listed.
  final bool needForum;

  /// The threads are the results of a search (`do: list`), not the forum's.
  final bool isSearch;

  /// The conditions of the search shown.
  final Map<String, String> filters;

  /// The types of thread to search by.
  final List<ModcpOption> threadOptions;

  /// The forum's thread categories (`typeid`, name).
  final List<ModcpOption> threadClasses;

  /// This page.
  final int page;

  /// Pages.
  final int pages;

  /// Threads in all.
  final int count;

  /// The threads of this page.
  final List<ModcpThreadRow> threads;

  /// What the account may do with the threads picked (as on the forum page), null when the answer tells nothing.
  final ThreadPerms? perms;

  /// The search, null when the answer has none to use.
  final ModcpSearchForm? search;

  /// The results' pages (`do=list`), null when the answer has none to use.
  final String? listUrl;

  /// The threads picked may be managed (the answer gives the forum's `topicadmin` form).
  final bool canModerate;

  /// The URL of page [page] of the results.
  String? resultsUrl(int page) => listUrl == null ? null : withTsdmAppJson('$listUrl${page > 1 ? '&page=$page' : ''}');
}

/// The panel's thread management in answer [json] (`type: modcp_thread`, `schema` 36); null when it is not one.
ModcpThreadPage? modcpThreadFromApi(Map<String, dynamic> json) {
  if (!_isPage(json, 'modcp_thread', 36)) {
    return null;
  }
  final fid = tsdmAppInt(json['fid']);
  final needForum = json['need_forum'] == 1 || fid <= 0;
  final filters = json['filters'] is Map ? json['filters'] as Map : const <String, Object?>{};
  final moderate = json['moderate'];
  return ModcpThreadPage(
    uid: tsdmAppInt(json['uid']),
    fid: needForum ? 0 : fid,
    forum: _str(json['forum']),
    forums: _forums(json['forums']),
    isModerator: json['ismoderator'] == 1,
    needForum: needForum,
    isSearch: json['do'] == 'list',
    filters: {for (final MapEntry(:key, :value) in filters.entries) '$key': _str(value)},
    threadOptions: _options(json['threadoptions']),
    threadClasses: [
      for (final c in _list(json['threadclasses']))
        if (tsdmAppInt(c['typeid']) > 0) (value: '${tsdmAppInt(c['typeid'])}', label: _str(c['name'])),
    ],
    page: tsdmAppInt(json['page']).clamp(1, 1 << 30),
    pages: tsdmAppInt(json['pages']).clamp(1, 1 << 30),
    count: tsdmAppInt(json['count']),
    threads: needForum
        ? const []
        : [
            for (final t in _list(json['threads']))
              if (tsdmAppInt(t['tid']) > 0)
                ModcpThreadRow(
                  tid: tsdmAppInt(t['tid']),
                  subject: _str(t['subject']),
                  author: _str(t['author']),
                  authorId: tsdmAppInt(t['authorid']),
                  dateline: tsdmAppInt(t['dateline']),
                  lastPost: tsdmAppInt(t['lastpost']),
                  replies: tsdmAppInt(t['replies']),
                  views: tsdmAppInt(t['views']),
                  digest: tsdmAppInt(t['digest']),
                  displayOrder: tsdmAppInt(t['displayorder']),
                  closed: tsdmAppInt(t['closed']) == 1,
                  special: tsdmAppInt(t['special']),
                ),
          ],
    perms: needForum ? null : ThreadPerms.fromApi(json['perms']),
    search: ModcpSearchForm.parse(json['search'], op: 'thread', conditions: ModcpThreadQuery.all),
    listUrl: needForum ? null : _listUrl(json['list_url'], action: 'thread', op: 'thread'),
    // The forum's own topicadmin form of this forum: the app's management of several threads sends it.
    canModerate: !needForum && moderate is Map && _isModerateForm(moderate, fid),
  );
}

/// Whether [json] is the forum's form managing threads of forum [fid] (`topicadmin`, `moderate[]`).
bool _isModerateForm(Map<dynamic, dynamic> json, int fid) {
  final uri = Uri.parse('$baseUrl/').resolve(_str(json['url']).trim());
  final q = uri.queryParameters;
  return uri.origin == Uri.parse(baseUrl).origin &&
      uri.path == '/forum.php' &&
      uri.fragment.isEmpty &&
      q.keys.every(const {'mod', 'action', 'fid', 'infloat', 'nopost'}.contains) &&
      q['mod'] == 'topicadmin' &&
      q['action'] == 'moderate' &&
      q['fid'] == '$fid' &&
      _listField(json['ids_field']) != null;
}

// ---------------------------------------------------------------------------------------------------------------------
// Post management (schema 37)
// ---------------------------------------------------------------------------------------------------------------------

/// The conditions of a post search, the panel's parameters.
abstract final class ModcpPostQuery {
  /// Where (`threadoptions[]`: all, first posts, replies).
  static const threadOption = 'threadoption';

  /// The authors, comma separated.
  static const users = 'users';

  /// The words, comma separated.
  static const keywords = 'keywords';

  /// The IP (`*` allowed).
  static const useIp = 'useip';

  /// Posted from (`YYYY-MM-DD`).
  static const startTime = 'starttime';

  /// Posted until (`YYYY-MM-DD`), an administrator's only.
  static const endTime = 'endtime';

  /// Every condition.
  static const all = <String>{threadOption, users, keywords, useIp, startTime, endTime};

  /// Whether [conditions] hold one of those the panel needs at least one of: an author, a word or an IP.
  static bool hasCondition(Map<String, String> conditions) =>
      [users, keywords, useIp].any((k) => (conditions[k] ?? '').trim().isNotEmpty);
}

/// Why the panel did not search or delete (`error_key`).
enum ModcpPostError {
  /// None.
  none,

  /// No author, word or IP.
  condition,

  /// The time range is longer than the account may search.
  range,

  /// A word is too short.
  keyword,

  /// The account may not delete posts several at a time.
  noperm,

  /// Another reason.
  unknown,
}

/// A post of the panel's post management.
@immutable
final class ModcpPostRow {
  /// Constructor.
  const ModcpPostRow({
    required this.pid,
    required this.tid,
    required this.fid,
    required this.forum,
    required this.first,
    required this.subject,
    required this.authorId,
    required this.author,
    required this.dateline,
    required this.pending,
    required this.message,
  });

  /// Post id.
  final int pid;

  /// Its thread.
  final int tid;

  /// Its forum.
  final int fid;

  /// The forum's name.
  final String forum;

  /// The thread's first post (deleting it deletes the thread).
  final bool first;

  /// The thread's title.
  final String subject;

  /// Author's uid.
  final int authorId;

  /// Author's name.
  final String author;

  /// Posted (seconds).
  final int dateline;

  /// Waiting for moderation (`invisible` −2).
  final bool pending;

  /// The beginning of the post (plain text).
  final String message;
}

/// The search limits of the account.
typedef ModcpPostLimits = ({int days, bool endTimeFixed, int keywordMinBytes});

/// The form deleting the posts picked: their ids, and the credits kept when asked.
@immutable
final class ModcpPostDeleteForm {
  /// Constructor.
  const ModcpPostDeleteForm({required this.ids, required this.noCreditField});

  /// The `delete` of an answer; null when it is not one to use.
  static ModcpPostDeleteForm? parse(Object? json, {required int fid}) {
    if (json is! Map) {
      return null;
    }
    final noCredit = _field(json['nocredit_field']);
    if (noCredit == null) {
      return null;
    }
    final ids = ModcpIdsForm.parse(
      json,
      action: 'thread',
      op: 'post',
      filled: {_bare(noCredit)},
      expect: {'do': 'delete', 'fid': '$fid'},
    );
    return ids == null ? null : ModcpPostDeleteForm(ids: ids, noCreditField: noCredit);
  }

  /// The ids and the panel's form.
  final ModcpIdsForm ids;

  /// The author keeps the credits (`nocredit`).
  final String noCreditField;

  /// The body deleting [pids], the credits kept when [keepCredits].
  Map<String, String> body(Iterable<int> pids, {bool keepCredits = false}) => {
    ...ids.body(pids.map((e) => '$e')),
    if (keepCredits) noCreditField: '1',
  };
}

/// A page of the panel's post management: the search and its results.
final class ModcpPostPage extends ModcpJsonPage {
  /// Constructor.
  const ModcpPostPage({
    required super.uid,
    required super.fid,
    required super.forum,
    required super.forums,
    required super.isModerator,
    required this.isSearch,
    required this.filters,
    required this.threadOptions,
    required this.limits,
    required this.error,
    required this.page,
    required this.pages,
    required this.count,
    required this.posts,
    required this.allowDelete,
    this.search,
    this.listUrl,
    this.deleteForm,
    super.messageKey,
  });

  /// The posts are the results of a search (`do: list`).
  final bool isSearch;

  /// The conditions shown.
  final Map<String, String> filters;

  /// Where to search.
  final List<ModcpOption> threadOptions;

  /// The account's limits.
  final ModcpPostLimits limits;

  /// Why the panel did not search or delete.
  final ModcpPostError error;

  /// This page.
  final int page;

  /// Pages.
  final int pages;

  /// Posts in all.
  final int count;

  /// The posts of this page.
  final List<ModcpPostRow> posts;

  /// The account may delete posts several at a time.
  final bool allowDelete;

  /// The search, null when the answer has none to use.
  final ModcpSearchForm? search;

  /// The results' pages, null when the answer has none to use.
  final String? listUrl;

  /// Deleting the posts picked, null when the answer has none to use.
  final ModcpPostDeleteForm? deleteForm;

  /// The posts may be deleted.
  bool get canDelete => allowDelete && deleteForm != null;

  /// The URL of page [page] of the results.
  String? resultsUrl(int page) => listUrl == null ? null : withTsdmAppJson('$listUrl${page > 1 ? '&page=$page' : ''}');
}

/// The panel's post management in answer [json] (`type: modcp_post`, `schema` 37); null when it is not one.
ModcpPostPage? modcpPostFromApi(Map<String, dynamic> json) {
  if (!_isPage(json, 'modcp_post', 37)) {
    return null;
  }
  final filters = json['filters'] is Map ? json['filters'] as Map : const <String, Object?>{};
  final limits = json['limits'] is Map ? json['limits'] as Map : const <String, Object?>{};
  final fid = tsdmAppInt(json['fid']);
  return ModcpPostPage(
    uid: tsdmAppInt(json['uid']),
    fid: fid > 0 ? fid : 0,
    forum: _str(json['forum']),
    forums: _forums(json['forums']),
    isModerator: json['ismoderator'] == 1,
    isSearch: json['do'] == 'list',
    filters: {for (final MapEntry(:key, :value) in filters.entries) '$key': _str(value)},
    threadOptions: _options(json['threadoptions']),
    limits: (
      days: tsdmAppInt(limits['days']),
      endTimeFixed: limits['endtime_fixed'] == 1,
      keywordMinBytes: tsdmAppInt(limits['keyword_min_bytes']),
    ),
    error: switch (json['error_key']) {
      '' || null when tsdmAppInt(json['error']) == 0 => ModcpPostError.none,
      'condition' => ModcpPostError.condition,
      'range' => ModcpPostError.range,
      'keyword' => ModcpPostError.keyword,
      'noperm' => ModcpPostError.noperm,
      _ => ModcpPostError.unknown,
    },
    page: tsdmAppInt(json['page']).clamp(1, 1 << 30),
    pages: tsdmAppInt(json['pages']).clamp(1, 1 << 30),
    count: tsdmAppInt(json['count']),
    posts: [
      for (final p in _list(json['posts']))
        if (tsdmAppInt(p['pid']) > 0)
          ModcpPostRow(
            pid: tsdmAppInt(p['pid']),
            tid: tsdmAppInt(p['tid']),
            fid: tsdmAppInt(p['fid']),
            forum: _str(p['forum']),
            first: tsdmAppInt(p['first']) == 1,
            subject: _str(p['subject']),
            authorId: tsdmAppInt(p['authorid']),
            author: _str(p['author']),
            dateline: tsdmAppInt(p['dateline']),
            pending: tsdmAppInt(p['invisible']) == -2,
            message: _str(p['message']).trim(),
          ),
    ],
    allowDelete: json['allow_delete'] == 1,
    search: ModcpSearchForm.parse(json['search'], op: 'post', conditions: ModcpPostQuery.all),
    listUrl: _listUrl(json['list_url'], action: 'thread', op: 'post'),
    deleteForm: ModcpPostDeleteForm.parse(json['delete'], fid: fid > 0 ? fid : 0),
    messageKey: _str(json['message_key']),
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Members' permissions in a forum (schema 38)
// ---------------------------------------------------------------------------------------------------------------------

/// A permission of a member in a forum the panel sets apart from the user group's.
enum ModcpAccessRight {
  /// Viewing the forum (denying it denies all).
  view,

  /// Posting threads.
  post,

  /// Replying.
  reply,

  /// Downloading attachments.
  getattach,

  /// Viewing images.
  getimage,

  /// Uploading attachments.
  postattach,

  /// Uploading images.
  postimage,
}

/// A member's permissions in a forum, set apart from the user group's.
@immutable
final class ModcpAccessEntry {
  /// Constructor.
  const ModcpAccessEntry({
    required this.uid,
    required this.username,
    required this.fid,
    required this.forum,
    required this.rights,
    required this.admin,
    required this.dateline,
  });

  /// The member.
  final int uid;

  /// Their name.
  final String username;

  /// The forum.
  final int fid;

  /// Its name.
  final String forum;

  /// Each permission: −1 denied, 1 allowed (by the admin centre), 0 as the user group.
  final Map<ModcpAccessRight, int> rights;

  /// Who set them.
  final String admin;

  /// When (seconds).
  final int dateline;

  /// The permissions denied.
  Set<ModcpAccessRight> get denied => {
    for (final r in ModcpAccessRight.values)
      if ((rights[r] ?? 0) < 0) r,
  };

  /// The permissions the admin centre allowed (a moderator can not change them).
  Set<ModcpAccessRight> get allowed => {
    for (final r in ModcpAccessRight.values)
      if ((rights[r] ?? 0) > 0) r,
  };
}

/// The form setting a member's permissions in a forum: denied ones, or back to the user group's.
@immutable
final class ModcpAccessForm {
  /// Constructor.
  const ModcpAccessForm({
    required this.form,
    required this.fidField,
    required this.userField,
    required this.restoreField,
    required this.restoreValue,
    required this.denyValue,
    required this.denyFields,
  });

  /// The `add` of an answer; null when it is not one to use.
  static ModcpAccessForm? parse(Object? json) {
    if (json is! Map || json['deny_fields'] is! Map) {
      return null;
    }
    final fid = _field(json['fid_field']);
    final user = _field(json['user_field']);
    final restore = _field(json['restore_field']);
    final deny = json['deny_fields'] as Map;
    final denyFields = <ModcpAccessRight, String>{
      for (final r in ModcpAccessRight.values) r: ?_field(deny[r.name]),
    };
    if (fid == null || user == null || restore == null || denyFields.length != ModcpAccessRight.values.length) {
      return null;
    }
    final form = ModcpPanelForm.parse(
      json,
      action: 'forumaccess',
      filled: {fid, user, restore, for (final f in denyFields.values) _bare(f)},
      expect: const {'op': ''},
    );
    if (form == null) {
      return null;
    }
    final denyValue = _str(json['deny_value']).trim();
    final restoreValue = _str(json['restore_value']).trim();
    return ModcpAccessForm(
      form: form,
      fidField: fid,
      userField: user,
      restoreField: restore,
      restoreValue: restoreValue.isEmpty ? '1' : restoreValue,
      denyValue: denyValue.isEmpty ? '-1' : denyValue,
      denyFields: Map.unmodifiable(denyFields),
    );
  }

  /// The panel's form.
  final ModcpPanelForm form;

  /// The forum (`fid`).
  final String fidField;

  /// The member's name (`new_user`).
  final String userField;

  /// Back to the user group's (`deleteaccess`).
  final String restoreField;

  /// Its value.
  final String restoreValue;

  /// The value of a permission denied (`-1`).
  final String denyValue;

  /// Each permission's field (`new_view`…).
  final Map<ModcpAccessRight, String> denyFields;

  /// The body denying [denied] to member [username] in forum [fid] (the whole set: those not sent are the user group's
  /// again; viewing denied denies all).
  Map<String, String> body(int fid, String username, Set<ModcpAccessRight> denied) {
    final all = denied.contains(ModcpAccessRight.view) ? ModcpAccessRight.values.toSet() : denied;
    return {
      ...form.fields,
      fidField: '$fid',
      userField: username.trim(),
      for (final r in ModcpAccessRight.values)
        if (all.contains(r)) denyFields[r]!: denyValue,
    };
  }

  /// The body giving member [username] the user group's permissions in forum [fid] again.
  Map<String, String> restoreBody(int fid, String username) => {
    ...form.fields,
    fidField: '$fid',
    userField: username.trim(),
    restoreField: restoreValue,
  };
}

/// The form looking a member up in the list.
@immutable
final class ModcpAccessSearchForm {
  /// Constructor.
  const ModcpAccessSearchForm({required this.form, required this.fidField, required this.userField});

  /// The `search` of an answer; null when it is not one to use.
  static ModcpAccessSearchForm? parse(Object? json) {
    if (json is! Map) {
      return null;
    }
    final fid = _field(json['fid_field']);
    final user = _field(json['user_field']);
    if (fid == null || user == null) {
      return null;
    }
    final form = ModcpPanelForm.parse(json, action: 'forumaccess', filled: {fid, user});
    return form == null ? null : ModcpAccessSearchForm(form: form, fidField: fid, userField: user);
  }

  /// The panel's form.
  final ModcpPanelForm form;

  /// The forum.
  final String fidField;

  /// The member's name (`suser`).
  final String userField;

  /// The body looking [username] up in forum [fid].
  Map<String, String> body(int fid, String username) => {
    ...form.fields,
    fidField: '$fid',
    userField: username.trim(),
  };
}

/// What the panel did with the form just sent (`result`).
enum ModcpAccessResult {
  /// Nothing was sent, or nothing done without a reason (no permission picked).
  none,

  /// Done.
  done,

  /// No such member.
  nouser,

  /// The member is of the staff: only an administrator may set them.
  staff,

  /// A permission the admin centre allowed: a moderator can not change it.
  whitelist,

  /// Another reason.
  unknown,
}

/// A page of the members' permissions in a forum.
final class ModcpAccessPage extends ModcpJsonPage {
  /// Constructor.
  const ModcpAccessPage({
    required super.uid,
    required super.fid,
    required super.forum,
    required super.forums,
    required super.isModerator,
    required this.keyword,
    required this.page,
    required this.pages,
    required this.count,
    required this.entries,
    required this.result,
    required this.canAdd,
    this.addForm,
    this.searchForm,
    super.messageKey,
  });

  /// The member looked up, empty for all.
  final String keyword;

  /// This page.
  final int page;

  /// Pages.
  final int pages;

  /// Entries in all.
  final int count;

  /// The entries of this page.
  final List<ModcpAccessEntry> entries;

  /// What the form just sent did.
  final ModcpAccessResult result;

  /// The account moderates the forum: it may set permissions.
  final bool canAdd;

  /// Setting permissions, null when the answer has none to use.
  final ModcpAccessForm? addForm;

  /// Looking a member up, null when the answer has none to use.
  final ModcpAccessSearchForm? searchForm;

  /// A forum must be chosen first.
  bool get needForum => fid <= 0;

  /// Permissions may be set.
  bool get canSet => canAdd && addForm != null;
}

/// The members' permissions in answer [json] (`type: modcp_forumaccess`, `schema` 38); null when it is not one.
ModcpAccessPage? modcpAccessFromApi(Map<String, dynamic> json) {
  if (!_isPage(json, 'modcp_forumaccess', 38)) {
    return null;
  }
  final result = json['result'] is Map ? json['result'] as Map : const <String, Object?>{};
  final fid = tsdmAppInt(json['fid']);
  return ModcpAccessPage(
    uid: tsdmAppInt(json['uid']),
    fid: fid > 0 ? fid : 0,
    forum: _str(json['forum']),
    forums: _forums(json['forums']),
    isModerator: json['ismoderator'] == 1,
    keyword: _str(json['keyword']),
    page: tsdmAppInt(json['page']).clamp(1, 1 << 30),
    pages: tsdmAppInt(json['pages']).clamp(1, 1 << 30),
    count: tsdmAppInt(json['count']),
    entries: [
      for (final e in _list(json['list']))
        if (tsdmAppInt(e['uid']) > 0)
          ModcpAccessEntry(
            uid: tsdmAppInt(e['uid']),
            username: _str(e['username']),
            fid: tsdmAppInt(e['fid']),
            forum: _str(e['forum']),
            rights: {for (final r in ModcpAccessRight.values) r: tsdmAppInt(e[r.name]).clamp(-1, 1)},
            admin: _str(e['admin']),
            dateline: tsdmAppInt(e['dateline']),
          ),
    ],
    result: switch ((tsdmAppInt(result['done']), result['error_key'])) {
      (1, _) => ModcpAccessResult.done,
      (_, 'nouser') => ModcpAccessResult.nouser,
      (_, 'staff') => ModcpAccessResult.staff,
      (_, 'whitelist') => ModcpAccessResult.whitelist,
      (_, '' || null) when tsdmAppInt(result['error']) == 0 => ModcpAccessResult.none,
      _ => ModcpAccessResult.unknown,
    },
    canAdd: json['can_add'] == 1 && fid > 0,
    addForm: fid > 0 ? ModcpAccessForm.parse(json['add']) : null,
    searchForm: fid > 0 ? ModcpAccessSearchForm.parse(json['search']) : null,
    messageKey: _str(json['message_key']),
  );
}
