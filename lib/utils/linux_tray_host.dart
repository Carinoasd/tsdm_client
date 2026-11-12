import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:tsdm_client/instance.dart';

/// The bus name a tray host of the StatusNotifierItem protocol (what appindicator talks to) takes.
const statusNotifierWatcherName = 'org.kde.StatusNotifierWatcher';

/// Linux: whether the desktop shows tray icons, asked on the session bus.
///
/// `app_indicator_new` never fails: on a desktop without a tray host (GNOME without the AppIndicator extension) the
/// icon is created and shown nowhere, so the switch would say "on" while nothing is there. Any failure, no session bus
/// or a bus slower than [timeout] counts as no tray.
Future<bool> linuxTrayHostAvailable({Duration timeout = const Duration(seconds: 2)}) async {
  DBusClient? client;
  try {
    client = DBusClient.session();
    return await client.nameHasOwner(statusNotifierWatcherName).timeout(timeout);
  } on Object catch (e, st) {
    talker.handle(e, st, 'tray host lookup failed');
    return false;
  } finally {
    try {
      await client?.close().timeout(const Duration(milliseconds: 500));
    } on Object catch (_) {
      // Nothing left to do with the bus.
    }
  }
}
