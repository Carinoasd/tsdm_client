// 这些 public 函数被 main.dart 和 settings_page.dart 调用，但分析器穿透不了
// runZonedGuarded 的闭包入口，会把它们误判为 unreachable。
// ignore_for_file: unreachable_from_main
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

/// 前台服务常驻通知使用的通知渠道 ID。
const String notificationChannelId = 'tsdm_foreground';

/// 前台服务常驻通知使用的通知 ID。
const int notificationId = 888;

/// 本地通知的渠道 ID，跟前台 `lib/features/local_notice/show.dart` 里的保持一致。
const String _localNoticeChannelId = 'newNoticeChannelV2';

/// 通知 payload，跟前台 `lib/features/local_notice/keys.dart` 里的 `LocalNoticeKeys.openNotification` 一致。
const String _openNotificationPayload = 'openNotification';

/// SharedPreferences 中保存开关状态的 key。
const String backgroundServiceEnabledKey = 'enableBackgroundMessageService';

/// SharedPreferences 标志：后台已经推送过通知，前台首次拉取时跳过重复推送。
const String _skipNextNotificationKey = 'background_notified_skip_next';

/// SharedPreferences 中记录最近一次推送通知的时间（秒）。
///
/// 前台 isolate 和后台 isolate 共享这个值：任何一侧推通知前先读它，
/// 如果距现在不到 30 秒，说明另一侧刚推过同一条消息，跳过这次推送。
/// 这条规则同时解决了两个问题：
/// * 启动时前后台同时拉取 → 只有先跑完的那一侧会推。
/// * 服务器对私信用 inclusive 边界，同一分钟内的私信会被两侧重复拉到 → 只有第一次推。
const String _lastPushTimeKey = 'notification_last_push_time';

/// 跨 isolate 去重窗口（秒）。
const int _pushDedupeWindowSeconds = 30;

/// 一种语言下的所有通知文案。
class _NotificationStrings {
  const _NotificationStrings({
    required this.title,
    required this.notice,
    required this.pm,
    required this.bm,
    required this.foregroundChannelName,
    required this.foregroundChannelDesc,
    required this.foregroundTitle,
    required this.foregroundContent,
  });

  final String title;
  final String notice;
  final String pm;
  final String bm;
  final String foregroundChannelName;
  final String foregroundChannelDesc;
  final String foregroundTitle;
  final String foregroundContent;
}

/// 每种语言的本地通知文案。
const Map<String, _NotificationStrings> _notificationStrings = {
  'zh-CN': _NotificationStrings(
    title: '新消息',
    notice: '收到了{noticeCount}条提醒，{pmCount}条私信，{bmCount}条公共消息\n[提醒]{msg}',
    pm: '收到了{noticeCount}条提醒，{pmCount}条私信，{bmCount}条公共消息\n[私信]{user}：{msg}',
    bm: '收到了{noticeCount}条提醒，{pmCount}条私信，{bmCount}条公共消息\n[公共消息]{msg}',
    foregroundChannelName: '后台消息服务',
    foregroundChannelDesc: '保持连接以接收论坛消息',
    foregroundTitle: '天使动漫',
    foregroundContent: '正在后台保持连接...',
  ),
  'zh-TW': _NotificationStrings(
    title: '新訊息',
    notice: '收到了{noticeCount}條提醒，{pmCount}條私信，{bmCount}條公用訊息\n[提醒]{msg}',
    pm: '收到了{noticeCount}條提醒，{pmCount}條私信，{bmCount}條公用訊息\n[私訊]{user}：{msg}',
    bm: '收到了{noticeCount}條提醒，{pmCount}條私信，{bmCount}條公用訊息\n[公用訊息]{msg}',
    foregroundChannelName: '後台訊息服務',
    foregroundChannelDesc: '保持連線以接收論壇訊息',
    foregroundTitle: '天使動漫',
    foregroundContent: '正在後台保持連線...',
  ),
  'en': _NotificationStrings(
    title: 'New notice',
    notice: 'You received {noticeCount} notice, {pmCount} PMs, {bmCount} BMs\n[Notice]{msg}',
    pm: 'You received {noticeCount} notice, {pmCount} PMs, {bmCount} BMs\n[PM]{user}: {msg}',
    bm: 'You received {noticeCount} notice, {pmCount} PMs, {bmCount} BMs\n[BM]{msg}',
    foregroundChannelName: 'Background message service',
    foregroundChannelDesc: 'Keep connected to receive forum messages',
    foregroundTitle: 'TSDM',
    foregroundContent: 'Keeping background connection...',
  ),
};

