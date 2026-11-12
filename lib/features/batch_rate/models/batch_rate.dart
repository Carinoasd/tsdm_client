import 'package:flutter/foundation.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

/// Rating many floors at once through the forum's batch rate plugin (`batchrate`, 1.3.0 and later), as the forum's app
/// API describes it (tsdmapp 3.9.0, second round, schemas 32 to 35). The rating and the taking back are the plugin's
/// own pages, posted as the answers describe them; the plugin checks the form hash, the moderator, the rating
/// permission and the quota itself.

int _int(Object? v) => tsdmAppInt(v);

String _str(Object? v) => switch (v) {
  final String s => s,
  final num n => '$n',
  _ => '',
};

bool _on(Object? v) => v == 1 || v == true || v == '1';

int? _intOrNull(Object? v) => v == null ? null : _int(v);

List<Map<String, dynamic>> _maps(Object? v) => v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];

Map<String, dynamic> _map(Object? v) => v is Map<String, dynamic> ? v : const {};

/// How the floors are picked (`brmode`).
enum BatchRateMode {
  /// The first floor of each thread picked in a forum's list (`tids`).
  list(1),

  /// Floors of a thread picked one by one (`tid`, `pids`).
  check(2),

  /// Floors of a thread by number (`tid`, `floors`).
  range(3)
  ;

  const BatchRateMode(this.value);

  /// The `brmode` sent.
  final int value;

  /// The mode of [value]; null for any other.
  static BatchRateMode? of(Object? value) => values.where((m) => m.value == _int(value)).firstOrNull;
}

/// A form of the batch rate plugin: where it posts (absolute) and its fixed fields.
@immutable
final class BatchRateForm {
  /// Constructor.
  const BatchRateForm({required this.url, required this.fields});

  /// The plugin pages a form or a link may go to.
  static const _pages = {'batchrate:rate', 'batchrate:run', 'batchrate:list'};

  /// The parameters a form or a link may carry besides `id`.
  static const _keys = {'bract', 'brmode', 'batchid', 'page'};

  /// The absolute url of [raw], a link of an answer, null when it goes anywhere but the plugin's pages on this forum:
  /// a tampered answer never sends a write elsewhere.
  static String? urlOf(Object? raw) {
    final text = _str(raw);
    if (text.isEmpty) {
      return null;
    }
    final Uri uri;
    try {
      uri = Uri.parse('$baseUrl/').resolve(text);
    } on FormatException {
      return null;
    }
    if (uri.origin != Uri.parse(baseUrl).origin ||
        uri.path != '/plugin.php' ||
        !_pages.contains(uri.queryParameters['id']) ||
        uri.queryParameters.keys.any((k) => k != 'id' && !_keys.contains(k))) {
      return null;
    }
    return uri.toString();
  }

  /// The form of [json] (`url`, `fields`), null when it posts anywhere else or has no fields.
  static BatchRateForm? parse(Object? json) {
    if (json is! Map) {
      return null;
    }
    final url = urlOf(json['url']);
    final fields = json['fields'];
    if (url == null || fields is! Map) {
      return null;
    }
    return BatchRateForm(
      url: url,
      fields: Map.unmodifiable({for (final e in fields.entries) '${e.key}': _str(e.value)}),
    );
  }

  /// Absolute url the form posts to.
  final String url;

  /// The fields sent as they are (the form hash; the picking of a confirmation).
  final Map<String, String> fields;

  /// The body with [extra] fields.
  Map<String, String> body(Map<String, String> extra) => {...fields, ...extra};
}

/// A credit that may be rated in a forum.
@immutable
final class BatchRateCredit {
  /// Constructor.
  const BatchRateCredit({
    required this.id,
    required this.title,
    required this.unit,
    required this.min,
    required this.max,
    this.daily = 0,
    this.left,
    this.score = 0,
    this.cond = '',
  });

  factory BatchRateCredit._of(Map<String, dynamic> m) => BatchRateCredit(
    id: _int(m['id']),
    title: _str(m['title']),
    unit: _str(m['unit']),
    min: _int(m['min']),
    max: _int(m['max']),
    daily: _int(m['daily']),
    left: _intOrNull(m['left']),
    score: _int(m['score']),
    cond: _str(m['cond']),
  );

  /// `extcredits` id.
  final int id;

  /// Name, as served.
  final String title;

  /// Unit, as served.
  final String unit;

