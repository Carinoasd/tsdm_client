import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tsdm_client/features/update/repository/release_update_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/widgets/shutdown.dart';

/// Starts a process that outlives the app, without anything on screen.
typedef DetachedLauncher = Future<void> Function(String executable, List<String> arguments);

/// Installs the portable Windows build over the folder the app runs from.
///
/// The running files are locked, so the verified zip is unpacked next to the downloads first, then a small
/// PowerShell script waits for the app to exit, copies the new files over the old ones and starts the app again. The
/// files it replaces are backed up first and put back when copying fails. Only the files of the release are written:
/// other files in the folder are left alone, and the user data lives in the application support folder anyway.
///
/// The app only exits once the script proved it runs by writing [startedMarkerName] with the nonce of this install:
/// an execution policy, AppLocker or an antivirus may stop PowerShell or the script, and quitting then would leave
/// the user without the app and without the update.
class WindowsUpdateInstaller implements UpdateInstaller {
  /// Optional dependencies support offline tests.
  WindowsUpdateInstaller({
    String? executable,
    String? updateDirectory,
    DetachedLauncher? launch,
    Future<void> Function()? quit,
    Duration startTimeout = const Duration(seconds: 20),
  }) : _executable = executable,
       _updateDirectory = updateDirectory,
       _launch = launch ?? _launchDetached,
       _quit = quit ?? exitApp,
       _startTimeout = startTimeout;

  final String? _executable;
  final String? _updateDirectory;
  final DetachedLauncher _launch;
  final Future<void> Function() _quit;
  final Duration _startTimeout;

  /// Executable name inside the release zip and the installed folder.
  static const executableName = 'tsdm_client.exe';

  /// Top level folder of the release zip.
  static const releaseFolder = 'tsdm_client';

  /// Name of the update script written next to the downloads.
  static const scriptName = 'apply-update.ps1';

  /// Log written by the update script, kept for diagnosis.
  static const logName = 'update.log';

  /// Written by the update script as its first action, holding the nonce it was started with.
  static const startedMarkerName = 'apply-update.started';

  /// Written by the app when the script of [nonce] did not report in within [_startTimeout]: that script, should it
  /// run after all, must not touch the installation. The app went on, the user may retry, another script may be
  /// waiting for the same exit, and the app may close for good much later.
  static String cancelledMarkerName(String nonce) => '$startedMarkerName.$nonce.cancelled';

  /// Copy the log of the last update attempt into the app's log, once: a report of an update that did not apply then
  /// carries what the script did (GitHub #172). Nothing happens when no attempt was made since the last report.
  Future<void> reportLastAttempt() async {
    try {
      final updates = await directory();
      final marker = File(p.join(updates, startedMarkerName));
      if (!marker.existsSync()) return;
      final log = File(p.join(updates, logName));
      final text = log.existsSync() ? (await log.readAsString()).trim() : '';
      talker.info('last update attempt, script log:\n${text.isEmpty ? '(empty)' : text}');
      await marker.delete();
    } on Exception catch (e) {
      talker.warning('failed to read the last update attempt: $e');
    }
  }

  /// Windows PowerShell by its full path: a PATH without System32 must not stop the update.
  static String get powershellPath {
    final root = Platform.environment['SystemRoot'] ?? Platform.environment['windir'] ?? r'C:\Windows';
    final full = p.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
    return File(full).existsSync() ? full : 'powershell.exe';
  }

  /// Not [ProcessStartMode.detached]: on Windows that is `DETACHED_PROCESS`, a process without any console, and
  /// PowerShell then exits at once without running the script (GitHub #172, reproduced). The normal mode starts it
  /// with `CREATE_NO_WINDOW`: a hidden console, nothing on screen, and a child that outlives the app like any process
  /// on Windows. Its pipes are drained so it never blocks on output; they break when the app exits, and the script
  /// writes nothing to them.
  static Future<void> _launchDetached(String executable, List<String> arguments) async {
    final process = await Process.start(executable, arguments);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
  }

