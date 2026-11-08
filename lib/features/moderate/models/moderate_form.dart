import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// A thread management operation the app offers a moderator, one thread at a time.
///
/// Each one is an operation of the forum's `forum.php?mod=topicadmin&action=moderate` (`operations[]`), opened in the
/// window group ([group], `optgroup`) the website opens it in from the thread page.
enum ModerateOperation {
  /// Stick or unstick (`stick`, `sticklevel` 0 to 3 as the account's group allows, `expirationstick`).
  stick(1),

  /// Digest or undigest (`digest`, `digestlevel` 0 to 3, `expirationdigest`).
  digest(1),

  /// Close the thread (`close`).
  close(4),

  /// Open the thread again (`open`).
  open(4),

  /// Move the thread to another forum (`move`, `moveto`, `type` normal or redirect).
  move(2),

  /// Delete the thread (`delete`): to the forum's recycle bin when the forum keeps one, gone otherwise.
  delete(3),

  /// Bump the thread: its last reply time set to now (`bump`, `expirationbump`).
  bump(3),

  /// Sink the thread: its last reply time set two years back (`down`, `expirationdown`).
  down(3)
  ;

  const ModerateOperation(this.group);

  /// The `optgroup` of the window the operation is in.
  final int group;

  /// The `operations[]` value the forum knows the operation by.
  String get value => name;

  /// The `operation` parameter asking the window of the operation when its group holds others (group 3 is bump and
  /// down unless asked for `delete`); null when the group is asked as it is.
  String? get windowOperation => this == ModerateOperation.delete ? 'delete' : null;
}

/// One choice of a select of the window: a level, or a forum to move to.
@immutable
final class ModerateChoice {
  /// Constructor.
  const ModerateChoice({required this.value, required this.label, this.selected = false, this.depth = 0, this.group});

  /// The value sent.
  final String value;

  /// The text the forum printed for it.
  final String label;

  /// The forum served it selected (the thread's current level, the thread's own forum).
  final bool selected;

  /// A forum's depth below its category (a sub forum is printed after `&nbsp;`).
  final int depth;

  /// The category (`<optgroup label>`) a forum is listed under, without the forum's leading dashes; null outside one.
  final String? group;

  @override
  bool operator ==(Object other) =>
      other is ModerateChoice &&
      other.value == value &&
      other.label == label &&
      other.selected == selected &&
      other.depth == depth &&
      other.group == group;

  @override
  int get hashCode => Object.hash(value, label, selected, depth, group);

  @override
  String toString() => 'ModerateChoice($value, $label${selected ? ', selected' : ''})';
}

/// The hidden fields of the management window the app sends back as they were served; any other hidden field (the
/// highlight colors of group 1, the `operations[]` a window fixes) is never sent.
const moderateServedFields = {'frommodcp', 'formhash', 'fid', 'redirect', 'handlekey', 'moderate[]'};

/// The management window of the forum (`form#moderateform`) for one thread, as served to the account that asked.
///
/// Read from the window `forum.php?mod=topicadmin&action=moderate&optgroup=N` ([ModerateForm.parse]); the forum's
/// app API has no structured form for it (plugin 3.x `forms` lists rate, report, buy, usergroup and profile only).
final class ModerateForm {
  /// Constructor.
  const ModerateForm({
    required this.operation,
    required this.tid,
    required this.fid,
    required this.fields,
    this.uid = 0,
    this.levels = const [],
    this.forums = const [],
    this.canRedirect = false,
    this.reasons = const [],
    this.canNotify = false,
    this.notifyForced = false,
  });

  /// The operation the window is for: the one asked, but close and open as the window checks it (the one that
  /// changes the thread as the forum sees it now).
  final ModerateOperation operation;

  /// The thread.
  final String tid;

  /// The forum the thread is in, as the window names it.
  final int fid;

  /// The hidden fields served ([moderateServedFields]): the form hash, the forum, the thread, the handle key.
  final Map<String, String> fields;

  /// The account the window was served to (the forum's app API tells it); 0 when the answer does not tell.
  final int uid;

  /// The stick or digest levels the account may set, as the forum listed them (0 first: none), the thread's current
  /// level selected. Empty for the other operations.
  final List<ModerateChoice> levels;

