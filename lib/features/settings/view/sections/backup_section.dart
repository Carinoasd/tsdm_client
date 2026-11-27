part of '../settings_page.dart';

/// Export and import of the app data; the texts about what the backup holds are kept as they are.
class _BackupSection extends StatelessWidget {
  const _BackupSection();

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.advancedSection;
    return AppTileGroup(
      title: tr.backupTitle,
      icon: Icons.backup_outlined,
      children: [
        SectionListTile(
          key: const ValueKey('settings-export-data'),
          leading: const Icon(Icons.download_outlined),
          title: Text(tr.exportData),
          subtitle: Text(tr.exportDataDetail),
          onTap: () async {
            final choice = await showExportBackupDialog(context);
            if (choice == null || !context.mounted) return;
            try {
              final data = await const BackupRepository().exportSanitized(
                await databaseFile,
                secretsPassword: choice.password,
              );
              final stamp = DateTime.now().microsecondsSinceEpoch;
              final name = choice.password == null
                  ? 'tsdm_client_data_$stamp.db'
                  : 'tsdm_client_data_${stamp}_accounts.db';
              if (isDesktop) {
                final filePath = await FilePicker.platform.saveFile(dialogTitle: tr.exportData, fileName: name);
                if (filePath == null) return;
                await File(filePath).writeAsBytes(data, flush: true);
              } else {
                await FilePicker.platform.saveFile(dialogTitle: tr.exportData, fileName: name, bytes: data);
              }
            } on Object catch (e, st) {
              // The copy failed (the database busy for too long, no space left…): say so, the data stays as it was.
              talker.handle(e, st, 'failed to export the backup');
              if (context.mounted) {
                showSnackBar(context: context, message: tr.exportDataFailed);
              }
            }
          },
        ),
        SectionListTile(
          key: const ValueKey('settings-import-data'),
          leading: const Icon(Icons.upload_outlined),
          title: Text(tr.importData.title),
          onTap: () async {
            final ok = await showQuestionDialog(
              context: context,
              title: tr.importData.title,
              message: tr.importData.tip,
            );
            if (ok != true || !context.mounted) return;
            final files = await FilePicker.platform.pickFiles(dialogTitle: tr.importData.title);
            if (files == null || !context.mounted) return;
            final file = files.files.firstOrNull;
            if (file == null || file.path == null) {
              showSnackBar(context: context, message: tr.importData.invalidData);
              return;
            }
            await _importBackup(context, File(file.path!));
          },
        ),
      ],
    );
  }
}

Future<void> _importBackup(BuildContext context, File source) async {
  final tr = context.t.settingsPage.advancedSection.importData;
  const repository = BackupRepository();
  final schemaVersion = getIt.get<AppDatabase>().schemaVersion;
  final check = await repository.validate(source, currentSchemaVersion: schemaVersion);
  if (!context.mounted) return;
  if (!check.ok) {
    await showMessageSingleButtonDialog(
      context: context,
      title: tr.title,
      message: tr.invalidDetail(reason: _backupProblemText(context, check)),
    );
    return;
  }
  BackupSecretsPayload? secrets;
  if (await repository.containsSecrets(source)) {
    if (!context.mounted) return;
    secrets = await _unlockSecrets(context, repository, source);
  }
  if (!context.mounted) return;
  final ok = await showQuestionDialog(context: context, title: tr.title, message: tr.tip);
  if (ok != true || !context.mounted) return;
  BackupValidation? invalid;
  BackupReplaceException? replaceFailure;
  try {
    // No automatic WebDAV backup may copy the database while it is replaced.
    if (getIt.isRegistered<WebdavBackupRepository>()) {
      await getIt.get<WebdavBackupRepository>().suspend();
    }
    await getIt.get<StorageProvider>().dispose();
    await repository.replaceDatabase(
      target: await databaseFile,
      source: source,
      currentSchemaVersion: schemaVersion,
      secrets: secrets,
    );
  } on BackupInvalidException catch (e) {
    invalid = e.validation;
  } on BackupReplaceException catch (e) {
    replaceFailure = e;
  }
  if (context.mounted) {
    final String message;
    if (invalid != null) {
      message = tr.invalidDetail(reason: _backupProblemText(context, invalid));
    } else if (replaceFailure != null) {
      message = replaceFailure.restored ? tr.restored : tr.replaceFailed;
    } else {
      message = secrets == null ? tr.success : tr.successWithAccounts;
    }
    await showMessageSingleButtonDialog(context: context, title: tr.title, message: message);
  }
  await exitApp();
}

Future<BackupSecretsPayload?> _unlockSecrets(BuildContext context, BackupRepository repository, File source) async {
  final tr = context.t.settingsPage.advancedSection.importData.unlock;
  var wrongPassword = false;
  while (true) {
    if (!context.mounted) return null;
    final password = await showUnlockBackupDialog(context, wrongPassword: wrongPassword);
    if (password == null) return null;
    try {
      return await repository.unlockSecrets(source, password: password);
    } on BackupSecretsPasswordException catch (e) {
      if (e.unsupported) {
        if (context.mounted) showSnackBar(context: context, message: tr.unsupported);
        return null;
      }
      wrongPassword = true;
    }
  }
}

String _backupProblemText(BuildContext context, BackupValidation check) {
  final tr = context.t.settingsPage.advancedSection.importData;
  return switch (check.problem) {
    BackupProblem.unreadable => tr.problem.unreadable,
    BackupProblem.notSqlite => tr.problem.notSqlite,
    BackupProblem.corrupted || BackupProblem.unexpectedObjects => tr.problem.corrupted,
    BackupProblem.missingTables => tr.problem.missingTables,
    BackupProblem.invalidVersion => tr.problem.invalidVersion,
    BackupProblem.newerSchema => tr.problem.newerSchema(version: check.detail ?? ''),
    null => '',
  };
}
