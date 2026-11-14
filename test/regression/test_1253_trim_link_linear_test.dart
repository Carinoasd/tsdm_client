/// The end of a link found in a piece of text is trimmed in time linear in its length (`_trimLink` of
/// `forum_link_in_text.dart`).
///
/// The trim took one character off per round and counted the brackets of the whole link again each round: a link
/// followed by a long run of closing brackets (`…tid=1))))…`, pasted or read from the clipboard) took time quadratic
/// in its length, on the UI thread. What is trimmed is unchanged.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/open_in_app/utils/forum_link_in_text.dart';

const _link = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1';

/// The median time, in microseconds, to find the link in [text] (of [runs] runs).
int _medianMicros(String text, {int runs = 5}) {
  final times = <int>[];
  for (var i = 0; i < runs; i++) {
    final watch = Stopwatch()..start();
    findForumLinkInText(text);
    times.add(watch.elapsedMicroseconds);
  }
  times.sort();
  return times[runs ~/ 2];
}

void main() {
  test('the trim keeps what it trimmed before', () {
    for (final (text, url) in [
      ('($_link)', _link),
      ('($_link).', _link),
      ('[$_link].', _link),
      ("'$_link'", _link),
      ('"$_link",', _link),
      ('$_link)).', _link),
      ('$_link.).].', _link),
      ('$_link&a=(1)', '$_link&a=(1)'),
      ('$_link&a=[1])', '$_link&a=%5B1%5D'),
      ('($_link&a=(1)))', '$_link&a=(1)'),
    ]) {
      expect(findForumLinkInText(text)?.url, url, reason: text);
    }
  });

  test('a link followed by a long run of closing brackets and punctuation is trimmed in linear time', () {
    String closing(int n) => '$_link${'.)' * n}${')' * n}${'].' * n}';
    const small = 2000;
    const large = small * 8;
    // Warm up: the first runs compile the code.
    _medianMicros(closing(small));
    _medianMicros(closing(large));

    expect(findForumLinkInText(closing(large))?.url, _link);
    final ratio = _medianMicros(closing(large)) / _medianMicros(closing(small)).clamp(1, 1 << 62);
    // Eight times the text: about eight times the time when linear, sixty-four times when quadratic.
    expect(ratio, lessThan(24), reason: 'time ratio $ratio for 8x the input');
  });
}
