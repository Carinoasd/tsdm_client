/// An audio attachment failed to play ("加载失败") when played more than a few seconds after its thread loaded, on
/// Android: `unexpected end of stream`, again at each retry.
///
/// PR #440 follows the redirects of an audio attachment hop by hop, and marked each request as a single attempt
/// ([singleAttemptHttpRequestKey]) because that mark was the only way to ask the Kotlin client for no redirect. A
/// single attempt is not sent again when it fails on the transport: a request written into a connection kept for reuse
/// that the server has closed meanwhile (Apache closes an idle one after 5 seconds; OkHttp checks a kept connection
/// closely only before a request with a body) failed for good, while the forum never saw it.
///
/// Now the Kotlin client reads [Options.followRedirects] itself: a read that follows no redirect (an audio attachment,
/// the picture of an attachment with the session) goes to a client that follows none but sends a read again on a new
/// connection; a single attempt (a write) is written into a new connection only (`HttpClientTest.kt`).
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_fetcher.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider_android.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('kzs.th000.tsdm_client/httpChannel');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'statusCode': 302,
        'headers': <String, List<String>>{
          'location': ['https://cdn.example.test/a.mp3'],
        },
        'body': Uint8List(0),
        'isRedirect': true,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Dio kotlinDio() => Dio()..httpClientAdapter = KotlinHttpClientAdapter(KotlinHttpClient(android: true));

  test('an audio attachment asks the Kotlin client for no redirect, and is not a single attempt', () async {
    final resp = await kotlinDio().get<dynamic>(
      'https://www.tsdm39.com/forum.php?mod=attachment&aid=x',
      options: audioAttachmentRequestOptions(),
    );
    expect(resp.statusCode, 302);
    final args = calls.single.arguments as Map;
    expect(args['followRedirects'], isFalse);
    expect(args['singleAttempt'], isFalse);
  });

  test('a GET following redirects as usual says nothing of them', () async {
    await kotlinDio().get<dynamic>(
      'https://www.tsdm39.com/forum.php',
      options: Options(validateStatus: (s) => s != null && s < HttpStatus.badRequest),
    );
    final args = calls.single.arguments as Map;
    expect(args.containsKey('followRedirects'), isFalse);
    expect(args['singleAttempt'], isFalse);
  });

  test('a single attempt stays one', () async {
    await kotlinDio().get<dynamic>(
      'https://www.tsdm39.com/forum.php?mod=misc&action=debatevote',
      options: Options(
        followRedirects: false,
        validateStatus: (s) => s != null && s < HttpStatus.badRequest,
        extra: {singleAttemptHttpRequestKey: true},
      ),
    );
    final args = calls.single.arguments as Map;
    expect(args['singleAttempt'], isTrue);
    expect(args['followRedirects'], isFalse);
  });

  test('the Kotlin side reads the flag (the Kotlin source; its behaviour is tested in HttpClientTest.kt)', () {
    final activity = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/MainActivity.kt').readAsStringSync();
    expect(activity, contains('call.argument<Boolean>("followRedirects")'));
  });
}
