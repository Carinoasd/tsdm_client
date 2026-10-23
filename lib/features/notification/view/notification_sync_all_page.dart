import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/notification/bloc/notification_sync_all_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Page showing the progress and the result of the sync of the notifications of all accounts.
///
/// A summary on top (what the sync does, how many accounts are running, waiting and done), then one section per
/// state: running first, then waiting, then done with the result of each account.
class NotificationSyncAllPage extends StatelessWidget {
  /// Constructor.
  const NotificationSyncAllPage({super.key});

  /// Text of [result] on the account card.
  static String message(BuildContext context, NotificationSyncResult result) {
    final tr = context.t.noticePage.syncAllPage.user;
    return switch (result) {
      NotificationSyncResultSuccess(
        recent: true,
        :final unreadNotice,
        :final unreadPersonalMessage,
        :final unreadBroadcastMessage,
      ) =>
        tr.recent(unreadNotice: unreadNotice, unreadPm: unreadPersonalMessage, unreadBm: unreadBroadcastMessage),
      NotificationSyncResultSuccess(
        :final newNotice,
        :final newPersonalMessage,
        :final newBroadcastMessage,
        :final unreadNotice,
        :final unreadPersonalMessage,
        :final unreadBroadcastMessage,
      ) =>
        tr.success(
          notice: newNotice,
          pm: newPersonalMessage,
          bm: newBroadcastMessage,
          unreadNotice: unreadNotice,
          unreadPm: unreadPersonalMessage,
          unreadBm: unreadBroadcastMessage,
        ),
      NotificationSyncResultNotAuthorized() => tr.notAuthed,
      NotificationSyncResultRateLimited() => tr.rateLimited,
      NotificationSyncResultFailed(:final message) => tr.failed(message: message),
    };
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.noticePage.syncAllPage;
    return BlocBuilder<NotificationSyncAllCubit, NotificationSyncAllState>(
      builder: (context, state) {
        var waitingList = <UserLoginInfo>[];
        var runningList = <UserLoginInfo>[];
        var finishedList = <(UserLoginInfo, NotificationSyncResult)>[];
        var preparing = false;
        var empty = false;
        switch (state) {
          case NotificationSyncAllStateIdle():
            break;
          case NotificationSyncAllStatePreparing():
            preparing = true;
          case NotificationSyncAllStateRunning(:final info):
            waitingList = info.waiting;
            runningList = info.running;
            finishedList = info.finished;
          case NotificationSyncAllStateFinished(:final results):
            finishedList = results;
            empty = results.isEmpty;
        }
        final busy = preparing || runningList.isNotEmpty || waitingList.isNotEmpty;
        return Scaffold(
          appBar: AppBar(title: Text(tr.title)),
          body: SafeArea(
            bottom: false,
            child: AppCenteredList(
              maxWidth: appFormMaxWidth,
              builder: (context, side, _) => ListView(
                padding: side.copyWith(top: 8, bottom: 12).add(context.safePadding()),
                children: [
                  _SummarySurface(
                    detail: tr.detail,
                    busy: busy,
                    counts: [
                      (Icons.sync_outlined, tr.running, runningList.length),
                      (Icons.hourglass_empty_outlined, tr.user.waiting, waitingList.length),
                      (Icons.task_alt_outlined, tr.finished, finishedList.length),
                    ],
                  ),
                  if (empty) ...[
                    sizedBoxW12H12,
                    AppStateView(icon: Icons.person_off_outlined, message: tr.empty, scrollable: false),
                  ],
                  ..._section(
                    tr.running,
                    Icons.sync_outlined,
                    runningList.map((e) => _AccountSurface(e, tr.user.running, state: _AccountState.running)),
                  ),
                  ..._section(
                    tr.user.waiting,
                    Icons.hourglass_empty_outlined,
                    waitingList.map((e) => _AccountSurface(e, tr.user.waiting, state: _AccountState.waiting)),
                  ),
                  ..._section(
                    tr.finished,
                    Icons.task_alt_outlined,
                    finishedList.map(
                      (e) => _AccountSurface(
                        // Ok to use record.
                        // ignore: avoid_positional_fields_in_records
                        e.$1,
                        // Ok to use record.
                        // ignore: avoid_positional_fields_in_records
                        message(context, e.$2),
                        // Ok to use record.
                        // ignore: avoid_positional_fields_in_records
                        state: e.$2 is NotificationSyncResultSuccess ? _AccountState.done : _AccountState.failed,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// A titled group of account surfaces, nothing when [cards] is empty.
  static List<Widget> _section(String title, IconData icon, Iterable<Widget> cards) {
    final list = cards.toList();
    if (list.isEmpty) {
      return const [];
    }
    return [
      AppSectionHeader(title, icon: icon, padding: const EdgeInsets.only(top: 16, bottom: 8)),
      for (final (index, card) in list.indexed) ...[if (index > 0) appListSeparator, card],
    ];
  }
}

/// Explanation of the sync and the number of accounts in each state.
class _SummarySurface extends StatelessWidget {
  const _SummarySurface({required this.detail, required this.busy, required this.counts});

  final String detail;

  /// Show a progress bar.
  final bool busy;

  /// Icon, name and number of accounts of each state.
  final List<(IconData, String, int)> counts;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AppSurface(
      padding: edgeInsetsL16T16R16B16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppIconTile(Icons.sync_outlined),
              sizedBoxW12H12,
              Expanded(
                child: Text(
                  detail,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          sizedBoxW12H12,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // Ok to use record.
              // ignore: avoid_positional_fields_in_records
              for (final e in counts) AppInfoPill(icon: e.$1, label: '${e.$2} ${e.$3}'),
            ],
          ),
          if (busy) ...[
            sizedBoxW12H12,
            ClipRRect(
              borderRadius: BorderRadius.circular(appInnerRadius),
              child: const LinearProgressIndicator(minHeight: 4),
            ),
          ],
        ],
      ),
    );
  }
}

enum _AccountState { running, waiting, done, failed }

/// One account in the sync: avatar letter, name and uid, state icon and the message of its state or result.
///
/// A tap opens the notice page as that account, switching to it first when another one is in use, the same way as a
/// tap on the system notification of that account ([openNoticePageOfAccount]).
class _AccountSurface extends StatelessWidget {
  const _AccountSurface(this.userInfo, this.message, {required this.state});

  final UserLoginInfo userInfo;

  final String message;

  final _AccountState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final failed = state == _AccountState.failed;
    final name = userInfo.username ?? '${userInfo.uid ?? ''}';
    final stateIcon = switch (state) {
      _AccountState.running => const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      _AccountState.waiting => Icon(Icons.hourglass_empty_outlined, size: 20, color: colorScheme.outline),
      _AccountState.done => Icon(Icons.check_circle_outline, size: 20, color: colorScheme.primary),
      _AccountState.failed => Icon(Icons.error_outline, size: 20, color: colorScheme.error),
    };
    final uid = userInfo.uid;
    return AppSurface(
      key: ValueKey('sync-all-account-$uid'),
      color: failed ? colorScheme.errorContainer : null,
      onTap: uid == null || uid <= 0 ? null : () async => openNoticePageOfAccount(context, uid: uid),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(child: Text(name.isEmpty ? '?' : name.characters.first)),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (userInfo.uid != null)
                      Text(
                        'UID ${userInfo.uid}',
                        style: textTheme.labelSmall?.copyWith(
                          color: failed ? colorScheme.onErrorContainer : colorScheme.outline,
                        ),
                      ),
                  ],
                ),
              ),
              sizedBoxW8H8,
              stateIcon,
              if (uid != null && uid > 0)
                Tooltip(
                  message: context.t.noticePage.syncAllPage.user.open,
                  child: Icon(
                    Icons.chevron_right,
                    color: failed ? colorScheme.onErrorContainer : colorScheme.outline,
                  ),
                ),
            ],
          ),
          sizedBoxW8H8,
          Text(
            message,
            style: textTheme.labelMedium?.copyWith(
              color: failed ? colorScheme.onErrorContainer : colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
