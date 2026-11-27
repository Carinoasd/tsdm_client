import 'package:flutter/material.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/action_sheet.dart';

/// A way to share or copy a thread.
enum ThreadShareAction {
  /// Copy the short link of the thread.
  copyLink,

  /// Copy the title with the link, as the app reads it back from the clipboard.
  copyShareText,

  /// Show the link as a QR code.
  qrCode,

  /// Send the thread to a friend in a private message.
  toFriend,

  /// Open the thread in the browser.
  openInBrowser,

  /// Pin the thread to the home screen of the device.
  pinToHome,

  /// Copy the thread id.
  copyTid,
}

/// Ask which way to share or copy the thread; null when the sheet was dismissed.
///
/// Only [offered] are shown (the page decides: no friend while offline or signed out, no pin where the platform has
/// none, nothing of the thread id before it is known), in the order of the sheet: the ones used most as icons, the
/// others listed under them. [tid] is named in the row copying it.
///
/// The sheet is closed when this returns: the caller runs what was picked from its own context.
Future<ThreadShareAction?> showThreadShareSheet(
  BuildContext context, {
  required Set<ThreadShareAction> offered,
  String? tid,
}) {
  final t = context.t;
  ActionSheetItem<ThreadShareAction> item(ThreadShareAction action) => ActionSheetItem(
    value: action,
    icon: switch (action) {
      ThreadShareAction.copyLink => Icons.copy_outlined,
      ThreadShareAction.copyShareText => Icons.share_outlined,
      ThreadShareAction.qrCode => Icons.qr_code_2_outlined,
      ThreadShareAction.toFriend => Icons.forward_to_inbox_outlined,
      ThreadShareAction.openInBrowser => Icons.open_in_browser,
      ThreadShareAction.pinToHome => Icons.add_to_home_screen_outlined,
      ThreadShareAction.copyTid => Icons.numbers_outlined,
    },
    label: switch (action) {
      ThreadShareAction.copyLink => t.networkList.actionCopyUrl,
      ThreadShareAction.copyShareText => t.linkToken.copyShareText,
      ThreadShareAction.qrCode => t.shareQr.title,
      ThreadShareAction.toFriend => t.threadPage.shareToFriend.title,
      ThreadShareAction.openInBrowser => t.networkList.actionOpenInBrowser,
      ThreadShareAction.pinToHome => t.appShortcuts.pinToHome,
      ThreadShareAction.copyTid => t.threadPage.copyTid(tid: tid ?? ''),
    },
  );
  const primary = [
    ThreadShareAction.copyLink,
    ThreadShareAction.copyShareText,
    ThreadShareAction.qrCode,
    ThreadShareAction.toFriend,
    ThreadShareAction.openInBrowser,
  ];
  const secondary = [ThreadShareAction.pinToHome, ThreadShareAction.copyTid];
  return showActionSheet<ThreadShareAction>(
    context: context,
    title: t.postCard.shareAndCopy,
    primary: [for (final action in primary.where(offered.contains)) item(action)],
    secondary: [for (final action in secondary.where(offered.contains)) item(action)],
  );
}
