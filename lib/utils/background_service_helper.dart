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

/// SharedPreferences 中保存"推送去重状态"的 key。
///
/// 前台 isolate 和后台 isolate 共享这份状态：推送前先看各类别的最新消息
/// 是否比上次推送时更新，是则推送并更新状态，否则跳过。
const String _pushDedupStateKey = 'notification_push_dedup_state';

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
/// 前台改了它看不到。这里每次都 `reload()` 一次，保证读到最新值。
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

/// 推送去重的持久化状态。
///
/// 记录上次推送时，三个类别里最新一条消息的时间戳。判定"是否有新消息"
/// 就是看这次拉到的最新消息时间戳，是否比上次推送时记录的更新。
class _PushDedupState {
  const _PushDedupState({
    required this.uid,
    required this.noticeLatestTs,
    required this.pmLatestKey,
    required this.bmLatestTs,
  });

  factory _PushDedupState.empty(int uid) => _PushDedupState(
    uid: uid,
    noticeLatestTs: 0,
    pmLatestKey: '',
    bmLatestTs: 0,
  );

  factory _PushDedupState.fromJson(Map<String, dynamic> json) => _PushDedupState(
    uid: json['uid'] as int? ?? 0,
    noticeLatestTs: json['noticeLatestTs'] as int? ?? 0,
    pmLatestKey: json['pmLatestKey'] as String? ?? '',
    bmLatestTs: json['bmLatestTs'] as int? ?? 0,
  );

  /// 状态所属账号。账号切换时状态作废。
  final int uid;

  /// 上次推送时最新一条提醒的时间戳（秒）。
  final int noticeLatestTs;

  /// 上次推送时最新一条私信的 key，格式 `peerUid:timestamp`。
  final String pmLatestKey;

  /// 上次推送时最新一条公共消息的时间戳（秒）。
  final int bmLatestTs;

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'noticeLatestTs': noticeLatestTs,
    'pmLatestKey': pmLatestKey,
    'bmLatestTs': bmLatestTs,
  };
}

/// 私信的去重 key：`peerUid:timestamp`。
///
/// 用 peerUid + timestamp 而不是只用 timestamp，是为了避免两个不同的人
/// 同一秒发消息时被当成同一条。
String _pmKey(PersonalMessageV2 pm) => '${pm.peerUid}:${pm.timestamp}';

/// 判定这次拉到的消息是否需要推送，并记录新的去重状态。
///
/// 判定依据是每个类别的最新消息时间戳：如果本次拉到的任意一类消息比
/// 上次推送时更新，就认为有新消息，返回 true 并把新状态写入。
///
/// 相较旧的"30 秒时间窗口去重"，这个方案：
/// * 不会把"零条新消息"的抓取算成推送。
/// * 不会吞掉不同的新消息。
/// * 按账号隔离（uid 变化时状态自动清空）。
///
/// 出错时返回 true（宁可多推不可漏推）。
Future<bool> checkAndRecordPush({
  required int uid,
  required List<NoticeV2> notices,
  required List<PersonalMessageV2> personalMessages,
  required List<BroadcastMessageV2> broadcastMessages,
}) async {
  try {
    final prefs = await _freshPrefs();

    final raw = prefs.getString(_pushDedupStateKey);
    _PushDedupState prev;
    if (raw == null || raw.isEmpty) {
      prev = _PushDedupState.empty(uid);
    } else {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          prev = _PushDedupState.fromJson(Map<String, dynamic>.from(decoded));
        } else {
          prev = _PushDedupState.empty(uid);
        }
      } on FormatException {
        prev = _PushDedupState.empty(uid);
      }
    }

    // 账号变了：状态作废，从头开始。
    if (prev.uid != uid) {
      prev = _PushDedupState.empty(uid);
    }

    // 本次各类别的最新值。
    final noticeLatestTs = notices.isEmpty
        ? 0
        : notices.map((e) => e.timestamp).reduce((a, b) => a > b ? a : b);
    final pmLatestKey = personalMessages.isEmpty
        ? ''
        : _pmKey(personalMessages.reduce((a, b) => a.timestamp > b.timestamp ? a : b));
    final bmLatestTs = broadcastMessages.isEmpty
        ? 0
        : broadcastMessages.map((e) => e.timestamp).reduce((a, b) => a > b ? a : b);

    // 判定：任意一类有更新就算有新消息。
    final hasNew = noticeLatestTs > prev.noticeLatestTs ||
        (pmLatestKey.isNotEmpty && pmLatestKey != prev.pmLatestKey) ||
        bmLatestTs > prev.bmLatestTs;

    if (!hasNew) {
      return false;
    }

    // 写入新的去重状态。
    final next = _PushDedupState(
      uid: uid,
      noticeLatestTs: noticeLatestTs,
      pmLatestKey: pmLatestKey,
      bmLatestTs: bmLatestTs,
    );
    await prefs.setString(_pushDedupStateKey, jsonEncode(next.toJson()));
    return true;
  } on Object catch (_) {
    // 出错了当作应该推送，宁可多推不可漏推。
    return true;
  }
}

