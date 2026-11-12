import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

/// Handling the reports of members (舉報處理). The list and its handling are the same whichever way the forum serves
/// them (`ReportSource`): the moderation panel's report page of one forum (`modcp_report`, plugin 3.9.0, `schema` 28)
/// now; the admin API's list of the whole forum (`adminreport`, `schema` 29) shares the item, the reward and the page.

String _str(Object? v) => v == null ? '' : '$v';
List<Map<String, dynamic>> _list(Object? v) => v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];

/// A report waiting to be handled: one URL reported, by one member or several.
final class ReportItem {
  /// Constructor.
  const ReportItem({
    required this.id,
    required this.url,
    required this.tid,
    required this.pid,
    required this.fid,
    required this.forum,
    required this.lines,
    required this.uid,
    required this.username,
    required this.dateline,
    required this.count,
    this.excerpt = '',
  });

  /// Report id.
  final int id;

  /// What was reported (relative to the forum).
  final String url;

  /// The thread reported, 0 when not known.
  final int tid;

  /// The floor reported, 0 when not known.
  final int pid;

  /// The forum, 0 for none.
  final int fid;

  /// The forum's name.
  final String forum;

  /// The reports: `reporter : reason`, one a line.
  final List<String> lines;

  /// The first member who reported it: the one rewarded.
  final int uid;

  /// Their name.
  final String username;

  /// When (seconds).
  final int dateline;

  /// How many times it was reported.
  final int count;

  /// The beginning of the post reported (plain text), empty when not given.
  final String excerpt;

  /// The absolute URL of what was reported, null unless it is a page of this forum.
  String? get absoluteUrl {
    if (url.trim().isEmpty) {
      return null;
    }
    final uri = Uri.parse('$baseUrl/').resolve(url.trim());
    return uri.origin == Uri.parse(baseUrl).origin ? uri.toString() : null;
  }
}

/// The reward a reporter may be given.
final class ReportReward {
  /// Constructor.
  const ReportReward({
    required this.creditTitle,
    required this.unit,
    required this.min,
    required this.max,
    required this.options,
  });

  /// The `reward` of an answer, null when the forum sets none (`enabled` 0): no reward nor message then.
  static ReportReward? fromJson(Object? json) {
    if (json is! Map || json['enabled'] != 1) {
      return null;
    }
    final min = tsdmAppInt(json['min']);
    final max = tsdmAppInt(json['max']);
    if (min >= max) {
      return null;
    }
    final credit = json['credit'];
    final options = <int>[
      for (final o in json['options'] is List ? json['options'] as List : const <Object?>[])
        if (tsdmAppInt(o) >= min && tsdmAppInt(o) <= max) tsdmAppInt(o),
    ];
    return ReportReward(
      creditTitle: credit is Map ? _str(credit['title']) : '',
      unit: credit is Map ? _str(credit['unit']) : '',
      min: min,
      max: max,
      options: {
        ...(options.isEmpty ? _steps(min, max) : options),
        0,
      }.toList()..sort((a, b) => b.compareTo(a)),
    );
  }

  /// The credit's name.
  final String creditTitle;

  /// Its unit.
  final String unit;

  /// The least value taken.
  final int min;

  /// The greatest value taken.
  final int max;

  /// The values offered, greatest first, 0 (no reward) among them.
  final List<int> options;
}

/// The values from [max] down to [min] the way the forum's select steps them: about ten, never hundreds.
List<int> _steps(int min, int max) {
  final step = ((max - min) / 10).ceil().clamp(1, 1 << 30);
  return [for (var v = max; v >= min; v -= step) v];
}

/// One of the parts a source lists the reports by: a forum of the panel.
typedef ReportScope = ({String key, String label});

/// A page of reports of a source.
class ReportList {
  /// Constructor.
  const ReportList({
    required this.uid,
    required this.scopes,
    required this.scope,
    required this.scopeLabel,
    required this.needScope,
    required this.page,
    required this.pages,
    required this.count,
    required this.items,
    this.reward,
  });

  /// The account it was served to.
  final int uid;

  /// The parts the reports may be listed by.
  final List<ReportScope> scopes;

  /// The part listed, empty for none.
  final String scope;

  /// Its name.
  final String scopeLabel;

  /// A part must be chosen first: nothing is listed.
  final bool needScope;

