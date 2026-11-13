/// The diagnostics bundle: what the app tells about itself when the user exports it (the error block, the debug
/// section of the settings), in one zip.
///
/// Built in two steps. On the UI isolate, [composeDiagnosticsInfo] writes the few lines of facts that need the app
/// (its version, the platform, the device model, the forum plugin, a summary of the settings). Then, in a background
/// isolate ([buildDiagnosticsBundle] through `compute`), the recent log files are read, cut to [DiagnosticsLimits] and
/// redacted, and everything is zipped. Every text of the bundle goes through [redactLogText]: the facts, and the log
/// files, which an older version of the app may have written before redaction.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:tsdm_client/features/settings/models/historical_log.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/utils/log_redaction.dart';

/// How much of the logs a bundle takes.
final class DiagnosticsLimits {
  /// Constructor.
  const DiagnosticsLimits({this.days = 3, this.appLogBytes = 4 * 1024 * 1024, this.backgroundLogBytes = 1024 * 1024});

  /// Days of logs, today included.
  final int days;

  /// Bytes of the app's own logs, all days together; the newest are kept.
  final int appLogBytes;

  /// Bytes of the logs of the Android background message service, all days together; the newest are kept.
  final int backgroundLogBytes;
}

/// What [buildDiagnosticsBundle] needs, all of it plain data that crosses to another isolate.
final class DiagnosticsRequest {
  /// Constructor.
  const DiagnosticsRequest({
    required this.info,
    required this.logDir,
    required this.now,
    this.limits = const DiagnosticsLimits(),
  });

  /// The facts of [composeDiagnosticsInfo].
  final String info;

  /// The folder of the log files.
  final String logDir;

  /// The time of the export: the logs of the [DiagnosticsLimits.days] days up to it are taken.
  final DateTime now;

  /// How much of the logs is taken.
  final DiagnosticsLimits limits;
}

/// Name of the facts file in the bundle.
const diagnosticsInfoName = 'diagnostics.txt';

/// Folder of the log files in the bundle.
const diagnosticsLogFolder = 'logs';

/// Settings a bundle tells, by their name in the settings map: how the app looks and behaves, never who uses it.
///
/// Left out on purpose: the account (`loginUsername`, `loginUid`, `loginEmail`), the proxy address
/// (`netClientProxy`, may hold credentials or a LAN address), texts the user wrote (`checkinFeeling`,
/// `checkinMessage`, `editorQuickPhrases`), paths (`attachmentDownloadDirectory`), the window and the forum lists.
/// A setting added later is not told until it is added here.
const diagnosticSettingNames = <String>[
  'locale',
  'themeMode',
  'themeModeScheduled',
  'accentColorFollowSystem',
  'chineseDisplayMode',
  'textScaleFactor',
  'threadContentScale',
  'fontFamily',
  'homeLayout',
  'twoPaneLayout',
  'highRefreshRate',
  'collapseAppBarWhenScroll',
  'threadOpenPosition',
  'threadSwipePaging',
  'threadFloorInteractionMode',
  'threadReverseOrder',
  'threadLinkCard',
  'enableAppPostRenderer',
  'postMediaPreview',
  'postImageAutoLoad',
  'dataSaverMode',
  'immersiveAllForums',
  'offlineThreads',
  'inAppBrowserForForum',
  'inAppBrowserForAll',
  'clipboardLinkPrompt',
  'netClientUseProxy',
  'useDetectedProxyWhenStartup',
  'enableUpdateCheckOnStartup',
  'autoCheckin',
  'autoSyncNoticeSeconds',
  'enableBackgroundMessageService',
  'backgroundSyncAllAccounts',
  'systemNotificationsOptIn',
  'notificationHideContent',
  'notificationDirectReply',
  'notifyReply',
  'notifyMention',
  'notifyRate',
  'notifyPersonalMessage',
  'notifySystem',
  'notifyFollowedThread',
  'notifyForumNewThread',
  'notifyKeywordAlert',
  'notifyQuietHours',
  'crossDeviceSync',
  'crossDeviceSyncSettings',
  'crossDeviceSyncDrafts',
  'crossDeviceSyncRateTemplates',
  'crossDeviceSyncBookmarks',
  'crossDeviceSyncPinnedForums',
  'crossDeviceSyncForumWatch',
  'crossDeviceSyncReplyTemplates',
  'crossDeviceSyncReadLater',
  'crossDeviceSyncFollowedThreads',
  'desktopTrayIcon',
  'closeToTray',
  'appIcon',
  'enableDebugOperations',
];

