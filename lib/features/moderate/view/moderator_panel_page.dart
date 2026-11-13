import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_ban_page.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_credit_page.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_group_page.dart';
import 'package:tsdm_client/features/admin_tools/widgets/admin_widgets.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/background_grant/view/background_grant_page.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/utils/batch_rate_access.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_list_page.dart';
import 'package:tsdm_client/features/medal_title_tools/utils/staff_access.dart';
import 'package:tsdm_client/features/medal_title_tools/view/medal_grant_page.dart';
import 'package:tsdm_client/features/medal_title_tools/view/title_issue_page.dart';
import 'package:tsdm_client/features/moderate/models/modcp_json_pages.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/utils/panel_tools_access.dart';
import 'package:tsdm_client/features/moderate/view/announcements_page.dart';
import 'package:tsdm_client/features/moderate/view/forum_rules_page.dart';
import 'package:tsdm_client/features/moderate/view/member_review_page.dart';
import 'package:tsdm_client/features/moderate/view/modcp_forum_access_page.dart';
import 'package:tsdm_client/features/moderate/view/modcp_members_page.dart';
import 'package:tsdm_client/features/moderate/view/modcp_notes_page.dart';
import 'package:tsdm_client/features/moderate/view/modcp_posts_page.dart';
import 'package:tsdm_client/features/moderate/view/modcp_threads_page.dart';
import 'package:tsdm_client/features/moderate/view/moderate_queue_page.dart';
import 'package:tsdm_client/features/moderate/view/moderator_log_page.dart';
import 'package:tsdm_client/features/moderate/view/recycle_bin_page.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_home_summary.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_panel_login.dart';
import 'package:tsdm_client/features/report_handling/repository/report_source.dart';
import 'package:tsdm_client/features/report_handling/view/admin_report_page.dart';
import 'package:tsdm_client/features/report_handling/view/report_handling_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The groups of the moderator's panel, in the order shown.
enum _PanelGroup {
  /// The threads and posts: the queue, the recycle bin, the log, the notes, the reports.
  moderation(Icons.gavel_outlined),

  /// The members and the forums: their permissions, the review of new members, the rules, the announcements.
  members(Icons.groups_outlined),

  /// What is given to members: medals, titles, backgrounds, the batch rates.
  rewards(Icons.redeem_outlined),

  /// The forum's admin actions on members: credits, user groups, cleaning up a spammer.
  site(Icons.shield_outlined)
  ;

  const _PanelGroup(this.icon);

  /// Icon of the group's header.
  final IconData icon;

  /// Title of the group's header.
  String title(Translations t) => switch (this) {
    moderation => t.modcp.groupModeration,
    members => t.modcp.groupMembers,
    rewards => t.modcp.groupRewards,
    site => t.modcp.groupSite,
  };
}

/// The moderator's panel: the pages of the forum's moderation panel the app offers, as tiles in four groups.
///
/// Shown to an account of a management group (the "me" page asks its profile); the forum decides what each page
/// lists or refuses. The pages the panel's menu links only to the groups allowed to use them (the members, the rules,
/// the announcements) are shown once the menu says so, all of them when it could not be read.
class ModeratorPanelPage extends StatefulWidget {
  /// Constructor.
  const ModeratorPanelPage({
    this.repository,
    this.queueRepository,
    this.staffTools,
    this.panelTools,
    this.adminAccess,
    this.adminRepository,
    this.batchRate,
    this.modcpPages,
    this.pagesRepository,
    super.key,
  });

  /// The panel's pages; the app's client when null.
  final ModcpRepository? repository;

  /// The moderation queue's lists and operations; the app's client when null.
  final ModerateRepository? queueRepository;

  /// What the account may do with the medal and title tools; asked of the forum (once per account) when null.
  final Future<StaffTools?> Function()? staffTools;

  /// Sending backgrounds and the report page (plugin 3.9.0); asked of the forum (once per account) when null.
  final Future<PanelTools?> Function()? panelTools;

