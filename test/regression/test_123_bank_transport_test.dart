import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/bank/models/bank_data.dart';
import 'package:tsdm_client/features/bank/repository/bank_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider_android.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:universal_html/parsing.dart';

BankTransactionForm _form() => parseBankSavings(
  parseHtmlDocument('''
<div class="tbn"><ul><li><font>Test coins:</font><span><b>800</b></span>(银行货币)</li></ul></div>
<table id="ttt"><tr><th><h2>活期储蓄</h2></th></tr>
<tr><td class="footoperation">您当前的存款金额为 100 ，活期利率为1‰。</td></tr>
<tr><td><form method="post" action="plugin.php?id=bank_ane:bank">
<input type="hidden" name="bankid" value="1"><input type="hidden" name="action" value="cur">
<input type="hidden" name="formhash" value="synthetic-token"><input type="text" name="banknum">
<input type="radio" name="op" value="in"><input type="radio" name="op" value="out">
<input type="password" name="bankpass"><button type="submit" name="banksubmit" value="true">提交</button>
</form></td></tr></table>
'''),
  bankId: 1,
).form!;

class _CaptureAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final bodies = <String>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    bodies.add(requestStream == null ? '' : utf8.decode(await requestStream.expand((chunk) => chunk).toList()));
    return ResponseBody.fromString(
      'Result unknown',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.registerSingleton<NetErrorSaver>(NetErrorSaver());
  });
  tearDownAll(getIt.reset);

  test('bank repository requests one attempt without leaking transport metadata into the encoded form', () async {
    final adapter = _CaptureAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty());
    await BankRepository.network(client).submit(_form(), BankOperation.deposit, '12', 'synthetic secret + & 測試');
    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.followRedirects, isFalse);
    expect(request.extra[singleAttemptHttpRequestKey], isTrue);
    expect(request.data, isA<Map<String, String>>(), reason: 'Android sends this map through its method channel');
    final decoded = Uri.splitQueryString(adapter.bodies.single);
    expect(decoded, request.data);
    expect(decoded['bankpass'], 'synthetic secret + & 測試');
    expect(decoded['banknum'], '12');
    expect(decoded['op'], 'in');
    expect(decoded.containsKey(singleAttemptHttpRequestKey), isFalse);
    expect(request.headers.containsKey(singleAttemptHttpRequestKey), isFalse);
  });

  test('ordinary form requests retain their previous redirect behavior', () async {
    final adapter = _CaptureAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final client = NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty());
    await client.postForm('https://www.tsdm39.com/plugin.php', data: <String, String>{'field': 'value'}).run();
    expect(adapter.requests.single.followRedirects, isTrue);
    expect(adapter.requests.single.extra.containsKey(singleAttemptHttpRequestKey), isFalse);
    expect(Uri.splitQueryString(adapter.bodies.single), {'field': 'value'});
  });

  for (final status in [303, 307, 308]) {
    test('desktop transport does not follow a $status response to a single-attempt form', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      final subscription = server.listen((request) async {
        requests++;
        await request.drain<void>();
        request.response.statusCode = status;
        request.response.headers.set(HttpHeaders.locationHeader, '/replay');
        await request.response.close();
      });
      addTearDown(subscription.cancel);
      final dio = Dio();
      addTearDown(dio.close);
      final client = NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty());
      final result = await client
          .postForm(
            'http://127.0.0.1:${server.port}/bank',
            data: <String, String>{'banknum': '12', 'bankpass': 'synthetic-secret'},
            singleAttempt: true,
          )
          .run();
      expect(result.isLeft(), isTrue, reason: 'A redirect is not accepted as a successful transaction');
      expect(requests, 1);
    });
  }
}