  /// This page.
  final int page;

  /// Pages.
  final int pages;

  /// Reports in all.
  final int count;

  /// The reports of this page.
  final List<ReportItem> items;

  /// The reward, null when none can be given.
  final ReportReward? reward;

  /// Whether reports of this page can be handled.
  bool get canResolve => !needScope && items.isNotEmpty;
}

/// How one report is handled: the reporter's reward (0 none) and a message to them (empty none).
typedef ReportDecision = ({ReportItem item, int credit, String message});

/// The panel's report form as the answer describes it.
final class ModcpReportForm {
  /// Constructor.
  const ModcpReportForm({
    required this.url,
    required this.fields,
    required this.idsField,
    required this.uidField,
    required this.creditField,
    required this.msgField,
  });

  static final _listField = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*\[\]$');
  static final _keyed = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*\[\{id\}\]$');

  /// The `submit` of [json] for forum [fid]; null unless it posts to the panel's report page of that forum on this
  /// forum with field names of the shape the panel reads, so a tampered answer can never redirect a write.
  static ModcpReportForm? parse(Object? json, {required int fid}) {
    if (json is! Map) {
      return null;
    }
    final fields = json['fields'];
    final raw = _str(json['url']).trim();
    final uri = Uri.parse('$baseUrl/').resolve(raw);
    final q = uri.queryParameters;
    if (raw.isEmpty ||
        fields is! Map ||
        fid <= 0 ||
        uri.origin != Uri.parse(baseUrl).origin ||
        uri.path != '/forum.php' ||
        q['mod'] != 'modcp' ||
        q['action'] != 'report' ||
        q['fid'] != '$fid' ||
        q.keys.any((k) => !const {'mod', 'action', 'fid', 'lpp', 'page'}.contains(k)) ||
        !_listField.hasMatch(_str(json['ids_field'])) ||
        !_keyed.hasMatch(_str(json['uid_field'])) ||
        !_keyed.hasMatch(_str(json['credit_field'])) ||
        !_keyed.hasMatch(_str(json['msg_field']))) {
      return null;
    }
    final filled = [
      for (final f in [json['ids_field'], json['uid_field'], json['credit_field'], json['msg_field']])
        _str(f).substring(0, _str(f).indexOf('[') + 1),
    ];
    return ModcpReportForm(
      url: uri.toString(),
      // The fields the app fills are never taken from the fixed ones (a reward is sent only when chosen).
      fields: Map.unmodifiable({
        for (final e in fields.entries)
          if (!filled.any('${e.key}'.startsWith)) '${e.key}': '${e.value}',
      }),
      idsField: _str(json['ids_field']),
      uidField: _str(json['uid_field']),
      creditField: _str(json['credit_field']),
      msgField: _str(json['msg_field']),
    );
  }

  /// Absolute URL the form posts to.
  final String url;

  /// Fixed fields (form hash, submit flag).
  final Map<String, String> fields;

  /// The ids handled (`reportids[]`).
  final String idsField;

  /// Each one's reporter (`reportuids[{id}]`).
  final String uidField;

  /// Each one's reward (`creditsvalue[{id}]`).
  final String creditField;

  /// Each one's message to the reporter (`msg[{id}]`).
  final String msgField;

  /// The body handling [decisions]: the ids indexed (`reportids[0]`…, as PHP reads a list), each one's reporter as the
  /// list served it, and the reward and the message only when [withReward] (the forum sets a reward) and not empty.
  Map<String, String> body(List<ReportDecision> decisions, {required bool withReward}) {
    final list = idsField.substring(0, idsField.length - 2);
    String keyed(String field, int id) => field.replaceFirst('{id}', '$id');
    return {
      ...fields,
      for (final (i, d) in decisions.indexed) ...{
        '$list[$i]': '${d.item.id}',
        keyed(uidField, d.item.id): '${d.item.uid}',
        if (withReward && d.credit != 0) keyed(creditField, d.item.id): '${d.credit}',
        if (withReward && d.message.trim().isNotEmpty) keyed(msgField, d.item.id): d.message.trim(),
      },
    };
  }
}

