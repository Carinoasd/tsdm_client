import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/follow/models/follow_models.dart';
import 'package:tsdm_client/features/follow/utils/parse_follow.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_account_repository.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/utils/space_v4.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// Reads the lists of the followed and of the followers, and the broadcasts.
///
/// The forum's app API answers them as fields since plugin 4.0.0 (`status` lists `follow` and `feed` in
/// `space_pages`): the lists are `type: space_follow` (`schema` 60), the broadcasts `space_feed` (59), their further
/// parts the forum's own `next` until it is empty. Without it (an older plugin, the flag off, an answer that is not
/// the page) the pages are the website's, which the plugin leaves alone and which are parsed; more broadcasts are
/// then loaded as the website loads them, a fragment at a time.
final class FollowRepository {
  /// Constructor; [get] replaces the request of the shared client, [currentUid] the account in use.
  const FollowRepository({Future<SyncEither<Response<dynamic>>> Function(String url)? get, int Function()? currentUid})
    : _get = get,
      _currentUid = currentUid;

  final Future<SyncEither<Response<dynamic>>> Function(String url)? _get;

  final int Function()? _currentUid;

  AsyncEither<TsdmAppV4Answer?> _v4(String url, {required String name, required String type, required int schema}) =>
      fetchSpaceV4Page(
        url,
        name: name,
        type: type,
        schema: schema,
        get: _get,
        currentUid: _currentUid ?? currentLoginUid,
      );

  /// How many pages without a broadcast to show are skipped in one go.
  static const _maxEmptyPages = 3;

  AsyncEither<Response<dynamic>> _run(String url) =>
      AsyncEither(() => _get == null ? getIt.get<NetClientProvider>().get(url).run() : _get(url));

  /// A page of a list of members ([followListUrl], or the next page of one).
  AsyncEither<SpaceListPage<FollowUser>> fetchList(String url) => AsyncEither(() async {
    switch (await _v4(url, name: 'follow', type: 'space_follow', schema: 60).run()) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        if (spaceV4ListPageOf(value, (json) => followListPageFromApi(json, url)) case final page?) {
          return right(page);
        }
    }
    return _run(withTsdmAppJson(url)).mapHttpPage(parseFollowListPage).run();
  });

  /// A page of broadcasts of the forum's app API (plugin 4.0.0): the first page ([followFeedPageFromApi]), or a further
  /// part from [url] on, the parts without a broadcast to show skipped (no more than [_maxEmptyPages] in one go) as
  /// the website's are; null to read the website's.
  Future<Either<AppException, SpaceListPage<FollowFeed>?>> _feedV4(String url) async {
    if (!isFollowMoreFeedUrl(url)) {
      return switch (await _v4(url, name: 'feed', type: 'space_feed', schema: 59).run()) {
        Left(:final value) => left(value),
        Right(:final value) => right(spaceV4ListPageOf(value, followFeedPageFromApi)),
      };
    }
    var at = url;
    for (var empty = 0; ; empty++) {
      switch (await _v4(at, name: 'feed', type: 'space_feed', schema: 59).run()) {
        case Left(:final value):
          return left(value);
        case Right(value: TsdmAppV4Page(:final json)):
          final feeds = followFeedsFromApi(json);
          final next = followNextFeedUrlFromApi(json);
          if (feeds.isNotEmpty || next == null || empty >= _maxEmptyPages) {
            return right(SpaceListPage(items: feeds, nextPageUrl: next, session: spaceV4Session(json)));
          }
          at = next;
        case Right(:final value):
          // The forum's words (a module switched off meanwhile), or the website's fragment to read.
          return right(spaceV4ListPageOf(value, followFeedPageFromApi));
      }
    }
  }

  /// A page of broadcasts: the first one ([followFeedUrl]), or a further one ([followMoreFeedUrl]).
  ///
  /// Once the recent broadcasts end (the forum answers `false`) the ones it filed away follow from their first page;
  /// a page whose broadcasts are all gone is skipped. The list ends with the filed ones.
  AsyncEither<SpaceListPage<FollowFeed>> fetchFeed(String url) => AsyncEither(() async {
    switch (await _feedV4(url)) {
      case Left(:final value):
        return left(value);
      case Right(value: final page?):
        return right(page);
      case Right():
        return _fetchFeedWeb(url).run();
    }
  });

  AsyncEither<SpaceListPage<FollowFeed>> _fetchFeedWeb(String url) {
    if (!isFollowMoreFeedUrl(url)) {
      return _run(withTsdmAppJson(url)).mapHttpPage((document) => parseFollowFeedPage(document, url));
    }
    return AsyncEither(() async {
      var at = url;
      for (var empty = 0; ; empty++) {
        final Response<dynamic> response;
        switch (await _run(withTsdmAppJsonWrite(at)).run()) {
          case Left(:final value):
            return left(value);
          case Right(:final value):
            response = value;
        }
        final fragment = response.statusCode == HttpStatus.ok ? spaceAjaxFragmentOf(response.data) : null;
        if (fragment == null) {
          return left(HttpRequestFailedException(response.statusCode));
        }
        final feeds = parseFollowMoreFeeds(fragment);
        final position = followMoreFeedPosition(at);
        if (feeds == null && position.archive) {
          return right(const SpaceListPage(items: []));
        }
        final next = feeds == null
            ? followMoreFeedUrlAt(at, archive: true, page: 1)
            : followMoreFeedUrlAt(at, archive: position.archive, page: position.page + 1);
        if (feeds != null && (feeds.isNotEmpty || empty >= _maxEmptyPages)) {
          return right(SpaceListPage(items: feeds, nextPageUrl: next));
        }
        at = next;
      }
    });
  }
}