  @override
  UpdateTarget get target => UpdateTarget.windows;

  @override
  List<UpdateAsset> get assets => const [UpdateAsset.windows];

  @override
  Future<String> directory() async =>
      _updateDirectory ?? p.join((await getApplicationSupportDirectory()).path, 'updates');

  @override
  Future<bool> canInstall() async => true;

  @override
  Future<bool> openPermissionSettings() async => false;

  File get _executableFile => File(_executable ?? Platform.resolvedExecutable);

  @override
  Future<UpdateDownloadFailure?> preflight() async => _check(_executableFile);

  static UpdateDownloadFailure? _check(File executable) {
    final installDir = executable.parent;
    // A debug run or an unknown layout is not a portable release folder: never copy files into it.
    if (p.basename(executable.path).toLowerCase() != executableName ||
        !File(p.join(installDir.path, 'flutter_windows.dll')).existsSync()) {
      return UpdateDownloadFailure.unsupported;
    }
    return _isWritable(installDir) ? null : UpdateDownloadFailure.installLocation;
  }

  @override
  Future<bool> install(DownloadedUpdate update) async {
    final executable = _executableFile;
    final installDir = executable.parent;
    // Checked again: the folder may have changed since the download started.
    if (_check(executable) case final failure?) throw UpdateDownloadException(failure);

    final updates = await directory();
    final marker = File(p.join(updates, startedMarkerName));
    final nonce = _nonce();
    final staging = Directory(p.join(updates, 'staging-${update.versionCode}'));
    // A new backup folder every time: one kept after an incomplete rollback is never overwritten.
    final backup = p.join(updates, 'backup-${update.versionCode}-${DateTime.now().millisecondsSinceEpoch}');
    final script = File(p.join(updates, scriptName));
    final log = File(p.join(updates, logName));
    final powershell = powershellPath;
    talker.info('windows update: install ${update.versionCode} from $updates into ${installDir.path}');
    try {
      if (staging.existsSync()) await staging.delete(recursive: true);
      await extractRelease(File(update.path), staging);
      await script.writeAsString(updateScript, flush: true);
      // A marker left by an earlier attempt must not pass for this one.
      if (marker.existsSync()) await marker.delete();
      talker.debug('windows update: release unpacked, starting $powershell');
      await _launch(powershell, [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        '-ProcessId',
        '$pid',
        '-Source',
        staging.path,
        '-Target',
        installDir.path,
        '-Backup',
        backup,
        '-Log',
        log.path,
        '-Marker',
        marker.path,
        '-Nonce',
        nonce,
      ]);
    } on FileSystemException catch (e) {
      talker.error('windows update: file error before the script started: $e');
      throw const UpdateDownloadException(UpdateDownloadFailure.storage);
    } on ProcessException catch (e) {
      talker.error('windows update: PowerShell could not be started: $e');
      throw const UpdateDownloadException(UpdateDownloadFailure.install);
    }
    // Started is not running: the app stays open unless the script reports in.
    if (!await _waitForStart(marker, nonce)) {
      // A script that starts late must stand down: the app is not exiting for it.
      try {
        await File(p.join(updates, cancelledMarkerName(nonce))).writeAsString(nonce, flush: true);
      } on FileSystemException catch (e) {
        talker.warning('windows update: could not write the cancel marker: $e');
      }
      // What is left tells why (GitHub #172): an antivirus removes the script, a policy stops PowerShell before the
      // first line, a slow start writes the marker later.
      String read(File f) {
        try {
          return f.existsSync() ? '"${f.readAsStringSync().trim()}"' : 'missing';
        } on FileSystemException catch (e) {
          return 'unreadable ($e)';
        }
      }

      talker.error(
        'windows update: the script did not report in within ${_startTimeout.inSeconds}s; '
        'script ${script.existsSync() ? 'present' : 'missing'}, marker ${read(marker)}, log ${read(log)}',
      );
      throw const UpdateDownloadException(UpdateDownloadFailure.install);
    }
    talker.info('windows update: the script runs, exiting');
    // Leave a moment for the page to show that the app restarts, then exit so the script can replace the files.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 800), _quit));
    return true;
  }

