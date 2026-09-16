// 这些 public 函数被 main.dart 和 settings_page.dart 调用，但分析器穿透不了
// runZonedGuarded 的闭包入口，会把它们误判为 unreachable。
// ignore_for_file: unreachable_from_main
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart' show Headers;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/fetch_bound.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/antitheft/antitheft_decoder.dart';
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

  final int uid;
  final int noticeLatestTs;
  final String pmLatestKey;
  final int bmLatestTs;

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'noticeLatestTs': noticeLatestTs,
    'pmLatestKey': pmLatestKey,
    'bmLatestTs': bmLatestTs,
  };
}

String _pmKey(PersonalMessageV2 pm) => '${pm.peerUid}:${pm.timestamp}';

/// 判定这次拉到的消息是否需要推送，并记录新的去重状态。
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

    if (prev.uid != uid) {
      prev = _PushDedupState.empty(uid);
    }

    final noticeLatestTs = notices.isEmpty
        ? 0
        : notices.map((e) => e.timestamp).reduce((a, b) => a > b ? a : b);
    final pmLatestKey = personalMessages.isEmpty
        ? ''
        : _pmKey(personalMessages.reduce((a, b) => a.timestamp > b.timestamp ? a : b));
    final bmLatestTs = broadcastMessages.isEmpty
        ? 0
        : broadcastMessages.map((e) => e.timestamp).reduce((a, b) => a > b ? a : b);

    final hasNew = noticeLatestTs > prev.noticeLatestTs ||
        (pmLatestKey.isNotEmpty && pmLatestKey != prev.pmLatestKey) ||
        bmLatestTs > prev.bmLatestTs;

    if (!hasNew) {
      return false;
    }

    final next = _PushDedupState(
      uid: uid,
      noticeLatestTs: noticeLatestTs,
      pmLatestKey: pmLatestKey,
      bmLatestTs: bmLatestTs,
    );
    await prefs.setString(_pushDedupStateKey, jsonEncode(next.toJson()));
    return true;
  } on Object catch (_) {
    return true;
  }
}

/// 清空推送去重状态。
Future<void> clearPushDedupState() async {
  try {
    final prefs = await _freshPrefs();
    await prefs.remove(_pushDedupStateKey);
  } on Object catch (_) {
    // 忽略。
  }
}

/// 初始化后台服务配置。
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
      foregroundServiceTypes: [AndroidForegroundType.specialUse],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
    ),
  );
}

/// `onStart` 内部 `startOrRestartTimer` 函数的引用。
Future<void> Function()? _startOrRestartTimerRef;

/// `onStart` 内部 `updateForegroundNotification` 函数的引用。
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

  Timer? backgroundTimer;

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

  _startOrRestartTimerRef = startOrRestartTimer;
  _updateForegroundNotificationRef = updateForegroundNotification;

  await startOrRestartTimer();
}

/// 从 [HttpHeaders] 中解析论坛回应携带的 `Date` 头（论坛时钟）。
///
/// 对应 PR #73 `fetch_bound.dart` 里 `serverTimeOf` 的逻辑，这里因为
/// 后台用的是裸 `HttpClient` 而不是 dio，所以读取 `HttpHeaders` 之后
/// 转成 dio 的 `Headers` 再调用 `serverTimeOf`。
DateTime? _serverTimeOf(HttpHeaders headers) {
  final raw = headers.value('date');
  if (raw == null || raw.isEmpty) {
    return null;
  }
  try {
    return serverTimeOf(Headers.fromMap({'date': [raw]}));
  } on Exception {
    return null;
  }
}

/// 用 dart:io 的 HttpClient 抓取一个页面，同时返回页面内容和论坛时钟。
///
/// 返回 `(html, serverTime)`：`serverTime` 是论坛 `Date` 头解析出的时间，
/// 缺头或坏值时是 null（行为退回设备时钟，与 PR #73 一致）。
///
/// 同时做了两件 PR #73 要求的“请求验证”：
/// * 检查 HTTP 状态码，非 2xx 直接抛出，不推进时间界線。
/// * 在调用方检查返回内容是否是登录页或防采集挑战页。
Future<(String, DateTime?)> _fetchHtml(
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

  // HTTP 状态检查：非成功状态码直接抛出，调用方会跳过这轮，不推进界線。
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpRequestFailedException(response.statusCode);
  }

  final serverTime = _serverTimeOf(response.headers);
  final html = await response.transform(utf8.decoder).join();
  return (html, serverTime);
}

