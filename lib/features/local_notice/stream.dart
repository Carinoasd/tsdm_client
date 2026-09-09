import 'dart:async';

/// A global stream acts like a bridge
final StreamController<String?> localNoticeStream = StreamController<String?>.broadcast();

/// Payload of the notification that cold-started the app, waiting for the home page to consume it.
///
/// A tap on a notification while the app is alive comes in through [localNoticeStream]; when the app was not running
/// the tap starts it and the payload only exists in the launch details read at boot (#14). Nothing listens on the
/// stream that early, so the payload is parked here until the home page has its first frame.
String? _pendingLaunchPayload;

/// Park the [payload] of the notification that launched the app until the home page consumes it.
///
/// `null` clears a pending payload.
void rememberLaunchPayload(String? payload) => _pendingLaunchPayload = payload;

/// The payload parked by [rememberLaunchPayload] that nobody consumed yet, for tests and diagnostics.
String? get pendingLaunchPayload => _pendingLaunchPayload;

/// Hand the parked launch payload to [handler] once.
///
/// The payload is forgotten before [handler] runs, so a second call, a rebuilt home page or a handler that throws
/// can not deliver it twice. Returns whether there was a payload to consume.
Future<bool> consumePendingLaunchPayload(FutureOr<void> Function(String payload) handler) async {
  final payload = _pendingLaunchPayload;
  _pendingLaunchPayload = null;
  if (payload == null) {
    return false;
  }
  await handler(payload);
  return true;
}