const _NotificationStrings _defaultStrings = _NotificationStrings(
  title: '新消息',
  notice: '收到了{noticeCount}条提醒，{pmCount}条私信，{bmCount}条公共消息\n[提醒]{msg}',
  pm: '收到了{noticeCount}条提醒，{pmCount}条私信，{bmCount}条公共消息\n[私信]{user}：{msg}',
  bm: '收到了{noticeCount}条提醒，{pmCount}条私信，{bmCount}条公共消息\n[公共消息]{msg}',
  foregroundChannelName: '后台消息服务',
  foregroundChannelDesc: '保持连接以接收论坛消息',
  foregroundTitle: '天使动漫',
  foregroundContent: '正在后台保持连接...',
);

_NotificationStrings _stringsForLocale(String? localeTag) {
  if (localeTag == null || localeTag.isEmpty) {
    return _defaultStrings;
  }
  final exact = _notificationStrings[localeTag];
  if (exact != null) {
    return exact;
  }
  final lower = localeTag.toLowerCase().replaceAll('_', '-');
  if (lower.startsWith('zh')) {
    if (lower.contains('tw') || lower.contains('hk') || lower.contains('hant')) {
      return _notificationStrings['zh-TW'] ?? _defaultStrings;
    }
    return _defaultStrings;
  }
  if (lower.startsWith('en')) {
    return _notificationStrings['en'] ?? _defaultStrings;
  }
  return _defaultStrings;
}

String _fillTemplate(String template, Map<String, String> values) {
  var result = template;
  for (final entry in values.entries) {
    result = result.replaceAll('{${entry.key}}', entry.value);
  }
  return result;
}

Future<File> _bgLogFile() async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}/bg_service.log');
}

Future<void> _bgLog(String msg) async {
  try {
    final file = await _bgLogFile();
    final line = '[${DateTime.now().toIso8601String()}] $msg\n';
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  } on Exception catch (_) {
    // 日志失败不能影响主流程
  }
}

/// 读取 SharedPreferences 并强制从磁盘 reload。
///
/// `SharedPreferences.getInstance()` 返回的是带内存缓存的单例。
/// 后台 isolate 是独立进程/isolate，第一次读之后内存里一直留着旧值，
/// 前台改了 `background_locale` 它看不到。这里每次都 `reload()` 一次，
/// 保证读到的是磁盘上的最新值。
Future<SharedPreferences> _freshPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return prefs;
}

/// 把后台服务的日志文件内容读取出来，注入到主 isolate 的 talker，然后清空文件。
Future<void> importBackgroundLogToTalker() async {
  try {
    final file = await _bgLogFile();
    if (!file.existsSync()) {
      return;
    }
    final content = await file.readAsString();
    if (content.isEmpty) {
      return;
    }
    for (final line in content.split('\n')) {
      if (line.trim().isEmpty) {
        continue;
      }
      talker.info('[BG] $line');
    }
    await file.writeAsString('');
  } on Exception catch (e) {
    talker.handle(e, null, 'import background log failed');
  }
}

