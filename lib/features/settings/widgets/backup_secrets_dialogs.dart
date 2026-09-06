import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// Shortest password accepted for a backup.
const backupPasswordMinLength = 8;

/// What the user chose in [showExportBackupDialog].
final class ExportBackupChoice {
  /// Constructor.
  const ExportBackupChoice({this.password});

  /// Password protecting the account logins carried in the backup; null exports without them.
  final String? password;
}

/// Ask whether to carry the account logins in the backup and, if so, for the password protecting them.
///
/// Returns null when the user cancels.
Future<ExportBackupChoice?> showExportBackupDialog(BuildContext context) =>
    showDialog<ExportBackupChoice>(context: context, builder: (_) => const _ExportBackupDialog());

/// Ask for the password of a backup carrying account logins; null means the user chose to import without them.
Future<String?> showUnlockBackupDialog(BuildContext context, {bool wrongPassword = false}) =>
    showDialog<String>(context: context, builder: (_) => _UnlockBackupDialog(wrongPassword: wrongPassword));

class _ExportBackupDialog extends StatefulWidget {
  const _ExportBackupDialog();

  @override
  State<_ExportBackupDialog> createState() => _ExportBackupDialogState();
}

class _ExportBackupDialogState extends State<_ExportBackupDialog> {
  final formKey = GlobalKey<FormState>();
  final password = TextEditingController();
  final confirm = TextEditingController();
  bool includeAccounts = false;
  bool obscure = true;

  @override
  void dispose() {
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  void _submit() {
    if (!includeAccounts) {
      Navigator.of(context).pop(const ExportBackupChoice());
      return;
    }
    if (formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(ExportBackupChoice(password: password.text));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.advancedSection.exportBackup;
    final toggle = IconButton(
      icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
      onPressed: () => setState(() => obscure = !obscure),
    );
    return AlertDialog(
      title: Text(tr.title),
      content: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr.includeAccounts),
              subtitle: Text(tr.includeAccountsDetail),
              value: includeAccounts,
              onChanged: (v) => setState(() => includeAccounts = v),
            ),
            if (includeAccounts) ...[
              sizedBoxW4H4,
              TextFormField(
                controller: password,
                obscureText: obscure,
                autofocus: true,
                decoration: InputDecoration(labelText: tr.password, suffixIcon: toggle),
                validator: (v) =>
                    (v == null || v.length < backupPasswordMinLength) ? tr.passwordTooShort(min: backupPasswordMinLength) : null,
              ),
              sizedBoxW4H4,
              TextFormField(
                controller: confirm,
                obscureText: obscure,
                decoration: InputDecoration(labelText: tr.confirmPassword),
                validator: (v) => v != password.text ? tr.passwordMismatch : null,
                onFieldSubmitted: (_) => _submit(),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton(onPressed: _submit, child: Text(tr.export)),
      ],
    );
  }
}

class _UnlockBackupDialog extends StatefulWidget {
  const _UnlockBackupDialog({required this.wrongPassword});

  final bool wrongPassword;

  @override
  State<_UnlockBackupDialog> createState() => _UnlockBackupDialogState();
}

class _UnlockBackupDialogState extends State<_UnlockBackupDialog> {
  final password = TextEditingController();
  bool obscure = true;

  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  void _submit() {
    if (password.text.isNotEmpty) {
      Navigator.of(context).pop(password.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.advancedSection.importData.unlock;
    return AlertDialog(
      title: Text(tr.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr.tip),
          sizedBoxW4H4,
          TextField(
            controller: password,
            obscureText: obscure,
            autofocus: true,
            decoration: InputDecoration(
              labelText: tr.password,
              errorText: widget.wrongPassword ? tr.wrongPassword : null,
              suffixIcon: IconButton(
                icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => obscure = !obscure),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr.skip)),
        FilledButton(onPressed: _submit, child: Text(tr.restore)),
      ],
    );
  }
}