/// The facts of a bundle, one per line.
///
/// [settings] holds the settings by their name, as they are (not encoded); only [diagnosticSettingNames] are told,
/// and only plain values (switches, numbers, short names). A setting whose value can not be told is left out alone,
/// named to [onSettingSkipped]. [deviceModel] is told on Android only, the host name of a desktop never (it often
/// carries the user's name).
String composeDiagnosticsInfo({
  required String appVersion,
  required String buildMode,
  required String platform,
  required String osVersion,
  required String deviceModel,
  required String locale,
  required String display,
  required TsdmAppPluginInfo? plugin,
  required Map<String, Object?> settings,
  required DateTime now,
  void Function(String name, Object error)? onSettingSkipped,
}) {
  final out = StringBuffer()
    ..writeln('tsdm_client diagnostics')
    ..writeln('time: ${_isoWithOffset(now)}')
    ..writeln('app: $appVersion ($buildMode)')
    ..writeln('platform: $platform')
    ..writeln('os: ${_oneLine(osVersion)}');
  if (deviceModel.isNotEmpty) {
    out.writeln('device: ${_oneLine(deviceModel)}');
  }
  out
    ..writeln('locale: $locale')
    ..writeln('display: $display')
    ..writeln(
      plugin == null
          ? 'forum plugin: unknown'
          : 'forum plugin: ${plugin.version}, api ${plugin.api ?? '-'}, nodoc ${_flag(plugin.nodoc)}, '
                'preview ${_flag(plugin.preview)}, device ${_flag(plugin.device)}, admin ${_flag(plugin.admin)}',
    )
    ..writeln('settings:');
  for (final (name, value) in diagnosticSettingsSummary(settings, onSkip: onSettingSkipped)) {
    out.writeln('  $name: $value');
  }
  return out.toString();
}

/// The settings of [settings] a bundle tells ([diagnosticSettingNames]), in that order, with plain values only.
///
/// Each one is turned into its text on its own: one that fails is left out, named to [onSkip], and the others are
/// still told.
List<(String, String)> diagnosticSettingsSummary(
  Map<String, Object?> settings, {
  void Function(String name, Object error)? onSkip,
}) {
  final told = <(String, String)>[];
  for (final name in diagnosticSettingNames) {
    if (!settings.containsKey(name)) {
      continue;
    }
    try {
      told.add((name, _plainValue(settings[name])));
    } on Object catch (e) {
      onSkip?.call(name, e);
    }
  }
  return told;
}

String _plainValue(Object? value) => switch (value) {
  null => '-',
  bool() || num() => '$value',
  // A short name (a locale, a layout, an enum), never a long text: those are not settings a report needs.
  final String s when s.length <= 32 && !s.contains('\n') => s,
  String() => '<${value.length} chars>',
  final Enum e => e.name,
  // The window's size and place, should one be told.
  Size(:final width, :final height) => '${width}x$height',
  Offset(:final dx, :final dy) => '$dx,$dy',
  _ => '<${value.runtimeType}>',
};

String _flag(bool? v) => switch (v) {
  true => '1',
  false => '0',
  null => '-',
};

String _oneLine(String s) => s.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();

String _isoWithOffset(DateTime t) {
  final offset = t.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final minutes = offset.inMinutes.abs();
  String two(int n) => n.toString().padLeft(2, '0');
  final local = t.toIso8601String().split('.').first;
  return '$local$sign${two(minutes ~/ 60)}:${two(minutes % 60)}';
}

/// A log file of the bundle: its name and what of it is taken.
final class _TakenLog {
  const _TakenLog(this.name, this.text, this.size, {required this.cut});

  final String name;
  final String text;
  final int size;
  final bool cut;
}