/// Follows members, notes names for them, relays and deletes broadcasts for one account, the one current when it was
/// built ([SpaceAccountRepository]).
final class FollowWriteRepository extends SpaceAccountRepository {
  /// Constructor.
  FollowWriteRepository({required super.client, required super.currentUid});

  /// Injectable transports; a post is never retried.
  FollowWriteRepository.withTransport({required super.currentUid, required super.getPage, required super.sendForm})
    : super.withTransport();

  static const _cp = '$baseUrl/home.php?mod=spacecp&ac=follow';

  /// Where [uid] is followed.
  static String followUrl(int uid) => '$_cp&op=add&fuid=$uid&inajax=1';

  /// Where [uid] is no longer followed.
  static String unfollowUrl(int uid) => '$_cp&op=del&fuid=$uid&inajax=1';

  /// Where the name noted for [uid] is saved.
  static String remarkUrl(int uid) => '$_cp&op=bkname&fuid=$uid&inajax=1';

  /// Where the thread [tid] is relayed.
  static String relayUrl(int tid) => '$_cp&op=relay&tid=$tid&inajax=1';

  /// Where the broadcast [feedId] is deleted.
  static String deleteFeedUrl(int feedId) => '$_cp&op=delete&feedid=$feedId&inajax=1';

  /// What the account is to the member [uid]: read from the head of the list of the members they follow, which
  /// depends on the follow module alone (the broadcasts may be switched off). The forum refuses here already with the
  /// module off (`follower_status_off`) or for a member that does not exist.
  Future<SpaceFormLoad<FollowRelation>> loadRelation(int uid) async {
    if (!isCurrent) return const SpaceFormLoad(SpaceFormLoadKind.identityChanged);
    final result = await getPage(withTsdmAppJson(followListUrl(followers: false, uid: uid)));
    if (!isCurrent) return const SpaceFormLoad(SpaceFormLoadKind.identityChanged);
    final Response<dynamic> response;
    switch (result) {
      case Left(:final value):
        error('failed to load the follow relation: $value');
        return const SpaceFormLoad(SpaceFormLoadKind.failed);
      case Right(:final value):
        response = value;
    }
    if (response.statusCode != HttpStatus.ok || tsdmAppAnswerWithoutPage(response.data)) {
      return const SpaceFormLoad(SpaceFormLoadKind.failed);
    }
    final document = tsdmAppPageDocument(response.data);
    if (parseFollowRelation(document, uid) case final relation?) {
      return relation.session.uid == ownerUid
          ? SpaceFormLoad(SpaceFormLoadKind.ready, form: relation)
          : const SpaceFormLoad(SpaceFormLoadKind.identityChanged);
    }
    final notice = spaceNoticeOf(document);
    if (notice?.needLogin ?? spaceSessionOf(document) == null) {
      return const SpaceFormLoad(SpaceFormLoadKind.loginRequired);
    }
    if (notice?.message case final String message when message.isNotEmpty) {
      return SpaceFormLoad(SpaceFormLoadKind.denied, message: message);
    }
    return const SpaceFormLoad(SpaceFormLoadKind.failed);
  }

