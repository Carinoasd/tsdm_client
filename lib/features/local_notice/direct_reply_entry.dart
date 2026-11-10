import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/background_sync/background_isolate.dart';
import 'package:tsdm_client/features/background_sync/background_sync_tick.dart';
import 'package:tsdm_client/features/local_notice/direct_reply.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';

/// The isolate side of the reply typed in a notification (`direct_reply.dart`): [onNotificationActionInBackground].
///
/// Kept apart from `direct_reply.dart` because a library with a `vm:entry-point` counts as executable for the
/// analyzer, which then reports every member not reached from the entry point.

/// What the isolate of the notification plugin needs, opened at the first reply and kept for the next ones: the plugin
/// keeps its engine for as long as the process lives.
final class _DirectReplyRuntime {
  _DirectReplyRuntime._(this.base, this.plugin);

  final BackgroundIsolateBase base;
  final FlutterLocalNotificationsPlugin plugin;

  static Future<_DirectReplyRuntime> create() async {
    // The same database, settings and clients as the background message service.
    final base = await BackgroundIsolateBase.open();
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_launcher_foreground'),
      ),
      onDidReceiveBackgroundNotificationResponse: onNotificationActionInBackground,
    );
    return _DirectReplyRuntime._(base, plugin);
  }

  /// The client of account [uid], from its cookie stored on this device; null when the account is not on it any more.
  Future<NetClientProvider?> clientOf(int uid) async {
    final cookie = getIt.get<CookieProvider>(instanceName: ServiceKeys.empty);
    if (!await cookie.loadCookieFromDatabase(UserLoginInfo(username: null, uid: uid))) {
      return null;
    }
    return base.clientOf(cookie);
  }
}

Future<_DirectReplyRuntime>? _runtime;

/// The log of this isolate, set up once: `talker` can be given only once.
Future<IOSink>? _logSink;

/// The end of the queue: one reply at a time.
Future<void> _queue = Future<void>.value();

/// What was sent lately, and when: the same text for the same floor is not sent twice in a row.
final _recent = <String, DateTime>{};

const _sameReplyWindow = Duration(seconds: 30);

/// Callback of the notification plugin for an action handled without the app (`showsUserInterface: false`), in the
/// plugin's own isolate: the direct reply ([DirectReplyRequest.of]), anything else is ignored.
///
/// The text is sent as the account the notification is about, with that account's cookie
/// ([BackgroundIsolateBase.clientOf]), whichever account the app has in use; the outcome is a notification of its own
/// ([showDirectReplyOutcome]). Replies are sent one at a time, each once.
@pragma('vm:entry-point')
Future<void> onNotificationActionInBackground(NotificationResponse response) async {
  final request = DirectReplyRequest.of(response);
  if (request == null) {
    return;
  }
  final previous = _queue;
  final done = Completer<void>();
  _queue = done.future;
  try {
    await previous;
    await _handle(request);
  } finally {
    done.complete();
  }
}

Future<void> _handle(DirectReplyRequest request) async {
  DartPluginRegistrant.ensureInitialized();
  final IOSink logSink;
  try {
    logSink = await (_logSink ??= initBackgroundLogger());
  } on Object catch (e) {
    // Set up as the last step: tried again with the next reply.
    _logSink = null;
    debugPrint('direct reply: no log: $e');
    await _showUnsent(request);
    return;
  }
  final _DirectReplyRuntime runtime;
  try {
    runtime = await (_runtime ??= _DirectReplyRuntime.create());
  } on Object catch (e, st) {
    _runtime = null;
    talker.handle(e, st, 'direct reply: failed to start');
    await _showUnsent(request);
    try {
      // What was registered before the failure, so the next reply starts over.
      await getIt.reset();
    } on Object catch (e, st) {
      talker.handle(e, st, 'direct reply: clearing the failed start failed');
    }
    await logSink.flush();
    return;
  }
  final key = '${request.uid}:${request.target.toQuery()}:${request.message.hashCode}';
  final now = DateTime.now();
  _recent.removeWhere((_, at) => now.difference(at) > _sameReplyWindow);
  if (_recent.containsKey(key)) {
    talker.info('direct reply: the same text was just sent, dropped');
    await logSink.flush();
    return;
  }
  _recent[key] = now;
  final storage = runtime.base.storage;
  try {
    talker.info(
      'direct reply: sending for uid ${"${request.uid}".obscured(4)} '
      '(${request.toConversation ? 'message' : 'floor'})',
    );
    DirectReplyOutcome outcome;
    try {
      try {
        await runtime.base.applyLocale((await readBackgroundSyncSettings(storage)).locale);
      } on Object catch (e, st) {
        // The texts of the notification only: sent all the same, in the language already loaded.
        talker.handle(e, st, 'direct reply: language not read');
      }
      // The proxy the user asked for: without it the reply would go out by a direct connection.
      await runtime.base.refreshNetwork();
      outcome = await runDirectReply(
        request,
        translations: t,
        enabled: () => directReplyEnabled(storage),
        locked: appLocked,
        clientOf: runtime.clientOf,
      );
    } on Object catch (e, st) {
      talker.handle(e, st, 'direct reply: failed before sending');
      outcome = DirectReplyNotSent(t.localNotification.directReply.error);
    }
    if (outcome is! DirectReplySent) {
      // Sent again only by hand, from the app or from a new notification.
      _recent.remove(key);
    }
    talker.info('direct reply: ${outcome.runtimeType}');
    try {
      await showDirectReplyOutcome(plugin: runtime.plugin, translations: t, request: request, outcome: outcome);
    } on Object catch (e) {
      talker.warning('direct reply: showing the outcome failed, once more: $e');
      await showDirectReplyOutcome(plugin: runtime.plugin, translations: t, request: request, outcome: outcome);
    }
  } on Object catch (e, st) {
    talker.handle(e, st, 'direct reply: failed');
  } finally {
    await logSink.flush();
  }
}

/// The notification telling [request] was not sent, when nothing of the isolate could be set up: the notification it
/// came from is gone, the text must not be. In the default language: the settings could not be read.
Future<void> _showUnsent(DirectReplyRequest request) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_launcher_foreground'),
      ),
      onDidReceiveBackgroundNotificationResponse: onNotificationActionInBackground,
    );
    await showDirectReplyOutcome(
      plugin: plugin,
      translations: t,
      request: request,
      outcome: DirectReplyNotSent(t.localNotification.directReply.error),
    );
  } on Object catch (e) {
    debugPrint('direct reply: telling it was not sent failed: $e');
  }
}
