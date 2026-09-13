import 'dart:async';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 前台服务常驻通知使用的通知渠道 ID。
const String notificationChannelId = 'tsdm_foreground';

/// 前台服务常驻通知使用的通知 ID。
const int notificationId = 888;

/// SharedPreferences 中保存开关状态的 key。
const String backgroundServiceEnabledKey = 'enableBackgroundMessageService';

/// 读取用户是否开启了后台消息服务。
Future<bool> isBackgroundServiceEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(backgroundServiceEnabledKey) ?? false;
}

/// 初始化后台服务配置。
///
/// 只做配置，不启动服务。是否运行由设置页面的开关控制。
Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  const channel = AndroidNotificationChannel(
    notificationChannelId,
    '后台消息服务',
    description: '保持连接以接收论坛消息',
    importance: Importance.low,
  );

  final plugin = FlutterLocalNotificationsPlugin();

  await plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: '天使动漫',
      initialNotificationContent: '正在后台保持连接...',
      foregroundServiceNotificationId: notificationId,
      foregroundServiceTypes: [AndroidForegroundType.dataSync],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
    ),
  );
}

/// 后台服务的入口，运行在独立的 Isolate 中。
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
  }

  Timer.periodic(const Duration(seconds: 30), (timer) {
    // TODO: 在这里调用项目中已有的消息拉取逻辑。
    // 例如：await fetchNewMessages();
  });

  service.on('stopService').listen((event) {
    unawaited(service.stopSelf());
  });
}

/// 启动后台服务，并记下开关状态。
Future<void> startBackgroundService() async {
  final service = FlutterBackgroundService();
  if (!await service.isRunning()) {
    await service.startService();
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(backgroundServiceEnabledKey, true);
}

/// 停止后台服务，并记下开关状态。
Future<void> stopBackgroundService() async {
  final service = FlutterBackgroundService();
  if (await service.isRunning()) {
    service.invoke('stopService');
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(backgroundServiceEnabledKey, false);
}
