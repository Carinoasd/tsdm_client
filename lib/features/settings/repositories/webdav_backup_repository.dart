import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/repositories/backup_repository.dart';
import 'package:tsdm_client/features/settings/repositories/webdav_client.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/logger.dart';

/// How often the backup is uploaded on its own.
enum WebdavAutoBackup {
  /// Only when asked for.
  off(Duration.zero),

  /// Once a day.
  daily(Duration(days: 1)),

  /// Once a week.
  weekly(Duration(days: 7))
  ;

  const WebdavAutoBackup(this.interval);

  /// Time between two automatic backups.
  final Duration interval;
}

/// Where and how often the database is backed up to WebDAV. The password is kept apart, see [WebdavBackupStore].
final class WebdavBackupConfig {
  /// Constructor.
  const WebdavBackupConfig({
    this.url = '',
    this.username = '',
    this.directory = defaultDirectory,
    this.schedule = WebdavAutoBackup.off,
    this.keep = defaultKeep,
  });

  /// Decode from [toJson]; anything unreadable falls back to the defaults.
  factory WebdavBackupConfig.fromJson(Map<String, dynamic> json) => WebdavBackupConfig(
    url: json['url'] as String? ?? '',
    username: json['username'] as String? ?? '',
    directory: json['directory'] as String? ?? defaultDirectory,
    schedule: WebdavAutoBackup.values.asNameMap()[json['schedule']] ?? WebdavAutoBackup.off,
    keep: ((json['keep'] as num?)?.toInt() ?? defaultKeep).clamp(1, maxKeep),
  );

  /// Directory below the WebDAV root used when none is given.
  static const defaultDirectory = 'tsdm_client';

  /// Backups kept by default.
  static const defaultKeep = 5;

  /// Most backups that can be kept.
  static const maxKeep = 100;

  /// WebDAV root url.
  final String url;

  /// User name of the basic authentication.
  final String username;

  /// Directory below [url], segments separated by `/`.
  final String directory;

  /// Automatic backup.
  final WebdavAutoBackup schedule;

  /// Number of backups kept on the server; older ones are deleted after each upload.
  final int keep;

  /// [url] as an http(s) url with a host, null when it is not one.
  Uri? get baseUri {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  /// Whether the server is set.
  bool get configured => baseUri != null;

  /// Encode.
  Map<String, dynamic> toJson() => {
    'url': url,
    'username': username,
    'directory': directory,
    'schedule': schedule.name,
    'keep': keep,
  };

  /// Copy with some fields replaced.
  WebdavBackupConfig copyWith({
    String? url,
    String? username,
    String? directory,
    WebdavAutoBackup? schedule,
    int? keep,
  }) => WebdavBackupConfig(
    url: url ?? this.url,
    username: username ?? this.username,
    directory: directory ?? this.directory,
    schedule: schedule ?? this.schedule,
    keep: keep ?? this.keep,
  );
}

/// When backups ran: written by whichever isolate (the app, the Android background service) runs one.
final class WebdavBackupState {
  /// Constructor.
  const WebdavBackupState({this.lastBackupAt, this.lastAttemptAt});

  /// Decode from [toJson].
  factory WebdavBackupState.fromJson(Map<String, dynamic> json) {
    DateTime? read(String key) {
      final v = json[key];
      return v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
    }

    return WebdavBackupState(lastBackupAt: read('lastBackupAt'), lastAttemptAt: read('lastAttemptAt'));
  }

  /// Last successful upload.
  final DateTime? lastBackupAt;

  /// Last start of an automatic backup, successful or not.
  final DateTime? lastAttemptAt;

  /// Encode.
  Map<String, dynamic> toJson() => {
    if (lastBackupAt != null) 'lastBackupAt': lastBackupAt!.millisecondsSinceEpoch,
    if (lastAttemptAt != null) 'lastAttemptAt': lastAttemptAt!.millisecondsSinceEpoch,
  };
}

/// Files of the WebDAV backup settings, in a directory of their own next to the database (never inside it).
///
/// Kept out of the database on purpose: the database is what gets backed up, so settings stored in it would upload
/// the WebDAV password to the WebDAV server inside every backup (and into every local export), and restoring a backup
/// from WebDAV would replace the settings used to fetch it.
///
/// The password is stored encrypted (AES-256-GCM) with a random key kept in a separate file of the same private
/// directory; neither file is part of any backup.
final class WebdavBackupStore with LoggerMixin {
  /// Constructor, files in [directory].
  WebdavBackupStore(this.directory);