  Future<bool> _waitForStart(File marker, String nonce) async {
    final deadline = DateTime.now().add(_startTimeout);
    while (true) {
      try {
        if (marker.existsSync() && (await marker.readAsString()).trim() == nonce) return true;
      } on FileSystemException {
        // Still being written by the script: read again.
      }
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  static String _nonce() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static bool _isWritable(Directory dir) {
    final probe = File(p.join(dir.path, '.tsdm_update_probe'));
    try {
      probe
        ..writeAsStringSync('')
        ..deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Unpack the `tsdm_client` folder of the release [zip] into [destination].
  ///
  /// Every entry must sit under that folder with a plain relative path, and the result must hold the executable and
  /// the engine; otherwise nothing is installed.
  static Future<void> extractRelease(File zip, Directory destination) async {
    final input = InputFileStream(zip.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      await destination.create(recursive: true);
      final root = p.canonicalize(destination.path);
      final written = <String>{};
      for (final entry in archive.files) {
        final name = entry.name;
        if (!name.startsWith('$releaseFolder/') || name.contains(r'\') || name.contains(':')) {
          throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
        }
        final segments = name.substring(releaseFolder.length + 1).split('/');
        if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
        if (segments.isEmpty) continue;
        if (segments.any((e) => e.isEmpty || e == '.' || e == '..')) {
          throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
        }
        final target = p.joinAll([root, ...segments]);
        if (!p.isWithin(root, target)) {
          throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
        }
        if (!entry.isFile) {
          await Directory(target).create(recursive: true);
          continue;
        }
        await Directory(p.dirname(target)).create(recursive: true);
        final output = OutputFileStream(target);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
        written.add(segments.join('/').toLowerCase());
      }
      if (!written.contains(executableName) || !written.contains('flutter_windows.dll')) {
        throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
      }
    } on ArchiveException {
      throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
    } finally {
      await input.close();
    }
  }

  /// The script run after the app exits. ASCII only: Windows PowerShell reads a script without BOM in the ANSI code
  /// page. Paths come in as arguments, so non-ASCII folders are fine.
  static const updateScript = r'''
param(
  [Parameter(Mandatory = $true)][int]$ProcessId,
  [Parameter(Mandatory = $true)][string]$Source,
  [Parameter(Mandatory = $true)][string]$Target,
  [Parameter(Mandatory = $true)][string]$Backup,
  [Parameter(Mandatory = $true)][string]$Log,
  [Parameter(Mandatory = $true)][string]$Marker,
  [Parameter(Mandatory = $true)][string]$Nonce
)
# First of all tell the app that the script runs; it only exits after reading this nonce.
Set-Content -LiteralPath $Marker -Value $Nonce -Encoding ASCII
$ErrorActionPreference = 'Stop'
# A log that cannot be written must not stop the update, nor the restart of the app.
function Write-Log([string]$Message) {
  try { Add-Content -LiteralPath $Log -Value ('{0} {1}' -f (Get-Date -Format o), $Message) -Encoding UTF8 } catch { }
}
# .NET file calls take paths as they are; the cmdlets' -Path and -Destination read [ ] as wildcards.
function Copy-WithRetry([string]$From, [string]$To) {
  $parent = Split-Path -Parent $To
  [System.IO.Directory]::CreateDirectory($parent) | Out-Null
  for ($i = 0; $i -lt 20; $i++) {
    try { [System.IO.File]::Copy($From, $To, $true); return } catch { Start-Sleep -Milliseconds 500 }
  }
  [System.IO.File]::Copy($From, $To, $true)
}
try { Set-Content -LiteralPath $Log -Value '' -Encoding UTF8 } catch { }
Write-Log ('started, waiting for the app (process {0}) to exit' -f $ProcessId)
$exited = $false
try {
  # The app exits on its own right after this script reported in; the long wait covers an exit held up by the system
  # or done by hand, still applying the update instead of leaving the old version.
  $app = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if ($app -and -not $app.WaitForExit(600000)) { throw 'the app did not exit' }
  $exited = $true
  Write-Log 'the app exited'
  # The app gave up on this attempt (this script reported in too late): it closed for some other reason, maybe much
  # later, and another script may be about to apply a newer attempt. Nothing is touched, nothing is started.
  if (Test-Path -LiteralPath ($Marker + '.' + $Nonce + '.cancelled')) { Write-Log 'the app gave up on this attempt, nothing changed'; exit }
  Start-Sleep -Milliseconds 500
  $files = @(Get-ChildItem -LiteralPath $Source -Recurse -File | ForEach-Object {
    $_.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')
  })
  if ($files.Count -eq 0) { throw 'nothing to install' }
  # A folder where the release has a file would take the file inside it: stop before anything changes.
  foreach ($file in $files) {
    if (Test-Path -LiteralPath (Join-Path $Target $file) -PathType Container) { throw ('a folder is in the way: {0}' -f $file) }
  }
  $replaced = @()
  foreach ($file in $files) {
    $old = Join-Path $Target $file
    if (Test-Path -LiteralPath $old -PathType Leaf) {
      Copy-WithRetry $old (Join-Path $Backup $file)
      $replaced += $file
    }
  }
  Write-Log ('backed up {0} files' -f $replaced.Count)
  $added = @()
  $attempted = @()
  try {
    foreach ($file in $files) {
      $new = Join-Path $Target $file
      if (-not (Test-Path -LiteralPath $new)) { $added += $file }
      # Recorded before copying: a copy that fails half way may have damaged the old file.
      $attempted += $file
      Copy-WithRetry (Join-Path $Source $file) $new
    }
    Write-Log ('installed {0} files' -f $files.Count)
  } catch {
    Write-Log ('install failed: {0}' -f $_)
    $failed = 0
    foreach ($file in ($replaced | Where-Object { $attempted -contains $_ })) {
      $old = Join-Path $Target $file
      $saved = Join-Path $Backup $file
      try { Copy-WithRetry $saved $old } catch {
        # Still locked but never changed: nothing to restore.
        $same = $false
        try { $same = (Get-FileHash -LiteralPath $old).Hash -eq (Get-FileHash -LiteralPath $saved).Hash } catch { }
        if (-not $same) { $failed++; Write-Log ('not restored: {0}' -f $file) }
      }
    }
    foreach ($file in $added) { Remove-Item -LiteralPath (Join-Path $Target $file) -Force -ErrorAction SilentlyContinue }
    if ($failed -eq 0) {
      Write-Log 'restored the previous version'
    } else {
      # The app cleans backup folders at its next version check; this marker keeps this one. A new file is written
      # even when a file in the folder is still locked, unlike renaming the folder.
      Set-Content -LiteralPath ($Backup + '.incomplete') -Value $Backup -Encoding UTF8
      Write-Log ('restore incomplete, the previous files are in {0}' -f $Backup)
    }
  }
} catch {
  Write-Log ('failed: {0}' -f $_)
}
if ($exited) {
  $start = New-Object System.Diagnostics.ProcessStartInfo
  $start.FileName = Join-Path $Target 'tsdm_client.exe'
  $start.WorkingDirectory = $Target
  $start.UseShellExecute = $true
  [System.Diagnostics.Process]::Start($start) | Out-Null
} else {
  # The app is still open: starting it again would run two instances on the same data.
  Write-Log 'the app is still running, not starting another instance'
}
''';
}
