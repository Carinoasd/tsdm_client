import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

/// Responses recorded from Discuz! X5 while replying with a test account (2026-09-05): the fast-post and the
/// per-floor success hooks, the flood-control rejection, and the per-floor reply window.
typedef _Route = ResponseBody Function(RequestOptions options, Map<String, String> form);

final class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.route);

  final _Route route;
  final requests = <({String method, Uri uri, Map<String, String> form})>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var body = '';
    if (requestStream != null) {
      final bytes = await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      body = utf8.decode(bytes);
    }
    final form = body.isEmpty ? <String, String>{} : Uri.splitQueryString(body);
    requests.add((method: options.method, uri: options.uri, form: form));
    return route(options, form);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _fixture(String name) => ResponseBody.fromString(
  File('test/data/$name').readAsStringSync(),
  200,
  headers: {
    Headers.contentTypeHeader: ['text/xml; charset=utf-8'],
  },
);

ResponseBody _text(String body, {int status = 200}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=utf-8'],
  },
);

const _params = ReplyParameters(fid: '4', tid: '1264975', postTime: '1788597210', formHash: 'XXXXXXXX', subject: '  ');
const _floorAction =
    'forum.php?mod=post&action=reply&fid=4&tid=1264975&reppost=77983792&extra=page%3D1&page=1&usesig=1&replyuid=1113';

