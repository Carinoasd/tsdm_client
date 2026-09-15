import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';

/// The antitheft interceptor solves the challenge for reads only. A form POST answered with the challenge page is
/// reported as a typed error and never copied: the challenge may be the final page of the redirect after the form was
/// accepted, and resending the body would submit it twice (follow-up of GitHub #41).
class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final String Function(RequestOptions options) respond;
  final requests = <RequestOptions>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    // Drain the body so a replayed form would show up as a second request.
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    return ResponseBody.fromString(
      respond(options),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }
}

String _challenge(String tid) => File('test/data/antitheft/$tid.html').readAsStringSync();

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.registerSingleton<NetErrorSaver>(NetErrorSaver());
  });
  tearDownAll(getIt.reset);

  (NetClientProvider, _Adapter) build(String Function(RequestOptions options) respond) {
    final adapter = _Adapter(respond);
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    return (NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty()), adapter);
  }

  test('a GET answered with the challenge is resent once with the sign', () async {
    const tid = '1255530';
    final (client, adapter) = build(
      (options) => options.uri.queryParameters.containsKey('_dsign') ? '<html>thread</html>' : _challenge(tid),
    );
    final result = await client.get('https://www.tsdm39.com/forum.php?mod=viewthread&tid=$tid').run();
    expect(result.isRight(), isTrue);
    expect(result.getOrElse((_) => throw StateError('unreachable')).data, '<html>thread</html>');
    expect(adapter.requests.map((r) => r.method), ['GET', 'GET']);
    expect(adapter.requests.last.uri.queryParameters['_dsign'], '7a76ac9f');
  });

  test('a form POST answered with the challenge is not replayed and fails with a typed error', () async {
    const tid = '1255531';
    final (client, adapter) = build((_) => _challenge(tid));
    final result = await client
        .postForm(
          'https://www.tsdm39.com/forum.php?mod=post&action=reply&tid=$tid',
          data: {'formhash': 'XXXXXXXX', 'message': 'hi'},
        )
        .run();
    expect(adapter.requests, hasLength(1), reason: 'the form body must never be sent twice');
    expect(adapter.requests.single.method, 'POST');
    switch (result) {
      case Left(:final value):
        expect(value, isA<AntitheftChallengedRequestException>());
        final error = value as AntitheftChallengedRequestException;
        expect(error.method, 'POST');
        expect(error.url, contains('tid=$tid'));
      case Right():
        fail('a challenge page must not be handed to the caller as if it were the result');
    }
  });

  test('a rejected POST does not stop a later GET of the same thread from solving the challenge', () async {
    const tid = '1255532';
    var posted = false;
    final (client, adapter) = build((options) {
      if (options.method == 'POST') {
        posted = true;
        return _challenge(tid);
      }
      return posted && options.uri.queryParameters.containsKey('_dsign') ? '<html>thread</html>' : _challenge(tid);
    });
    final post = await client
        .postForm('https://www.tsdm39.com/forum.php?mod=misc&action=votepoll&tid=$tid', data: {'formhash': 'XXXXXXXX'})
        .run();
    expect(post.isLeft(), isTrue);
    final get = await client.get('https://www.tsdm39.com/forum.php?mod=viewthread&tid=$tid').run();
    expect(get.isRight(), isTrue);
    expect(adapter.requests.map((r) => r.method), ['POST', 'GET', 'GET']);
    expect(adapter.requests.last.uri.queryParameters['_dsign'], '481a174c');
    expect(adapter.requests.where((r) => r.method == 'GET').every((r) => r.data == null), isTrue);
  });
}
