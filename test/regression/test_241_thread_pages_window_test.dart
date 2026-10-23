/// Reading progress round (UX audit items 1 and 6), the floors of a thread page by page:
///
/// * reading on keeps [threadWindowPages] pages, the first ones dropped; going up asks the page before and puts it
///   above, the last ones dropped;
/// * the next page is asked once while on its way, never again once on screen; a page that failed at an end keeps the
///   floors and says so there;
/// * the last page asked again adds the floors posted since;
/// * a jump to a floor works its page out from the floors per page (the forum's `ppp`, else a full page), oldest or
///   newest first, scrolls to a floor on screen without asking, and goes to the closest floor of one the thread lacks;
/// * "every author" again drops the author filter, the medal menus of every page on screen stay;
/// * [FloorLayout]: floors only ever added at the far ends, dropped ones leave empty places, never filled again.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/widgets/floor_layout.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/card/post_card/post_medal_menu_info.dart';

/// Post id of floor [floor].
String pidOf(int floor) => '${700000 + floor}';

Post _floor(int floor, int page, {bool hot = false}) => Post(
  postID: pidOf(floor),
  postFloor: hot ? null : floor,
  author: const User(name: 'u', url: 'u'),
  publishTime: DateTime(2026, 10, 23),
  data: 'floor $floor',
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: page,
  isDraft: false,
  packetAllTaken: false,
  hot: hot,
  hotFloor: hot ? floor : null,
);

ThreadPageInfo _page(
  int page,
  int pages,
  List<Post> posts, {
  int? ppp,
  int? replies,
  List<PostMedalMenuItem> medals = const [],
}) => ThreadPageInfo(
  tid: '1120',
  title: 'long thread',
  fid: 2,
  forumName: 'forum',
  currentPage: page,
  totalPages: pages,
  havePermission: true,
  permissionDeniedMessage: null,
  needLogin: false,
  threadSoftClosed: false,
  threadClosed: false,
  postList: posts,
  replyParameters: null,
  threadType: null,
  isDraft: false,
  latestModAct: null,
  breadcrumbs: const [],
  postMedals: medals,
  viewCount: 1,
  replyCount: replies,
  postsPerPage: ppp,
  paginationReplies: replies,
);

/// A thread of [floors] floors, [ppp] a page, served the way the forum pages it: oldest first page N holds floors
/// (N-1)·ppp+1 to N·ppp; newest first page 1 holds the first floor and the latest ppp-1 replies, the later pages ppp
/// replies each. Floors in [missing] are not there (deleted in a rush thread), their numbers stay.
final class _Thread extends ThreadRepository {
  _Thread({this.floors = 150, this.ppp = 10, this.tellsPpp = true});

  int floors;
  final int ppp;

  /// Whether the answer names the floors per page (the forum's app API does, a web page does not).
  bool tellsPpp;
  final asked = <int>[];
  final askedAuthors = <String?>[];
  bool failing = false;
  Completer<void>? hold;

  /// Pages held back until completed, by page.
  final holds = <int, Completer<void>>{};
  Set<int> missing = {};

  /// Medal menus of page N: `md_N`.
  bool medals = false;

  int pagesOf({required bool newestFirst}) =>
      math.max(1, newestFirst ? ((floors - 1) / ppp).ceil() : (floors / ppp).ceil());

