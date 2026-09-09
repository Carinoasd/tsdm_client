import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as path;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/settings/models/historical_log.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/log_redaction.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';
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

    final nameRe = RegExp(r'^tsdm_client_(?<year>\d\d\d\d)(?<month>\d\d)(?<day>\d\d).log$');
    for (final logFile in logDir.listSync()) {
      if (logFile.statSync().type != FileSystemEntityType.file) {
        continue;
      }
      final fileName = path.basename(logFile.path);
      final m = nameRe.firstMatch(fileName);
      if (m == null) {
        continue;
      }

      final year = m.namedGroup('year')!.parseToInt()!;
      final month = m.namedGroup('month')!.parseToInt()!;
      final day = m.namedGroup('day')!.parseToInt()!;

      final logTime = DateTime(year, month, day);
      logFiles.add(HistoricalLog(logTime, File(logFile.path)));
    }

    return logFiles;
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.debugSection.viewHistoryLog;
    final body = FutureBuilder(
      future: _loadLogFiles(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const CenteredCircularIndicator();
        }

        if (snapshot.hasError) {
          error('failed to load logs: ${snapshot.error}');
          return Center(child: Text('${context.t.general.failedToLoad}: ${snapshot.error}'));
        }

        final logFiles = snapshot.data!;

        return ListView.builder(
          padding: context.safePadding(),
          itemCount: logFiles.length,
          itemBuilder: (context, idx) => ListTile(
            title: Text(logFiles[idx].time.yyyyMMDD()),
            onTap: () async => context.pushNamed(ScreenPaths.debugHistoricalLogDetail, extra: logFiles[idx]),
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

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.debugSection.viewHistoryLog;
    final body = FutureBuilder(
      future: File(widget.log.file.path).readAsString(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const CenteredCircularIndicator();
        }

        if (snapshot.hasError) {
          error('failed to load log ${widget.log.time.yyyyMMDD()}: ${snapshot.error}');
          return Center(child: Text('${context.t.general.failedToLoad}: ${snapshot.error}'));
        }

        // Older log files may predate redaction; never show or export a secret from them.
        _logData = redactSensitive(snapshot.data!);

        return SingleChildScrollView(child: SelectableText(_logData!));
      },
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.log.time.yyyyMMDD()),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_alt_outlined),
            onPressed: () async {
              if (_logData == null) {
                showSnackBar(context: context, message: 'Log is empty');
                return;
              }
              await FilePicker.platform.saveFile(
                fileName: 'log_${widget.log.time.yyyyMMDD()}.txt',
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
