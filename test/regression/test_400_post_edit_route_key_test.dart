/// The editor route keys its page by the full URI.
///
/// Choosing another thread kind in the editor replaces the route with the same path and another `kind` query
/// (`_switchKind` in the post edit page). The pages carried no key, so the navigator kept the old page's state: the
/// bloc that fetches the form (made once per state) never asked for the new kind's form, and the reward, red packet,
/// activity and debate buttons never appeared on a device. Now the page's key follows the URI, so a replacement
/// with another query is a new page, while a rebuild of the same location keeps the editor as it is.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/view/post_edit_page.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

GoRoute? _find(List<RouteBase> routes, String path) {
  for (final route in routes) {
    if (route is GoRoute && route.path == path) {
      return route;
    }
    final nested = _find(route.routes, path);
    if (nested != null) {
      return nested;
    }
  }
  return null;
}

/// Builds the editor page the router would build for [location].
Widget _pageAt(BuildContext context, String location) {
  final route = _find(router.configuration.routes, ScreenPaths.editPost);
  expect(route, isNotNull, reason: 'the editor route exists');
  final uri = Uri.parse(location);
  final state = GoRouterState(
    router.configuration,
    uri: uri,
    matchedLocation: uri.path,
    fullPath: ScreenPaths.editPost,
    pathParameters: {'editType': '${PostEditType.newThread.index}', 'fid': '2'},
    pageKey: const ValueKey('editPost'),
  );
  final page = route!.pageBuilder!(context, state) as MaterialPage<void>;
  return (page.child as RootPage).child;
}

void main() {
  const normal = '/editPost/0/2?poll=1';
  const reward = '/editPost/0/2?poll=1&kind=reward';
  const hongbao = '/editPost/0/2?poll=1&kind=hongbao';

  testWidgets('another kind is another page; the same location is the same page', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );

    final pages = {for (final l in [normal, reward, hongbao]) l: _pageAt(context, l)};
    for (final page in pages.values) {
      expect(page, isA<PostEditPage>());
      expect(page.key, isNotNull, reason: 'the page is keyed, or the navigator reuses the old state on replacement');
    }
    expect(pages[normal]!.key, isNot(pages[reward]!.key));
    expect(pages[reward]!.key, isNot(pages[hongbao]!.key));
    expect(pages[normal]!.key, isNot(pages[hongbao]!.key));

    // A rebuild of the same location must not throw the editor away.
    expect(_pageAt(context, reward).key, pages[reward]!.key);

    final kinds = {for (final e in pages.entries) e.key: (e.value as PostEditPage).threadKind.name};
    expect(kinds, {normal: 'normal', reward: 'reward', hongbao: 'hongbao'});
  });
}