  @override
  AsyncEither<ThreadPageInfo> fetchThreadPage({
    String? tid,
    String? pid,
    int pageNumber = 1,
    int? pageFallback,
    String? onlyVisibleUid,
    bool? reverseOrder,
    int? exactOrder,
  }) => AsyncEither(() async {
    asked.add(pageNumber);
    askedAuthors.add(onlyVisibleUid);
    if (hold case final hold?) {
      await hold.future;
    }
    if (holds[pageNumber] case final hold?) {
      await hold.future;
    }
    if (failing) {
      return left(HttpRequestFailedException(500));
    }
    final newestFirst = exactOrder == 1 || (exactOrder == null && (reverseOrder ?? false));
    final pages = pagesOf(newestFirst: newestFirst);
    final page = pageNumber.clamp(1, pages);
    final List<int> numbers;
    if (!newestFirst) {
      numbers = [for (var f = (page - 1) * ppp + 1; f <= math.min(page * ppp, floors); f++) f];
    } else {
      final first = page == 1 ? 0 : (page - 1) * ppp - 1;
      final count = page == 1 ? ppp - 1 : ppp;
      numbers = [
        if (page == 1) 1,
        for (var newer = first; newer < first + count && floors - newer >= 2; newer++) floors - newer,
      ];
    }
    return right(
      _page(
        page,
        pages,
        [
          for (final f in numbers)
            if (!missing.contains(f)) _floor(f, page),
        ],
        ppp: tellsPpp ? ppp : null,
        replies: floors - 1,
        medals: medals ? [PostMedalMenuItem(id: 'md_$page', name: 'medal $page', description: '')] : const [],
      ),
    );
  });
}

ThreadBloc _bloc(_Thread thread, {bool? reverseOrder}) => ThreadBloc(
  tid: '1120',
  pid: null,
  onlyVisibleUid: null,
  reverseOrder: reverseOrder,
  exactOrder: null,
  threadRepository: thread,
  currentUid: () => 31,
);

/// Let the bloc handle what was added.
Future<void> _settled() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

List<int?> _floors(ThreadState state) => state.postList.map((e) => e.postFloor).toList();

