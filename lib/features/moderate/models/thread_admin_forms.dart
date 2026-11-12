import 'package:flutter/foundation.dart' show immutable;
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// The poster's IP of a floor (`form: getip` of the forum's app API, plugin 3.9.0): who posted it, the IP and port,
/// and where the forum's IP library places it (may be empty).
@immutable
final class FloorIp {
  /// Constructor.
  const FloorIp({
    required this.uid,
    required this.pid,
    required this.author,
    required this.ip,
    this.port = 0,
    this.location = '',
  });

  /// The answer [form] served to account [uid] for floor [pid]; null when it is another floor's.
  static FloorIp? of(SmallFormFields form, {required int uid, required int pid}) {
    final json = form.json;
    if (tsdmAppInt(json['pid']) != pid) {
      return null;
    }
    return FloorIp(
      uid: uid,
      pid: pid,
      author: tsdmAppText(json['author']),
      ip: tsdmAppText(json['ip']).trim(),
      port: tsdmAppInt(json['port']),
      location: tsdmAppText(json['location']).trim(),
    );
  }

  /// The account it was served to.
  final int uid;

  /// The floor.
  final int pid;

  /// The floor's author.
  final String author;

  /// The IP the floor was posted from; empty when the forum kept none.
  final String ip;

  /// The port, 0 when not kept.
  final int port;

  /// Where the IP library places [ip], as the forum wrote it.
  final String location;
}

/// The two operations on a thread the forum's management menu has beside its management window (plugin 3.9.0 gives
/// their window's data): taking the bounty off, refunding the buyers.
enum ThreadAdminAction {
  /// 移除悬赏: the bounty goes back to the author, the thread becomes an ordinary one.
  removeReward,

  /// 强制退款: every buyer is refunded, taken back from the author; the thread can not be bought any more.
  refund
  ;

  /// The `action` of `forum.php?mod=topicadmin` and the `form` of the answer.
  String get action => switch (this) {
    removeReward => 'removereward',
    refund => 'refund',
  };

  /// The small form of the answer.
  SmallFormKind get kind => switch (this) {
    removeReward => SmallFormKind.removereward,
    refund => SmallFormKind.refund,
  };
}

/// The window of a [ThreadAdminAction] on a thread, as served to account [uid]: what the thread is (the bounty or
/// the price, the buyers), the reason (required or not, the forum's preset reasons), the notice to the author, and
/// the form to post.
@immutable
final class ThreadAdminForm {
  /// Constructor.
  const ThreadAdminForm({
    required this.action,
    required this.uid,
    required this.tid,
    required this.subject,
    required this.price,
    required this.submitUrl,
    required this.fields,
    this.creditTitle = '',
    this.creditUnit = '',
    this.solved = false,
    this.payers = 0,
    this.income = 0,
    this.reasonField = 'reason',
    this.reasonRequired = false,
    this.reasons = const [],
    this.notifyField = '',
    this.notifyValue = '',
    this.notifyForced = false,
  });

