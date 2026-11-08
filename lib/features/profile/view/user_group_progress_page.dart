import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/profile/bloc/user_group_progress_cubit.dart';
import 'package:tsdm_client/features/profile/models/user_group_progress.dart';
import 'package:tsdm_client/features/profile/repository/user_group_progress_repository.dart';
import 'package:tsdm_client/features/profile/widgets/user_group_progress_bar.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';

/// The credits every user group starts at, the current group marked, under the progress towards the next one.
///
/// The groups the member has besides the main one are listed and can not be switched here.
final class UserGroupProgressPage extends StatefulWidget {
  /// Constructor.
  const UserGroupProgressPage({super.key});

  @override
  State<UserGroupProgressPage> createState() => _UserGroupProgressPageState();
}

class _UserGroupProgressPageState extends State<UserGroupProgressPage> {
  late final UserGroupProgressCubit _cubit = UserGroupProgressCubit(UserGroupProgressRepository())..load(detail: true);

  @override
  void dispose() {
    unawaited(_cubit.close());
    super.dispose();
  }

  Widget _buildContent(BuildContext context, UserGroupProgress progress) {
    final colorScheme = Theme.of(context).colorScheme;
    return AppCenteredList(
      maxWidth: appFormMaxWidth,
      builder: (context, side, _) => ListView(
        padding: side.copyWith(top: 8, bottom: 24),
        children: [
          AppSurface(child: UserGroupProgressBar(progress)),
          sizedBoxW8H8,
          AppSurface(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final tier in progress.tiers)
                  SectionListTile(
                    selected: progress.currentGid != null
                        ? tier.gid == progress.currentGid
                        : tier.name == progress.mainGroupName,
                    selectedTileColor: colorScheme.primaryContainer.withValues(alpha: 0.4),
                    title: Text(tier.name),
                    trailing: Text(tier.creditsFrom < 0 ? '—' : '${tier.creditsFrom}'),
                  ),
              ],
            ),
          ),
          if (progress.extraGroups.isNotEmpty) ...[
            sizedBoxW8H8,
            AppSurface(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  AppSectionHeader(
                    context.t.userGroupProgress.extraGroups,
                    padding: edgeInsetsL16T12R16B12,
                  ),
                  for (final name in progress.extraGroups) SectionListTile(title: Text(name)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UserGroupProgressCubit, UserGroupProgressState>(
      bloc: _cubit,
      builder: (context, state) {
        final progress = state.progress;
        final body = switch (state.status) {
          UserGroupProgressStatus.initial || UserGroupProgressStatus.loading => const CenteredCircularIndicator(),
          UserGroupProgressStatus.failure => buildRetryButton(
            context,
            () => unawaited(_cubit.load(detail: true)),
            message: context.t.general.failedToLoad,
          ),
          UserGroupProgressStatus.success =>
            progress == null
                ? Center(child: Text(context.t.userGroupProgress.noNext))
                : _buildContent(context, progress),
        };
        return Scaffold(
          appBar: AppBar(title: Text(context.t.userGroupProgress.title)),
          body: SafeArea(bottom: false, child: body),
        );
      },
    );
  }
}
