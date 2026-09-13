import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 通知渠道ID和通知ID，用于前台服务的常驻通知
const String notificationChannelId = 'tsdm_foreground';
const int notificationId = 888;

/// 初始化服务配置（在 main() 中调用，但不要自动启动）
Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  // 创建通知渠道
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    notificationChannelId,
    '后台消息服务',
    description: '保持连接以接收论坛消息',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false, // 不要自动启动，由开关控制
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

/// 后台服务的入口，运行在独立的 Isolate 中
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    // 把服务设为前台，这样系统不容易杀掉它
    service.setAsForegroundService();
  }

  // 在这里维持你的 WebSocket 连接 / 轮询逻辑
  // 示例：每隔30秒检查一次新消息
  Timer.periodic(const Duration(seconds: 30), (timer) async {
    // 调用你项目中已有的消息拉取逻辑
    // await fetchNewMessages();
  });

  // 监听来自主界面的停止指令
  service.on('stopService').listen((event) {
    service.stopSelf();
  });
}

/// 启动后台服务
Future<void> startBackgroundService() async {
  final service = FlutterBackgroundService();
  if (!await service.isRunning()) {
    await service.startService();
  }
}

/// 停止后台服务
Future<void> stopBackgroundService() async {
  final service = FlutterBackgroundService();
  if (await service.isRunning()) {
    service.invoke('stopService');
  }
}
