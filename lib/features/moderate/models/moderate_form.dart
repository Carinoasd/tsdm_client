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
  delete(3)
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
      '$baseUrl/forum.php?mod=topicadmin&action=moderate&fid=$fid&moderate%5B%5D=$tid&handlekey=mods&infloat=yes'
      '&nopost=yes&optgroup=${operation.group}'
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
    var operation = asked;
    final form = doc.querySelector('form#moderateform');
    if (form == null || !_isTarget(form.attributes['action'] ?? '', operation.group)) {
      return null;
    }
    final fields = <String, String>{};
    for (final input in form.querySelectorAll('input[type="hidden"]')) {
      final name = input.attributes['name'] ?? '';
      if (moderateServedFields.contains(name)) {
        if (fields.containsKey(name)) {
          // Two threads, or a field served twice: not the window of one thread.
          return null;
        }
        fields[name] = input.attributes['value'] ?? '';
      }
    }
    if ((fields['formhash'] ?? '').isEmpty || fields['moderate[]'] != tid || fields['fid'] != '$fid') {
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
      },
      'reason': reason.trim(),
      if (form.canNotify && (notify || form.notifyForced)) 'sendreasonpm': 'on',
    };
  }
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
