import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The hidden fields of the forum's window taking rates back the app sends back as they were served.
const removeRateServedFields = {'formhash', 'tid', 'pid', 'handlekey'};

/// One rate of a floor as the forum's window taking rates back lists it (a row of `form#rateform`).
final class RemoveRateEntry {
  /// Constructor.
  const RemoveRateEntry({
    required this.logId,
    required this.username,
    required this.uid,
    required this.time,
    required this.credit,
    required this.reason,
  });

  /// The value of the row's checkbox (`logidarray[]`: the rater's uid, the credit and the time, as the forum knows
  /// the rate by), sent back as served.
  final String logId;

  /// The rater's name.
  final String username;

  /// The rater's uid, 0 when the row links none.
  final int uid;

  /// When it was rated, as the forum printed it (the exact time when the forum gave it as the row's title).
  final String time;

  /// The credit and the score, as the forum printed them (`威望 +1`).
  final String credit;

  /// The rater's reason, empty for none.
  final String reason;
}

/// The forum's window taking rates of floor [pid] of thread [tid] back
/// (`forum.php?mod=misc&action=removerate`), as served to account [uid].
final class RemoveRateForm {
  /// Constructor.
  const RemoveRateForm({
    required this.tid,
    required this.pid,
    required this.fields,
    required this.entries,
    this.uid = 0,
    this.canNotify = false,
    this.notifyForced = false,
  });

  /// The thread.
  final String tid;

  /// The floor.
  final String pid;

  /// The hidden fields served ([removeRateServedFields]).
  final Map<String, String> fields;

  /// The rates the window lists, in its order.
  final List<RemoveRateEntry> entries;

  /// The account the window was served to.
  final int uid;

  /// The window offers to notify the author (`sendreasonpm`).
  final bool canNotify;

  /// The forum notifies the author whatever is sent (the checkbox served checked and disabled).
  final bool notifyForced;

  /// The url the window is posted to, as an AJAX request.
  static const submitUrl = '$baseUrl/forum.php?mod=misc&action=removerate&ratesubmit=yes&infloat=yes&inajax=1';

  /// The url the window of floor [pid] of thread [tid] is asked at, as the floor's 撤销评分 link opens it.
  static String windowUrl({required String tid, required String pid}) =>
      '$baseUrl/forum.php?mod=misc&action=removerate&tid=$tid&pid=$pid&infloat=yes&handlekey=rate&inajax=1';

  /// The window of floor [pid] of thread [tid] read from [doc], served to [uid]; null when [doc] has no such window
  /// (no `form#rateform` posting to `removerate`, a form hash missing, another thread or floor).
  static RemoveRateForm? parse(uh.Document doc, {required String tid, required String pid, int uid = 0}) {
    final form = doc.querySelector('form#rateform');
    if (form == null) {
      return null;
    }
    final Uri target;
    try {
      target = Uri.parse((form.attributes['action'] ?? '').replaceAll('&amp;', '&'));
    } on FormatException {
      return null;
    }
    final query = uniqueQueryParameters(target);
    if (!isForumScriptUri(target, 'forum.php') ||
        query == null ||
        query['mod'] != 'misc' ||
        query['action'] != 'removerate' ||
        query['ratesubmit'] != 'yes') {
      return null;
    }
    final fields = <String, String>{};
    for (final input in form.querySelectorAll('input[type="hidden"]')) {
      final name = input.attributes['name'] ?? '';
      if (removeRateServedFields.contains(name)) {
        if (fields.containsKey(name)) {
          return null;
        }
        fields[name] = input.attributes['value'] ?? '';
      }
    }
    if ((fields['formhash'] ?? '').isEmpty || fields['tid'] != tid || fields['pid'] != pid) {
      return null;
    }
    String text(uh.Element? e) => (e?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final entries = <RemoveRateEntry>[];
    for (final row in form.querySelectorAll('table.list tr')) {
      final box = row.querySelector('input[type="checkbox"][name="logidarray[]"]');
      final logId = box?.attributes['value'] ?? '';
      final cells = row.querySelectorAll('td');
      if (logId.trim().isEmpty || cells.length < 5 || entries.any((e) => e.logId == logId)) {
        continue;
      }
      final link = cells[1].querySelector('a');
      final uidMatch = RegExp(r'[?&]uid=(\d+)').firstMatch((link?.attributes['href'] ?? '').replaceAll('&amp;', '&'));
      final timeSpan = cells[2].querySelector('span[title]');
      entries.add(
        RemoveRateEntry(
          logId: logId,
          username: text(cells[1]),
          uid: uidMatch == null ? 0 : int.parse(uidMatch.group(1)!),
          time: (timeSpan?.attributes['title'] ?? '').trim().isNotEmpty
              ? timeSpan!.attributes['title']!.trim()
              : text(cells[2]),
          credit: text(cells[3]),
          reason: text(cells[4]),
        ),
      );
    }
    final notify = form.querySelector('input[name="sendreasonpm"]');
    return RemoveRateForm(
      tid: tid,
      pid: pid,
      fields: fields,
      entries: entries,
      uid: uid,
      canNotify: notify != null,
      notifyForced:
          notify != null && notify.attributes.containsKey('disabled') && notify.attributes.containsKey('checked'),
    );
  }

  /// The form body taking the rates [logIds] back with [reason] and the notice: the served hidden fields, each rate
  /// chosen by index (`logidarray[0]`…, the same list for PHP: a map carries no name twice). Rates the window does not
  /// list are never sent.
  Map<String, String> body(Iterable<String> logIds, {String reason = '', bool notify = false}) {
    final listed = {for (final e in entries) e.logId};
    final chosen = logIds.where(listed.contains).toSet().toList();
    return {
      ...fields,
      for (final (i, id) in chosen.indexed) 'logidarray[$i]': id,
      'reason': reason.trim(),
      if (canNotify && (notify || notifyForced)) 'sendreasonpm': 'on',
      'ratesubmit': 'true',
    };
  }
}

/// What the forum answered when asked for the window taking rates of a floor back.
sealed class RemoveRateWindow {
  const RemoveRateWindow();
}

/// The window, ready to fill in.
final class RemoveRateWindowReady extends RemoveRateWindow {
  /// Constructor.
  const RemoveRateWindowReady(this.form);