void main() {
  late _FakeAdapter adapter;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  void serve(_Route route) {
    adapter = _FakeAdapter(route);
    getIt
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      );
  }

  tearDown(getIt.reset);

  Future<List<ReplyState>> drive(ReplyEvent event) async {
    final bloc = ReplyBloc(replyRepository: const ReplyRepository());
    addTearDown(bloc.close);
    final states = <ReplyState>[];
    final sub = bloc.stream.listen(states.add);
    addTearDown(sub.cancel);
    bloc.add(event);
    for (var i = 0; i < 40 && (states.isEmpty || states.last.status == ReplyStatus.loading); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return states;
  }

  group('reply to thread (fast post)', () {
    test('X5 success hook is accepted and the form matches the fast-post form', () async {
      serve((_, _) => _fixture('reply_success_fastpost_x5.xml'));
      final result = await const ReplyRepository().replyToThread(replyParameters: _params, replyMessage: 'hi').run();
      expect(result.isRight(), isTrue, reason: '$result');
      final req = adapter.requests.single;
      expect(req.method, 'POST');
      expect(req.uri.queryParameters, containsPair('handlekey', 'fastpost'));
      expect(req.uri.queryParameters, containsPair('replysubmit', 'yes'));
      expect(req.uri.queryParameters, containsPair('inajax', '1'));
      expect(req.form, containsPair('message', 'hi'));
      expect(req.form, containsPair('formhash', 'XXXXXXXX'));
      expect(req.form, containsPair('posttime', '1788597210'));
      expect(req.form, containsPair('usesig', '1'));
      expect(req.form, containsPair('subject', '  '));
    });

    test('a reply held for moderation counts as stored', () async {
      serve(
        (_, _) => _text(
          '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[<script type="text/javascript" reload="1"> '
          "if(typeof succeedhandle_fastpost=='function') {succeedhandle_fastpost('forum.php?mod=viewthread&tid=1264975', "
          "'回复需要审核，请等待通过', {'fid':'4','tid':'1264975'});}</script>]]></root>",
        ),
      );
      final result = await const ReplyRepository().replyToThread(replyParameters: _params, replyMessage: 'hi').run();
      expect(result.isRight(), isTrue, reason: '$result');
    });

    test('flood control rejection carries the server reason', () async {
      serve((_, _) => _fixture('reply_error_flood_x5.xml'));
      final result = await const ReplyRepository().replyToThread(replyParameters: _params, replyMessage: 'hi').run();
      expect(result.isLeft(), isTrue);
      final err = result.getLeft().toNullable();
      expect(err, isA<ReplyToThreadResultFailedException>());
      expect(err!.message, contains('10 秒'));
    });

    test('an HTTP failure ends in a failure state with a reason instead of a stuck spinner', () async {
      serve((_, _) => _text('<html><body>503 Service Unavailable</body></html>', status: 503));
      final states = await drive(const ReplyToThreadRequested(replyParameters: _params, replyMessage: 'hi'));
      expect(states.map((s) => s.status), [ReplyStatus.loading, ReplyStatus.failure]);
      expect(states.last.failedReason, 'HTTP 503');
      expect(states.last.networkFailure, isFalse);
    });

    test('no answer at all (offline, DNS, timeout) is flagged as a network failure', () async {
      serve((options, _) => throw DioException.connectionError(requestOptions: options, reason: 'offline'));
      final states = await drive(const ReplyToThreadRequested(replyParameters: _params, replyMessage: 'hi'));
      expect(states.map((s) => s.status), [ReplyStatus.loading, ReplyStatus.failure]);
      expect(states.last.networkFailure, isTrue);
      expect(states.last.failedReason, isEmpty);
    });

    test('a later server rejection clears the network flag', () async {
      serve((options, _) => throw DioException.connectionError(requestOptions: options, reason: 'offline'));
      final bloc = ReplyBloc(replyRepository: const ReplyRepository());
      addTearDown(bloc.close);
      bloc.add(const ReplyToThreadRequested(replyParameters: _params, replyMessage: 'hi'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(bloc.state.networkFailure, isTrue);
      await getIt.reset();
      serve((_, _) => _fixture('reply_error_flood_x5.xml'));
      bloc.add(const ReplyToThreadRequested(replyParameters: _params, replyMessage: 'hi'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(bloc.state.networkFailure, isFalse);
      expect(bloc.state.failedReason, contains('10 秒'));
    });

    test('a server rejection reaches the state as the server text', () async {
      serve((_, _) => _fixture('reply_error_flood_x5.xml'));
      final states = await drive(const ReplyToThreadRequested(replyParameters: _params, replyMessage: 'hi'));
      expect(states.map((s) => s.status), [ReplyStatus.loading, ReplyStatus.failure]);
      expect(states.last.failedReason, contains('10 秒'));
    });
  });

  group('reply to a floor', () {
    test('window inputs are sent back and the X5 success hook is accepted', () async {
      serve(
        (options, _) =>
            options.method == 'GET' ? _fixture('reply_window_x5.xml') : _fixture('reply_success_reply_x5.xml'),
      );
      final result = await const ReplyRepository()
          .replyToPost(replyParameters: _params, replyAction: _floorAction, replyMessage: 'hi')
          .run();
      expect(result.isRight(), isTrue, reason: '$result');
      expect(adapter.requests, hasLength(2));
      final window = adapter.requests.first;
      expect(window.uri.queryParameters, containsPair('ajaxtarget', 'fwin_content_reply'));
      expect(window.uri.queryParameters, containsPair('reppost', '77983792'));
      final post = adapter.requests.last;
      expect(post.method, 'POST');
      expect(post.uri.queryParameters, containsPair('replysubmit', 'yes'));
      expect(post.form, containsPair('formhash', 'XXXXXXXX'));
      expect(post.form, containsPair('handlekey', 'reply'));
      expect(post.form, containsPair('reppid', '77983792'));
      expect(post.form, containsPair('reppost', '77983792'));
      expect(post.form, containsPair('noticeauthor', 'NOTICEAUTHORTOKEN'));
      expect(post.form, containsPair('noticeauthormsg', '測試測試測試測試'));
      expect(post.form, containsPair('replyuid', '1113'));
      expect(post.form, containsPair('usesig', '1'));
      expect(post.form, containsPair('message', 'hi'));
    });

    test('flood control rejection reaches the state as the server text', () async {
      serve(
        (options, _) =>
            options.method == 'GET' ? _fixture('reply_window_x5.xml') : _fixture('reply_error_flood_x5.xml'),
      );
      final states = await drive(
        const ReplyToPostRequested(replyParameters: _params, replyAction: _floorAction, replyMessage: 'hi'),
      );
      expect(states.map((s) => s.status), [ReplyStatus.loading, ReplyStatus.failure]);
      expect(states.last.failedReason, contains('10 秒'));
    });
  });
}