String _truncate(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

/// 读取用户是否开启了后台消息服务。
Future<bool> isBackgroundServiceEnabled() async {
  final prefs = await _freshPrefs();
  return prefs.getBool(backgroundServiceEnabledKey) ?? false;
}

/// 查询后台服务是否真的在运行。
Future<bool> isBackgroundServiceRunning() async {
  return FlutterBackgroundService().isRunning();
}

/// 初始化后台服务配置。
///
/// 常驻通知的文案按 SharedPreferences 里的 `background_locale` 选择。
Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  final prefs = await _freshPrefs();
  final strings = _stringsForLocale(prefs.getString('background_locale'));

  final channel = AndroidNotificationChannel(
    notificationChannelId,
    strings.foregroundChannelName,
    description: strings.foregroundChannelDesc,
    importance: Importance.low,
  );

  final plugin = FlutterLocalNotificationsPlugin();

  await plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: strings.foregroundTitle,
      initialNotificationContent: strings.foregroundContent,
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
  await _bgLog('=== onStart called ===');
  DartPluginRegistrant.ensureInitialized();

  final enabled = await isBackgroundServiceEnabled();
  await _bgLog('enabled=$enabled');
  if (!enabled) {
    await _bgLog('service disabled, stopping self');
    await service.stopSelf();
    return;
  }

  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
  }

  final flnp = FlutterLocalNotificationsPlugin();
  await flnp.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_launcher_foreground'),
    ),
  );
  await _bgLog('flnp initialized');

  /// 按当前 locale 更新常驻通知的标题和内容。
  ///
  /// 渠道名无法更新（Android 不允许修改已存在的渠道），但标题和内容可以。
  Future<void> updateForegroundNotification() async {
    if (service is! AndroidServiceInstance) {
      return;
    }
    try {
      final prefs = await _freshPrefs();
      final strings = _stringsForLocale(prefs.getString('background_locale'));
      await service.setForegroundNotificationInfo(
        title: strings.foregroundTitle,
        content: strings.foregroundContent,
      );
      await _bgLog('foreground notification updated: title=${strings.foregroundTitle}');
    } on Exception catch (e) {
      await _bgLog('updateForegroundNotification exception: $e');
    }
  }

  Timer? backgroundTimer;

  Future<void> startOrRestartTimer() async {
    backgroundTimer?.cancel();
    final prefs = await _freshPrefs();
    final intervalSeconds = prefs.getInt('autoSyncNoticeSeconds') ?? 180;
    await _bgLog('startOrRestartTimer: interval=$intervalSeconds');

    if (intervalSeconds <= 0) {
      await _bgLog('interval <= 0, skip timer');
      return;
    }

    backgroundTimer = Timer.periodic(Duration(seconds: intervalSeconds), (timer) async {
      await _bgLog('timer fired, checking messages');
      try {
        await _checkNewMessages(flnp);
      } on Exception catch (e) {
        await _bgLog('checkNewMessages exception: $e');
      }
    });

    try {
      await _checkNewMessages(flnp);
    } on Exception catch (e) {
      await _bgLog('initial checkNewMessages exception: $e');
    }
  }

  // 让前台先把首拉跑完。
  //
  // 应用启动时前台和后台几乎同时启动，如果两边都立刻拉取，
  // 就会把同一批消息推两次。等几秒让前台先推完并写好 `_lastPushTime`，
  // 后台首拉时读到时间戳在 30 秒窗口内就会跳过推送。
  await Future<void>.delayed(const Duration(seconds: 3));

  await startOrRestartTimer();

  service.on('stopService').listen((event) {
    unawaited(_bgLog('received stopService'));
    backgroundTimer?.cancel();
    unawaited(service.stopSelf());
  });

  service.on('updateTimer').listen((event) async {
    await _bgLog('received updateTimer');
    await startOrRestartTimer();
  });

  service.on('updateLocale').listen((event) async {
    await _bgLog('received updateLocale');
    await updateForegroundNotification();
  });
}

Future<void> _checkNewMessages(FlutterLocalNotificationsPlugin flnp) async {
  await _bgLog('_checkNewMessages start');
  final prefs = await _freshPrefs();

  final uid = prefs.getInt('background_login_uid');
  await _bgLog('uid=$uid');
  if (uid == null || uid <= 0) {
    await _bgLog('uid null or <= 0, abort');
    return;
  }

  final cookieJson = prefs.getString('background_cookie_$uid');
  await _bgLog('cookie=${cookieJson == null ? "null" : "len=${cookieJson.length}"}');
  if (cookieJson == null || cookieJson.isEmpty) {
    return;
  }
  final cookieMap = Map<String, String>.from(jsonDecode(cookieJson) as Map);

  final cookieHeader = _buildCookieHeader(cookieMap);

  final lastFetchTime = prefs.getInt('background_last_fetch_time_$uid');
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final nowMinute = nowSec - (nowSec % 60);
  final since = lastFetchTime ?? (nowMinute - 3 * 24 * 3600);
  await _bgLog('since=$since lastFetchTime=$lastFetchTime nowMinute=$nowMinute');

  await _bgLog('fetching pages...');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final noticeHtml = await _fetchHtml(client, noticeUrl, cookieHeader);
    final isLoginPage = noticeHtml.contains('<title>登录');
    await _bgLog('notice html len=${noticeHtml.length} isLogin=$isLoginPage');

    final pmHtml = await _fetchHtml(client, personalMessageUrl, cookieHeader);
    final bmHtml = await _fetchHtml(client, broadcastMessageUrl, cookieHeader);

    if (isLoginPage) {
      await _bgLog('server returned login page, abort');
      return;
    }

    final info = NotificationV2.fromDocuments(
      noticeDoc: parseHtmlDocument(noticeHtml),
      personalMessageDoc: parseHtmlDocument(pmHtml),
      broadcastMessageDoc: parseHtmlDocument(bmHtml),
      since: since,
    );
    await _bgLog(
      'parsed: notice=${info.noticeList.length} pm=${info.personalMessageList.length} '
      'bm=${info.broadcastMessageList.length}',
    );

    final total = info.noticeList.length +
        info.personalMessageList.length +
        info.broadcastMessageList.length;

    if (total > 0) {
      final strings = _stringsForLocale(prefs.getString('background_locale'));
      final countValues = <String, String>{
        'noticeCount': '${info.noticeList.length}',
        'pmCount': '${info.personalMessageList.length}',
        'bmCount': '${info.broadcastMessageList.length}',
      };

      String body;
      if (info.personalMessageList.isNotEmpty) {
        final pm = info.personalMessageList.last;
        body = _fillTemplate(strings.pm, {
          ...countValues,
          'user': pm.peerUsername,
          'msg': _truncate(pm.data, 40),
        });
      } else if (info.broadcastMessageList.isNotEmpty) {
        final bm = info.broadcastMessageList.last;
        body = _fillTemplate(strings.bm, {
          ...countValues,
          'msg': _truncate(bm.data, 40),
        });
      } else {
        final n = info.noticeList.last;
        final text = parseHtmlDocument(n.data).body?.innerText ?? '<null>';
        body = _fillTemplate(strings.notice, {
          ...countValues,
          'msg': _truncate(text, 40),
        });
      }

      // ---- 跨 isolate 去重 ----
      //
      // 前台和后台共享 `_lastPushTimeKey`。任何一侧推通知时都写入当前时间；
      // 另一侧推送前读它，如果距现在不到 30 秒就跳过。
      //
      // 这个机制同时覆盖：
      // * 启动时前后台同时跑：后台延迟 3 秒启动，前台先写，后台读到窗口内就跳过。
      // * 私信用 inclusive 边界被两侧重复拉到：只有第一次的推送生效。
      final lastPush = prefs.getInt(_lastPushTimeKey) ?? 0;
      final sinceLastPush = nowSec - lastPush;
      if (sinceLastPush >= 0 && sinceLastPush < _pushDedupeWindowSeconds) {
        await _bgLog('skip push: another isolate pushed ${sinceLastPush}s ago');
      } else {
        await flnp.show(
          id: 0,
          title: strings.title,
          body: body,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              _localNoticeChannelId,
              '新提醒',
              channelDescription: '自动同步消息时收到新提醒',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
          payload: _openNotificationPayload,
        );

        // 记录推送时间，供前台推通知前检查。
        await prefs.setInt(_lastPushTimeKey, nowSec);
        // 兼容旧标记：前台也读 `_skipNextNotificationKey`。
        await prefs.setBool(_skipNextNotificationKey, true);

        await _bgLog('notification pushed: title=${strings.title} body=$body');
      }
    } else {
      await _bgLog('no new messages');
    }

    await prefs.setInt('background_last_fetch_time_$uid', nowMinute);
  } on Exception catch (e) {
    await _bgLog('fetch error: $e');
  } finally {
    client.close(force: true);
  }
}

