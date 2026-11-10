import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/view/announcements_page.dart';
import 'package:tsdm_client/features/moderate/view/forum_rules_page.dart';
import 'package:tsdm_client/features/moderate/view/member_review_page.dart';
import 'package:tsdm_client/features/moderate/view/modcp_members_page.dart';
import 'package:tsdm_client/features/moderate/view/moderate_queue_page.dart';
import 'package:tsdm_client/features/moderate/view/moderator_log_page.dart';
import 'package:tsdm_client/features/moderate/view/recycle_bin_page.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_panel_login.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The moderator's panel: the pages of the forum's moderation panel the app offers, as a grid of tiles.
///
/// Shown to an account of a management group (the "me" page asks its profile); the forum decides what each page
/// lists or refuses. The pages the panel's menu links only to the groups allowed to use them (the members, the rules,
/// the announcements) are shown once the menu says so, all of them when it could not be read.
class ModeratorPanelPage extends StatefulWidget {
  /// Constructor.
  const ModeratorPanelPage({this.repository, this.queueRepository, super.key});

  /// The panel's pages; the app's client when null.
  final ModcpRepository? repository;

  /// The moderation queue's lists and operations; the app's client when null.
  final ModerateRepository? queueRepository;

  @override
  State<ModeratorPanelPage> createState() => _ModeratorPanelPageState();
}

class _ModeratorPanelPageState extends State<ModeratorPanelPage> {
  late final ModcpRepository _repository = widget.repository ?? ModcpRepository.network();

  /// The panel's menu; null while it is asked or when it could not be read.
  ModcpMenu? _menu;

  /// The menu was asked and answered (read or not).
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMenu());
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
    final entries = <(Key, IconData, String, Widget Function())>[
      (
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
        const ValueKey('modcp-recycle-bin'),
        Icons.delete_sweep_outlined,
        t.modcp.recycleBin,
        () => RecycleBinPage(repository: repository),
      ),
      (
        const ValueKey('modcp-log'),
        Icons.history_outlined,
        t.modcp.log,
        () => ModeratorLogPage(repository: repository),
      ),
      if (_offers((m) => m.canManageMembers))
        (
          const ValueKey('modcp-members'),
          Icons.manage_accounts_outlined,
          t.modcp.members,
          () => ModcpMembersPage(repository: repository),
        ),
      (
        const ValueKey('modcp-member-review'),
        Icons.how_to_reg_outlined,
        t.modcp.memberReview,
        () => MemberReviewPage(repository: repository),
      ),
      if (_offers((m) => m.canEditForum))
        (
          const ValueKey('modcp-rules'),
          Icons.rule_outlined,
          t.modcp.rules,
          () => ForumRulesPage(repository: repository),
        ),
      if (_offers((m) => m.canAnnounce))
        (
          const ValueKey('modcp-announcements'),
          Icons.campaign_outlined,
          t.modcp.announcements,
          () => AnnouncementsPage(repository: repository),
        ),
    ];
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.modcp.panel)),
      body: SafeArea(
        top: false,
        child: AppCenteredList(
          builder: (context, padding, _) => GridView.extent(
            key: const ValueKey('modcp-grid'),
            maxCrossAxisExtent: 160,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.3,
            padding: padding.copyWith(top: 12, bottom: 12),
            children: [
              for (final (key, icon, label, page) in entries)
                Material(
                  key: key,
                  color: colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(appInnerRadius),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => unawaited(
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page())),
                    ),
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

/// The view of an answer that is not the page: the panel's refusal in its own words, or why it could not be had.
Widget modcpErrorView(
  BuildContext context,
  Either<AppException, ModcpAnswer<Object?>>? answer, {
  VoidCallback? onRetry,
}) {
  final message = switch (answer) {
    Right(value: ModcpRefused(:final message)) when message.isNotEmpty => message,
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
