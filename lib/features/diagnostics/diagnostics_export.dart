import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/features/diagnostics/diagnostics_bundle.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/export_file.dart';
import 'package:tsdm_client/utils/log_redaction.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/method_channel.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Whether an export ([exportDiagnostics], [exportCurrentLog]) runs: a second tap (another error block, the settings
/// row) waits for it instead of starting another.
final ValueNotifier<bool> diagnosticsExportBusy = ValueNotifier(false);

/// The bounds of the widget of [context] on the screen, where the share sheet points from on an iPad.
Rect? shareOriginOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) {
    return null;
  }
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Build the diagnostics bundle ([buildDiagnosticsBundle]) and hand it to the user: the share sheet on a phone, a save
/// dialog on a desktop. [context] is only for the snack bar telling where it went or that it failed.
Future<void> exportDiagnostics(BuildContext context, {Rect? shareOrigin}) => _exclusive(context, () async {
  await flushLogSink();
  final now = DateTime.now();
  final info = composeDiagnosticsInfo(
    appVersion: appFullVersion,
    buildMode: kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
    platform: Platform.operatingSystem,
    osVersion: Platform.operatingSystemVersion,
    deviceModel: await _deviceModel(),
    locale: '${Platform.localeName}, app ${LocaleSettings.currentLocale.languageTag}',
    display: _display(),
    plugin: TsdmAppApi.pluginInfo.value,
    settings: _settings(),
    now: now,
  );
  final request = DiagnosticsRequest(info: info, logDir: (await getLogDir()).path, now: now);
  final bytes = await compute(buildDiagnosticsBundle, request);
  return shareOrSaveFile(
    bytes,
    fileName: 'tsdm_diagnostics_${_stamp(now)}.zip',
    mimeType: 'application/zip',
    share: isMobile,
    dialogTitle: t.diagnostics.export,
    shareOrigin: shareOrigin,
  );
});

/// Export the log of this run (what the log page shows), redacted once more off the UI isolate.
Future<void> exportCurrentLog(BuildContext context, {Rect? shareOrigin}) => _exclusive(context, () async {
  final now = DateTime.now();
  // The entries are turned into text here: they hold exceptions, which do not all cross to another isolate.
  final text = talker.history.map((e) => e.generateTextMessage()).join('\n');
  final redacted = await compute(redactLogText, text);
  return shareOrSaveFile(
    Uint8List.fromList(utf8.encode(redacted)),
    fileName: 'log_${_stamp(now)}.txt',
    mimeType: 'text/plain',
    share: isMobile,
    dialogTitle: t.settingsPage.debugSection.exportLog.title,
    shareOrigin: shareOrigin,
  );
});

/// Run [export] unless another one runs, then tell where the file went (a save) or that it failed.
Future<void> _exclusive(BuildContext context, Future<String?> Function() export) async {
  if (diagnosticsExportBusy.value) {
    return;
  }
  diagnosticsExportBusy.value = true;
  try {
    final savedTo = await export();
    if (savedTo != null && context.mounted) {
      showSnackBar(
        context: context,
        message: t.diagnostics.saved(path: savedTo),
      );
    }
  } on Object catch (e, st) {
    talker.handle(e, st, 'failed to export diagnostics');
    if (context.mounted) {
      showSnackBar(context: context, message: t.diagnostics.failed);
    }
  } finally {
    diagnosticsExportBusy.value = false;
  }
}

Future<String> _deviceModel() async {
  if (!isAndroid) {
    return '';
  }
  try {
    return (await androidDeviceName().timeout(const Duration(seconds: 2))).trim();
  } on Object catch (e) {
    talker.debug('device model not available: $e');
    return '';
  }
}

String _display() {
  final views = PlatformDispatcher.instance.views;
  if (views.isEmpty) {
    return '-';
  }
  final view = views.first;
  final size = view.physicalSize;
  return '${size.width.round()}x${size.height.round()} @${view.devicePixelRatio.toStringAsFixed(2)}';
}

Map<String, Object?> _settings() {
  if (!getIt.isRegistered<SettingsRepository>()) {
    return const {};
  }
  try {
    return getIt.get<SettingsRepository>().currentSettings.toMap();
  } on Object catch (e) {
    talker.debug('settings not available for diagnostics: $e');
    return const {};
  }
}

String _stamp(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${time.year}${two(time.month)}${two(time.day)}_${two(time.hour)}${two(time.minute)}${two(time.second)}';
}
