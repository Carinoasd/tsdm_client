import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/stream.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:window_manager/window_manager.dart';

/// Callback of the user tap on local notification.
///
/// First hop of a tap while the app is alive: when this line is missing from an exported log the tap never reached
/// Dart, so whatever happened next was not the app's decision (#14).
///
/// The payload is forwarded **synchronously first**, the desktop window restore that follows is awaited after: a
/// listener (and the test for it) sees the payload as soon as this function is called, while the window only comes
/// back on the next event loop turn. On non-desktop platforms the window part is skipped entirely.
Future<void> onLocalNotificationOpened(NotificationResponse resp) async {
  talker.info(
    'local notification tapped: id=${resp.id} type=${resp.notificationResponseType.name} payload=${resp.payload} '
    'listened=${localNoticeStream.hasListener}',
  );

  // Forward the payload before anything asynchronous so every listener sees it immediately.
  localNoticeStream.add(resp.payload);

  // Desktop: bring the window back to the front. Without it the route change below is invisible while the window is
  // minimized or hidden. Done after the add so the payload delivery is not delayed.
  if (isDesktop) {
    await _bringWindowToFront();
  }
}

/// Restore / show / focus the desktop window.
///
/// Same sequence as the tray menu: `restore` only matters when the window is minimized, `show` recovers a window
/// hidden with `hide()`, and `focus` puts it in front of other windows. Any failure is logged and swallowed: the
/// route change is still attempted, a lost focus is not worth blocking the notification handler.
Future<void> _bringWindowToFront() async {
  try {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  } on Exception catch (e, st) {
    talker.handle(e, st, 'bring window to front on notification tap failed: ');
  }
}

/// Park the payload of the notification that cold-started the app, if any (#14).
///
/// Android only, call at boot after the plugin is initialized. [onLocalNotificationOpened] is not invoked for the
/// tap that launched the app, its payload only exists in the launch details; only the payloads this app knows
/// ([LocalNoticeKeys]) are kept. Failures are logged and swallowed because they must not block the boot.
Future<void> rememberNotificationLaunch() async {
  if (!isAndroid) {
    return;
  }
  try {
    final launch = await flnp.getNotificationAppLaunchDetails();
    if (launch == null || !launch.didNotificationLaunchApp) {
      talker.debug('app not launched from a local notification');
      return;
    }
    final payload = launch.notificationResponse?.payload;
    talker.info('app launched from local notification: payload=$payload');
    if (payload == LocalNoticeKeys.openNotification) {
      rememberLaunchPayload(payload);
    } else {
      talker.warning('ignore launch notification with unknown payload: $payload');
    }
  } on Exception catch (e, st) {
    talker.handle(e, st, 'read notification launch details failed: ');
  }
}