/// 与 `NotificationRepository._buildSinceTimestamp` 保持一致的抓取下界：
/// [timestamp] 在最近 3 天内则直接用，否则用 3 天前。
int _buildSinceTimestamp(int? timestamp) {
  final now = DateTime.now();
  if (timestamp == null) {
    return now.subtract(const Duration(days: 3)).millisecondsSinceEpoch ~/ 1000;
  }
  final time = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  final diff = now.difference(time);
  if (diff.inDays >= 0 && diff.inDays <= 3) {
    return timestamp;
  }
  return now.subtract(const Duration(days: 3)).millisecondsSinceEpoch ~/ 1000;
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

  // ---- 时间界線：用论坛时钟（PR #73） ----
  //
  // 抓取开始前先记下设备时钟。如果论坛回应的 Date 头可用，就用论坛
  // 时钟推界線；否则退回设备时钟。这样设备时钟不准也不会漏消息。
  final startedAt = DateTime.now();
  final lastFetchTime = prefs.getInt('background_last_fetch_time_$uid');
  final since = _buildSinceTimestamp(lastFetchTime);
  await _bgLog('since=$since lastFetchTime=$lastFetchTime startedAt=$startedAt');

  await _bgLog('fetching pages...');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final (noticeHtml, noticeServerTime) = await _fetchHtml(client, noticeUrl, cookieHeader);
    final (pmHtml, pmServerTime) = await _fetchHtml(client, personalMessageUrl, cookieHeader);
    final (bmHtml, bmServerTime) = await _fetchHtml(client, broadcastMessageUrl, cookieHeader);

    // 三个页面里取最早的 Date，与 PR #73 一致。
    final serverTime = earliestOf([noticeServerTime, pmServerTime, bmServerTime]);
    await _bgLog('notice html len=${noticeHtml.length} '
        'pm html len=${pmHtml.length} bm html len=${bmHtml.length} '
        'serverTime=${serverTime?.toIso8601String() ?? 'none'}');

    // 登录页检查：会话过期时不推进界線，下轮重试。
    if (noticeHtml.contains('<title>登录')) {
      await _bgLog('server returned login page, abort (will retry next cycle)');
      return;
    }

    // 防采集挑战页检查：后台没有 AntitheftInterceptor 去解 _dsign，
    // 遇到挑战就直接跳过这轮，不推进界線，让下一轮再试。
    if (AntitheftDecoder.isChallenge(noticeHtml)) {
      await _bgLog('server returned antitheft challenge, abort (will retry next cycle)');
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

        await _bgLog(
          'notification pushed: notice=${info.noticeList.length} '
          'pm=${info.personalMessageList.length} '
          'bm=${info.broadcastMessageList.length}',
        );
      }
    } else {
      await _bgLog('no new messages');
    }

    // ---- 写入下次抓取下界（论坛时钟优先，PR #73） ----
    //
    // 与前台 AutoNotificationCubit / NotificationSyncAllRepository 用
    // 同一个 nextFetchBound：有论坛时钟就截到整分钟再减一分钟，没有
    // 就退回设备开始分钟。
    final nextBound = nextFetchBound(
      startedAt: startedAt,
      serverTime: serverTime,
    );
    await prefs.setInt(
      'background_last_fetch_time_$uid',
      nextBound.millisecondsSinceEpoch ~/ 1000,
    );
    await _bgLog('next fetch bound updated to ${nextBound.toIso8601String()}');
  } on Exception catch (e) {
    // 出错时**不推进界線**，让下一轮重试。HTTP 状态检查抛出的
    // HttpRequestFailedException 会走到这里。
    await _bgLog('fetch error (bound not advanced): $e');
  } finally {
    client.close(force: true);
  }
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
  await Future<void>.delayed(const Duration(milliseconds: 500));

  final service = FlutterBackgroundService();
  if (await service.isRunning()) {
    service.invoke('stopService');
    for (var i = 0; i < 25; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!await service.isRunning()) break;
    }
  }
}
