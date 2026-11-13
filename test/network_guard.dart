// Keeps every test off the real network.
//
// `test/flutter_test_config.dart` installs this guard for every test file under `test/`. A test that reaches past
// its fakes (a repository built without the injected client or client factory, a widget that builds its own
// `Dio`/`HttpClient`, a raw `Socket`) gets a [RealNetworkBlocked] right away, and the test fails at its end even if
// the code under test swallowed that error.
//
// What it covers in a test isolate:
// - `dart:io` `HttpClient` (and everything built on it: dio's `IOHttpClientAdapter`, `package:http`'s `IOClient`,
//   `WebSocket.connect`, `Image.network`): through [HttpOverrides], checking where each connection really goes (the
//   proxy when one is set, else the URL's host).
// - raw `Socket.connect` / `Socket.startConnect`: through [IOOverrides].
// - the Android `httpChannel` (`KotlinHttpClient`) and every other method channel: there is no platform side in
//   `flutter test`, so a call without a mocked handler ends in a `MissingPluginException`, never on the network.
// - `Process`: not intercepted (tests run `chmod`, `id`, ...); no code under test spawns a network tool.
//
// Not covered (nothing in `lib/` uses these today):
// - an isolate the code under test spawns (`Isolate.run`, `compute`) does not inherit these overrides; the ones in
//   `lib/` crop images, hash PINs, list cache files and build exports;
// - `SecureSocket.connect`, `RawSocket.connect`, `RawDatagramSocket.bind` (they bypass `IOOverrides`) and DNS
//   lookups (`InternetAddress.lookup`);
// - connections opened in `setUpAll` / `tearDownAll` are blocked, but only reported by the next test's `setUp`, and
//   not at all after the last test.
//
// A test that needs a server of its own binds it to loopback (`HttpServer.bind(InternetAddress.loopbackIPv4, 0)`)
// and calls [allowLoopbackNetwork] first; only loopback is let through, and only for that test.

import 'dart:io';

/// Thrown when a test tries to open a connection to anything but an allowed loopback address.
final class RealNetworkBlocked implements Exception {
  /// Constructor.
  const RealNetworkBlocked(this.target);

  /// Where the connection was going, e.g. `www.tsdm39.com:443 (https://www.tsdm39.com/forum.php)`.
  final String target;

  @override
  String toString() =>
      'RealNetworkBlocked: tests must not reach the real network (測試不得連真實網路), '
      'inject a fake client instead (請注入假 client): $target';
}

bool _loopbackAllowed = false;
final _blocked = <String>[];

/// Lets the current test connect to loopback addresses (127.0.0.0/8, ::1, `localhost`), for a server it binds
/// itself. Reset before every test.
void allowLoopbackNetwork() => _loopbackAllowed = true;

/// The connections blocked since the current test started; drained by [takeBlockedConnections].
List<String> get blockedConnections => List.unmodifiable(_blocked);

/// Returns and forgets the connections blocked so far.
List<String> takeBlockedConnections() {
  final ret = List<String>.of(_blocked);
  _blocked.clear();
  return ret;
}

/// Forgets the loopback permission and the blocked list; called before every test.
void resetNetworkGuard() {
  _loopbackAllowed = false;
  _blocked.clear();
}

bool _isLoopback(String host) {
  final h = host.startsWith('[') && host.endsWith(']') ? host.substring(1, host.length - 1) : host;
  if (h.toLowerCase() == 'localhost') {
    return true;
  }
  return InternetAddress.tryParse(h)?.isLoopback ?? false;
}

/// Returns the error to fail the connection with, or null when it may go ahead.
RealNetworkBlocked? _check(Object? host, int? port, String what) {
  final name = host is InternetAddress ? host.address : '$host';
  if (_loopbackAllowed && _isLoopback(name)) {
    return null;
  }
  final target = '$name:${port ?? '?'} ($what)';
  _blocked.add(target);
  return RealNetworkBlocked(target);
}

final class _NoNetworkHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // `super` builds the real client; `HttpClient()` here would come back to this override.
    return super.createHttpClient(context)
      ..connectionFactory = (uri, proxyHost, proxyPort) {
        final host = proxyHost ?? uri.host;
        final port = proxyHost != null ? proxyPort : uri.port;
        if (_check(host, port, '$uri') case final blocked?) {
          return Future.error(blocked);
        }
        // Loopback only from here on. A direct https connection to it loses the client's `badCertificateCallback` and
        // `keyLog`; no test serves https on loopback today.
        if (proxyHost == null && uri.isScheme('https')) {
          return SecureSocket.startConnect(host, port ?? 443, context: context);
        }
        return Socket.startConnect(host, port ?? 80);
      };
  }
}

final class _NoNetworkIOOverrides extends IOOverrides {
  @override
  Future<Socket> socketConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) {
    if (_check(host, port, 'Socket.connect') case final blocked?) {
      return Future.error(blocked);
    }
    return super.socketConnect(host, port, sourceAddress: sourceAddress, sourcePort: sourcePort, timeout: timeout);
  }

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
  }) {
    if (_check(host, port, 'Socket.startConnect') case final blocked?) {
      return Future.error(blocked);
    }
    return super.socketStartConnect(host, port, sourceAddress: sourceAddress, sourcePort: sourcePort);
  }
}

final _httpOverrides = _NoNetworkHttpOverrides();

/// Installs the guard for the whole test isolate.
void installNetworkGuard() {
  HttpOverrides.global = _httpOverrides;
  IOOverrides.global = _NoNetworkIOOverrides();
}

/// Puts the HTTP guard back in place. `TestWidgetsFlutterBinding` replaces `HttpOverrides.global` with its own
/// mock (every request answers 400) when it starts; this makes those tests throw [RealNetworkBlocked] as well.
void reinstallHttpGuard() => HttpOverrides.global = _httpOverrides;
