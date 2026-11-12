/// The reply, the quick reply and the new poll decide their outcome from the forum's language key, not its words.
///
/// The forum's app API (plugin 2.6.0) answers a write with `message_key`, the key Discuz! showed its message with.
/// The readers of the reply still compared the words "回复发布成功", "回复需要审核" (and the poll "需要审核") for a
/// message answer, which a change of the forum's language pack broke. Now a key of a stored reply
/// (`post_reply_succeed`, `post_reply_mod_succeed`) or of a created thread (`post_newthread_succeed`,
/// `post_newthread_mod_succeed`) decides whatever the words; a refusal's key (`post_flood_ctrl`, the captcha's
/// `submit_seccode_invalid`) is a refusal. An answer without a key (another plugin's own words, such as a reply merged
/// into the previous floor) and the forum's own answer without the API are read as before. The fixtures
/// `write_by_key/*.json` are the test forum's real answers (2026-11-13; uid, form hash and time replaced).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/repository/poll_create_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

import 'poll_fixtures.dart';

const _dir = 'test/data/tsdmapp/write_by_key';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// A forum answering every request with [body] (a JSON object, or the forum's own text).
final class _Forum implements HttpClientAdapter {
  _Forum(this.body);

  final Object body;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final b = body;
    return ResponseBody.fromString(
      b is String ? b : jsonEncode(b),
      200,
      headers: {
        Headers.contentTypeHeader: [if (b is String) 'text/xml; charset=utf-8' else 'application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _reply = ReplyParameters(fid: '25', tid: '9202864', postTime: '1700000000', formHash: 'f1f2f3f4', subject: '');

/// The quick reply posted to a forum answering [body].
Future<Either<AppException, PostedReply>> _quickReply(Object body) {
  final forum = _Forum(body);
  getIt.registerFactory<NetClientProvider>(
    () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
  );
  return const ReplyRepository().replyToThread(replyParameters: _reply, replyMessage: 'hi').run();
}

/// The forum's AJAX answer of the quick reply: the success hook with [text], or the error hook.
String _ajax(String text, {bool succeed = true}) {
  final call = succeed
      ? "if(typeof succeedhandle_fastpost=='function') {succeedhandle_fastpost('forum.php?mod=viewthread&tid=9202864&pid=22422&page=6', '$text', {});}"
      : "if(typeof errorhandle_fastpost=='function') {errorhandle_fastpost('$text', {});}";
  return '<?xml version="1.0" encoding="utf-8"?>\n'
      '<root><![CDATA[<script type="text/javascript" reload="1">$call</script>]]></root>';
}

const _draft = PollDraft(
  subject: 'Synthetic poll',
  message: '',
  options: ['Alpha', 'Beta'],
  maxChoices: '1',
  expiry: '',
  visibleAfterVote: false,
  publicVoters: false,
  threadType: null,
  extraOptions: [],
);

/// The poll posted to a forum answering the post with [data]; the thread page of [thread] (the verification GET)
/// fails when null. The GETs after the form are recorded in [gets].
Future<PollCreateResult> _poll(Object? data, {List<String>? gets, String? thread}) async {
  final repository = PollCreateRepository.withTransport(
    currentUid: () => 1000,
    getPage: (url) async {
      if (url.contains('viewthread')) {
        gets?.add(url);
        return thread == null ? left(HttpRequestFailedException(500)) : right(pollResponse(thread));
      }
      return right(pollResponse(pollForm()));
    },
    sendForm: (url, body) async =>
        right(Response<dynamic>(requestOptions: RequestOptions(), data: data, statusCode: 200)),
  );
  final form = (await repository.fetchForm('4')).form!;
  return repository.submit(form, validatePollDraft(_draft, form).submission!);
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(TsdmAppApi.reset);
  tearDown(() async {
    if (getIt.isRegistered<NetClientProvider>()) {
      await getIt.unregister<NetClientProvider>();
    }
  });

  group('the reply', () {
    test('the real answers: published and awaiting moderation are stored, where they landed', () async {
      final ok = await _quickReply(_fixture('reply_ok'));
      expect(ok.getRight().toNullable(), (pid: '22422', page: 6));
      final redirect = await _quickReply(_fixture('reply_redirect'));
      expect(redirect.getRight().toNullable(), (pid: '22423', page: 6));
      final moderated = await _quickReply(_fixture('reply_mod'));
      expect(moderated.isRight(), isTrue, reason: 'awaiting moderation is stored');
    });

    test('a stored key decides, whatever the words and the class of the message', () async {
      for (final name in ['reply_ok', 'reply_mod']) {
        for (final changes in <Map<String, Object?>>[
          {'kind': 'message', 'message': 'Reply posted.', 'alert': 'info'},
          {'kind': 'message', 'message': '已送出', 'alert': '', 'ok': 0},
          {'kind': 'handle', 'message': '', 'alert': 'error', 'ok': 0},
        ]) {
          final result = await _quickReply({..._fixture(name), ...changes});
          expect(result.isRight(), isTrue, reason: '$name $changes');
        }
      }
    });

    test('a stored key asking to log in is no reply', () async {
      final result = await _quickReply({..._fixture('reply_ok'), 'login': 1, 'ok': 0});
      expect(result.getLeft().toNullable(), isA<ReplyToThreadResultFailedException>());
    });

    test('a refusal key is a refusal with its words, even with the words of a success', () async {
      final flood = await _quickReply(_fixture('reply_flood'));
      expect(
        flood.getLeft().toNullable(),
        isA<ReplyToThreadResultFailedException>().having((e) => e.message, 'message', contains('15 秒')),
      );
      final masked = await _quickReply({..._fixture('reply_flood'), 'kind': 'message', 'message': '回复发布成功？不'});
      expect(masked.getLeft().toNullable(), isA<ReplyToThreadResultFailedException>());
    });

    test('the captcha refused by its key: the reply asks for it', () async {
      final result = await _quickReply({
        ..._fixture('reply_flood'),
        'message_key': 'submit_seccode_invalid',
        'message': 'Wrong code',
        'values': <String, Object?>{},
      });
      expect(result.getLeft().toNullable(), isA<ReplyNeedsVerificationException>());
    });

    test("no key (another plugin's own words): read as before", () async {
      // The reply merged into the previous floor (plugin replymerge): its own words, the success hook.
      final merged = {
        ..._fixture('reply_ok'),
        'message': '回复已并入你上一楼的内容',
        'message_key': '',
        'values': {'fid': '25', 'tid': '9202864', 'pid': '22421', 'merged': '1'},
        'url': 'forum.php?mod=viewthread&tid=9202864&pid=22421&page=6&extra=#pid22421',
      };
      expect((await _quickReply(merged)).getRight().toNullable(), (pid: '22421', page: 6));
      final words = {..._fixture('reply_ok'), 'kind': 'message', 'message_key': '', 'alert': 'info'};
      expect((await _quickReply(words)).isRight(), isTrue, reason: 'the words of a stored reply');
      final other = {...words, 'message': 'Posted.'};
      expect((await _quickReply(other)).isLeft(), isTrue, reason: 'nothing tells it was stored');
    });

    test("without the API: the forum's own answer, read as before", () async {
      expect((await _quickReply(_ajax('非常感谢，回复发布成功'))).getRight().toNullable(), (pid: '22422', page: 6));
      expect(
        (await _quickReply(_ajax('抱歉，您两次发表间隔少于 15 秒，请稍候再发表', succeed: false))).getLeft().toNullable(),
        isA<ReplyToThreadResultFailedException>(),
      );
    });
  });

  group('the new poll', () {
    test('the real answers: created and verified, awaiting moderation, refused for flooding', () async {
      final gets = <String>[];
      final ok = await _poll(
        _fixture('poll_ok'),
        gets: gets,
        thread: pollThread(tid: '9203362'),
      );
      expect((ok.outcome, ok.tid), (PollCreateOutcome.published, '9203362'));
      expect(gets.single, contains('tid=9203362'), reason: 'verified by its thread');
      final moderated = await _poll(_fixture('poll_mod'));
      expect((moderated.outcome, moderated.tid), (PollCreateOutcome.moderated, '9203363'));
      final flood = await _poll(_fixture('poll_flood'));
      expect((flood.outcome, flood.message), (PollCreateOutcome.rejected, '抱歉，您两次发表间隔少于 15 秒，请稍候再发表'));
    });

    test('a created key decides, whatever the words and the class of the message', () async {
      final moderated = await _poll({..._fixture('poll_mod'), 'message': 'Awaiting review.', 'alert': 'info'});
      expect((moderated.outcome, moderated.tid), (PollCreateOutcome.moderated, '9203363'));
      final gets = <String>[];
      final created = {
        ..._fixture('poll_mod'),
        'message_key': 'post_newthread_succeed',
        'message': 'Thread posted.',
        'alert': 'info',
      };
      final ok = await _poll(
        created,
        gets: gets,
        thread: pollThread(tid: '9203363'),
      );
      expect((ok.outcome, ok.tid), (PollCreateOutcome.published, '9203363'));
      expect(gets, hasLength(1), reason: 'still verified by its thread, never trusted');
    });

    test('no key: the words and the class of the message, as before', () async {
      final noKey = {..._fixture('poll_mod'), 'message_key': ''};
      final moderated = await _poll(noKey);
      expect((moderated.outcome, moderated.tid), (PollCreateOutcome.moderated, '9203363'));
      final changed = await _poll({...noKey, 'message': 'Awaiting review.'});
      expect(changed.outcome, PollCreateOutcome.unconfirmed, reason: 'verified by the link, which fails here');
    });
  });
}
