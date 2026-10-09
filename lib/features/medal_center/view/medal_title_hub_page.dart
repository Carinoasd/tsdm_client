import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/medal_title_tools/repository/medal_title_tools_repository.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Common entry of the medal centre, the titles of the current account and the title shop.
///
/// Testers found the title shop only behind avatar > profile > menu > my titles > shop. This page links the three
/// existing pages side by side, each one keeps its own route, flow and confirmations; nothing is bought or switched
/// here.
class MedalTitleHubPage extends StatelessWidget {
  /// Constructor.
  const MedalTitleHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = context.t.medalTitleHub;
    final tools = context.t.medalTitleTools;
    final uid = context.readOrNull<AuthenticationRepository>()?.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(title: Text(tr.title)),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: appFormMaxWidth),
            child: ListView(
              padding: edgeInsetsL16T16R16B16,
              children: [
                _CurrentTitleCard(uid: uid),
                sizedBoxW16H16,
                _HubDestination(
                  icon: Icons.workspace_premium_outlined,
                  title: context.t.medalCenter.title,
                  description: tr.medalCenterDescription,
                  path: ScreenPaths.medalCenter,
                ),
                sizedBoxW12H12,
                _HubDestination(
                  icon: Icons.badge_outlined,
                  title: context.t.myTitlesPage.title,
                  description: tr.myTitlesDescription,
                  path: ScreenPaths.switchTitle,
                ),
                sizedBoxW12H12,
                _HubDestination(
                  icon: Icons.shopping_bag_outlined,
                  title: context.t.titleShop.title,
                  description: tr.titleShopDescription,
                  path: ScreenPaths.titleShop,
                ),
                if (uid != null) ...[
                  sizedBoxW12H12,
                  _HubDestination(
                    icon: Icons.swap_horiz_outlined,
                    title: tools.exchangeTitle,
                    description: tools.hubExchange,
                    path: ScreenPaths.titleExchange,
                  ),
                  sizedBoxW12H12,
                  _HubDestination(
                    icon: Icons.military_tech_outlined,
                    title: tools.myMedalsTitle,
                    description: tools.hubMyMedals,
                    path: ScreenPaths.myMedals,
                  ),
                  _StaffDestinations(uid: uid),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The title the current account uses, read once per account.
class _CurrentTitleCard extends StatelessWidget {
  const _CurrentTitleCard({required this.uid});

  final int? uid;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.medalTitleHub;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final cubit = context.readOrNull<CurrentTitleCubit>();
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr.currentTitle, style: textTheme.titleMedium),
        sizedBoxW4H4,
        if (cubit != null && uid != null)
          BlocBuilder<CurrentTitleCubit, CurrentTitleState>(
            bloc: cubit,
            builder: (context, state) {
              final String text;
              if (state.uid != uid) {
                text = '';
              } else {
                text = switch (state.status) {
                  CurrentTitleStatus.success => state.title?.name ?? tr.noTitle,
                  CurrentTitleStatus.failure => tr.loadFailed,
                  CurrentTitleStatus.initial || CurrentTitleStatus.loading => state.title?.name ?? '',
                };
              }
              return Text(text, style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant));
            },
          ),
      ],
    );
    return AppSurface(
      color: colorScheme.surfaceContainerLow,
      padding: edgeInsetsL16T16R16B16,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The title at its natural 184px width beside the text when there is room, below it otherwise.
          final badgeWidth = SecondaryTitleBadge.fitWidth(constraints.maxWidth);
          if (constraints.maxWidth - badgeWidth - 12 >= 160) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: info),
                CurrentAccountTitleBadge(
                  uid: uid,
                  width: badgeWidth,
                  padding: const EdgeInsetsDirectional.only(start: 12),
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              info,
              CurrentAccountTitleBadge(uid: uid, width: badgeWidth, padding: const EdgeInsets.only(top: 12)),
            ],
          );
        },
      ),
    );
  }
}

/// A card linking an existing page.
class _HubDestination extends StatelessWidget {
  const _HubDestination({required this.icon, required this.title, required this.description, required this.path});

  final IconData icon;
  final String title;
  final String description;
  final String path;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: DecoratedBox(
          decoration: BoxDecoration(color: colorScheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, color: colorScheme.onPrimaryContainer),
          ),
        ),
        title: Text(title),
        subtitle: Text(description),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async => context.pushNamed(path),
      ),
    );
  }
}

/// Sending medals and issuing titles, shown only to the accounts the forum lets use them.
///
/// Whether the account may is asked once and kept for ten minutes: the answers carry the whole medal list and the
/// latest sendings, too much to read each time this page opens.
class _StaffDestinations extends StatefulWidget {
  const _StaffDestinations({required this.uid});

  final int uid;

  static final _known = <int, ({bool grant, bool issue, DateTime at})>{};

  @override
  State<_StaffDestinations> createState() => _StaffDestinationsState();
}

class _StaffDestinationsState extends State<_StaffDestinations> {
  ({bool grant, bool issue})? _can;

  @override
  void initState() {
    super.initState();
    final known = _StaffDestinations._known[widget.uid];
    if (known != null && DateTime.now().difference(known.at) < const Duration(minutes: 10)) {
      _can = (grant: known.grant, issue: known.issue);
    } else {
      unawaited(_ask());
    }
  }

  Future<void> _ask() async {
    final repo = MedalTitleToolsRepository.network(getIt.get<NetClientProvider>());
    try {
      final grant = await repo.grant();
      final issue = await repo.issue();
      final can = (grant: grant?.canGrant ?? false, issue: issue?.canIssue ?? false);
      _StaffDestinations._known[widget.uid] = (grant: can.grant, issue: can.issue, at: DateTime.now());
      if (mounted) setState(() => _can = can);
    } on Exception {
      // Not shown; the website has them.
    }
  }

  @override
  Widget build(BuildContext context) {
    final can = _can;
    final tools = context.t.medalTitleTools;
    if (can == null) return const SizedBox.shrink();
    return Column(
      children: [
        if (can.grant) ...[
          sizedBoxW12H12,
          _HubDestination(
            icon: Icons.card_giftcard_outlined,
            title: tools.grantTitle,
            description: tools.hubGrant,
            path: ScreenPaths.medalGrant,
          ),
        ],
        if (can.issue) ...[
          sizedBoxW12H12,
          _HubDestination(
            icon: Icons.verified_outlined,
            title: tools.issueTitle,
            description: tools.hubIssue,
            path: ScreenPaths.titleIssue,
          ),
        ],
      ],
    );
  }
}