  /// Lowest and highest score of one floor.
  final int min;

  /// See [min].
  final int max;

  /// What may be rated in 24 hours, 0 for no limit (the entry answer).
  final int daily;

  /// What is left of [daily], null for no limit.
  final int? left;

  /// The score set (the confirmation).
  final int score;

  /// The threshold set (the confirmation), empty for none.
  final String cond;
}

/// The quota of a credit for the scores set: `need` used, `left` left (null for no limit).
typedef BatchRateQuota = ({int id, String title, int need, int? left, bool ok});

/// The two anti-flood switches of a thread's floors: skip who was rated in the thread already (`rated`), rate one
/// person once in the batch (`same`); `locked` by the forum (always on).
typedef BatchRateAntispam = ({bool locked, bool rated, bool same});

/// What the forum's app API tells about rating in batches (`action=batchrate`, schema 32).
@immutable
final class BatchRateInfo {
  /// Constructor.
  const BatchRateInfo({
    required this.uid,
    required this.version,
    required this.formHash,
    required this.installed,
    required this.supported,
    required this.canList,
    required this.maxTotal,
    required this.chunk,
    required this.multMax,
    required this.floorSegments,
    required this.fid,
    required this.forum,
    required this.can,
    required this.why,
    required this.entryList,
    required this.entryThread,
    required this.credits,
    required this.reasonRequired,
    required this.notifyForced,
    required this.reasonChoices,
    required this.antispam,
    required this.threadTid,
    required this.threadAuthor,
    required this.confirmUrl,
    required this.listUrl,
  });

  /// The info of an answer [json]; null when it is not one.
  static BatchRateInfo? fromJson(Map<String, dynamic>? json) {
    if (json == null || json['ok'] != 1 || json['type'] != 'batchrate') {
      return null;
    }
    final limits = _map(json['limits']);
    final entry = _map(json['entry']);
    final reason = _map(json['reason']);
    final antispam = _map(json['antispam']);
    final thread = _map(json['thread']);
    final forms = _map(json['forms']);
    return BatchRateInfo(
      uid: _int(json['uid']),
      // `batchrate_version` (3.9.0 third round) does not clash with the `version` of the other answers.
      version: _str(json['batchrate_version']).isNotEmpty ? _str(json['batchrate_version']) : _str(json['version']),
      formHash: _str(json['formhash']),
      installed: _on(json['installed']),
      supported: _on(json['supported']),
      canList: _on(json['can_list']),
      maxTotal: _int(limits['max_total']),
      chunk: _int(limits['chunk']),
      multMax: limits.containsKey('mult_max') ? _int(limits['mult_max']) : 99,
      floorSegments: limits.containsKey('floor_segments') ? _int(limits['floor_segments']) : 50,
      fid: _int(json['fid']),
      forum: _str(json['forum']),
      can: _on(json['can']),
      why: _str(json['why']),
      entryList: _on(entry['list']),
      entryThread: _on(entry['thread']),
      credits: [for (final c in _maps(json['credits'])) BatchRateCredit._of(c)],
      reasonRequired: _on(reason['required']),
      notifyForced: _on(reason['notify_forced']),
      reasonChoices: [
        for (final c in reason['choices'] is List ? reason['choices'] as List : const []) _str(c),
      ].where((c) => c.isNotEmpty).toList(),
      antispam: (locked: _on(antispam['locked']), rated: _on(antispam['rated']), same: _on(antispam['same'])),
      threadTid: _int(thread['tid']),
      threadAuthor: _str(thread['author']),
      confirmUrl: BatchRateForm.urlOf(_map(forms['confirm'])['url']),
      listUrl: BatchRateForm.urlOf(forms['list_url']),
    );
  }

  /// The account the answer is for.
  final int uid;

  /// The batch rate plugin's version (`batchrate_version`), empty when the plugin is not there.
  final String version;

  /// The form hash of the session.
  final String formHash;

  /// The plugin is on.
  final bool installed;

  /// The plugin is new enough.
  final bool supported;

  /// The account may read the batches.
  final bool canList;

  /// Most floors rated in one batch.
  final int maxTotal;

  /// Floors rated in one run.
  final int chunk;

  /// Highest multiple of a floor.
  final int multMax;

  /// Most segments of floor numbers.
  final int floorSegments;

  /// The forum asked about, 0 when none.
  final int fid;

  /// Its name, as served.
  final String forum;

