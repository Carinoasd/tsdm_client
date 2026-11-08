import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/features/app_lock/repository/forget_accounts.dart';
import 'package:tsdm_client/features/app_lock/repository/pin_hasher.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/show_dialog.dart';

/// Removes every account for "forgot PIN"; replaceable in tests.
typedef ForgetAccounts = Future<bool> Function(BuildContext context);

Future<bool> _forgetAccounts(BuildContext context) => forgetAllAccounts(
  authenticationRepository: context.repo<AuthenticationRepository>(),
  storageProvider: getIt.get<StorageProvider>(),
);

/// The lock screen: a PIN pad, the system unlock when it is on, and "forgot PIN".
///
/// Covers the whole app while [AppLockState.covering]. Digits can also be typed on a keyboard (Enter checks the PIN,
/// Backspace removes the last digit).
class AppLockScreen extends StatefulWidget {
  /// Constructor.
  const AppLockScreen({required this.cubit, this.forgetAccounts = _forgetAccounts, super.key});

  /// The app lock.
  final AppLockCubit cubit;

  /// Removes every account for "forgot PIN".
  final ForgetAccounts forgetAccounts;

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final _focus = FocusNode(debugLabel: 'app lock');
  late final AppLifecycleListener _lifecycle;
  String _pin = '';
  Timer? _ticker;
  bool _forgetting = false;
  bool _forgetFailed = false;

  /// The system unlock is asked by itself once each time the app comes back: the prompt makes the app inactive and
  /// resumed again, which must not ask again after the user closed it (the fingerprint button still does).
  bool _autoPromptArmed = true;

  AppLockCubit get _cubit => widget.cubit;