Future<ThreadBloc> _openAt(_Thread thread, int page, {bool? reverseOrder}) async {
  final bloc = _bloc(thread, reverseOrder: reverseOrder)..add(ThreadLoadMoreRequested(page));
  addTearDown(bloc.close);
  await _settled();
  expect(bloc.state.status, ThreadStatus.success);
  return bloc;
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('the pages kept', () {
    test('reading on keeps ten pages, the first ones dropped', () async {
      final thread = _Thread();
      final bloc = await _openAt(thread, 1);
      for (var i = 0; i < 11; i++) {
        bloc.add(ThreadLoadMoreRequested(bloc.state.currentPage + 1));
        await _settled();
      }
      expect(bloc.state.currentPage, 12);
      expect(bloc.state.firstPage, 12 - threadWindowPages + 1);
      expect(bloc.state.postList.map((e) => e.page).toSet(), {for (var p = 3; p <= 12; p++) p});
      expect(_floors(bloc.state).first, 21);
      expect(_floors(bloc.state).last, 120);
      expect(bloc.state.canLoadPrevious, isTrue);
      expect(bloc.state.canLoadMore, isTrue);
    });

    test('going up asks the page before and puts it above; the last ones dropped past ten pages', () async {
      final thread = _Thread();
      final bloc = await _openAt(thread, 12);
      expect(bloc.state.firstPage, 12);
      bloc.add(const ThreadLoadPreviousRequested());
      await _settled();
      expect(thread.asked, [12, 11]);
      expect(bloc.state.firstPage, 11);
      expect(bloc.state.currentPage, 12);
      expect(_floors(bloc.state).take(11), [101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111]);
      for (var i = 0; i < 9; i++) {
        bloc.add(const ThreadLoadPreviousRequested());
        await _settled();
      }
      expect(bloc.state.firstPage, 2);
      expect(bloc.state.currentPage, 11, reason: 'page 12 dropped');
      expect(bloc.state.canLoadMore, isTrue, reason: 'asked again when read on to it');
      expect(_floors(bloc.state).first, 11);
      expect(_floors(bloc.state).last, 110);
      // The first page: nothing above it.
      bloc.add(const ThreadLoadPreviousRequested());
      await _settled();
      expect(bloc.state.firstPage, 1);
      bloc.add(const ThreadLoadPreviousRequested());
      await _settled();
      expect(thread.asked.where((e) => e == 0), isEmpty);
      expect(thread.asked.last, 1);
    });

    test('the next page is asked once while on its way, never again once on screen', () async {
      final thread = _Thread();
      final bloc = await _openAt(thread, 1);
      thread.hold = Completer<void>();
      bloc
        ..add(const ThreadLoadMoreRequested(2))
        ..add(const ThreadLoadMoreRequested(2));
      await _settled();
      expect(bloc.state.nextStatus, ThreadEdgeStatus.loading);
      thread.hold!.complete();
      thread.hold = null;
      await _settled();
      expect(thread.asked, [1, 2]);
      expect(bloc.state.nextStatus, ThreadEdgeStatus.idle);
      bloc.add(const ThreadLoadMoreRequested(2));
      await _settled();
      expect(thread.asked, [1, 2], reason: 'page 2 is on screen');
      expect(_floors(bloc.state), [for (var f = 1; f <= 20; f++) f]);
    });

    test('a page that failed at an end keeps the floors and says so there; the retry goes on', () async {
      final thread = _Thread();
      final bloc = await _openAt(thread, 5);
      thread.failing = true;
      bloc.add(const ThreadLoadMoreRequested(6));
      await _settled();
      expect(bloc.state.status, ThreadStatus.success, reason: 'no "failed to load" page');
      expect(bloc.state.nextStatus, ThreadEdgeStatus.failed);
      expect(_floors(bloc.state), [for (var f = 41; f <= 50; f++) f]);
      bloc.add(const ThreadLoadPreviousRequested());
      await _settled();
      expect(bloc.state.previousStatus, ThreadEdgeStatus.failed);
      thread.failing = false;
      bloc
        ..add(const ThreadLoadMoreRequested(6))
        ..add(const ThreadLoadPreviousRequested());
      await _settled();
      expect(bloc.state.nextStatus, ThreadEdgeStatus.idle);
      expect(bloc.state.previousStatus, ThreadEdgeStatus.idle);
      expect(_floors(bloc.state), [for (var f = 31; f <= 60; f++) f]);
    });

    test('a page put above after the floors moved on is dropped', () async {
      final thread = _Thread();
      final bloc = await _openAt(thread, 5);
      final page4 = thread.holds[4] = Completer<void>();
      bloc.add(const ThreadLoadPreviousRequested());
      await _settled();
      expect(bloc.state.previousStatus, ThreadEdgeStatus.loading);
      // A jump replaces the floors meanwhile, then page 4 arrives.
      bloc.add(const ThreadJumpPageRequested(9));
      await _settled();
      page4.complete();
      await _settled();
      expect(thread.asked, [5, 4, 9]);
      expect(bloc.state.firstPage, 9);
      expect(bloc.state.previousStatus, ThreadEdgeStatus.idle);
      expect(_floors(bloc.state), [for (var f = 81; f <= 90; f++) f]);
    });

    test('the last page asked again adds the floors posted since, once', () async {
      final thread = _Thread(floors: 25);
      final bloc = await _openAt(thread, 3);
      expect(bloc.state.canLoadMore, isFalse);
      thread.floors = 28;
      bloc.add(const ThreadLoadNewRepliesRequested());
      await _settled();
      expect(thread.asked, [3, 3]);
      expect(_floors(bloc.state), [for (var f = 21; f <= 28; f++) f]);
      expect(bloc.state.newRepliesSerial, 1);
      expect(bloc.state.newRepliesCount, 3);
      // Nothing new.
      bloc.add(const ThreadLoadNewRepliesRequested());
      await _settled();
      expect(bloc.state.newRepliesSerial, 2);
      expect(bloc.state.newRepliesCount, 0);
      // A new page opened: the next one is there to read on to.
      thread.floors = 33;
      bloc.add(const ThreadLoadNewRepliesRequested());
      await _settled();
      expect(_floors(bloc.state).last, 30);
      expect(bloc.state.canLoadMore, isTrue);
      expect(bloc.state.totalPages, 4);
    });

    test('the medal menus of every page on screen stay', () async {
      final thread = _Thread()..medals = true;
      final bloc = await _openAt(thread, 1);
      bloc.add(const ThreadLoadMoreRequested(2));
      await _settled();
      expect(bloc.state.postMedals.map((e) => e.id), ['md_1', 'md_2']);
    });

    test('"every author" again drops the author filter', () async {
      final thread = _Thread();
      final bloc = await _openAt(thread, 1);
      bloc.add(const ThreadOnlyViewAuthorRequested('42'));
      await _settled();
      expect(bloc.state.onlyVisibleUid, '42');
      bloc.add(ThreadViewAllAuthorsRequested());
      await _settled();
      expect(bloc.state.onlyVisibleUid, isNull, reason: 'used to be put back');
      bloc.add(ThreadLoadMoreRequested(bloc.state.currentPage + 1));
      await _settled();
      expect(thread.askedAuthors.last, isNull, reason: 'the next page of every author');
    });
  });

  group('jump to a floor', () {
    test('on screen: scrolled to, nothing asked', () async {
      final thread = _Thread();
      final bloc = await _openAt(thread, 2);
      bloc.add(const ThreadJumpToFloorRequested(17));
      await _settled();
      expect(thread.asked, [2]);
      expect(bloc.state.scrollTargetPid, pidOf(17));
      expect(bloc.state.scrollTargetSerial, 1);
      expect(bloc.state.jumpFloorMissed, isNull);
    });

    test('oldest first: the page from the floors per page of the answer', () async {
      final thread = _Thread(ppp: 15);
      final bloc = await _openAt(thread, 1);
      bloc.add(const ThreadJumpToFloorRequested(77));
      await _settled();
      expect(thread.asked, [1, 6]);
      expect(bloc.state.firstPage, 6);
      expect(bloc.state.scrollTargetPid, pidOf(77));
      expect(bloc.state.generation, 1, reason: 'the list starts over at that page');
    });

    test('a web page tells the floors per page by a full page', () async {
      final thread = _Thread(ppp: 20, tellsPpp: false);
      final bloc = await _openAt(thread, 2);
      expect(bloc.state.postsPerPage, 20);
      bloc.add(const ThreadJumpToFloorRequested(95));
      await _settled();
      expect(thread.asked, [2, 5]);
      expect(bloc.state.scrollTargetPid, pidOf(95));
    });

    test('newest first: counted from the highest floor, the page before or after asked when off', () async {
      final thread = _Thread(floors: 302);
      final bloc = await _openAt(thread, 1, reverseOrder: true);
      expect(_floors(bloc.state), [1, 302, 301, 300, 299, 298, 297, 296, 295, 294]);
      bloc.add(const ThreadJumpToFloorRequested(250));
      await _settled();
      // 52 floors are newer: page 1 holds 9 of them, page 2 the next 10…
      expect(thread.asked.last, 6);
      expect(bloc.state.scrollTargetPid, pidOf(250));
      // A reply count gone stale: the page worked out is off, the next one is asked.
      thread.floors = 312;
      bloc.add(const ThreadJumpToFloorRequested(150));
      await _settled();
      expect(bloc.state.scrollTargetPid, pidOf(150));
      expect(thread.asked.length, lessThanOrEqualTo(6));
    });

    test('a floor the thread lacks: the closest one, and the page says so', () async {
      final thread = _Thread()..missing = {33};
      final bloc = await _openAt(thread, 1);
      bloc.add(const ThreadJumpToFloorRequested(33));
      await _settled();
      expect(bloc.state.scrollTargetPid, pidOf(34));
      expect(bloc.state.jumpFloorMissed, 33);
      // Past the last floor: the last one.
      bloc.add(const ThreadJumpToFloorRequested(9999));
      await _settled();
      expect(bloc.state.scrollTargetPid, pidOf(150));
      expect(bloc.state.jumpFloorMissed, 9999);
    });

    test('going on with the reading: the post on its page first, its floor when it moved', () async {
      final thread = _Thread();
      final bloc = _bloc(thread)..add(ThreadJumpToFloorRequested(44, pid: pidOf(44), page: 5));
      addTearDown(bloc.close);
      await _settled();
      expect(thread.asked, [5]);
      expect(bloc.state.scrollTargetPid, pidOf(44));
      expect(bloc.state.firstPage, 5);
    });
  });

  group('FloorLayout', () {
    List<Post> pages(int from, int to, {int ppp = 3}) => [
      for (var p = from; p <= to; p++)
        for (var i = 1; i <= ppp; i++) _floor((p - 1) * ppp + i, p),
    ];
    List<String> keys(Iterable<FloorSlot> slots) => [for (final s in slots) s.isDropped ? '-' : s.post!.postID];

    test('new floors go to the far ends only; dropped ones leave empty places that are never filled again', () {
      final layout = FloorLayout()..layOut(pages(5, 5), 0);
      expect(keys(layout.below), [pidOf(13), pidOf(14), pidOf(15)]);
      expect(layout.above, isEmpty);

      // The page before: above.
      layout.layOut(pages(4, 5), 0);
      expect(keys(layout.above), [pidOf(10), pidOf(11), pidOf(12)]);
      expect(layout.aboveItem(0).post!.postID, pidOf(12), reason: 'nearest to the opening place first');
      // The page after: below.
      layout.layOut(pages(4, 6), 0);
      expect(keys(layout.below), [for (var f = 13; f <= 18; f++) pidOf(f)]);

      // Reading on drops page 4 (far end, removed) and page 5 (empty places at the opening place).
      layout.layOut(pages(6, 7), 0);
      expect(layout.above, isEmpty);
      expect(keys(layout.below), ['-', '-', '-', for (var f = 16; f <= 21; f++) pidOf(f)]);
      expect(layout.hasDropped, isTrue);

      // Going up again: page 5 goes above, the empty places stay empty.
      layout.layOut(pages(5, 7), 0);
      expect(keys(layout.above), [pidOf(13), pidOf(14), pidOf(15)]);
      expect(keys(layout.below).take(3), ['-', '-', '-']);
      expect(layout.posts.map((e) => e.postFloor), [for (var f = 13; f <= 21; f++) f]);

      // Going up past ten pages drops the last ones at the end of the list.
      layout.layOut(pages(5, 6), 0);
      expect(keys(layout.below), ['-', '-', '-', pidOf(16), pidOf(17), pidOf(18)]);
    });

    test('items keep their index while laid out again', () {
      final layout = FloorLayout()..layOut(pages(5, 6), 0);
      final index16 = layout.belowItemIndexOf(floorKeyOf(_floor(16, 6)));
      layout
        ..layOut(pages(3, 6), 0)
        ..layOut(pages(3, 8), 0);
      expect(layout.belowItemIndexOf(floorKeyOf(_floor(16, 6))), index16);
      final index9 = layout.aboveItemIndexOf(floorKeyOf(_floor(9, 3)));
      layout.layOut(pages(2, 8), 0);
      expect(layout.aboveItemIndexOf(floorKeyOf(_floor(9, 3))), index9);
    });

    test('a new generation starts over; page starts after the first page get their divider', () {
      final layout = FloorLayout()
        ..layOut(pages(5, 6), 0)
        ..layOut(pages(1, 2), 1);
      expect(layout.above, isEmpty);
      expect(keys(layout.below), [for (var f = 1; f <= 6; f++) pidOf(f)]);
      expect(layout.pageStarts, {floorKeyOf(_floor(4, 2))});
      layout.layOut([_floor(1, 1, hot: true), ...pages(1, 2)], 1);
      expect(layout.pageStarts, {floorKeyOf(_floor(4, 2))}, reason: 'a hot reply is on page 1');
    });
  });
}
