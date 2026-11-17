import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:system_hotkeys/system_hotkeys.dart';
import 'package:system_hotkeys_linux/system_hotkeys_linux.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/features/boss_key/models/boss_key_combo.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/utils/window_configs.dart';
import 'package:window_manager/window_manager.dart';

/// The id of the app for the GlobalShortcuts portal of Linux (`linux/CMakeLists.txt`): the basename of its `.desktop`
/// file, when one is installed.
const _linuxApplicationId = 'com.tsdm.tsdm_client';

Future<HotKeyResult> _systemRegister(HotKey hotKey) => SystemHotkeys.register(
  bossKeyId,
  hotKey,
  // Listed in the shortcut settings of the Linux desktops.
  description: LocaleSettings.currentLocale.translations.settingsPage.windowSection.bossKey,
);

Future<void> _systemUnregister() => SystemHotkeys.unregister(bossKeyId);

Future<bool> _systemWindowOnScreen() async => await windowManager.isVisible() && !await windowManager.isMinimized();

AppLockCubit? get _appLock => getIt.isRegistered<AppLockCubit>() ? getIt.get<AppLockCubit>() : null;

/// One frame for the lock screen the app lock may just have put up, painted before the window changes. Nothing while
/// frames are off (the lifecycle is hidden while the window is: the first frame comes once it is shown); bounded all
/// the same.
Future<void> _systemSettle() async {
  if (!SchedulerBinding.instance.framesEnabled) {
    return;
  }
  await WidgetsBinding.instance.endOfFrame.timeout(const Duration(milliseconds: 150), onTimeout: () {});
}

/// The boss key of the desktop app (`SettingsKeys.bossKey`, off by default): a system-wide shortcut
/// (`SettingsKeys.bossKeyCombo`) hides the window, the next press brings it back with the focus.
///
/// The window goes whether or not there is a tray icon: the shortcut itself brings it back. Nothing else changes while
/// it is hidden: the audio goes on playing, the notices go on syncing. The app lock counts the time away from the
/// moment it is hidden ([AppLockCubit.windowHidden]) and locks as it would after leaving the screen.
///
/// The switch says what the user gets: a combination another app holds, or one the desktop turns down, turns it back
/// off with a snack bar saying why. A platform that can not bind any (Linux without the GlobalShortcuts portal, or a
/// desktop that does not know the app) makes the switch unavailable for the rest of the run ([available]); nothing is
/// bound to find out before the user turns it on (GNOME would ask in a dialog).
///
/// On Linux the desktop decides the keys ([configuredByDesktop]): the combination of the app is a suggestion for the
/// first binding, what the desktop bound comes back as [desktopTrigger], and the keys are changed in the desktop's own
/// settings ([configureInDesktop]).
class BossKey with WindowListener, LoggerMixin {
  BossKey._({
    required Future<HotKeyResult> Function(HotKey hotKey) register,
    required Future<void> Function() unregister,
    required Stream<HotKeyEvent> Function() events,
    required Future<bool> Function() windowOnScreen,
    required Future<void> Function() hideWindow,
    required Future<void> Function() showWindow,
    required void Function() onHidden,
    required void Function() onShown,
    required void Function(HotKeyResult result) report,
    required bool listenWindow,
    required Stream<Map<String, String>> Function() triggers,
    required Future<bool> Function() configure,
    required bool Function() configuredByDesktop,
    required Future<void> Function() settle,
    void Function()? beforeStart,
  }) : _register = register,
       _unregister = unregister,
       _events = events,
       _windowOnScreen = windowOnScreen,
       _hideWindow = hideWindow,
       _showWindow = showWindow,
       _onHidden = onHidden,
       _onShown = onShown,
       _report = report,
       _listenWindow = listenWindow,
       _triggers = triggers,
       _configure = configure,
       _configuredByDesktop = configuredByDesktop,
       _settle = settle,
       _beforeStart = beforeStart;