  /// What the account may do with the forum's admin actions; asked of the forum (once per account) when null.
  final Future<AdminAccess?> Function()? adminAccess;

  /// The admin actions' requests; the app's client when null.
  final AdminRepository? adminRepository;

  /// Whether the account may read the batch rates (tsdmapp 3.9.0); asked of the forum (once per account) when null.
  final Future<BatchRateInfo?> Function()? batchRate;

  /// The panel's pages the forum answers as fields (`status.modcp_pages`, tsdmapp 3.9.0); asked of the forum (with
  /// [panelTools]) when null.
  final Future<Set<String>?> Function()? modcpPages;

  /// Those pages' requests; the app's client when null.
  final ModcpPagesRepository? pagesRepository;

  @override
  State<ModeratorPanelPage> createState() => _ModeratorPanelPageState();
}

class _ModeratorPanelPageState extends State<ModeratorPanelPage> {
  late final ModcpRepository _repository = widget.repository ?? ModcpRepository.network();

  /// The panel's menu; null while it is asked or when it could not be read.
  ModcpMenu? _menu;

  /// The menu was asked and answered (read or not).
  bool _asked = false;

  /// The medal and title tools the account may use; null until asked or when it could not be.
  StaffTools? _staff;

  /// Sending backgrounds and the report page; null until asked or when it could not be.
  PanelTools? _panel;

  late final AdminRepository _adminRepository = widget.adminRepository ?? AdminRepository.network();

  /// The admin actions the account may use; null until asked or when it could not be.
  AdminAccess? _admin;

  /// The batch rates the account may read; null until asked or when it may not.
  BatchRateInfo? _batchRate;

  late final ModcpPagesRepository _pages = widget.pagesRepository ?? ModcpPagesRepository.network(_repository);

  /// The panel's pages the forum answers as fields; none until asked.
  Set<String> _modcpPages = const {};

  /// The panel's first page (what waits), null until read or when it could not be (the panel's password not given).
  ModcpHome? _home;

  /// The form hash of the panel's login when the first page asked for it (the panel's password not given yet); null
  /// otherwise.
  String? _homeLogin;

  /// Asked as [_loadStaff] is; the first page read once the forum answers it.
  Future<void> _loadModcpPages() async {
    final auth = context.readOrNull<AuthenticationRepository>();
    final uid = auth?.currentUser?.uid;
    final ask =
        widget.modcpPages ??
        (uid == null
            ? null
            : () async {
                await PanelToolsAccess.check(uid, stillCurrent: () => auth?.currentUser?.uid == uid);
                return PanelToolsAccess.modcpPages(uid);
              });
    final pages = await ask?.call();
    if (mounted && pages != null && pages.isNotEmpty) {
      setState(() => _modcpPages = pages);
      await _loadHome();
    }
  }

  /// The first page asked last: an earlier answer is dropped.
  int _homeGeneration = 0;

  /// What waits on the panel's first page.
  Future<void> _loadHome() async {
    if (!_modcpPages.contains('home')) {
      return;
    }
    final generation = ++_homeGeneration;
    final answer = await _pages.fetchHome().run();
    if (mounted && generation == _homeGeneration) {
      setState(() {
        _home = switch (answer) {
          Right(value: ModcpReady(:final value)) => value,
          _ => null,
        };
        _homeLogin = switch (answer) {
          Right(value: ModcpNeedsLogin(:final formHash)) => formHash,
          _ => null,
        };
      });
    }
  }