  /// The account may rate in batches in [fid].
  final bool can;

  /// Why not: `fid`, `norate`, `notmod`; empty when [can].
  final String why;

  /// The forum offers the entry in its forum lists.
  final bool entryList;

  /// The forum offers the entry in its threads.
  final bool entryThread;

  /// The credits that may be rated, with the quota left.
  final List<BatchRateCredit> credits;

  /// A reason must be given.
  final bool reasonRequired;

  /// The authors are always notified.
  final bool notifyForced;

  /// The forum's reasons to pick from.
  final List<String> reasonChoices;

  /// The anti-flood switches as they start.
  final BatchRateAntispam antispam;

  /// The thread asked about (in [fid]), 0 when none.
  final int threadTid;

  /// Its author's name, empty when none.
  final String threadAuthor;

  /// Where the confirmation is posted, null when the answer named another place.
  final String? confirmUrl;

  /// The batches' page, null when the answer named another place.
  final String? listUrl;

  /// The plugin is there and new enough.
  bool get usable => installed && supported;

  /// The entry in a forum's list of threads.
  bool get offersList => usable && can && entryList && confirmUrl != null;

  /// The entry in a thread.
  bool get offersThread => usable && can && entryThread && confirmUrl != null;

  /// The batches' page.
  bool get offersBatches => usable && canList && listUrl != null;
}

/// The floors picked: the first request of a confirmation.
@immutable
final class BatchRateSelection {
  /// The first floor of each of [tids] in forum [fid].
  const BatchRateSelection.threads({required this.fid, required this.tids})
    : mode = BatchRateMode.list,
      tid = 0,
      pids = const [],
      floors = '';

  /// Floors [pids] of thread [tid] in forum [fid].
  const BatchRateSelection.posts({required this.fid, required this.tid, required this.pids})
    : mode = BatchRateMode.check,
      tids = const [],
      floors = '';

  /// Floors numbered [floors] (as [parseBatchRateFloors] wrote them) of thread [tid] in forum [fid].
  const BatchRateSelection.floors({required this.fid, required this.tid, required this.floors})
    : mode = BatchRateMode.range,
      tids = const [],
      pids = const [];

  /// How the floors are picked.
  final BatchRateMode mode;

  /// The forum.
  final int fid;

  /// The thread, 0 for [BatchRateMode.list].
  final int tid;

  /// The threads of [BatchRateMode.list].
  final List<int> tids;

  /// The floors of [BatchRateMode.check].
  final List<int> pids;

  /// The floor numbers of [BatchRateMode.range].
  final String floors;

  /// The fields of the first request (the confirmation with the forum's defaults).
  Map<String, String> get fields => {
    'brmode': '${mode.value}',
    'fid': '$fid',
    if (mode != BatchRateMode.list) 'tid': '$tid',
    if (mode == BatchRateMode.list) 'tids': tids.join(','),
    if (mode == BatchRateMode.check) 'pids': pids.join(','),
    if (mode == BatchRateMode.range) 'floors': floors,
  };
}

/// The floor numbers [raw] as the plugin reads them (`3~5 10 15~20`, `30~` to the last; blanks, commas, `、` and `;`
/// apart; `~`, `～`, `-` between), sorted and written the plugin's way; null when it can not read them or there are
/// more than [maxSegments] segments.
String? parseBatchRateFloors(String raw, {int maxSegments = 50}) {
  var text = raw.trim();
  for (final dash in ['～', '－', '—', '至', '〜']) {
    text = text.replaceAll(dash, '~');
  }
  text = text.replaceAll(RegExp(r'\s*~\s*'), '~').replaceAll(RegExp(r'\s*-\s*'), '~');
  final parts = text.split(RegExp(r'[\s,，、;；]+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) {
    return null;
  }
  final ranges = <(int, int)>[];
  for (final p in parts) {
    final int from;
    final int to;
    if (RegExp(r'^(\d{1,7})$').firstMatch(p) case final m?) {
      from = int.parse(m[1]!);
      to = from;
    } else if (RegExp(r'^(\d{1,7})~(\d{0,7})$').firstMatch(p) case final m?) {
      from = int.parse(m[1]!);
      to = m[2]!.isEmpty ? 0 : int.parse(m[2]!);
    } else {
      return null;
    }
    if (from < 1 || (to != 0 && to < from)) {
      return null;
    }
    ranges.add((from, to));
  }
  if (ranges.length > maxSegments) {
    return null;
  }
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (a, b) in ranges) b == 0 ? '$a~' : (a == b ? '$a' : '$a~$b')].join(' ');
}