  /// The store of the app: `<application support>/webdav`.
  static Future<WebdavBackupStore> forApp() async {
    final support = await getApplicationSupportDirectory();
    return WebdavBackupStore(Directory('${support.path}${Platform.pathSeparator}webdav'));
  }

  /// Directory holding the files.
  final Directory directory;

  File _file(String name) => File('${directory.path}${Platform.pathSeparator}$name');

  File get _configFile => _file('config.json');

  File get _stateFile => _file('state.json');

  File get _passwordFile => _file('password.json');

  File get _keyFile => _file('key.bin');

  static final List<int> _aad = utf8.encode('tsdm_client.webdav_password.v1');

  Future<Map<String, dynamic>?> _readJson(File file) async {
    try {
      if (!file.existsSync()) {
        return null;
      }
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } on Object catch (e) {
      warning('webdav: can not read ${file.uri.pathSegments.last}: $e');
      return null;
    }
  }

  Future<void> _writeJson(File file, Map<String, dynamic> json) => _writeBytes(file, utf8.encode(jsonEncode(json)));

  /// Write through a temporary file and a rename, so a reader in the other isolate never sees half a file.
  Future<void> _writeBytes(File file, List<int> bytes) async {
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    final tmp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  /// The settings, the defaults when there are none.
  Future<WebdavBackupConfig> readConfig() async {
    final json = await _readJson(_configFile);
    return json == null ? const WebdavBackupConfig() : WebdavBackupConfig.fromJson(json);
  }

  /// Save the settings.
  Future<void> writeConfig(WebdavBackupConfig config) => _writeJson(_configFile, config.toJson());

  /// When backups ran.
  Future<WebdavBackupState> readState() async {
    final json = await _readJson(_stateFile);
    return json == null ? const WebdavBackupState() : WebdavBackupState.fromJson(json);
  }

  /// Save when backups ran.
  Future<void> writeState(WebdavBackupState state) => _writeJson(_stateFile, state.toJson());

  Future<SecretKey> _key({required bool create}) async {
    if (_keyFile.existsSync()) {
      final bytes = await _keyFile.readAsBytes();
      if (bytes.length == 32) {
        return SecretKey(bytes);
      }
    }
    if (!create) {
      throw const FileSystemException('webdav key missing');
    }
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    await _writeBytes(_keyFile, bytes);
    return SecretKey(bytes);
  }

  /// The saved password, empty when there is none (or it can not be read any more).
  Future<String> readPassword() async {
    final json = await _readJson(_passwordFile);
    if (json == null) {
      return '';
    }
    try {
      final key = await _key(create: false);
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          base64Decode(json['ciphertext'] as String),
          nonce: base64Decode(json['nonce'] as String),
          mac: Mac(base64Decode(json['mac'] as String)),
        ),
        secretKey: key,
        aad: _aad,
      );
      return utf8.decode(clear);
    } on Object catch (e) {
      warning('webdav: saved password can not be read: ${e.runtimeType}');
      return '';
    }
  }

  /// Save [password]; an empty one removes the saved password.
  Future<void> writePassword(String password) async {
    if (password.isEmpty) {
      if (_passwordFile.existsSync()) {
        await _passwordFile.delete();
      }
      return;
    }
    final key = await _key(create: true);
    final algorithm = AesGcm.with256bits();
    final box = await algorithm.encrypt(utf8.encode(password), secretKey: key, nonce: algorithm.newNonce(), aad: _aad);
    await _writeJson(_passwordFile, {
      'version': 1,
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
      'ciphertext': base64Encode(box.cipherText),
    });
  }
}

/// A backup file found on the server.
final class WebdavBackupFile {
  /// Constructor.
  const WebdavBackupFile({required this.name, required this.createdAt, required this.withAccounts, this.size});

  /// File name.
  final String name;

  /// When it was exported, from the name.
  final DateTime createdAt;

  /// It carries account logins encrypted with a password (`_accounts` names).
  final bool withAccounts;

  /// Size in bytes, when the server said.
  final int? size;
}

/// Backups of the app database on a WebDAV server: the same files as the local export ([BackupRepository]).
final class WebdavBackupRepository with LoggerMixin {
  /// Constructor. [databaseFile] gives the database to back up; [dio] and [now] are replaced in tests.
  WebdavBackupRepository({
    required this.store,
    required Future<File> Function() databaseFile,
    BackupRepository backup = const BackupRepository(),
    Dio? dio,
    DateTime Function()? now,
  }) : _databaseFile = databaseFile,
       _backup = backup,
       _dio = dio,
       _now = now ?? DateTime.now;

  /// Settings and state.
  final WebdavBackupStore store;

  final Future<File> Function() _databaseFile;
  final BackupRepository _backup;
  final Dio? _dio;
  final DateTime Function() _now;

