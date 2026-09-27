import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/blocking/models/website_blocklist.dart';
import 'package:tsdm_client/features/blocking/repository/website_blocklist_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';

import 'fixtures/website_blocklist_fixtures.dart';

/// Website blacklist (#126) against a synthetic forum: the list and lookup are read-only, a write is sent once from a
/// fresh form of exactly the chosen user, and the list read afterwards decides the result, also when the answer to
/// the write is lost. No live request, token or account.
NetClientProvider _clientOf(BlocklistForum forum) =>
    NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() {
    getIt
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver());
  });

  tearDown(getIt.reset);

  const repo = WebsiteBlocklistRepository();

  group('reads', () {
    test('the list is read from the plugin page', () async {
      final forum = BlocklistForum(listed: {2001: 'Alpha'});
      final result = await repo.fetchList(_clientOf(forum), uid: blocklistOwner);
      final list = result.getOrElse((e) => fail('$e'));
      expect(list.rows.map((e) => e.uid), [2001]);
      expect((list.quota?.used, list.quota?.limit), (1, 10));
      // The client adds its desktop layout flag; the plugin query is exactly the settings link.
      expect(
        Map.of(forum.gets.single.queryParameters)..remove('mobile'),
        {'mod': 'spacecp', 'ac': 'plugin', 'id': 'blockuser:spacecp'},
      );
      expect(forum.posts, isEmpty);
    });

    test('an unknown answer is a failure, never an empty list', () async {
      final forum = BlocklistForum()..listOverride = '<html><body>maintenance</body></html>';
      final result = await repo.fetchList(_clientOf(forum), uid: blocklistOwner);
      expect(result.isLeft(), isTrue);
    });

    test('a transport error is a network failure', () async {
      final forum = BlocklistForum()..failListAfter = 0;
      final result = await repo.fetchList(_clientOf(forum), uid: blocklistOwner);
      expect(result.getLeft().toNullable()?.failure, WebsiteBlocklistFailure.network);
    });

    test('the lookup only reads and returns the member the forum shows', () async {
      final forum = BlocklistForum();
      final result = await repo.lookup(_clientOf(forum), uid: blocklistOwner, target: 2003);
      final found = result.getOrElse((e) => fail('$e'));
      expect((found.uid, found.username, found.canAdd, found.alreadyListed), (2003, 'Charlie', true, false));
      expect(forum.gets.single.queryParameters['bu_q'], '2003');
      expect(forum.posts, isEmpty);

      final missing = await repo.lookup(_clientOf(forum), uid: blocklistOwner, target: 2999);
      expect(missing.getLeft().toNullable()?.failure, WebsiteBlocklistFailure.notFound);
      expect(forum.posts, isEmpty);
    });
  });

  group('add', () {
    test('one post from a fresh lookup form, confirmed by the reloaded list', () async {
      final forum = BlocklistForum(listed: {2001: 'Alpha'});
      final result = await repo.add(_clientOf(forum), uid: blocklistOwner, target: 2003, expectedName: 'Charlie');
      expect(result.isSuccess, isTrue);
      expect(result.list!.contains(2003), isTrue);
      expect(result.list!.contains(2001), isTrue);
      expect(forum.posts, hasLength(1));
      expect(forum.posts.single.form, {'formhash': blocklistToken, 'blockuseradd': blocklistAddFlag, 'buid': '2003'});
      expect(Map.of(forum.posts.single.uri.queryParameters)..remove('mobile'), websiteBlocklistQuery);
      expect(result.sent, isTrue);
      // Fresh lookup before, list after.
      expect(forum.gets.map((e) => e.queryParameters['bu_q']), ['2003', null]);
    });

    test('a member already listed sends nothing', () async {
      final forum = BlocklistForum(listed: {2003: 'Charlie'});
      final result = await repo.add(_clientOf(forum), uid: blocklistOwner, target: 2003);
      expect((result.isSuccess, result.alreadyApplied), (true, true));
      expect(forum.posts, isEmpty);
    });

    test('a member removed between lookup and reload is not reported as already blocked', () async {
      final forum = BlocklistForum(listed: {2003: 'Charlie'})
        ..listOverride = blocklistPage(quota: blocklistQuota(0, 10));
      final result = await repo.add(_clientOf(forum), uid: blocklistOwner, target: 2003);
      expect(result.isSuccess, isFalse);
      expect(result.error?.failure, WebsiteBlocklistFailure.notListed);
      expect(result.list!.contains(2003), isFalse);
      expect(result.sent, isFalse);
      expect(forum.posts, isEmpty);
    });

    test('a lookup showing another name than the confirmed one sends nothing', () async {
      final forum = BlocklistForum();
      final result = await repo.add(_clientOf(forum), uid: blocklistOwner, target: 2003, expectedName: 'Someone');
      expect(result.error?.failure, WebsiteBlocklistFailure.targetMismatch);
      expect(forum.posts, isEmpty);
    });

    test('a lookup form without a token or for another member sends nothing', () async {
      final forum = BlocklistForum()
        ..lookupOverride = blocklistPage(
          quota: blocklistQuota(0, 10),
          confirmation: blocklistConfirmation(2003, 'Charlie', token: ''),
        );
      var result = await repo.add(_clientOf(forum), uid: blocklistOwner, target: 2003);
      expect(result.error?.failure, WebsiteBlocklistFailure.unsupported);
      expect(result.sent, isFalse);

      forum.lookupOverride = blocklistPage(
        quota: blocklistQuota(0, 10),
        confirmation: blocklistConfirmation(2003, 'Charlie', targetValue: '2004'),
      );
      result = await repo.add(_clientOf(forum), uid: blocklistOwner, target: 2003);
      expect(result.error?.failure, WebsiteBlocklistFailure.targetMismatch);
      expect(forum.posts, isEmpty);
    });

    test('the account itself is never sent', () async {
      final forum = BlocklistForum();
      final result = await repo.add(_clientOf(forum), uid: blocklistOwner, target: blocklistOwner);
      expect(result.isSuccess, isFalse);
      expect(forum.gets, isEmpty);
      expect(forum.posts, isEmpty);
    });

    test('a refusal (full list) is shown with the forum text and the list is read again', () async {
      final forum = BlocklistForum(listed: {2001: 'Alpha'})..refuseWith = 'synthetic list full';
      final result = await repo.add(_clientOf(forum), uid: blocklistOwner, target: 2003);
      expect(result.error?.failure, WebsiteBlocklistFailure.forumError);
      expect(result.error?.message, 'synthetic list full');
      expect(result.list!.contains(2003), isFalse);
      expect(forum.posts, hasLength(1));
    });

    test('a redirect answer is verified by the list, not trusted', () async {
      final forum = BlocklistForum()..redirectWrites = true;
      final result = await repo.add(_clientOf(forum), uid: blocklistOwner, target: 2003);
      expect(result.isSuccess, isTrue);
      expect(forum.posts, hasLength(1));
    });

    test('a lost answer is never retried; the list read after it decides', () async {
      final applied = BlocklistForum()
        ..failPost = true
        ..applyBeforeFailing = true;
      final ok = await repo.add(_clientOf(applied), uid: blocklistOwner, target: 2003);
      expect(ok.isSuccess, isTrue, reason: 'the list shows the member now, it was absent before');
      expect(applied.posts, hasLength(1));

      final lost = BlocklistForum()..failPost = true;
      final unknown = await repo.add(_clientOf(lost), uid: blocklistOwner, target: 2003);
      expect(unknown.error?.failure, WebsiteBlocklistFailure.unknownAfterSubmit);
      expect(unknown.list, isNotNull);
      expect(lost.posts, hasLength(1));
    });

    test('an accepted write the list does not show is not confirmed', () async {
      final forum = BlocklistForum()..ignoreWrites = true;
      final result = await repo.add(_clientOf(forum), uid: blocklistOwner, target: 2003);
      expect(result.error?.failure, WebsiteBlocklistFailure.unknownAfterSubmit);
      expect(forum.posts, hasLength(1));
    });

    test('a list that can not be read after the write leaves the result unknown', () async {
      // The lookup is not a list read: the first list read is the one after the write.
      final forum = BlocklistForum()..failListAfter = 0;
      final result = await repo.add(_clientOf(forum), uid: blocklistOwner, target: 2003);
      expect(result.error?.failure, WebsiteBlocklistFailure.unknownAfterSubmit);
      expect(result.list, isNull);
      expect(forum.posts, hasLength(1));
    });
  });

  group('remove', () {
    test('one post from the fresh row form, confirmed by absence in the reloaded complete list', () async {
      final forum = BlocklistForum(listed: {2001: 'Alpha', 2002: 'Bravo'});
      final result = await repo.remove(_clientOf(forum), uid: blocklistOwner, target: 2001);
      expect(result.isSuccess, isTrue);
      expect(result.list!.rows.map((e) => e.uid), [2002]);
      expect(
        forum.posts.single.form,
        {'formhash': blocklistToken, 'blockuserdel': blocklistRemoveFlag, 'buid': '2001'},
      );
      expect(forum.gets, hasLength(2));
    });

    test('a user not listed any more sends nothing', () async {
      final forum = BlocklistForum(listed: {2002: 'Bravo'});
      final result = await repo.remove(_clientOf(forum), uid: blocklistOwner, target: 2001);
      expect((result.isSuccess, result.alreadyApplied), (true, true));
      expect(forum.posts, isEmpty);
    });

    test('a row whose form is not understood sends nothing', () async {
      final forum = BlocklistForum()
        ..listOverride = blocklistPage(
          rows: [blocklistRow(2001, 'Alpha', token: '')],
          quota: blocklistQuota(1, 10),
        );
      final result = await repo.remove(_clientOf(forum), uid: blocklistOwner, target: 2001);
      expect(result.error?.failure, WebsiteBlocklistFailure.unsupported);
      expect(forum.posts, isEmpty);
    });

    test('a page without the list table is never read as an empty list', () async {
      final forum = BlocklistForum(listed: {2001: 'Alpha'})
        ..listOverride = blocklistDocument('<div id="bu_page"><div id="bu_quota">${blocklistQuota(0, 10)}</div></div>');
      final result = await repo.remove(_clientOf(forum), uid: blocklistOwner, target: 2001);
      expect(result.error?.failure, WebsiteBlocklistFailure.unsupported);
      expect(result.alreadyApplied, isFalse);
      expect(forum.posts, isEmpty);
    });

    test('absence in an incomplete list does not confirm a removal', () async {
      // The page stays as it was: it still shows the row after the write.
      final forum = BlocklistForum(listed: {2001: 'Alpha'})
        ..listOverride = blocklistPage(rows: [blocklistRow(2001, 'Alpha')], quota: blocklistQuota(1, 10));
      final first = await repo.remove(_clientOf(forum), uid: blocklistOwner, target: 2001);
      expect(first.isSuccess, isFalse, reason: 'the fixed page still shows the row');
      expect(forum.posts, hasLength(1));

      forum
        ..listed.clear()
        ..listOverride = blocklistPage(quota: blocklistQuota(1, 10));
      final second = await repo.remove(_clientOf(forum), uid: blocklistOwner, target: 2001);
      expect(second.error?.failure, WebsiteBlocklistFailure.notListed, reason: 'an incomplete list proves nothing');
      expect(forum.posts, hasLength(1));
    });

    test('a page of another account is refused before anything is sent', () async {
      final forum = BlocklistForum(listed: {2001: 'Alpha'})..pageUid = 1001;
      final result = await repo.remove(_clientOf(forum), uid: blocklistOwner, target: 2001);
      expect(result.error?.failure, WebsiteBlocklistFailure.accountMismatch);
      expect(forum.posts, isEmpty);
    });
  });

  group('operation validity', () {
    test('an operation that is not current any more reads and sends nothing', () async {
      final forum = BlocklistForum(listed: {2001: 'Alpha'});
      final removed = await repo.remove(_clientOf(forum), uid: blocklistOwner, target: 2001, stillCurrent: () => false);
      final added = await repo.add(_clientOf(forum), uid: blocklistOwner, target: 2003, stillCurrent: () => false);
      for (final result in [removed, added]) {
        expect((result.error?.failure, result.sent), (WebsiteBlocklistFailure.accountMismatch, false));
      }
      expect(forum.gets, isEmpty);
      expect(forum.posts, isEmpty);
    });

    for (final add in [true, false]) {
      test('an ${add ? 'add' : 'remove'} that expires while its fresh form is read sends nothing', () async {
        final gate = Completer<void>();
        final forum = BlocklistForum(listed: {2001: 'Alpha'});
        if (add) {
          forum.lookupGate = gate;
        } else {
          forum.listGate = gate;
        }
        var current = true;
        final pending = add
            ? repo.add(_clientOf(forum), uid: blocklistOwner, target: 2003, stillCurrent: () => current)
            : repo.remove(_clientOf(forum), uid: blocklistOwner, target: 2001, stillCurrent: () => current);
        for (var i = 0; i < 100 && forum.gets.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(forum.gets, hasLength(1));
        current = false;
        gate.complete();
        final result = await pending;
        expect((result.isSuccess, result.sent), (false, false));
        expect(forum.posts, isEmpty);
        expect(forum.gets, hasLength(1), reason: 'nothing is read after an expired operation either');
      });
    }
  });
}
