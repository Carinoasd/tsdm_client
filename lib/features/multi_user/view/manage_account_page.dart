import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/checkin/bloc/auto_checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/utils/checkin_day.dart';
import 'package:tsdm_client/features/multi_user/bloc/switch_user_bloc.dart';
import 'package:tsdm_client/features/multi_user/widgets/manage_user_dialog.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Page to manage user account for multi-user target.
class ManageAccountPage extends StatefulWidget {
  /// Constructor.
  const ManageAccountPage({super.key});

  @override
  State<ManageAccountPage> createState() => _ManageAccountPageState();
}

class _ManageAccountPageState extends State<ManageAccountPage> {
  @override
  Widget build(BuildContext context) {
    final tr = context.t.manageAccountPage;
    return BlocProvider(
      create: (context) => SwitchUserBloc(context.repo()),
      child: BlocConsumer<SwitchUserBloc, SwitchUserBaseState>(
        listener: (context, state) {
          if (state case SwitchUserFailure(:final reason)) {
            final errorText = switch (reason) {
              SwitchUserNotAuthedException() => context.t.loginPage.perhapsExpired,
              _ => context.t.general.failedToLoad,
            };
            showSnackBar(context: context, message: errorText);
            context.read<AutoNotificationCubit>().resume('switch user');
          } else if (state case SwitchUserSuccess()) {
            showSnackBar(context: context, message: context.t.manageAccountPage.switchAccount.success);
            context.read<AutoNotificationCubit>().resume('switch user');
          }
        },
        builder: (context, state) {
          final body = Scaffold(
            appBar: AppBar(title: Text(tr.title)),
            body: SafeArea(
              bottom: false,
              child: SingleChildScrollView(
                child: StreamBuilder(
                  stream: getIt.get<StorageProvider>().allUsersWithTimeStream(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      // Unreachable.
                      return Center(child: Text('${snapshot.error}'));
                    }
                    if (!snapshot.hasData) {
                      return const CenteredCircularIndicator();
                    }

                    final tr = context.t.manageAccountPage;

                    final currentUser = context.read<AuthenticationRepository>().currentUser;
                    final users = snapshot.data!;
                    return Padding(
                      padding: edgeInsetsL12T4R12B4,
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: edgeInsetsL12T12R12.add(context.safePadding()),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Text(tr.allUsers, style: Theme.of(context).textTheme.titleMedium),
                                  if (state is SwitchUserLoading) ...[sizedBoxW12H12, sizedCircularProgressIndicator],
                                ],
                              ),
                              sizedBoxW4H4,
                              // List all recorded users.
                              ...users
                                  .where(
                                    (e) =>
                                        e.$1.username != null &&
                                        e.$1.username!.isNotEmpty &&
                                        e.$1.uid != null &&
                                        e.$1.uid != 0,
                                  )
                                  .map(
                                    (e) => _UserInfoListTile(
                                      userInfo: e.$1,
                                      lastCheckin: e.$2,
                                      currentUserInfo: currentUser,
                                    ),
                                  ),
                              ListTile(
                                leading: const Icon(Icons.add_outlined),
                                title: Text(tr.addUser),
                                enabled: state is! SwitchUserLoading,
                                onTap: () async => context.pushNamed(ScreenPaths.login),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          );
          return body;
        },
      ),
    );
  }
}

class _UserInfoListTile extends StatelessWidget with LoggerMixin {
  const _UserInfoListTile({required this.userInfo, required this.lastCheckin, required this.currentUserInfo});

  /// User info displayed in this widget.
  final UserLoginInfo userInfo;

  /// When this account last checked in from this device, null when never.
  final DateTime? lastCheckin;

  /// Current login user.
  final UserLoginInfo? currentUserInfo;

  /// Why this account did not check in during the auto check-in of this app run, null when it did or when nothing
  /// is known.
  ///
  /// "Already checked in" is not a failure: it is recorded as checked in today like a success.
  String? _autoCheckinFailure(BuildContext context) {
    final state = context.watch<AutoCheckinBloc>().state;
    if (state is! AutoCheckinStateFinished) {
      return null;
    }
    for (final (user, result) in state.failed) {
      if (user.uid == userInfo.uid && result is! CheckinResultAlreadyChecked) {
        return CheckinResult.message(context, result);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.manageAccountPage;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isCurrentUser = userInfo.uid! == currentUserInfo?.uid;
    final checkedIn = isCheckedInToday(lastCheckin);
    final failure = checkedIn ? null : _autoCheckinFailure(context);

    return BlocBuilder<SwitchUserBloc, SwitchUserBaseState>(
      builder: (context, state) {
        final loading = state is SwitchUserLoading;
        return ListTile(
          enabled: !loading,
          leading: HeroUserAvatar(username: userInfo.username!, avatarUrl: null, disableHero: true),
          title: Text(userInfo.username!),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${userInfo.uid!}'),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    checkedIn ? Icons.check_circle_outline : Icons.radio_button_unchecked,
                    size: 16,
                    color: checkedIn ? colorScheme.primary : colorScheme.outline,
                  ),
                  sizedBoxW4H4,
                  Flexible(child: Text(checkedIn ? tr.checkin.today : tr.checkin.notYet)),
                ],
              ),
              if (failure != null) Text(failure, style: textTheme.bodySmall?.copyWith(color: colorScheme.error)),
            ],
          ),
          trailing: isCurrentUser
              ? Chip(
                  side: BorderSide.none,
                  backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                  label: Text(
                    tr.online,
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSecondaryContainer),
                  ),
                )
              : null,
          onTap: loading
              ? null
              : () async => openManageUserDialog(
                  context: context,
                  userInfo: userInfo,
                  heroTag: '',
                  isCurrentUser: isCurrentUser,
                ),
        );
      },
    );
  }
}
