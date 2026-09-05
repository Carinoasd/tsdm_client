import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
import 'package:tsdm_client/utils/safe_path.dart';

/// Cache file names from the database and emoji ids from the forum must stay inside the cache directories.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('isSafeFileName', () {
    test('plain names pass', () {
      expect(isSafeFileName('3f2504e0-4f89-11d3-9a0c-0305e82c3301'), isTrue);
      expect(isSafeFileName('avatar.png'), isTrue);
      expect(isSafeFileName('..hidden'), isTrue, reason: 'a name starting with dots is still one segment');
    });

    test('traversal, separators, empty and control names fail', () {
      for (final bad in ['', '.', '..', '../x', 'a/b', r'a\b', '/etc/passwd', r'C:\x', 'a\u0000b', 'x' * 256]) {
        expect(isSafeFileName(bad), isFalse, reason: '"$bad" must be refused');
      }
    });
  });

  group('fileInside', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('tsdm_cache_path'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('resolves plain names inside the directory', () {
      final file = fileInside(dir, 'abc.png');
      expect(file, isNotNull);
      expect(file!.path, '${dir.absolute.path}/abc.png');
    });

    test('never resolves outside the directory', () {
      for (final bad in ['../outside', '../../etc/passwd', '/etc/passwd', 'sub/../../x', '..']) {
        expect(fileInside(dir, bad), isNull, reason: '"$bad" must not resolve');
      }
    });
  });

  group('emoji ids', () {
    test('only plain tokens are accepted', () {
      expect(isSafeEmojiId('20'), isTrue);
      expect(isSafeEmojiId('tsdm_1-a'), isTrue);
      for (final bad in ['', '../1', '1/2', '1 2', 'a.b', '1\u0000', 'x' * 65]) {
        expect(isSafeEmojiId(bad), isFalse, reason: '"$bad" must be refused');
      }
    });

    test('a cache info with a traversal id is invalid, even when the file it points at exists', () {
      final dir = Directory.systemTemp.createTempSync('tsdm_emoji_cache');
      addTearDown(() => dir.deleteSync(recursive: true));
      final outside = File('${dir.path}/../${dir.path.split('/').last}_outside.jpg')..writeAsStringSync('x');
      addTearDown(() => outside.existsSync() ? outside.deleteSync() : null);
      File('${dir.path}/1_20.jpg').writeAsStringSync('x');

      const good = EmojiGroupList([
        EmojiGroup(id: '1', name: 'g', routeName: 'r', emojiList: [Emoji(id: '20', code: '{:1_20:}', url: 'x')]),
      ]);
      expect(good.validateCache(dir.path), isTrue);

      final traversalId = '../${dir.path.split('/').last}_outside';
      final bad = EmojiGroupList([
        EmojiGroup(id: '1', name: 'g', routeName: 'r', emojiList: [Emoji(id: traversalId, code: 'x', url: 'x')]),
      ]);
      expect(bad.validateCache(dir.path), isFalse);
    });
  });
}