/// A floor of a confirmation or a batch.
@immutable
final class BatchRateItem {
  /// Constructor.
  const BatchRateItem({
    required this.itemId,
    required this.tid,
    required this.pid,
    required this.position,
    required this.subject,
    required this.authorId,
    required this.author,
    required this.status,
    required this.statusText,
    required this.mult,
    this.canUndo = false,
  });

  factory BatchRateItem._of(Map<String, dynamic> m) => BatchRateItem(
    itemId: _int(m['itemid']),
    tid: _int(m['tid']),
    pid: _int(m['pid']),
    position: _int(m['position']),
    subject: _str(m['subject']),
    authorId: _int(m['authorid']),
    author: _str(m['author']),
    status: _str(m['status']),
    statusText: _str(m['status_text']),
    mult: _int(m['mult']) < 1 ? 1 : _int(m['mult']),
    canUndo: _on(m['can_undo']),
  );

  /// The batch's item, 0 in a confirmation.
  final int itemId;

  /// Thread.
  final int tid;

  /// Floor.
  final int pid;

  /// Floor number.
  final int position;

  /// The thread's title (the list mode), empty otherwise.
  final String subject;

  /// Author.
  final int authorId;

  /// Author's name.
  final String author;

  /// `pending`, `applied`, `undone`, `skip_*`…
  final String status;

  /// What the plugin says of [status], as served.
  final String statusText;

  /// The multiple of the score.
  final int mult;

  /// This floor's rate may be taken back.
  final bool canUndo;

  /// The floor is rated (a confirmation) or waits to be (a batch).
  bool get pending => status == 'pending' || status == 'running';

  /// The floor is skipped.
  bool get skipped => status.startsWith('skip_');
}

/// Either answer of a posted confirmation: the confirmation again ([BatchRateConfirm]) or the batch made
/// ([BatchRateBatchPage]).
sealed class BatchRatePosted {
  const BatchRatePosted();
}

/// The confirmation (schema 33): what would be rated and skipped with the settings sent.
final class BatchRateConfirm extends BatchRatePosted {
  /// Constructor.
  const BatchRateConfirm({
    required this.uid,
    required this.formHash,
    required this.mode,
    required this.fid,
    required this.forum,
    required this.tid,
    required this.floors,
    required this.total,
    required this.apply,
    required this.multSum,
    required this.chunks,
    required this.credits,
    required this.quota,
    required this.reason,
    required this.reasonRequired,
    required this.notify,
    required this.notifyForced,
    required this.antispam,
    required this.ratedOverridden,
    required this.exclude,
    required this.errors,
    required this.blocked,
    required this.items,
    required this.submit,
    required this.fieldNames,
    this.precheck,
    this.condCredits,
  });

