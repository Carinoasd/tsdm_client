import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:universal_html/html.dart' as uh;

/// One thread recommended in a forum, as the panel's 推荐主题 lists it.
final class RecommendedThread {
  /// Constructor.
  const RecommendedThread({
    required this.tid,
    required this.order,
    required this.subject,
    required this.author,
    required this.recommender,
    required this.expiration,
    this.authorUid,
    this.recommenderUid,
  });

  /// The thread.
  final int tid;

  /// Its place in the forum's list (`displayorder`, the smaller first).
  final int order;

  /// The title shown in the list (its own, not the thread's).
  final String subject;

  /// The thread's author, may be empty (an anonymous thread).
  final String author;

  /// The author's uid, null without a link.
  final int? authorUid;

  /// Who recommended it: a moderator's name, the forum's `System` for the threads the forum recommended itself.
  final String recommender;

  /// The moderator's uid, null for the forum.
  final int? recommenderUid;

  /// Until when, as the panel prints it (`yyyy-M-d HH:mm`); empty for no end.
  final String expiration;
}

/// A change of one recommended thread: its place, its title and until when (empty for no end).
typedef RecommendEdit = ({int order, String subject, String expiration});

/// The largest place the forum keeps (`displayorder` is a `tinyint`).
const recommendOrderMax = 127;

/// The panel's 推荐主题 of a forum (`forum.php?mod=modcp&action=forum&op=recommend`): the threads recommended in it, in
/// the forum's order. A moderator of a forum (`adminid` 3) is shown the forum's own and theirs only.
final class RecommendList {
  /// Constructor.
  const RecommendList({
    required this.uid,
    required this.fid,
    required this.forums,
    this.threads = const [],
    this.editable = false,
    this.formHash = '',
    this.message = '',
  });

  /// The account the page was served to.
  final int uid;

  /// The forum, 0 for none (one the account does not moderate).
  final int fid;

  /// The forums the panel offers in its select.
  final List<ModcpForum> forums;

  /// The threads recommended.
  final List<RecommendedThread> threads;

  /// The list can be changed: the forum orders it by hand. A forum ordering its recommended threads itself
  /// (`modrecommend.sort` 1) prints the fields `readonly` and keeps the list as it is whatever is posted.
  final bool editable;

  /// The form hash of the list's form.
  final String formHash;

  /// The panel's line after a post (推荐主题更新成功).
  final String message;

  /// The url of the list of forum [fid]; without one the panel sends the account on to the forum it chose last, or
  /// its first.
  static String url({int fid = 0}) =>
      '$baseUrl/forum.php?mod=modcp&action=forum&op=recommend${fid > 0 ? '&fid=$fid' : ''}';

  /// The url the list is posted to (the form's `op` is a field).
  static String get submitUrl => '$baseUrl/forum.php?mod=modcp&action=forum';

  /// The body of the list's form: every thread listed as it is but those of [edits] as changed there, and [remove]
  /// taken off the list. The panel saves the place, the title and the end of each thread posted, so all of them are
  /// sent as the web page does.
  Map<String, String> body({Map<int, RecommendEdit> edits = const {}, Set<int> remove = const {}}) {
    final body = <String, String>{
      'formhash': formHash,
      'op': 'recommend',
      'page': '1',
      'fid': '$fid',
      'check': '',
    };
    for (final (i, tid) in remove.indexed) {
      // Indexed keys: a repeated `delete[]` does not fit the string map the transport takes.
      body['delete[$i]'] = '$tid';
    }
    for (final thread in threads) {
      final edit = edits[thread.tid];
      body['order[${thread.tid}]'] = '${edit?.order ?? thread.order}';
      body['subject[${thread.tid}]'] = edit?.subject ?? thread.subject;
      body['expirationrecommend[${thread.tid}]'] = edit?.expiration ?? thread.expiration;
    }
    body['editsubmit'] = 'yes';
    return body;
  }
}