Future<String> _fetchHtml(
  HttpClient client,
  String url,
  String cookieHeader,
) async {
  final request = await client.getUrl(Uri.parse(url));
  if (cookieHeader.isNotEmpty) {
    request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
  }
  request.headers.set(
    HttpHeaders.userAgentHeader,
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
  );
  final response = await request.close();
  return response.transform(utf8.decoder).join();
}

String _buildCookieHeader(Map<String, String> cookieMap) {
  final pairs = <String>[];
  for (final value in cookieMap.values) {
    try {
      final domainMap = jsonDecode(value);
      if (domainMap is! Map) {
        continue;
      }
      for (final pathValue in domainMap.values) {
        if (pathValue is! Map) {
          continue;
        }
        for (final entry in pathValue.entries) {
          final v = entry.value;
          if (v is Map) {
            final name = v['name'];
            final val = v['value'];
            if (name is String && val is String && name.isNotEmpty) {
              if (val.contains('=')) {
                final firstPair = val.split(';').first.trim();
                if (firstPair.isNotEmpty) {
                  pairs.add(firstPair);
                }
              } else {
                pairs.add('$name=$val');
              }
            }
          } else if (v is String) {
            final name = entry.key.toString();
            if (name.isNotEmpty) {
              if (v.contains('=')) {
                final firstPair = v.split(';').first.trim();
                if (firstPair.isNotEmpty) {
                  pairs.add(firstPair);
                }
              } else {
                pairs.add('$name=$v');
              }
            }
          }
        }
      }
    } on FormatException catch (_) {
      // 不是 JSON 就跳过
    }
  }
  return pairs.join('; ');
}

/// 启动后台服务，并等待服务真正起来。
Future<void> startBackgroundService() async {
  final prefs = await _freshPrefs();
  await prefs.setBool(backgroundServiceEnabledKey, true);

  final service = FlutterBackgroundService();
  if (!await service.isRunning()) {
    await service.startService();
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (await service.isRunning()) break;
    }
  }
}

/// 停止后台服务。
Future<void> stopBackgroundService() async {
  final prefs = await _freshPrefs();
  await prefs.setBool(backgroundServiceEnabledKey, false);

  final service = FlutterBackgroundService();
  if (await service.isRunning()) {
    service.invoke('stopService');
    for (var i = 0; i < 25; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!await service.isRunning()) break;
    }
  }
}