  /// The confirmation of an answer [json]; null when it is not one or its form posts elsewhere.
  static BatchRateConfirm? fromJson(Map<String, dynamic>? json) {
    if (json == null || json['ok'] != 1 || json['type'] != 'batchrate_confirm') {
      return null;
    }
    final mode = BatchRateMode.of(json['mode']);
    final submit = BatchRateForm.parse(json['submit']);
    if (mode == null || submit == null) {
      return null;
    }
    final names = _map(json['submit']);
    String name(String key, String fallback) => _str(names[key]).isEmpty ? fallback : _str(names[key]);
    final reason = _map(json['reason']);
    final notify = _map(json['notify']);
    final antispam = _map(json['antispam']);
    return BatchRateConfirm(
      uid: _int(json['uid']),
      formHash: _str(json['formhash']),
      mode: mode,
      fid: _int(json['fid']),
      forum: _str(json['forum']),
      tid: _int(json['tid']),
      floors: _str(json['floors']),
      total: _int(json['total']),
      apply: _int(json['apply']),
      multSum: _int(json['multsum']),
      chunks: _int(json['chunks']),
      credits: [for (final c in _maps(json['credits'])) BatchRateCredit._of(c)],
      quota: [
        for (final q in _maps(json['quota']))
          (
            id: _int(q['id']),
            title: _str(q['title']),
            need: _int(q['need']),
            left: _intOrNull(q['left']),
            ok: _on(q['ok']),
          ),
      ],
      reason: _str(reason['value']),
      reasonRequired: _on(reason['required']),
      notify: _on(notify['checked']),
      notifyForced: _on(notify['forced']),
      antispam: (locked: _on(antispam['locked']), rated: _on(antispam['rated']), same: _on(antispam['same'])),
      ratedOverridden: _on(antispam['rated_overridden']),
      exclude: _str(json['exclude']),
      errors: [
        for (final e in json['errors'] is List ? json['errors'] as List : const []) _str(e),
      ].where((e) => e.isNotEmpty).toList(),
      blocked: _on(json['blocked']),
      items: [for (final i in _maps(json['items'])) BatchRateItem._of(i)],
      submit: submit,
      fieldNames: (
        recalc: name('recalc_field', 'recalc'),
        submit: name('submit_field', 'ratesubmit'),
        score: name('score_field', 'score{id}'),
        reason: name('reason_field', 'reason'),
        notify: name('notify_field', 'sendreasonpm'),
        exclude: name('exclude_field', 'exclude'),
        rated: name('rated_field', 'as_rated'),
        same: name('same_field', 'as_same'),
        cond: name('cond_field', 'cond[{id}]'),
        mult: name('mult_field', 'mult[{pid}]'),
        floors: name('floors_field', 'floors'),
      ),
      precheck: switch (json['precheck']) {
        final Map<String, dynamic> p => (
          ok: _on(p['ok']),
          errors: [
            for (final e in _maps(p['errors'])) (code: _str(e['code']), id: _int(e['id']), message: _str(e['message'])),
          ],
        ),
        _ => null,
      },
      condCredits: json['cond_credits'] is List
          ? [
              for (final c in _maps(json['cond_credits']))
                (id: _int(c['id']), title: _str(c['title']), cond: _str(c['cond'])),
            ]
          : null,
    );
  }

  /// The account the answer is for.
  final int uid;

  /// The form hash of the session.
  final String formHash;

  /// How the floors were picked.
  final BatchRateMode mode;

  /// Forum.
  final int fid;

  /// Its name, as served.
  final String forum;

  /// Thread, 0 for the list mode.
  final int tid;

  /// The floor numbers of the range mode.
  final String floors;

  /// Floors picked.
  final int total;

  /// Floors rated.
  final int apply;

  /// The sum of the multiples of the floors rated (the quota is counted with it).
  final int multSum;

  /// Runs the batch takes.
  final int chunks;

  /// The credits with the scores and thresholds set.
  final List<BatchRateCredit> credits;

  /// The quota of the credits scored.
  final List<BatchRateQuota> quota;

  /// The reason set.
  final String reason;

  /// A reason must be given.
  final bool reasonRequired;

  /// The authors are notified.
  final bool notify;

  /// The authors are always notified.
  final bool notifyForced;

  /// The anti-flood switches set.
  final BatchRateAntispam antispam;

  /// A threshold is set: skipping who was rated in the thread already is not applied.
  final bool ratedOverridden;

  /// The names left out, as written.
  final String exclude;

  /// What the plugin tells (as served).
  final List<String> errors;

  /// Sending now would be refused.
  final bool blocked;

  /// The floors picked, rated or skipped.
  final List<BatchRateItem> items;

  /// The picking sent back with every request.
  final BatchRateForm submit;

  /// The field names of the settings.
  final BatchRateFieldNames fieldNames;

  /// What the plugin's checks of a sending say of these settings (`precheck`, 3.9.0 third round): sent only when
  /// `ok`; null for an older answer (the app's own checks then).
  final BatchRatePrecheck? precheck;

  /// The credits a threshold may be set for (`cond_credits`, every credit of the forum; 3.9.0 third round); null for an
  /// older answer.
  final List<({int id, String title, String cond})>? condCredits;

  /// The credits a threshold may be set for: [condCredits], or the credits rated for an older answer.
  List<({int id, String title, String cond})> get thresholds =>
      condCredits ?? [for (final c in credits) (id: c.id, title: c.title, cond: c.cond)];

  /// The floors of a thread (not the first floors of threads).
  bool get inThread => mode != BatchRateMode.list;
}

/// The field names of a confirmation's settings, with `{id}` and `{pid}` to fill in.
typedef BatchRateFieldNames = ({
  String recalc,
  String submit,
  String score,
  String reason,
  String notify,
  String exclude,
  String rated,
  String same,
  String cond,
  String mult,
  String floors,
});

