import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/post_report/cubit/post_report_cubit.dart';
import 'package:tsdm_client/features/post_report/models/post_report.dart';
import 'package:tsdm_client/features/post_report/repository/post_report_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider_android.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';

import 'fixtures/post_report_fixtures.dart';

/// A synthetic forum answering the report flow. Records every request; never talks to the network.
class _Forum {
  _Forum({String? page, String? form, FutureOr<PostReportResponse> Function(Map<String, String>)? answer})
    : page = page ?? threadPage(),
      form = form ?? reportFormAjax(),
      answer = answer ?? ((_) => PostReportResponse(200, successAjax()));

  String page;
  String form;
  FutureOr<PostReportResponse> Function(Map<String, String>) answer;

  /// Completes page reads when set; reads wait on it.
  Completer<void>? holdReads;

  final gets = <(Uri, bool)>[];
  final posts = <(Uri, Map<String, String>)>[];

  PostReportRepository repository() => PostReportRepository(
    get: (url, {required ajax}) async {
      gets.add((url, ajax));
      if (holdReads case final hold?) {
        await hold.future;
      }
      return PostReportResponse(200, url.path == '/misc.php' ? form : page);
    },
    post: (url, body) async {
      posts.add((url, body));
      return answer(body);
    },
  );
}

PostReportCubit _cubit(_Forum forum, {int? Function()? uid}) =>
    PostReportCubit(target: reportTarget, currentUid: uid ?? () => viewerUid, repository: forum.repository);

Future<PostReportCubit> _ready(_Forum forum, {int? Function()? uid}) async {
  final cubit = _cubit(forum, uid: uid);
  addTearDown(cubit.close);
  await cubit.load();
  expect(cubit.state.phase, PostReportPhase.ready);
  return cubit;
}

class _CaptureAdapter implements HttpClientAdapter {
  _CaptureAdapter(this.reply);

  final String reply;
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
      reply,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/xml; charset=utf-8'],
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

