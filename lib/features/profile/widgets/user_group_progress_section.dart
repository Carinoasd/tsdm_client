import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/profile/bloc/user_group_progress_cubit.dart';
import 'package:tsdm_client/features/profile/repository/user_group_progress_repository.dart';
import 'package:tsdm_client/features/profile/widgets/user_group_progress_bar.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The user group progress of the logged in account on its own profile page; nothing for an account without a next
/// credit-based group, nothing while it is read. Tapping it opens the table of every group.
class UserGroupProgressSection extends StatefulWidget {
  /// Constructor.
  const UserGroupProgressSection({super.key});

  @override
  State<UserGroupProgressSection> createState() => _UserGroupProgressSectionState();
}

class _UserGroupProgressSectionState extends State<UserGroupProgressSection> {
  late final UserGroupProgressCubit _cubit = UserGroupProgressCubit(UserGroupProgressRepository())..load();

  @override
  void dispose() {
    unawaited(_cubit.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UserGroupProgressCubit, UserGroupProgressState>(
      bloc: _cubit,
      builder: (context, state) {
        final progress = state.progress;
        if (progress == null) {
          if (state.status != UserGroupProgressStatus.failure) {
            return sizedBoxEmpty;
          }
          return AppSurface(
            child: AppSectionHeader(
              context.t.userGroupProgress.title,
              icon: Icons.trending_up_outlined,
              padding: EdgeInsets.zero,
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: context.t.general.retry,
                onPressed: () => unawaited(_cubit.load()),
              ),
            ),
          );
        }
        return AppSurface(
          onTap: () async => context.pushNamed(ScreenPaths.userGroupProgress),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSectionHeader(
                context.t.userGroupProgress.title,
                icon: Icons.trending_up_outlined,
                padding: const EdgeInsets.only(bottom: 8),
                trailing: const Icon(Icons.chevron_right),
              ),
              UserGroupProgressBar(progress),
            ],
          ),
        );
      },
    );
  }
}
