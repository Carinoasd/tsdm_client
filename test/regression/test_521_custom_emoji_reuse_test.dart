/// A custom emoji goes into a post as an attachment: uploaded once per account while the forum keeps that upload free
/// to use, never an attachment of another post.
///
/// Measured on the test forum (Discuz X5): the forum shows an attachment only in the post it is bound to (another
/// post's `[attachimg]aid[/attachimg]` prints nothing), and posting `attachnew[aid]` for an attachment bound to another
/// post of the same attachment table moves it out of that post. An upload stays unused (`attach.unused` of the form)
/// until a post is published with it; the forum deletes unused ones a day after the upload.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/custom_emoji/models/custom_emoji.dart';
import 'package:tsdm_client/features/custom_emoji/repository/custom_emoji_store.dart';
import 'package:tsdm_client/features/custom_emoji/utils/custom_emoji_reuse.dart';
import 'package:tsdm_client/features/custom_emoji/widgets/custom_emoji_grid.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _json(String path) =>
    jsonDecode(File('test/data/$path').readAsStringSync()) as Map<String, dynamic>;

final String _sha = 'a' * 64;

CustomEmojiAttachment _decide({
  Map<String, int> inPost = const {},
  int? remembered,
  Set<int> unused = const {},
  Set<int> used = const {},
}) => decideCustomEmojiAttachment(sha256: _sha, inPost: inPost, remembered: remembered, unused: unused, used: used);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  group('A. reuse or upload', () {
    test('never uploaded by the account: upload', () {
      expect(_decide(), isA<CustomEmojiUpload>().having((e) => e.forget, 'forget', isFalse));
    });

    test('already in this post: its code again, nothing bound twice', () {
      expect(_decide(inPost: {_sha: 7}, remembered: 9), isA<CustomEmojiInPost>().having((e) => e.aid, 'aid', 7));
    });

    test('an unused upload of the account the form lists: reused and bound to this post', () {
      expect(_decide(remembered: 9, unused: {3, 9}), isA<CustomEmojiUnused>().having((e) => e.aid, 'aid', 9));
    });

    test('an attachment of the edited post: its code, no new binding', () {
      expect(_decide(remembered: 9, used: {9}), isA<CustomEmojiInPost>().having((e) => e.aid, 'aid', 9));
    });

    test('bound to another post, or deleted by the forum: uploaded again, the old one forgotten', () {
      expect(_decide(remembered: 9, unused: {3}), isA<CustomEmojiUpload>().having((e) => e.forget, 'forget', isTrue));
    });
  });

  group('B. what the form tells', () {
    test('the unused images and the attachments of the edited post', () {
      final json = _json('tsdmapp/post_v16_reply.json');
      (json['attach'] as Map<String, dynamic>)
        ..['unused'] = [
          {'aid': 1603, 'isimage': 1, 'filename': 'a.png'},
          {'aid': 1604, 'isimage': 0, 'filename': 'a.zip'},
          {'aid': 0, 'isimage': 1, 'filename': 'x.png'},
          'junk',
        ]
        ..['used'] = [
          {'aid': 88, 'isimage': 1, 'filename': 'b.png'},
          {'aid': 89, 'isimage': 0, 'filename': 'c.rar'},
        ];
      final form = PostForm.fromJson(json)!;
      expect(form.unusedAttachmentImages, {1603});
      expect(form.usedAttachments, {88, 89});
    });

    test('none without them', () {
      final json = _json('tsdmapp/post_v16_reply.json');
      (json['attach'] as Map<String, dynamic>).remove('unused');
      final form = PostForm.fromJson(json)!;
      expect(form.unusedAttachmentImages, isEmpty);
      expect(form.usedAttachments, isEmpty);
      expect(PostForm.fromJson(_json('tsdmapp/post_v16_reply.json'))!.unusedAttachmentImages, isEmpty);
    });

    test('the image upload asks for the DISCUZUPLOAD answer (simple=2)', () {
      final upload = PostForm.fromJson(_json('tsdmapp/post_v16_reply.json'))!.attachmentUpload!;
      expect(upload.imageUrl.queryParameters['simple'], '2');
      expect(upload.imageUrl.queryParameters['type'], 'image');
    });
  });

  group('C. the uploads remembered', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('custom_emoji_uploads_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('by account, kept on the device, forgotten when stale', () async {
      final store = CustomEmojiStore(directory: () async => dir);
      await store.load();
      store
        ..rememberUpload(35, _sha, 1607)
        ..rememberUpload(31, _sha, 500);
      expect(store.uploadedAid(35, _sha), 1607);
      expect(store.uploadedAid(31, _sha), 500);
      expect(store.uploadedAid(36, _sha), isNull, reason: 'another account never shares an upload');
      store.forgetUpload(31, _sha);
      await store.pendingWrites;

      final again = CustomEmojiStore(directory: () async => dir);
      await again.load();
      expect(again.uploadedAid(35, _sha), 1607);
      expect(again.uploadedAid(31, _sha), isNull);
    });
  });

  test('D. the code a sender gives', () {
    expect(isCustomEmojiBBCode('[attachimg]1607[/attachimg]'), isTrue);
    expect(isCustomEmojiBBCode('[attachimg]x[/attachimg]'), isFalse);
    expect(isCustomEmojiBBCode('[img]https://forum.test/a.png[/img]'), isFalse);
    expect(isCustomEmojiBBCode(null), isFalse);
  });

  testWidgets('E. a tap sends the image once, its tile showing the progress', (tester) async {
    final pack = CustomEmojiPack(
      id: 'p',
      name: 'p',
      emojis: [
        CustomEmoji(sha256: _sha, ext: 'png'),
        CustomEmoji(sha256: 'b' * 64, ext: 'png'),
      ],
    );
    final sent = <String>[];
    final results = <String?>[];
    var answer = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomEmojiGrid(
            pack: pack,
            send: (emoji) {
              sent.add(emoji.sha256);
              return answer.future;
            },
            onSent: results.add,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(ValueKey('custom-emoji-pick-$_sha')));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // Another tap while one goes up: nothing.
    await tester.tap(find.byKey(ValueKey('custom-emoji-pick-${'b' * 64}')));
    await tester.pump();
    expect(sent, [_sha]);
    answer.complete('[attachimg]1607[/attachimg]');
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(results, ['[attachimg]1607[/attachimg]']);

    answer = Completer<String?>();
    await tester.tap(find.byKey(ValueKey('custom-emoji-pick-${'b' * 64}')));
    await tester.pump();
    answer.complete(null);
    await tester.pump();
    expect(results, ['[attachimg]1607[/attachimg]', null], reason: 'failed: told with nothing');
  });
}