/// The settings of a confirmation, as the page holds them while they are changed.
final class BatchRateSettings {
  /// Constructor.
  BatchRateSettings({
    required this.scores,
    required this.conds,
    required this.mults,
    required this.reason,
    required this.notify,
    required this.exclude,
    required this.rated,
    required this.same,
    required this.floors,
  });

  /// The settings a confirmation [c] was computed with: the forum's defaults the first time.
  factory BatchRateSettings.of(BatchRateConfirm c) => BatchRateSettings(
    scores: {for (final credit in c.credits) credit.id: credit.score},
    conds: {for (final t in c.thresholds) t.id: t.cond},
    mults: {for (final item in c.items) item.pid: item.mult},
    reason: c.reason,
    notify: c.notify || c.notifyForced,
    exclude: c.exclude,
    rated: c.antispam.rated,
    same: c.antispam.same,
    floors: c.floors,
  );

  /// Score of each credit; 0 rates none of it.
  final Map<int, int> scores;

  /// Threshold of each credit; empty for none.
  final Map<int, String> conds;

  /// Multiple of each floor (pid).
  final Map<int, int> mults;

  /// Reason.
  String reason;

  /// Notify the authors.
  bool notify;

  /// Names left out.
  String exclude;

  /// Skip who was rated in the thread already.
  bool rated;

  /// Rate one person once in the batch.
  bool same;

  /// The floor numbers (the range mode).
  String floors;

  /// The scores that rate something.
  Map<int, int> get scored => {
    for (final e in scores.entries)
      if (e.value != 0) e.key: e.value,
  };

  /// Every field of the request for confirmation [c] (its picking, all the settings), to compute it again
  /// ([submit] false) or to send it ([submit] true). Switches on are sent as `1`, off are left out, as the web form does.
  Map<String, String> fields(BatchRateConfirm c, {required bool submit}) {
    final n = c.fieldNames;
    return c.submit.body({
      if (c.mode == BatchRateMode.range) n.floors: floors.trim(),
      if (submit) n.submit: '1' else n.recalc: '1',
      for (final e in scores.entries)
        if (e.value != 0) n.score.replaceAll('{id}', '${e.key}'): '${e.value}',
      n.reason: reason.trim(),
      if (notify || c.notifyForced) n.notify: '1',
      if (c.inThread) n.exclude: exclude.trim(),
      if (c.inThread && (rated || c.antispam.locked)) n.rated: '1',
      if (c.inThread && (same || c.antispam.locked)) n.same: '1',
      for (final e in conds.entries)
        if (e.value.trim().isNotEmpty) n.cond.replaceAll('{id}', '${e.key}'): e.value.trim(),
      for (final e in mults.entries)
        if (e.value > 1) n.mult.replaceAll('{pid}', '${e.key}'): '${e.value}',
    });
  }
}

/// The plugin's checks of a sending, run on the settings of a confirmation: `ok`, or each check that failed with its
/// `code` (`reason`, `score_range`, `mult_range`, `no_score`, `quota`), the credit (`id`, 0 for none) and the plugin's
/// sentence.
typedef BatchRatePrecheck = ({bool ok, List<({String code, int id, String message})> errors});

/// What keeps confirmation [c] from being sent: the plugin's [BatchRateConfirm.blocked], nothing rated, and the
/// plugin's [BatchRateConfirm.precheck] when it answered one; the app's own checks ([batchRateLocalHolds]) for an older
/// answer. Empty when it may be sent.
List<BatchRateHold> batchRateHolds(BatchRateConfirm c, BatchRateSettings settings, {int multMax = 99}) => [
  if (c.blocked) BatchRateHold.blocked,
  if (c.apply == 0) BatchRateHold.nothing,
  ...switch (c.precheck) {
    final precheck? => [if (!precheck.ok) BatchRateHold.precheck],
    null => batchRateLocalHolds(c, settings, multMax: multMax),
  },
];

