import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/settings/repositories/webdav_backup_repository.dart';
import 'package:tsdm_client/features/settings/repositories/webdav_client.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Edit the WebDAV backup settings; true when they were saved.
Future<bool?> showWebdavSettingsDialog(
  BuildContext context, {
  required WebdavBackupRepository repository,
  required WebdavBackupConfig config,
  required String password,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _WebdavSettingsDialog(repository: repository, config: config, password: password),
);

/// Pick one of [backups] (newest first) to restore.
Future<WebdavBackupFile?> showWebdavRestorePicker(BuildContext context, List<WebdavBackupFile> backups) =>
    showDialog<WebdavBackupFile>(
      context: context,
      builder: (context) {
        final tr = context.t.settingsPage.advancedSection.webdav;
        return CustomAlertDialog.sync(
          title: AppDialogTitle(icon: Icons.cloud_download_outlined, title: tr.restore),
          contentPadding: edgeInsetsT8,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final backup in backups)
                ListTile(
                  leading: Icon(backup.withAccounts ? Icons.manage_accounts_outlined : Icons.description_outlined),
                  title: Text(backup.createdAt.yyyyMMDDHHMMSS()),
                  trailing: backup.size == null ? null : Text(_formatSize(backup.size!)),
                  onTap: () => Navigator.of(context).pop(backup),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
          ],
        );
      },
    );

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

class _WebdavSettingsDialog extends StatefulWidget {
  const _WebdavSettingsDialog({required this.repository, required this.config, required this.password});

  final WebdavBackupRepository repository;
  final WebdavBackupConfig config;
  final String password;

  @override
  State<_WebdavSettingsDialog> createState() => _WebdavSettingsDialogState();
}

class _WebdavSettingsDialogState extends State<_WebdavSettingsDialog> {
  final formKey = GlobalKey<FormState>();
  late final url = TextEditingController(text: widget.config.url);
  late final username = TextEditingController(text: widget.config.username);
  late final password = TextEditingController(text: widget.password);
  late final directory = TextEditingController(text: widget.config.directory);
  late final keep = TextEditingController(text: '${widget.config.keep}');
  late WebdavAutoBackup schedule = widget.config.schedule;
  bool obscure = true;

  /// Null before the first test.
  WebdavCheck? check;
  bool testing = false;
  bool saving = false;

  @override
  void dispose() {
    url.dispose();
    username.dispose();
    password.dispose();
    directory.dispose();
    keep.dispose();
    super.dispose();
  }

  WebdavBackupConfig get _config => widget.config.copyWith(
    url: url.text.trim(),
    username: username.text.trim(),
    directory: directory.text.trim(),
    schedule: schedule,
    keep: int.tryParse(keep.text.trim()),
  );

  Future<void> _test() async {
    if (!formKey.currentState!.validate()) return;
    setState(() => testing = true);
    final result = await widget.repository.testConnection(_config, password.text);
    if (!mounted) return;
    setState(() {
      testing = false;
      check = result;
    });
  }

  Future<void> _save() async {
    if (!formKey.currentState!.validate()) return;
    setState(() => saving = true);
    final store = widget.repository.store;
    try {
      await store.writeConfig(_config);
      await store.writePassword(password.text);
    } on Object catch (e, st) {
      talker.handle(e, st, 'webdav: saving the settings failed');
      if (!mounted) return;
      setState(() => saving = false);
      showSnackBar(context: context, message: context.t.settingsPage.advancedSection.webdav.saveFailed);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.advancedSection.webdav;
    final colorScheme = Theme.of(context).colorScheme;
    final plainHttp = Uri.tryParse(url.text.trim())?.isScheme('http') ?? false;
    final (IconData icon, Color color, String label) = switch (check) {
      null => (Icons.help_outline, colorScheme.outline, tr.test.idle),
      WebdavCheck.ok => (Icons.check_circle_outline, colorScheme.primary, tr.test.ok),
      WebdavCheck.unauthorized => (Icons.error_outline, colorScheme.error, tr.test.unauthorized),
      WebdavCheck.notFound => (Icons.error_outline, colorScheme.error, tr.test.notFound),
      WebdavCheck.unreachable => (Icons.error_outline, colorScheme.error, tr.test.unreachable),
      WebdavCheck.failed => (Icons.error_outline, colorScheme.error, tr.test.failed),
    };
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.cloud_outlined, title: tr.title),
      content: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            sizedBoxW4H4,
            TextFormField(
              controller: url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: appFieldDecoration(
                label: tr.url,
                icon: Icons.link_outlined,
                // Basic authentication over plain http sends the password readable to anyone on the way.
                suffix: plainHttp ? Icon(Icons.no_encryption_outlined, color: colorScheme.error) : null,
              ),
              onChanged: (_) => setState(() {}),
              validator: (v) => WebdavBackupConfig(url: v ?? '').configured ? null : tr.invalidUrl,
            ),
            sizedBoxW12H12,
            TextFormField(
              controller: username,
              autocorrect: false,
              decoration: appFieldDecoration(label: tr.username, icon: Icons.person_outline),
            ),
            sizedBoxW12H12,
            TextFormField(
              controller: password,
              obscureText: obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: appFieldDecoration(
                label: tr.password,
                icon: Icons.password_outlined,
                suffix: IconButton(
                  icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => obscure = !obscure),
                ),
              ),
            ),
            sizedBoxW12H12,
            TextFormField(
              controller: directory,
              autocorrect: false,
              decoration: appFieldDecoration(label: tr.directory, icon: Icons.folder_outlined),
            ),
            sizedBoxW12H12,
            AppInsetBlock(
              outlined: true,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (testing)
                    const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Icon(icon, size: 20, color: color),
                  OutlinedButton.icon(
                    label: Text(testing ? tr.test.testing : label),
                    icon: const Icon(Icons.refresh_outlined),
                    onPressed: testing ? null : _test,
                  ),
                ],
              ),
            ),
            sizedBoxW16H16,
            Text(tr.autoBackup, style: Theme.of(context).textTheme.labelLarge),
            sizedBoxW8H8,
            SegmentedButton<WebdavAutoBackup>(
              segments: [
                ButtonSegment(value: WebdavAutoBackup.off, label: Text(tr.schedule.off)),
                ButtonSegment(value: WebdavAutoBackup.daily, label: Text(tr.schedule.daily)),
                ButtonSegment(value: WebdavAutoBackup.weekly, label: Text(tr.schedule.weekly)),
              ],
              selected: {schedule},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => schedule = v.first),
            ),
            sizedBoxW16H16,
            TextFormField(
              controller: keep,
              keyboardType: TextInputType.number,
              decoration: appFieldDecoration(label: tr.keep, icon: Icons.layers_outlined),
              validator: (v) {
                final n = int.tryParse(v?.trim() ?? '');
                return n == null || n < 1 || n > WebdavBackupConfig.maxKeep
                    ? tr.invalidKeep(max: WebdavBackupConfig.maxKeep)
                    : null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: saving ? null : () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton(onPressed: saving ? null : _save, child: Text(context.t.general.ok)),
      ],
    );
  }
}