/// 清空推送去重状态。
///
/// 账号切换或移除时调用，避免用旧账号的状态判定新账号。
Future<void> clearPushDedupState() async {
  try {
    final prefs = await _freshPrefs();
    await prefs.remove(_pushDedupStateKey);
  } on Object catch (_) {
    // 忽略。
  }
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

/// `onStart` 内部 `startOrRestartTimer` 函数的引用。
///
/// `onStart` 里提前注册的 `updateTimer` 监听器需要调用它，
/// 但函数本身在监听器注册之后才定义，因此用一个全局变量做桥接。
Future<void> Function()? _startOrRestartTimerRef;

/// `onStart` 内部 `updateForegroundNotification` 函数的引用。
///
/// `onStart` 里提前注册的 `updateLocale` 监听器需要调用它，
/// 但函数本身在监听器注册之后才定义，因此用一个全局变量做桥接。
Future<void> Function()? _updateForegroundNotificationRef;

/// 后台服务的入口，运行在独立的 Isolate 中。
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await _bgLog('=== onStart called ===');

  final enabled = await isBackgroundServiceEnabled();
  await _bgLog('enabled=$enabled');
  if (!enabled) {
    await _bgLog('service disabled, stopping self');
    await service.stopSelf();
    return;
  }

  // 定时器变量提前声明，供下面所有监听器共享。
  Timer? backgroundTimer;

  // ---- 关键：三个 service.on 监听器必须在任何 await 之前注册 ----
  //
  // 前台设置页通过 `FlutterBackgroundService().invoke('stopService')` 发停止指令。
  // 如果这个监听器注册得太晚（比如等首拉和 3 秒延迟跑完才注册），
  // 用户在此期间点“关闭”会被漏掉，服务就停不下来。
  service.on('stopService').listen((event) {
    unawaited(_bgLog('received stopService'));
    backgroundTimer?.cancel();
    unawaited(service.stopSelf());
  });

  service.on('updateTimer').listen((event) async {
    await _bgLog('received updateTimer');
    await _startOrRestartTimerRef?.call();
  });

  service.on('updateLocale').listen((event) async {
    await _bgLog('received updateLocale');
    await _updateForegroundNotificationRef?.call();
  });

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
      // 每轮先检查用户开关，开关被关了就立刻停止自己。
      final stillEnabled = await isBackgroundServiceEnabled();
      if (!stillEnabled) {
        await _bgLog('timer fired but service disabled, stopping self');
        timer.cancel();
        await service.stopSelf();
        return;
      }
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

  // 保存引用，供上面提前注册的监听器调用。
  _startOrRestartTimerRef = startOrRestartTimer;
  _updateForegroundNotificationRef = updateForegroundNotification;

  // 立即跑一次首拉并启动定时器。
  await startOrRestartTimer();
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
      // 按消息事件去重：只有"最新一条消息"比上次推送时更新，才推送。
      final shouldPush = await checkAndRecordPush(
        uid: uid,
        notices: info.noticeList,
        personalMessages: info.personalMessageList,
        broadcastMessages: info.broadcastMessageList,
      );

      if (!shouldPush) {
        await _bgLog('skip push: no new message since last push');
      } else {
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

        // 只记数量/类型/结果，不写 body 正文，避免私信预览落进日志。
        await _bgLog(
          'notification pushed: notice=${info.noticeList.length} '
          'pm=${info.personalMessageList.length} '
          'bm=${info.broadcastMessageList.length}',
        );
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
///
/// 先把开关写为 false 并等待落盘，再发停止指令。这样即使服务被系统重建，
/// 新的 onStart 也会读到 false 并立刻 stopSelf，不会自己跑起来。
Future<void> stopBackgroundService() async {
  // 1. 先写 SharedPreferences 并等落盘。
  final prefs = await _freshPrefs();
  await prefs.setBool(backgroundServiceEnabledKey, false);
  // 给磁盘写入一点时间，确保后台 isolate 的 reload 能读到。
  await Future<void>.delayed(const Duration(milliseconds: 500));

  // 2. 再发停止指令。
  final service = FlutterBackgroundService();
  if (await service.isRunning()) {
    service.invoke('stopService');
    for (var i = 0; i < 25; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!await service.isRunning()) break;
    }
  }
}
