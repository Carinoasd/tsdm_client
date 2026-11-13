/// The panel's 推荐主题 (`forum.php?mod=modcp&action=forum&op=recommend`) read from the web page: the forum's app API
/// answers no fields for it (`tsdmapp=json` gives the page back as it is).
///
/// * Each row: the thread, its place, the title shown in the list, the author (empty for an anonymous thread), who
///   recommended it (a moderator linked, `System` for the forum's own), until when (`yyyy-M-d HH:mm`, empty for no
///   end); the forums of the panel's select; the form hash and forum of the form.
/// * A forum ordering the list itself (`modrecommend.sort` 1) prints the fields `readonly`: the list is read only.
/// * No thread recommended (`div.emp`): the forum with an empty list. The panel's line after a post
///   (推荐主题更新成功) is kept.
/// * Not the page (no permission, the forum's message): null.
/// * The body posts every row (the panel saves each row posted), the changes and the threads taken off as indexed keys.
///
/// Fixtures `test/data/modcp_recommend/*.html`: the test forum's pages cut to the panel, cleaned.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_recommend.dart';
import 'package:universal_html/parsing.dart';

String _raw(String name) => File('test/data/modcp_recommend/$name.html').readAsStringSync();

RecommendList? _parse(String name, {int uid = 33}) => parseRecommendList(parseHtmlDocument(_raw(name)), uid: uid);

void main() {
  group('list', () {
    test('a forum ordering it by hand: the rows, the forums, the form', () {
      final list = _parse('editable')!;
      expect(list.uid, 33);
      expect(list.fid, 6);
      expect(list.editable, isTrue);
      expect(list.formHash, isNotEmpty);
      expect(list.message, isEmpty);
      expect(list.forums.map((e) => e.fid), containsAll([2, 6, 7, 25]));
      expect(list.threads.map((e) => e.tid), [9199891, 9199890]);
      final first = list.threads.first;
      expect(first.order, 1);
      expect(first.subject, '本周推荐 <新番>');
      expect(first.author, 'ag_low2');
      expect(first.authorUid, 35);
      expect(first.recommender, 'ag_mid');
      expect(first.recommenderUid, 33);
      expect(first.expiration, '2027-1-2 03:04');
      expect(list.threads.last.order, 2);
      expect(list.threads.last.expiration, isEmpty);
    });

    test('a forum ordering it itself: read only, the forum as recommender, an anonymous author', () {
      final list = _parse('auto')!;
      expect(list.fid, 25);
      expect(list.editable, isFalse);
      expect(list.threads, hasLength(10));
      expect(list.threads.map((e) => e.recommender).toSet(), {'System'});
      expect(list.threads.map((e) => e.recommenderUid).toSet(), {null});
      final anonymous = list.threads.firstWhere((e) => e.tid == 9199069);
      expect(anonymous.author, isEmpty);
    });

    test('a row not as the panel prints it: read only, nothing posted empty', () {
      final missing = _raw('editable').replaceFirst(RegExp(r'<input type="text" name="subject\[9199890\]"[^>]*>'), '');
      final list = parseRecommendList(parseHtmlDocument(missing), uid: 33)!;
      expect(list.threads, hasLength(2));
      expect(list.editable, isFalse);
      final badOrder = _raw('editable').replaceFirst(
        RegExp(r'name="order\[9199890\]" class="px" size="3" value="\d+"'),
        'name="order[9199890]" class="px" size="3" value="x"',
      );
      expect(parseRecommendList(parseHtmlDocument(badOrder), uid: 33)!.editable, isFalse);
    });

    test('no thread recommended: the forum, an empty list', () {
      final list = _parse('empty')!;
      expect(list.fid, 7);
      expect(list.threads, isEmpty);
      expect(list.forums, isNotEmpty);
    });

    test("the panel's line after a post", () {
      expect(_parse('saved')!.message, '推荐主题更新成功，请继续操作');
    });

    test('not the page: null', () {
      expect(_parse('noperm'), isNull);
      expect(_parse('message'), isNull);
      expect(_parse('bad_expiration'), isNull);
    });

    test('the menu offers it', () {
      expect(modcpMenuOf(parseHtmlDocument(_raw('editable')))!.canRecommend, isTrue);
      expect(modcpMenuOf(parseHtmlDocument(_raw('noperm')))!.canRecommend, isFalse);
    });
  });

  group('form', () {
    test('every row posted, the changes and the threads taken off', () {
      final list = _parse('editable')!;
      final body = list.body(
        edits: {9199890: (order: 0, subject: '新标题', expiration: '2027-3-4 05:06')},
        remove: {9199891},
      );
      expect(body['formhash'], list.formHash);
      expect(body['op'], 'recommend');
      expect(body['fid'], '6');
      expect(body['editsubmit'], 'yes');
      expect(body['delete[0]'], '9199891');
      expect(body['order[9199891]'], '1');
      expect(body['subject[9199891]'], '本周推荐 <新番>');
      expect(body['expirationrecommend[9199891]'], '2027-1-2 03:04');
      expect(body['order[9199890]'], '0');
      expect(body['subject[9199890]'], '新标题');
      expect(body['expirationrecommend[9199890]'], '2027-3-4 05:06');
      expect(body.keys.where((k) => k.startsWith('delete')), ['delete[0]']);
    });

    test('the urls', () {
      expect(RecommendList.url(fid: 6), '$baseUrl/forum.php?mod=modcp&action=forum&op=recommend&fid=6');
      expect(RecommendList.url(), '$baseUrl/forum.php?mod=modcp&action=forum&op=recommend');
      expect(RecommendList.submitUrl, '$baseUrl/forum.php?mod=modcp&action=forum');
    });

    test('the end as the panel prints and reads it', () {
      expect(recommendExpirationTime('2027-1-2 03:04'), DateTime(2027, 1, 2, 3, 4));
      expect(recommendExpirationTime(''), isNull);
      expect(recommendExpirationTime('2027/1/2'), isNull);
      expect(recommendExpirationText(DateTime(2027, 1, 2, 3, 4)), '2027-1-2 03:04');
      expect(recommendExpirationText(DateTime(2027, 11, 20, 13, 45)), '2027-11-20 13:45');
    });
  });
}