  @override
  void initState() {
    super.initState();
    // onShow is hidden to inactive, a real return; the prompt only moves between inactive and resumed.
    _lifecycle = AppLifecycleListener(onShow: () => _autoPromptArmed = true, onResume: _autoPrompt);
    _syncTicker();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _autoPrompt();
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _lifecycle.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _autoPrompt() {
    if (!_autoPromptArmed) {
      return;
    }
    _autoPromptArmed = false;
    _promptBiometric();
  }

  void _promptBiometric() {
    if (!mounted || !_cubit.state.covering || !_cubit.state.offersBiometric) {
      return;
    }
    unawaited(_cubit.unlockWithBiometric(context.t.appLock.lockScreen.reason(appName: context.t.appName)));
  }

  /// Refresh every second while the PIN pad waits after too many wrong PINs.
  void _syncTicker() {
    if (_cubit.lockedOutUntil == null) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() {});
      if (_cubit.lockedOutUntil == null) {
        _ticker?.cancel();
        _ticker = null;
      }
    });
  }

  void _add(String digit) {
    if (_pin.length >= appLockPinMaxLength || _cubit.state.checking || _cubit.lockedOutUntil != null) {
      return;
    }
    setState(() => _pin += digit);
    if (_pin.length == appLockPinMaxLength) {
      unawaited(_submit());
    }
  }

  void _backspace() {
    if (_pin.isEmpty) {
      return;
    }
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_pin.length < appLockPinMinLength) {
      return;
    }
    final pin = _pin;
    final ok = await _cubit.unlockWithPin(pin);
    if (!mounted) {
      return;
    }
    if (!ok) {
      setState(() => _pin = '');
      _syncTicker();
    }
  }

  Future<void> _forgot() async {
    final tr = context.t.appLock.forgot;
    final first = await showQuestionDialog(context: context, title: tr.title, message: tr.detail, dangerous: true);
    if (first != true || !mounted) {
      return;
    }
    final second = await showQuestionDialog(
      context: context,
      title: tr.confirmTitle,
      message: tr.confirmDetail,
      dangerous: true,
    );
    if (second != true || !mounted) {
      return;
    }
    setState(() {
      _forgetting = true;
      _forgetFailed = false;
    });
    final removed = await widget.forgetAccounts(context);
    if (removed) {
      await _cubit.disable();
    }
    if (mounted) {
      setState(() {
        _forgetting = false;
        _forgetFailed = !removed;
      });
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final char = event.character;
    if (char != null && char.length == 1 && '0123456789'.contains(char)) {
      _add(char);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      unawaited(_submit());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _cubit.state.verifying && !_cubit.state.locked) {
      _cubit.cancelVerification();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.appLock.lockScreen;
    final colorScheme = Theme.of(context).colorScheme;
    return BlocConsumer<AppLockCubit, AppLockState>(
      bloc: _cubit,
      listenWhen: (prev, curr) => prev.config.lockedOutUntil != curr.config.lockedOutUntil,
      listener: (_, _) => _syncTicker(),
      builder: (context, state) {
        final until = _cubit.lockedOutUntil;
        final busy = state.checking || _forgetting;
        final String? message;
        if (until != null) {
          message = tr.retryIn(seconds: until.difference(_cubit.now()).inSeconds + 1);
        } else if (_forgetFailed) {
          message = context.t.appLock.forgot.failed;
        } else if (state.wrongPin) {
          message = tr.wrongPin;
        } else {
          message = null;
        }
        return Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Scaffold(
            appBar: state.verifying && !state.locked
                ? AppBar(
                    leading: IconButton(
                      key: const ValueKey('app-lock-cancel'),
                      icon: const Icon(Icons.close),
                      tooltip: context.t.general.cancel,
                      onPressed: _cubit.cancelVerification,
                    ),
                  )
                : null,
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_outline, size: 40, color: colorScheme.primary),
                        const SizedBox(height: 16),
                        Text(tr.enterPin, style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 16),
                        _PinDots(length: _pin.length, error: message != null && until == null && !_forgetFailed),
                        SizedBox(
                          height: 40,
                          child: Center(
                            child: message == null
                                ? null
                                : Text(
                                    message,
                                    key: const ValueKey('app-lock-message'),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: colorScheme.error),
                                  ),
                          ),
                        ),
                        _PinPad(
                          enabled: !busy && until == null,
                          canSubmit: _pin.length >= appLockPinMinLength,
                          onDigit: _add,
                          onBackspace: _backspace,
                          onSubmit: () => unawaited(_submit()),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          height: 48,
                          child: busy
                              ? const Center(child: CircularProgressIndicator())
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (state.offersBiometric)
                                      IconButton.filledTonal(
                                        key: const ValueKey('app-lock-biometric'),
                                        icon: const Icon(Icons.fingerprint),
                                        tooltip: tr.biometric,
                                        onPressed: _promptBiometric,
                                      ),
                                    if (state.offersBiometric) const SizedBox(width: 16),
                                    TextButton(
                                      key: const ValueKey('app-lock-forgot'),
                                      onPressed: _forgot,
                                      child: Text(context.t.appLock.forgot.title),
                                    ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PinDots extends StatelessWidget {
  const _PinDots({required this.length, required this.error});

  final int length;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = error ? colorScheme.error : colorScheme.primary;
    return SizedBox(
      height: 16,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < appLockPinMaxLength; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < length ? color : null,
                  border: Border.all(color: i < length ? color : colorScheme.outline),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PinPad extends StatelessWidget {
  const _PinPad({
    required this.enabled,
    required this.canSubmit,
    required this.onDigit,
    required this.onBackspace,
    required this.onSubmit,
  });

  final bool enabled;
  final bool canSubmit;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.appLock.lockScreen;
    Widget digit(String d) => _PadKey(
      key: ValueKey('app-lock-digit-$d'),
      onPressed: enabled ? () => onDigit(d) : null,
      child: Text(d, style: Theme.of(context).textTheme.headlineSmall),
    );
    return Column(
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [for (final d in row) digit(d)]),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _PadKey(
              key: const ValueKey('app-lock-backspace'),
              tooltip: tr.delete,
              onPressed: enabled ? onBackspace : null,
              child: const Icon(Icons.backspace_outlined),
            ),
            digit('0'),
            _PadKey(
              key: const ValueKey('app-lock-submit'),
              tooltip: tr.confirm,
              onPressed: enabled && canSubmit ? onSubmit : null,
              child: const Icon(Icons.check),
            ),
          ],
        ),
      ],
    );
  }
}

class _PadKey extends StatelessWidget {
  const _PadKey({required this.child, required this.onPressed, this.tooltip, super.key});

  final Widget child;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: 72,
      height: 72,
      child: TextButton(
        style: TextButton.styleFrom(shape: const CircleBorder()),
        onPressed: onPressed,
        child: child,
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(4),
      child: tooltip == null ? button : Tooltip(message: tooltip, child: button),
    );
  }
}
