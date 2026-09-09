import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/stream.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Callback of the user tap on local notification.
void onLocalNotificationOpened(NotificationResponse resp) => localNoticeStream.add(resp.payload);

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
      return;
    }
    final payload = launch.notificationResponse?.payload;
    talker.info('app launched from local notification: payload=$payload');
    if (payload == LocalNoticeKeys.openNotification) {
      rememberLaunchPayload(payload);
    }
  } on Exception catch (e, st) {
    talker.handle(e, st, 'read notification launch details failed: ');
  }
}
