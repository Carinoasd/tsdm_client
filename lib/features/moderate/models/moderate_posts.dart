import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// A management operation the app offers a moderator on one floor of a thread.
///
/// Each one is an action of the forum's `forum.php?mod=topicadmin` with the floor in `topiclist[]`; the forum's window
/// of it (`form#topicadminform`) is read first ([FloorModerateForm.parse]).
enum FloorModerateAction {
  /// Delete the reply (`delpost`): to the forum's recycle bin when the forum keeps one, gone otherwise. Never the first
  /// floor: the forum answers that one with the window deleting the whole thread.
  delete('delpost'),

  /// Warn the author for the floor, or take the warning back (`warn`, `warned` 1 or 0).
  warn('warn'),

  /// Hide the floor from readers, or show it again (`banpost`, `banned` 1 or 0).
  ban('banpost')
  ;

  const FloorModerateAction(this.action);

  /// The `action` the forum knows it by.
  final String action;

  /// The field of the choice between doing and undoing it (`warned`, `banned`); null for [delete].
  String? get choiceField => switch (this) {
    FloorModerateAction.delete => null,
    FloorModerateAction.warn => 'warned',
    FloorModerateAction.ban => 'banned',
  };
}

/// The hidden fields of a floor's management window the app sends back as they were served; nothing else of the
/// window is sent (no ban of the author, no deletion of all his posts, no violation record).
const floorModerateServedFields = {'formhash', 'fid', 'tid', 'page', 'handlekey', 'topiclist[]'};

/// The forum's management window (`form#topicadminform`) of [action] on floor [pid] of thread [tid], as served to the
/// account that asked.
///
/// Read from the window `forum.php?mod=topicadmin&action=delpost|warn|banpost&topiclist[]=PID` ([parse]); the forum's
/// app API has no structured form for it.
final class FloorModerateForm {
  /// Constructor.
  const FloorModerateForm({
    required this.action,
    required this.tid,
    required this.fid,
    required this.pid,
    required this.fields,
    this.uid = 0,
    this.undo = false,
    this.reasons = const [],
    this.canNotify = false,
    this.notifyForced = false,
  });

  /// The operation.
  final FloorModerateAction action;

  /// The thread.
  final String tid;

  /// The forum the thread is in.
  final int fid;

  /// The floor.
  final String pid;

  /// The hidden fields served ([floorModerateServedFields]).
  final Map<String, String> fields;

  /// The account the window was served to.
  final int uid;

  /// The window checks taking the warning or the hiding back (`warned` or `banned` 0): the floor is warned or hidden
  /// now, so undoing it is what changes it. Always false for [FloorModerateAction.delete].
  final bool undo;

  /// The reasons the site set for management (`ul#reasonselect`), separators left out.
  final List<String> reasons;

  /// The window offers to notify the author (`sendreasonpm`).
  final bool canNotify;

  /// The forum notifies the author whatever is sent (the checkbox served checked and disabled).
  final bool notifyForced;

  /// The url the window is posted to, as an AJAX request.
  String get submitUrl =>
      '$baseUrl/forum.php?mod=topicadmin&action=${action.action}&modsubmit=yes&infloat=yes&modclick=yes&inajax=1';

  /// The url the window of [action] on floor [pid] of thread [tid] in forum [fid] is asked at, as the website asks it
  /// from the floor's management link (`modaction`).
  static String windowUrl(FloorModerateAction action, {required String tid, required int fid, required String pid}) =>
      '$baseUrl/forum.php?mod=topicadmin&action=${action.action}&fid=$fid&tid=$tid&topiclist%5B%5D=$pid'
      '&handlekey=mods&infloat=yes&nopost=yes&inajax=1';

