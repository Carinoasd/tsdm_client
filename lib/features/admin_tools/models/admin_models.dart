import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

/// The admin actions of the forum's app API (plugin 3.9.0) the app offers.
abstract final class AdminActions {
  /// Rewarding and penalizing members' credits (积分奖惩).
  static const credit = 'admincredit';

  /// Changing a member's user groups (变更用户组).
  static const group = 'admingroup';

  /// Banning a member and clearing their posts (清理广告号).
  static const ban = 'adminban';

  /// The reports (handled elsewhere; listed so the answer reads whole).
  static const report = 'adminreport';
}

/// The header the admin token is sent with (`header` of `action=admin`, fixed by the plugin).
const adminTokenHeader = 'X-Tsdmapp-Admin';

/// Whether an account may read and post one admin action (`actions.<name>` of `action=admin`).
typedef AdminActionPerm = ({bool read, bool write});

/// The state of the second login (`login` of an admin answer): locked after too many wrong passwords, the seconds
/// until the next try, the tries left, and whether the security question is always asked.
@immutable
final class AdminLoginInfo {
  /// Constructor.
  const AdminLoginInfo({this.locked = false, this.retryAfter = 0, this.triesLeft = 4, this.secques = false});

  /// The `login` object of an answer [json] (missing fields as an unlocked state).
  factory AdminLoginInfo.fromJson(Object? json) {
    final m = tsdmAppMap(json);
    return AdminLoginInfo(
      locked: tsdmAppInt(m['locked']) == 1,
      retryAfter: tsdmAppInt(m['retry_after']),
      triesLeft: m.containsKey('tries_left') ? tsdmAppInt(m['tries_left']) : 4,
      secques: tsdmAppInt(m['secques']) == 1,
    );
  }

  /// Locked: no password is taken until [retryAfter] seconds passed.
  final bool locked;

  /// Seconds to wait; 0 when not locked.
  final int retryAfter;

  /// Wrong passwords left before the lock.
  final int triesLeft;

  /// The forum asks every admin login for the security question.
  final bool secques;
}

/// What `action=admin` (plugin 3.9.0, `schema: 25`) told about the account: whether the forum's admin actions are on,
/// whether the account may use them, and which. Only what the menus need is kept; the session and the login state are
/// read from each answer.
@immutable
final class AdminAccess {
  /// Constructor.
  const AdminAccess({
    required this.enabled,
    required this.eligible,
    this.why = '',
    this.founder = false,
    this.actions = const {},
  });

  /// The forum's switch is off (`status.admin` 0, or `enabled` 0).
  static const off = AdminAccess(enabled: false, eligible: false);

  /// The answer [json] of `action=admin`; null when it is not one.
  static AdminAccess? fromJson(Map<String, dynamic>? json) {
    if (json == null || json['ok'] != 1 || json['type'] != 'admin') {
      return null;
    }
    final actions = <String, AdminActionPerm>{
      for (final e in tsdmAppMap(json['actions']).entries)
        if (e.value is Map<String, dynamic>)
          e.key: (
            read: tsdmAppInt((e.value as Map<String, dynamic>)['read']) == 1,
            write: tsdmAppInt((e.value as Map<String, dynamic>)['write']) == 1,
          ),
    };
    return AdminAccess(
      enabled: tsdmAppInt(json['enabled']) == 1,
      eligible: tsdmAppInt(json['eligible']) == 1,
      why: tsdmAppText(json['why']),
      founder: tsdmAppInt(json['founder']) == 1,
      actions: actions,
    );
  }

  /// The forum's admin actions are switched on.
  final bool enabled;

  /// The account may use them.
  final bool eligible;

  /// Why not (`adminid`, `uids`, `cpaccess`, `ip`); empty when it may.
  final String why;

  /// The account is a founder.
  final bool founder;

  /// What the account may do with each action.
  final Map<String, AdminActionPerm> actions;

