/// A redirect the dart:io transport follows (iOS, the desktops, the image client of every platform) does not take the
/// app's `X-Tsdmapp-*` headers, the cookie or an `Authorization` to another host ([PlainTransportGuard]), as the
/// Kotlin client of Android does not (`HttpClient.sessionScope`).
///
/// dart:io copies every header of a request to the hop of a redirect, but `Cookie` and `Authorization` only to the
/// same host or a parent domain of it, on the same scheme and port; the app's own headers went everywhere.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';

import '../network_guard.dart';

/// A self-signed certificate made for these tests only (`localhost` and `127.0.0.1`), with its key: the servers below
/// serve https, as the forum does. A request over plain http to a host that is not the forum never carries the session
/// in the first place ([PlainTransportGuard.guard]).
const _cert = '''
-----BEGIN CERTIFICATE-----
MIIBmzCCAUGgAwIBAgIUP37KYOzJv+yi1NrfvhrMDRB0ZPEwCgYIKoZIzj0EAwIw
FDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTExNzEwMDY0OFoYDzIxMjYxMDI0
MTAwNjQ4WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO
PQMBBwNCAATMJKZWtqJyxIcRZgr6rWdflM6k9W9KbgcuVmpfcjmOLSgheyeMZ9Om
YF3eguLec8aGfIaAvqteuBcX43m+YG5Fo28wbTAdBgNVHQ4EFgQUPG4FVyqF7b8P
xLZEgw6jYHnF70UwHwYDVR0jBBgwFoAUPG4FVyqF7b8PxLZEgw6jYHnF70UwDwYD
VR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwCgYIKoZI
zj0EAwIDSAAwRQIgbY6kbsbxceqv52EaWcKAioqKrkHbNMwmWFq+LTOnz3gCIQCv
UUrebKF+G/nI4McR+WWn+jtnbHhYFs2XOS/aVS/Vpw==
-----END CERTIFICATE-----
''';

