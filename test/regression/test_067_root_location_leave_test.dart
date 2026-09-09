import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/root/bloc/root_location_cubit.dart';
import 'package:tsdm_client/features/root/models/models.dart';
import 'package:tsdm_client/features/root/stream/root_location_stream.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// GitHub #14: the location stack only ever grew because no page reported leaving, so after visiting the notice
/// page once and going back, a notification tap on the homepage was refused as "already in the notice page".
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 10));

  test('leaving the current page pops it, leaving an earlier page drops that entry only', () async {
    final cubit = RootLocationCubit();
    rootLocationStream
      ..add(const RootLocationEventEnter(ScreenPaths.notice))
      ..add(const RootLocationEventEnter(ScreenPaths.threadV1));
    await tick();
    expect(cubit.isIn(ScreenPaths.threadV1), isTrue);
    rootLocationStream.add(const RootLocationEventLeave(ScreenPaths.threadV1));
    await tick();
    expect(cubit.isIn(ScreenPaths.notice), isTrue);
    // Replaced page disposed after its successor entered.
    rootLocationStream
      ..add(const RootLocationEventEnter(ScreenPaths.profile))
      ..add(const RootLocationEventLeave(ScreenPaths.notice));
    await tick();
    expect(cubit.state.locations, [ScreenPaths.profile]);
    // Leaving something that never entered changes nothing.
    rootLocationStream.add(const RootLocationEventLeave(ScreenPaths.search));
    await tick();
    expect(cubit.state.locations, [ScreenPaths.profile]);
    await cubit.close();
  });

  testWidgets('a RootPage reports leaving when it is popped, shell pages never do', (tester) async {
    final events = <RootLocationEvent>[];
    final sub = rootLocationStream.stream.listen(events.add);
    addTearDown(sub.cancel);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: Text('home')),
      ),
    );
    unawaited(
      nav.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const RootPage(ScreenPaths.notice, Scaffold(body: Text('notice')))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('notice'), findsOneWidget);
    expect(events, [const RootLocationEventEnter(ScreenPaths.notice)]);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('notice'), findsNothing);
    expect(events.last, const RootLocationEventLeave(ScreenPaths.notice));

    // A shell branch page is mounted for the whole run: entering counts, being disposed (never happens in the app)
    // must not report a leave that could pop somebody else.
    events.clear();
    await tester.pumpWidget(const MaterialApp(home: RootPage(ScreenPaths.homepage, Scaffold(body: Text('home')))));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(events, [const RootLocationEventEnter(ScreenPaths.homepage)]);
  });
}
