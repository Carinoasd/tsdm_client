import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/utils/html/review_parser.dart';
import 'package:universal_html/parsing.dart';

/// Regression test for parsing the post comment (点评) block on Discuz! X5.
///
/// `test/data/review_x5.html` is a real `<div class="cm">` captured from the
/// forum (tid=1174425). Since X5 the author link lives in `div.psta` and the
/// comment text is a bare text node in `div.psti`; the old parser read a fixed
/// child index of `div.psti` and rendered an empty comment without a name.
void main() {
  test('parse X5 review block', () {
    final html = File('test/data/review_x5.html').readAsStringSync();
    final cm = parseHtmlDocument(html).querySelector('div.cm');
    expect(cm, isNotNull);

    final review = parseReviewElement(cm!);
    expect(review.name, 'Heidi');
    expect(review.avatarUrl, 'https://example.com/img/1.gif');
    expect(
      review.content,
      '你没看到我最后一部分的意思，比如你举例的这个动漫，下面就写让17来参加配音之类，不是举例谁发原创主题',
    );
  });

  test('empty X5 placeholder block has no name or content', () {
    final cm = parseHtmlDocument('<div class="cm"></div>').querySelector('div.cm');
    final review = parseReviewElement(cm!);
    expect(review.name, isNull);
    expect(review.content, anyOf(isNull, isEmpty));
  });

  test('legacy layout with author link inside psti still parses', () {
    // Line breaks are kept outside `div.psti` so its direct text nodes stay unchanged.
    const html = '''
<div class="cm"><div class="pstl">
<div class="psta"><a><img src="https://example.com/a.png"></a></div>
<div class="psti"><a class="xi2">old_user</a>&nbsp;&nbsp;old comment <span class="xg1">发表于 2020-1-1</span></div>
</div></div>''';
    final review = parseReviewElement(parseHtmlDocument(html).querySelector('div.cm')!);
    expect(review.name, 'old_user');
    expect(review.content, 'old comment');
  });
}