  /// The account may open [action] (switched on, eligible, `read` 1).
  bool canRead(String action) => enabled && eligible && (actions[action]?.read ?? false);

  /// The account may post [action] (and read it).
  bool canWrite(String action) => canRead(action) && (actions[action]?.write ?? false);

  /// The admin actions on one member the account may open, in the order shown.
  List<String> get memberActions => [
    for (final a in const [AdminActions.credit, AdminActions.group, AdminActions.ban])
      if (canRead(a)) a,
  ];

  @override
  bool operator ==(Object other) =>
      other is AdminAccess &&
      other.enabled == enabled &&
      other.eligible == eligible &&
      other.why == why &&
      other.founder == founder &&
      mapEquals(other.actions, actions);

  @override
  int get hashCode =>
      Object.hash(enabled, eligible, why, founder, Object.hashAllUnordered(actions.entries.map((e) => e)));
}

/// A member as the admin actions describe one (the member object of `admincredit`, `admingroup`, `adminban`).
@immutable
final class AdminMember {
  /// Constructor.
  const AdminMember({
    required this.uid,
    required this.username,
    this.groupId = 0,
    this.group = '',
    this.groupType = '',
    this.adminId = 0,
    this.locked = false,
    this.self = false,
    this.founder = false,
  });

  /// The member object [json]; null without a uid.
  static AdminMember? fromJson(Object? json) {
    final m = tsdmAppMap(json);
    final uid = tsdmAppInt(m['uid']);
    if (uid <= 0) {
      return null;
    }
    return AdminMember(
      uid: uid,
      username: tsdmAppText(m['username']),
      groupId: tsdmAppInt(m['groupid']),
      group: tsdmAppText(m['group']),
      groupType: tsdmAppText(m['grouptype']),
      adminId: tsdmAppInt(m['adminid']),
      locked: tsdmAppInt(m['status']) == -1,
      self: tsdmAppInt(m['self']) == 1,
      founder: tsdmAppInt(m['founder']) == 1,
    );
  }

  /// UID.
  final int uid;

  /// Username.
  final String username;

  /// Main user group.
  final int groupId;

  /// The main user group's name.
  final String group;

  /// `system`, `special` or `member`.
  final String groupType;

  /// 1 administrator, 2 super moderator, 3 moderator, 0 and -1 none.
  final int adminId;

  /// The account is locked (`status` -1).
  final bool locked;

  /// The account itself.
  final bool self;

  /// A founder.
  final bool founder;
}

/// Members to look up, as typed: UIDs and usernames, one a line or separated by commas.
({List<int> uids, List<String> usernames}) adminTargetsOf(String text) {
  final uids = <int>[];
  final names = <String>[];
  for (final t in text.split(RegExp(r'[\r\n,，]+')).map((e) => e.trim())) {
    if (t.isEmpty) continue;
    final uid = RegExp(r'^\d+$').hasMatch(t) ? int.tryParse(t) : null;
    if (uid != null && uid > 0) {
      if (!uids.contains(uid)) uids.add(uid);
    } else if (!names.contains(t)) {
      names.add(t);
    }
  }
  return (uids: uids, usernames: names);
}

/// The query naming one member: `uid` when [target] is a UID, `username` otherwise.
Map<String, String> adminTargetQuery(String target) {
  final t = target.trim();
  return RegExp(r'^\d+$').hasMatch(t) ? {'uid': t} : {'username': t};
}

// ---------------------------------------------------------------------------------------------------------------------
// 积分奖惩 (admincredit, schema 26)

/// A credit the forum has on: id 1 to 8, its name and unit.
typedef AdminCreditType = ({int id, String title, String unit});

/// A member of a credit change with their credits now (by credit id).
typedef AdminCreditMember = ({AdminMember member, Map<int, int> credits});

/// The answer of `GET action=admincredit`.
@immutable
final class AdminCreditInfo {
  /// Constructor.
  const AdminCreditInfo({
    required this.credits,
    required this.members,
    required this.missing,
    this.maxUsers = 50,
    this.maxDelta = 99999999,
    this.maxReason = 200,
    this.reasonRequired = false,
  });

