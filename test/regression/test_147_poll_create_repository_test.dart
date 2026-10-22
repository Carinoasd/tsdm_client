import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/repository/poll_create_repository.dart';
import 'package:tsdm_client/features/post/utils/new_thread_status.dart';
import 'package:tsdm_client/features/post/utils/submission_result.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

import 'poll_fixtures.dart';

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

final class _Harness {
  _Harness({required this.post, String? thread, this.uid = 1000}) : _thread = thread;

  final SyncEither<Response<dynamic>> Function() post;
  final String? _thread;
  int uid;
  int posts = 0;
  final gets = <String>[];
  Map<String, String>? payload;

  late final repo = PollCreateRepository.withTransport(
    currentUid: () => uid,
    getPage: (url) async {
      gets.add(url);
      if (url.contains('viewthread')) {
        return _thread == null ? left(HttpRequestFailedException(500)) : right(pollResponse(_thread));
      }
      return right(pollResponse(pollForm()));
    },
    sendForm: (url, body) async {
      posts++;
      payload = body;
      return post();
    },
  );

  Future<PollCreateResult> submit() async {
    final form = (await repo.fetchForm('4')).form!;
    return repo.submit(form, validatePollDraft(_draft, form).submission!);
  }
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('form fetch', () {
    Future<PollFormLoad> fetch(String html, {int uid = 1000}) => PollCreateRepository.withTransport(
      currentUid: () => uid,
      getPage: (_) async => right(pollResponse(html)),
      sendForm: (_, _) async => throw StateError('no post'),
    ).fetchForm('4');

    test('guest page means the same account must sign in again', () async {
      expect((await fetch(pollForm(uid: 0))).kind, PollFormLoadKind.loginRequired);
    });
    test('a form served to another account is never used', () async {
      expect((await fetch(pollForm(uid: 1001))).kind, PollFormLoadKind.identityChanged);
    });
    test('no permission keeps the server wording', () async {
      final load = await fetch(pollMessage('Synthetic refusal', cls: 'alert_error'));
      expect(load.kind, PollFormLoadKind.denied);
      expect(load.message, 'Synthetic refusal');
    });
    test("requests the special=1 form of the forum, in the JSON mode of the forum's app API (plugin 2.9.0)", () async {
      final harness = _Harness(post: () => throw StateError('no post'));
      await harness.repo.fetchForm('4');
      expect(harness.gets.single, withTsdmAppJson('$baseUrl/forum.php?mod=post&action=newthread&fid=4&special=1'));
    });
  });

