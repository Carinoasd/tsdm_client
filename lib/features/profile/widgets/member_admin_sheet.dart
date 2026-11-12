import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/medal_title_tools/repository/medal_title_tools_repository.dart';
import 'package:tsdm_client/features/medal_title_tools/utils/staff_access.dart';
import 'package:tsdm_client/features/moderate/utils/panel_tools_access.dart';
import 'package:tsdm_client/features/profile/utils/management_group.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// What the account [uid] may do to other members, null when it may not or the forum could not tell.
///
/// The forum is asked about the tools only for an account of a management group ([isManager] reads that from the
/// account's own profile, once per account): an ordinary member sends no request for them.
Future<StaffTools?> memberAdminToolsOf(
  int uid, {
  required Future<bool?> Function() isManager,
  MedalTitleToolsRepository? repository,
  bool Function()? stillCurrent,
}) async {
  if (await ManagementGroupCache.check(uid, isManager) != true) {
    return null;
  }
  return StaffToolsAccess.check(uid, repository: repository, stillCurrent: stillCurrent);
}

/// What the account [uid] may do to other members with the forum's admin actions (plugin 3.9.0: credits, user
/// groups, cleaning up a spammer), null when nothing or the forum could not tell.
///
/// Asked only for an account of a management group, as [memberAdminToolsOf]: an ordinary member sends no request.
Future<AdminAccess?> memberAdminAccessOf(
  int uid, {
  required Future<bool?> Function() isManager,
  AdminRepository? repository,
  Future<bool?> Function()? switchOn,
  bool Function()? stillCurrent,
}) async {
  if (await ManagementGroupCache.check(uid, isManager) != true) {
    return null;
  }
  final access = await AdminAccessCache.check(
    uid,
    repository: repository,
    switchOn: switchOn,
    stillCurrent: stillCurrent,
  );
  return access == null || access.memberActions.isEmpty ? null : access;
}

/// Whether the account [uid] may send backgrounds to other members ([PanelToolsAccess]); false when it may not, is
/// not of a management group or the forum could not tell. Asked only for an account of a management group, as
/// [memberAdminToolsOf].
Future<bool> memberBackgroundGrantOf(
  int uid, {
  required Future<bool?> Function() isManager,
  bool Function()? stillCurrent,
  Future<PanelTools?> Function()? check,
}) async {
  if (await ManagementGroupCache.check(uid, isManager) != true) {
    return false;
  }
  final can = await (check ?? () => PanelToolsAccess.check(uid, stillCurrent: stillCurrent))();
  return can?.background ?? false;
}

/// One admin operation on a member: an icon, a label and the page it opens with the member's UID brought in; `site`
/// for the forum's admin actions, listed apart from the rewards.
typedef MemberAdminItem = ({Key key, IconData icon, String label, String path, bool site});

/// The admin operations [can] offers on a member, in the order shown: the rewards (medals, titles, sending backgrounds
/// when [background]), then the forum's admin actions [admin] lets the account read. Add new operations here.
List<MemberAdminItem> memberAdminItems(
  BuildContext context,
  StaffTools can, {
  bool background = false,
  AdminAccess? admin,
}) {
  final tr = context.t.medalTitleTools;
  final at = context.t.adminTools;
  return [
    if (can.grant)
      (
        key: const ValueKey('member-admin-medal-grant'),
        icon: Icons.card_giftcard_outlined,
        label: tr.grantTitle,
        path: ScreenPaths.medalGrant,
        site: false,
      ),
    if (can.issue)
      (
        key: const ValueKey('member-admin-title-issue'),
        icon: Icons.verified_outlined,
        label: tr.issueTitle,
        path: ScreenPaths.titleIssue,
        site: false,
      ),
    if (background)
      (
        key: const ValueKey('member-admin-background-grant'),
        icon: Icons.wallpaper_outlined,
        label: context.t.backgroundGrant.title,
        path: ScreenPaths.backgroundGrant,
        site: false,
      ),
    if (admin?.canRead(AdminActions.credit) ?? false)
      (
        key: const ValueKey('member-admin-credit'),
        icon: Icons.savings_outlined,
        label: at.credit,
        path: ScreenPaths.adminCredit,
        site: true,
      ),
    if (admin?.canRead(AdminActions.group) ?? false)
      (
        key: const ValueKey('member-admin-group'),
        icon: Icons.group_outlined,
        label: at.group,
        path: ScreenPaths.adminGroup,
        site: true,
      ),
    if (admin?.canRead(AdminActions.ban) ?? false)
      (
        key: const ValueKey('member-admin-ban'),
        icon: Icons.cleaning_services_outlined,
        label: at.ban,
        path: ScreenPaths.adminBan,
        site: true,
      ),
  ];
}

/// Show the admin operations on the member [uid] as a bottom sheet; a pick opens its page with the member filled in.
Future<void> showMemberAdminSheet(
  BuildContext context, {
  required int uid,
  required StaffTools can,
  bool background = false,
  AdminAccess? admin,
}) {
  final items = memberAdminItems(context, can, background: background, admin: admin);
  final router = GoRouter.of(context);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, item) in items.indexed) ...[
            // The rewards and the forum's admin actions apart.
            if (i > 0 && item.site != items[i - 1].site) const Divider(height: 8, indent: 16, endIndent: 16),
            ListTile(
              key: item.key,
              leading: Icon(item.icon),
              title: Text(item.label),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(router.pushNamed(item.path, queryParameters: {'uid': '$uid'}));
              },
            ),
          ],
        ],
      ),
    ),
  );
}