  /// The forums the thread may be moved to, in the forum's order, without the forum it is in. Empty for the other
  /// operations.
  final List<ModerateChoice> forums;

  /// The move window offers to leave a redirect behind (`type` redirect).
  final bool canRedirect;

  /// The reasons the site set for management (`ul#reasonselect`), separators left out.
  final List<String> reasons;

  /// The window offers to notify the author (`sendreasonpm`).
  final bool canNotify;

  /// The forum notifies the author whatever is sent (the checkbox served checked and disabled).
  final bool notifyForced;

  /// The level the thread is at now (the selected one); null when none is selected: a level the account may not set,
  /// such as a global stick seen by a forum moderator, is not listed, and no level is chosen for the moderator.
  ModerateChoice? get currentLevel => levels.firstWhereOrNull((e) => e.selected);

  /// The url the window is posted to: the forum's own target of [operation]'s group, as an AJAX request.
  String get submitUrl =>
      '$baseUrl/forum.php?mod=topicadmin&action=moderate&optgroup=${operation.group}&modsubmit=yes&infloat=yes'
      '&inajax=1';

  /// The url the window of [operation] for thread [tid] in forum [fid] is asked at, as the website asks it from the
  /// thread page (`modthreads`).
  static String windowUrl(ModerateOperation operation, {required String tid, required int fid}) =>
      batchWindowUrl(operation, tids: [tid], fid: fid);

  /// The url the window of [operation] for threads [tids] of forum [fid] is asked at, as the website asks it from the
  /// forum page (`modthreads` with the threads checked).
  static String batchWindowUrl(ModerateOperation operation, {required List<String> tids, required int fid}) =>
      '$baseUrl/forum.php?mod=topicadmin&action=moderate&fid=$fid${tids.map((e) => '&moderate%5B%5D=$e').join()}'
      '&handlekey=mods&infloat=yes&nopost=yes&optgroup=${operation.group}'
      '${operation.windowOperation == null ? '' : '&operation=${operation.windowOperation}'}&inajax=1';

  /// The window of operation [asked] for thread [tid] in forum [fid] read from [doc], served to [uid]; null when [doc] has no
  /// such window: no `form#moderateform` posting to the topicadmin target of the operation's group, a form hash
  /// missing, another thread or another forum, or none of what the operation needs (the levels of a stick or digest,
  /// the open and close choices, a forum to move to, the delete operation).
  static ModerateForm? parse(
    uh.Document doc,
    ModerateOperation asked, {
    required String tid,
    required int fid,
    int uid = 0,
  }) {
    final form = doc.querySelector('form#moderateform');
    if (form == null) {
      return null;
    }
    final served = form
        .querySelectorAll('input[type="hidden"][name="moderate[]"]')
        .map((e) => e.attributes['value'] ?? '')
        .toList();
    // Two threads: not the window of one thread.
    if (served.length != 1 || served.single != tid) {
      return null;
    }
    return _parse(form, asked, tid: tid, fid: fid, uid: uid, keepThread: true);
  }