  /// The answer [json]; null when it is not one.
  static AdminCreditInfo? fromJson(Map<String, dynamic>? json) {
    if (json == null || json['ok'] != 1 || json['type'] != 'admincredit') {
      return null;
    }
    final limits = tsdmAppMap(json['limits']);
    return AdminCreditInfo(
      credits: [
        for (final c in tsdmAppList(json['credits']))
          if (tsdmAppInt(c['id']) > 0)
            (id: tsdmAppInt(c['id']), title: tsdmAppText(c['title']), unit: tsdmAppText(c['unit'])),
      ],
      members: adminCreditMembersOf(json['members']),
      missing: [
        for (final m in (json['missing'] is List ? json['missing'] as List : const <Object?>[]))
          if (m != null) '$m',
      ],
      maxUsers: tsdmAppInt(limits['users']) > 0 ? tsdmAppInt(limits['users']) : 50,
      maxDelta: tsdmAppInt(limits['delta']) > 0 ? tsdmAppInt(limits['delta']) : 99999999,
      maxReason: tsdmAppInt(limits['reason']) > 0 ? tsdmAppInt(limits['reason']) : 200,
      reasonRequired: tsdmAppInt(json['reason_required']) == 1,
    );
  }

  /// The credits that may be changed.
  final List<AdminCreditType> credits;

  /// The members found.
  final List<AdminCreditMember> members;

  /// The UIDs and usernames not found.
  final List<String> missing;

  /// At most this many members at once.
  final int maxUsers;

  /// The largest change of one credit, either way.
  final int maxDelta;

  /// The longest reason.
  final int maxReason;

  /// A reason must be given.
  final bool reasonRequired;
}

/// The members of a credit answer's `members` [value].
List<AdminCreditMember> adminCreditMembersOf(Object? value) => [
  for (final m in tsdmAppList(value))
    if (AdminMember.fromJson(m) case final member?)
      (
        member: member,
        credits: {
          for (final e in tsdmAppMap(m['credits']).entries) ?int.tryParse(e.key): tsdmAppInt(e.value),
        },
      ),
];

/// The change of each credit typed in [text] (by credit id): integers, a leading `+` allowed; empty and 0 left out.
/// Null when one is not an integer.
Map<int, int>? adminCreditDeltasOf(Map<int, String> text) {
  final out = <int, int>{};
  for (final e in text.entries) {
    final t = e.value.trim().replaceFirst(RegExp(r'^\+'), '');
    if (t.isEmpty) continue;
    final v = int.tryParse(t);
    if (v == null) return null;
    if (v != 0) out[e.key] = v;
  }
  return out;
}

/// The form of `POST action=admincredit` (without `formhash` and `opid`): the members by UID, each credit's change
/// (`credits[<id>]`), the reason and whether to notify them.
Map<String, String> adminCreditForm({
  required List<int> uids,
  required Map<int, int> deltas,
  String reason = '',
  bool notify = false,
}) => {
  'uids': uids.join(','),
  for (final e in deltas.entries)
    if (e.value != 0) 'credits[${e.key}]': '${e.value}',
  if (reason.trim().isNotEmpty) 'reason': reason.trim(),
  if (notify) 'notify': '1',
};

/// The answer of `POST action=admincredit` (`op: reward`): what changed, how many were notified, the members after.
typedef AdminCreditResult = ({Map<int, int> changed, int notified, List<AdminCreditMember> members});