  /// The window of [action] on floor [pid] of thread [tid] in forum [fid] read from [doc], served to [uid]; null when
  /// [doc] has no such window: no `form#topicadminform` posting to the action, a form hash missing, another floor,
  /// thread or forum, or the choice between doing and undoing missing.
  static FloorModerateForm? parse(
    uh.Document doc,
    FloorModerateAction action, {
    required String tid,
    required int fid,
    required String pid,
    int uid = 0,
  }) {
    final form = doc.querySelector('form#topicadminform');
    if (form == null || !_isTarget(form.attributes['action'] ?? '', action)) {
      return null;
    }
    final fields = <String, String>{};
    for (final input in form.querySelectorAll('input[type="hidden"]')) {
      final name = input.attributes['name'] ?? '';
      if (floorModerateServedFields.contains(name)) {
        if (fields.containsKey(name)) {
          // Two floors, or a field served twice: not the window of one floor.
          return null;
        }
        fields[name] = input.attributes['value'] ?? '';
      }
    }
    if ((fields['formhash'] ?? '').isEmpty ||
        fields['topiclist[]'] != pid ||
        fields['tid'] != tid ||
        fields['fid'] != '$fid') {
      return null;
    }

    var undo = false;
    if (action.choiceField case final field?) {
      final radios = form.querySelectorAll('input[type="radio"][name="$field"]');
      if (!radios.any((e) => e.attributes['value'] == '1') || !radios.any((e) => e.attributes['value'] == '0')) {
        return null;
      }
      // The forum checks the one that changes the floor as it is now (undo for a warned or hidden floor).
      final checked = radios.where((e) => e.attributes.containsKey('checked')).map((e) => e.attributes['value']);
      undo = checked.length == 1 && checked.single == '0';
    }

    final notify = form.querySelector('input[name="sendreasonpm"]');
    return FloorModerateForm(
      action: action,
      tid: tid,
      fid: fid,
      pid: pid,
      fields: fields,
      uid: uid,
      undo: undo,
      reasons: moderateReasons(form),
      canNotify: notify != null,
      notifyForced:
          notify != null && notify.attributes.containsKey('disabled') && notify.attributes.containsKey('checked'),
    );
  }

  static bool _isTarget(String action, FloorModerateAction asked) {
    final query = _forumQuery(action);
    return query != null &&
        query['mod'] == 'topicadmin' &&
        query['action'] == asked.action &&
        query['modsubmit'] == 'yes';
  }

  /// The form body of the moderator's choice: the served hidden fields, the choice of the window (doing or undoing, as
  /// it is checked), the [reason] and the notice. Nothing else.
  Map<String, String> body({String reason = '', bool notify = false}) => {
    ...fields,
    ?action.choiceField: undo ? '0' : '1',
    'reason': reason.trim(),
    if (canNotify && (notify || notifyForced)) 'sendreasonpm': 'on',
  };
}

/// The reasons the site set for management in a window [form] (`ul#reasonselect`), separators left out.
List<String> moderateReasons(uh.Element form) => form
    .querySelectorAll('ul#reasonselect > li')
    .map((e) => e.text?.trim() ?? '')
    .where((e) => e.isNotEmpty && !RegExp(r'^-+$').hasMatch(e))
    .toList();