  /// The window of [operation] read from [form], the threads it holds left out of [fields] when not [keepThread].
  static ModerateForm? _parse(
    uh.Element form,
    ModerateOperation asked, {
    required String tid,
    required int fid,
    required int uid,
    required bool keepThread,
  }) {
    var operation = asked;
    if (!_isTarget(form.attributes['action'] ?? '', operation.group)) {
      return null;
    }
    final fields = <String, String>{};
    for (final input in form.querySelectorAll('input[type="hidden"]')) {
      final name = input.attributes['name'] ?? '';
      if (name == 'moderate[]' && !keepThread) {
        continue;
      }
      if (moderateServedFields.contains(name)) {
        if (fields.containsKey(name)) {
          // A field served twice: not a window the app knows.
          return null;
        }
        fields[name] = input.attributes['value'] ?? '';
      }
    }
    if ((fields['formhash'] ?? '').isEmpty || (keepThread && fields['moderate[]'] != tid) || fields['fid'] != '$fid') {
      return null;
    }

    var levels = const <ModerateChoice>[];
    var forums = const <ModerateChoice>[];
    var canRedirect = false;
    switch (operation) {
      case ModerateOperation.stick || ModerateOperation.digest:
        final name = operation == ModerateOperation.stick ? 'sticklevel' : 'digestlevel';
        levels = form
            .querySelectorAll('select[name="$name"] option')
            .map(
              (e) => ModerateChoice(
                value: e.attributes['value'] ?? '',
                label: e.text?.trim() ?? '',
                selected: e.attributes.containsKey('selected'),
              ),
            )
            .where((e) => int.tryParse(e.value) != null)
            .toList();
        if (levels.isEmpty) {
          return null;
        }
      case ModerateOperation.close || ModerateOperation.open:
        final radios = form.querySelectorAll('input[type="radio"][name="operations[]"]');
        final choices = radios.map((e) => e.attributes['value']).toSet();
        if (!choices.contains(ModerateOperation.close.value) || !choices.contains(ModerateOperation.open.value)) {
          return null;
        }
        // The forum checks the one that changes the thread as it is now (open for a closed thread): that one is done,
        // whatever the lock beside the title said when the operation was picked.
        final checked = radios.where((e) => e.attributes.containsKey('checked')).map((e) => e.attributes['value']);
        if (checked.length == 1) {
          operation = checked.single == ModerateOperation.open.value ? ModerateOperation.open : ModerateOperation.close;
        }
      case ModerateOperation.move:
        forums = _forums(form.querySelector('select[name="moveto"]'), fid);
        if (forums.isEmpty) {
          return null;
        }
        canRedirect = form.querySelector('input[type="radio"][name="type"][value="redirect"]') != null;
      case ModerateOperation.delete:
        if (form.querySelector('input[name="operations[]"][value="delete"]') == null) {
          return null;
        }
      case ModerateOperation.bump || ModerateOperation.down:
        final choices = form
            .querySelectorAll('input[type="radio"][name="operations[]"]')
            .map((e) => e.attributes['value'])
            .toSet();
        if (!choices.contains(ModerateOperation.bump.value) || !choices.contains(ModerateOperation.down.value)) {
          return null;
        }
    }

    final notify = form.querySelector('input[name="sendreasonpm"]');
    return ModerateForm(
      operation: operation,
      tid: tid,
      fid: fid,
      fields: fields,
      uid: uid,
      levels: levels,
      forums: forums,
      canRedirect: canRedirect,
      reasons: form
          .querySelectorAll('ul#reasonselect > li')
          .map((e) => e.text?.trim() ?? '')
          .where((e) => e.isNotEmpty && !RegExp(r'^-+$').hasMatch(e))
          .toList(),
      canNotify: notify != null,
      notifyForced:
          notify != null && notify.attributes.containsKey('disabled') && notify.attributes.containsKey('checked'),
    );
  }

  /// The window of operation [asked] for some of threads [tids] of forum [fid] read from [doc], served to [uid]; null
  /// when [doc] has no such window (as [parse]), or holds none of [tids] or a thread not asked.
  ///
  /// The forum serves the threads it takes, in its own order: it leaves out a thread not in the forum (moved,
  /// deleted, a thread of another forum stuck here), one waiting for approval, and those past the account's threads
  /// per page.
  static ModerateBatchForm? parseBatch(
    uh.Document doc,
    ModerateOperation asked, {
    required List<String> tids,
    required int fid,
    int uid = 0,
  }) {
    final form = doc.querySelector('form#moderateform');
    if (form == null) {
      return null;
    }
    final asks = tids.toSet();
    final served = <String>[];
    for (final input in form.querySelectorAll('input[type="hidden"][name="moderate[]"]')) {
      final tid = input.attributes['value'] ?? '';
      if (!asks.contains(tid) || served.contains(tid)) {
        return null;
      }
      served.add(tid);
    }
    if (served.isEmpty) {
      return null;
    }
    final window = _parse(form, asked, tid: served.first, fid: fid, uid: uid, keepThread: false);
    return window == null ? null : ModerateBatchForm(window: window, tids: served);
  }