/// The app's own checks of [settings] on confirmation [c], told as the settings change (before the plugin computes
/// them): no score, a reason required but empty, a quota short, a multiple out of 1 to [multMax], a score times a
/// multiple out of the credit's range.
List<BatchRateHold> batchRateLocalHolds(BatchRateConfirm c, BatchRateSettings settings, {int multMax = 99}) => [
  if (settings.scored.isEmpty) BatchRateHold.noScore,
  if (c.reasonRequired && settings.reason.trim().isEmpty) BatchRateHold.reason,
  if (c.quota.any((q) => !q.ok)) BatchRateHold.quota,
  if (c.items.any(
    (i) => i.pending && ((settings.mults[i.pid] ?? i.mult) < 1 || (settings.mults[i.pid] ?? i.mult) > multMax),
  ))
    BatchRateHold.mult,
  if (batchRateOutOfRange(c, settings).isNotEmpty) BatchRateHold.range,
];

/// The floors (pids) of confirmation [c] rated whose score of some credit times the floor's multiple is out of the
/// credit's range.
Set<int> batchRateOutOfRange(BatchRateConfirm c, BatchRateSettings settings) => {
  for (final item in c.items)
    if (item.pending)
      for (final credit in c.credits)
        if (settings.scored[credit.id] case final score?)
          if (score * (settings.mults[item.pid] ?? item.mult) case final v when v < credit.min || v > credit.max)
            item.pid,
};

/// Why a confirmation is not sent.
enum BatchRateHold {
  /// The plugin says it would refuse it.
  blocked,

  /// The plugin's checks of a sending failed (its sentences tell which).
  precheck,

  /// No floor is rated.
  nothing,

  /// No score is set.
  noScore,

  /// A reason is required.
  reason,

  /// A quota is short.
  quota,

  /// A multiple is out of its range.
  mult,

  /// A score times a multiple is out of range.
  range,
}

/// A batch (a row of the batches, the head of a result).
@immutable
final class BatchRateBatch {
  /// Constructor.
  const BatchRateBatch({
    required this.batchId,
    required this.uid,
    required this.username,
    required this.fid,
    required this.forum,
    required this.tid,
    required this.mode,
    required this.modeText,
    required this.floors,
    required this.conds,
    required this.scores,
    required this.reason,
    required this.exclude,
    required this.total,
    required this.applied,
    required this.skipped,
    required this.pending,
    required this.status,
    required this.statusText,
    required this.dateline,
    required this.canContinue,
    required this.canUndo,
    required this.canUndoItem,
  });

  /// The batch of [m]; null without a batch id.
  static BatchRateBatch? fromJson(Object? m) {
    if (m is! Map<String, dynamic> || _int(m['batchid']) <= 0) {
      return null;
    }
    return BatchRateBatch(
      batchId: _int(m['batchid']),
      uid: _int(m['uid']),
      username: _str(m['username']),
      fid: _int(m['fid']),
      forum: _str(m['forum']),
      tid: _int(m['tid']),
      mode: _int(m['mode']),
      modeText: _str(m['mode_text']),
      floors: _str(m['floors']),
      conds: [for (final c in m['conds'] is List ? m['conds'] as List : const []) _str(c)],
      scores: [
        for (final s in _maps(m['scores'])) (id: _int(s['id']), title: _str(s['title']), score: _int(s['score'])),
      ],
      reason: _str(m['reason']),
      exclude: [for (final e in m['exclude'] is List ? m['exclude'] as List : const []) _str(e)],
      total: _int(m['total']),
      applied: _int(m['applied']),
      skipped: _int(m['skipped']),
      pending: _intOrNull(m['pending']),
      status: _int(m['status']),
      statusText: _str(m['status_text']),
      dateline: _int(m['dateline']),
      canContinue: _on(m['can_continue']),
      canUndo: _on(m['can_undo']),
      canUndoItem: _on(m['can_undo_item']),
    );
  }

  /// Batch id.
  final int batchId;

  /// Who made it.
  final int uid;

  /// Their name.
  final String username;

  /// Forum.
  final int fid;

  /// Its name, as served.
  final String forum;

  /// Thread, 0 for the list mode.
  final int tid;

  /// `brmode`.
  final int mode;

  /// The mode, as served.
  final String modeText;

  /// The floor numbers of the range mode.
  final String floors;

  /// The thresholds, as served.
  final List<String> conds;

  /// The scores.
  final List<({int id, String title, int score})> scores;

  /// Reason.
  final String reason;

  /// Names left out.
  final List<String> exclude;

  /// Floors in the batch.
  final int total;

  /// Floors rated.
  final int applied;

  /// Floors skipped.
  final int skipped;

  /// Floors still to rate, null when not counted.
  final int? pending;

