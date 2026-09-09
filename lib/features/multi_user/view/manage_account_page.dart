import 'dart:async';

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
import 'package:tsdm_client/features/multi_user/bloc/manage_account_bloc.dart';
import 'package:tsdm_client/features/multi_user/bloc/switch_user_bloc.dart';
import 'package:tsdm_client/features/multi_user/widgets/manage_user_dialog.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_sync_all_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Page to manage user account for multi-user target.
///
/// Lists every account saved on this device with its check-in state of today. A long press on an account, or the
/// select action in the app bar, enters selection mode where accounts can be deleted from this device together.
class ManageAccountPage extends StatefulWidget {
  /// Constructor.
  const ManageAccountPage({super.key});

  @override
  State<ManageAccountPage> createState() => _ManageAccountPageState();
}

class _ManageAccountPageState extends State<ManageAccountPage> {
  /// Subscribed once: the drift stream queries again for every new subscriber.
  late final Stream<List<(UserLoginInfo, DateTime?)>> _users = getIt.get<StorageProvider>().allUsersWithTimeStream();

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (context) => SwitchUserBloc(context.repo())),
        BlocProvider(
          create: (context) => ManageAccountBloc(
            storageProvider: getIt.get<StorageProvider>(),
            authenticationRepository: context.repo(),
          ),
        ),
      ],
      child: MultiBlocListener(
        listeners: [
          BlocListener<SwitchUserBloc, SwitchUserBaseState>(
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
          ),
          BlocListener<ManageAccountBloc, ManageAccountState>(
            listenWhen: (prev, curr) => prev.status != curr.status,
            listener: (context, state) {
              switch (state.status) {
                case ManageAccountStatus.deleted:
                  showSnackBar(
                    context: context,
                    message: context.t.manageAccountPage.selection.deleted(count: state.deletedCount),
                  );
                case ManageAccountStatus.failed:
                  showSnackBar(context: context, message: context.t.general.failedToLoad);
                case ManageAccountStatus.idle || ManageAccountStatus.deleting:
                  break;
              }
            },
          ),
        ],
        child: StreamBuilder(
          stream: _users,
          builder: (context, snapshot) {
            final users = (snapshot.data ?? const <(UserLoginInfo, DateTime?)>[])
                .where((e) => e.$1.username != null && e.$1.username!.isNotEmpty && e.$1.uid != null && e.$1.uid != 0)
                .toList();
            return BlocBuilder<ManageAccountBloc, ManageAccountState>(
              builder: (context, selection) => BlocBuilder<SwitchUserBloc, SwitchUserBaseState>(
                builder: (context, state) => _buildPage(context, snapshot, users, selection, state),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildPage(
    BuildContext context,
    AsyncSnapshot<List<(UserLoginInfo, DateTime?)>> snapshot,
    List<(UserLoginInfo, DateTime?)> users,
    ManageAccountState selection,
    SwitchUserBaseState state,
  ) {
    final tr = context.t.manageAccountPage;
    final switching = state is SwitchUserLoading;
    final deleting = selection.status == ManageAccountStatus.deleting;
    // Also the account whose stored session was not verified yet (offline start, expired session).
    final currentUid = context.read<AuthenticationRepository>().effectiveCurrentUid;
    final busy = switching || deleting;

    final Widget body;
    if (snapshot.hasError) {
      // Unreachable.
      body = Center(child: Text('${snapshot.error}'));
    } else if (!snapshot.hasData) {
      body = const CenteredCircularIndicator();
    } else {
      body = SingleChildScrollView(
        child: Padding(
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
                      if (busy) ...[sizedBoxW12H12, sizedCircularProgressIndicator],
                    ],
                  ),
                  sizedBoxW4H4,
                  // List all recorded users.
                  ...users.map(
                    (e) => _UserInfoListTile(
                      userInfo: e.$1,
                      lastCheckin: e.$2,
                      currentUid: currentUid,
                      selecting: selection.selecting,
                      selected: selection.selectedUids.contains(e.$1.uid),
                      enabled: !busy,
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.add_outlined),
                    title: Text(tr.addUser),
                    enabled: !busy && !selection.selecting,
                    onTap: () async => context.pushNamed(ScreenPaths.login),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return PopScope(
      canPop: !selection.selecting,
      onPopInvokedWithResult: (didPop, _) {
        // Back leaves selection mode first; while deleting it is swallowed like the disabled close button.
        if (!didPop && !deleting) {
          context.read<ManageAccountBloc>().add(const ManageAccountSelectionCleared());
        }
      },
      child: Scaffold(
        appBar: selection.selecting
            ? _buildSelectionAppBar(context, selection, users, currentUid)
            : AppBar(
                title: Text(tr.title),
                actions: [
                  BlocBuilder<NotificationSyncAllCubit, NotificationSyncAllState>(
                    builder: (context, syncState) {
                      final syncing =
                          syncState is NotificationSyncAllStatePreparing ||
                          syncState is NotificationSyncAllStateRunning;
                      return IconButton(
                        icon: const Icon(Icons.sync_outlined),
                        tooltip: tr.syncAll.title,
                        onPressed: busy || syncing || users.isEmpty
                            ? null
                            : () async {
                                unawaited(context.read<NotificationSyncAllCubit>().start());
                                await context.pushNamed(ScreenPaths.notificationSyncAll);
                              },
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.checklist_outlined),
                    tooltip: tr.selection.enter,
                    onPressed: busy || users.isEmpty
                        ? null
                        : () => context.read<ManageAccountBloc>().add(const ManageAccountSelectionStarted()),
                  ),
                ],
              ),
        body: SafeArea(bottom: false, child: body),
      ),
    );
  }

  AppBar _buildSelectionAppBar(
    BuildContext context,
    ManageAccountState selection,
    List<(UserLoginInfo, DateTime?)> users,
    int? currentUid,
  ) {
    final tr = context.t.manageAccountPage.selection;
    final bloc = context.read<ManageAccountBloc>();
    final deleting = selection.status == ManageAccountStatus.deleting;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: context.t.general.close,
        onPressed: deleting ? null : () => bloc.add(const ManageAccountSelectionCleared()),
      ),
      title: Text(tr.count(count: selection.selectedUids.length)),
      actions: [
        IconButton(
          icon: const Icon(Icons.select_all_outlined),
          tooltip: tr.selectAll,
          onPressed: deleting
              ? null
              : () => bloc.add(ManageAccountSelectAllRequested(users.map((e) => e.$1.uid!).toList())),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: tr.delete,
          onPressed: deleting || selection.selectedUids.isEmpty
              ? null
              : () async {
                  final includesCurrent = currentUid != null && selection.selectedUids.contains(currentUid);
                  final confirmed = await showQuestionDialog(
                    context: context,
                    title: tr.delete,
                    message: [
                      tr.confirm(count: selection.selectedUids.length),
                      if (includesCurrent) tr.currentHint,
                    ].join('\n\n'),
                    dangerous: true,
                  );
                  if (confirmed != true || !context.mounted) {
                    return;
                  }
                  bloc.add(const ManageAccountDeleteSelectedRequested());
                },
        ),
      ],
    );
  }
}

class _UserInfoListTile extends StatelessWidget with LoggerMixin {
  const _UserInfoListTile({
    required this.userInfo,
    required this.lastCheckin,
    required this.currentUid,
    required this.selecting,
    required this.selected,
    required this.enabled,
  });

  /// User info displayed in this widget.
  final UserLoginInfo userInfo;

  /// When this account last checked in from this device, null when never.
  final DateTime? lastCheckin;

  /// Uid of the current account, see [AuthenticationRepository.effectiveCurrentUid].
  final int? currentUid;

  /// Whether the page is in selection mode.
  final bool selecting;

  /// Whether this account is selected.
  final bool selected;

  /// Whether the tile reacts to taps.
  final bool enabled;

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
    final isCurrentUser = userInfo.uid! == currentUid;
    final checkedIn = isCheckedInToday(lastCheckin);
    final failure = checkedIn ? null : _autoCheckinFailure(context);
    final bloc = context.read<ManageAccountBloc>();

    return ListTile(
      enabled: enabled,
      selected: selected,
      selectedTileColor: colorScheme.primaryContainer.withValues(alpha: 0.35),
      leading: selected
          ? CircleAvatar(
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              child: const Icon(Icons.check),
            )
          : HeroUserAvatar(username: userInfo.username!, avatarUrl: null, disableHero: true),
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
              backgroundColor: colorScheme.secondaryContainer,
              label: Text(
                tr.online,
                style: textTheme.labelMedium?.copyWith(color: colorScheme.onSecondaryContainer),
              ),
            )
          : null,
      onTap: !enabled
          ? null
          : selecting
          ? () => bloc.add(ManageAccountSelectionToggled(userInfo.uid!))
          : () async =>
                openManageUserDialog(context: context, userInfo: userInfo, heroTag: '', isCurrentUser: isCurrentUser),
      onLongPress: !enabled || selecting ? null : () => bloc.add(ManageAccountSelectionToggled(userInfo.uid!)),
    );
  }
}