/// A page of the panel's report page: one forum's reports and its form.
final class ModcpReportList extends ReportList {
  /// Constructor.
  const ModcpReportList({
    required super.uid,
    required super.scopes,
    required super.scope,
    required super.scopeLabel,
    required super.needScope,
    required super.page,
    required super.pages,
    required super.count,
    required super.items,
    required this.fid,
    super.reward,
    this.form,
  });

  /// The forum listed, 0 for none.
  final int fid;

  /// The form handling them, null when the answer has none usable.
  final ModcpReportForm? form;

  @override
  bool get canResolve => super.canResolve && form != null;
}

/// The panel's report page in the answer [json] (`type: modcp_report`, `schema` 28), null when it is not one.
ModcpReportList? modcpReportFromApi(Map<String, dynamic> json) {
  if (json['ok'] != 1 || json['type'] != 'modcp_report' || tsdmAppInt(json['schema']) < 28) {
    return null;
  }
  final fid = tsdmAppInt(json['fid']);
  final needForum = json['need_forum'] == 1 || fid <= 0;
  final page = tsdmAppInt(json['page']);
  final pages = tsdmAppInt(json['pages']);
  return ModcpReportList(
    uid: tsdmAppInt(json['uid']),
    fid: needForum ? 0 : fid,
    scopes: [
      for (final f in _list(json['forums']))
        if (tsdmAppInt(f['fid']) > 0) (key: '${tsdmAppInt(f['fid'])}', label: _str(f['name']).trim()),
    ],
    scope: needForum ? '' : '$fid',
    scopeLabel: needForum ? '' : _str(json['forum']).trim(),
    needScope: needForum,
    page: page < 1 ? 1 : page,
    pages: pages < 1 ? 1 : pages,
    count: tsdmAppInt(json['count']),
    reward: needForum ? null : ReportReward.fromJson(json['reward']),
    items: needForum
        ? const []
        : [
            for (final r in _list(json['reports']))
              if (tsdmAppInt(r['id']) > 0) reportItemFromApi(r),
          ],
    form: needForum ? null : ModcpReportForm.parse(json['submit'], fid: fid),
  );
}

/// A report of an answer's `reports[]` (the panel's and the admin API's share the fields).
ReportItem reportItemFromApi(Map<String, dynamic> r) => ReportItem(
  id: tsdmAppInt(r['id']),
  url: _str(r['url']),
  tid: tsdmAppInt(r['tid']),
  pid: tsdmAppInt(r['pid']),
  fid: tsdmAppInt(r['fid']),
  forum: _str(r['forum']).trim(),
  lines: _str(r['message']).split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
  uid: tsdmAppInt(r['uid']),
  username: _str(r['username']),
  dateline: tsdmAppInt(r['dateline']),
  count: tsdmAppInt(r['num']) < 1 ? 1 : tsdmAppInt(r['num']),
  excerpt: _str(r['excerpt']).trim(),
);

/// The answer of a source to a list asked.
sealed class ReportAnswer {
  const ReportAnswer();
}

/// The list.
final class ReportReady extends ReportAnswer {
  /// Constructor.
  const ReportReady(this.list);

  /// The list.
  final ReportList list;
}

/// The source asks a login first (the panel's password): [token] is what the source's login needs (the form hash of
/// the panel's login form).
final class ReportNeedsLogin extends ReportAnswer {
  /// Constructor.
  const ReportNeedsLogin(this.token);

  /// What the login needs.
  final String token;
}

/// The forum refused, in its own words.
final class ReportRefused extends ReportAnswer {
  /// Constructor.
  const ReportRefused(this.message);

  /// The forum's message, may be empty.
  final String message;
}

/// What became of reports sent to be handled.
sealed class ReportOutcome {
  const ReportOutcome();
}

/// Handled, the forum says.
final class ReportDone extends ReportOutcome {
  /// Constructor.
  const ReportDone(this.message);

  /// The forum's message.
  final String message;
}

/// Not handled, or stopped part way (the reports before it were handled): the forum's message.
final class ReportNotDone extends ReportOutcome {
  /// Constructor.
  const ReportNotDone(this.message);

  /// The forum's message, may be empty.
  final String message;
}

/// The login ended: nothing was done.
final class ReportSessionEnded extends ReportOutcome {
  /// Constructor.
  const ReportSessionEnded();
}

/// Sent, but the answer does not tell what was done.
final class ReportUnknown extends ReportOutcome {
  /// Constructor.
  const ReportUnknown();
}