  group('single submission outcome', () {
    test('redirect alone is verified; a normal header is published', () async {
      final harness = _Harness(
        post: () => right(pollResponse('', status: 301, location: 'forum.php?mod=viewthread&tid=321')),
        thread: pollThread(),
      );
      final result = await harness.submit();
      expect(result.outcome, PollCreateOutcome.published);
      expect(result.tid, '321');
      expect(harness.posts, 1);
      expect(harness.payload!['tpolloption'], '2');
      expect(harness.payload!.keys.where((k) => k.startsWith('polloption[')), isEmpty);
    });

    test('redirect surfaced as a handshake error is handled the same way', () async {
      final harness = _Harness(
        post: () => left(
          HttpHandshakeFailedException(
            'redirect',
            statusCode: 302,
            headers: Headers.fromMap({
              'location': ['forum.php?mod=viewthread&tid=321'],
            }),
          ),
        ),
        thread: pollThread(label: '(审核中)'),
      );
      expect((await harness.submit()).outcome, PollCreateOutcome.moderated);
    });

    test('owner-visible thread with a pending moderation header is moderated, never published', () async {
      final pending = pollThread(label: '(Under Review)');
      final harness = _Harness(post: () => right(pollResponse(pending)));
      final result = await harness.submit();
      expect(result.outcome, PollCreateOutcome.moderated);
      // The ordinary editor's generic parser would accept this same page as a thread target.
      expect(parseSubmissionResult(pollResponse(pending)), isNotNull);
    });

    test('draft, ignored or unknown header labels stay unconfirmed', () async {
      for (final label in [
        '(草稿)<a class="psave" href="forum.php?mod=misc&amp;action=pubsave&amp;tid=321">Publish</a>',
        '(已忽略)',
        '(Synthetic unknown status)',
      ]) {
        final harness = _Harness(
          post: () => right(pollResponse('', status: 302, location: 'forum.php?mod=viewthread&tid=321')),
          thread: pollThread(label: label),
        );
        final result = await harness.submit();
        expect(result.outcome, PollCreateOutcome.unconfirmed, reason: label);
        expect(result.tid, '321');
      }
    });

    test('rewritten canonical of another thread or site is not this thread', () {
      String withCanonical(String href) => pollThread().replaceFirst(
        'rel="canonical" href="forum.php?mod=viewthread&amp;tid=321"',
        'rel="canonical" href="$href"',
      );
      expect(
        classifyNewThreadHeader(parseHtmlDocument(withCanonical('/thread-321-1-1.html')), '321'),
        NewThreadHeaderStatus.visible,
      );
      expect(
        classifyNewThreadHeader(parseHtmlDocument(withCanonical('/thread-999-1-1.html')), '321'),
        NewThreadHeaderStatus.unknown,
      );
      expect(
        classifyNewThreadHeader(parseHtmlDocument(withCanonical('https://example.com/thread-321-1-1.html')), '321'),
        NewThreadHeaderStatus.unknown,
      );
    });

    test('only the copy link to the same thread is ignored in the status line', () {
      final other = pollThread(label: '<a href="forum.php?mod=forumdisplay&amp;fid=4">Synthetic status</a>');
      expect(classifyNewThreadHeader(parseHtmlDocument(other), '321'), NewThreadHeaderStatus.unknown);
      final hidden = pollThread(label: '<a href="forum.php?mod=misc&amp;action=hiderecover&amp;tid=321"></a>');
      expect(classifyNewThreadHeader(parseHtmlDocument(hidden), '321'), NewThreadHeaderStatus.unknown);
    });

    test('status words inside the post body are not header labels', () {
      final document = parseHtmlDocument(pollThread(body: '(审核中) (Under Review) (草稿)'));
      expect(classifyNewThreadHeader(document, '321'), NewThreadHeaderStatus.visible);
      expect(classifyNewThreadHeader(document, '999'), NewThreadHeaderStatus.unknown);
    });

    test('explicit moderation message is moderated with its thread link', () async {
      final harness = _Harness(
        post: () => right(
          pollResponse(
            pollMessage(
              'New thread requires moderation, your post will be displayed after passing review',
              link: 'forum.php?mod=viewthread&amp;tid=321',
            ),
          ),
        ),
      );
      final result = await harness.submit();
      expect(result.outcome, PollCreateOutcome.moderated);
      expect(result.tid, '321');
      expect(harness.gets.where((u) => u.contains('viewthread')), isEmpty);
    });

    test('success message link alone is verified, and unverifiable is unconfirmed', () async {
      final harness = _Harness(
        post: () => right(
          pollResponse(pollMessage('Synthetic success wording', link: 'forum.php?mod=viewthread&amp;tid=321')),
        ),
      );
      final result = await harness.submit();
      expect(result.outcome, PollCreateOutcome.unconfirmed);
      expect(result.tid, '321');
    });

    test('verification page of another account is not proof', () async {
      final harness = _Harness(
        post: () => right(pollResponse('', status: 301, location: 'forum.php?mod=viewthread&tid=321')),
        thread: pollThread(uid: 1001),
      );
      expect((await harness.submit()).outcome, PollCreateOutcome.unconfirmed);
    });

    test('explicit refusal is rejected with plain server text', () async {
      final harness = _Harness(
        post: () => right(pollResponse(pollMessage('Synthetic <b>refusal</b>', cls: 'alert_error'))),
      );
      final result = await harness.submit();
      expect(result.outcome, PollCreateOutcome.rejected);
      expect(result.message, 'Synthetic refusal');
    });

    test('alert_info or unclassified messages are not refusals; a returned link is only verified by GET', () async {
      // Upstream showmessage uses alert_info for forwards whose message is not *_succeed and for notes.
      for (final cls in ['alert_info', '', 'alert_synthetic']) {
        final harness = _Harness(post: () => right(pollResponse(pollMessage('Synthetic note', cls: cls))));
        final result = await harness.submit();
        expect(result.outcome, PollCreateOutcome.unconfirmed, reason: cls);
        expect(harness.posts, 1);
      }
      final linked = _Harness(
        post: () => right(
          pollResponse(pollMessage('Synthetic note', cls: 'alert_info', link: 'forum.php?mod=viewthread&amp;tid=321')),
        ),
        thread: pollThread(),
      );
      final result = await linked.submit();
      expect(result.outcome, PollCreateOutcome.published);
      expect(result.tid, '321');
      expect(linked.posts, 1);
      expect(linked.gets.where((u) => u.contains('viewthread')), hasLength(1));
    });

    test('transport failure, bare 200 or foreign redirect is unconfirmed and never retried', () async {
      for (final post in <SyncEither<Response<dynamic>> Function()>[
        () => left(HttpRequestFailedException(null)),
        () => right(pollResponse('<html><body>ok</body></html>')),
        () => right(pollResponse('', status: 302, location: 'https://example.com/forum.php?mod=viewthread&tid=321')),
        () => right(pollResponse('', status: 500)),
      ]) {
        final harness = _Harness(post: post, thread: pollThread());
        final result = await harness.submit();
        expect(result.outcome, PollCreateOutcome.unconfirmed);
        expect(harness.posts, 1);
      }
    });

    test('account change before sending posts nothing', () async {
      final harness = _Harness(post: () => throw StateError('no post'));
      final form = (await harness.repo.fetchForm('4')).form!;
      harness.uid = 1001;
      final result = await harness.repo.submit(form, validatePollDraft(_draft, form).submission!);
      expect(result.outcome, PollCreateOutcome.identityChanged);
      expect(harness.posts, 0);
    });
  });
}
