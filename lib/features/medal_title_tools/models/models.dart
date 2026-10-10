import 'package:tsdm_client/constants/url.dart';

/// Models of the medal and title pages read from the forum's app API (tsdmapp 1.5.0): title exchange, my medals,
/// sending medals (medal centre 3.2) and issuing titles (title plugin 6.2).
///
/// Every write is one of the plugins' own forms as the API describes it ([ApiForm]): the same endpoint and fields as
/// on the website, so the plugins check and do the work exactly as for a browser.

int _int(Object? v) => (v as num?)?.toInt() ?? 0;
String _str(Object? v) => v == null ? '' : '$v'.trim();
List<Map<String, dynamic>> _list(Object? v) => v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];

/// A same-origin image URL, null for anything else.
String? apiImageUrl(Object? value) {
  final src = _str(value);
  if (src.isEmpty) return null;
  final relative = Uri.tryParse(src);
  if (relative == null) return null;
  final uri = Uri.parse(baseUrl).resolveUri(relative);
  if (!['https', 'http'].contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  return uri.toString();
}

/// A form of a plugin described by the API: where it posts and its fixed fields.
final class ApiForm {
  /// Constructor.
  const ApiForm({required this.url, required this.fields});

  /// The form of [json], posting to [plugin] (`id` of `plugin.php`) with `action` [action]; null when it posts
  /// anywhere else, so a tampered answer can never redirect a write.
  static ApiForm? parse(Object? json, {required String plugin, required String action}) {
    if (json is! Map) return null;
    final fields = json['fields'];
    final uri = Uri.parse('$baseUrl/').resolve(_str(json['url']));
    if (fields is! Map ||
        uri.origin != Uri.parse(baseUrl).origin ||
        uri.path != '/plugin.php' ||
        uri.queryParameters['id'] != plugin ||
        uri.queryParameters['action'] != action ||
        uri.queryParameters.keys.any((k) => k != 'id' && k != 'action')) {
      return null;
    }
    return ApiForm(
      url: uri.toString(),
      fields: Map.unmodifiable({for (final e in fields.entries) '${e.key}': '${e.value}'}),
    );
  }

  /// Absolute URL the form posts to.
  final String url;

  /// Fixed fields (form hash, submit flags).
  final Map<String, String> fields;

  /// The body with [extra] fields.
  Map<String, String> body(Map<String, String> extra) => {...fields, ...extra};
}

/// A filter of a list page: its key, label and how many match.
typedef ApiFilter = ({String key, String label, int count});

/// Paging of a list answer.
typedef ApiPaging = ({int page, int pages, int total});

ApiPaging _paging(Object? q) => q is Map
    ? (page: _int(q['page']).clamp(1, 1 << 30), pages: _int(q['pages']).clamp(1, 1 << 30), total: _int(q['total']))
    : (page: 1, pages: 1, total: 0);

List<ApiFilter> _filters(Object? v) => [
  for (final f in _list(v))
    if (_str(f['key']).isNotEmpty) (key: _str(f['key']), label: _str(f['label']), count: _int(f['count'])),
];

/// Whether [json] is a usable answer with the plugin installed.
bool apiInstalled(Map<String, dynamic>? json) => json != null && json['ok'] == 1 && json['installed'] == 1;

// ---------------------------------------------------------------- title exchange

/// A medal a title asks for.
final class ExchangeMedal {
  /// Constructor.
  const ExchangeMedal({required this.id, required this.name, required this.owned, this.imageUrl});

  /// Medal id.
  final int id;

  /// Name.
  final String name;

  /// Image.
  final String? imageUrl;

  /// The account has it (hidden ones count, expired ones do not).
  final bool owned;
}

/// A title got with medals.
final class ExchangeTitle {
  /// Constructor.
  const ExchangeTitle({
    required this.id,
    required this.name,
    required this.description,
    required this.medals,
    required this.ready,
    required this.consume,
    required this.owned,
    this.imageUrl,
  });

  /// Title id.
  final int id;

  /// Name.
  final String name;

  /// Description.
  final String description;

  /// Image.
  final String? imageUrl;

  /// Medals asked for.
  final List<ExchangeMedal> medals;

  /// Every medal is there.
  final bool ready;

  /// The medals are taken when the title is got.
  final bool consume;

  /// The account owns the title already.
  final bool owned;

  /// How many of [medals] the account has.
  int get have => medals.where((m) => m.owned).length;
}

/// A page of the title exchange.
final class ExchangePage {
  /// Constructor.
  const ExchangePage({
    required this.items,
    required this.filters,
    required this.filter,
    required this.paging,
    this.form,
  });

  /// The page of `titleexchange`, null when [json] is not usable.
  static ExchangePage? fromJson(Map<String, dynamic>? json) {
    if (!apiInstalled(json) || json!['items'] is! List) return null;
    final q = json['query'];
    return ExchangePage(
      items: [
        for (final t in _list(json['items']))
          if (_int(t['id']) > 0)
            ExchangeTitle(
              id: _int(t['id']),
              name: _str(t['name']),
              description: _str(t['description']),
              imageUrl: apiImageUrl(t['image']),
              medals: [
                for (final m in _list(t['medals']))
                  ExchangeMedal(
                    id: _int(m['id']),
                    name: _str(m['name']),
                    imageUrl: apiImageUrl(m['image']),
                    owned: m['owned'] == 1,
                  ),
              ],
              ready: t['ready'] == 1,
              consume: t['consume'] == 1,
              owned: t['owned'] == 1,
            ),
      ],
      filters: _filters(json['filters']),
      filter: q is Map ? _str(q['filter']) : 'all',
      paging: _paging(q),
      form: ApiForm.parse(json['exchange_form'], plugin: 'tsdmtitle:tsdmtitle', action: 'exchange'),
    );
  }

  /// Titles of this page.
  final List<ExchangeTitle> items;

  /// Filters with counts.
  final List<ApiFilter> filters;

  /// Current filter.
  final String filter;

  /// Paging.
  final ApiPaging paging;

  /// The exchange form (`exchangeid`), null when the answer has none usable.
  final ApiForm? form;
}

// ---------------------------------------------------------------- my medals

/// A medal of the account, in the order they show in posts.
final class MyMedal {
  /// Constructor.
  const MyMedal({required this.id, required this.name, required this.hidden, required this.expiration, this.imageUrl});

  /// Medal id.
  final int id;

  /// Name.
  final String name;

  /// Image.
  final String? imageUrl;

  /// Hidden from posts.
  final bool hidden;

  /// Expiration time (seconds), 0 when permanent.
  final int expiration;
}

/// A line of the medal record.
final class MedalLogEntry {
  /// Constructor.
  const MedalLogEntry({
    required this.id,
    required this.medalId,
    required this.name,
    required this.kind,
    required this.dateline,
    this.imageUrl,
  });

  /// Record id.
  final int id;

  /// Medal id.
  final int medalId;

  /// Medal name.
  final String name;

  /// Image.
  final String? imageUrl;

  /// grant／claim／pending／denied／exchanged／bought／sign／revoked／other.
  final String kind;

  /// Time (seconds).
  final int dateline;
}

/// My medals and the medal record.
final class MyMedalsData {
  /// Constructor.
  const MyMedalsData({
    required this.medals,
    required this.log,
    required this.logPaging,
    required this.previewLimit,
    required this.hideWarning,
    this.hideForm,
  });

  /// The answer of `mymedals`, null when [json] is not usable.
  static MyMedalsData? fromJson(Map<String, dynamic>? json) {
    if (!apiInstalled(json) || json!['medals'] is! List) return null;
    final log = json['log'];
    return MyMedalsData(
      medals: [
        for (final m in _list(json['medals']))
          if (_int(m['id']) > 0)
            MyMedal(
              id: _int(m['id']),
              name: _str(m['name']),
              imageUrl: apiImageUrl(m['image']),
              hidden: m['hidden'] == 1,
              expiration: _int(m['expiration']),
            ),
      ],
      log: [
        for (final l in _list(log is Map ? log['items'] : null))
          MedalLogEntry(
            id: _int(l['id']),
            medalId: _int(l['medalid']),
            name: _str(l['name']),
            imageUrl: apiImageUrl(l['image']),
            kind: _str(l['kind']),
            dateline: _int(l['dateline']),
          ),
      ],
      logPaging: _paging(log),
      previewLimit: json['preview_limit'] is num ? _int(json['preview_limit']) : null,
      hideWarning: _str(json['hide_warning']),
      hideForm: ApiForm.parse(json['hide_form'], plugin: 'dsu_medalCenter:memcp', action: 'sethide'),
    );
  }

  /// Medals in post order.
  final List<MyMedal> medals;

  /// A page of the record.
  final List<MedalLogEntry> log;

  /// Paging of the record.
  final ApiPaging logPaging;

  /// How many medals posts show at most (0: all), null when the plugin does not tell.
  final int? previewLimit;

  /// The warning shown before hiding medals.
  final String hideWarning;

  /// The hide form: `myMedalHide[id]` = 1 hide, 2 show.
  final ApiForm? hideForm;
}

// ---------------------------------------------------------------- send medals

/// A medal that can be sent.
final class GrantMedal {
  /// Constructor.
  const GrantMedal({required this.id, required this.name, required this.days, this.imageUrl});

  /// Medal id.
  final int id;

  /// Name.
  final String name;

  /// Image.
  final String? imageUrl;

  /// Days it lasts, 0 when permanent.
  final int days;
}

/// One medal sent to one member.
final class GrantRow {
  /// Constructor.
  const GrantRow({
    required this.id,
    required this.uid,
    required this.username,
    required this.medalId,
    required this.medalName,
    required this.expiration,
    required this.revoked,
    required this.revokeName,
    required this.revokeTime,
    required this.canRevoke,
    this.imageUrl,
  });

  /// Record id.
  final int id;

  /// Member.
  final int uid;

  /// Member name.
  final String username;

  /// Medal id.
  final int medalId;

  /// Medal name.
  final String medalName;

  /// Medal image.
  final String? imageUrl;

  /// Expiration (seconds), 0 permanent.
  final int expiration;

  /// Taken back.
  final bool revoked;

  /// Who took it back.
  final String revokeName;

  /// When (seconds).
  final int revokeTime;

  /// This account may take it back now.
  final bool canRevoke;
}

/// One sending: what one submit gave.
final class GrantBatch {
  /// Constructor.
  const GrantBatch({
    required this.batch,
    required this.dateline,
    required this.opName,
    required this.reason,
    required this.users,
    required this.medals,
    required this.count,
    required this.revoked,
    required this.canRevoke,
    required this.rows,
  });

  /// Batch id.
  final int batch;

  /// Time (seconds).
  final int dateline;

  /// Sender name.
  final String opName;

  /// Reason given, may be empty.
  final String reason;

  /// Members.
  final int users;

  /// Medals.
  final int medals;

  /// Records.
  final int count;

  /// Records taken back.
  final int revoked;

  /// Records this account may take back now.
  final int canRevoke;

  /// The records.
  final List<GrantRow> rows;
}

/// The send medals page.
final class GrantInfo {
  /// Constructor.
  const GrantInfo({
    required this.canGrant,
    required this.supported,
    required this.medals,
    required this.batches,
    required this.paging,
    required this.maxUsers,
    required this.maxMedals,
    required this.maxPairs,
    required this.maxReason,
    required this.revokeWindow,
    required this.canRevokeAll,
    this.grantForm,
    this.revokeForm,
    this.revokeBatchForm,
    this.lookupUrl,
    this.threadUrl,
  });

  /// The answer of `medalgrant`, null when [json] is not usable.
  static GrantInfo? fromJson(Map<String, dynamic>? json) {
    if (!apiInstalled(json)) return null;
    final records = json!['records'];
    final limits = json['limits'];
    String? json2url(Object? v, String action) {
      final uri = Uri.parse('$baseUrl/').resolve(_str(v));
      return _str(v).isNotEmpty &&
              uri.origin == Uri.parse(baseUrl).origin &&
              uri.path == '/plugin.php' &&
              uri.queryParameters['id'] == 'dsu_medalCenter:memcp' &&
              uri.queryParameters['action'] == action
          ? uri.toString()
          : null;
    }

    const plugin = 'dsu_medalCenter:memcp';
    return GrantInfo(
      canGrant: json['can_grant'] == 1,
      supported: json['supported'] == 1,
      medals: [
        for (final m in _list(json['medals']))
          if (_int(m['id']) > 0)
            GrantMedal(
              id: _int(m['id']),
              name: _str(m['name']),
              imageUrl: apiImageUrl(m['image']),
              days: _int(m['expiration_days']),
            ),
      ],
      batches: [
        for (final b in _list(records is Map ? records['batches'] : null))
          GrantBatch(
            batch: _int(b['batch']),
            dateline: _int(b['dateline']),
            opName: _str(b['opname']),
            reason: _str(b['reason']),
            users: _int(b['users']),
            medals: _int(b['medals']),
            count: _int(b['count']),
            revoked: _int(b['revoked']),
            canRevoke: _int(b['can_revoke']),
            rows: [
              for (final r in _list(b['items']))
                GrantRow(
                  id: _int(r['id']),
                  uid: _int(r['uid']),
                  username: _str(r['username']),
                  medalId: _int(r['medalid']),
                  medalName: _str(r['name']),
                  imageUrl: apiImageUrl(r['image']),
                  expiration: _int(r['expiration']),
                  revoked: r['revoked'] == 1,
                  revokeName: _str(r['revoke_name']),
                  revokeTime: _int(r['revoke_time']),
                  canRevoke: r['can_revoke'] == 1,
                ),
            ],
          ),
      ],
      paging: _paging(records),
      maxUsers: limits is Map ? _int(limits['users']) : 200,
      maxMedals: limits is Map ? _int(limits['medals']) : 50,
      maxPairs: limits is Map ? _int(limits['pairs']) : 1000,
      maxReason: limits is Map ? _int(limits['reason']) : 100,
      revokeWindow: _int(json['revoke_window']),
      canRevokeAll: json['can_revoke_all'] == 1,
      grantForm: ApiForm.parse(json['grant_form'], plugin: plugin, action: 'grantgrid'),
      revokeForm: ApiForm.parse(json['revoke_form'], plugin: plugin, action: 'grantrevoke'),
      revokeBatchForm: ApiForm.parse(json['revoke_batch_form'], plugin: plugin, action: 'grantrevokebatch'),
      lookupUrl: json2url(json['lookup_url'], 'grantlookup'),
      threadUrl: json2url(json['thread_url'], 'grantthread'),
    );
  }

  /// The account is on the sending list.
  final bool canGrant;

  /// The medal centre is new enough (3.2, updated); otherwise only the website sends.
  final bool supported;

  /// Medals that can be sent.
  final List<GrantMedal> medals;

  /// Sendings, newest first.
  final List<GrantBatch> batches;

  /// Paging of [batches].
  final ApiPaging paging;

  /// Members at most per sending.
  final int maxUsers;

  /// Medals at most per sending.
  final int maxMedals;

  /// Members × medals at most.
  final int maxPairs;

  /// Characters of the reason at most.
  final int maxReason;

  /// Seconds a sender may take back their sending.
  final int revokeWindow;

  /// The account may take back any sending (administrator).
  final bool canRevokeAll;

  /// The sending form (`grant_users`, `grant_medalids`, `grant_reason`; checked already).
  final ApiForm? grantForm;

  /// Take back one record (`logid`).
  final ApiForm? revokeForm;

  /// Take back a sending (`batch`).
  final ApiForm? revokeBatchForm;

  /// The medal centre's lookup of members (`uids`, `mids`).
  final String? lookupUrl;

  /// The medal centre's import of a thread's repliers (`tid`, `from`, `to`, `noowner`).
  final String? threadUrl;
}

/// A member found by the lookup, with the chosen medals they have.
typedef GrantPerson = ({int uid, String name, String? avatar, Set<int> has});

/// The answer of the lookup: members found and the UIDs not found.
({List<GrantPerson> users, List<String> missing})? grantLookupFromJson(Object? json) {
  if (json is! Map || json['ok'] != 1) return null;
  return (
    users: [
      for (final u in _list(json['users']))
        if (_int(u['uid']) > 0)
          (
            uid: _int(u['uid']),
            name: _str(u['name']),
            avatar: apiImageUrl(u['avatar']),
            has: {for (final m in (u['has'] as List? ?? const [])) _int(m)},
          ),
    ],
    missing: [for (final m in (json['missing'] as List? ?? const [])) _str(m)],
  );
}

/// The member UIDs written in [text]: separated by spaces, new lines, commas, 、 or semicolons (full-width digits and
/// separators too, as the medal centre reads them); the tokens that are not UIDs are given apart.
({List<int> uids, List<String> bad}) splitUids(String text) {
  final half = text.replaceAllMapped(RegExp('[０-９]'), (m) => String.fromCharCode(m[0]!.codeUnitAt(0) - 0xFEE0));
  final uids = <int>[];
  final bad = <String>[];
  for (final t in half.split(RegExp(r'[\s,，、;；]+'))) {
    if (t.isEmpty) continue;
    final n = RegExp(r'^\d{1,10}$').hasMatch(t) ? int.tryParse(t) : null;
    if (n != null && n > 0) {
      if (!uids.contains(n)) uids.add(n);
    } else if (!bad.contains(t)) {
      bad.add(t);
    }
  }
  return (uids: uids, bad: bad);
}

// ---------------------------------------------------------------- issue titles

/// A title that can be issued.
final class IssueTitle {
  /// Constructor.
  const IssueTitle({required this.id, required this.name, required this.enabled, this.imageUrl});

  /// Title id.
  final int id;

  /// Name.
  final String name;

  /// Image.
  final String? imageUrl;

  /// On sale／shown (disabled ones can be issued too, for events).
  final bool enabled;
}

/// A line of the issue record.
final class IssueLogEntry {
  /// Constructor.
  const IssueLogEntry({
    required this.dateline,
    required this.grant,
    required this.by,
    required this.to,
    required this.toUid,
    required this.title,
    required this.days,
    required this.note,
  });

  /// Time (seconds).
  final int dateline;

  /// Given (else taken back).
  final bool grant;

  /// Who.
  final String by;

  /// To whom.
  final String to;

  /// Their UID.
  final int toUid;

  /// Title name.
  final String title;

  /// Days given, 0 permanent.
  final int days;

  /// Note.
  final String note;
}

/// The issue titles page.
final class IssueInfo {
  /// Constructor.
  const IssueInfo({
    required this.canIssue,
    required this.supported,
    required this.titles,
    required this.logs,
    required this.maxUsers,
    required this.maxTitles,
    required this.maxDays,
    required this.maxNote,
    this.form,
  });

  /// The answer of `titleissue`, null when [json] is not usable.
  static IssueInfo? fromJson(Map<String, dynamic>? json) {
    if (!apiInstalled(json)) return null;
    final limits = json!['limits'];
    return IssueInfo(
      canIssue: json['can_issue'] == 1,
      supported: json['supported'] == 1,
      titles: [
        for (final t in _list(json['titles']))
          if (_int(t['id']) > 0)
            IssueTitle(
              id: _int(t['id']),
              name: _str(t['name']),
              imageUrl: apiImageUrl(t['image']),
              enabled: t['enabled'] == 1,
            ),
      ],
      logs: [
        for (final l in _list(json['logs']))
          IssueLogEntry(
            dateline: _int(l['dateline']),
            grant: l['op'] == 'grant',
            by: _str(l['by']),
            to: _str(l['to']),
            toUid: _int(l['touid']),
            title: _str(l['title']),
            days: _int(l['days']),
            note: _str(l['note']),
          ),
      ],
      maxUsers: limits is Map ? _int(limits['users']) : 200,
      maxTitles: limits is Map ? _int(limits['titles']) : 30,
      maxDays: limits is Map ? _int(limits['days']) : 36500,
      maxNote: limits is Map ? _int(limits['note']) : 80,
      form: ApiForm.parse(json['issue_form'], plugin: 'tsdmtitle:tsdmtitle', action: 'issue'),
    );
  }

  /// The account may issue titles.
  final bool canIssue;

  /// The title plugin is new enough (6.2).
  final bool supported;

  /// Titles, newest first, disabled ones included.
  final List<IssueTitle> titles;

  /// The latest issues.
  final List<IssueLogEntry> logs;

  /// Members at most.
  final int maxUsers;

  /// Titles at most.
  final int maxTitles;

  /// Days at most.
  final int maxDays;

  /// Characters of the note at most.
  final int maxNote;

  /// The form: `issueop` grant／revoke, `issuetitles`, `issueusers`, `issuedays`, `issuenote`.
  final ApiForm? form;
}
