import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/post_report/utils/report_page_context.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/parsing.dart';

import 'fixtures/post_report_fixtures.dart';

Post? _post(String floor, {PostReportPageContext? context = pageContext, int pid = reportPid}) {
  final doc = parseHtmlDocument('<html><body>$floor</body></html>');
  return Post.fromPostNode(doc.querySelector('div#post_$pid')!, 1, reportContext: context);
}

String _hrefLink(String href) => '<a href="$href">举报</a>';

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('report link of a floor', () {
    test('observed javascript:; link with the literal showWindow call gives the target', () {
      final post = _post(postFloor());
      expect(post, isNotNull);
      expect(post!.reportTarget, reportTarget);
      expect(
        post.reportTarget!.reportUrl.toString(),
        'https://www.tsdm39.com/misc.php?mod=report&rtype=post&rid=$reportPid&tid=$reportTid&fid=$reportFid',
      );
      expect(post.reportTarget!.handleKey, 'miscreport$reportPid');
      expect(
        post.reportTarget!.floorUrl.toString(),
        'https://www.tsdm39.com/forum.php?mod=redirect&goto=findpost&ptid=$reportTid&pid=$reportPid',
        reason: 'the browser fallback opens the full thread floor, not the ajax report fragment',
      );
    });

    test('a real href to the report entry is accepted', () {
      for (final href in [
        'misc.php?mod=report&amp;rtype=post&amp;rid=$reportPid&amp;tid=$reportTid&amp;fid=$reportFid',
        '/misc.php?mod=report&amp;rtype=post&amp;rid=$reportPid&amp;tid=$reportTid&amp;fid=$reportFid',
        'https://www.tsdm39.com/misc.php?mod=report&amp;rtype=post&amp;rid=$reportPid&amp;tid=$reportTid&amp;fid=$reportFid',
        'http://tsdm39.com/misc.php?fid=$reportFid&amp;mod=report&amp;rtype=post&amp;rid=$reportPid&amp;tid=$reportTid',
      ]) {
        expect(_post(postFloor(operations: _hrefLink(href)))!.reportTarget, reportTarget, reason: href);
      }
    });

    test('href and onclick must name the same report', () {
      const url = 'misc.php?mod=report&amp;rtype=post&amp;rid=$reportPid&amp;tid=$reportTid&amp;fid=$reportFid';
      final same = postFloor(
        operations:
            '<a href="$url" onclick="showWindow(\'miscreport$reportPid\', '
            "'misc.php?mod=report&rtype=post&rid=$reportPid&tid=$reportTid&fid=$reportFid', 'get', -1);return false;\">举报</a>",
      );
      expect(_post(same)!.reportTarget, reportTarget);
      final differ = postFloor(
        operations:
            '<a href="$url" onclick="showWindow(\'miscreport$reportPid\', '
            "'misc.php?mod=report&rtype=post&rid=$reportPid&tid=$reportTid&fid=999', 'get', -1);return false;\">举报</a>",
      );
      expect(_post(differ)!.reportTarget, isNull);
    });

    test('a link of another thread, forum or post is refused, the page ids decide', () {
      expect(_post(postFloor(operations: reportOnclickLink(tid: 999)))!.reportTarget, isNull);
      expect(_post(postFloor(operations: reportOnclickLink(fid: 999)))!.reportTarget, isNull);
      expect(_post(postFloor(operations: reportOnclickLink(pid: 1)))!.reportTarget, isNull);
      expect(_post(postFloor(operations: reportOnclickLink(handlePid: '1')))!.reportTarget, isNull);
      // The link agrees with itself but not with the page.
      expect(
        _post(
          postFloor(),
          context: const PostReportPageContext(tid: 1, fid: reportFid, viewerUid: viewerUid),
        )!.reportTarget,
        isNull,
      );
      expect(
        _post(
          postFloor(),
          context: const PostReportPageContext(tid: reportTid, fid: 1, viewerUid: viewerUid),
        )!.reportTarget,
        isNull,
      );
    });

    test('fake, duplicated or extended links are refused', () {
      const base = 'mod=report&amp;rtype=post&amp;rid=$reportPid&amp;tid=$reportTid&amp;fid=$reportFid';
      for (final href in [
        'https://evil.example/misc.php?$base',
        'https://www.tsdm39.com:8443/misc.php?$base',
        'https://user@www.tsdm39.com/misc.php?$base',
        '//www.tsdm39.com/misc.php?$base',
        'x/misc.php?$base',
        'misc.php.evil?$base',
        'forum.php?$base',
        'misc.php?$base&amp;reportsubmit=true',
        'misc.php?$base&amp;handlekey=x',
        'misc.php?$base&amp;rid=$reportPid',
        'misc.php?$base#x',
        'misc.php?mod=report&amp;rtype=user&amp;rid=$reportPid&amp;tid=$reportTid&amp;fid=$reportFid',
        'misc.php?mod=report&amp;rtype=post&amp;rid=0$reportPid&amp;tid=$reportTid&amp;fid=$reportFid',
        'javascript:alert(1)',
      ]) {
        expect(_post(postFloor(operations: _hrefLink(href)))!.reportTarget, isNull, reason: href);
      }
      final injected = postFloor(
        operations:
            '<a href="javascript:;" onclick="showWindow(\'miscreport$reportPid\', '
            "'misc.php?mod=report&rtype=post&rid=$reportPid&tid=$reportTid&fid=$reportFid', 'get', -1);"
            'doSomething();return false;">举报</a>',
      );
      expect(_post(injected)!.reportTarget, isNull);
      final twice = postFloor(operations: reportOnclickLink() + reportOnclickLink());
      expect(_post(twice)!.reportTarget, isNull, reason: 'ambiguous operation row');
    });

    test('links in the post body or the signature are not the floor action', () {
      final fake = reportOnclickLink();
      final onlyFake = postFloor(
        operations: '',
        body: '<div class="pob">$fake</div>',
        signature: '<div class="pob">$fake</div>',
      );
      expect(_post(onlyFake)!.reportTarget, isNull);
      final withReal = postFloor(body: '<div class="pob">$fake</div>', signature: '<div class="pob">$fake</div>');
      expect(_post(withReal)!.reportTarget, reportTarget);
    });

    test('own posts, floors without the link and pages without reliable ids have no target', () {
      expect(_post(postFloor(author: viewerUid))!.reportTarget, isNull, reason: 'own post');
      expect(_post(postFloor(operations: ''))!.reportTarget, isNull, reason: 'no report link');
      expect(_post(postFloor(), context: null)!.reportTarget, isNull, reason: 'unknown page context');
    });
  });

  group('page context', () {
    test('ids come from the page itself', () {
      final doc = parseHtmlDocument(threadPage());
      final context = postReportPageContextOf(doc)!;
      expect(context.tid, reportTid);
      expect(context.fid, reportFid);
      expect(context.viewerUid, viewerUid);
      expect(postReportPageContextOf(doc, expectedTid: '$reportTid'), isNotNull);
      expect(postReportPageContextOf(doc, expectedTid: '1'), isNull);
    });

    test('guest pages, missing or disagreeing ids give no context', () {
      expect(postReportPageContextOf(parseHtmlDocument(threadPage(uid: 0))), isNull);
      expect(postReportPageContextOf(parseHtmlDocument(threadPage(fastPostFid: '999'))), isNull);
      expect(
        postReportPageContextOf(parseHtmlDocument(threadPage().replaceFirst('rel="canonical"', 'rel="alternate"'))),
        isNull,
      );
      final noFid = threadPage(fastPost: false).replaceFirst('name="srhfid"', 'name="other"');
      expect(postReportPageContextOf(parseHtmlDocument(noFid)), isNull);
    });

    test('thread page parsing keeps the target of the observed floor only', () {
      final info = parseThreadDocument(parseHtmlDocument(threadPage()), 1);
      expect(info.postList.single.reportTarget, reportTarget);
      final guest = parseThreadDocument(parseHtmlDocument(threadPage(uid: 0)), 1);
      expect(guest.postList.single.reportTarget, isNull, reason: 'guests see the link but can not report');
      final own = parseThreadDocument(parseHtmlDocument(threadPage(floors: postFloor(author: viewerUid))), 1);
      expect(own.postList.single.reportTarget, isNull);
    });

    test('a target stays bound to the account that read the page', () {
      final info = parseThreadDocument(parseHtmlDocument(threadPage(uid: otherUid)), 1);
      final target = info.postList.single.reportTarget!;
      expect(target.viewerUid, otherUid);
      expect(target == reportTarget, isFalse);
    });
  });
}
