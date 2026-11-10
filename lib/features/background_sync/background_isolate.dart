import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/background_sync/background_sync_tick.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/proxy_provider/proxy_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/connection/connection.dart' as conn;
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/saved_answer_store.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/app_language.dart';
import 'package:tsdm_client/utils/log_redaction.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/redacting_talker.dart';

/// What an isolate of the app without a page needs to talk to the forum as one of the saved accounts: the shared
/// database, the settings, the proxy, and clients built from an account's stored cookie.
///
/// Opened once by the Android background message service (#80, `background_sync_entry.dart`) and by the isolate the
/// notification plugin starts for a reply typed in a notification (`direct_reply_entry.dart`): both have no activity,
/// and both build their clients the same way.
final class BackgroundIsolateBase {
  BackgroundIsolateBase._(this.db, this.storage, this.settings, this.proxy);

  /// The database shared with the app.
  final AppDatabase db;

  /// The storage over [db].
  final StorageProvider storage;

  /// The app's settings, read from [db].
  final SettingsRepository settings;

  /// Filled before every request by [refreshNetwork]: the system proxy is only known after asking the platform.
  final ProxyProvider proxy;

  /// Open the shared database and register what the shared repositories look up in `getIt` of this isolate.
  static Future<BackgroundIsolateBase> open() async {
    // Dart analyzer does not work on conditional export.
    // ignore: undefined_function
    final db = AppDatabase(conn.connect());
    final StorageProvider storage;
    final SettingsRepository settingsRepo;
    try {
      storage = StorageProvider(db, await preloadCookie(db), {});
      settingsRepo = SettingsRepository(storage);
      await settingsRepo.init();
    } on Object {
      // Not left open for the next try.
      await db.close();
      rethrow;
    }
    final proxy = ProxyProvider();
    getIt
      ..registerSingleton(proxy)
      // Closed by `getIt.reset()` too: an isolate starting over after a failure opens it again.
      ..registerSingleton(db, dispose: (d) => d.close())
      ..registerSingleton(storage)
      ..registerSingleton(settingsRepo)
      ..registerFactory(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton(NetErrorSaver())
      // An account removed here takes the pages saved for it along, as in the app.
      ..registerSingleton(SavedAnswerStore());
    return BackgroundIsolateBase._(db, storage, settingsRepo, proxy);
  }

  /// A client sending [cookie] (one account's, loaded from the database), built as the app's are.
  ///
  /// The Kotlin http client lives in the activity's method channel: this isolate has no activity.
  NetClientProvider clientOf(CookieProvider cookie) =>
      NetClientProvider.buildNoCookie(dio: settings.buildDefaultDio(nativeHttp: false), cookie: cookie);

  /// Settings the client is built from, read again for this request: a snapshot from the isolate's start is stale as
  /// soon as the app changed the proxy (or was started again), and the system proxy has to be asked for here.
  Future<void> refreshNetwork() => refreshBackgroundNetworkSettings(settings: settings, updateProxy: proxy.updateProxy);

  /// Load the app's language so the notification texts match the app: the stored tag means here what it means to the
  /// app ([appLocaleOfSetting]), an unknown one follows the device in both.
  Future<void> applyLocale(String locale) async {
    final appLocale = appLocaleOfSetting(locale);
    if (appLocale == null) {
      await LocaleSettings.useDeviceLocale();
    } else {
      await LocaleSettings.setLocale(appLocale);
    }
  }

  /// Close the database.
  Future<void> dispose() => db.close();
}

/// The log file of an isolate without a page: lines are written and flushed from several places at once (the ticks
/// of the background message service overlap, a reply typed in a notification logs while another one is flushed).
///
/// An [IOSink] takes neither a write nor a second flush while a flush is running (`Bad state: StreamSink is bound to
/// a stream`): here the flushes run one after another, and what is written during one is held back and written, in
/// order, as soon as it is done. A flush that fails gives its own error to its caller; lines the file's sink then
/// refuses (it throws) stay held, in order, for the next flush, up to [heldLimit]. A sink that takes them and loses
/// them is no different from before.
final class BackgroundLogSink {
  /// Constructor.
  BackgroundLogSink(this._sink);

  final IOSink _sink;

  /// How much is held (in UTF-16 code units) before the held lines are given up: a file that can not be written for
  /// hours must not grow the memory of the service.
  static const int heldLimit = 256 * 1024;

  /// What is written in place of the lines given up.
  static const droppedMark = '[log lines dropped: the log file could not be written]\n';

  /// Written while a flush was running, or after lines the file's sink did not take.
  final _held = StringBuffer();

  var _flushing = false;

  /// The flush running now.
  Future<void>? _running;

  /// The one flush waiting for [_running]: every caller arriving meanwhile shares it.
  Future<void>? _queued;

  /// Append [text].
  void write(String text) {
    // Behind the lines still held: the order of the file is the order of the calls.
    if (_flushing || _held.isNotEmpty) {
      if (_held.length > heldLimit) {
        _held
          ..clear()
          ..write(droppedMark);
      }
      _held.write(text);
    } else {
      _sink.write(text);
    }
  }

  /// Done when everything written before this call is handed to the file.
  Future<void> flush() {
    final running = _running;
    if (!_flushing || running == null) {
      return _running = _flushOnce();
    }
    // What was written since the running flush began is only written when it ends: one more flush after it.
    return _queued ??= running.then<void>((_) {}, onError: (Object _) {}).then((_) {
      _queued = null;
      return flush();
    });
  }

  Future<void> _flushOnce() async {
    _flushing = true;
    try {
      // What an earlier, failed flush left behind.
      _release();
      await _sink.flush();
    } finally {
      _flushing = false;
      _release();
    }
  }

  /// Hand the held lines to the file's sink. One that does not take them (it failed) keeps them held: the error the
  /// caller of [flush] gets is the one of the flush, not this one.
  void _release() {
    if (_held.isEmpty) {
      return;
    }
    try {
      _sink.write(_held.toString());
      _held.clear();
    } on Object {
      // Kept for the next flush.
    }
  }
}

/// Log lines of an isolate without a page go to their own file in the log directory, exported with the app's logs.
final class _BackgroundLogObserver implements TalkerObserver {
  _BackgroundLogObserver(this._sink);

  final BackgroundLogSink _sink;

  void _write(TalkerData data) => _sink.write('${redactSensitive(data.generateTextMessage())}\n');

  @override
  void onError(TalkerError err) => _write(err);

  @override
  void onException(TalkerException err) => _write(err);

  @override
  void onLog(TalkerData log) => _write(log);
}

/// Send the log lines of this isolate to the day's log file of the background isolates (`tsdm_client_bg_<day>.log`),
/// and return its sink for the caller to flush.
Future<BackgroundLogSink> initBackgroundLogger() async {
  final logDir = await getLogDir();
  if (!logDir.existsSync()) {
    await logDir.create(recursive: true);
  }
  final now = DateTime.now();
  final day = '${now.year}${"${now.month}".padLeft(2, "0")}${"${now.day}".padLeft(2, "0")}';
  final sink = BackgroundLogSink(
    File('${logDir.path}${Platform.pathSeparator}tsdm_client_bg_$day.log').openWrite(mode: FileMode.append),
  );
  talker = RedactingTalker(
    logger: TalkerLogger(output: debugPrint),
    settings: TalkerSettings(colors: {TalkerKey.debug: AnsiPen()..xterm(60)}),
    observer: _BackgroundLogObserver(sink),
  );
  return sink;
}