  group('repository', () {
    test('prepare reads the full floor page first, then the ajax dialog; sends nothing', () async {
      final forum = _Forum();
      final form = await forum.repository().prepare(reportTarget, uid: viewerUid);
      expect(form.reasons, hasLength(5));
      expect(forum.posts, isEmpty);
      expect(forum.gets, hasLength(2));
      expect(forum.gets[0].$1, reportTarget.floorUrl);
      expect(forum.gets[0].$2, isFalse);
      final ajax = forum.gets[1].$1;
      expect(forum.gets[1].$2, isTrue);
      expect(ajax.host, 'www.tsdm39.com');
      expect(ajax.scheme, 'https');
      expect(ajax.path, '/misc.php');
      expect(ajax.queryParameters, {
        'mod': 'report',
        'rtype': 'post',
        'rid': '$reportPid',
        'tid': '$reportTid',
        'fid': '$reportFid',
        'inajax': '1',
        'infloat': 'yes',
        'handlekey': 'miscreport$reportPid',
      });
    });

    test('another account, a guest page or a floor without the link stop before the form', () async {
      final cases = <String, (String, PostReportProblem)>{
        'page of another account': (threadPage(uid: otherUid), PostReportProblem.accountChanged),
        'own post of the viewer': (threadPage(floors: postFloor(author: viewerUid)), PostReportProblem.noPermission),
        'link gone': (threadPage(floors: postFloor(operations: '')), PostReportProblem.noPermission),
        'floor gone': (threadPage(floors: postFloor(pid: 1)), PostReportProblem.noPermission),
        'other forum': (threadPage(fid: 1), PostReportProblem.noPermission),
        'guest': (
          '<html><body><form id="lsform"></form><div id="messagelogin"></div></body></html>',
          PostReportProblem.notLoggedIn,
        ),
      };
      for (final MapEntry(key: name, value: (page, problem)) in cases.entries) {
        final forum = _Forum(page: page);
        await expectLater(
          forum.repository().prepare(reportTarget, uid: viewerUid),
          throwsA(isA<PostReportFailure>().having((e) => e.problem, 'problem', problem)),
          reason: name,
        );
        expect(forum.gets, hasLength(1), reason: name);
        expect(forum.posts, isEmpty, reason: name);
      }
    });

    test('a target of account A is never used by account B, not even read', () async {
      final forum = _Forum();
      await expectLater(
        forum.repository().prepare(reportTarget, uid: otherUid),
        throwsA(isA<PostReportFailure>().having((e) => e.problem, 'problem', PostReportProblem.accountChanged)),
      );
      expect(forum.gets, isEmpty);
    });

    test('submit posts the served fields once to the canonical action', () async {
      final forum = _Forum();
      final repo = forum.repository();
      final form = await repo.prepare(reportTarget, uid: viewerUid);
      final outcome = await repo.submit(form, '违规内容');
      expect(outcome, isA<PostReportSucceeded>());
      expect(forum.posts, hasLength(1));
      final (url, body) = forum.posts.single;
      expect(url.toString(), 'https://www.tsdm39.com/misc.php?mod=report');
      expect(body, {for (final (k, v) in defaultHidden) k: v, 'message': '违规内容'});
      expect(body.containsKey('tid'), isFalse);
    });

    test('a failed or unreadable request is unknown and is not repeated', () async {
      for (final answer in <FutureOr<PostReportResponse> Function(Map<String, String>)>[
        (_) => throw Exception('connection reset'),
        (_) => const PostReportResponse(500, ''),
        (_) => const PostReportResponse(200, ''),
        (_) => const PostReportResponse(302, ''),
      ]) {
        final forum = _Forum(answer: answer);
        final repo = forum.repository();
        final form = await repo.prepare(reportTarget, uid: viewerUid);
        expect(await repo.submit(form, 'x'), isA<PostReportUnknown>());
        expect(forum.posts, hasLength(1));
      }
    });

    test('network transport: one attempt, no redirects, string form map, ajax read header', () async {
      final adapter = _CaptureAdapter(successAjax());
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final client = NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty());
      final repo = PostReportRepository.network(client);
      final form = parsePostReportForm(reportFormAjax(), target: reportTarget);
      final outcome = await repo.submit(form, '其他 & 说明 + 😀');
      expect(outcome, isA<PostReportSucceeded>());
      expect(adapter.requests, hasLength(1));
      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.followRedirects, isFalse);
      expect(request.extra[singleAttemptHttpRequestKey], isTrue);
      expect(request.data, isA<Map<String, String>>());
      final decoded = Uri.splitQueryString(adapter.bodies.single);
      expect(decoded['message'], '其他 & 说明 + 😀');
      expect(decoded['url'], '');
      expect(decoded.containsKey('tid'), isFalse);
      expect(decoded.containsKey(singleAttemptHttpRequestKey), isFalse);

      await repo.get(reportTarget.reportUrl, ajax: true);
      expect(adapter.requests.last.method, 'GET');
      expect(adapter.requests.last.headers['X-Requested-With'], 'XMLHttpRequest');
    });
  });

  group('controller', () {
    test('explicit submit sends once and reports success', () async {
      final forum = _Forum();
      final cubit = await _ready(forum);
      await cubit.submit(generation: cubit.generation, reasonIndex: 1, custom: '');
      expect(forum.posts, hasLength(1));
      expect(forum.posts.single.$2['message'], '违规内容');
      expect(cubit.state.phase, PostReportPhase.succeeded);
      expect(cubit.state.message, '合成的成功提示');
      // Done: a later confirmation sends nothing.
      await cubit.submit(generation: cubit.generation, reasonIndex: 1, custom: '');
      expect(forum.posts, hasLength(1));
    });

    test('the custom choice sends the typed text; empty or over-limit text sends nothing', () async {
      final forum = _Forum();
      final cubit = await _ready(forum);
      await cubit.submit(generation: cubit.generation, reasonIndex: 4, custom: '   ');
      await cubit.submit(generation: cubit.generation, reasonIndex: 4, custom: '中' * 101);
      expect(forum.gets, hasLength(2), reason: 'only the initial load');
      expect(forum.posts, isEmpty);
      await cubit.submit(generation: cubit.generation, reasonIndex: 4, custom: ' 合成的说明 ');
      expect(forum.posts.single.$2['message'], '合成的说明');
    });

    test('double confirmation sends one request', () async {
      final forum = _Forum();
      final cubit = await _ready(forum);
      final g = cubit.generation;
      await Future.wait([
        cubit.submit(generation: g, reasonIndex: 0, custom: ''),
        cubit.submit(generation: g, reasonIndex: 0, custom: ''),
        cubit.submit(generation: g, reasonIndex: 2, custom: ''),
      ]);
      expect(forum.posts, hasLength(1));
    });

    test('unknown result closes sending for good', () async {
      final forum = _Forum(answer: (_) => throw Exception('timeout'));
      final cubit = await _ready(forum);
      await cubit.submit(generation: cubit.generation, reasonIndex: 0, custom: '');
      expect(cubit.state.phase, PostReportPhase.unknown);
      expect(cubit.canConfirm(cubit.generation), isFalse);
      await cubit.submit(generation: cubit.generation, reasonIndex: 0, custom: '');
      expect(forum.posts, hasLength(1));
    });

    test('explicit refusal keeps the dialog usable; only another explicit submit sends again', () async {
      final forum = _Forum(answer: (_) => PostReportResponse(200, rejectionAjax()));
      final cubit = await _ready(forum);
      await cubit.submit(generation: cubit.generation, reasonIndex: 0, custom: '');
      expect(cubit.state.phase, PostReportPhase.rejected);
      expect(cubit.state.message, '合成的拒绝提示');
      expect(forum.posts, hasLength(1));
      expect(cubit.canConfirm(cubit.generation), isTrue);
      await cubit.submit(generation: cubit.generation, reasonIndex: 0, custom: '');
      expect(forum.posts, hasLength(2));
    });

    test('the old card of account A can not report after switching to B', () async {
      var uid = viewerUid;
      final forum = _Forum();
      final cubit = _cubit(forum, uid: () => uid);
      addTearDown(cubit.close);
      uid = otherUid;
      await cubit.load();
      expect(cubit.state.phase, PostReportPhase.unavailable);
      expect(cubit.state.problem, PostReportProblem.accountChanged);
      await cubit.submit(generation: cubit.generation, reasonIndex: 0, custom: '');
      expect(forum.gets, isEmpty);
      expect(forum.posts, isEmpty);
    });

    test('A → B → A: a confirmation from before the switch sends nothing', () async {
      var uid = viewerUid;
      final forum = _Forum();
      final cubit = await _ready(forum, uid: () => uid);
      final g = cubit.generation;
      uid = otherUid;
      cubit.invalidate();
      uid = viewerUid;
      expect(cubit.canConfirm(g), isFalse);
      await cubit.submit(generation: g, reasonIndex: 0, custom: '');
      await cubit.submit(generation: cubit.generation, reasonIndex: 0, custom: '');
      expect(forum.posts, isEmpty);
      expect(cubit.state.phase, PostReportPhase.closed);
    });

    test('account switch while the fresh check is pending: no request is sent', () async {
      var uid = viewerUid;
      final forum = _Forum();
      final cubit = await _ready(forum, uid: () => uid);
      forum.holdReads = Completer<void>();
      final pending = cubit.submit(generation: cubit.generation, reasonIndex: 0, custom: '');
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.phase, PostReportPhase.submitting);
      uid = otherUid;
      cubit.invalidate();
      uid = viewerUid;
      forum.holdReads!.complete();
      await pending;
      expect(forum.posts, isEmpty);
      expect(cubit.state.phase, PostReportPhase.closed);
    });

    test('closing while the form is loading drops the late answer', () async {
      final forum = _Forum()..holdReads = Completer<void>();
      final cubit = _cubit(forum);
      addTearDown(cubit.close);
      final pending = cubit.load();
      cubit.invalidate();
      forum.holdReads!.complete();
      await pending;
      expect(cubit.state.phase, PostReportPhase.closed);
      await cubit.submit(generation: cubit.generation, reasonIndex: 0, custom: '');
      expect(forum.posts, isEmpty);
    });

    test('a late answer after an account switch is not shown', () async {
      var uid = viewerUid;
      final answer = Completer<PostReportResponse>();
      final forum = _Forum(answer: (_) => answer.future);
      final cubit = await _ready(forum, uid: () => uid);
      final pending = cubit.submit(generation: cubit.generation, reasonIndex: 0, custom: '');
      await Future<void>.delayed(Duration.zero);
      expect(forum.posts, hasLength(1));
      uid = otherUid;
      cubit.invalidate();
      answer.complete(PostReportResponse(200, successAjax()));
      await pending;
      expect(cubit.state.phase, PostReportPhase.closed);
      expect(forum.posts, hasLength(1));
    });

    test('a failed fresh check sends nothing and keeps the dialog', () async {
      final forum = _Forum();
      final cubit = await _ready(forum);
      forum.page = threadPage(floors: postFloor(operations: ''));
      await cubit.submit(generation: cubit.generation, reasonIndex: 0, custom: '');
      expect(forum.posts, isEmpty);
      expect(cubit.state.phase, PostReportPhase.notSent);
      expect(cubit.state.problem, PostReportProblem.noPermission);
      expect(cubit.state.form, isNotNull);
    });

    test('changed reason choices send nothing and ask again', () async {
      final forum = _Forum();
      final cubit = await _ready(forum);
      forum.form = reportFormAjax(script: "var reasons = ['违规内容', '广告垃圾', '其他'];");
      await cubit.submit(generation: cubit.generation, reasonIndex: 0, custom: '');
      expect(forum.posts, isEmpty);
      expect(cubit.state.phase, PostReportPhase.ready);
      expect(cubit.state.formChanged, isTrue);
      expect(cubit.state.form!.reasons, ['违规内容', '广告垃圾', '其他']);
    });
  });
}