  static bool _isTarget(String action, int group) {
    final Uri uri;
    try {
      uri = Uri.parse(action.replaceAll('&amp;', '&'));
    } on FormatException {
      return false;
    }
    if (!isForumScriptUri(uri, 'forum.php')) {
      return false;
    }
    final query = uniqueQueryParameters(uri);
    return query != null &&
        query['mod'] == 'topicadmin' &&
        query['action'] == 'moderate' &&
        query['modsubmit'] == 'yes' &&
        query['optgroup'] == '$group';
  }

  /// The forums of the move select, the thread's own forum [fid] left out (moving there the forum does nothing and
  /// still says it succeeded).
  static List<ModerateChoice> _forums(uh.Element? select, int fid) {
    if (select == null) {
      return const [];
    }
    final forums = <ModerateChoice>[];
    for (final option in select.querySelectorAll('option')) {
      final value = option.attributes['value'] ?? '';
      final id = int.tryParse(value);
      if (id == null || id <= 0 || id == fid) {
        continue;
      }
      final raw = option.text ?? '';
      final label = raw.trim();
      if (label.isEmpty) {
        continue;
      }
      // The forum indents a sub forum with `&nbsp; &nbsp; &nbsp; ` per level.
      final lead = raw.length - raw.trimLeft().length;
      final parent = option.parent;
      final groupLabel = parent?.localName == 'optgroup' ? parent?.attributes['label'] : null;
      forums.add(
        ModerateChoice(
          value: value,
          label: label,
          depth: lead == 0 ? 0 : (lead / 6).ceil(),
          group: groupLabel?.replaceFirst(RegExp('^-+'), '').trim(),
        ),
      );
    }
    return forums;
  }
}

/// What the moderator chose in a window, sent with [ModerateForm.fields].
final class ModerateRequest {
  /// Constructor.
  const ModerateRequest({
    required this.operation,
    this.level,
    this.expiration,
    this.moveTo,
    this.redirect = false,
    this.reason = '',
    this.notify = false,
  });

  /// The operation.
  final ModerateOperation operation;

  /// The stick or digest level ([ModerateChoice.value]).
  final String? level;

  /// The day a stick or digest ends, none for no end.
  final DateTime? expiration;

  /// The forum to move to ([ModerateChoice.value]).
  final String? moveTo;

  /// Leave a redirect behind in the forum the thread leaves.
  final bool redirect;

  /// The reason, as typed.
  final String reason;

  /// Notify the author.
  final bool notify;

  /// The form body of this request for [form]: the served hidden fields, the operation and its own fields, the reason
  /// and the notice, as the website's window posts them. Nothing else (no ban of the author, no deletion of all his
  /// posts, no violation record).
  Map<String, String> body(ModerateForm form) {
    String day(DateTime? d) => d == null
        ? ''
        : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
              '${d.day.toString().padLeft(2, '0')}';
    final hasLevel = (int.tryParse(level ?? '') ?? 0) > 0;
    return {
      ...form.fields,
      'operations[]': operation.value,
      ...switch (operation) {
        ModerateOperation.stick => {'sticklevel': level ?? '0', 'expirationstick': hasLevel ? day(expiration) : ''},
        ModerateOperation.digest => {'digestlevel': level ?? '0', 'expirationdigest': hasLevel ? day(expiration) : ''},
        ModerateOperation.close || ModerateOperation.open => {'expirationclose': ''},
        ModerateOperation.move => {
          'moveto': moveTo ?? '',
          'threadtypeid': '0',
          'type': redirect && form.canRedirect ? 'redirect' : 'normal',
        },
        ModerateOperation.delete => const <String, String>{},
        ModerateOperation.bump => {'expirationbump': ''},
        ModerateOperation.down => {'expirationdown': ''},
      },
      'reason': reason.trim(),
      if (form.canNotify && (notify || form.notifyForced)) 'sendreasonpm': 'on',
    };
  }
}

/// The management window of the forum for several threads of a forum ([ModerateForm.parseBatch]).
///
/// The forum takes one verdict for all of them: it says nothing of the threads it leaves out, so the threads the
/// window holds ([tids]) are the ones a request acts on.
final class ModerateBatchForm {
  /// Constructor.
  const ModerateBatchForm({required this.window, required this.tids});