/// The result [json] of a credit change; null when it is not one.
AdminCreditResult? adminCreditResultOf(Map<String, dynamic>? json) {
  if (json == null || json['ok'] != 1 || json['op'] != 'reward') {
    return null;
  }
  return (
    changed: {
      for (final e in tsdmAppMap(json['changed']).entries) ?int.tryParse(e.key): tsdmAppInt(e.value),
    },
    notified: tsdmAppInt(json['notified']),
    members: adminCreditMembersOf(json['members']),
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// 变更用户组 (admingroup, schema 27)

/// A group offered: as the main group (`groups[]`, with `relatedAdmin`), as an extended group (`extgroups[]`) or as
/// the group after the expiry (`expgroups[]`, only the id and title).
typedef AdminGroupOption = ({
  int groupId,
  String title,
  String type,
  int radminId,
  bool relatedAdmin,
  bool allowed,
});

/// An extended group's expiry as the forum printed it: `time` 0 for good, `date` `YYYY-M-D`.
typedef AdminExtExpiry = ({int groupId, String title, int time, String date});

/// The member of a group answer, with their groups and expiries.
@immutable
final class AdminGroupMember {
  /// Constructor.
  const AdminGroupMember({
    required this.member,
    this.extGroupIds = const [],
    this.credits = 0,
    this.expiryTime = 0,
    this.expiryDate = '',
    this.expiryGroupId = 0,
    this.expiryAdminId = 0,
    this.extExpiry = const [],
  });

  /// The `member` object [json]; null without a uid.
  static AdminGroupMember? fromJson(Object? json) {
    final member = AdminMember.fromJson(json);
    if (member == null) return null;
    final m = tsdmAppMap(json);
    final expiry = tsdmAppMap(m['expiry']);
    return AdminGroupMember(
      member: member,
      extGroupIds: [
        for (final g in (m['extgroupids'] is List ? m['extgroupids'] as List : const <Object?>[]))
          if (tsdmAppInt(g) > 0) tsdmAppInt(g),
      ],
      credits: tsdmAppInt(m['credits']),
      expiryTime: tsdmAppInt(expiry['time']),
      expiryDate: tsdmAppText(expiry['date']),
      expiryGroupId: tsdmAppInt(expiry['groupid']),
      expiryAdminId: tsdmAppInt(expiry['adminid']),
      extExpiry: [
        for (final e in tsdmAppList(m['ext_expiry']))
          (
            groupId: tsdmAppInt(e['groupid']),
            title: tsdmAppText(e['title']),
            time: tsdmAppInt(e['time']),
            date: tsdmAppText(e['date']),
          ),
      ],
    );
  }

  /// The member.
  final AdminMember member;

  /// The extended groups now.
  final List<int> extGroupIds;

  /// The total credits.
  final int credits;

  /// The main group's expiry (unix seconds), 0 for none.
  final int expiryTime;

  /// The main group's expiry as printed (`YYYY-M-D`), empty for none.
  final String expiryDate;

  /// The group after the expiry, 0 for an ordinary member.
  final int expiryGroupId;

  /// The admin level after the expiry.
  final int expiryAdminId;

  /// The extended groups' expiries.
  final List<AdminExtExpiry> extExpiry;
}

/// The answer of `GET action=admingroup`.
@immutable
final class AdminGroupInfo {
  /// Constructor.
  const AdminGroupInfo({
    required this.member,
    required this.can,
    required this.groups,
    required this.extGroups,
    required this.expGroups,
    required this.adminIds,
    this.why = '',
    this.adminGrant = false,
    this.maxExtLength = 30,
    this.maxReason = 200,
    this.reasonRequired = false,
  });

  /// The answer [json]; null when it is not one.
  static AdminGroupInfo? fromJson(Map<String, dynamic>? json) {
    if (json == null || json['ok'] != 1 || json['type'] != 'admingroup') {
      return null;
    }
    final member = AdminGroupMember.fromJson(json['member']);
    if (member == null) return null;
    List<AdminGroupOption> options(Object? value) => [
      for (final g in tsdmAppList(value))
        (
          groupId: tsdmAppInt(g['groupid']),
          title: tsdmAppText(g['title']),
          type: tsdmAppText(g['type']),
          radminId: tsdmAppInt(g['radminid']),
          relatedAdmin: tsdmAppInt(g['related_adminid']) == 1,
          // `expgroups[]` has no `allowed`: all of them may be chosen.
          allowed: !g.containsKey('allowed') || tsdmAppInt(g['allowed']) == 1,
        ),
    ];
    final limits = tsdmAppMap(json['limits']);
    return AdminGroupInfo(
      member: member,
      can: tsdmAppInt(json['can']) == 1,
      why: tsdmAppText(json['why']),
      adminGrant: tsdmAppInt(json['admin_grant']) == 1,
      groups: options(json['groups']),
      extGroups: options(json['extgroups']),
      expGroups: options(json['expgroups']),
      adminIds: [
        for (final a in (json['adminids'] is List ? json['adminids'] as List : const <Object?>[])) tsdmAppInt(a),
      ],
      maxExtLength: tsdmAppInt(limits['extgroups_len']) > 0 ? tsdmAppInt(limits['extgroups_len']) : 30,
      maxReason: tsdmAppInt(limits['reason']) > 0 ? tsdmAppInt(limits['reason']) : 200,
      reasonRequired: tsdmAppInt(json['reason_required']) == 1,
    );
  }

  /// The member.
  final AdminGroupMember member;

  /// The account may change this member.
  final bool can;

  /// Why not: `self`, `founder_only`.
  final String why;

  /// The account may set and remove the administrator level (a founder).
  final bool adminGrant;

  /// The main groups offered.
  final List<AdminGroupOption> groups;

  /// The extended groups offered.
  final List<AdminGroupOption> extGroups;

  /// The groups after the expiry (`groupId` 0: an ordinary member).
  final List<AdminGroupOption> expGroups;

  /// The admin levels offered (0 none, 3, 2, 1).
  final List<int> adminIds;

  /// The extended group ids joined by tabs fit in this many characters.
  final int maxExtLength;

  /// The longest reason.
  final int maxReason;

  /// A reason must be given.
  final bool reasonRequired;

  /// The main group option [groupId], null when not offered.
  AdminGroupOption? groupOf(int groupId) => groups.where((g) => g.groupId == groupId).firstOrNull;
}

/// A forum date `YYYY-M-D` as `YYYY-MM-DD`, the way the form takes it; empty when it is not a date.
String adminPadDate(String date) {
  final m = RegExp(r'^\s*(\d{4})-(\d{1,2})-(\d{1,2})\s*$').firstMatch(date);
  if (m == null) return '';
  return '${m.group(1)}-${m.group(2)!.padLeft(2, '0')}-${m.group(3)!.padLeft(2, '0')}';
}

/// The fields of the group form: the whole state of the member's groups, the form replaces it.
@immutable
final class AdminGroupDraft {
  /// Constructor.
  const AdminGroupDraft({
    required this.groupId,
    this.adminId = 0,
    this.expiry = '',
    this.expGroupId = 0,
    this.expAdminId = 0,
    this.extGroupIds = const [],
    this.extExpiry = const {},
  });

  /// The member's groups now, as the form starts (dates as `YYYY-MM-DD`).
  factory AdminGroupDraft.of(AdminGroupInfo info) {
    final m = info.member;
    final group = info.groupOf(m.member.groupId);
    return AdminGroupDraft(
      groupId: m.member.groupId,
      // The related admin level only means something for a custom group that takes one.
      adminId: (group?.relatedAdmin ?? false) && m.member.adminId > 0 ? m.member.adminId : 0,
      expiry: m.expiryTime > 0 ? adminPadDate(m.expiryDate) : '',
      expGroupId: m.expiryGroupId,
      expAdminId: m.expiryAdminId,
      extGroupIds: m.extGroupIds,
      extExpiry: {
        for (final e in m.extExpiry)
          if (e.time > 0 && adminPadDate(e.date).isNotEmpty) e.groupId: adminPadDate(e.date),
      },
    );
  }

  /// Main group.
  final int groupId;

  /// The related admin level (main groups with `related_adminid` 1).
  final int adminId;

  /// The main group's expiry `YYYY-MM-DD`, empty for none.
  final String expiry;

  /// The group after the expiry.
  final int expGroupId;

  /// The admin level after the expiry.
  final int expAdminId;

  /// The extended groups, the whole list.
  final List<int> extGroupIds;

  /// Each extended group's expiry `YYYY-MM-DD`; missing for good.
  final Map<int, String> extExpiry;

  /// A copy with the fields given changed.
  AdminGroupDraft copyWith({
    int? groupId,
    int? adminId,
    String? expiry,
    int? expGroupId,
    int? expAdminId,
    List<int>? extGroupIds,
    Map<int, String>? extExpiry,
  }) => AdminGroupDraft(
    groupId: groupId ?? this.groupId,
    adminId: adminId ?? this.adminId,
    expiry: expiry ?? this.expiry,
    expGroupId: expGroupId ?? this.expGroupId,
    expAdminId: expAdminId ?? this.expAdminId,
    extGroupIds: extGroupIds ?? this.extGroupIds,
    extExpiry: extExpiry ?? this.extExpiry,
  );

  @override
  bool operator ==(Object other) =>
      other is AdminGroupDraft &&
      other.groupId == groupId &&
      other.adminId == adminId &&
      other.expiry == expiry &&
      other.expGroupId == expGroupId &&
      other.expAdminId == expAdminId &&
      setEquals(other.extGroupIds.toSet(), extGroupIds.toSet()) &&
      mapEquals(other.extExpiry, extExpiry);

  @override
  int get hashCode => Object.hash(groupId, adminId, expiry, expGroupId, expAdminId, extGroupIds.length);
}

/// The parts of the group form a change touches.
enum AdminGroupField {
  /// The main group.
  group,

  /// The related admin level.
  adminId,

  /// The main group's expiry, and what follows it.
  expiry,

  /// The extended groups added or removed.
  extGroups,

  /// An extended group's expiry.
  extExpiry,
}

/// What changed from [before] to [after], in the order of the form.
List<AdminGroupField> adminGroupChanges(AdminGroupDraft before, AdminGroupDraft after) => [
  if (before.groupId != after.groupId) AdminGroupField.group,
  if (before.adminId != after.adminId) AdminGroupField.adminId,
  if (before.expiry != after.expiry ||
      (after.expiry.isNotEmpty && (before.expGroupId != after.expGroupId || before.expAdminId != after.expAdminId)))
    AdminGroupField.expiry,
  if (!setEquals(before.extGroupIds.toSet(), after.extGroupIds.toSet())) AdminGroupField.extGroups,
  // The expiries of the groups kept: one added or removed is told by the groups.
  if (after.extGroupIds.any(
    (g) => before.extGroupIds.contains(g) && (before.extExpiry[g] ?? '') != (after.extExpiry[g] ?? ''),
  ))
    AdminGroupField.extExpiry,
];

/// The form of `POST action=admingroup` (without `formhash` and `opid`) for member [uid] with [draft]: the whole state,
/// as the forum replaces it. The related admin level only for a main group that takes one, the group after the expiry
/// only with an expiry, `notify` only with a reason (the forum only notifies with one).
Map<String, String> adminGroupForm({
  required int uid,
  required AdminGroupInfo info,
  required AdminGroupDraft draft,
  String reason = '',
  bool notify = false,
}) {
  final related = info.groupOf(draft.groupId)?.relatedAdmin ?? false;
  final hasReason = reason.trim().isNotEmpty;
  return {
    'uid': '$uid',
    'groupid': '${draft.groupId}',
    if (related && draft.adminId > 0) 'adminid': '${draft.adminId}',
    'expiry': draft.expiry,
    if (draft.expiry.isNotEmpty) ...{
      'expgroupid': '${draft.expGroupId}',
      if (draft.expAdminId > 0) 'expadminid': '${draft.expAdminId}',
    },
    for (final (i, g) in draft.extGroupIds.indexed) 'extgroupids[$i]': '$g',
    for (final g in draft.extGroupIds)
      if ((draft.extExpiry[g] ?? '').isNotEmpty) 'extexpiry[$g]': draft.extExpiry[g]!,
    if (hasReason) 'reason': reason.trim(),
    if (hasReason && notify) 'notify': '1',
  };
}

/// The extended groups [ids] joined as the forum stores them (by tabs) fit in [max] characters.
bool adminExtGroupsFit(List<int> ids, int max) => ids.join('\t').length <= max;

// ---------------------------------------------------------------------------------------------------------------------
// 清理广告号 (adminban, schema 30)

/// A record of a member's offence (`crimes[]`).
typedef AdminCrime = ({String action, String text, int dateline, String reason, String operator});

/// The member of a ban answer.
@immutable
final class AdminBanMember {
  /// Constructor.
  const AdminBanMember({
    required this.member,
    this.banned = '',
    this.banExpiry = 0,
    this.posts = 0,
    this.threads = 0,
    this.postRows = 0,
  });

  /// The `member` object [json]; null without a uid.
  static AdminBanMember? fromJson(Object? json) {
    final member = AdminMember.fromJson(json);
    if (member == null) return null;
    final m = tsdmAppMap(json);
    return AdminBanMember(
      member: member,
      banned: tsdmAppText(m['banned']),
      banExpiry: tsdmAppInt(m['banexpiry']),
      posts: tsdmAppInt(m['posts']),
      threads: tsdmAppInt(m['threads']),
      postRows: tsdmAppInt(m['post_rows']),
    );
  }

  /// The member.
  final AdminMember member;

  /// `""` none, `post`, `visit`, `status`.
  final String banned;

  /// Until (unix seconds), 0 for good or not banned.
  final int banExpiry;

  /// Posts on the member's record.
  final int posts;

  /// Threads on the member's record.
  final int threads;

  /// Rows of the post table under the member (the recycled too): the total of the clearing.
  final int postRows;
}

/// The answer of `GET action=adminban`.
@immutable
final class AdminBanInfo {
  /// Constructor.
  const AdminBanInfo({
    required this.member,
    required this.can,
    this.why = '',
    this.bans = const ['', 'post', 'visit', 'status'],
    this.days = const [0],
    this.clear = const [],
    this.batch = 200,
    this.reasonRequired = false,
    this.maxReason = 200,
    this.maxDays = 3650,
    this.crimes = const [],
    this.timeOffset = 8,
  });

  /// The answer [json]; null when it is not one.
  static AdminBanInfo? fromJson(Map<String, dynamic>? json) {
    if (json == null || json['ok'] != 1 || json['type'] != 'adminban' || json['op'] != null) {
      return null;
    }
    final member = AdminBanMember.fromJson(json['member']);
    if (member == null) return null;
    List<String> texts(Object? v) => [
      for (final e in (v is List ? v : const <Object?>[]))
        if (e is String) e,
    ];
    final limits = tsdmAppMap(json['limits']);
    return AdminBanInfo(
      member: member,
      can: tsdmAppInt(json['can']) == 1,
      why: tsdmAppText(json['why']),
      bans: texts(json['bans']),
      days: [
        for (final d in (json['days'] is List ? json['days'] as List : const <Object?>[0])) tsdmAppInt(d),
      ],
      clear: texts(json['clear']),
      batch: tsdmAppInt(json['batch']),
      reasonRequired: tsdmAppInt(json['reason_required']) == 1,
      maxReason: tsdmAppInt(limits['reason']) > 0 ? tsdmAppInt(limits['reason']) : 200,
      maxDays: tsdmAppInt(limits['days']) > 0 ? tsdmAppInt(limits['days']) : 3650,
      crimes: [
        for (final c in tsdmAppList(json['crimes']))
          (
            action: tsdmAppText(c['action']),
            text: tsdmAppText(c['action_text']),
            dateline: tsdmAppInt(c['dateline']),
            reason: tsdmAppText(c['reason']),
            operator: tsdmAppText(c['operator']),
          ),
      ],
      timeOffset: tsdmAppTimeOffset(json),
    );
  }

  /// The member.
  final AdminBanMember member;

  /// The account may ban this member.
  final bool can;

  /// Why not: `protected`, `portal`.
  final String why;

  /// The values of `bannew`.
  final List<String> bans;

  /// The days offered (0 for good).
  final List<int> days;

  /// What may be cleared: `post`, `postcomment`, `avatar`, `profile`.
  final List<String> clear;

  /// Rows one clearing request handles at most.
  final int batch;

  /// A reason must be given.
  final bool reasonRequired;

  /// The longest reason.
  final int maxReason;

  /// The longest ban in days.
  final int maxDays;

  /// The member's offences.
  final List<AdminCrime> crimes;

  /// The offset (hours) the forum shows the account's times with.
  final num timeOffset;
}

/// The form of `POST action=adminban op=ban` (without `formhash` and `opid`): the ban (`""` lifts it), its days (for
/// `post` and `visit`; 0 for good), the reason and what to clear (`clear[]`).
Map<String, String> adminBanForm({
  required int uid,
  required String ban,
  int days = 0,
  String reason = '',
  List<String> clear = const [],
}) => {
  'op': 'ban',
  'uid': '$uid',
  'bannew': ban,
  if ((ban == 'post' || ban == 'visit') && days > 0) 'banexpirynew': '$days',
  if (reason.trim().isNotEmpty) 'reason': reason.trim(),
  for (final (i, c) in clear.indexed) 'clear[$i]': c,
};

/// The posts still to clear: `pending` 1 while there are, from `cursor`.
typedef AdminClearPosts = ({bool pending, String cursor, int remaining, int batch});

/// The answer of `op=ban`: the member after, what was cleared there and then, the posts to clear (null when `post`
/// was not asked).
typedef AdminBanResult = ({AdminBanMember? member, List<String> cleared, AdminClearPosts? clearPosts});

/// The result [json] of `op=ban`; null when it is not one.
AdminBanResult? adminBanResultOf(Map<String, dynamic>? json) {
  if (json == null || json['ok'] != 1 || json['op'] != 'ban') {
    return null;
  }
  final cp = json['clear_posts'];
  return (
    member: AdminBanMember.fromJson(json['member']),
    cleared: [
      for (final c in (json['cleared'] is List ? json['cleared'] as List : const <Object?>[]))
        if (c is String) c,
    ],
    clearPosts: cp is Map<String, dynamic>
        ? (
            pending: tsdmAppInt(cp['pending']) == 1,
            cursor: tsdmAppText(cp['cursor']).isEmpty ? adminClearStart : tsdmAppText(cp['cursor']),
            remaining: tsdmAppInt(cp['remaining']),
            batch: tsdmAppInt(cp['batch']),
          )
        : null,
  );
}

/// The cursor a clearing starts from.
const adminClearStart = '0-0';

/// One batch of the clearing (`op=clear`): done, the cursor of the next, the rows left, what this one handled.
typedef AdminClearStep = ({bool done, String cursor, int remaining, int posts, int threads});

/// The answer [json] of `op=clear`; null when it is not one.
AdminClearStep? adminClearStepOf(Map<String, dynamic>? json) {
  if (json == null || json['ok'] != 1 || json['op'] != 'clear') {
    return null;
  }
  return (
    done: tsdmAppInt(json['done']) == 1,
    cursor: tsdmAppText(json['cursor']),
    remaining: tsdmAppInt(json['remaining']),
    posts: tsdmAppInt(json['posts']),
    threads: tsdmAppInt(json['threads']),
  );
}

/// The form of one clearing batch of member [uid] from [cursor].
Map<String, String> adminClearForm({required int uid, required String cursor}) => {
  'op': 'clear',
  'uid': '$uid',
  'cursor': cursor,
};
