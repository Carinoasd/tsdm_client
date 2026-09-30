import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';

/// Answers every request with a 404, the way a plugin that is disabled or a page that is gone does.
///
/// The interceptors of the client stay in place: the point of this test is what the error handler does with the answer.
final class _MissingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream, Future<void>? cancel) async =>
      ResponseBody.fromString('', 404);

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() {
    final dio = Dio()..httpClientAdapter = _MissingAdapter();
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<NetClientProvider>(
        NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty()),
      );
  });

  tearDown(getIt.reset);

  test('a 404 that means the plugin has no battle stays out of the error banner', () async {
    await getIt
        .get<NetClientProvider>()
        .get('https://x/plugin.php?id=pokemon:pokemon&endpoint=battle&action=recover&mobile=no')
        .run();

    expect(getIt.get<NetErrorSaver>().error(), isNull);
  });

  test('a plugin 404 for any other call still reports', () async {
    await getIt
        .get<NetClientProvider>()
        .get('https://x/plugin.php?id=pokemon:pokemon&endpoint=pokemon&action=list&mobile=no')
        .run();

    expect(getIt.get<NetErrorSaver>().error(), isNotNull);
  });

  test('a forum page that is gone still reports', () async {
    await getIt.get<NetClientProvider>().get('https://x/forum.php?mod=viewthread&tid=1').run();

    expect(getIt.get<NetErrorSaver>().error(), isNotNull);
  });
}
