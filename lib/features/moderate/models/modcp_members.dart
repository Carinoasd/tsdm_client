import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/moderate/models/member_ban.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:universal_html/html.dart' as uh;

// ---------------------------------------------------------------------------------------------------------------------
// The panel's menu
// ---------------------------------------------------------------------------------------------------------------------

/// The pages the panel's menu (`div.appl`) links to an account: the entries the forum prints only to a group allowed
/// to use them (`forum/modcp.htm`: 禁止用户, 禁止 IP, 编辑用户, 版块编辑, 公告…). Every page of the panel prints it, its
/// login form too.
final class ModcpMenu {
  /// Constructor.
  const ModcpMenu(this.entries);

  /// The pages linked, as `action` or `action/op`.
  final Set<String> entries;

  /// The menu links the panel's [action] (with [op] when given).
  bool has(String action, [String? op]) => entries.contains(op == null ? action : '$action/$op');

  /// Banning members (禁止用户: `allowbanuser` or `allowbanvisituser`).
  bool get canBanMember => has('member', 'ban');

  /// Editing members (编辑用户: `allowedituser`).
  bool get canEditMember => has('member', 'edit');

  /// Banning IPs (禁止 IP: `allowbanip`).
  bool get canBanIp => has('member', 'ipban');

  /// Any of the pages of the members.
  bool get canManageMembers => canBanMember || canEditMember || canBanIp;

  /// Editing the rules of the forums moderated (版块编辑: `alloweditforum`).
  bool get canEditForum => has('forum', 'editforum');

  /// The announcements (公告: `allowpostannounce`).
  bool get canAnnounce => has('announcement');

  /// The threads recommended in the forums moderated (推荐主题: `allowrecommendthread`).
  bool get canRecommend => has('forum', 'recommend');
}

String? _entryOf(String href) {
  final query = modcpQuery(href);
  if (query == null || query['mod'] != 'modcp') {
    return null;
  }
  final action = query['action'] ?? '';
  if (action.isEmpty) {
    return null;
  }
  final op = query['op'] ?? '';
  return op.isEmpty ? action : '$action/$op';
}

/// The panel's menu on page [doc], null when it has none (not a page of the panel, a message page).
ModcpMenu? modcpMenuOf(uh.Document doc) {
  final menu = doc.querySelector('div.appl');
  if (menu == null) {
    return null;
  }
  return ModcpMenu({
    for (final link in menu.querySelectorAll('li a')) ?_entryOf(link.attributes['href'] ?? ''),
  });
}

/// Whether [doc] is the panel's page of [action] (and [op] when given): its menu entry or its tab is the one marked
/// (`li.a`).
bool isModcpPage(uh.Document doc, String action, [String? op]) {
  final wanted = op == null ? action : '$action/$op';
  return doc
      .querySelectorAll('div.appl li.a > a, ul.tb > li.a > a')
      .any((e) => _entryOf(e.attributes['href'] ?? '') == wanted);
}