  /// Drives a fake system and window in tests.
  @visibleForTesting
  BossKey.forTesting({
    required Future<HotKeyResult> Function(HotKey hotKey) register,
    required Future<void> Function() unregister,
    required Stream<HotKeyEvent> events,
    required Future<bool> Function() windowOnScreen,
    required Future<void> Function() hideWindow,
    required Future<void> Function() showWindow,
    required void Function() onHidden,
    required void Function() onShown,
    required void Function(HotKeyResult result) report,
    Stream<Map<String, String>> triggers = const Stream.empty(),
    Future<bool> Function()? configure,
    bool configuredByDesktop = false,
    Future<void> Function()? settle,
  }) : this._(
         register: register,
         unregister: unregister,
         events: () => events,
         windowOnScreen: windowOnScreen,
         hideWindow: hideWindow,
         showWindow: showWindow,
         onHidden: onHidden,
         onShown: onShown,
         report: report,
         listenWindow: false,
         triggers: () => triggers,
         configure: configure ?? () async => false,
         configuredByDesktop: () => configuredByDesktop,
         settle: settle ?? () async {},
       );

  /// The app's.
  static final BossKey instance = BossKey._(
    register: _systemRegister,
    unregister: _systemUnregister,
    events: () => SystemHotkeys.events,
    windowOnScreen: _systemWindowOnScreen,
    hideWindow: windowManager.hide,
    showWindow: bringWindowToFront,
    onHidden: () => _appLock?.windowHidden(),
    onShown: () => _appLock?.windowShown(),
    report: _reportFailure,
    listenWindow: true,
    triggers: () => SystemHotkeys.triggers,
    configure: SystemHotkeys.configure,
    configuredByDesktop: () => SystemHotkeys.capabilities.configureExternally,
    settle: _systemSettle,
    beforeStart: () {
      // Before the first shortcut: the portal ties the connection to an app on its first call.
      if (isLinux) {
        SystemHotkeysLinux.registerWith(applicationId: _linuxApplicationId);
      }
    },
  );

  final Future<HotKeyResult> Function(HotKey hotKey) _register;
  final Future<void> Function() _unregister;
  final Stream<HotKeyEvent> Function() _events;
  final Future<bool> Function() _windowOnScreen;
  final Future<void> Function() _hideWindow;
  final Future<void> Function() _showWindow;
  final void Function() _onHidden;
  final void Function() _onShown;
  final void Function(HotKeyResult result) _report;
  final bool _listenWindow;
  final Stream<Map<String, String>> Function() _triggers;
  final Future<bool> Function() _configure;
  final bool Function() _configuredByDesktop;
  final Future<void> Function() _settle;
  final void Function()? _beforeStart;

  bool _started = false;
  StreamSubscription<SettingsMap>? _settingsSubscription;
  StreamSubscription<HotKeyEvent>? _eventSubscription;
  StreamSubscription<Map<String, String>>? _triggerSubscription;

  /// The combination bound now, null when none is.
  HotKey? _bound;

  /// Set while the shortcut is being recorded ([suspend]): nothing is bound, the keys reach the recorder.
  bool _suspended = false;

  /// Set while the recorder is open ([record]).
  bool _recording = false;

  /// Set while the window is hidden by the boss key, until it is shown again by any means.
  bool _hidden = false;

  /// Bindings one after the other, in the order asked.
  Future<void> _binding = Future<void>.value();

  /// Hiding and showing one after the other: a second press waits for the first to finish.
  Future<void> _toggling = Future<void>.value();

  /// The tasks of [_toggling] not done yet.
  int _togglingPending = 0;

  final _available = ValueNotifier<bool>(false);

  /// Whether the boss key can be used: started, and the platform did not answer that it can bind none.
  ValueListenable<bool> get available => _available;

  /// The combination bound now, null when none is.
  HotKey? get bound => _bound;

  final _desktopTrigger = ValueNotifier<String?>(null);

  /// What the desktop says triggers the boss key, in its own words (empty: bound without keys yet), null when it says
  /// nothing: only where [configuredByDesktop].
  ValueListenable<String?> get desktopTrigger => _desktopTrigger;

  bool? _desktopDecides;

  /// Whether the desktop, not the app, decides the keys (Linux): the recorded combination is only a suggestion.
  bool get configuredByDesktop => _desktopDecides ??= _configuredByDesktop();

  /// Whether the window is hidden by the boss key (tests).
  @visibleForTesting
  bool get hidden => _hidden;

  SettingsRepository get _settings => getIt.get<SettingsRepository>();

