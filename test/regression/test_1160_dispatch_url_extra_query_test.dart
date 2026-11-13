/// `dispatchAsUrl` merged `extraPathParameters` into the query parameters of the pushed route, so
/// `extraQueryParameters` was dropped: the `hero` tag the notice and private message cards send along with a member's
/// space url never reached the profile page, whose avatar then had a tag of its own and no hero to pair with on the
/// way back.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

void main() {
  const space = 'https://www.tsdm39.com/home.php?mod=space&uid=123';

  /// Pages pushed: path parameters and query parameters.
  final pushed = <(Map<String, String>, Map<String, String>)>[];

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  setUp(pushed.clear);

  /// Dispatch [space] from a page, the profile route living at [profilePath].
  Future<void> open(
    WidgetTester tester, {
    String profilePath = ScreenPaths.profile,
    Map<String, String>? extraPathParameters,
    Map<String, String>? extraQueryParameters,
  }) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () async => context.dispatchAsUrl(
                space,
                extraPathParameters: extraPathParameters,
                extraQueryParameters: extraQueryParameters,
              ),
              child: const Text('open'),
            ),
          ),
        ),
        GoRoute(
          path: profilePath,
          name: ScreenPaths.profile,
          builder: (context, state) {
            pushed.add((state.pathParameters, state.uri.queryParameters));
            return const Scaffold(body: Text('profile'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('extra query parameters reach the pushed page', (tester) async {
    await open(tester, extraQueryParameters: {'hero': '123-2026-01-01'});
    expect(pushed, hasLength(1));
    expect(pushed.single.$2, {'uid': '123', 'hero': '123-2026-01-01'});
  });

  testWidgets('extra path parameters stay out of the query', (tester) async {
    await open(tester, profilePath: '${ScreenPaths.profile}/:slot', extraPathParameters: {'slot': 'a'});
    expect(pushed, hasLength(1));
    expect(pushed.single.$1, {'slot': 'a'});
    expect(pushed.single.$2, {'uid': '123'});
  });

  testWidgets('without extras the route keeps its own parameters', (tester) async {
    await open(tester);
    expect(pushed, hasLength(1));
    expect(pushed.single.$2, {'uid': '123'});
  });
}