  /// Names of backup files, as the local export names them: `tsdm_client_data_<microseconds>[_accounts].db`.
  static final backupName = RegExp(r'^tsdm_client_data_(\d+)(_accounts)?\.db$');

  /// Least time between two attempts of the automatic backup, so a failing server is not asked on every tick, and the
  /// app and the background service (separate isolates) do not both upload.
  static const retryGap = Duration(hours: 1);

  /// The upload in progress in this isolate.
  Future<WebdavBackupFile>? _running;

  /// Set by [suspend]: the database is about to be replaced, no automatic backup starts any more.
  var _suspended = false;

  /// Stop starting automatic backups in this isolate and wait for a running upload; called before the database is
  /// replaced by an import (the app restarts afterwards).
  Future<void> suspend() async {
    _suspended = true;
    try {
      await _running;
    } on Object {
      // Reported by its caller.
    }
  }

  /// File name of a backup made at [time].
  static String fileNameAt(DateTime time, {required bool withAccounts}) =>
      'tsdm_client_data_${time.microsecondsSinceEpoch}${withAccounts ? '_accounts' : ''}.db';

  /// Whether an automatic backup should run at [now].
  static bool isDue(WebdavBackupConfig config, WebdavBackupState state, DateTime now) {
    if (config.schedule == WebdavAutoBackup.off || !config.configured) {
      return false;
    }
    final attempt = state.lastAttemptAt;
    if (attempt != null && now.difference(attempt) < retryGap && !now.isBefore(attempt)) {
      return false;
    }
    final last = state.lastBackupAt;
    // A clock set back (last backup "in the future") counts as due, or backups would stop until the clock catches up.
    return last == null || now.isBefore(last) || now.difference(last) >= config.schedule.interval;
  }