  /// Follow the settings and the presses. Desktop only, and not with `--no-window-configs` (it hides the window).
  void start() {
    if (_started) {
      return;
    }
    _started = true;
    _beforeStart?.call();
    _available.value = true;
    _eventSubscription = _events().listen(_onEvent, onError: handleRaw);
    _triggerSubscription = _triggers().listen(
      // Told while the combination is being bound (before [_bound] is set), and as nothing once it is released.
      (triggers) => _desktopTrigger.value = triggers[bossKeyId],
      onError: handleRaw,
    );
    if (_listenWindow) {
      windowManager.addListener(this);
    }
    _settingsSubscription = _settings.settings.listen((_) => unawaited(apply()));
    unawaited(apply());
  }

  /// Bind or release the shortcut as the settings say.
  Future<void> apply() => _serial(_apply);

  Future<void> _serial(Future<void> Function() task) => _binding = _binding.then((_) => task()).catchError(handleRaw);

  Future<void> _apply() async {
    if (!_started) {
      return;
    }
    final settings = _settings.currentSettings;
    final want = settings.bossKey && !_suspended && _available.value ? bossKeyOf(settings.bossKeyCombo) : null;
    if (want == _bound) {
      return;
    }
    if (want == null) {
      await _release();
      return;
    }
    final result = await _bind(want);
    if (result != HotKeyResult.bound) {
      await _failed(result);
    }
  }

  /// Turn the boss key on or off from the settings page. A failure to bind is told by a snack bar and turns the
  /// switch back off. Not turned on where it is not [available].
  Future<void> setEnabled({required bool enable}) async {
    if (enable && !_available.value) {
      return;
    }
    await _settings.setValue(SettingsKeys.bossKey, enable);
    await apply();
  }

  /// Release the shortcut while a new one is recorded: the keys go to the recorder, and pressing the current one does
  /// not hide the window.
  Future<void> suspend() {
    _suspended = true;
    return apply();
  }

  /// The recording is over: bind [hotKey] when it is a new combination, else what was bound before.
  ///
  /// A new combination is saved only once bound (or right away while the boss key is off). One another app holds or
  /// the desktop turns down is told by a snack bar, and the one of before is bound again.
  Future<void> resume({HotKey? hotKey}) => _serial(() async {
    _suspended = false;
    final settings = _settings.currentSettings;
    final current = bossKeyOf(settings.bossKeyCombo);
    if (hotKey == null || hotKey == current || bossKeyProblem(hotKey) != null) {
      return _apply();
    }
    if (!_started || !settings.bossKey || !_available.value) {
      await _settings.setValue(SettingsKeys.bossKeyCombo, encodeBossKey(hotKey)!);
      return _apply();
    }
    final result = await _bind(hotKey);
    if (result == HotKeyResult.bound) {
      await _settings.setValue(SettingsKeys.bossKeyCombo, encodeBossKey(hotKey)!);
      return;
    }
    if (result == HotKeyResult.unsupported) {
      return _failed(result);
    }
    _report(result);
    final back = await _bind(current);
    if (back != HotKeyResult.bound) {
      await _failed(back, report: false);
    }
  });

  /// Record a new combination with [show] (the recorder, giving the combination to save or null): the shortcut is
  /// released while it is open ([suspend]) and bound again after ([resume]). Nothing while one is open already.
  Future<void> record(Future<HotKey?> Function() show) async {
    if (_recording) {
      return;
    }
    _recording = true;
    HotKey? hotKey;
    try {
      await suspend();
      hotKey = await show();
    } finally {
      await resume(hotKey: hotKey);
      _recording = false;
    }
  }

  /// Open the desktop's settings of the app's shortcuts, where the keys are changed when [configuredByDesktop]: false
  /// when there are none to open (nothing bound, or a desktop too old for it).
  Future<bool> configureInDesktop() async {
    if (!configuredByDesktop || _bound == null) {
      return false;
    }
    try {
      return await _configure();
    } on Object catch (e, st) {
      handleRaw(e, st);
      return false;
    }
  }

  Future<HotKeyResult> _bind(HotKey hotKey) async {
    HotKeyResult result;
    try {
      result = await _register(hotKey);
    } on Object catch (e, st) {
      handleRaw(e, st);
      result = HotKeyResult.unsupported;
    }
    // Binding the id again releases what it held before, even when the new combination fails.
    _bound = result == HotKeyResult.bound ? hotKey : null;
    info('boss key ${encodeBossKey(hotKey)}: ${result.name}');
    return result;
  }