const _key = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgj79ZqmbSQ1r10g94
eOTd0OF4sNe2H3odCNqn9FjS7lKhRANCAATMJKZWtqJyxIcRZgr6rWdflM6k9W9K
bgcuVmpfcjmOLSgheyeMZ9OmYF3eguLec8aGfIaAvqteuBcX43m+YG5F
-----END PRIVATE KEY-----
''';

/// What a server of the test was sent.
typedef _Seen = ({String method, String path, Map<String, String> headers, String body});

/// A server on loopback answering each request with [answer], recording what came in; over https unless [plain].
Future<(HttpServer, List<_Seen>)> _serve(
  Future<void> Function(HttpRequest request, int index) answer, {
  bool plain = false,
}) async {
  final server = plain
      ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      : await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          SecurityContext()
            ..useCertificateChainBytes(utf8.encode(_cert))
            ..usePrivateKeyBytes(utf8.encode(_key)),
        );
  addTearDown(() => server.close(force: true));
  final seen = <_Seen>[];
  server.listen((request) async {
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(', '));
    final body = await utf8.decodeStream(request);
    seen.add((method: request.method, path: request.uri.path, headers: headers, body: body));
    await answer(request, seen.length - 1);
  });
  return (server, seen);
}

Future<void> _redirect(HttpRequest request, int status, String location) async {
  request.response
    ..statusCode = status
    ..headers.set(HttpHeaders.locationHeader, location);
  await request.response.close();
}

Future<void> _page(HttpRequest request, {String? setCookie}) async {
  if (setCookie != null) {
    request.response.headers.add(HttpHeaders.setCookieHeader, setCookie);
  }
  request.response.write('page');
  await request.response.close();
}

const _session = {
  'Cookie': 's_auth=synthetic',
  'Authorization': 'Bearer synthetic',
  'X-Tsdmapp-Device': 'synthetic-device',
  'X-Tsdmapp-Admin': 'synthetic-token',
  'Accept': 'text/html',
};

Iterable<String> _sessionNames(Map<String, String> headers) =>
    headers.keys.where((k) => k == 'cookie' || k == 'authorization' || k.startsWith('x-tsdmapp-'));

NetClientProvider _client() {
  final dio = Dio()
    ..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient(context: SecurityContext()..setTrustedCertificatesBytes(utf8.encode(_cert))),
    );
  addTearDown(dio.close);
  return NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty());
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.registerSingleton<NetErrorSaver>(NetErrorSaver());
  });
  tearDownAll(getIt.reset);

  setUp(allowLoopbackNetwork);

  test('a redirect to another host goes without the session headers, and its cookie is not handed back', () async {
    final (other, otherSeen) = await _serve((r, _) => _page(r, setCookie: 's_auth=foreign'));
    // Another host name for the same machine: `localhost` asked for, `127.0.0.1` redirected to.
    final (forum, forumSeen) = await _serve((r, _) => _redirect(r, 302, 'https://127.0.0.1:${other.port}/file'));

    final resp = await _client()
        .get('https://localhost:${forum.port}/forum.php', options: Options(headers: {..._session}))
        .run();
    final response = resp.getOrElse((e) => throw e);

    expect(response.statusCode, 200);
    expect(response.realUri.host, '127.0.0.1');
    expect(response.redirects, hasLength(1));
    expect(forumSeen.single.headers['x-tsdmapp-device'], 'synthetic-device');
    expect(forumSeen.single.headers['cookie'], contains('s_auth=synthetic'));
    final hop = otherSeen.single;
    expect(hop.path, '/file');
    expect(_sessionNames(hop.headers), isEmpty);
    expect(hop.headers['accept'], 'text/html');
    expect(response.headers[HttpHeaders.setCookieHeader], isNull);
  });

  test('a hop that left the host does not bring the session back on a later hop to it', () async {
    late final HttpServer forum;
    final (other, otherSeen) = await _serve((r, _) => _redirect(r, 302, 'https://localhost:${forum.port}/back'));
    final (server, forumSeen) = await _serve(
      (r, i) => i == 0 ? _redirect(r, 302, 'https://127.0.0.1:${other.port}/away') : _page(r),
    );
    forum = server;

    final resp = await _client()
        .get('https://localhost:${forum.port}/forum.php', options: Options(headers: {..._session}))
        .run();
    expect(resp.getOrElse((e) => throw e).statusCode, 200);
    expect(forumSeen, hasLength(2));
    expect(_sessionNames(otherSeen.single.headers), isEmpty);
    expect(_sessionNames(forumSeen[1].headers), isEmpty);
  });

  test('a redirect on the same host keeps the session headers', () async {
    final (forum, seen) = await _serve((r, i) => i == 0 ? _redirect(r, 302, '/next') : _page(r, setCookie: 's_x=1'));

    final resp = await _client()
        .get('https://localhost:${forum.port}/forum.php', options: Options(headers: {..._session}))
        .run();
    final response = resp.getOrElse((e) => throw e);

    expect(response.statusCode, 200);
    expect(response.realUri.path, '/next');
    expect(response.headers[HttpHeaders.setCookieHeader], ['s_x=1']);
    expect(seen, hasLength(2));
    expect(seen[1].headers['cookie'], contains('s_auth=synthetic'));
    expect(seen[1].headers['authorization'], 'Bearer synthetic');
    expect(seen[1].headers['x-tsdmapp-device'], 'synthetic-device');
    expect(seen[1].headers['x-tsdmapp-admin'], 'synthetic-token');
  });

  test('a redirect from https to http on the same host goes without the session headers', () async {
    final (plain, plainSeen) = await _serve((r, _) => _page(r), plain: true);
    final (forum, _) = await _serve((r, _) => _redirect(r, 302, 'http://localhost:${plain.port}/clear'));

    final resp = await _client()
        .get('https://localhost:${forum.port}/forum.php', options: Options(headers: {..._session}))
        .run();

    expect(resp.getOrElse((e) => throw e).statusCode, 200);
    expect(plainSeen.single.path, '/clear');
    expect(_sessionNames(plainSeen.single.headers), isEmpty);
  });

  test('a form answered 303 is read with a GET without the form, sent once', () async {
    final (other, otherSeen) = await _serve((r, _) => _page(r));
    final (forum, forumSeen) = await _serve((r, _) => _redirect(r, 303, 'https://127.0.0.1:${other.port}/done'));

    final resp = await _client()
        .postForm(
          'https://localhost:${forum.port}/plugin.php',
          data: {'field': 'value'},
          tsdmAppJson: false,
          headers: {..._session},
        )
        .run();

    expect(resp.getOrElse((e) => throw e).statusCode, 200);
    expect(forumSeen.single.method, 'POST');
    expect(forumSeen.single.body, 'field=value');
    final hop = otherSeen.single;
    expect(hop.method, 'GET');
    expect(hop.body, isEmpty);
    expect(hop.headers[HttpHeaders.contentLengthHeader], anyOf(isNull, '0'));
    expect(_sessionNames(hop.headers), isEmpty);
  });

  for (final status in [301, 302, 307, 308]) {
    test('a form answered $status is not sent again', () async {
      final (forum, seen) = await _serve((r, _) => _redirect(r, status, '/again'));

      final resp = await _client()
          .postForm(
            'https://localhost:${forum.port}/plugin.php',
            data: {'field': 'value'},
            tsdmAppJson: false,
            headers: {..._session},
          )
          .run();

      expect(resp.isLeft(), isTrue, reason: 'a redirect status is no success of a form');
      expect(seen, hasLength(1));
    });
  }

  test('the redirect limit of the request still holds', () async {
    final (forum, seen) = await _serve((r, i) => _redirect(r, 302, '/hop$i'));

    final resp = await _client()
        .get(
          'https://localhost:${forum.port}/forum.php',
          options: Options(headers: {..._session}, maxRedirects: 2),
        )
        .run();

    expect(resp.isLeft(), isTrue);
    expect(seen, hasLength(3));
  });

  test('the answer of a redirect that never ends is given up at the receive timeout', () async {
    final (forum, seen) = await _serve((r, _) async {
      r.response
        ..statusCode = 302
        ..headers.set(HttpHeaders.locationHeader, '/next')
        ..contentLength = 1000
        ..add(List.filled(10, 0x20));
      await r.response.flush();
      // The rest of the body never comes.
    });

    final watch = Stopwatch()..start();
    final resp = await _client()
        .get(
          'https://localhost:${forum.port}/forum.php',
          options: Options(headers: {..._session}, receiveTimeout: const Duration(milliseconds: 500)),
        )
        .run();

    expect(resp.isLeft(), isTrue);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(seen, hasLength(1));
  });

  test('which hop keeps the session: the same host or the forum, never https turned into http', () {
    bool keeps(String origin, String hop) => PlainTransportGuard.keepsSession(Uri.parse(origin), Uri.parse(hop));

    expect(keeps('https://www.tsdm39.com/forum.php', 'https://www.tsdm39.com/next'), isTrue);
    expect(keeps('https://www.tsdm39.com/forum.php', 'https://tsdm39.com/forum.php'), isTrue);
    expect(keeps('https://tsdm39.com/forum.php', 'https://WWW.TSDM39.COM/forum.php'), isTrue);
    expect(keeps('https://localhost:1/a', 'https://localhost:1/b'), isTrue);
    expect(keeps('https://localhost:1/a', 'https://localhost:2/b'), isFalse);
    expect(keeps('http://www.tsdm39.com/forum.php', 'https://www.tsdm39.com/forum.php'), isTrue);
    expect(keeps('https://www.tsdm39.com/forum.php', 'http://www.tsdm39.com/forum.php'), isFalse);
    expect(keeps('https://www.tsdm39.com/forum.php', 'http://tsdm39.com/forum.php'), isFalse);
    expect(keeps('https://www.tsdm39.com/forum.php', 'https://www.tsdm39.com.example.test/forum.php'), isFalse);
    expect(keeps('https://www.tsdm39.com/forum.php', 'https://cdn.example.test/file'), isFalse);
    expect(keeps('https://cdn.example.test/a', 'https://www.tsdm39.com/forum.php'), isFalse);
  });
}
