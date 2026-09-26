import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/draft_box/models/draft_data.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/utils/draft_marker.dart';
import 'package:tsdm_client/features/post/utils/submission_result.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/parsing.dart';

import 'draft_fixtures.dart';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  test('filtered rows need no draft badge, author, date or counters', () {
    final page = parseDraftPage(parseHtmlDocument(draftList(next: 2)), page: 1, uid: 1000);
    expect(page.entries.single.tid, '123');
    expect(page.entries.single.fid, '4');
    expect(page.nextPage, 2);
  });
  test('recognized empty list differs from login or unknown pages', () {
    expect(parseDraftPage(parseHtmlDocument(draftList(empty: true)), page: 1, uid: 1000).entries, isEmpty);
    for (final html in [
      '<div id="messagelogin">Login</div>',
      '<p>Unknown</p>',
      draftList().replaceFirst('class="a"', 'class=""'),
    ]) {
      expect(() => parseDraftPage(parseHtmlDocument(html), page: 1, uid: 1000), throwsFormatException);
    }
  });
  test('pagination rejects foreign identities, origins, duplicate keys and backwards pages', () {
    for (final replacement in [
      'filter=all',
      'filter=save&amp;uid=1001',
      'filter=save&amp;filter=all',
      'filter=save&amp;action=pubsave',
    ]) {
      // action has no effect: pagination is always reconstructed as an inert GET.
      final html = draftList(next: 2).replaceFirst('filter=save&amp;page=2', '$replacement&amp;page=2');
      if (replacement.contains('action=pubsave')) {
        expect(parseDraftPage(parseHtmlDocument(html), page: 1, uid: 1000).nextPage, 2);
      } else {
        expect(() => parseDraftPage(parseHtmlDocument(html), page: 1, uid: 1000), throwsFormatException);
      }
    }
    expect(() => parseDraftPage(parseHtmlDocument(draftList(next: 1)), page: 1, uid: 1000), throwsFormatException);
    final foreign = draftList(
      next: 2,
    ).replaceFirst('class="nxt" href="home.php', 'class="nxt" href="https://evil.example/home.php');
    expect(() => parseDraftPage(parseHtmlDocument(foreign), page: 1, uid: 1000), throwsFormatException);
  });
  test('only the first actual draft post can supply an edit target', () {
    final entry = parseDraftPage(parseHtmlDocument(draftList()), page: 1, uid: 1000).entries.single;
    expect(parseDraftTarget(parseHtmlDocument(draftThread()), entry), (fid: '4', tid: '123', pid: '456'));
    for (final html in [
      draftThread(draft: false),
      draftThread(edit: false, secondPost: true),
      draftThread().replaceAll('action=edit', 'action=delete'),
      draftThread().replaceAll('fid=4', 'fid=5'),
      draftThread().replaceAll('mod=post&amp;action=edit', 'mod=post&amp;action=edit&amp;tid=999'),
    ]) {
      expect(() => parseDraftTarget(parseHtmlDocument(html), entry), throwsFormatException);
    }
  });
  test('X5 sibling marker propagates only to first-floor post', () {
    final parsed = parseThreadDocument(parseHtmlDocument(draftThread(secondPost: true)), 1);
    expect(parsed.isDraft, isTrue);
    expect(parsed.postList.map((p) => p.isDraft), [true, false]);
  });
  test('named first-floor labels still resolve and preserve draft editing', () {
    final html = draftThread().replaceFirst(
      '<a><em>1</em></a>',
      '<a href="forum.php?mod=viewthread&amp;tid=123">楼主</a>',
    );
    final entry = parseDraftPage(parseHtmlDocument(draftList()), page: 1, uid: 1000).entries.single;
    expect(parseDraftTarget(parseHtmlDocument(html), entry).pid, '456');
    expect(parseThreadDocument(parseHtmlDocument(html), 1).postList.single.isDraft, isTrue);
  });
  test('legacy mark works but subject, body and hidden-post recovery are not drafts', () {
    expect(
      isDraftThreadDocument(parseHtmlDocument('<div id="postlist"><h1 class="ts"><span>[草稿]</span></h1></div>')),
      isTrue,
    );
    expect(
      isDraftThreadDocument(parseHtmlDocument(draftThread(draft: false).replaceAll('Synthetic subject', '草稿'))),
      isFalse,
    );
    final node = parseHtmlDocument(
      draftPost(marker: '<a class="psave" href="forum.php?action=hiderecover">恢复</a>'),
    ).querySelector('#post_456')!;
    expect(Post.fromPostNode(node, 1)!.isDraft, isFalse);
  });
  for (final marker in [
    '<input name="special" value="1">',
    '<input name="specialextra" value="plugin">',
    '<input name="sortid" value="2">',
    '<input name="typeoption[3]" value="x">',
    '<input name="contentType" value="json">',
    '<input name="contentEditor" value="jsonEditor">',
  ]) {
    test('unsupported structured form is not editable: $marker', () {
      expect(PostEditContent.fromDocument(parseHtmlDocument(draftEditForm(extra: marker))), isNull);
    });
  }
  test('ordinary draft form is editable without exposing its token in errors', () {
    final content = PostEditContent.fromDocument(parseHtmlDocument(draftEditForm()));
    expect(content?.data, 'Synthetic private body');
    expect(content?.canSaveDraft, isTrue);
  });
  test('a category named draft cannot classify a published thread as private', () {
    final document = parseHtmlDocument(
      draftThread(draft: false).replaceFirst(
        '<h1 class="ts">',
        '<h1 class="ts"><a href="forum.php?mod=forumdisplay&amp;fid=4&amp;typeid=9">[草稿]</a>',
      ),
    );
    expect(isDraftThreadDocument(document), isFalse);
    expect(parseThreadDocument(document, 1).postList.single.isDraft, isFalse);
  });
  test('save permission requires an actual button, not the global hidden save field', () {
    final document = parseHtmlDocument(draftEditForm());
    document.querySelector('button')!.remove();
    expect(PostEditContent.fromDocument(document)!.canSaveDraft, isFalse);
  });
  test('reply rewards and rush replies are protected; tags remain preserved', () {
    for (final extra in [
      '<input name="replycredit_extcredits" value="10">',
      '<input name="rushreply" checked disabled value="1">',
    ]) {
      expect(PostEditContent.fromDocument(parseHtmlDocument(draftEditForm(extra: extra))), isNull);
    }
    final content = PostEditContent.fromDocument(
      parseHtmlDocument(draftEditForm(extra: '<input name="tags" value="a,b">')),
    );
    expect(content!.tags, 'a,b');
  });
  test('plain replies in special threads stay editable, scheduled drafts do not', () {
    final reply = draftEditForm(extra: '<script>var isfirstpost = 0;</script><input name="special" value="1">');
    expect(PostEditContent.fromDocument(parseHtmlDocument(reply)), isNotNull);
    final scheduled = draftEditForm(extra: '<input name="cronpublish" value="1" checked>');
    expect(PostEditContent.fromDocument(parseHtmlDocument(scheduled)), isNull);
  });
  Response<dynamic> response(String data, {String? location, int code = 200}) => Response<dynamic>(
    requestOptions: RequestOptions(),
    data: data,
    statusCode: code,
    headers: Headers.fromMap({
      if (location != null) 'location': [location],
    }),
  );
  test('success accepts explicit forward link, never arbitrary first anchor', () {
    final result = parseSubmissionResult(
      response('''<div id="messagetext" class="alert_right">
<p>Saved <a href="forum.php?mod=forumdisplay&amp;fid=4">Forum</a></p>
<p class="alert_btnleft"><a href="forum.php?mod=viewthread&amp;tid=123">Continue</a></p></div>'''),
      expectedTid: '123',
    );
    expect(result, '$baseUrl/forum.php?mod=viewthread&tid=123');
  });
  test('HTTP 200, success-looking text and wrong redirects are not confirmation', () {
    for (final item in [
      response('ok'),
      response('<div id="messagetext"><p>Success</p></div>'),
      response('', code: 301, location: 'https://evil.example/forum.php?mod=viewthread&tid=123'),
      response('', code: 301, location: 'forum.php?mod=viewthread&tid=999'),
      response('', code: 301, location: 'forum.php?mod=misc&action=pubsave&tid=123'),
    ]) {
      expect(parseSubmissionResult(item, expectedTid: '123'), isNull);
    }
  });
  test('query and rewritten redirects canonicalize the same thread', () {
    expect(submittedThreadUrl('thread-123-1-1.html'), '$baseUrl/forum.php?mod=viewthread&tid=123');
    expect(
      parseSubmissionResult(response('', code: 301, location: 'forum.php?mod=viewthread&tid=123')),
      '$baseUrl/forum.php?mod=viewthread&tid=123',
    );
  });
}