  Future<void> _release() async {
    _bound = null;
    _desktopTrigger.value = null;
    try {
      await _unregister();
    } on Object catch (e, st) {
      handleRaw(e, st);
    }
  }

  /// Nothing is bound after [result]: the switch goes off, and with [HotKeyResult.unsupported] it is unavailable.
  ///
  /// Released all the same: the Linux portal keeps a combination it could not bind, to bind it again by itself when
  /// the portal restarts.
  Future<void> _failed(HotKeyResult result, {bool report = true}) async {
    await _release();
    if (result == HotKeyResult.unsupported) {
      _available.value = false;
    }
    if (report) {
      _report(result);
    }
    await _settings.setValue(SettingsKeys.bossKey, false);
  }

  void _onEvent(HotKeyEvent event) {
    if (event.id != bossKeyId || _bound == null || _suspended) {
      return;
    }
    unawaited(toggle());
  }

  /// Hide the window when it is on the screen, else bring it back with the focus.
  ///
  /// On the screen means shown and not minimized, focused or not: a window seen behind another one goes too. A
  /// minimized window comes back, the next press hides it.
  Future<void> toggle() => _queueToggling(_toggle);

  /// Run [task] after the presses before it, counted in [_togglingPending] until it is done.
  Future<void> _queueToggling(Future<void> Function() task) {
    _togglingPending++;
    return _toggling = _toggling.then((_) => task()).catchError(handleRaw).whenComplete(() => _togglingPending--);
  }

  Future<void> _toggle() async {
    if (await _windowOnScreen()) {
      _hidden = true;
      _onHidden();
      try {
        // Locked as it hides ("every time"): the lock screen is painted while the window still gets frames, so it is
        // what the window shows when it comes back (and what the system keeps of it meanwhile).
        await _settle();
        await _hideWindow();
      } on Object catch (e, st) {
        handleRaw(e, st);
        _shownAgain();
      }
      return;
    }
    await _beforeWindowShown();
    await _showWindow();
  }

  /// The window is about to be shown again by the app (the tray, a notification): with the window hidden by the boss
  /// key, the app lock decides now and its lock screen gets a frame, before the window is seen. After a press of the
  /// boss key being handled: a window still on its way out is not taken for one coming back.
  ///
  /// Nothing to wait for (no press being handled, the window not hidden by the boss key, as always on the platforms
  /// without it): done at once, without touching the queue.
  Future<void> beforeWindowShown() {
    if (!_hidden && _togglingPending == 0) {
      return Future<void>.value();
    }
    return _queueToggling(_beforeWindowShown);
  }

  Future<void> _beforeWindowShown() async {
    if (!_hidden) {
      return;
    }
    _shownAgain();
    await _settle();
  }

  void _shownAgain() {
    if (!_hidden) {
      return;
    }
    _hidden = false;
    _onShown();
  }

  /// Shown again some other way the app is not told of beforehand (the Dock, launching the app again): the app lock
  /// counts the time away all the same.
  @override
  void onWindowFocus() => _shownAgain();

  /// Stop following (tests).
  @visibleForTesting
  Future<void> dispose() async {
    if (!_started) {
      return;
    }
    _started = false;
    if (_listenWindow) {
      windowManager.removeListener(this);
    }
    await _settingsSubscription?.cancel();
    _settingsSubscription = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _triggerSubscription?.cancel();
    _triggerSubscription = null;
    await _binding;
    await _toggling;
  }
}

/// Tell why the boss key is not bound: on the app's messenger, after the first frame when it fails at startup.
void _reportFailure(HotKeyResult result) {
  Future<void> show() async {
    for (var frame = 0; frame < 30 && snackbarKey.currentContext == null; frame++) {
      await WidgetsBinding.instance.endOfFrame;
    }
    final context = snackbarKey.currentContext;
    if (context == null || !context.mounted) {
      return;
    }
    final tr = context.t.settingsPage.windowSection;
    showSnackBar(
      context: context,
      message: switch (result) {
        HotKeyResult.conflict => tr.bossKeyConflict,
        HotKeyResult.declined => tr.bossKeyDeclined,
        HotKeyResult.unsupported || HotKeyResult.bound => tr.bossKeyUnavailable,
      },
    );
  }

  unawaited(show());
}