Map<String, String>? _forumQuery(String url) {
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

/// The two lists of the moderation queue of a forum (`forum.php?mod=modcp&action=moderate&op=threads|replies`).
enum ModerateQueueKind {
  /// New threads waiting for a moderator.
  threads,

  /// Replies waiting for a moderator.
  replies,
}

/// What a moderator does to an item of the queue (`modact`). The website's 驳回 (`dismiss`) is not one: the forum takes
/// only these three and does [ignore] for anything else.
enum ModerateQueueAction {
  /// Let it show (`validate`).
  validate,

  /// Leave it hidden and out of the list of waiting ones (`ignore`).
  ignore,

  /// Delete it (`delete`): to the recycle bin when the forum keeps one, gone otherwise.
  delete,
}

/// One thread or reply waiting in the queue, as the moderation panel lists it.
final class ModerateQueueItem {
  /// Constructor.
  const ModerateQueueItem({
    required this.id,
    required this.subject,
    required this.author,
    required this.time,
    required this.message,
    this.authorUid,
  });

  /// The thread id (threads) or the post id (replies), the `moderate[]` of the item.
  final String id;

  /// The thread's subject: of the new thread, or of the thread replied to.
  final String subject;

  /// The author's name, as listed.
  final String author;

  /// The author's uid when the list links the author.
  final int? authorUid;

  /// When it was posted, as the forum printed it.
  final String time;

  /// The content as the forum listed it: the author's text, line breaks kept, no markup rendered.
  final String message;
}

/// The hidden fields of the queue's form (`form#moderate`) sent back with an operation.
const moderateQueueServedFields = {'formhash', 'fid', 'filter', 'posttableid'};

/// One page of a list of the moderation queue, served to [uid].
final class ModerateQueueList {
  /// Constructor.
  const ModerateQueueList({
    required this.kind,
    required this.fid,
    required this.items,
    required this.fields,
    required this.uid,
    this.page = 1,
    this.hasNext = false,
  });

  /// The list.
  final ModerateQueueKind kind;

  /// The forum.
  final int fid;

  /// What waits, in the forum's order.
  final List<ModerateQueueItem> items;

  /// The hidden fields of the list's form ([moderateQueueServedFields]); empty when nothing waits.
  final Map<String, String> fields;

  /// The account the page was served to.
  final int uid;

  /// The page number.
  final int page;

  /// The forum links a next page.
  final bool hasNext;

  /// The url the queue's operations are posted to, as an AJAX request. The forum's own window leaves the forum out
  /// and then acts in every forum the account moderates; it is sent here so only this forum is touched.
  String get submitUrl => '$baseUrl/forum.php?mod=modcp&action=moderate&op=${kind.name}&fid=$fid&infloat=yes&inajax=1';

  /// The url of page [page] of list [kind] of forum [fid], waiting ones only (`filter` 0).
  static String url(ModerateQueueKind kind, {required int fid, int page = 1}) =>
      '$baseUrl/forum.php?mod=modcp&action=moderate&op=${kind.name}&fid=$fid&filter=0'
      '${page > 1 ? '&page=$page' : ''}';

  /// The form body of [action] on [item] with [reason].
  Map<String, String> body(ModerateQueueAction action, ModerateQueueItem item, {String reason = ''}) => {
    ...fields,
    'modact': action.name,
    'modsubmit': '1',
    'handlekey': 'mods',
    'moderate[]': item.id,
    'reason': reason.trim(),
  };
}

/// What the moderation panel answered for a list of its queue.
sealed class ModerateQueueAnswer {
  const ModerateQueueAnswer();
}

/// The list.
final class ModerateQueueReady extends ModerateQueueAnswer {
  /// Constructor.
  const ModerateQueueReady(this.page);

  /// The page of the list.
  final ModerateQueueList page;
}

/// The panel asks the moderator's password again (the first visit, or after an hour idle): its login form.
final class ModerateQueueNeedsLogin extends ModerateQueueAnswer {
  /// Constructor.
  const ModerateQueueNeedsLogin({required this.formHash});

  /// The form hash of the login form.
  final String formHash;
}

/// The panel refused, in its own words [message] (no access, locked after too many wrong passwords, no permission to
/// moderate posts); empty when it gave none.
final class ModerateQueueRefused extends ModerateQueueAnswer {
  /// Constructor.
  const ModerateQueueRefused(this.message);

  /// The forum's message.
  final String message;
}

/// How the panel answered the moderator's password.
sealed class ModeratePanelLogin {
  const ModeratePanelLogin();
}

/// Logged in to the panel.
final class ModeratePanelLoggedIn extends ModeratePanelLogin {
  /// Constructor.
  const ModeratePanelLoggedIn();
}

/// The panel showed its login form again: the password was wrong (the forum says nothing more).
final class ModeratePanelWrongPassword extends ModeratePanelLogin {
  /// Constructor.
  const ModeratePanelWrongPassword();
}

/// The panel refused, in its own words [message] (locked after too many wrong passwords).
final class ModeratePanelRefused extends ModeratePanelLogin {
  /// Constructor.
  const ModeratePanelRefused(this.message);

  /// The forum's message.
  final String message;
}

final _discuzUidRe = RegExp(r"discuz_uid\s*=\s*'(\d+)'");

/// The account the panel's page [doc] was served to (its `discuz_uid`), null when it names none.
int? moderatePageUid(uh.Document doc) {
  for (final script in doc.querySelectorAll('script')) {
    final match = _discuzUidRe.firstMatch(script.text ?? '');
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
  }
  return null;
}

/// Whether [doc] is the panel's login form (`form` posting to `mod=modcp&action=login` with the password `cppwd`);
/// its form hash, null when it is not.
String? moderatePanelLoginFormHash(uh.Document doc) {
  for (final form in doc.querySelectorAll('form')) {
    final query = _forumQuery(form.attributes['action'] ?? '');
    if (query == null || query['mod'] != 'modcp' || query['action'] != 'login') {
      continue;
    }
    if (form.querySelector('input[name="cppwd"]') == null) {
      continue;
    }
    return form.querySelector('input[name="formhash"]')?.attributes['value'] ?? '';
  }
  return null;
}

/// The forum's message on page [doc]: the 提示信息 (`div#messagetext`), or the panel's own error block (no permission
/// to moderate posts: a heading and its paragraphs); empty when it has none.
String moderatePageMessage(uh.Document doc) {
  String text(uh.Element e) => (e.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (doc.querySelector('div#messagetext') case final box?) {
    final p = box.querySelector('p');
    return text(p ?? box);
  }
  // The panel's error block is a heading and paragraphs alone, no tabs or form of a page of the panel.
  if (doc.querySelector('div.mn div.bm h1.mt') case final heading?
      when heading.parent?.querySelector('ul.tb') == null && heading.parent?.querySelector('form') == null) {
    return [
      text(heading),
      for (final p in heading.parent?.querySelectorAll('p') ?? const <uh.Element>[]) text(p),
    ].where((e) => e.isNotEmpty).join('\n');
  }
  return '';
}

/// The list [kind] of the queue of forum [fid] on page [doc], served to [uid]; null when [doc] is not that list (the
/// tab of another list or none, the form of another forum).
ModerateQueueList? parseModerateQueue(
  uh.Document doc,
  ModerateQueueKind kind, {
  required int fid,
  required int uid,
  int page = 1,
}) {
  // The tab of the list shown.
  final current = doc.querySelectorAll('ul.tb > li.a > a').map((e) => _forumQuery(e.attributes['href'] ?? ''));
  if (!current.any((q) => q != null && q['mod'] == 'modcp' && q['action'] == 'moderate' && q['op'] == kind.name)) {
    return null;
  }
  // The forum the panel lists, as its forum select shows it (a forum the account does not moderate lists them all).
  // None selected is all of them: the forum asked was not taken.
  if (doc.querySelector('select[name="fid"]') case final select?
      when select.querySelector('option[selected]')?.attributes['value'] != '$fid') {
    return null;
  }
  final form = doc.querySelector('form#moderate');
  if (form == null) {
    // Nothing waits: the forum prints no form, only its "no result".
    return ModerateQueueList(kind: kind, fid: fid, items: const [], fields: const {}, uid: uid, page: page);
  }
  final fields = <String, String>{};
  for (final input in form.querySelectorAll('input[type="hidden"]')) {
    final name = input.attributes['name'] ?? '';
    if (moderateQueueServedFields.contains(name)) {
      fields[name] = input.attributes['value'] ?? '';
    }
  }
  if ((fields['formhash'] ?? '').isEmpty || fields['fid'] != '$fid') {
    return null;
  }
  final items = <ModerateQueueItem>[];
  for (final row in form.querySelectorAll('div.um')) {
    final id = row.querySelector('input[type="checkbox"][name="moderate[]"]')?.attributes['value'] ?? '';
    if (int.tryParse(id) == null) {
      continue;
    }
    final lines = row.querySelectorAll('p.pbn');
    final authorBox = row.querySelector('span.xi2');
    final authorLink = authorBox?.querySelector('a');
    final uidMatch = RegExp(r'[?&]uid=(\d+)').firstMatch(authorLink?.attributes['href'] ?? '');
    final note = row.querySelector('div#list_note_$id');
    items.add(
      ModerateQueueItem(
        id: id,
        subject: lines.firstOrNull?.querySelector('span.xw1')?.text?.trim() ?? '',
        author: authorBox?.text?.trim() ?? '',
        authorUid: uidMatch == null ? null : int.tryParse(uidMatch.group(1)!),
        time: row.querySelector('span.xg1')?.text?.trim() ?? '',
        message: _noteText(note),
      ),
    );
  }
  final hasNext = doc.querySelector('div.pg a.nxt') != null;
  return ModerateQueueList(
    kind: kind,
    fid: fid,
    items: items,
    fields: fields,
    uid: uid,
    page: page,
    hasNext: hasNext,
  );
}

/// The text of a listed content [note]: `<br />` as line breaks, the rest as the forum escaped it.
String _noteText(uh.Element? note) {
  if (note == null) {
    return '';
  }
  final buffer = StringBuffer();
  void walk(uh.Node node) {
    for (final child in node.nodes) {
      if (child is uh.Element) {
        if (child.localName == 'br') {
          buffer.write('\n');
        } else {
          walk(child);
        }
      } else if (child.nodeType == uh.Node.TEXT_NODE) {
        // The forum's own line breaks around `<br />` are not the author's.
        buffer.write((child.text ?? '').replaceAll(RegExp(r'[\r\n]'), ''));
      }
    }
  }

  walk(note);
  return buffer.toString().trim();
}

/// What the forum answered when asked for the management window of a floor: the window, or its refusal to open it.
sealed class FloorModerateWindow {
  const FloorModerateWindow();
}

/// The window, ready to fill in.
final class FloorModerateWindowReady extends FloorModerateWindow {
  /// Constructor.
  const FloorModerateWindowReady(this.form);

  /// The window.
  final FloorModerateForm form;
}

/// The forum refused to open the window, in its own words [message] (not a moderator of this forum, no permission to
/// warn this author, the first floor asked for a reply's deletion); empty when it gave none.
final class FloorModerateWindowRefused extends FloorModerateWindow {
  /// Constructor.
  const FloorModerateWindowRefused(this.message);

  /// The forum's message.
  final String message;
}