  /// The backups among [entries], newest first.
  static List<WebdavBackupFile> backupsOf(Iterable<WebdavEntry> entries) {
    final files = <WebdavBackupFile>[];
    for (final entry in entries) {
      if (entry.isCollection) {
        continue;
      }
      final match = backupName.firstMatch(entry.name);
      final stamp = int.tryParse(match?.group(1) ?? '');
      if (match == null || stamp == null) {
        continue;
      }
      files.add(
        WebdavBackupFile(
          name: entry.name,
          createdAt: DateTime.fromMicrosecondsSinceEpoch(stamp),
          withAccounts: match.group(2) != null,
          size: entry.size,
        ),
      );
    }
    return files..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// A client for [config] and [password].
  WebdavClient clientFor(WebdavBackupConfig config, String password) {
    final base = config.baseUri;
    if (base == null) {
      throw ArgumentError('webdav url not set');
    }
    return WebdavClient(baseUrl: base, username: config.username, password: password, dio: _dio);
  }

  Future<(WebdavClient, List<String>, WebdavBackupConfig)> _open() async {
    final config = await store.readConfig();
    final client = clientFor(config, await store.readPassword());
    return (client, WebdavClient.splitPath(config.directory), config);
  }

  /// Ask the server whether [config] and [password] work (the directory need not exist yet).
  Future<WebdavCheck> testConnection(WebdavBackupConfig config, String password) => clientFor(config, password).check();

  /// Export the database and upload it now; [secretsPassword] carries the account logins as the local export does.
  ///
  /// Older backups beyond the number to keep are deleted afterwards. One upload at a time in this isolate: a second
  /// call while one runs gets the running one.
  Future<WebdavBackupFile> backupNow({String? secretsPassword}) =>
      _running ??= _backupNow(secretsPassword).whenComplete(() => _running = null);

  /// Copy the database for upload off this isolate: the snapshot, the stripping and the `VACUUM` are synchronous
  /// sqlite calls, and the automatic backup starts on its own while the user may be scrolling.
  Future<Uint8List> _export(String? secretsPassword) async {
    final path = (await _databaseFile()).path;
    final backup = _backup;
    return Isolate.run(() {
      // A fresh isolate: the app's logger is not set up in it.
      talker = Talker(settings: TalkerSettings(enabled: false));
      return backup.exportSanitized(File(path), secretsPassword: secretsPassword);
    });
  }

  Future<WebdavBackupFile> _backupNow(String? secretsPassword) async {
    final (client, dir, config) = await _open();
    final bytes = await _export(secretsPassword);
    final time = _now();
    final name = fileNameAt(time, withAccounts: secretsPassword != null);
    await client.ensureCollection(dir);
    await client.put([...dir, name], bytes);
    info('webdav: uploaded backup of ${bytes.length} bytes');
    final state = await store.readState();
    await store.writeState(WebdavBackupState(lastBackupAt: time, lastAttemptAt: state.lastAttemptAt));
    try {
      await _prune(client, dir, config.keep, uploaded: name);
    } on Object catch (e) {
      // The upload is done; old files stay until the next backup.
      warning('webdav: pruning old backups failed: $e');
    }
    return WebdavBackupFile(name: name, createdAt: time, withAccounts: secretsPassword != null, size: bytes.length);
  }

  /// Delete the backups beyond [keep], never the one just [uploaded] (with a clock set back its name sorts oldest).
  ///
  /// Backups with account logins (`_accounts`, only ever made by hand) are counted apart from the plain ones: the
  /// daily automatic backups must not push out the one backup that can bring the logins back.
  Future<void> _prune(WebdavClient client, List<String> dir, int keep, {required String uploaded}) async {
    final backups = backupsOf(await client.list(dir));
    for (final withAccounts in [false, true]) {
      final group = backups.where((b) => b.withAccounts == withAccounts).toList();
      final others = group.where((b) => b.name != uploaded).toList();
      final keepOthers = group.length == others.length ? keep : keep - 1;
      for (final old in others.skip(keepOthers)) {
        await client.delete([...dir, old.name]);
        debug('webdav: deleted old backup');
      }
    }
  }

  /// The backups on the server, newest first.
  Future<List<WebdavBackupFile>> listBackups() async {
    final (client, dir, _) = await _open();
    return backupsOf(await client.list(dir));
  }

  /// Prefix of downloaded backups in the temporary directory.
  static const _downloadPrefix = 'webdav-';

  /// Delete backups downloaded for a restore that are still in [temp] (the system temporary directory by default):
  /// the restore ends by closing the app, before the downloaded file could be removed.
  Future<void> deleteStaleDownloads({Directory? temp}) async {
    try {
      final base = temp ?? await getTemporaryDirectory();
      if (!base.existsSync()) return;
      await for (final entity in base.list()) {
        final name = entity.uri.pathSegments.last;
        if (entity is File && name.startsWith(_downloadPrefix) && name.contains('tsdm_client_data_')) {
          await entity.delete();
        }
      }
    } on Object catch (e) {
      warning('webdav: can not clean old downloads: $e');
    }
  }

  /// Download the backup [name] into a new file of [temp] (the system temporary directory by default).
  Future<File> download(String name, {Directory? temp}) async {
    if (!backupName.hasMatch(name)) {
      throw ArgumentError('not a backup file name');
    }
    final (client, dir, _) = await _open();
    final base = temp ?? await getTemporaryDirectory();
    final target = File('${base.path}${Platform.pathSeparator}$_downloadPrefix${_now().microsecondsSinceEpoch}-$name');
    await client.download([...dir, name], target);
    return target;
  }

  /// Run the automatic backup when it is due ([isDue]); true when a backup was uploaded. Never throws.
  ///
  /// The attempt is recorded before the upload starts, so the other isolate skips it meanwhile and a failing server is
  /// asked again only after [retryGap].
  Future<bool> runIfDue() async {
    try {
      final config = await store.readConfig();
      final state = await store.readState();
      final now = _now();
      if (_suspended || _running != null || !isDue(config, state, now)) {
        return false;
      }
      await store.writeState(WebdavBackupState(lastBackupAt: state.lastBackupAt, lastAttemptAt: now));
      await backupNow();
      return true;
    } on Object catch (e, st) {
      warning('webdav: automatic backup failed: $e');
      debug('$st');
      return false;
    }
  }
}

/// Runs the automatic WebDAV backup while the app is open: soon after the start, then every [period].
///
/// On Android the background message service also calls [WebdavBackupRepository.runIfDue] on its ticks, so the
/// backup runs while the app is in the background too; the attempt record keeps the two from both uploading.
final class WebdavAutoBackupScheduler {
  /// Constructor.
  WebdavAutoBackupScheduler(this.repository, {this.period = const Duration(minutes: 30)});

  /// The repository whose [WebdavBackupRepository.runIfDue] runs.
  final WebdavBackupRepository repository;

  /// Time between two checks.
  final Duration period;

  Timer? _timer;
  Timer? _first;

  /// Start checking.
  void start({Duration firstDelay = const Duration(minutes: 1)}) {
    unawaited(repository.deleteStaleDownloads());
    _first?.cancel();
    _timer?.cancel();
    _first = Timer(firstDelay, () => unawaited(repository.runIfDue()));
    _timer = Timer.periodic(period, (_) => unawaited(repository.runIfDue()));
  }

  /// Stop checking.
  void dispose() {
    _first?.cancel();
    _timer?.cancel();
  }
}
