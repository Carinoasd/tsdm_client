/// Reading progress round (UX audit items 1 and 2), the list of floors:
///
/// * it opens at the start of its floors, the title shown;
/// * the page after the last one is asked before the end is reached, without pulling past it;
/// * a page put above (scrolled up to it) and the pages dropped at the top while reading on never move what is on
///   screen;
/// * "page N" between the pages; the end of the thread tells the floors and offers a reply and the new replies;
/// * a floor asked for is brought to the top; the floor at the top is told (page indicator, reading position);
/// * pulled down at the start of the thread it refreshes, above a page in the middle it does not.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

Post _floor(int floor, int page) => Post(
  postID: '${700000 + floor}',
  postFloor: floor,
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
);

List<Post> _pages(int from, int to, {int ppp = 10}) => [
  for (var p = from; p <= to; p++)
    for (var i = 1; i <= ppp; i++) _floor((p - 1) * ppp + i, p),
];

/// Hosts a [PostList] the way the thread page does, its floors and ends set by the test.
class _Host extends StatefulWidget {
  const _Host({required this.controller, required this.posts, this.firstPage = 1, this.floorHeight = 200, super.key});

  final ScrollController controller;
  final List<Post> posts;
  final int firstPage;
  final double floorHeight;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late List<Post> posts = widget.posts;
  late int firstPage = widget.firstPage;
  late int lastPage = posts.last.page;
  int totalPages = 30;
  int generation = 0;
  ThreadEdgeStatus next = ThreadEdgeStatus.idle;
  ThreadEdgeStatus previous = ThreadEdgeStatus.idle;
  String? target;
  int serial = 0;
  Widget? end;

  int nextCalls = 0;
  int previousCalls = 0;
  int refreshCalls = 0;
  final tops = <({int floor, bool atThreadTop})>[];

  void show(List<Post> posts, {int? firstPage, int? lastPage, int? generation}) => setState(() {
    this.posts = posts;
    this.firstPage = firstPage ?? this.firstPage;
    this.lastPage = lastPage ?? posts.last.page;
    this.generation = generation ?? this.generation;
    next = ThreadEdgeStatus.idle;
    previous = ThreadEdgeStatus.idle;
  });