  static final _field = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// The window [form] of [action] on thread [tid] served to account [uid]; null when it is another thread's or its
  /// form does not post back to that operation of `forum.php?mod=topicadmin` on this forum.
  static ThreadAdminForm? of(SmallFormFields form, ThreadAdminAction action, {required int uid, required int tid}) {
    final json = form.json;
    final fields = form.submitFields;
    final url = form.submitUrl('forum.php', {'mod': 'topicadmin', 'action': action.action});
    if (tsdmAppInt(json['tid']) != tid || url == null || fields['tid'] != '$tid' || !form.usable) {
      return null;
    }
    final credit = tsdmAppMap(json['credit']);
    final reason = tsdmAppMap(json['reason']);
    final notify = tsdmAppMap(json['notify']);
    final reasonName = tsdmAppText(reason['name']);
    final notifyName = tsdmAppText(notify['name']);
    return ThreadAdminForm(
      action: action,
      uid: uid,
      tid: tid,
      subject: tsdmAppText(json['subject']),
      price: tsdmAppInt(json['price']),
      creditTitle: tsdmAppText(credit['title']),
      creditUnit: tsdmAppText(credit['unit']),
      solved: tsdmAppInt(json['solved']) == 1,
      payers: tsdmAppInt(json['payers']),
      income: tsdmAppInt(json['income']),
      submitUrl: url,
      fields: Map.unmodifiable(fields),
      reasonField: _field.hasMatch(reasonName) ? reasonName : 'reason',
      reasonRequired: tsdmAppInt(reason['required']) == 1,
      reasons: [
        for (final c in (reason['choices'] is List ? reason['choices'] as List : const <Object?>[]))
          if (c is String && c.trim().isNotEmpty && !RegExp(r'^-+$').hasMatch(c.trim())) c.trim(),
      ],
      notifyField: _field.hasMatch(notifyName) ? notifyName : '',
      notifyValue: tsdmAppText(notify['value']).isEmpty ? 'on' : tsdmAppText(notify['value']),
      notifyForced: tsdmAppInt(notify['forced']) == 1,
    );
  }

  /// Which operation.
  final ThreadAdminAction action;

  /// The account it was served to.
  final int uid;

  /// The thread.
  final int tid;

  /// Its title.
  final String subject;

  /// The bounty, or the price of the paid thread.
  final int price;

  /// The credit of [price].
  final String creditTitle;

  /// Its unit.
  final String creditUnit;

  /// The bounty has its best answer (it is then taken back from the one who answered).
  final bool solved;

  /// The members who bought the thread.
  final int payers;

  /// What the author got from them.
  final int income;

  /// The absolute url the form posts to (with `inajax=1`).
  final String submitUrl;

  /// The fields served (form hash, forum, thread, handle key, submit flag), sent as they are.
  final Map<String, String> fields;

  /// The name of the reason field.
  final String reasonField;

  /// A reason must be given.
  final bool reasonRequired;

  /// The forum's preset reasons.
  final List<String> reasons;

  /// The name of the notice field; empty when the window has none.
  final String notifyField;

  /// Its value when sent.
  final String notifyValue;

  /// The author is told whatever is sent.
  final bool notifyForced;

  /// The body posting the form with [reason], the notice sent when [notify] (and the window has one).
  Map<String, String> body({String reason = '', bool notify = false}) => {
    ...fields,
    reasonField: reason.trim(),
    if (notify && notifyField.isNotEmpty) notifyField: notifyValue,
  };
}

/// The url of the window of [action] on thread [tid] of forum [fid] in the JSON mode of the forum's app API.
String threadAdminWindowUrl(String baseUrl, ThreadAdminAction action, {required int fid, required int tid}) =>
    withTsdmAppForm('$baseUrl/forum.php?mod=topicadmin&action=${action.action}&fid=$fid&tid=$tid', page: true);

/// Whether [raw] (a floor's `urls.viewip`, absolute) is the forum's IP window of floor [pid]: `forum.php` of this
/// forum with `mod=topicadmin&action=getip` and that `pid`.
bool isFloorIpUrl(String raw, {required int pid}) {
  final uri = Uri.tryParse(raw);
  if (uri == null || !isForumScriptUri(uri, 'forum.php')) {
    return false;
  }
  final q = uniqueQueryParameters(uri);
  return q != null && q['mod'] == 'topicadmin' && q['action'] == 'getip' && q['pid'] == '$pid';
}

/// The first version of the forum's plugin giving the windows of [ThreadAdminAction] as small forms.
const threadAdminFormsVersion = '3.9.0';

/// Whether the forum's plugin last named is known to give the windows of [ThreadAdminAction] ([TsdmAppApi.pluginInfo]):
/// their flags are older (plugin 3.7.0), their windows are not.
bool threadAdminFormsKnown() => switch (TsdmAppApi.pluginInfo.value) {
  final info? => compareTsdmAppVersions(info.version, threadAdminFormsVersion) >= 0,
  null => false,
};
