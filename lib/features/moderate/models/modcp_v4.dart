import 'package:tsdm_client/features/moderate/models/member_ban.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The pages of the moderation panel the forum's app API answers as fields with `tsdmv=4` (plugin 4.0.0, `status`
/// `modcp_pages_v4`): the moderation queue and the new members (`modcp_moderate`, `schema` 42), banning and editing a
/// member (`modcp_member`, 43), the IP bans (`modcp_ipban`, 44), the recycle bins (`modcp_recyclebin` and
/// `modcp_recyclebinpost`, 45), the forum rules (`modcp_editforum`, 46) and the announcements (`modcp_announcement`,
/// 47).
///
/// Each one is read into the model the page's web parser makes, the texts the web page prints made the same way (a
/// time in the forum's clock and the page's format), so the screens show what they showed. Values reflected from the
/// request (`submit.fields`) are only ever sent back.

/// The `status` name (`modcp_pages_v4`), the answer's `type` and `schema` of each page of plugin 4.0.0.
enum ModcpV4Page {
  /// The moderation queue: threads, replies, new members.
  moderate('moderate', 'modcp_moderate', 42),

  /// Banning (`op=ban`) and editing (`op=edit`) a member.
  member('member', 'modcp_member', 43),

  /// The IP bans.
  ipban('ipban', 'modcp_ipban', 44),

  /// The recycle bin of threads.
  recyclebin('recyclebin', 'modcp_recyclebin', 45),

  /// The recycle bin of replies.
  recyclebinpost('recyclebinpost', 'modcp_recyclebinpost', 45),

  /// The forum rules.
  editforum('editforum', 'modcp_editforum', 46),

  /// The announcements.
  announcement('announcement', 'modcp_announcement', 47)
  ;

  const ModcpV4Page(this.name, this.type, this.schema);

  /// The name in `status` (`modcp_pages_v4`).
  final String name;

  /// The `type` of the answer.
  final String type;

  /// The `schema` of the answer.
  final int schema;

  /// The page of recycle bin [kind].
  static ModcpV4Page bin(RecycleBinKind kind) => switch (kind) {
    RecycleBinKind.threads => recyclebin,
    RecycleBinKind.posts => recyclebinpost,
  };
}

/// Time [value] (unix seconds) of an answer with offset [offset] printed as the web page prints it with PHP's
/// [format] (`Y`, `m`, `n`, `d`, `j`, `H`, `i`, `s`; anything else as it is) in the forum's clock; empty for none.
String modcpTimeText(Object? value, num offset, String format) {
  final t = tsdmAppWallClockTime(value, offset);
  if (t == null) {
    return '';
  }
  String two(int n) => n.toString().padLeft(2, '0');
  final buffer = StringBuffer();
  for (final c in format.split('')) {
    buffer.write(switch (c) {
      'Y' => '${t.year}',
      'm' => two(t.month),
      'n' => '${t.month}',
      'd' => two(t.day),
      'j' => '${t.day}',
      'H' => two(t.hour),
      'i' => two(t.minute),
      's' => two(t.second),
      _ => c,
    });
  }
  return buffer.toString();
}

/// The forum's default date (`dgmdate(…, 'd')`).
const _date = 'Y-n-j';

/// The forum's default time (`dgmdate(…)`).
const _dateTime = 'Y-n-j H:i';

String _text(Object? value) => switch (value) {
  final String s => s,
  final num n => '$n',
  _ => '',
};

/// [value] with its runs of white space as one space, trimmed: as the web parsers read a cell.
String _cell(Object? value) => _text(value).replaceAll(RegExp(r'\s+'), ' ').trim();

/// The offset (hours) of an answer; `timeoffset` may come as text.
num _offset(Map<String, dynamic> json) => switch (json['timeoffset']) {
  final num n => n,
  final String s => num.tryParse(s.trim()) ?? 8,
  _ => 8,
};

/// The panel's menu of an answer (`menu[]`: `action` or `action/op`, as [ModcpMenu] holds them).
ModcpMenu modcpMenuFromApi(Map<String, dynamic> json) => ModcpMenu({
  for (final entry in json['menu'] is List ? json['menu'] as List : const []) ?(entry is String ? entry : null),
});

/// The forums of the panel's forum select of an answer (`forums[]`).
List<ModcpForum> modcpForumsFromApi(Map<String, dynamic> json) => [
  for (final forum in tsdmAppList(json['forums']))
    if (tsdmAppInt(forum['fid']) case final fid when fid > 0) ModcpForum(fid: fid, name: _text(forum['name']).trim()),
];

/// The fields of [submit] (the form of a page) named in [names], as served.
Map<String, String> _served(Object? submit, Set<String> names) => {
  for (final MapEntry(:key, :value) in tsdmAppMap(tsdmAppMap(submit)['fields']).entries)
    if (names.contains(key)) key: _text(value),
};

bool _hasNext(Map<String, dynamic> json) => tsdmAppInt(json['page']) < tsdmAppInt(json['pages']);

// ---------------------------------------------------------------------------------------------------------------------
// The moderation queue (42)
// ---------------------------------------------------------------------------------------------------------------------

/// List [kind] of the queue of forum [fid] in page answer [json] (`modcp_moderate`), served to [uid], as
/// [parseModerateQueue] reads it; null when it is another list or forum.
ModerateQueueList? moderateQueueFromApi(
  Map<String, dynamic> json,
  ModerateQueueKind kind, {
  required int fid,
  required int uid,
  int page = 1,
}) {
  // The forum asked is taken only when the panel lists it (its name given): another is answered with every forum's
  // items, as the web page selects none.
  if (json['op'] != kind.name ||
      tsdmAppInt(json['fid']) != fid ||
      (fid > 0 && (_text(json['forum']).isEmpty || !modcpForumsFromApi(json).any((e) => e.fid == fid)))) {
    return null;
  }
  final offset = _offset(json);
  final items = [
    for (final item in tsdmAppList(json['items']))
      if (tsdmAppInt(item['id']) case final id when id > 0)
        ModerateQueueItem(
          id: '$id',
          subject: _text(item['thread_subject']).trim(),
          author: _text(item['author']).trim(),
          authorUid: tsdmAppInt(item['authorid']) > 0 ? tsdmAppInt(item['authorid']) : null,
          time: modcpTimeText(item['dateline'], offset, _dateTime),
          message: _text(item['message']).trim(),
        ),
  ];
  final served = _served(json['submit'], moderateQueueServedFields);
  if (items.isNotEmpty && (served['formhash'] ?? '').isEmpty) {
    return null;
  }
  return ModerateQueueList(
    kind: kind,
    fid: fid,
    items: items,
    // As the web page: no form when nothing waits. The forum's own form names its forum.
    fields: items.isEmpty ? const {} : {...served, 'fid': '$fid'},
    uid: uid,
    page: page,
    hasNext: _hasNext(json),
    v4: true,
  );
}

/// The new members waiting (`op=members`, `filter` 0) in page answer [json], served to [uid], as [parseMemberReview]
/// reads them; null when it is another list.
MemberReviewList? memberReviewFromApi(Map<String, dynamic> json, {required int uid, int page = 1}) {
  final formHash = _served(json['submit'], const {'formhash'})['formhash'] ?? '';
  // No form needed while nobody waits (the web page prints none then either).
  if (json['op'] != 'members' ||
      tsdmAppInt(json['filter']) != 0 ||
      (formHash.isEmpty && tsdmAppList(json['members']).isNotEmpty)) {
    return null;
  }
  final offset = _offset(json);
  return MemberReviewList(
    uid: uid,
    items: [
      for (final member in tsdmAppList(json['members']))
        if (tsdmAppInt(member['uid']) case final id when id > 0)
          MemberReviewItem(
            id: '$id',
            username: _cell(member['username']),
            regDate: modcpTimeText(member['regdate'], offset, _dateTime),
            regIp: _cell(member['regip']),
            reason: _cell(member['message']),
            canDelete: member['can_delete'] == 1,
          ),
    ],
    formHash: formHash,
    page: page,
    hasNext: _hasNext(json),
    v4: true,
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Members (43)
// ---------------------------------------------------------------------------------------------------------------------

/// The state of member [member] as the ban page prints it: the state, and the day a ban ends.
String _memberStatus(Map<String, dynamic> member, num offset) {
  final status = _cell(member['status_text']);
  final expiry = modcpTimeText(member['banexpiry'], offset, _date);
  return expiry.isEmpty ? status : '$status ( ${t.modcp.validUntil(date: expiry)} )';
}

/// What the ban (`op=ban`) or edit (`op=edit`, when [edit]) page answer [json] holds, served to [uid], as
/// [parseMemberBanPage] or [parseMemberEditPage] reads it; null when it is the other page.
ModcpMemberLookup? memberLookupFromApi(Map<String, dynamic> json, {required int uid, bool edit = false}) {
  if (json['op'] != (edit ? 'edit' : 'ban')) {
    return null;
  }
  final menu = modcpMenuFromApi(json);
  final note = switch (_text(json['error_key'])) {
    'nouser' => t.modcp.memberNotFound,
    'staff' => t.modcp.memberIsStaff,
    _ => '',
  };
  final member = tsdmAppMap(json['member']);
  final memberUid = tsdmAppInt(member['uid']);
  if (memberUid <= 0) {
    return ModcpMemberLookup(menu: menu, note: note);
  }
  if (edit) {
    final window = tsdmAppMap(json['edit']);
    final fields = _served(window['submit'], memberEditServedFields);
    if (window.isEmpty || fields['uid'] != '$memberUid' || (fields['formhash'] ?? '').isEmpty) {
      return ModcpMemberLookup(menu: menu, note: note);
    }
    return ModcpMemberLookup(
      menu: menu,
      edit: MemberEditForm(
        memberUid: memberUid,
        username: _cell(member['username']),
        uid: uid,
        fields: fields,
        bio: _text(window['bio']),
        signature: _text(window['signature']),
        v4: true,
      ),
    );
  }
  final form = memberBanFormFromApi(json, memberUid: memberUid, uid: uid, any: true);
  if (form == null) {
    return ModcpMemberLookup(menu: menu, note: note);
  }
  final ban = tsdmAppMap(json['ban']);
  final offset = _offset(json);
  return ModcpMemberLookup(
    menu: menu,
    member: ModcpMember(
      memberUid: memberUid,
      username: _cell(member['username']),
      status: _memberStatus(member, offset),
      crimes: [
        for (final crime in tsdmAppList(ban['crimes']))
          ModcpCrime(
            action: _cell(crime['action_text']),
            time: modcpTimeText(crime['dateline'], offset, 'Y-m-d H:i'),
            reason: _cell(crime['reason']),
            operator: _cell(crime['operator']),
          ),
      ],
      form: form,
      choices: _banChoices(ban),
    ),
  );
}

List<ModcpBanChoice> _banChoices(Map<String, dynamic> ban) => [
  for (final choice in tsdmAppList(ban['choices']))
    if (_text(choice['value']) case final value when const {'0', '4', '5'}.contains(value))
      ModcpBanChoice(value: value, label: _cell(choice['label'])),
];

/// The ban window of member [memberUid] in the ban page answer [json] (`op=ban`), served to [uid], as
/// [MemberBanForm.parse] reads it: null when it holds no window of that member, or one offering neither the ban from
/// posting nor its lifting (unless [any], the panel's page, which offers what it offers).
MemberBanForm? memberBanFormFromApi(
  Map<String, dynamic> json, {
  required int memberUid,
  required int uid,
  bool any = false,
}) {
  final ban = tsdmAppMap(json['ban']);
  final fields = _served(tsdmAppMap(ban)['submit'], memberBanServedFields);
  if (json['op'] != 'ban' ||
      tsdmAppInt(tsdmAppMap(json['member'])['uid']) != memberUid ||
      fields['uid'] != '$memberUid' ||
      (fields['formhash'] ?? '').isEmpty) {
    return null;
  }
  final values = {for (final choice in _banChoices(ban)) choice.value};
  final banned = values.contains('0');
  if (!any && !banned && !values.contains('4')) {
    return null;
  }
  return MemberBanForm(memberUid: memberUid, uid: uid, fields: fields, banned: banned, v4: true);
}

// ---------------------------------------------------------------------------------------------------------------------
// IP bans (44)
// ---------------------------------------------------------------------------------------------------------------------

/// The IP bans in page answer [json] (`modcp_ipban`), served to [uid], as [parseIpBanList] reads them: the line the
/// web page prints after an add that failed ([IpBanList.message]) told by `result.error_key`.
IpBanList? ipBanListFromApi(Map<String, dynamic> json, {required int uid}) {
  final formHash = _served(json['submit'], const {'formhash'})['formhash'] ?? '';
  if (formHash.isEmpty) {
    return null;
  }
  final offset = _offset(json);
  final result = tsdmAppMap(json['result']);
  return IpBanList(
    uid: uid,
    entries: [
      for (final ban in tsdmAppList(json['list']))
        if (tsdmAppInt(ban['id']) case final id when id > 0)
          IpBanEntry(
            id: '$id',
            ip: _cell(ban['ip']),
            location: _cell(ban['location']),
            admin: _cell(ban['admin']),
            start: modcpTimeText(ban['dateline'], offset, _date),
            end: modcpTimeText(ban['expiration'], offset, _date),
            deletable: ban['can_delete'] == 1,
          ),
    ],
    formHash: formHash,
    message: ipBanErrorText(_text(result['error_key'])),
    ipEcho: _text(json['ip']).trim(),
    v4: true,
  );
}

/// What to tell of an add the panel refused by `result.error_key` [key] (`format`, `cidr`, `exists`); empty for none.
String ipBanErrorText(String key) => switch (key) {
  'format' => t.modcp.ipBanFormat,
  'cidr' => t.modcp.ipBanCidr,
  'exists' => t.modcp.ipBanExists,
  _ => '',
};

// ---------------------------------------------------------------------------------------------------------------------
// Recycle bins (45)
// ---------------------------------------------------------------------------------------------------------------------

/// Bin [kind] of forum [fid] in page answer [json], served to [uid], as [parseRecycleBin] reads it: the bin without a
/// forum (its `fid` 0) when the forum asked is not taken (none asked, not the account's, no bin there).
RecycleBinList? recycleBinFromApi(
  Map<String, dynamic> json,
  RecycleBinKind kind, {
  required int fid,
  required int uid,
  int page = 1,
}) {
  final forums = modcpForumsFromApi(json);
  if (fid <= 0 || tsdmAppInt(json['fid']) != fid || json['enabled'] != 1 || json['need_forum'] == 1) {
    return RecycleBinList(
      kind: kind,
      fid: 0,
      forums: forums,
      items: const [],
      fields: const {},
      uid: uid,
      v4: true,
    );
  }
  final offset = _offset(json);
  final items = switch (kind) {
    RecycleBinKind.threads => [
      for (final thread in tsdmAppList(json['threads']))
        if (tsdmAppInt(thread['tid']) case final tid when tid > 0)
          RecycleBinItem(
            id: '$tid',
            title: _cell(thread['subject']),
            author: _cell(thread['author']),
            authorUid: tsdmAppInt(thread['authorid']) > 0 ? tsdmAppInt(thread['authorid']) : null,
            time: modcpTimeText(thread['dateline'], offset, _date),
            reason: _cell(thread['reason']),
            replies: '${tsdmAppInt(thread['replies'])}',
            views: '${tsdmAppInt(thread['views'])}',
          ),
    ],
    RecycleBinKind.posts => [
      for (final post in tsdmAppList(json['posts']))
        if (tsdmAppInt(post['pid']) case final pid when pid > 0)
          RecycleBinItem(
            id: '$pid',
            title: _cell(post['message']),
            author: _cell(post['author']),
            authorUid: tsdmAppInt(post['authorid']) > 0 ? tsdmAppInt(post['authorid']) : null,
            time: modcpTimeText(post['dateline'], offset, 'Y-m-d H:i:s'),
            tid: tsdmAppInt(post['tid']) > 0 ? '${tsdmAppInt(post['tid'])}' : null,
          ),
    ],
  };
  final submit = tsdmAppMap(json['submit']);
  final served = _served(submit, recycleBinServedFields);
  if (items.isNotEmpty && (served['formhash'] ?? '').isEmpty) {
    return null;
  }
  final actions = {for (final action in submit['actions'] is List ? submit['actions'] as List : const []) '$action'};
  return RecycleBinList(
    kind: kind,
    fid: fid,
    forums: forums,
    items: items,
    // As the web page: no form when the bin is empty.
    fields: items.isEmpty ? const {} : served,
    uid: uid,
    canDelete: items.isNotEmpty && json['can_delete'] == 1 && actions.contains('delete'),
    page: page,
    hasNext: _hasNext(json),
    v4: true,
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Forum rules (46)
// ---------------------------------------------------------------------------------------------------------------------

/// The rules in page answer [json] (`modcp_editforum`), served to [uid], as [parseForumRules] reads them: a forum the
/// account does not moderate is the rules without a forum (`fid` 0).
ForumRules? forumRulesFromApi(Map<String, dynamic> json, {required int uid}) {
  final forums = modcpForumsFromApi(json);
  final fid = tsdmAppInt(json['fid']);
  final fields = _served(json['submit'], const {'formhash', 'fid'});
  if (json['need_forum'] == 1 || fid <= 0 || fields['fid'] != '$fid' || (fields['formhash'] ?? '').isEmpty) {
    return ForumRules(uid: uid, fid: 0, forums: forums, v4: true);
  }
  final editable = json['editable'] == 1;
  return ForumRules(
    uid: uid,
    fid: fid,
    forums: forums,
    rules: _text(json['rules']),
    editable: editable,
    note: editable ? '' : t.modcp.rulesLocked,
    formHash: fields['formhash']!,
    v4: true,
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Announcements (47)
// ---------------------------------------------------------------------------------------------------------------------

AnnouncementForm? _announcementFormFromApi(Map<String, dynamic> form, {required int uid}) {
  final formHash = _served(form['submit'], const {'formhash'})['formhash'] ?? '';
  if (form.isEmpty || formHash.isEmpty) {
    return null;
  }
  final type = tsdmAppInt(form['type']) == 1 ? AnnouncementType.link : AnnouncementType.text;
  return AnnouncementForm(
    uid: uid,
    id: tsdmAppInt(form['id']),
    formHash: formHash,
    subject: _text(form['subject']),
    type: type,
    start: _text(form['starttime']).trim(),
    end: _text(form['endtime']).trim(),
    message: type == AnnouncementType.link ? _text(form['message']).trim() : _text(form['message']),
    displayOrder: _text(form['displayorder']).trim(),
    v4: true,
  );
}

/// The announcements and the form adding one in page answer [json] (`modcp_announcement`, `op` add or manage),
/// served to [uid], as [parseAnnouncements] reads them; null when it is the form of one announcement.
///
/// `editable` is the web page's state of the row (its box enabled), not a permission: the app shows it as the page
/// does.
AnnouncementList? announcementsFromApi(Map<String, dynamic> json, {required int uid}) {
  final formHash = _served(json['manage'], const {'formhash'})['formhash'] ?? '';
  if (json['op'] == 'edit' || json['list'] is! List || formHash.isEmpty) {
    return null;
  }
  final offset = _offset(json);
  String day(Object? value) => switch (modcpTimeText(value, offset, _date)) {
    '' => '-',
    final text => text,
  };
  return AnnouncementList(
    uid: uid,
    items: [
      for (final item in tsdmAppList(json['list']))
        if (tsdmAppInt(item['id']) case final id when id > 0)
          AnnouncementItem(
            id: '$id',
            author: _cell(item['author']),
            subject: _cell(item['subject']),
            type: tsdmAppInt(item['type']) == 1 ? t.modcp.typeLink : t.modcp.typeText,
            start: day(item['starttime']),
            end: day(item['endtime']),
            deletable: item['editable'] == 1,
          ),
    ],
    formHash: formHash,
    blank: _announcementFormFromApi(tsdmAppMap(json['form']), uid: uid),
    v4: true,
  );
}

/// The form of announcement [id] in page answer [json] (`op=edit`), served to [uid], as [parseAnnouncementForm] reads
/// it; null when it is not that form.
AnnouncementForm? announcementFormFromApi(Map<String, dynamic> json, {required int id, required int uid}) {
  final form = _announcementFormFromApi(tsdmAppMap(json['form']), uid: uid);
  return json['op'] == 'edit' && form != null && form.id == id ? form : null;
}
