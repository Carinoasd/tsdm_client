import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/friend/widgets/friend_picker_sheet.dart';
import 'package:tsdm_client/features/thread/v1/repository/share_thread_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Thread page menu action: pick a friend and send them the thread title and link as a private message (#23).
Future<void> shareThreadToFriend(
  BuildContext context, {
  required String tid,
  required String title,
  ShareThreadRepository repository = const ShareThreadRepository(),
}) async {
  final tr = context.t.threadPage.shareToFriend;
  final friend = await showFriendPicker(context);
  if (friend == null || !context.mounted) {
    return;
  }
  final message = tr.message(title: title, url: '$baseUrl/forum.php?mod=viewthread&tid=$tid');
  final result = await repository.sendToFriend(uid: friend.uid, message: message).run();
  if (!context.mounted) {
    return;
  }
  switch (result) {
    case Left(:final value):
      showSnackBar(
        context: context,
        clearPrevious: true,
        message: tr.failed(err: value.toString()),
      );
    case Right():
      showSnackBar(
        context: context,
        clearPrevious: true,
        message: tr.sent(name: friend.username),
      );
  }
}
