/// A request over plain http never carries the account ([PlainTransportGuard], the last interceptor of every client).
///
/// To the forum's host it goes over https instead (same host, the cookie read for it); to any other host it goes
/// without `Cookie` and without the app's `X-Tsdmapp-*` headers. An https request is left as it is.
library;

import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// Records what each request carried when it left; answers an empty page. Nothing leaves the machine.
final class _Adapter implements HttpClientAdapter {
  final sent = <({Uri uri, Map<String, dynamic> headers})>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sent.add((uri: options.uri, headers: {...options.headers}));
    return ResponseBody.fromString(
      '',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The app's device header, set the way `LoginDeviceHeader` sets it, before the guard.
final class _DeviceHeader extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers['X-Tsdmapp-Device'] = 'synthetic-device';
    handler.next(options);
  }
}

String? _header(Map<String, dynamic> headers, String name) =>
    headers.entries.where((e) => e.key.toLowerCase() == name.toLowerCase()).map((e) => '${e.value}').firstOrNull;

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  RequestOptions guarded(String url, {Map<String, dynamic>? headers, Map<String, dynamic>? query}) {
    final options = RequestOptions(path: url, headers: headers, queryParameters: query);
    PlainTransportGuard.guard(options);
    return options;
  }

  const session = {'Cookie': 's_auth=synthetic', 'X-Tsdmapp-Device': 'synthetic-device', 'x-tsdmapp-other': '1'};

  test('the forum over http: over https, on the same host, the query once', () {
    for (final (url, expected) in [
      ('http://www.tsdm39.com/forum.php?mod=attachment&aid=1', 'https://www.tsdm39.com/forum.php?mod=attachment&aid=1'),
      ('http://tsdm39.com/forum.php?mod=attachment&aid=1', 'https://tsdm39.com/forum.php?mod=attachment&aid=1'),
      ('HTTP://WWW.TSDM39.COM/home.php', 'https://www.tsdm39.com/home.php'),
    ]) {
      final options = guarded(url, headers: {...session});
      expect('${options.uri}', expected, reason: url);
      // The session stays: the request no longer leaves in clear text.
      expect(_header(options.headers, 'Cookie'), 's_auth=synthetic');
    }
    final withQuery = guarded('http://www.tsdm39.com/forum.php', query: {'mod': 'viewthread', 'tid': '1'});
    expect('${withQuery.uri}', 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1');
  });

  test('another host over http: without the cookie and the app headers', () {
    final options = guarded('http://cdn.example.test/a.zip', headers: {...session, 'Accept': 'image/*'});
    expect('${options.uri}', 'http://cdn.example.test/a.zip');
    expect(_header(options.headers, 'Cookie'), isNull);
    expect(options.headers.keys.where((k) => k.toLowerCase().startsWith('x-tsdmapp-')), isEmpty);
    expect(_header(options.headers, 'Accept'), 'image/*');
    // A host that only looks like the forum's is another host.
    final lookalike = guarded('http://www.tsdm39.com.example.test/forum.php', headers: {...session});
    expect(_header(lookalike.headers, 'Cookie'), isNull);
  });

  test('https is left as it is', () {
    final forum = guarded('https://www.tsdm39.com/forum.php', headers: {...session});
    expect(_header(forum.headers, 'Cookie'), 's_auth=synthetic');
    final other = guarded('https://cdn.example.test/a.zip', headers: {'Accept': 'image/*'});
    expect('${other.uri}', 'https://cdn.example.test/a.zip');
  });

  test('after the cookie manager: the cookie it adds for an http host does not leave', () async {
    final jar = CookieJar();
    await jar.saveFromResponse(Uri.parse('http://cdn.example.test/'), [Cookie('s_cdn', 'synthetic')]);
    await jar.saveFromResponse(Uri.parse('https://www.tsdm39.com/'), [Cookie('s_auth', 'synthetic')]);
    final adapter = _Adapter();
    final dio = Dio()
      ..httpClientAdapter = adapter
      ..interceptors.addAll([CookieManager(jar), _DeviceHeader(), PlainTransportGuard()]);
    await dio.get<dynamic>('http://cdn.example.test/a.zip');
    await dio.get<dynamic>('http://www.tsdm39.com/forum.php?mod=attachment&aid=1');
    final (cdn, forum) = (adapter.sent[0], adapter.sent[1]);
    expect(cdn.uri.toString(), 'http://cdn.example.test/a.zip');
    expect(_header(cdn.headers, 'Cookie'), isNull);
    expect(_header(cdn.headers, 'X-Tsdmapp-Device'), isNull);
    expect(forum.uri.toString(), 'https://www.tsdm39.com/forum.php?mod=attachment&aid=1');
    expect(_header(forum.headers, 'Cookie'), contains('s_auth=synthetic'));
  });

  test('a client of the app has the guard last', () async {
    final adapter = _Adapter();
    final client = NetClientProvider.buildNoCookie(
      dio: Dio()..httpClientAdapter = adapter,
      cookie: CookieProvider.buildEmpty(),
    );
    await client.get('http://cdn.example.test/a.zip', options: Options(headers: {...session})).run();
    await client.get('http://www.tsdm39.com/forum.php?mod=viewthread&tid=1').run();
    expect(_header(adapter.sent[0].headers, 'Cookie'), isNull);
    expect(adapter.sent[0].headers.keys.where((k) => k.toLowerCase().startsWith('x-tsdmapp-')), isEmpty);
    expect(adapter.sent[1].uri.scheme, 'https');
  });
}
