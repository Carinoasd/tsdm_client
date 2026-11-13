// A fake forum for the tests of plugin 4.0.0 (`tsdmv=4`): answers each request as a function says, records them.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';

/// The fixtures of plugin 4.0.0 recorded on the test forum (cleaned of its traces).
const v4FixtureDir = 'test/data/tsdmapp/v4';

/// Fixture [name] as text.
String v4Raw(String name) => File('$v4FixtureDir/$name').readAsStringSync();

/// Fixture [name] as a JSON object.
Map<String, dynamic> v4Json(String name) => jsonDecode(v4Raw(name)) as Map<String, dynamic>;

/// One answer of the fake forum: [body] (a JSON object or list is sent as JSON, text as a page; an xml text as xml).
final class V4Reply {
  /// Constructor.
  const V4Reply(this.body, {this.status = 200, this.retryAfter});

  /// HTTP 429 of the plugin: the same action of the same account within its interval ([retryAfter] seconds).
  const V4Reply.busy([int this.retryAfter = 0]) : body = const {'ok': 0, 'error': 'busy'}, status = 429;

  /// The body.
  final Object? body;

  /// The HTTP status.
  final int status;

  /// The `retry_after` of a 429.
  final int? retryAfter;
}

/// No answer at all: the network is down.
const v4Offline = V4Reply('offline', status: 0);

/// A forum answering every request by [answer] (null: no answer, a connection error, and noted in [unexpected]).
final class V4Forum implements HttpClientAdapter {
  /// Constructor.
  V4Forum(this.answer);

  /// The answer of a request.
  final V4Reply? Function(RequestOptions options) answer;

  /// Every request, in order.
  final requests = <RequestOptions>[];

  /// The body of each request, in order (empty for a GET).
  final bodies = <String>[];

  /// The requests nobody answered.
  final unexpected = <String>[];

  /// The `action` of each request of the plugin's API, the path and query of the others.
  List<String> get names => [
    for (final r in requests)
      r.uri.queryParameters['id'] == 'tsdmapp:api'
          ? '${r.uri.queryParameters['action']}'
          : '${r.uri.path}?${r.uri.query}',
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    bodies.add(requestStream == null ? '' : utf8.decode(await requestStream.expand((e) => e).toList()));
    final reply = answer(options);
    if (reply == null || identical(reply, v4Offline)) {
      if (reply == null) {
        unexpected.add('${options.method} ${options.uri}');
      }
      throw DioException.connectionError(requestOptions: options, reason: 'no answer');
    }
    final body = reply.body;
    final String text;
    final String type;
    if (body is Map || body is List) {
      text = jsonEncode(
        reply.status == 429 ? {...(body! as Map), 'retry_after': reply.retryAfter ?? 1} : body,
      );
      type = 'application/json';
    } else {
      text = '$body';
      type = text.trimLeft().startsWith('<?xml') ? 'text/xml' : 'text/html';
    }
    return ResponseBody.fromString(
      text,
      reply.status,
      headers: {
        Headers.contentTypeHeader: ['$type; charset=utf-8'],
        if (reply.status == 429) 'retry-after': ['${reply.retryAfter ?? 1}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A client of [forum] without cookies.
NetClientProvider v4Client(V4Forum forum) =>
    NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

/// Know the plugin as the `status` answer [status] tells it (the recorded `status` of 4.0.0 by default).
void knowV4Status([Map<String, dynamic>? status]) =>
    TsdmAppApi.pluginInfo.value = TsdmAppPluginInfo.fromAnswer(status ?? v4Json('status_v400.json'));

/// The recorded `status` of 4.0.0 with [changes] applied (a value of null removes the key).
Map<String, dynamic> v4Status([Map<String, Object?> changes = const {}]) {
  final status = v4Json('status_v400.json');
  for (final MapEntry(:key, :value) in changes.entries) {
    if (value == null) {
      status.remove(key);
    } else {
      status[key] = value;
    }
  }
  return status;
}

/// Register what a client of the fake forum needs (in `setUpAll`): a silent logger, the error saver, an empty cookie
/// provider; reassignment allowed so a test can make a fake forum the app's default client ([useV4Forum]).
void registerV4TestServices() {
  talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  getIt.allowReassignment = true;
  getIt
    ..registerSingleton<NetErrorSaver>(NetErrorSaver())
    ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
}

/// Undo [registerV4TestServices] (in `tearDownAll`).
Future<void> resetV4TestServices() async {
  await getIt.reset();
  getIt.allowReassignment = false;
}

/// Make [forum] the forum of the app's default client.
void useV4Forum(V4Forum forum) => getIt.registerFactory<NetClientProvider>(() => v4Client(forum));