  /// The window.
  final RemoveRateForm form;
}

/// The forum refused to open the window, in its own words [message] (not a moderator of this forum:
/// `no_privilege_removerate`; a floor hidden or of a guest: `rate_post_error`); empty when it gave none.
final class RemoveRateWindowRefused extends RemoveRateWindow {
  /// Constructor.
  const RemoveRateWindowRefused(this.message);

  /// The forum's message.
  final String message;
}

/// The forum's verdict on rates taken back, or on an attachment deleted.
sealed class FloorOpOutcome {
  const FloorOpOutcome();
}

/// Done, with the forum's message (empty when it gave none).
final class FloorOpSucceeded extends FloorOpOutcome {
  /// Constructor.
  const FloorOpSucceeded([this.message = '']);

  /// The forum's message.
  final String message;
}

/// Refused, in the forum's words (empty when it gave none).
final class FloorOpRefused extends FloorOpOutcome {
  /// Constructor.
  const FloorOpRefused([this.message = '']);

  /// The forum's message.
  final String message;
}

/// The text of an AJAX answer (`<root><![CDATA[…]]></root>`), [text] itself when it is not one.
String floorOpAjaxText(String text) {
  if (!text.trimLeft().startsWith('<?xml')) {
    return text;
  }
  try {
    return parseXmlDocument(text).documentElement?.text ?? text;
  } on Object catch (_) {
    return text;
  }
}

/// The handler call of the AJAX answer of the window taking rates back (without the app API):
/// `succeedhandle_rate('url', 'message', {})` or `errorhandle_rate('message', {})`, the message quoted with `\'`
/// escaped.
final _rateSucceedRe = RegExp(r"succeedhandle_rate\('(?:[^'\\]|\\.)*',\s*'(?<message>(?:[^'\\]|\\.)*)'");
final _rateErrorRe = RegExp(r"errorhandle_rate\('(?<message>(?:[^'\\]|\\.)*)'");

String _unescape(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!).trim();

/// The forum's refusal in the AJAX answer [text] of the window taking rates back, null when it calls no error
/// handler.
String? removeRateAjaxError(String text) {
  final match = _rateErrorRe.firstMatch(floorOpAjaxText(text));
  return match == null ? null : _unescape(match.namedGroup('message')!);
}

/// The forum's verdict in answer [data] to rates taken back: `thread_rate_removesucceed` of the app API, or the
/// success handler of the AJAX answer; anything else is a refusal in the forum's words.
FloorOpOutcome removeRateOutcomeOf(Object? data) {
  if (tsdmAppWriteResultOf(data) case final result?) {
    if (result.succeeded && result.messageKey == 'thread_rate_removesucceed') {
      return FloorOpSucceeded(result.message);
    }
    return FloorOpRefused(result.reason);
  }
  final text = floorOpAjaxText(tsdmAppAnswerText(data));
  if (_rateSucceedRe.firstMatch(text) case final match?) {
    return FloorOpSucceeded(_unescape(match.namedGroup('message')!));
  }
  if (_rateErrorRe.firstMatch(text) case final match?) {
    return FloorOpRefused(_unescape(match.namedGroup('message')!));
  }
  return const FloorOpRefused();
}

/// The url deleting attachment [aid] of floor [pid] of thread [tid], with the form hash [formHash] of the edit page,
/// as the edit page's attachment list asks it (`forum.php?mod=ajax&action=deleteattach`, a GET that deletes).
String deleteAttachmentUrl({required String tid, required String pid, required int aid, required String formHash}) =>
    '$baseUrl/forum.php?mod=ajax&action=deleteattach&inajax=yes&formhash=${Uri.encodeQueryComponent(formHash)}'
    '&tid=$tid&pid=$pid&aids%5B%5D=$aid';

/// The forum's verdict in answer [data] to an attachment deleted: the number of attachments it deleted, the only
/// thing it answers (the app API's `page` whose document is that number, or the AJAX fragment). One is done; none is
/// a refusal without words (not the post's author nor a moderator of the forum, a form hash expired, an attachment
/// gone already); null when [data] is no such answer.
FloorOpOutcome? deleteAttachmentOutcomeOf(Object? data) {
  final String text;
  if (tsdmAppWriteResultOf(data) case final result?) {
    if (result.kind != TsdmAppWriteKind.page) {
      return result.login ? FloorOpRefused(result.reason) : null;
    }
    text = result.documentHtml;
  } else {
    text = floorOpAjaxText(tsdmAppAnswerText(data));
  }
  return switch (int.tryParse(text.trim())) {
    null => null,
    > 0 => const FloorOpSucceeded(),
    _ => const FloorOpRefused(),
  };
}
