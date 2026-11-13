import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as path;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/settings/models/historical_log.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/log_redaction.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Colors of the talker screens (log list, the nested "Talker Monitor" page and their sheets) taken from [theme].
///
/// The package default is a fixed dark palette: under the light app theme it left the status bar icons unreadable on
/// the dark app bar and the nested monitor page with a light app bar over a dark body (#15). The talker app bars
/// paint `backgroundColor`, so a surface-colored background also gives them the same overlay style as any other
/// app bar. The light variant darkens the two grey log levels whose default shades were meant for a dark ground.
TalkerScreenTheme buildTalkerScreenTheme(ThemeData theme) {
  final cs = theme.colorScheme;
  return TalkerScreenTheme(
    backgroundColor: cs.surface,
    textColor: cs.onSurface,
    cardColor: cs.surfaceContainerHigh,
    logColors: switch (theme.brightness) {
      Brightness.light => {TalkerKey.debug: const Color(0xFF616161), TalkerKey.verbose: const Color(0xFF757575)},
      Brightness.dark => null,
    },
  );
}

/// Debug page for show all caught log since this start.
class DebugLogPage extends StatefulWidget {
  /// Constructor.
  const DebugLogPage({super.key});

  @override
  State<DebugLogPage> createState() => _DebugLogPageState();
}

class _DebugLogPageState extends State<DebugLogPage> {
  @override
  Widget build(BuildContext context) {
    final tr = context.t.debugLogPage;
    return TalkerScreen(talker: talker, appBarTitle: tr.title, theme: buildTalkerScreenTheme(Theme.of(context)));
  }
}

/// Page showing all historical logs.
class DebugHistoricalLogPage extends StatelessWidget with LoggerMixin {
  /// Constructor.
  const DebugHistoricalLogPage({super.key});

  Future<List<HistoricalLog>> _loadLogFiles() async {
    final logDir = await getLogDir();
    if (!logDir.existsSync()) {
      error('log directory not found: ${logDir.path}');
      return [];
    }

    final logFiles = <HistoricalLog>[];

    // The app's own days, and those of the Android background message service (`_bg_`): a report of messages missed
    // while the app was in the background needs the service's log, which only it writes (GitHub #173).
    for (final logFile in logDir.listSync()) {
      if (logFile.statSync().type != FileSystemEntityType.file) {
        continue;
      }
      final name = HistoricalLog.parseFileName(path.basename(logFile.path));
      if (name == null) {
        continue;
      }
      logFiles.add(HistoricalLog(name.day, File(logFile.path), background: name.background));
    }

    return logFiles;
  }

  /// The day, and whose log it is when not the app's.
  static String _title(BuildContext context, HistoricalLog log) => log.background
      ? '${log.time.yyyyMMDD()} · ${context.t.settingsPage.debugSection.viewHistoryLog.backgroundService}'
      : log.time.yyyyMMDD();

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.debugSection.viewHistoryLog;
    final body = FutureBuilder(
      future: _loadLogFiles(),
      builder: (context, snapshot) {
        // The error first: a failed future has no data and used to spin forever.
        if (snapshot.hasError) {
          error('failed to load logs: ${snapshot.error}');
          return AppStateView(
            icon: Icons.error_outline,
            error: true,
            message: '${context.t.general.failedToLoad}: ${snapshot.error}',
          );
        }

        if (!snapshot.hasData) {
          return const CenteredCircularIndicator();
        }

        // Newest day first, the app's log before the service's of the same day.
        final logFiles = snapshot.data!
          ..sort((a, b) {
            final byDay = b.time.compareTo(a.time);
            return byDay != 0 ? byDay : (a.background ? 1 : 0) - (b.background ? 1 : 0);
          });
        if (logFiles.isEmpty) {
          return AppStateView(icon: Icons.history_toggle_off_outlined, message: context.t.general.noData);
        }

        return AppCenteredList(
          maxWidth: appFormMaxWidth,
          builder: (context, padding, _) => ListView.separated(
            padding: padding.copyWith(top: 12).add(context.safePadding()),
            itemCount: logFiles.length,
            separatorBuilder: (_, _) => appListSeparator,
            itemBuilder: (context, idx) => AppSurface(
              onTap: () async => context.pushNamed(ScreenPaths.debugHistoricalLogDetail, extra: logFiles[idx]),
              child: Row(
                children: [
                  AppIconTile(logFiles[idx].background ? Icons.sync_outlined : Icons.description_outlined),
                  sizedBoxW12H12,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _title(context, logFiles[idx]),
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          path.basename(logFiles[idx].file.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        );
      },
    );

    return Scaffold(
      appBar: AppBar(title: Text(tr.historicalLogs)),
      body: SafeArea(bottom: false, child: body),
    );
  }
}

/// Page to show the detail of historical log.
///
/// The caller MUST ensure corresponding log file is accessible.
class DebugHistoricalLogDetailPage extends StatefulWidget {
  /// Constructor.
  const DebugHistoricalLogDetailPage(this.log, {super.key});

  /// The log to show page.
  final HistoricalLog log;

  @override
  State<DebugHistoricalLogDetailPage> createState() => _DebugHistoricalLogDetailPageState();
}

class _DebugHistoricalLogDetailPageState extends State<DebugHistoricalLogDetailPage> with LoggerMixin {
  /// Log content.
  String? _logData;

  /// The file read and redacted once, off the UI isolate: older log files may predate redaction; never show or export
  /// a secret from them.
  late final Future<String> _redacted = File(
    widget.log.file.path,
  ).readAsString().then((text) => compute(redactLogText, text));

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.debugSection.viewHistoryLog;
    final body = FutureBuilder(
      future: _redacted,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          error('failed to load log ${widget.log.time.yyyyMMDD()}: ${snapshot.error}');
          return AppStateView(
            icon: Icons.error_outline,
            error: true,
            message: '${context.t.general.failedToLoad}: ${snapshot.error}',
          );
        }

        if (!snapshot.hasData) {
          return const CenteredCircularIndicator();
        }

        _logData = snapshot.data;

        // Monospaced text in a rounded block; long lines wrap, the page scrolls.
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12).add(context.safePadding()),
          child: AppInsetBlock(
            outlined: true,
            padding: edgeInsetsL12T12R12B12,
            child: SelectableText(
              _logData!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.4),
            ),
          ),
        );
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(DebugHistoricalLogPage._title(context, widget.log)),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_alt_outlined),
            onPressed: () async {
              if (_logData == null) {
                showSnackBar(context: context, message: 'Log is empty');
                return;
              }
              await FilePicker.platform.saveFile(
                fileName: 'log_${widget.log.background ? 'bg_' : ''}${widget.log.time.yyyyMMDD()}.txt',
                bytes: utf8.encode(_logData!),
              );
            },
            tooltip: tr.export,
          ),
        ],
      ),
      body: SafeArea(bottom: false, child: body),
    );
  }
}
