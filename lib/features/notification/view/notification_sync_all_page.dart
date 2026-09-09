import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/list.dart';
import 'package:tsdm_client/features/checkin/widgets/auto_checkin_user_card.dart';
import 'package:tsdm_client/features/notification/bloc/notification_sync_all_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/tips.dart';

/// Page showing the progress and the result of the sync of the notifications of all accounts.
///
/// Cloned from `AutoCheckinPage`: one card per account, running first, then waiting, then done with the result.
class NotificationSyncAllPage extends StatelessWidget {
  /// Constructor.
  const NotificationSyncAllPage({super.key});

  /// Text of [result] on the account card.
  static String message(BuildContext context, NotificationSyncResult result) {
    final tr = context.t.noticePage.syncAllPage.user;
    return switch (result) {
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
        return Scaffold(
          appBar: AppBar(title: Text(tr.title)),
          body: SafeArea(
            bottom: false,
            child: ListView(
              padding: edgeInsetsL12T4R12.add(context.safePadding()),
              children: <Widget>[
                Tips(tr.detail, enablePadding: false),
                if (preparing) const CenteredCircularIndicator(),
                if (empty) Center(child: Text(tr.empty)),
                ...runningList.map((e) => AutoCheckinUserCard(e, tr.user.running)),
                ...waitingList.map((e) => AutoCheckinUserCard(e, tr.user.waiting)),
                ...finishedList.map(
                  (e) => AutoCheckinUserCard(
                    // Ok to use record.
                    // ignore: avoid_positional_fields_in_records
                    e.$1,
                    // Ok to use record.
                    // ignore: avoid_positional_fields_in_records
                    message(context, e.$2),
                    // Ok to use record.
                    // ignore: avoid_positional_fields_in_records
                    failure: e.$2 is! NotificationSyncResultSuccess,
                  ),
                ),
              ].insertBetween(sizedBoxW8H8),
            ),
          ),
        );
      },
    );
  }
}