  void scrollTo(int floor) => setState(() {
    target = '${700000 + floor}';
    serial++;
  });

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => JumpPageCubit(),
    child: Builder(
      builder: (context) => Scaffold(
        body: PostList(
          threadID: '1120',
          title: 'Thread title',
          postList: posts,
          widgetBuilder: (_, post) => SizedBox(
            height: widget.floorHeight,
            child: Text('floor ${post.postFloor}', key: ValueKey('floor-${post.postFloor}')),
          ),
          canLoadMore: lastPage < totalPages,
          scrollController: widget.controller,
          latestModAct: null,
          useDivider: true,
          generation: generation,
          firstPage: firstPage,
          lastPage: lastPage,
          nextStatus: next,
          previousStatus: previous,
          scrollTargetPid: target,
          scrollTargetSerial: serial,
          endOfThread: end,
          onLoadNext: () => setState(() {
            nextCalls++;
            next = ThreadEdgeStatus.loading;
          }),
          onLoadPrevious: () => setState(() {
            previousCalls++;
            previous = ThreadEdgeStatus.loading;
          }),
          onRefresh: () => refreshCalls++,
          onTopFloorChanged: (post, {required atThreadTop}) =>
              tops.add((floor: post.postFloor!, atThreadTop: atThreadTop)),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });

  Future<(ThreadScrollController, GlobalKey<_HostState>)> pump(
    WidgetTester tester,
    List<Post> posts, {
    int firstPage = 1,
    double floorHeight = 200,
  }) async {
    final controller = ThreadScrollController();
    addTearDown(controller.dispose);
    final key = GlobalKey<_HostState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _Host(controller: controller, posts: posts, firstPage: firstPage, floorHeight: floorHeight, key: key),
      ),
    );
    await tester.pump();
    await tester.pump();
    return (controller, key);
  }

  Finder floor(int n) => find.byKey(ValueKey('floor-$n'));
  double topOf(WidgetTester tester, int n) => tester.getTopLeft(floor(n)).dy;

  /// Drag the list by [dy] (negative: towards the end) and let it come to rest.
  Future<void> drag(WidgetTester tester, double dy) async {
    await tester.drag(find.byType(CustomScrollView), Offset(0, dy), touchSlopY: 0);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('opens at the start of the floors, the title shown', (tester) async {
    final (controller, key) = await pump(tester, _pages(1, 1));
    expect(controller.offset, controller.position.minScrollExtent);
    expect(tester.getTopLeft(find.text('Thread title')).dy, closeTo(8, 0.5));
    expect(key.currentState!.tops.last, (floor: 1, atThreadTop: true));
  });

  testWidgets('the next page is asked before the end is reached, then goes on below without moving anything', (
    tester,
  ) async {
    final (controller, key) = await pump(tester, _pages(1, 1));
    final host = key.currentState!;
    expect(host.nextCalls, 0, reason: 'far from the end');
    await drag(tester, -900);
    expect(host.nextCalls, 1, reason: 'about a screen and a half before the end, no pull past it');
    expect(controller.offset, lessThan(controller.position.maxScrollExtent), reason: 'not at the end yet');
    expect(find.text(t.threadPage.loadingPage(page: 2)), findsNothing, reason: 'no spinner in sight');
    // Asked once while on its way.
    await drag(tester, -100);
    expect(host.nextCalls, 1);

    final visible = host.tops.last.floor;
    final before = topOf(tester, visible);
    host.show(_pages(1, 2));
    await tester.pump();
    await tester.pump();
    expect(topOf(tester, visible), before, reason: 'the floors on screen stay where they are');
    expect(find.text(t.threadPage.pageDivider(page: 2)), findsNothing, reason: 'below the screen');
    await drag(tester, -1200);
    expect(find.text(t.threadPage.pageDivider(page: 2)), findsOneWidget);
    expect(find.text(t.threadPage.pageDivider(page: 1)), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the page before goes above once scrolled up to, nothing on screen moves', (tester) async {
    final (controller, key) = await pump(tester, _pages(5, 5), firstPage: 5);
    final host = key.currentState!;
    expect(find.text(t.threadPage.pageDivider(page: 5)), findsOneWidget, reason: 'where the floors begin');
    expect(find.text(t.threadPage.loadPage(page: 4)), findsOneWidget, reason: 'the page before, not asked yet');
    expect(host.previousCalls, 0, reason: 'not asked right when a page in the middle opens');

    await drag(tester, -300);
    await drag(tester, 100);
    expect(host.previousCalls, 1, reason: 'scrolled up near the first floor');

    final before = topOf(tester, 41);
    host.show(_pages(4, 5), firstPage: 4);
    await tester.pump();
    await tester.pump();
    expect(topOf(tester, 41), before, reason: 'page 4 went above without moving page 5');
    await drag(tester, 400);
    expect(find.byKey(const ValueKey('floor-40')), findsOneWidget);
    expect(topOf(tester, 40), lessThan(topOf(tester, 41)));
    // Page 4 ends right above "page 5" and its first floor.
    expect(
      tester.getBottomLeft(floor(40)).dy,
      lessThan(tester.getTopLeft(find.text(t.threadPage.pageDivider(page: 5))).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pages dropped at the top while reading on move nothing; scrolled back up, the page before', (
    tester,
  ) async {
    final (controller, key) = await pump(tester, _pages(1, 10, ppp: 3), floorHeight: 100);
    final host = key.currentState!;
    await drag(tester, -2800);
    final visible = host.tops.last.floor;
    expect(visible, greaterThan(9), reason: 'page 1 far above the screen');
    final before = topOf(tester, visible);
    // Page 11 read on to: page 1 dropped.
    host.show(_pages(2, 11, ppp: 3), firstPage: 2);
    await tester.pump();
    await tester.pump();
    expect(topOf(tester, visible), before);
    expect(find.byKey(const ValueKey('floor-1'), skipOffstage: false), findsNothing);

    // Back up to the top: the empty places of page 1 take no room; the page before is asked.
    for (var i = 0; i < 6; i++) {
      await drag(tester, 1000);
    }
    expect(find.text('Thread title'), findsOneWidget);
    expect(find.byKey(const ValueKey('floor-4')), findsOneWidget);
    expect(topOf(tester, 4), greaterThan(tester.getBottomLeft(find.text('Thread title')).dy));
    expect(host.previousCalls, 1);
    expect(host.tops.last.atThreadTop, isFalse, reason: 'page 1 is not on screen');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the end of the thread: its floors, a reply, the new replies', (tester) async {
    final (controller, key) = await pump(tester, _pages(3, 3));
    final host = key.currentState!;
    var replied = 0;
    var asked = 0;
    host
      ..totalPages = 3
      ..end = ThreadEndCard(
        floors: 30,
        status: ThreadEdgeStatus.idle,
        onReply: () => replied++,
        onLoadNewReplies: () => asked++,
      )
      ..show(_pages(3, 3));
    await tester.pump();
    await drag(tester, -3000);
    expect(find.text(t.threadPage.lastFloorReached), findsOneWidget);
    expect(find.text(t.threadPage.floorCount(count: 30)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('thread-end-reply')));
    await tester.tap(find.byKey(const ValueKey('thread-end-new-replies')));
    expect(replied, 1);
    expect(asked, 1);
    expect(host.nextCalls, 0, reason: 'nothing after the last page');
  });

  testWidgets('a floor asked for is brought to the top; the page indicator follows the floor at the top', (
    tester,
  ) async {
    final (controller, key) = await pump(tester, _pages(1, 3));
    final host = key.currentState!..scrollTo(25);
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(topOf(tester, 25), closeTo(0, 1));
    final cubit = BlocProvider.of<JumpPageCubit>(tester.element(find.byType(PostList)));
    expect(cubit.state.currentPage, 3);
    expect(host.tops.last, (floor: 25, atThreadTop: false));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('pulled down at the start of the thread it refreshes; above a page in the middle it does not', (
    tester,
  ) async {
    final (_, key) = await pump(tester, _pages(1, 1));
    await tester.fling(find.byType(CustomScrollView), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(key.currentState!.refreshCalls, 1);

    final (_, middle) = await pump(tester, _pages(5, 5), firstPage: 5);
    await tester.fling(find.byType(CustomScrollView), const Offset(0, 400), 1000);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(middle.currentState!.refreshCalls, 0);
  });
}
