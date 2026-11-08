import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/settings/repositories/webdav_backup_repository.dart';
import 'package:tsdm_client/features/settings/repositories/webdav_client.dart';
import 'package:tsdm_client/features/settings/widgets/backup_secrets_dialogs.dart';
import 'package:tsdm_client/features/settings/widgets/webdav_backup_dialogs.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';

/// The WebDAV rows of the settings: the server, "back up now" and "restore from WebDAV".
///
/// [importBackup] is the import of a local backup file of the settings page; a backup downloaded from WebDAV goes
/// through it unchanged (validation, the password of the account logins, the confirmation and the restart).
class WebdavBackupGroup extends StatefulWidget {
  /// Constructor.
  const WebdavBackupGroup({required this.importBackup, required this.repository, super.key});

  /// Import a downloaded backup file.
  final Future<void> Function(File file) importBackup;

  /// The repository.
  final WebdavBackupRepository repository;

  @override
  State<WebdavBackupGroup> createState() => _WebdavBackupGroupState();
}

class _WebdavBackupGroupState extends State<WebdavBackupGroup> {
  WebdavBackupRepository get repository => widget.repository;

  WebdavBackupConfig? config;
  WebdavBackupState? backupState;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final c = await repository.store.readConfig();
    final s = await repository.store.readState();
    if (!mounted) return;
    setState(() {
      config = c;
      backupState = s;
    });
  }

  Future<void> _edit() async {
    final current = config ?? await repository.store.readConfig();
    final password = await repository.store.readPassword();
    if (!mounted) return;
    final saved = await showWebdavSettingsDialog(context, repository: repository, config: current, password: password);
    if (saved ?? false) await _reload();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _backupNow() => _run(() async {
    final tr = context.t.settingsPage.advancedSection.webdav;
    final choice = await showExportBackupDialog(context);
    if (choice == null || !mounted) return;
    try {
      await repository.backupNow(secretsPassword: choice.password);
      if (mounted) showSnackBar(context: context, message: tr.backupDone);
    } on Object catch (e, st) {
      talker.handle(e, st, 'webdav: backup failed');
      if (mounted) {
        final unauthorized = e is WebdavException && e.unauthorized;
        showSnackBar(context: context, message: unauthorized ? tr.backupUnauthorized : tr.backupFailed);
      }
    }
    await _reload();
  });

  Future<void> _restore() => _run(() async {
    final tr = context.t.settingsPage.advancedSection.webdav;
    final List<WebdavBackupFile> backups;
    try {
      backups = await repository.listBackups();
    } on Object catch (e, st) {
      talker.handle(e, st, 'webdav: listing backups failed');
      if (mounted) showSnackBar(context: context, message: tr.listFailed);
      return;
    }
    if (!mounted) return;
    if (backups.isEmpty) {
      showSnackBar(context: context, message: tr.restoreEmpty);
      return;
    }
    final picked = await showWebdavRestorePicker(context, backups);
    if (picked == null || !mounted) return;
    final File file;
    try {
      file = await repository.download(picked.name);
    } on Object catch (e, st) {
      talker.handle(e, st, 'webdav: download failed');
      if (mounted) showSnackBar(context: context, message: tr.downloadFailed);
      return;
    }
    try {
      if (mounted) await widget.importBackup(file);
    } finally {
      if (file.existsSync()) await file.delete();
    }
  });

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.advancedSection.webdav;
    final config = this.config;
    final configured = config?.configured ?? false;
    final last = backupState?.lastBackupAt;
    return AppTileGroup(
      title: tr.title,
      icon: Icons.cloud_outlined,
      children: [
        SectionListTile(
          leading: const Icon(Icons.dns_outlined),
          title: Text(tr.url),
          subtitle: configured ? Text(config!.baseUri!.host) : null,
          trailing: configured && config!.schedule != WebdavAutoBackup.off
              ? Text(switch (config.schedule) {
                  WebdavAutoBackup.daily => tr.schedule.daily,
                  WebdavAutoBackup.weekly => tr.schedule.weekly,
                  WebdavAutoBackup.off => tr.schedule.off,
                })
              : null,
          onTap: busy ? null : _edit,
        ),
        if (configured) ...[
          SectionListTile(
            leading: busy
                ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cloud_upload_outlined),
            title: Text(tr.backupNow),
            subtitle: last == null ? null : Text(tr.lastBackup(time: last.yyyyMMDDHHMM())),
            onTap: busy ? null : _backupNow,
          ),
          SectionListTile(
            leading: const Icon(Icons.cloud_download_outlined),
            title: Text(tr.restore),
            onTap: busy ? null : _restore,
          ),
        ],
      ],
    );
  }
}
