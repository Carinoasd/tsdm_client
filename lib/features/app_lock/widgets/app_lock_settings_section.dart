import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/features/app_lock/models/app_lock_config.dart';
import 'package:tsdm_client/features/app_lock/repository/pin_hasher.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';
import 'package:tsdm_client/widgets/selectable_list_tile.dart';

/// The words for [method].
String appLockMethodLabel(BuildContext context, AppLockMethod method) {
  final tr = context.t.appLock.method;
  return switch (method) {
    AppLockMethod.off => tr.off,
    AppLockMethod.pin => tr.pin,
    AppLockMethod.biometric => tr.biometric,
  };
}

/// The words for [timing].
String appLockTimingLabel(BuildContext context, AppLockTiming timing) {
  final tr = context.t.appLock.timing;
  return switch (timing) {
    AppLockTiming.immediately => tr.immediately,
    AppLockTiming.oneMinute => tr.oneMinute,
    AppLockTiming.fiveMinutes => tr.fiveMinutes,
  };
}

/// The app lock group of the settings page.
///
/// Turning the lock off, changing the way to unlock or the PIN, a longer time before locking and switching accounts
/// without unlocking first ask for the PIN (or the system unlock).
class AppLockSettingsSection extends StatelessWidget {
  /// Constructor; [cubit] is the app's one by default.
  const AppLockSettingsSection({this.cubit, super.key});

  /// The app lock.
  final AppLockCubit? cubit;

  @override
  Widget build(BuildContext context) {
    final lock = cubit ?? getIt.get<AppLockCubit>();
    final tr = context.t.appLock;
    return BlocBuilder<AppLockCubit, AppLockState>(
      bloc: lock,
      buildWhen: (prev, curr) => prev.config != curr.config || prev.biometricAvailable != curr.biometricAvailable,
      builder: (context, state) {
        final config = state.config;
        return AppTileGroup(
          title: tr.title,
          icon: Icons.lock_outline,
          children: [
            SectionListTile(
              key: const ValueKey('settings-app-lock-method'),
              leading: const Icon(Icons.lock_outline),
              title: Text(tr.method.title),
              subtitle: Text(appLockMethodLabel(context, config.enabled ? config.method : AppLockMethod.off)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async => _changeMethod(context, lock),
            ),
            if (config.enabled) ...[
              SectionListTile(
                key: const ValueKey('settings-app-lock-timing'),
                leading: const Icon(Icons.timer_outlined),
                title: Text(tr.timing.title),
                subtitle: Text(appLockTimingLabel(context, config.timing)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final timing = await _choose<AppLockTiming>(
                    context,
                    icon: Icons.timer_outlined,
                    title: tr.timing.title,
                    values: AppLockTiming.values,
                    current: config.timing,
                    label: (v) => appLockTimingLabel(context, v),
                  );
                  if (timing == null || timing == config.timing) {
                    return;
                  }
                  // A longer time away loosens the lock: only after unlocking.
                  if (timing.delay > config.timing.delay && !await lock.requestVerification(always: true)) {
                    return;
                  }
                  await lock.setTiming(timing);
                },
              ),
              SectionListTile(
                key: const ValueKey('settings-app-lock-change-pin'),
                leading: const Icon(Icons.pin_outlined),
                title: Text(tr.changePin),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  if (!await lock.requestVerification(always: true) || !context.mounted) {
                    return;
                  }
                  final pin = await showSetAppLockPinDialog(context);
                  if (pin != null) {
                    await lock.setPin(pin);
                  }
                },
              ),
              SectionSwitchListTile(
                key: const ValueKey('settings-app-lock-account-switch'),
                secondary: const Icon(Icons.switch_account_outlined),
                title: Text(tr.requireForAccountSwitch),
                value: config.requireForAccountSwitch,
                onChanged: (v) async {
                  // Turning it off loosens the lock: only after unlocking.
                  if (!v && !await lock.requestVerification(always: true)) {
                    return;
                  }
                  await lock.setRequireForAccountSwitch(value: v);
                },
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _changeMethod(BuildContext context, AppLockCubit lock) async {
    final config = lock.state.config;
    final current = config.enabled ? config.method : AppLockMethod.off;
    final biometric = await lock.biometricAvailable();
    if (!context.mounted) {
      return;
    }
    final method = await _choose<AppLockMethod>(
      context,
      icon: Icons.lock_outline,
      title: context.t.appLock.method.title,
      values: [
        AppLockMethod.off,
        AppLockMethod.pin,
        if (biometric || current == AppLockMethod.biometric) AppLockMethod.biometric,
      ],
      current: current,
      label: (v) => appLockMethodLabel(context, v),
    );
    if (method == null || method == current || !context.mounted) {
      return;
    }
    if (!config.enabled) {
      // Turning it on: a PIN first, the way in when the system unlock fails.
      final pin = await showSetAppLockPinDialog(context);
      if (pin == null) {
        return;
      }
      await lock.setPin(pin, method: method);
      return;
    }
    if (!await lock.requestVerification(always: true)) {
      return;
    }
    if (method == AppLockMethod.off) {
      await lock.disable();
      return;
    }
    if (method == AppLockMethod.biometric && !await lock.biometricAvailable()) {
      if (context.mounted) {
        showSnackBar(context: context, message: context.t.appLock.biometricUnavailable);
      }
      return;
    }
    await lock.setMethod(method);
  }
}

Future<T?> _choose<T>(
  BuildContext context, {
  required IconData icon,
  required String title,
  required List<T> values,
  required T current,
  required String Function(T) label,
}) => showDialog<T>(
  context: context,
  builder: (context) => CustomAlertDialog.sync(
    title: AppDialogTitle(icon: icon, title: title),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final value in values)
          SelectableListTile(
            key: ValueKey('app-lock-choice-$value'),
            title: Text(label(value)),
            selected: value == current,
            onTap: () => Navigator.of(context).pop(value),
          ),
      ],
    ),
    contentPadding: const EdgeInsets.symmetric(vertical: 8),
  ),
);

/// Ask for a new PIN, twice; null when cancelled.
Future<String?> showSetAppLockPinDialog(BuildContext context) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => const _SetPinDialog(),
);

class _SetPinDialog extends StatefulWidget {
  const _SetPinDialog();

  @override
  State<_SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends State<_SetPinDialog> {
  final _formKey = GlobalKey<FormState>();
  final _pin = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_pin.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.appLock.setPin;
    InputDecoration decoration(String label) => appFieldDecoration(label: label, icon: Icons.pin_outlined);
    final formatters = [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(appLockPinMaxLength),
    ];
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.pin_outlined, title: tr.title),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const ValueKey('app-lock-new-pin'),
              controller: _pin,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: formatters,
              decoration: decoration(tr.pin),
              textInputAction: TextInputAction.next,
              validator: (v) => isValidAppLockPin(v ?? '') ? null : tr.invalid,
            ),
            sizedBoxW12H12,
            TextFormField(
              key: const ValueKey('app-lock-confirm-pin'),
              controller: _confirm,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: formatters,
              decoration: decoration(tr.confirm),
              onFieldSubmitted: (_) => _submit(),
              validator: (v) => v == _pin.text ? null : tr.mismatch,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton(
          key: const ValueKey('app-lock-save-pin'),
          onPressed: _submit,
          child: Text(context.t.general.ok),
        ),
      ],
    );
  }
}
