/// The order switch of a thread whose author set it newest first (the thread status bit 4: the forum serves its floors
/// newest first when the order is not asked).
///
/// The page of the forum's app API tells the order it served (`ordertype`, [ThreadPageInfo.newestFirst]). The switch
/// took the order not asked for the oldest first: on such a thread the first switch asked for the newest first again,
/// the floors stayed as they were and the menu offered "newest first" over floors already newest first. The switch now
/// goes to the other order than the one on screen, and the menu names it the same way.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

Post _floor(int floor) => Post(
  postID: '${800000 + floor}',
  postFloor: floor,
  author: const User(name: 'u', url: 'u'),
  publishTime: DateTime(2026, 11, 13),
  data: 'floor $floor',
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: 1,
  isDraft: false,
  packetAllTaken: false,
);

/// A thread of 5 floors whose author set it newest first when [authorNewestFirst]; the order asked wins.
final class _Thread extends ThreadRepository {
  _Thread({required this.authorNewestFirst});

  final bool authorNewestFirst;

  /// The orders asked, `(reverseOrder, exactOrder)`, one per page asked.
  final asked = <(bool?, int?)>[];

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
    asked.add((reverseOrder, exactOrder));
    // The forum's `ordertype`: what was asked, else the thread's own order.
    final newestFirst = switch ((exactOrder, reverseOrder)) {
      (final int order, _) => order == 1,
      (null, final bool reverse) => reverse,
      (null, null) => authorNewestFirst,
    };
    final floors = newestFirst ? [1, 5, 4, 3, 2] : [1, 2, 3, 4, 5];
    return right(
      ThreadPageInfo(
        tid: '1130',
        title: 'thread',
        fid: 2,
        forumName: 'forum',
        currentPage: 1,
        totalPages: 1,
        havePermission: true,
        permissionDeniedMessage: null,
        needLogin: false,
        threadSoftClosed: false,
        threadClosed: false,
        postList: floors.map(_floor).toList(),
        replyParameters: null,
        threadType: null,
        isDraft: false,
        latestModAct: null,
        breadcrumbs: const [],
        postMedals: const [],
        viewCount: 1,
        replyCount: 4,
        newestFirst: newestFirst,
      ),
    );
  });
}

Future<void> _settled() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<ThreadBloc> _open(_Thread thread, {bool? reverseOrder, int? exactOrder}) async {
  final bloc = ThreadBloc(
    tid: '1130',
    pid: null,
    onlyVisibleUid: null,
    reverseOrder: reverseOrder,
    exactOrder: exactOrder,
    threadRepository: thread,
    currentUid: () => 31,
  )..add(const ThreadLoadMoreRequested(1));
  addTearDown(bloc.close);
  await _settled();
  expect(bloc.state.status, ThreadStatus.success);
  return bloc;
}

List<int?> _floors(ThreadBloc bloc) => bloc.state.postList.map((e) => e.postFloor).toList();

Future<void> _switch(ThreadBloc bloc) async {
  bloc.add(const ThreadChangeViewOrderRequested());
  await _settled();
  expect(bloc.state.status, ThreadStatus.success);
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('a thread its author set newest first: the first switch goes to the oldest first', () async {
    final thread = _Thread(authorNewestFirst: true);
    final bloc = await _open(thread);
    expect(bloc.state.shownNewestFirst, isTrue, reason: 'the page told the order it served');
    expect(_floors(bloc), [1, 5, 4, 3, 2]);

    await _switch(bloc);
    expect(thread.asked.last, (false, null), reason: 'the oldest first asked (ordertype 2), not the newest first');
    expect(bloc.state.shownNewestFirst, isFalse);
    expect(_floors(bloc), [1, 2, 3, 4, 5]);

    await _switch(bloc);
    expect(thread.asked.last, (true, null));
    expect(bloc.state.shownNewestFirst, isTrue);
    expect(_floors(bloc), [1, 5, 4, 3, 2]);
  });

  test('a thread in the forum order: the first switch goes to the newest first, as before', () async {
    final thread = _Thread(authorNewestFirst: false);
    final bloc = await _open(thread);
    expect(bloc.state.shownNewestFirst, isFalse);

    await _switch(bloc);
    expect(thread.asked.last, (true, null));
    expect(_floors(bloc), [1, 5, 4, 3, 2]);
  });

  test('a link with its own order: the switch goes to the other one, the order of the link gives way', () async {
    final thread = _Thread(authorNewestFirst: false);
    final bloc = await _open(thread, exactOrder: 1);
    expect(_floors(bloc), [1, 5, 4, 3, 2]);

    await _switch(bloc);
    expect(thread.asked.last, (false, null), reason: 'the order of the link used to win over every switch');
    expect(bloc.state.exactOrder, isNull);
    expect(_floors(bloc), [1, 2, 3, 4, 5]);
  });

  test('while the other order loads, the order on screen is the one asked', () async {
    final thread = _Thread(authorNewestFirst: true);
    final bloc = await _open(thread);
    final loading = bloc.stream.firstWhere((s) => s.status == ThreadStatus.loading);
    bloc.add(const ThreadChangeViewOrderRequested());
    final state = await loading;
    expect(state.shownNewestFirst, isFalse, reason: 'the menu names the next switch by the order asked');
    await _settled();
  });
}
