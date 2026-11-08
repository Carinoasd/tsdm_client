import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/thread/v1/tts/thread_tts_text.dart';
import 'package:tsdm_client/shared/models/models.dart';

Post _post(String html, {int floor = 3}) => Post(
  postID: '1',
  postFloor: floor,
  author: const User(name: '作者', url: 'u'),
  publishTime: DateTime(2026, 9, 5),
  data: html,
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: 1,
  isDraft: false,
  packetAllTaken: false,
);

void main() {
  group('speech text of a floor', () {
    test('plain paragraphs are kept, one per line', () {
      expect(speechTextOfHtml('<div>第一段<br>第二段</div>'), '第一段\n第二段');
    });

    test('the address of a link is not read, its words are', () {
      final text = speechTextOfHtml('<a href="https://forum.test/thread-1-1-1.html">看这里</a>');
      expect(text, '看这里');
      expect(text, isNot(contains('http')));
    });

    test('a bare address is dropped', () {
      expect(speechTextOfHtml('<p>网址 https://forum.test/a?b=1 就是</p>'), '网址 就是');
    });

    test('an image is said as the image label, with no address', () {
      final text = speechTextOfHtml('<p>前<img src="https://forum.test/a.png">后</p>');
      expect(text, '前 图片 后');
      expect(
        speechTextOfHtml('<img src="https://forum.test/a.png">', labels: const SpeechLabels(image: 'image')),
        'image',
      );
    });

    test('quote and list marks are not read', () {
      final text = speechTextOfHtml('<blockquote>引用的话</blockquote><ul><li>甲</li><li>乙</li></ul>');
      expect(text, isNot(contains('>')));
      expect(text, isNot(contains('- ')));
      expect(text, contains('引用的话'));
      expect(text, contains('甲'));
    });

    test('a post of nothing but spaces is empty', () {
      expect(speechTextOfHtml('<div>  \n </div>'), isEmpty);
    });
  });

  group('chunks', () {
    test('a short text is one chunk', () {
      expect(chunkSpeech('你好'), ['你好']);
    });

    test('a long text is cut at sentence ends within the limit', () {
      final sentence = '这是一句话。' * 10;
      final chunks = chunkSpeech(sentence * 5, maxLength: 100);
      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(100));
        expect(chunk.endsWith('。'), isTrue);
      }
      expect(chunks.join(), sentence * 5);
    });

    test('a text without any break is cut at the limit', () {
      final chunks = chunkSpeech('a' * 250, maxLength: 100);
      expect(chunks.map((e) => e.length), [100, 100, 50]);
    });
  });

  test('a floor is said as its heading, then its content', () {
    final speech = floorSpeechOf(_post('<div>内容</div>'), heading: '第 3 楼，作者：作者');
    expect(speech.utterances, ['第 3 楼，作者：作者', '内容']);
  });

  test('a floor without content is only its heading', () {
    final speech = floorSpeechOf(_post(''), heading: 'H');
    expect(speech.utterances, ['H']);
  });
}