  /// Follow [uid] with the [session] of a page, once (`follow_add_succeed` "成功关注").
  ///
  /// The website follows with a link carrying the form hash (`&hash=…`); the forum takes the same fields posted. It
  /// refuses the account itself (`follow_not_follow_self`), a member already followed (`follow_followed_ta`), a group
  /// that may not follow (`follow_not_follow_others`); a stale hash is answered a bare "Access Denied".
  Future<SpaceWriteResult> follow(SpaceSession session, int uid) async {
    if (!owns(session)) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    final result = await sendForm(followUrl(uid), {'hash': session.formHash, 'handlekey': 'followmod'});
    if (result case Right(:final value)) {
      final api = tsdmAppWriteResultOf(value.data);
      final text = api == null ? tsdmAppAnswerText(value.data) : api.documentHtml;
      if ((api == null || api.kind == TsdmAppWriteKind.page) && text.trim() == 'Access Denied') {
        return const SpaceWriteResult(SpaceWriteOutcome.rejected);
      }
    }
    return outcomeOf(result);
  }

  /// No longer follow [uid], once (`follow_cancel_succeed` "取消成功", also for a member that was not followed).
  Future<SpaceWriteResult> unfollow(SpaceSession session, int uid) async {
    if (!owns(session)) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return outcomeOf(await sendForm(unfollowUrl(uid), {'formhash': session.formHash, 'handlekey': 'followmod'}));
  }

  /// Note [name] for the followed member [uid], once (`follow_remark_succeed` "备注成功"); empty removes it.
  ///
  /// The forum strips tags and keeps the beginning (`cutstr` to 30: fifteen Chinese characters); the name it kept
  /// comes back with the result. A member not followed is `follow_not_assignation_user`.
  Future<({SpaceWriteResult result, String? remark})> remark(SpaceSession session, int uid, String name) async {
    if (!owns(session)) {
      return (result: const SpaceWriteResult(SpaceWriteOutcome.identityChanged), remark: null);
    }
    final answer = await sendForm(remarkUrl(uid), {
      'formhash': session.formHash,
      'editbkname': 'true',
      'bkname': name.trim(),
      'handlekey': 'fbkname_$uid',
    });
    final result = outcomeOf(answer);
    final kept = switch (answer) {
      Right(:final value) => tsdmAppWriteResultOf(value.data)?.json['values'],
      Left() => null,
    };
    return (
      result: result,
      remark: result.outcome != SpaceWriteOutcome.done
          ? null
          : switch (kept) {
              {'bkname': final String kept} => kept,
              _ => name.trim(),
            },
    );
  }

  /// What a note of a relay may hold, in bytes (`strlen($_GET['note']) > 140`, `follow_input_word_limit`).
  static const relayNoteMaxBytes = 140;

  /// Relay the thread [tid] with [note], once (`relay_feed_success` "转播成功"); [reply] posts the note as a reply to
  /// the thread as well, which the forum asks for from the second relay of a thread on
  /// (`follow_only_allow_the_relay_time`).
  Future<SpaceWriteResult> relay(SpaceSession session, int tid, String note, {required bool reply}) async {
    if (!owns(session)) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return outcomeOf(
      await sendForm(relayUrl(tid), {
        'formhash': session.formHash,
        'relaysubmit': 'true',
        'tid': '$tid',
        'note': note.trim(),
        if (reply) 'addnewreply': '1',
        'handlekey': 'qrelay_$tid',
      }),
    );
  }

  /// Delete the broadcast [feedId], once (`do_success`): the forum takes it from who broadcast and an administrator
  /// (`quickclear_noperm` otherwise).
  Future<SpaceWriteResult> deleteFeed(SpaceSession session, int feedId) async {
    if (!owns(session)) return const SpaceWriteResult(SpaceWriteOutcome.identityChanged);
    return outcomeOf(
      await sendForm(deleteFeedUrl(feedId), {
        'formhash': session.formHash,
        'deletesubmit': 'true',
        'handlekey': 'c_delete_$feedId',
      }),
    );
  }
}
