/// Messages between the app and the Android background message service (#80).
abstract final class BackgroundSyncEvents {
  /// App to service: stop.
  static const stop = 'stop';

  /// App to service: the switch, the interval or the locale changed, read the settings again.
  static const settingsChanged = 'settingsChanged';

  /// Service to app: rows were stored for `uid`; `notice`, `personalMessage` and `broadcastMessage` are the account's
  /// unread counts.
  static const synced = 'synced';
}
