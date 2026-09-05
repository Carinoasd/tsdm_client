import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';

/// Discuz! X5 answers permission failures on attachments with HTTP 200 and an HTML 提示信息 page, and serves real
/// attachments with a bare `image` content type.
NetClientProvider _client(Uint8List body, String contentType) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response<Uint8List>(
            requestOptions: options,
            statusCode: 200,
            data: body,
            headers: Headers.fromMap({Headers.contentTypeHeader: [contentType]}),
          ),
        ),
      ),
    );
  return NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty());
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.registerSingleton<NetErrorSaver>(NetErrorSaver());
  });
  tearDownAll(getIt.reset);

  test('an HTML page answered to an image request is rejected with the server message', () async {
    final html = File('test/data/attachment_payto_x5.html').readAsBytesSync();
    final result = await _client(html, 'text/html; charset=utf-8')
        .getImage('https://www.tsdm39.com/forum.php?mod=attachment&aid=x')
        .run();
    expect(result.isLeft(), isTrue);
    final error = result.getLeft().toNullable();
    expect(error, isA<ImageResponseNotImageException>());
    expect((error! as ImageResponseNotImageException).message, contains('付费'));
    expect((error as ImageResponseNotImageException).message, isNot(contains('setTimeout')));
  });

  test('image bytes with a bare "image" content type are accepted', () async {
    final jpeg = File('test/data/attachment_head.jpg').readAsBytesSync();
    final result = await _client(jpeg, 'image').getImage('https://www.tsdm39.com/forum.php?mod=attachment&aid=y').run();
    expect(result.isRight(), isTrue, reason: '$result');
  });
}
