import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// After a reply the thread reloads and the list scrolls to the new floor; cards then grow while avatars and images
/// load. The revealed post must stay in view during that settle window and be left alone afterwards.
Post _post(int i) => Post(
  postID: '$i',
  postFloor: i,
  author: User(name: 'u$i', url: 'u'),
  publishTime: DateTime(2026, 9, 5),
  data: 'body $i',
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: 2,
  isDraft: false,
  packetAllTaken: false,
);

class _Page extends StatefulWidget {
  const _Page(this.controller, {super.key});

  final ScrollController controller;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  final List<Post> posts = List.generate(8, (i) => _post(i + 11));
  double height = 400;

  void grow(double to) => setState(() => height = to);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PostList(
      threadID: '1',
      postList: posts,
      canLoadMore: false,
      scrollController: widget.controller,
      latestModAct: null,
      title: 'title',
      useDivider: true,
      initialPostID: 18,
      widgetBuilder: (_, p) => SizedBox(height: height, child: Text('post ${p.postID}')),
    ),
  );
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  Future<void> pass(WidgetTester tester, Duration d) async {
    for (var t = Duration.zero; t < d; t += const Duration(milliseconds: 50)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<(ScrollController, GlobalKey<_PageState>)> pump(WidgetTester tester) async {
    final controller = ScrollController();
    final key = GlobalKey<_PageState>();
    await tester.pumpWidget(
      BlocProvider(
        create: (_) => JumpPageCubit(),
        child: MaterialApp(home: _Page(controller, key: key)),
      ),
    );
    // The approach animation takes 200 ms and ticks once per frame.
    await pass(tester, const Duration(milliseconds: 400));
    return (controller, key);
  }

  testWidgets('the revealed last post stays at the end while cards grow', (tester) async {
    final (controller, key) = await pump(tester);
    expect(controller.position.pixels, controller.position.maxScrollExtent, reason: 'landed on the last post');
    expect(find.text('post 18'), findsOneWidget);

    key.currentState!.grow(700);
    // Extents settle over a few frames; the hold re-aligns every 100 ms. A card taller than the viewport can be
    // aligned with its top at the top of the viewport, a shorter one is clamped to the end of the list.
    await pass(tester, const Duration(milliseconds: 600));
    expect(find.text('post 18'), findsOneWidget, reason: 'the revealed post is still on screen');
    expect(tester.getTopLeft(find.text('post 18')).dy, closeTo(0, 2), reason: 'held at the top of the viewport');
    expect(tester.takeException(), isNull);
  });

  testWidgets('touching the list ends the hold', (tester) async {
    final (controller, key) = await pump(tester);
    final before = controller.position.pixels;
    await tester.tapAt(tester.getCenter(find.text('post 18')));
    await tester.pump();

    key.currentState!.grow(700);
    await pass(tester, const Duration(milliseconds: 300));
    expect(controller.position.pixels, before, reason: 'no re-alignment after the user took over');
    expect(controller.position.pixels, lessThan(controller.position.maxScrollExtent));
  });

  testWidgets('the hold ends by itself after the settle window', (tester) async {
    final (controller, key) = await pump(tester);
    await pass(tester, const Duration(milliseconds: 2500));
    final before = controller.position.pixels;

    key.currentState!.grow(700);
    await pass(tester, const Duration(milliseconds: 300));
    expect(controller.position.pixels, before, reason: 'the list is left alone once settled');
  });
}