  /// 0 running, 1 done, 2 taken back, 3 partly taken back.
  final int status;

  /// [status], as served.
  final String statusText;

  /// When it was made (unix seconds).
  final int dateline;

  /// It may be run on.
  final bool canContinue;

  /// It may be taken back.
  final bool canUndo;

  /// Its floors may be taken back one by one.
  final bool canUndoItem;
}

/// The links of a batch's answer.
typedef BatchRateLinks = ({BatchRateForm? run, BatchRateForm? undoItem, BatchRateForm? undoBatch, String? resultUrl});

BatchRateLinks _links(Map<String, dynamic> forms, int batchId) => (
  run: BatchRateForm.parse(forms['run']),
  undoItem: BatchRateForm.parse(forms['undo_item']),
  undoBatch: BatchRateForm.parse(forms['undo_batch']),
  resultUrl: BatchRateForm.urlOf(_str(forms['result_url']).replaceAll('{batchid}', '$batchId')),
);

/// A batch with its floors (schema 34): just made or run on ([run], no [items]), or its result.
final class BatchRateBatchPage extends BatchRatePosted {
  /// Constructor.
  const BatchRateBatchPage({
    required this.uid,
    required this.formHash,
    required this.batch,
    required this.items,
    required this.run,
    required this.links,
  });

  /// The page of an answer [json]; null when it is not one.
  static BatchRateBatchPage? fromJson(Map<String, dynamic>? json) {
    if (json == null || json['ok'] != 1 || json['type'] != 'batchrate_batch') {
      return null;
    }
    final batch = BatchRateBatch.fromJson(json['batch']);
    if (batch == null) {
      return null;
    }
    return BatchRateBatchPage(
      uid: _int(json['uid']),
      formHash: _str(json['formhash']),
      batch: batch,
      items: json['items'] is List ? [for (final i in _maps(json['items'])) BatchRateItem._of(i)] : null,
      run: _on(json['run']),
      links: _links(_map(json['forms']), batch.batchId),
    );
  }

  /// The account the answer is for.
  final int uid;

  /// The form hash of the session.
  final String formHash;

  /// The batch.
  final BatchRateBatch batch;

  /// Its floors; null for a batch to run.
  final List<BatchRateItem>? items;

  /// The batch is to be run now (made, or run on).
  final bool run;

  /// Its forms.
  final BatchRateLinks links;
}

/// A page of the batches (schema 35), newest first.
@immutable
final class BatchRateBatches {
  /// Constructor.
  const BatchRateBatches({
    required this.uid,
    required this.formHash,
    required this.page,
    required this.pages,
    required this.count,
    required this.batches,
    required this.detailUrl,
    required this.undoBatch,
  });

  /// The page of an answer [json]; null when it is not one.
  static BatchRateBatches? fromJson(Map<String, dynamic>? json) {
    if (json == null || json['ok'] != 1 || json['type'] != 'batchrate_list') {
      return null;
    }
    final forms = _map(json['forms']);
    return BatchRateBatches(
      uid: _int(json['uid']),
      formHash: _str(json['formhash']),
      page: _int(json['page']) < 1 ? 1 : _int(json['page']),
      pages: _int(json['pages']) < 1 ? 1 : _int(json['pages']),
      count: _int(json['count']),
      batches: [for (final b in _maps(json['batches'])) ?BatchRateBatch.fromJson(b)],
      detailUrl: _str(forms['detail_url']),
      undoBatch: BatchRateForm.parse(forms['undo_batch']),
    );
  }

  /// The account the answer is for.
  final int uid;

  /// The form hash of the session.
  final String formHash;

  /// This page.
  final int page;

  /// Pages.
  final int pages;

  /// Batches.
  final int count;

  /// The batches of this page.
  final List<BatchRateBatch> batches;

  /// The detail link, `{batchid}` to fill in.
  final String detailUrl;

  /// The form taking a batch back.
  final BatchRateForm? undoBatch;

  /// The detail of [batchId], null when the answer named another place.
  String? detailOf(int batchId) => BatchRateForm.urlOf(detailUrl.replaceAll('{batchid}', '$batchId'));
}

/// The answer to a run or a taking back (a write result, `kind: handle`): what is `done` of `total`, what is
/// `remaining`, `finished`; or the plugin's `message` when not `ok`.
typedef BatchRateStep = ({bool ok, int done, int total, int remaining, bool finished, String message});