/// Build the bundle of [request]: a zip of [diagnosticsInfoName] and the recent log files under
/// [diagnosticsLogFolder], all of it redacted. Runs in a background isolate (`compute`): it reads files.
Uint8List buildDiagnosticsBundle(DiagnosticsRequest request) {
  final app = <(DateTime, File)>[];
  final background = <(DateTime, File)>[];
  final today = DateTime(request.now.year, request.now.month, request.now.day);
  final first = DateTime(today.year, today.month, today.day - (request.limits.days - 1));
  final dir = Directory(request.logDir);
  if (dir.existsSync()) {
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name = HistoricalLog.parseFileName(entity.uri.pathSegments.last);
      if (name == null || name.day.isBefore(first) || name.day.isAfter(today)) {
        continue;
      }
      (name.background ? background : app).add((name.day, entity));
    }
  }

  final taken = [
    ..._takeNewest(app, request.limits.appLogBytes),
    ..._takeNewest(background, request.limits.backgroundLogBytes),
  ];

  final info = StringBuffer(redactLogText(request.info))
    ..writeln()
    ..writeln('logs:');
  if (taken.isEmpty) {
    info.writeln('  -');
  }
  for (final log in taken) {
    final bytes = utf8.encode(log.text).length;
    info.writeln('  ${log.name}: $bytes of ${log.size} bytes${log.cut ? ' (newest part)' : ''}');
  }

  final archive = Archive()..addFile(ArchiveFile.bytes(diagnosticsInfoName, utf8.encode(info.toString())));
  for (final log in taken.where((e) => e.text.isNotEmpty)) {
    archive.addFile(ArchiveFile.bytes('$diagnosticsLogFolder/${log.name}', utf8.encode(log.text)));
  }
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

/// The newest days of [logs] that fit in [budget] bytes, the newest day first; the oldest one taken may be cut to its
/// newest lines.
List<_TakenLog> _takeNewest(List<(DateTime, File)> logs, int budget) {
  logs.sort((a, b) => b.$1.compareTo(a.$1));
  final out = <_TakenLog>[];
  var left = budget;
  for (final (_, file) in logs) {
    if (left <= 0) {
      break;
    }
    final size = file.lengthSync();
    final read = _readNewest(file, size, left);
    if (read == null) {
      continue;
    }
    final (text, cut) = read;
    final kept = utf8.encode(text).length;
    // Even when nothing of it is left (all of it dropped at the cut): the facts still name the day.
    out.add(_TakenLog(file.uri.pathSegments.last, text, size, cut: cut));
    if (cut) {
      // The budget ran out in this day: an older day would only fill the rest with its last lines.
      break;
    }
    left -= kept;
  }
  return out;
}

/// What [_readNewest] drops from the start of a cut file once redacted: the lines a secret whose name was left before
/// the cut may still run into (a header value or an html input over several lines).
@visibleForTesting
const diagnosticsCutMargin = 4096;

/// The newest whole lines of [file] that fit in [budget] bytes once redacted, and whether older lines were left out;
/// null when it cannot be read.
///
/// Redacted with the text read before the cut, then cut again at a line end: a secret spanning the cut would
/// otherwise keep its value with its name cut off (`…RET` of `password=SECRET`, a `Cookie:` line followed by its
/// value), which no pattern recognizes. The first [diagnosticsCutMargin] bytes of a cut file are always dropped for that.
(String, bool)? _readNewest(File file, int size, int budget) {
  // Redaction mostly shortens a text; take a little more than the budget so a cut file still fills it.
  final want = math.min(size, budget + budget ~/ 4 + 2 * diagnosticsCutMargin);
  final RandomAccessFile raf;
  try {
    raf = file.openSync();
  } on FileSystemException {
    return null;
  }
  final Uint8List bytes;
  try {
    raf.setPositionSync(size - want);
    bytes = raf.readSync(want);
  } on FileSystemException {
    return null;
  } finally {
    raf.closeSync();
  }
  final cut = want < size;
  final encoded = utf8.encode(redactLogText(utf8.decode(bytes, allowMalformed: true)));
  // Where the kept text starts: past the margin of a cut file, and late enough to fit in the budget.
  var from = math.max(cut ? math.min(diagnosticsCutMargin, encoded.length) : 0, encoded.length - budget);
  if (from == 0) {
    return (utf8.decode(encoded, allowMalformed: true), cut);
  }
  // At the start of a line.
  while (from < encoded.length && encoded[from - 1] != 0x0A) {
    from++;
  }
  return (utf8.decode(encoded.sublist(from), allowMalformed: true), true);
}