String _text(uh.Element? e) => (e?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// The value of a textarea as the browser shows it: its text, line breaks kept, the one line break the parser keeps
/// after the tag dropped.
String _textareaValue(uh.Element? e) {
  final text = (e?.text ?? '').replaceAll('\r\n', '\n');
  return text.startsWith('\n') ? text.substring(1) : text;
}

/// Text sent and text read back compared the way the forum keeps it: line breaks as `\n`, the ends trimmed.
String modcpNormalized(String text) => text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();

/// The hidden fields of [form] named in [names].
Map<String, String> _hidden(uh.Element form, Set<String> names) => {
  for (final input in form.querySelectorAll('input[type="hidden"]'))
    if (names.contains(input.attributes['name'] ?? '')) input.attributes['name']!: input.attributes['value'] ?? '',
};

/// The forms of [doc] posting to the panel's [action] and [op].
Iterable<uh.Element> _formsOf(uh.Document doc, String action, String op) => doc.querySelectorAll('form').where((form) {
  final query = modcpQuery(form.attributes['action'] ?? '');
  return query != null && query['mod'] == 'modcp' && query['action'] == action && query['op'] == op;
});

/// The text next to the submit button named [button] (the line the panel prints its result on), the button's own
/// words left out.
String _besideButton(uh.Element? scope, String button) {
  final cell = scope?.querySelector('button[name="$button"]')?.parent;
  if (cell == null) {
    return '';
  }
  return cell.nodes
      .where((n) => n is! uh.Element || (n.localName != 'button' && n.localName != 'script'))
      .map((n) => n.text ?? '')
      .join()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

// ---------------------------------------------------------------------------------------------------------------------
// Members
// ---------------------------------------------------------------------------------------------------------------------

/// How a member is asked: by name or by UID, as the panel's search form takes either.
final class ModcpMemberQuery {
  /// By user name.
  const ModcpMemberQuery.name(this.username) : uid = 0;

  /// By UID.
  const ModcpMemberQuery.uid(this.uid) : username = '';

  /// The user name, empty when asked by UID.
  final String username;

  /// The UID, 0 when asked by name.
  final int uid;

  /// The query of the panel's page [op] (`ban` or `edit`) for this member.
  String url(String op) =>
      '$baseUrl/forum.php?mod=modcp&action=member&op=$op'
      '${uid > 0 ? '&uid=$uid' : '&username=${Uri.encodeQueryComponent(username)}'}';
}

/// One line of a member's record of violations (违规记录), as the ban page prints it.
final class ModcpCrime {
  /// Constructor.
  const ModcpCrime({required this.action, required this.time, required this.reason, required this.operator});

  /// What was done (禁止发言, 删除帖子…), in the forum's words.
  final String action;

  /// When, as printed.
  final String time;

  /// Why.
  final String reason;

  /// Who did it.
  final String operator;
}

/// A status the ban window offers to change a member to (the radio `bannew`), with the forum's label.
final class ModcpBanChoice {
  /// Constructor.
  const ModcpBanChoice({required this.value, required this.label});

  /// `0` (back to normal), `4` (banned from posting) or `5` (banned from visiting).
  final String value;

  /// The forum's words (正常状态, 禁止发言, 禁止访问).
  final String label;

  /// The choice is a ban, which lasts some days.
  bool get isBan => value != '0';
}

/// A member found by the panel's 禁止用户 page: who, the state the panel prints, the record, and the window.
final class ModcpMember {
  /// Constructor.
  const ModcpMember({
    required this.memberUid,
    required this.username,
    required this.status,
    required this.crimes,
    required this.form,
    required this.choices,
  });

  /// The member.
  final int memberUid;

  /// The name, as printed.
  final String username;

  /// The state (正常状态, 禁止发言 ( 有效期至 … )), as printed.
  final String status;

  /// The record of violations, oldest first as printed.
  final List<ModcpCrime> crimes;

  /// The window sent back (its served fields).
  final MemberBanForm form;

  /// The changes the window offers.
  final List<ModcpBanChoice> choices;

  /// The body changing the member to [choice] for [days] (null for ever), with [reason].
  ///
  /// The window prints the member's signature in its reason box (a template slip, `forum/modcp_member.htm`): the box
  /// is never read, only the [reason] typed is sent.
  Map<String, String> body(ModcpBanChoice choice, {int? days, String reason = ''}) => {
    ...form.fields,
    'bannew': choice.value,
    'banexpirynew': !choice.isBan || days == null ? '' : '$days',
    'reason': reason.trim(),
    'bansubmit': 'true',
  };
}

/// What the panel's 禁止用户 or 编辑用户 page answered a search with.
final class ModcpMemberLookup {
  /// Constructor.
  const ModcpMemberLookup({required this.menu, this.member, this.edit, this.note = ''});

  /// The panel's menu on the page.
  final ModcpMenu menu;

  /// The member and the ban window (禁止用户), null when not found or not asked there.
  final ModcpMember? member;

  /// The edit window (编辑用户), null when not found or not asked there.
  final MemberEditForm? edit;

  /// Why no member was loaded, in the forum's words (the search form's caption: not found, staff of the forum); empty
  /// when one was, or when nothing was asked.
  final String note;
}

/// The search form's caption on page [doc]: why the member asked was not loaded.
String _caption(uh.Document doc) => _text(doc.querySelector('div.mdcp form caption'));

/// The 禁止用户 page [doc] served to [uid]; null when it is not that page.
ModcpMemberLookup? parseMemberBanPage(uh.Document doc, {required int uid}) {
  if (!isModcpPage(doc, 'member', 'ban')) {
    return null;
  }
  final menu = modcpMenuOf(doc) ?? const ModcpMenu({});
  for (final form in _formsOf(doc, 'member', 'ban')) {
    final fields = _hidden(form, memberBanServedFields);
    final memberUid = int.tryParse(fields['uid'] ?? '') ?? 0;
    if (memberUid <= 0 || (fields['formhash'] ?? '').isEmpty) {
      continue;
    }
    final choices = [
      for (final radio in form.querySelectorAll('input[type="radio"][name="bannew"]'))
        if (radio.attributes['value'] case final value? when const {'0', '4', '5'}.contains(value))
          ModcpBanChoice(value: value, label: _text(radio.parent)),
    ];
    final card = form.querySelector('table.tfm td.avt')?.nextElementSibling;
    final lines = card?.querySelectorAll('p') ?? const <uh.Element>[];
    final crimes = [
      // Each line in a `tbody` of its own (its id the record's), the header row outside.
      for (final row in form.querySelectorAll('table.dt tbody[id] tr'))
        if (row.querySelectorAll('td') case final cells when cells.length >= 4)
          ModcpCrime(
            action: _text(cells[0]),
            time: _text(cells[1]),
            reason: _text(cells[2]),
            operator: _text(cells[3]),
          ),
    ];
    return ModcpMemberLookup(
      menu: menu,
      member: ModcpMember(
        memberUid: memberUid,
        username: _text(card?.querySelector('a') ?? lines.firstOrNull),
        status: lines.length >= 3 ? _text(lines[2]) : '',
        crimes: crimes,
        form: MemberBanForm(
          memberUid: memberUid,
          uid: uid,
          fields: fields,
          banned: choices.any((e) => e.value == '0'),
        ),
        choices: choices,
      ),
    );
  }
  return ModcpMemberLookup(menu: menu, note: _caption(doc));
}

/// The hidden fields of the edit window sent back as they were served.
const memberEditServedFields = {'formhash', 'username', 'uid'};

/// The panel's 编辑用户 window of member [memberUid], served to account [uid]: the member's self-introduction and
/// signature as BBCode, and clearing the avatar.
///
/// The forum writes both texts every time it is sent (`member.php` op `edit`), so both are always sent back, changed
/// or as they were.
final class MemberEditForm {
  /// Constructor.
  const MemberEditForm({
    required this.memberUid,
    required this.username,
    required this.uid,
    required this.fields,
    required this.bio,
    required this.signature,
    this.v4 = false,
  });

  /// Read from the page of the forum's app API (plugin 4.0.0, `tsdmv=4`): a change is posted with [tsdmAppV4Query] too
  /// and told by what that answer holds.
  final bool v4;

  /// The member.
  final int memberUid;

  /// The name, as printed.
  final String username;

  /// The account the window was served to.
  final int uid;

  /// The hidden fields served ([memberEditServedFields]).
  final Map<String, String> fields;

  /// The self-introduction (自我介绍), as the window holds it.
  final String bio;

  /// The signature (个人签名), as the window holds it.
  final String signature;

  /// The url the window is posted to.
  static String get submitUrl => '$baseUrl/forum.php?mod=modcp&action=member&op=edit';

  /// The form body: both texts, and the avatar cleared when [clearAvatar].
  Map<String, String> body({required String bio, required String signature, bool clearAvatar = false}) => {
    ...fields,
    'bionew': bio,
    'signaturenew': signature,
    if (clearAvatar) 'clearavatar': '1',
    'editsubmit': 'true',
  };
}

/// The 编辑用户 page [doc] served to [uid]; null when it is not that page.
ModcpMemberLookup? parseMemberEditPage(uh.Document doc, {required int uid}) {
  if (!isModcpPage(doc, 'member', 'edit')) {
    return null;
  }
  final menu = modcpMenuOf(doc) ?? const ModcpMenu({});
  for (final form in _formsOf(doc, 'member', 'edit')) {
    final bio = form.querySelector('textarea[name="bionew"]');
    final signature = form.querySelector('textarea[name="signaturenew"]');
    final fields = _hidden(form, memberEditServedFields);
    final memberUid = int.tryParse(fields['uid'] ?? '') ?? 0;
    if (bio == null || signature == null || memberUid <= 0 || (fields['formhash'] ?? '').isEmpty) {
      continue;
    }
    return ModcpMemberLookup(
      menu: menu,
      edit: MemberEditForm(
        memberUid: memberUid,
        username: _text(form.querySelector('td.avt')?.nextElementSibling?.querySelector('a')),
        uid: uid,
        fields: fields,
        bio: _textareaValue(bio),
        signature: _textareaValue(signature),
      ),
    );
  }
  return ModcpMemberLookup(menu: menu, note: _caption(doc));
}

// ---------------------------------------------------------------------------------------------------------------------
// IP bans
// ---------------------------------------------------------------------------------------------------------------------

/// How long an IP ban can be chosen to last, in days; the forum bans for one day when none is given and has no ban
/// for ever.
const ipBanDays = <int>[1, 3, 7, 30, 90, 365];

/// One banned IP (or range), as the panel lists it.
final class IpBanEntry {
  /// Constructor.
  const IpBanEntry({
    required this.id,
    required this.ip,
    required this.location,
    required this.admin,
    required this.start,
    required this.end,
    required this.deletable,
  });

  /// The ban's id (`delete[]`).
  final String id;

  /// The IP or range, as printed.
  final String ip;

  /// Where it is, as the forum guessed.
  final String location;

  /// Who banned it.
  final String admin;

  /// From, as printed.
  final String start;

  /// Until, as printed.
  final String end;

  /// The panel offers to delete it: an administrator any, others their own only (the others' boxes `disabled`).
  final bool deletable;
}

/// The panel's 禁止 IP page, served to [uid].
final class IpBanList {
  /// Constructor.
  const IpBanList({
    required this.uid,
    required this.entries,
    required this.formHash,
    this.message = '',
    this.ipEcho = '',
    this.v4 = false,
  });

  /// Read from the page of the forum's app API (plugin 4.0.0, `tsdmv=4`): a change is posted with [tsdmAppV4Query] too
  /// and told by what that answer holds.
  final bool v4;

  /// The account the page was served to.
  final int uid;

  /// The bans, newest first.
  final List<IpBanEntry> entries;

  /// The form hash of the page's form.
  final String formHash;

  /// The panel's line after an add (an error, or 更新成功); empty otherwise.
  final String message;

  /// The IP the add box holds: the one sent back when adding it failed, empty otherwise.
  final String ipEcho;

  /// The url of the page.
  static String get url => '$baseUrl/forum.php?mod=modcp&action=member&op=ipban';

  /// The body adding [ip] for [days].
  Map<String, String> addBody(String ip, int days) => {
    'formhash': formHash,
    'ipnew': ip.trim(),
    'validitynew': '$days',
    'ipbansubmit': 'true',
  };

  /// The body deleting the bans [ids]. The others' end dates are not sent: the forum never applies them anyway.
  Map<String, String> deleteBody(List<String> ids) => {
    'formhash': formHash,
    for (final (i, id) in ids.indexed) 'delete[$i]': id,
    'ipbansubmit': 'true',
  };
}

/// The 禁止 IP page [doc] served to [uid]; null when it is not that page.
IpBanList? parseIpBanList(uh.Document doc, {required int uid}) {
  if (!isModcpPage(doc, 'member', 'ipban')) {
    return null;
  }
  final form = _formsOf(
    doc,
    'member',
    'ipban',
  ).where((e) => e.querySelector('input[name="ipnew"]') != null).firstOrNull;
  final formHash = form?.querySelector('input[name="formhash"]')?.attributes['value'] ?? '';
  if (form == null || formHash.isEmpty) {
    return null;
  }
  final entries = <IpBanEntry>[];
  for (final row in form.querySelectorAll('table.dt tr')) {
    final box = row.querySelector('input[type="checkbox"][name="delete[]"]');
    final cells = row.querySelectorAll('td');
    final id = box?.attributes['value'] ?? '';
    if (box == null || int.tryParse(id) == null || cells.length < 6) {
      continue;
    }
    entries.add(
      IpBanEntry(
        id: id,
        ip: _text(cells[1]),
        location: _text(cells[2]),
        admin: _text(cells[3]),
        start: _text(cells[4]),
        end: (cells[5].querySelector('input')?.attributes['value'] ?? _text(cells[5])).trim(),
        deletable: !box.attributes.containsKey('disabled'),
      ),
    );
  }
  return IpBanList(
    uid: uid,
    entries: entries,
    formHash: formHash,
    message: _besideButton(form.querySelector('div.exfm'), 'ipbansubmit'),
    ipEcho: (form.querySelector('input[name="ipnew"]')?.attributes['value'] ?? '').trim(),
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// New members waiting for approval
// ---------------------------------------------------------------------------------------------------------------------

/// What a moderator does to new members waiting (`modact`).
enum MemberReviewAction {
  /// Let them in (通过).
  validate,

  /// Turn them down (否决): they stay waiting in the list of those refused.
  ignore,

  /// Delete the accounts (删除), offered for those of the group waiting for approval only.
  delete,
}

/// A new member waiting for approval, as the panel lists it.
final class MemberReviewItem {
  /// Constructor.
  const MemberReviewItem({
    required this.id,
    required this.username,
    required this.regDate,
    required this.regIp,
    required this.reason,
    required this.canDelete,
  });

  /// The member's uid (`moderate[]`).
  final String id;

  /// The name.
  final String username;

  /// When the account was made, as printed.
  final String regDate;

  /// From where.
  final String regIp;

  /// Why the member wants in (注册原因), as printed.
  final String reason;

  /// The panel offers deleting the account (its 删除 link, for the group waiting for approval only).
  final bool canDelete;
}

/// One page of the new members waiting for approval (审核 › 用户), served to [uid].
final class MemberReviewList {
  /// Constructor.
  const MemberReviewList({
    required this.uid,
    required this.items,
    required this.formHash,
    this.page = 1,
    this.hasNext = false,
    this.v4 = false,
  });

  /// Read from the page of the forum's app API (plugin 4.0.0, `tsdmv=4`): a change is posted with [tsdmAppV4Query] too
  /// and told by what that answer holds.
  final bool v4;

  /// The account the page was served to.
  final int uid;

  /// The members waiting, newest first.
  final List<MemberReviewItem> items;

  /// The form hash of the page.
  final String formHash;

  /// The page number.
  final int page;

  /// The forum links a next page.
  final bool hasNext;

  /// The url of page [page] of the members waiting (`filter` 0).
  static String url({int page = 1}) =>
      '$baseUrl/forum.php?mod=modcp&action=moderate&op=members&filter=0${page > 1 ? '&page=$page' : ''}';

  /// The url the operations are posted to: the forum answers with its message (审核处理完毕 when at least one of
  /// those sent was one it could handle).
  static String get submitUrl => '$baseUrl/forum.php?mod=modcp&action=moderate&op=members';

  /// The body of [action] on the members [ids] with [reason].
  Map<String, String> body(MemberReviewAction action, List<String> ids, {String reason = ''}) => {
    'formhash': formHash,
    'filter': '0',
    'modact': action.name,
    'modsubmit': '1',
    for (final (i, id) in ids.indexed) 'moderate[$i]': id,
    'reason': reason.trim(),
  };
}

/// The value after the label of a line `label: value`.
String _valueOf(uh.Element? line) {
  final text = _text(line);
  final at = text.indexOf(': ');
  return at < 0 ? text : text.substring(at + 2).trim();
}

/// The list of new members waiting on page [doc], served to [uid]; null when it is not that page.
MemberReviewList? parseMemberReview(uh.Document doc, {required int uid, int page = 1}) {
  if (!isModcpPage(doc, 'moderate', 'members')) {
    return null;
  }
  final formHash =
      _formsOf(doc, 'moderate', 'members')
          .map((e) => e.querySelector('input[name="formhash"]')?.attributes['value'] ?? '')
          .where((e) => e.isNotEmpty)
          .firstOrNull ??
      '';
  if (formHash.isEmpty) {
    return null;
  }
  final items = <MemberReviewItem>[];
  for (final row in doc.querySelectorAll('form#moderate tr')) {
    final id = row.querySelector('input[type="checkbox"][name="moderate[]"]')?.attributes['value'] ?? '';
    final cells = row.querySelectorAll('td');
    if (int.tryParse(id) == null || cells.length < 3) {
      continue;
    }
    final lines = cells[1].querySelectorAll('p');
    items.add(
      MemberReviewItem(
        id: id,
        username: _text(cells[1].querySelector('h5')),
        regDate: lines.isNotEmpty ? _valueOf(lines[0]) : '',
        regIp: lines.length > 1 ? _valueOf(lines[1]) : '',
        reason: _text(cells[2]),
        canDelete: row.querySelectorAll('a').any((e) => (e.attributes['href'] ?? '').contains('modact=delete')),
      ),
    );
  }
  return MemberReviewList(
    uid: uid,
    items: items,
    formHash: formHash,
    page: page,
    hasNext: doc.querySelector('div.pg a.nxt') != null,
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Forum rules
// ---------------------------------------------------------------------------------------------------------------------

/// The panel's 版块编辑 page of forum [fid] (本版规则), served to [uid].
///
/// [fid] is 0 when the page holds no forum the account moderates (the panel then prints an empty column).
final class ForumRules {
  /// Constructor.
  const ForumRules({
    required this.uid,
    required this.fid,
    required this.forums,
    this.rules = '',
    this.editable = false,
    this.note = '',
    this.message = '',
    this.formHash = '',
    this.v4 = false,
  });

  /// Read from the page of the forum's app API (plugin 4.0.0, `tsdmv=4`): a change is posted with [tsdmAppV4Query] too
  /// and told by what that answer holds.
  final bool v4;

  /// The account the page was served to.
  final int uid;

  /// The forum, 0 for none.
  final int fid;

  /// The forums the panel offers in its select.
  final List<ModcpForum> forums;

  /// The rules as BBCode, as the editor holds them.
  final String rules;

  /// The panel lets the account change them (an administrator, or a forum allowing its moderators to); otherwise the
  /// editor is `disabled` and a post changes nothing.
  final bool editable;

  /// Why the rules can not be changed, in the forum's words; empty when they can.
  final String note;

  /// The panel's line after a post (版规更新成功, printed even when nothing was changed).
  final String message;

  /// The form hash of the editor's form.
  final String formHash;

  /// The url of the rules of forum [fid]; without one the panel sends the account on to the forum it chose last, or
  /// its first.
  static String url({int fid = 0}) =>
      '$baseUrl/forum.php?mod=modcp&action=forum&op=editforum${fid > 0 ? '&fid=$fid' : ''}';

  /// The url the rules are posted to.
  static String get submitUrl => '$baseUrl/forum.php?mod=modcp&action=forum&op=editforum';

  /// The body saving [rules].
  Map<String, String> body(String rules) => {
    'formhash': formHash,
    'fid': '$fid',
    'rulesnew': rules,
    'editsubmit': 'true',
  };
}

/// The rules on page [doc], served to [uid]; null when it is not the panel's 版块编辑 page.
ForumRules? parseForumRules(uh.Document doc, {required int uid}) {
  if (!isModcpPage(doc, 'forum', 'editforum')) {
    return null;
  }
  final (forums, selected) = modcpForums(doc);
  final form = _formsOf(
    doc,
    'forum',
    'editforum',
  ).where((e) => e.querySelector('textarea[name="rulesnew"]') != null).firstOrNull;
  final fid = int.tryParse(form?.querySelector('input[name="fid"]')?.attributes['value'] ?? '') ?? 0;
  final formHash = form?.querySelector('input[name="formhash"]')?.attributes['value'] ?? '';
  if (form == null || fid <= 0 || formHash.isEmpty || (selected > 0 && selected != fid)) {
    // A forum the account does not moderate: the panel prints nothing in place of the editor.
    return ForumRules(uid: uid, fid: 0, forums: forums);
  }
  final editor = form.querySelector('textarea[name="rulesnew"]')!;
  final editable = !editor.attributes.containsKey('disabled') && !editor.attributes.containsKey('readonly');
  return ForumRules(
    uid: uid,
    fid: fid,
    forums: forums,
    rules: _textareaValue(editor),
    editable: editable,
    // The editor's frame (`div.tedt`) is followed by the forum's words when it is locked.
    note: editable ? '' : _text(editor.parent?.parent?.nextElementSibling),
    message: _besideButton(form, 'editsubmit'),
    formHash: formHash,
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Announcements
// ---------------------------------------------------------------------------------------------------------------------

/// What an announcement is (`type`).
enum AnnouncementType {
  /// Text (文字类型, BBCode).
  text,

  /// A link (网址链接): the message is an `http(s)://` address.
  link,
}

/// One announcement, as the panel lists it.
final class AnnouncementItem {
  /// Constructor.
  const AnnouncementItem({
    required this.id,
    required this.author,
    required this.subject,
    required this.type,
    required this.start,
    required this.end,
    required this.deletable,
  });

  /// The announcement's id.
  final String id;

  /// Who posted it.
  final String author;

  /// The subject, as printed.
  final String subject;

  /// Text or link, as printed.
  final String type;

  /// From, as printed (`-` for none).
  final String start;

  /// Until, as printed (`-` for none).
  final String end;

  /// The panel offers to delete it: the account's own (the others' boxes `disabled`).
  final bool deletable;
}

/// The panel's 公告 page, served to [uid]: the announcements and the form adding one.
final class AnnouncementList {
  /// Constructor.
  const AnnouncementList({
    required this.uid,
    required this.items,
    required this.formHash,
    this.blank,
    this.message = '',
    this.v4 = false,
  });

  /// Read from the page of the forum's app API (plugin 4.0.0, `tsdmv=4`): a change is posted with [tsdmAppV4Query] too
  /// and told by what that answer holds.
  final bool v4;

  /// The account the page was served to.
  final int uid;

  /// The announcements, in the forum's order.
  final List<AnnouncementItem> items;

  /// The form hash of the list's form.
  final String formHash;

  /// The form adding one, with the forum's default dates.
  final AnnouncementForm? blank;

  /// The panel's line under the list (选定公告删除完毕) or under the form (公告添加完毕); empty when none.
  final String message;

  /// The url of the page.
  static String get url => '$baseUrl/forum.php?mod=modcp&action=announcement';

  /// The url deletions are posted to. The forum answers with the list again.
  static String get deleteUrl => '$baseUrl/forum.php?mod=modcp&action=announcement&op=manage';

  /// The body deleting [ids]. The order boxes are not sent: the forum would set the order of the announcements to what
  /// they say.
  Map<String, String> deleteBody(List<String> ids) => {
    'formhash': formHash,
    for (final (i, id) in ids.indexed) 'delete[$i]': id,
    'submit': 'true',
  };
}

/// The panel's form of one announcement: a new one (`id` 0) or one being edited, served to [uid].
final class AnnouncementForm {
  /// Constructor.
  const AnnouncementForm({
    required this.uid,
    required this.id,
    required this.formHash,
    required this.subject,
    required this.type,
    required this.start,
    required this.end,
    required this.message,
    this.displayOrder = '',
    this.notice = '',
    this.v4 = false,
  });

  /// Read from the page of the forum's app API (plugin 4.0.0, `tsdmv=4`): a change is posted with [tsdmAppV4Query] too
  /// and told by what that answer holds.
  final bool v4;

  /// The account the form was served to.
  final int uid;

  /// The announcement, 0 for a new one.
  final int id;

  /// The form hash.
  final String formHash;

  /// The subject.
  final String subject;

  /// Text or link.
  final AnnouncementType type;

  /// From (`Y-n-j`), empty for now.
  final String start;

  /// Until (`Y-n-j`), empty for none.
  final String end;

  /// The text, or the link.
  final String message;

  /// The order kept as served.
  final String displayOrder;

  /// The panel's line beside its button after a post (公告设置更新完毕); empty otherwise.
  final String notice;

  /// The url of the form of announcement [id].
  static String url(int id) => '$baseUrl/forum.php?mod=modcp&action=announcement&op=edit&id=$id';

  /// The url the form is posted to.
  String get submitUrl => '$baseUrl/forum.php?mod=modcp&action=announcement&op=${id > 0 ? 'edit' : 'add'}';

  /// The body of the form filled in.
  Map<String, String> body({
    required String subject,
    required AnnouncementType type,
    required String start,
    required String end,
    required String message,
  }) => {
    'formhash': formHash,
    'id': id > 0 ? '$id' : '',
    'displayorder': displayOrder,
    'subject': subject.trim(),
    'type': '${type.index}',
    'starttime': start.trim(),
    'endtime': end.trim(),
    'message[0]': type == AnnouncementType.text ? message : '',
    'message[1]': type == AnnouncementType.link ? message.trim() : '',
    'submit': 'true',
  };

  /// Whether this form holds what was sent: the [subject], the [type] and the [message] as the forum keeps them (a link
  /// cut to its first line).
  ///
  /// The dates are compared only where the forum keeps them as sent: a start after [today] (an earlier one becomes
  /// the moment saved), an end after both (an earlier one becomes 30 days after the start). A day of margin: the
  /// forum's today may not be the device's.
  bool holds({
    required String subject,
    required AnnouncementType type,
    required String message,
    String start = '',
    String end = '',
    DateTime? today,
  }) {
    final now = today ?? DateTime.now();
    final day = DateTime(now.year, now.month, now.day + 1);
    final sentStart = announcementDate(start);
    final sentEnd = announcementDate(end);
    final keptStart = sentStart != null && sentStart.isAfter(day);
    final keptEnd = sentEnd != null && sentEnd.isAfter(day) && (sentStart == null || sentEnd.isAfter(sentStart));
    return this.subject.trim() == subject.trim() &&
        this.type == type &&
        modcpNormalized(this.message) ==
            modcpNormalized(type == AnnouncementType.link ? message.split('\n').first : message) &&
        (!keptStart || announcementDate(this.start) == sentStart) &&
        (!keptEnd || announcementDate(this.end) == sentEnd);
  }
}

/// A date of an announcement as the forum prints it (`2026-12-1`) or the app sends it (`2026-12-01`); null for none.
DateTime? announcementDate(String text) {
  final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(text.trim());
  if (match == null) {
    return null;
  }
  return DateTime(int.parse(match.group(1)!), int.parse(match.group(2)!), int.parse(match.group(3)!));
}

AnnouncementForm? _announcementForm(uh.Element? form, {required int uid}) {
  if (form == null) {
    return null;
  }
  final formHash = form.querySelector('input[name="formhash"]')?.attributes['value'] ?? '';
  final subject = form.querySelector('input[name="subject"]');
  if (formHash.isEmpty || subject == null) {
    return null;
  }
  final type = form.querySelector('select[name="type"] option[selected]')?.attributes['value'] == '1'
      ? AnnouncementType.link
      : AnnouncementType.text;
  String value(String name) => (form.querySelector('input[name="$name"]')?.attributes['value'] ?? '').trim();
  return AnnouncementForm(
    uid: uid,
    id: int.tryParse(value('id')) ?? 0,
    formHash: formHash,
    subject: subject.attributes['value'] ?? '',
    type: type,
    start: value('starttime'),
    end: value('endtime'),
    message: type == AnnouncementType.link
        ? value('message[1]')
        : _textareaValue(form.querySelector('textarea[name="message[0]"]')),
    displayOrder: value('displayorder'),
    notice: _besideButton(form, 'submit'),
  );
}

/// The announcements on page [doc], served to [uid]; null when it is not the panel's 公告 page with its list.
AnnouncementList? parseAnnouncements(uh.Document doc, {required int uid}) {
  if (!isModcpPage(doc, 'announcement')) {
    return null;
  }
  final listForm = _formsOf(doc, 'announcement', 'manage').firstOrNull;
  final formHash = listForm?.querySelector('input[name="formhash"]')?.attributes['value'] ?? '';
  if (listForm == null || formHash.isEmpty) {
    return null;
  }
  final items = <AnnouncementItem>[];
  for (final row in listForm.querySelectorAll('tr')) {
    final box = row.querySelector('input[type="checkbox"][name="delete[]"]');
    final cells = row.querySelectorAll('td');
    final id = box?.attributes['value'] ?? '';
    if (box == null || int.tryParse(id) == null || cells.length < 7) {
      continue;
    }
    items.add(
      AnnouncementItem(
        id: id,
        author: _text(cells[2]),
        subject: _text(cells[3]),
        type: _text(cells[4]),
        start: _text(cells[5]),
        end: _text(cells[6]),
        deletable: !box.attributes.containsKey('disabled'),
      ),
    );
  }
  final blank = _announcementForm(_formsOf(doc, 'announcement', 'add').firstOrNull, uid: uid);
  final deleted = _besideButton(listForm.querySelector('tr.bw0_all'), 'submit');
  return AnnouncementList(
    uid: uid,
    items: items,
    formHash: formHash,
    blank: blank,
    message: deleted.isNotEmpty ? deleted : (blank?.notice ?? ''),
  );
}

/// The form of announcement [id] on page [doc], served to [uid]; null when it is not that form.
AnnouncementForm? parseAnnouncementForm(uh.Document doc, {required int id, required int uid}) {
  if (!isModcpPage(doc, 'announcement')) {
    return null;
  }
  final form = _announcementForm(_formsOf(doc, 'announcement', 'edit').firstOrNull, uid: uid);
  return form != null && form.id == id ? form : null;
}

// ---------------------------------------------------------------------------------------------------------------------
// Outcomes
// ---------------------------------------------------------------------------------------------------------------------

/// How the panel answered a change sent from these pages, told by what its answer holds afterwards: most of them
/// draw the page again and say nothing, or say the same whether anything changed or not.
sealed class ModcpWriteOutcome {
  const ModcpWriteOutcome();
}

/// Carried out: all [count] items; [message] is the forum's words when it gave some.
final class ModcpWriteDone extends ModcpWriteOutcome {
  /// Constructor.
  const ModcpWriteDone({this.count = 1, this.message = ''});

  /// How many.
  final int count;

  /// The forum's message, empty when none.
  final String message;
}

/// The page still lists [remaining] of the items sent: those were not done, the [done] others were.
final class ModcpWriteNotDone extends ModcpWriteOutcome {
  /// Constructor.
  const ModcpWriteNotDone({required this.done, required this.remaining});

  /// How many were done.
  final int done;

  /// The items still listed.
  final List<String> remaining;
}

/// Sent, and the panel answered, but what it holds now could not be read: it may have been done.
final class ModcpWriteUnknown extends ModcpWriteOutcome {
  /// Constructor.
  const ModcpWriteUnknown();
}

/// The panel showed its login form: its session ended, nothing was done.
final class ModcpWriteSessionEnded extends ModcpWriteOutcome {
  /// Constructor.
  const ModcpWriteSessionEnded();
}

/// Not done: the panel refused, in its own words [message] (empty when it gave none, or the answer showed nothing
/// changed).
final class ModcpWriteRefused extends ModcpWriteOutcome {
  /// Constructor.
  const ModcpWriteRefused(this.message);

  /// The forum's message.
  final String message;
}