  /// Open [page], and read what waits again once back.
  Future<void> _push(Widget Function() page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page()));
    if (mounted) {
      await _loadHome();
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadModcpPages());
    unawaited(_loadMenu());
    unawaited(_loadStaff());
    unawaited(_loadPanel());
    unawaited(_loadAdmin());
    unawaited(_loadBatchRate());
  }

  /// Asked as [_loadStaff] is.
  Future<void> _loadBatchRate() async {
    final auth = context.readOrNull<AuthenticationRepository>();
    final uid = auth?.currentUser?.uid;
    final ask =
        widget.batchRate ??
        (uid == null ? null : () => BatchRateAccess.check(uid, stillCurrent: () => auth?.currentUser?.uid == uid));
    final info = await ask?.call();
    if (mounted && info != null && info.offersBatches) {
      setState(() => _batchRate = info);
    }
  }

  Future<void> _loadAdmin() async {
    final auth = context.readOrNull<AuthenticationRepository>();
    final uid = auth?.currentUser?.uid;
    bool stillCurrent() => auth?.currentUser?.uid == uid;
    final ask =
        widget.adminAccess ??
        (uid == null
            ? null
            : () => AdminAccessCache.check(uid, repository: _adminRepository, stillCurrent: stillCurrent));
    if (ask == null) {
      return;
    }
    final access = await ask();
    if (!mounted || access == null || (access.memberActions.isEmpty && !access.canRead(AdminActions.report))) {
      return;
    }
    setState(() => _admin = access);
  }

  /// The panel is linked to the accounts of a management group only (the "me" page), so asking here sends nothing for
  /// an ordinary member who does not open it by hand.
  Future<void> _loadStaff() async {
    final auth = context.readOrNull<AuthenticationRepository>();
    final uid = auth?.currentUser?.uid;
    bool stillCurrent() => auth?.currentUser?.uid == uid;
    final ask =
        widget.staffTools ?? (uid == null ? null : () => StaffToolsAccess.check(uid, stillCurrent: stillCurrent));
    if (ask == null) {
      return;
    }
    final can = await ask();
    if (mounted && can != null) {
      setState(() => _staff = can);
    }
  }

  /// Asked as [_loadStaff] is.
  Future<void> _loadPanel() async {
    final auth = context.readOrNull<AuthenticationRepository>();
    final uid = auth?.currentUser?.uid;
    final ask =
        widget.panelTools ??
        (uid == null ? null : () => PanelToolsAccess.check(uid, stillCurrent: () => auth?.currentUser?.uid == uid));
    final panel = await ask?.call();
    if (mounted && panel != null) {
      setState(() => _panel = panel);
    }
  }

  Future<void> _loadMenu() async {
    final answer = await _repository.fetchMenu().run();
    if (!mounted) {
      return;
    }
    setState(() {
      _asked = true;
      _menu = switch (answer) {
        Right(value: ModcpReady(:final value)) => value,
        _ => null,
      };
    });
  }

  /// Whether a page the menu gates is shown: once the menu offers it, or when the menu could not be read.
  bool _offers(bool Function(ModcpMenu menu) offered) => switch (_menu) {
    final menu? => offered(menu),
    null => _asked,
  };

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final repository = _repository;
    final queueRepository = widget.queueRepository;
    final entries = <(_PanelGroup, Key, IconData, String, Widget Function())>[
      (
        _PanelGroup.moderation,
        const ValueKey('modcp-queue'),
        Icons.fact_check_outlined,
        t.moderate.queue,
        () => ModcpForumPickerPage(
          title: t.moderate.queue,
          repository: repository,
          load: repository.fetchQueueForums,
          pageOf: (forum) => ModerateQueuePage(fid: forum.fid, title: forum.name, repository: queueRepository),
        ),
      ),
      (
        _PanelGroup.moderation,
        const ValueKey('modcp-recycle-bin'),
        Icons.delete_sweep_outlined,
        t.modcp.recycleBin,
        () => RecycleBinPage(repository: repository),
      ),
      (
        _PanelGroup.moderation,
        const ValueKey('modcp-log'),
        Icons.history_outlined,
        t.modcp.log,
        () => ModeratorLogPage(repository: repository),
      ),
      // The panel's pages tsdmapp 3.9.0 answers as fields; the members' permissions need a group allowed to edit
      // members (the panel's menu links it to those only).
      if (_modcpPages.contains('home'))
        (
          _PanelGroup.moderation,
          const ValueKey('modcp-notes'),
          Icons.sticky_note_2_outlined,
          t.modcpPages.notes,
          () => ModcpNotesPage(repository: _pages),
        ),
      if (_modcpPages.contains('thread')) ...[
        (
          _PanelGroup.moderation,
          const ValueKey('modcp-threads'),
          Icons.topic_outlined,
          t.modcpPages.threads,
          () => ModcpThreadsPage(repository: _pages, moderateRepository: queueRepository),
        ),
        (
          _PanelGroup.moderation,
          const ValueKey('modcp-posts'),
          Icons.article_outlined,
          t.modcpPages.posts,
          () => ModcpPostsPage(repository: _pages),
        ),
      ],
      if (_modcpPages.contains('forumaccess') && _offers((m) => m.has('forumaccess')))
        (
          _PanelGroup.members,
          const ValueKey('modcp-forum-access'),
          Icons.admin_panel_settings_outlined,
          t.modcpPages.access,
          () => ModcpForumAccessPage(repository: _pages),
        ),
      if (_offers((m) => m.canManageMembers))
        (
          _PanelGroup.members,
          const ValueKey('modcp-members'),
          Icons.manage_accounts_outlined,
          t.modcp.members,
          () => ModcpMembersPage(repository: repository),
        ),
      (
        _PanelGroup.members,
        const ValueKey('modcp-member-review'),
        Icons.how_to_reg_outlined,
        t.modcp.memberReview,
        () => MemberReviewPage(repository: repository),
      ),
      if (_offers((m) => m.canEditForum))
        (
          _PanelGroup.members,
          const ValueKey('modcp-rules'),
          Icons.rule_outlined,
          t.modcp.rules,
          () => ForumRulesPage(repository: repository),
        ),
      if (_offers((m) => m.canAnnounce))
        (
          _PanelGroup.members,
          const ValueKey('modcp-announcements'),
          Icons.campaign_outlined,
          t.modcp.announcements,
          () => AnnouncementsPage(repository: repository),
        ),
      // The reports of the whole forum for an account the admin API lets read them, beside the panel's.
      if (_admin?.canRead(AdminActions.report) ?? false)
        (
          _PanelGroup.moderation,
          const ValueKey('modcp-report'),
          Icons.flag_outlined,
          t.reportHandling.title,
          () => AdminReportPage(
            repository: _adminRepository,
            writable: _admin?.canWrite(AdminActions.report) ?? false,
            panel: (_panel?.modcpReport ?? false) ? ModcpReportSource.network(repository) : null,
          ),
        )
      else if (_panel?.modcpReport ?? false)
        (
          _PanelGroup.moderation,
          const ValueKey('modcp-report'),
          Icons.flag_outlined,
          t.reportHandling.title,
          () => ReportHandlingPage(source: ModcpReportSource.network(repository)),
        ),
      if (_staff?.grant ?? false)
        (
          _PanelGroup.rewards,
          const ValueKey('modcp-medal-grant'),
          Icons.card_giftcard_outlined,
          t.medalTitleTools.grantTitle,
          () => const MedalGrantPage(),
        ),
      if (_staff?.issue ?? false)
        (
          _PanelGroup.rewards,
          const ValueKey('modcp-title-issue'),
          Icons.verified_outlined,
          t.medalTitleTools.issueTitle,
          () => const TitleIssuePage(),
        ),
      if (_panel?.background ?? false)
        (
          _PanelGroup.rewards,
          const ValueKey('modcp-background-grant'),
          Icons.wallpaper_outlined,
          t.backgroundGrant.title,
          () => const BackgroundGrantPage(),
        ),
      if (_batchRate?.listUrl case final listUrl?)
        (
          _PanelGroup.rewards,
          const ValueKey('modcp-batch-rate'),
          Icons.thumbs_up_down_outlined,
          t.batchRate.batches,
          () => BatchRateListPage(listUrl: listUrl),
        ),
      if (_admin?.canRead(AdminActions.credit) ?? false)
        (
          _PanelGroup.site,
          const ValueKey('modcp-admin-credit'),
          Icons.savings_outlined,
          t.adminTools.credit,
          () => AdminCreditPage(
            repository: _adminRepository,
            writable: _admin?.canWrite(AdminActions.credit),
          ),
        ),
      if (_admin?.canRead(AdminActions.group) ?? false)
        (
          _PanelGroup.site,
          const ValueKey('modcp-admin-group'),
          Icons.group_outlined,
          t.adminTools.group,
          () => AdminGroupPage(
            repository: _adminRepository,
            writable: _admin?.canWrite(AdminActions.group),
          ),
        ),
      if (_admin?.canRead(AdminActions.ban) ?? false)
        (
          _PanelGroup.site,
          const ValueKey('modcp-admin-ban'),
          Icons.cleaning_services_outlined,
          t.adminTools.ban,
          () => AdminBanPage(
            repository: _adminRepository,
            writable: _admin?.canWrite(AdminActions.ban),
          ),
        ),
    ];
    final groups = [
      for (final group in _PanelGroup.values)
        if (entries.where((entry) => entry.$1 == group).toList() case final tiles when tiles.isNotEmpty) (group, tiles),
    ];
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.modcp.panel),
        actions: [if (_admin != null) AdminLogoutButton(repository: _adminRepository)],
      ),
      body: SafeArea(
        top: false,
        child: AppCenteredList(
          builder: (context, padding, _) => ListView(
            padding: padding.copyWith(top: 12, bottom: 12),
            children: [
              if (_home case final home?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ModcpHomeSummary(
                    home: home,
                    onModerate: () => unawaited(
                      _push(
                        () => ModcpForumPickerPage(
                          title: t.moderate.queue,
                          repository: repository,
                          load: repository.fetchQueueForums,
                          pageOf: (forum) =>
                              ModerateQueuePage(fid: forum.fid, title: forum.name, repository: queueRepository),
                        ),
                      ),
                    ),
                    onNotes: () => unawaited(_push(() => ModcpNotesPage(repository: _pages))),
                  ),
                )
              else if (_homeLogin case final formHash?)
                // Where the counts go: the panel's login, then the counts.
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ModcpHomeLoginTile(
                    onTap: () => unawaited(
                      _push(
                        () => ModcpPanelLoginPage(
                          login: (password) => repository.loginPanel(formHash: formHash, password: password),
                        ),
                      ),
                    ),
                  ),
                ),
              // Each tile belongs to one group for good: the answers come in one after another, a tile shown never
              // moves to another group, and a group with no tile (yet) is not shown at all.
              for (final (group, tiles) in groups)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AppSurface(
                    key: ValueKey('modcp-group-${group.name}'),
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppSectionHeader(
                          group.title(t),
                          icon: group.icon,
                          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                        ),
                        GridView.extent(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          maxCrossAxisExtent: 160,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 1.3,
                          children: [
                            for (final (_, key, icon, label, page) in tiles)
                              Material(
                                key: key,
                                color: colorScheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(appInnerRadius),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: () => unawaited(_push(page)),
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(icon, color: colorScheme.primary, size: 28),
                                        const SizedBox(height: 8),
                                        Text(
                                          label,
                                          maxLines: 2,
                                          textAlign: TextAlign.center,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.labelLarge,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Choose one of the forums the panel offers ([load]), then the page of it ([pageOf]) takes this one's place.
class ModcpForumPickerPage extends StatelessWidget {
  /// Constructor.
  const ModcpForumPickerPage({
    required this.title,
    required this.repository,
    required this.load,
    required this.pageOf,
    super.key,
  });

  /// The page's title.
  final String title;

  /// The panel (its login).
  final ModcpRepository repository;

  /// Ask the forums.
  final AsyncEither<ModcpAnswer<List<ModcpForum>>> Function() load;

  /// The page of the forum chosen.
  final Widget Function(ModcpForum forum) pageOf;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: ModcpForumChooser(
      repository: repository,
      load: () => load().run(),
      onPick: (forum) => unawaited(
        Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => pageOf(forum))),
      ),
    ),
  );
}

/// The forums the panel offers ([load]) as a list to choose from ([onPick]); the panel's login when it asks it, its
/// refusal in its own words. The only forum offered is chosen right away when [pickSingle].
class ModcpForumChooser extends StatefulWidget {
  /// Constructor.
  const ModcpForumChooser({
    required this.repository,
    required this.load,
    required this.onPick,
    this.pickSingle = true,
    super.key,
  });

  /// The panel (its login).
  final ModcpRepository repository;

  /// Ask the forums.
  final Future<Either<AppException, ModcpAnswer<List<ModcpForum>>>> Function() load;

  /// A forum was chosen.
  final void Function(ModcpForum forum) onPick;

  /// Choose the only forum offered without asking.
  final bool pickSingle;

  @override
  State<ModcpForumChooser> createState() => _ModcpForumChooserState();
}

class _ModcpForumChooserState extends State<ModcpForumChooser> {
  bool _loading = true;
  Either<AppException, ModcpAnswer<List<ModcpForum>>>? _answer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final answer = await widget.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      _answer = answer;
    });
    if (answer case Right(value: ModcpReady(value: [final only])) when widget.pickSingle) {
      widget.onPick(only);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return switch (_answer) {
      Right(value: ModcpNeedsLogin(:final formHash)) => ModeratePanelLoginView(
        login: (password) => widget.repository.loginPanel(formHash: formHash, password: password),
        onLoggedIn: _load,
      ),
      Right(value: ModcpReady(value: final forums)) when forums.isNotEmpty => AppCenteredList(
        builder: (context, padding, _) => ListView(
          padding: padding.copyWith(top: 8, bottom: 8),
          children: [
            AppSurface(
              child: Column(
                children: [
                  for (final forum in forums)
                    ListTile(
                      key: ValueKey('modcp-forum-${forum.fid}'),
                      leading: const Icon(Icons.forum_outlined),
                      title: Text(context.displayText(forum.name)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => widget.onPick(forum),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      Right(value: ModcpReady()) => AppStateView(icon: Icons.forum_outlined, message: context.t.modcp.noForums),
      final answer => modcpErrorView(context, answer, onRetry: _load),
    };
  }
}

/// The panel's login asked alone ([ModeratePanelLoginView]): closed once logged in, the page that opened it reads
/// what it needed again.
class ModcpPanelLoginPage extends StatelessWidget {
  /// Constructor.
  const ModcpPanelLoginPage({required this.login, super.key});

  /// Send the password.
  final AsyncEither<ModeratePanelLogin> Function(String password) login;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.t.moderate.panelLogin)),
    body: ModeratePanelLoginView(
      login: login,
      onLoggedIn: () async {
        if (context.mounted) Navigator.of(context).pop();
      },
    ),
  );
}

/// The view of an answer that is not the page: the panel's refusal in its own words, or why it could not be had.
Widget modcpErrorView(
  BuildContext context,
  Either<AppException, ModcpAnswer<Object?>>? answer, {
  VoidCallback? onRetry,
}) {
  final message = switch (answer) {
    Right(value: ModcpRefused(:final message)) when message.isNotEmpty => context.displayText(message),
    Left(value: IdentityChangedException()) => context.t.general.accountChangedRetry,
    Right(value: ModcpRefused()) => context.t.moderate.failed,
    _ => context.t.general.failedToLoad,
  };
  return AppStateView(
    icon: Icons.error_outline,
    error: true,
    message: message,
    action: onRetry == null ? null : TextButton(onPressed: onRetry, child: Text(context.t.general.retry)),
  );
}
