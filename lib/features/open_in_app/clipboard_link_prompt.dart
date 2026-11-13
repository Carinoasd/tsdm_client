import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/features/open_in_app/utils/forum_link_in_text.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/share_receive/share_dispatcher.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Name of the settings row holding the forum link last offered from the clipboard (or copied in the app). Kept on
/// this device only: never synced, never in a diagnostics bundle.
const clipboardLinkPromptedKey = 'clipboardLinkPrompted';

/// Offers to open a forum link the user just copied (`SettingsKeys.clipboardLinkPrompt`).
///
/// Everything it touches is injected, the running app's in [ClipboardLinkPrompter.app]:
///
/// * Nothing is read, not even the clipboard, while [enabled] says no.
/// * The clipboard is read once per [check]; the first forum link in its text ([findForumLinkInText]) is offered by
///   [prompt] unless it is the one offered (or copied in the app, [remember]) last.
/// * A link is remembered when it is offered, whether it is opened or not: the same link is offered once.
final class ClipboardLinkPrompter with LoggerMixin {
  /// Constructor.
  ClipboardLinkPrompter({
    required this.enabled,
    required this.readClipboard,
    required this.loadPrompted,
    required this.savePrompted,
    required this.prompt,
  });

  /// The prompter of the running app: the setting, the system clipboard, the settings storage, a snack bar.
  factory ClipboardLinkPrompter.app() => ClipboardLinkPrompter(
    enabled: _appEnabled,
    readClipboard: getPlainTextFromClipboard,
    loadPrompted: () async => getIt.get<StorageProvider>().getString(clipboardLinkPromptedKey),
    savePrompted: (url) async => getIt.get<StorageProvider>().saveString(clipboardLinkPromptedKey, url),
    prompt: showClipboardLinkSnackBar,
  );

  /// Whether the user wants copied links offered.
  final bool Function() enabled;

  /// The plain text in the clipboard.
  final Future<String?> Function() readClipboard;

  /// The link offered last, null when none was.
  final Future<String?> Function() loadPrompted;

  /// Remember a url as offered.
  final Future<void> Function(String url) savePrompted;

  /// Offer to open a link.
  final Future<void> Function(ForumLinkInText link) prompt;

  /// Read the clipboard and offer the forum link in it, if any and new.
  Future<void> check() async {
    if (!enabled()) {
      return;
    }
    final String? text;
    try {
      text = await readClipboard();
    } on Object catch (e) {
      // A platform may refuse the clipboard (no focus, a policy): nothing to offer.
      debug('clipboard not read: $e');
      return;
    }
    final link = text == null || text.isEmpty ? null : findForumLinkInText(text);
    if (link == null) {
      return;
    }
    if (await loadPrompted() == link.url) {
      return;
    }
    await savePrompted(link.url);
    await prompt(link);
  }

  /// [text] was copied in the app: its forum link is not offered when the app comes back.
  Future<void> remember(String text) async {
    if (!enabled()) {
      return;
    }
    final link = findForumLinkInText(text);
    if (link != null) {
      await savePrompted(link.url);
    }
  }
}

bool _appEnabled() =>
    getIt.isRegistered<StorageProvider>() &&
    getIt.isRegistered<SettingsRepository>() &&
    getIt.get<SettingsRepository>().currentSettings.clipboardLinkPrompt;

/// [text] was copied in the running app (see [ClipboardLinkPrompter.remember]).
Future<void> rememberCopiedInApp(String text) async {
  try {
    await ClipboardLinkPrompter.app().remember(text);
  } on Object catch (e, st) {
    talker.handle(e, st, 'failed to remember the link copied');
  }
}

/// The snack bar offering [link]: a thread or another page of the forum, opened only when tapped.
///
/// At a cold start it waits for the app to be built.
Future<void> showClipboardLinkSnackBar(ForumLinkInText link) async {
  final context = await waitForRootNavigatorContext();
  if (context == null || !context.mounted) {
    return;
  }
  final tr = context.t.linkToken;
  showSnackBar(
    context: context,
    message: link.isThread ? tr.clipboardThread : tr.clipboardPage,
    clearPrevious: true,
    action: SnackBarAction(
      label: tr.open,
      onPressed: () {
        final current = rootNavigatorContext();
        if (current != null && current.mounted) {
          unawaited(current.dispatchAsUrl(link.url));
        }
      },
    ),
  );
}

/// Runs [ClipboardLinkPrompter.check] when the app comes to the front: once after a cold start, once each time it is
/// shown again (a phone shows the user a notice every time the clipboard is read: not when only a system sheet or the
/// notification shade covered the app), on desktop also when the window gets the focus back. Never while the app
/// lock covers the app: then once it is unlocked.
final class ClipboardLinkWatcher extends StatefulWidget {
  /// Constructor.
  const ClipboardLinkWatcher({this.prompter, this.lock, this.checkOnFocus, super.key});

  /// The prompter, the running app's by default.
  final ClipboardLinkPrompter? prompter;

  /// The app lock, the registered one by default.
  final AppLockCubit? lock;

  /// Check each time the app gets the focus back, not only when it is shown again; desktop platforms by default.
  final bool? checkOnFocus;

  @override
  State<ClipboardLinkWatcher> createState() => _ClipboardLinkWatcherState();
}

final class _ClipboardLinkWatcherState extends State<ClipboardLinkWatcher> {
  late final AppLifecycleListener _lifecycle;
  late final ClipboardLinkPrompter _prompter = widget.prompter ?? ClipboardLinkPrompter.app();

  /// The next resume checks.
  bool _armed = true;

  /// Waits for the app lock to open.
  StreamSubscription<AppLockState>? _unlock;

  bool get _checkOnFocus => widget.checkOnFocus ?? isDesktop;

  AppLockCubit? get _lock => widget.lock ?? (getIt.isRegistered<AppLockCubit>() ? getIt.get<AppLockCubit>() : null);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onShow: () => _armed = true,
      onInactive: () {
        if (_checkOnFocus) {
          _armed = true;
        }
      },
      onHide: _cancelWait,
      onResume: _onResume,
    );
    // A cold start: the first page is up after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == null || state == AppLifecycleState.resumed) {
        _onResume();
      }
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _cancelWait();
    super.dispose();
  }

  void _cancelWait() {
    unawaited(_unlock?.cancel());
    _unlock = null;
  }

  void _onResume() {
    if (!_armed || !_prompter.enabled()) {
      return;
    }
    _armed = false;
    // After the frame: the app lock decides on the same resume whether it covers the app.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final lock = _lock;
      if (lock == null || !lock.state.covering) {
        unawaited(_prompter.check());
        return;
      }
      _cancelWait();
      _unlock = lock.stream.where((s) => !s.covering).take(1).listen((_) {
        _unlock = null;
        if (mounted) {
          unawaited(_prompter.check());
        }
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
