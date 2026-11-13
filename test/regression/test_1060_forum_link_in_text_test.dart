// The forum link in a piece of text (a link token: "【天使动漫】<title> <link> 点击链接直接打开"), and what a change of
// a text field pasted.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/open_in_app/utils/forum_link_in_text.dart';
import 'package:tsdm_client/features/quick_open/models/quick_open_candidate.dart';
import 'package:tsdm_client/features/quick_open/utils/quick_open_search.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

const _token = '【天使动漫】某某标题 https://www.tsdm39.com/forum.php?mod=viewthread&tid=123 点击链接直接打开';

void main() {
  group('findForumLinkInText', () {
    test('the link of a token with words around it is a thread', () {
      final link = findForumLinkInText(_token)!;
      expect(link.url, 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=123');
      expect(link.isThread, isTrue);
      expect(link.route!.queryParameters['tid'], '123');
    });

    test('words right after the link, without a space, end it', () {
      final link = findForumLinkInText('看这个https://www.tsdm39.com/forum.php?mod=viewthread&tid=55&page=2点击打开')!;
      expect(link.url, 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=55&page=2');
      expect(link.route!.queryParameters['pageNumber'], '2');
      expect(
        findForumLinkInText('(https://www.tsdm39.com/forum.php?mod=viewthread&tid=9).')!.url,
        'https://www.tsdm39.com/forum.php?mod=viewthread&tid=9',
      );
    });

    test('a link alone, http and without www, is put on the https forum host', () {
      expect(
        findForumLinkInText('http://tsdm39.com/forum.php?mod=forumdisplay&fid=8')!.url,
        'https://www.tsdm39.com/forum.php?mod=forumdisplay&fid=8',
      );
      final forum = findForumLinkInText('www.tsdm39.com/forum.php?mod=forumdisplay&fid=8')!;
      expect(forum.route!.screenPath, ScreenPaths.forum);
      expect(forum.isThread, isFalse);
    });

    test('the rewritten paths and the old domains are the current pages', () {
      final thread = findForumLinkInText('xx https://www.tsdm39.com/thread-777-3-1.html yy')!;
      expect(thread.url, 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=777&page=3');
      expect(thread.isThread, isTrue);
      final forum = findForumLinkInText('https://www.tsdm39.com/forum-6-1.html')!;
      expect(forum.route!.screenPath, ScreenPaths.forum);
      expect(findForumLinkInText('http://www.tsdm39.net/thread-5-1-1.html')!.url, contains('tid=5'));
    });

    test('a word, a number, a mark or a BBCode tag may come right before a link', () {
      for (final text in [
        '[url=https://www.tsdm39.com/thread-5-1-1.html]帖子[/url]',
        'url=https://www.tsdm39.com/thread-5-1-1.html',
        'EP03https://www.tsdm39.com/thread-5-1-1.html',
        '标题-https://www.tsdm39.com/thread-5-1-1.html',
        '1.https://www.tsdm39.com/thread-5-1-1.html',
        '看这个!https://www.tsdm39.com/thread-5-1-1.html',
        '<a href="https://www.tsdm39.com/thread-5-1-1.html">',
      ]) {
        expect(findForumLinkInText(text)?.url, 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=5', reason: text);
      }
    });

    test("the forum's own name may come right before a link", () {
      expect(
        findForumLinkInText('天使动漫tsdm39.com:https://www.tsdm39.com/thread-5-1-1.html')?.url,
        'https://www.tsdm39.com/forum.php?mod=viewthread&tid=5',
      );
    });

    test('a long run before a link or many links take little time', () {
      final watch = Stopwatch()..start();
      final run = 'A' * 200000;
      expect(findForumLinkInText('$run https://www.tsdm39.com/thread-5-1-1.html'), isNotNull);
      expect(findForumLinkInText('${run}https://www.tsdm39.com/thread-5-1-1.html'), isNotNull);
      final others = List.generate(3000, (i) => 'https://example.com/a/$i').join('\n');
      expect(findForumLinkInText('$others\nhttps://www.tsdm39.com/thread-5-1-1.html'), isNotNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a colon or a bracket may come before a link', () {
      expect(findForumLinkInText('链接:https://www.tsdm39.com/forum.php?mod=viewthread&tid=3')!.url, contains('tid=3'));
      expect(findForumLinkInText('(tsdm39.com/forum.php?mod=viewthread&tid=3)')!.url, contains('tid=3'));
    });

    test('user info and port are dropped: the canonical host only', () {
      expect(
        findForumLinkInText('http://x@www.tsdm39.com:8080/plugin.php?id=a#top')!.url,
        'https://www.tsdm39.com/plugin.php?id=a#top',
      );
    });

    test('a forum link the app has no page for is still found, without a route', () {
      final link = findForumLinkInText('看 https://www.tsdm39.com/plugin.php?id=xyz 吧')!;
      expect(link.route, isNull);
      expect(link.isThread, isFalse);
    });

    test('the first forum link wins over a later one and over links of other sites', () {
      final link = findForumLinkInText(
        'https://example.com/a https://www.tsdm39.com/forum.php?mod=viewthread&tid=1 '
        'https://www.tsdm39.com/forum.php?mod=viewthread&tid=2',
      )!;
      expect(link.route!.queryParameters['tid'], '1');
    });

    test('links of other sites never count, also with the forum inside them', () {
      for (final text in [
        'https://example.com/forum.php?mod=viewthread&tid=1',
        'https://example.com/?u=https://www.tsdm39.com/forum.php?mod=viewthread&tid=1',
        'https://www.tsdm39.com.example.com/forum.php?mod=viewthread&tid=1',
        'https://www.tsdm39.com@example.com/forum.php?mod=viewthread&tid=1',
        'https://faketsdm39.com/forum.php?mod=viewthread&tid=1',
        'example.tsdm39.com.cn/forum.php?mod=viewthread&tid=1',
        'tsdm39.com.cn/forum.php?mod=viewthread&tid=1',
        'www.tsdm39.company/forum.php?mod=viewthread&tid=1',
        'javascript:alert(1)',
        'tsdm39.com 打不开',
        '去 www.tsdm39.com 看看',
        'www.tsdm39.com',
        '有人能上tsdm39.com?',
        '是tsdm39.com?还是别的',
        'tsdm39.com/ 打不开',
        'www.tsdm39.com# 呢',
        'tsdm39.com/# 呢',
        'tsdm39.com// 呢',
        'example.com/?u=www.tsdm39.com/forum.php?mod=viewthread&tid=1',
        'example.com/?u=https://www.tsdm39.com/forum.php?mod=viewthread&tid=1',
        '某某标题 点击链接直接打开',
        '123',
        '',
      ]) {
        expect(findForumLinkInText(text), isNull, reason: text);
      }
    });
  });

  group('forumLinkPasted', () {
    test('a paste over the selected text: all of it, or a link replaced by a longer one', () {
      const one = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1';
      const longer = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=12345';
      const all = TextSelection(baseOffset: 0, extentOffset: one.length);
      expect(forumLinkPasted(one, longer, selection: all)!.url, longer);
      const longText = '很长很长的一段关键字 $one';
      expect(
        forumLinkPasted(longText, one, selection: const TextSelection(baseOffset: 0, extentOffset: longText.length)),
        isNotNull,
      );
      // Without the selection the change looks like typing "2345".
      expect(forumLinkPasted(one, longer), isNull);
      // A character typed over a selection is a key press.
      expect(forumLinkPasted(one, '$one!'.substring(0, 1), selection: all), isNull);
    });

    test('a token or a link pasted at once, into an empty or a filled field', () {
      expect(forumLinkPasted('', _token)!.url, contains('tid=123'));
      expect(forumLinkPasted('abc', 'abc$_token')!.url, contains('tid=123'));
      expect(forumLinkPasted('ab', 'a${_token}b')!.url, contains('tid=123'));
      expect(forumLinkPasted('old', 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=4'), isNotNull);
    });

    test('a link typed one character after the other is never one', () {
      const url = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=4';
      for (var i = 1; i <= url.length; i++) {
        expect(forumLinkPasted(url.substring(0, i - 1), url.substring(0, i)), isNull, reason: '$i');
      }
    });

    test('deleting, a foreign link, or text without a link pastes nothing', () {
      expect(forumLinkPasted(_token, ''), isNull);
      expect(forumLinkPasted('', 'https://example.com/forum.php?mod=viewthread&tid=4'), isNull);
      expect(forumLinkPasted('', '动画 推荐'), isNull);
    });
  });

  group('quick open', () {
    test('a link token opens its thread, labelled with the link', () {
      final target = parseQuickOpenTarget(_token)!;
      expect(target.kind, QuickOpenKind.typedThread);
      expect(target.route.queryParameters['tid'], '123');
      expect(target.title, 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=123');
      final first = buildQuickOpenCandidates(_token, const QuickOpenSources()).first;
      expect((first.kind, first.title), (target.kind, target.title));
    });

    test('words without a forum link stay a search', () {
      expect(parseQuickOpenTarget('动画 https://example.com/forum.php?mod=viewthread&tid=4'), isNull);
    });
  });
}