  /// The window, as for one thread: its [ModerateForm.fields] hold no thread, its [ModerateForm.tid] is the first of
  /// [tids].
  final ModerateForm window;

  /// The threads the window holds, in the forum's order.
  final List<String> tids;

  /// The form body of [request] for these threads: [ModerateRequest.body] of the window with every thread.
  ///
  /// The website's form repeats `moderate[]`; the threads are numbered instead (`moderate[0]`, `moderate[1]`…), which
  /// the forum reads as the same list, so the body stays a map of one value per field (the Android client posts
  /// nothing else).
  Map<String, String> body(ModerateRequest request) => {
    ...request.body(window),
    for (final (i, tid) in tids.indexed) 'moderate[$i]': tid,
  };
}

/// How the forum answered a management request.
sealed class ModerateOutcome {
  const ModerateOutcome();
}

/// The forum carried it out (`admin_succeed`); [message] is its words ("管理操作成功"), empty when it gave none.
final class ModerateSucceeded extends ModerateOutcome {
  /// Constructor.
  const ModerateSucceeded(this.message);

  /// The forum's message.
  final String message;
}

/// The forum refused it, in its own words [message] (no permission to stick so high, the end day out of range, the
/// thread not in this forum any more…); empty when the answer said nothing the app can show.
final class ModerateRefused extends ModerateOutcome {
  /// Constructor.
  const ModerateRefused(this.message);

  /// The forum's message.
  final String message;
}

/// What the forum answered when asked for a management window: the window, or its refusal to open it.
sealed class ModerateWindow {
  const ModerateWindow();
}

/// The window, ready to fill in.
final class ModerateWindowReady extends ModerateWindow {
  /// Constructor.
  const ModerateWindowReady(this.form);

  /// The window.
  final ModerateForm form;
}

/// The forum refused to open the window, in its own words [message] (not a moderator of this forum, no such thread).
final class ModerateWindowRefused extends ModerateWindow {
  /// Constructor.
  const ModerateWindowRefused(this.message);

  /// The forum's message, empty when it gave none.
  final String message;
}

/// What the forum answered when asked for the management window of several threads.
sealed class ModerateBatchWindow {
  const ModerateBatchWindow();
}

/// The window of the threads the forum takes.
final class ModerateBatchWindowReady extends ModerateBatchWindow {
  /// Constructor.
  const ModerateBatchWindowReady(this.form);

  /// The window.
  final ModerateBatchForm form;
}

/// The forum refused to open the window, in its own words [message] (none of the threads can be managed here, not a
/// moderator of this forum).
final class ModerateBatchWindowRefused extends ModerateBatchWindow {
  /// Constructor.
  const ModerateBatchWindowRefused(this.message);

  /// The forum's message, empty when it gave none.
  final String message;
}

/// What became of one thread of a management of several threads.
sealed class ModerateBatchResult {
  const ModerateBatchResult();
}

/// The forum carried it out on the thread.
final class ModerateBatchDone extends ModerateBatchResult {
  /// Constructor.
  const ModerateBatchDone();
}

/// Why a thread of a management of several threads was not done.
enum ModerateBatchFailure {
  /// The forum refused it or left the thread out, in its words.
  refused,

  /// The account changed: nothing more was sent.
  accountChanged,

  /// The request failed (the network, an answer the app can not read).
  failed,
}

/// The thread was not done.
final class ModerateBatchFailed extends ModerateBatchResult {
  /// Constructor.
  const ModerateBatchFailed(this.kind, [this.message = '']);

  /// Why.
  final ModerateBatchFailure kind;

  /// The forum's words for a [ModerateBatchFailure.refused], empty when it gave none.
  final String message;
}

/// What became of each thread of a management of several threads, in the order they were picked.
final class ModerateBatchReport {
  /// Constructor.
  const ModerateBatchReport(this.results);

  /// Each thread's result, by tid.
  final Map<String, ModerateBatchResult> results;

  /// The threads done.
  int get doneCount => results.values.whereType<ModerateBatchDone>().length;

  /// The threads not done, with why.
  List<(String, ModerateBatchFailed)> get failed => [
    for (final MapEntry(:key, :value) in results.entries)
      if (value case final ModerateBatchFailed failed) (key, failed),
  ];
}