String _text(uh.Element? e) => (e?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

final _tidRe = RegExp(r'^order\[(\d+)\]$');

/// The panel's 推荐主题 on page [doc], served to [uid]; null when it is not that page.
RecommendList? parseRecommendList(uh.Document doc, {required int uid}) {
  final heading = doc.querySelector('div.mdcp h1.mt');
  final isPage = doc
      .querySelectorAll('div.appl li.a > a')
      .map((e) => modcpQuery(e.attributes['href'] ?? ''))
      .any((q) => q != null && q['mod'] == 'modcp' && q['action'] == 'forum' && q['op'] == 'recommend');
  if (!isPage) {
    return null;
  }
  final (forums, selected) = modcpForums(doc);
  final form = doc
      .querySelectorAll('form')
      .where((e) => e.querySelector('input[name="op"][value="recommend"]') != null)
      .firstOrNull;
  if (form == null) {
    // No thread recommended (`div.emp`), or a forum the account does not moderate (nothing printed).
    final fid = heading == null ? 0 : selected;
    return RecommendList(uid: uid, fid: fid, forums: forums);
  }
  final fid = int.tryParse(form.querySelector('input[name="fid"]')?.attributes['value'] ?? '') ?? 0;
  final formHash = form.querySelector('input[name="formhash"]')?.attributes['value'] ?? '';
  if (fid <= 0 || formHash.isEmpty) {
    return RecommendList(uid: uid, fid: 0, forums: forums);
  }
  final threads = <RecommendedThread>[];
  var editable = true;
  for (final row in form.querySelectorAll('tr')) {
    final orderInput = row.querySelector('input[name^="order["]');
    final tid = int.tryParse(_tidRe.firstMatch(orderInput?.attributes['name'] ?? '')?.group(1) ?? '');
    final cells = row.children.where((e) => e.localName == 'td').toList();
    if (orderInput == null || tid == null || cells.length < 6) {
      continue;
    }
    if (orderInput.attributes.containsKey('readonly') || orderInput.attributes.containsKey('disabled')) {
      editable = false;
    }
    final subjectInput = row.querySelector('input[name="subject[$tid]"]');
    final expirationInput = row.querySelector('input[name="expirationrecommend[$tid]"]');
    final order = int.tryParse((orderInput.attributes['value'] ?? '').trim());
    if (subjectInput == null || expirationInput == null || order == null) {
      // A row not as the panel prints it: posting the list would send its fields empty, so it is read only.
      editable = false;
    }
    final authorLink = cells[3].querySelector('a');
    final recommenderLink = cells[4].querySelector('a');
    threads.add(
      RecommendedThread(
        tid: tid,
        order: order ?? 0,
        subject: subjectInput?.attributes['value'] ?? '',
        author: _text(cells[3]),
        authorUid: modcpAuthorUidOf(authorLink),
        recommender: _text(cells[4]),
        recommenderUid: modcpAuthorUidOf(recommenderLink),
        expiration: (expirationInput?.attributes['value'] ?? '').trim(),
      ),
    );
  }
  final button = form.querySelector('button[name="editsubmit"]');
  final message =
      button?.parent?.nodes
          .where((n) => n is! uh.Element || (n.localName != 'button' && n.localName != 'script'))
          .map((n) => n.text ?? '')
          .join()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim() ??
      '';
  return RecommendList(
    uid: uid,
    fid: fid,
    forums: forums,
    threads: List.unmodifiable(threads),
    editable: editable,
    formHash: formHash,
    message: message,
  );
}

final _expirationRe = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2}) +(\d{1,2}):(\d{1,2})$');

/// [text] as a time: the end of a recommendation as the panel prints and reads it (`yyyy-M-d H:mm`); null when empty or
/// not in that form.
DateTime? recommendExpirationTime(String text) {
  final m = _expirationRe.firstMatch(text.trim());
  if (m == null) {
    return null;
  }
  final v = [for (var i = 1; i <= 5; i++) int.parse(m.group(i)!)];
  return DateTime(v[0], v[1], v[2], v[3], v[4]);
}

/// [time] as the panel prints the end of a recommendation (`2027-1-2 03:04`).
String recommendExpirationText(DateTime time) =>
    '${time.year}-${time.month}-${time.day} ${'${time.hour}'.padLeft(2, '0')}:${'${time.minute}'.padLeft(2, '0')}';
