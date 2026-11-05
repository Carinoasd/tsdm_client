import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/share_receive/models/shared_content.dart';
import 'package:tsdm_client/features/share_receive/models/shared_thread_draft.dart';
import 'package:tsdm_client/features/share_receive/utils/share_action.dart';
import 'package:tsdm_client/features/share_receive/widgets/forum_picker_sheet.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/app_routes.dart' as app;
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Carries out what [decideShare] decided for a share, on the [router].
///
/// The account and the forum picker are injected: the running app reads the account from its providers and picks the
/// forum in a sheet ([ShareDispatcher.app]); tests give their own.
final class ShareDispatcher with LoggerMixin {
  /// Constructor.
  ShareDispatcher({
    required this.router,
    required this.isLoggedIn,
    required this.currentUid,
    required this.pickForum,
  });

  /// The dispatcher of the running app: the global router; the account in use read from the app's providers through
  /// the root navigator, the forum picked in a sheet over it.
  factory ShareDispatcher.app() => ShareDispatcher(
    router: app.router,
    isLoggedIn: () => _authentication()?.effectiveCurrentUid != null,
    currentUid: () => _authentication()?.effectiveCurrentUid,
    pickForum: pickForumInApp,
  );

  /// The router the pages are opened on.
  final GoRouter router;

  /// Whether an account is in use.
  final bool Function() isLoggedIn;

  /// The uid of the account in use, null without one.
  final int? Function() currentUid;

  /// Ask the user for the forum to post in: its id, null when they declined.
  final Future<int?> Function() pickForum;

  /// Do what [content] asks for, see [decideShare].
  Future<void> dispatch(SharedContent content) async {
    final action = decideShare(content, loggedIn: isLoggedIn());
    info('share action: ${action.runtimeType}');
    switch (action) {
      case ShareIgnored():
        return;
      case ShareOpenRoute(:final route):
        // A pushed route completes when its page is left: the share is done once the page is opened.
        unawaited(
          router.pushNamed<void>(
            route.screenPath,
            pathParameters: route.pathParameters,
            queryParameters: route.queryParameters,
          ),
        );
      case ShareOpenInApp(:final url):
        unawaited(router.pushNamed<void>(ScreenPaths.openInApp, queryParameters: {'url': url, 'autoOpen': 'true'}));
      case ShareLoginFirst(:final compose):
        // Waited for: the login page pops once logged in or given up.
        await router.pushNamed<void>(ScreenPaths.login);
        if (!isLoggedIn()) {
          discardSharedFiles(compose.imagePaths);
          return;
        }
        await _compose(compose);
      case ShareCompose():
        await _compose(action);
    }
  }

  Future<void> _compose(ShareCompose compose) async {
    final fid = await pickForum();
    final uid = currentUid();
    if (fid == null || uid == null) {
      discardSharedFiles(compose.imagePaths);
      return;
    }
    final hasText = compose.subject.isNotEmpty || compose.text.isNotEmpty;
    unawaited(
      router.pushNamed<void>(
        ScreenPaths.editPost,
        pathParameters: {'editType': '${PostEditType.newThread.index}', 'fid': '$fid'},
        extra: SharedThreadDraft(
          transfer: hasText
              ? ThreadModeTransfer(uid: uid, fid: '$fid', subject: compose.subject, body: compose.text)
              : null,
          imagePaths: compose.imagePaths,
        ),
      ),
    );
  }
}

/// The context of the root navigator of the running app, under the app's providers; null before the app is built.
BuildContext? rootNavigatorContext() => app.router.routerDelegate.navigatorKey.currentState?.overlay?.context;

/// [rootNavigatorContext] once the app is built, waiting for it at a cold start (a share the app was launched with
/// arrives before its first frame); null when it did not come within [timeout].
Future<BuildContext?> waitForRootNavigatorContext({Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final context = rootNavigatorContext();
    if (context != null && context.mounted) {
      return context;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}

AuthenticationRepository? _authentication() => rootNavigatorContext()?.read<AuthenticationRepository>();

/// The forum index as the topics tab shows it: the cached homepage, fetched when there is none; empty when it failed.
Future<List<ForumGroup>> loadForumGroups(ForumHomeRepository repository) async =>
    (await repository.fetchHomePage().run()).fold(
      (_) => const [],
      (page) => switch (page) {
        ForumHomeWebPage(:final document) => buildGroupListFromDocument(document),
        ForumHomeApiPage(:final json) => forumGroupsFromApi(json),
      },
    );

/// Pick the forum in a sheet over the running app, from the forum index: null when dismissed or the index failed to
/// load (told in a snack bar).
Future<int?> pickForumInApp() async {
  final context = await waitForRootNavigatorContext();
  if (context == null || !context.mounted) {
    return null;
  }
  final groups = await loadForumGroups(context.read<ForumHomeRepository>());
  if (!context.mounted) {
    return null;
  }
  if (postableForums(groups).isEmpty) {
    showSnackBar(context: context, message: context.t.general.failedToLoad);
    return null;
  }
  return showForumPickerSheet(context, groups);
}
