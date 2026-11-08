/// Links in a post's content to a thread are drawn as cards of the thread (the link card, part 1: which links).
///
/// A link becomes a card when it shows a url itself and points at a thread of the forum: `forum.php?mod=viewthread&
/// tid=N`, the rewritten `thread-N-P-X.html`, the floor redirect `forum.php?mod=redirect&goto=findpost&pid=…&ptid=N`.
/// The text is the url as the forum prints it (with or without its scheme, cut around ` ... ` past 65 characters by
/// `parseurl`) or another url of the same thread (the forum rewrites the link of `[url]…/thread-N-P-X.html[/url]` to
/// `viewthread`, keeping the text). A link with text of its own, to another site, or to anything but a thread is not.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/thread_link_card/utils/thread_link.dart';
import 'package:universal_html/parsing.dart';

void main() {
  group('a link showing its url', () {
    test('viewthread', () {
      const url = '$baseUrl/forum.php?mod=viewthread&tid=9202763';
      expect(threadLinkOf(url, url), const ThreadLink(tid: 9202763, url: url));
      // Any other parameter, the floor anchor kept for the route.
      const page = '$baseUrl/forum.php?mod=viewthread&tid=9202763&extra=page%3D1&page=2#pid11176';
      expect(threadLinkOf(page, page)?.url, page);
    });

    test('the text without the scheme, or with the other one, in any case', () {
      const url = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=12';
      expect(threadLinkOf(url, 'www.tsdm39.com/forum.php?mod=viewthread&tid=12')?.tid, 12);
      expect(threadLinkOf(url, 'http://www.tsdm39.com/forum.php?mod=viewthread&tid=12')?.tid, 12);
      expect(threadLinkOf(url, ' HTTPS://WWW.TSDM39.COM/forum.php?mod=viewthread&tid=12 ')?.tid, 12);
      expect(
        threadLinkOf(
          'http://tsdm39.com/forum.php?mod=viewthread&tid=12',
          'tsdm39.com/forum.php?mod=viewthread&tid=12',
        )?.tid,
        12,
      );
    });

    test('a relative link and one on the scheme of the page open on the forum host', () {
      const relative = 'forum.php?mod=viewthread&tid=5';
      expect(threadLinkOf(relative, relative)?.url, '$baseUrl/forum.php?mod=viewthread&tid=5');
      const noScheme = '//www.tsdm39.com/forum.php?mod=viewthread&tid=5';
      expect(threadLinkOf(noScheme, noScheme)?.url, '$baseUrl/forum.php?mod=viewthread&tid=5');
    });

    test('the rewritten url opens its page', () {
      const first = '$baseUrl/thread-9202765-1-1.html';
      expect(
        threadLinkOf(first, first),
        const ThreadLink(tid: 9202765, url: '$baseUrl/forum.php?mod=viewthread&tid=9202765'),
      );
      const second = '$baseUrl/thread-9202765-2-1.html';
      expect(threadLinkOf(second, second)?.url, '$baseUrl/forum.php?mod=viewthread&tid=9202765&page=2');
    });

    test('the floor redirect is its thread, opened at the floor', () {
      const url = '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=11176&ptid=9202763';
      expect(threadLinkOf(url, url), const ThreadLink(tid: 9202763, url: url));
      // Without the thread: no card.
      const noThread = '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=11176';
      expect(threadLinkOf(noThread, noThread), isNull);
    });

    test('a long url cut by the forum', () {
      const url = '$baseUrl/forum.php?mod=viewthread&tid=9202765&extra=page%3D1&page=1&ordertype=2';
      // `parseurl`: the first 32 characters and the last 19, of the escaped url.
      expect(threadLinkOf(url, 'https://www.tsdm39.com/forum.php ... e=1&ordertype=2')?.tid, 9202765);
      // Cut text of another url.
      expect(threadLinkOf(url, 'https://www.tsdm39.com/forum.php ... e=1&ordertype=1'), isNull);
      expect(threadLinkOf(url, 'https://www.tsdm39.com/home.php ... e=1&ordertype=2'), isNull);
    });

    test('another url of the same thread: the forum rewrote the link, not its text', () {
      expect(
        threadLinkOf('$baseUrl/forum.php?mod=viewthread&tid=9202765&page=2', '$baseUrl/thread-9202765-2-1.html')?.url,
        '$baseUrl/forum.php?mod=viewthread&tid=9202765&page=2',
      );
      // A url of another thread is not the link's: it stays a link.
      expect(
        threadLinkOf('$baseUrl/forum.php?mod=viewthread&tid=1', '$baseUrl/forum.php?mod=viewthread&tid=2'),
        isNull,
      );
    });
  });

  group('not a card', () {
    test('a link with text of its own', () {
      expect(threadLinkOf('$baseUrl/forum.php?mod=viewthread&tid=1', '自定义文字'), isNull);
      expect(
        threadLinkOf('$baseUrl/forum.php?mod=viewthread&tid=1', '详见 $baseUrl/forum.php?mod=viewthread&tid=1'),
        isNull,
      );
      expect(threadLinkOf('$baseUrl/forum.php?mod=viewthread&tid=1', ''), isNull);
    });

    test('a link out of the forum, whatever it looks like', () {
      const foreign = 'https://example.com/forum.php?mod=viewthread&tid=1';
      expect(threadLinkOf(foreign, foreign), isNull);
      const trick = 'https://www.tsdm39.com@example.com/forum.php?mod=viewthread&tid=1';
      expect(threadLinkOf(trick, trick), isNull);
      const script = 'javascript:forum.php?mod=viewthread&tid=1';
      expect(threadLinkOf(script, script), isNull);
    });

    test('a link of the forum to anything but a thread', () {
      for (final url in [
        '$baseUrl/forum.php?mod=forumdisplay&fid=10',
        '$baseUrl/forum.php?mod=viewthread',
        '$baseUrl/forum.php?mod=viewthread&tid=0',
        '$baseUrl/forum.php?mod=viewthread&tid=abc',
        '$baseUrl/home.php?mod=space&uid=1',
        '$baseUrl/plugin.php?mod=viewthread&tid=1',
        '$baseUrl/thread-0-1-1.html',
        '$baseUrl/forum-10-1.html',
      ]) {
        expect(threadLinkOf(url, url), isNull, reason: url);
      }
    });
  });

  test('the links of a floor of the test forum', () {
    final document = parseHtmlDocument(File('test/data/thread_link_card/post_links_x5.html').readAsStringSync());
    final links = [
      for (final a in document.querySelectorAll('a'))
        (a.innerText, threadLinkOf(a.attributes['href']!, a.innerText)?.tid),
    ];
    expect(links.map((e) => e.$2), [9202763, null, 9202765, 9202765, 9202763, null, 9202766]);
    // The custom text, the forum's list.
    expect(links[1].$1, '自定义文字');
    expect(links[5].$1, contains('forumdisplay'));
  });
}
