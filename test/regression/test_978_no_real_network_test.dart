// The global guard of `test/flutter_test_config.dart` (`test/network_guard.dart`): no test reaches the real network.
//
// PR #408 had a test that built a repository without the injected `currentUserClientFactory`; it sent an anonymous
// read-only request to the live forum, locally and on CI. With the guard, such a request throws right away and the
// test fails at its end even when the code under test swallows the error.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../network_guard.dart';

const _forum = 'https://www.tsdm39.com/forum.php';

Matcher _blockedTo(String host) => isA<RealNetworkBlocked>().having((e) => e.target, 'target', contains(host));

void main() {
  group('blocked', () {
    test('dart:io HttpClient', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      await expectLater(client.getUrl(Uri.parse(_forum)), throwsA(_blockedTo('www.tsdm39.com:443')));
      expect(takeBlockedConnections(), [contains(_forum)]);
    });

    test('dio with the IO adapter, the message says what to do', () async {
      final dio = Dio()..httpClientAdapter = IOHttpClientAdapter();
      Object? error;
      try {
        await dio.get<String>(_forum);
      } on DioException catch (e) {
        error = e.error;
      }
      expect(error, _blockedTo('www.tsdm39.com'));
      expect('$error', allOf(contains('測試不得連真實網路'), contains('請注入假 client')));
      takeBlockedConnections();
    });

    test('through a proxy: what counts is the proxy', () async {
      final client = HttpClient()..findProxy = (_) => 'PROXY proxy.example:8080';
      addTearDown(() => client.close(force: true));
      await expectLater(client.getUrl(Uri.parse('http://forum.test/forum.php')), throwsA(_blockedTo('proxy.example')));
      takeBlockedConnections();
    });

    test('raw sockets', () async {
      await expectLater(Socket.connect('www.tsdm39.com', 80), throwsA(_blockedTo('www.tsdm39.com:80')));
      await expectLater(Socket.startConnect('www.tsdm39.com', 443), throwsA(_blockedTo('www.tsdm39.com:443')));
      expect(takeBlockedConnections(), hasLength(2));
    });

    test('loopback too, unless the test asks for it', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      await expectLater(
        client.getUrl(Uri.parse('http://${InternetAddress.loopbackIPv4.address}:${server.port}/')),
        throwsA(_blockedTo('${InternetAddress.loopbackIPv4.address}:${server.port}')),
      );
      takeBlockedConnections();
    });

    test('a swallowed error is still on record (the global tearDown fails the test with it)', () async {
      final dio = Dio()..httpClientAdapter = IOHttpClientAdapter();
      await dio.get<String>(_forum).then<void>((_) {}, onError: (_) {});
      expect(blockedConnections, [contains(_forum)]);
      takeBlockedConnections();
    });

    testWidgets('in widget tests as well, where the binding swaps in its own HttpClient mock', (tester) async {
      expect(HttpOverrides.current, isNotNull);
      final error = await tester.runAsync(() async {
        final client = HttpClient();
        try {
          await client.getUrl(Uri.parse(_forum));
          return null;
        } on Object catch (e) {
          return e;
        } finally {
          client.close(force: true);
        }
      });
      expect(error, _blockedTo('www.tsdm39.com'));
      takeBlockedConnections();
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('allowed', () {
    test('a loopback server of the test, after allowLoopbackNetwork', () async {
      allowLoopbackNetwork();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write('pong ${request.uri.path}');
        await request.response.close();
      });
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(
        Uri.parse('http://${InternetAddress.loopbackIPv4.address}:${server.port}/ping'),
      )).close();
      expect(await response.transform(utf8.decoder).join(), 'pong /ping');
      expect(blockedConnections, isEmpty);
    });

    test('the permission does not carry over to the next test', () async {
      await expectLater(Socket.startConnect(InternetAddress.loopbackIPv4, 9), throwsA(isA<RealNetworkBlocked>()));
      takeBlockedConnections();
    });
  });
}
