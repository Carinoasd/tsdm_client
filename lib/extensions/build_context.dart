import 'package:flutter/cupertino.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/map.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/friend/utils/approve_friend_link.dart';
import 'package:tsdm_client/features/friend/widgets/approve_friend_dialog.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:url_launcher/url_launcher.dart';

/// Extension on [BuildContext] that provides ability to dispatch a [String]
/// as an url.
extension DispatchUrl<T> on BuildContext {
  /// If [url] is an valid url:
  /// * Try parse route and push route to the corresponding page.
  /// * If is an unrecognized forum (or relative) url, push the "Open in app" page with the url filled in; the browser
  ///   is only started from there, by the user.
  /// * If is a foreign url, launch url in external browser.
  ///
  /// With [external] the url is launched in external browser directly.
  ///
  /// If current string is not an valid url:
  /// * Do nothing.
  Future<T?> dispatchAsUrl(
    String url, {
    bool external = false,
    Map<String, String>? extraPathParameters,
    Map<String, String>? extraQueryParameters,
  }) async {
    talker.debug('dispatch url: $url');
    final u = Uri.tryParse(url);
    if (u == null) {
      // Do nothing if is invalid url.
      talker.error('failed to dispatch invalid url: $url ');
      return null;
    }
    if (external) {
      await launchUrl(u, mode: LaunchMode.externalApplication);
      return null;
    }
    // The "批准申请" link of a friend request notice: approve inside the app instead of the browser.
    final approveUid = friendApprovalUidOfUrl(url);
    if (approveUid != null) {
      await showApproveFriendDialog(this, targetUid: approveUid);
      return null;
    }
    final route = url.parseUrlToRoute();
    if (route != null) {
      // Push route to the page if is recognized route.
      return pushNamed<T>(
        route.screenPath,
        pathParameters: route.pathParameters.copyWith(extraPathParameters ?? {}),
        queryParameters: route.queryParameters.copyWith(extraPathParameters ?? {}),
      );
    }
    // An unsupported forum url never goes to the platform on its own: on Android another installed build of this app
    // may claim forum links and open before the user had a choice (#105). The "Open in app" page shows the link and
    // opens it in the browser only when asked to.
    if (u.isForumOrRelative) {
      final router = GoRouter.maybeOf(this);
      if (router == null) {
        talker.error('no router to open unsupported forum url: $url');
        return null;
      }
      // Relative links are resolved on the forum host, keeping query and fragment.
      final absolute = u.hasScheme ? u : Uri.parse('$baseUrl/').resolveUri(u);
      return router.pushNamed<T>(ScreenPaths.openInApp, queryParameters: {'url': '$absolute', 'autoOpen': 'false'});
    }
    // Launch in external browser if is a foreign url.
    await launchUrl(u, mode: LaunchMode.externalApplication);
    return null;
  }
}

/// Extension on [BuildContext] provides methods to access the widget tree.
extension AccessContext on BuildContext {
  /// Try to read the bloc type [T] on context.
  ///
  /// * Return [T] if bloc found.
  /// * Return null if bloc not found.
  T? readOrNull<T>() {
    try {
      return read<T>();
      // This catch clause intends to be a safe accessor on providers.
      // ignore: avoid_catches_without_on_clauses
    } catch (e) {
      return null;
    }
  }

  /// Get the repository on current context.
  T repo<T>() => RepositoryProvider.of<T>(this);

  /// Return the safe padding here.
  EdgeInsets safePadding() {
    final padding = MediaQuery.paddingOf(this).copyWith(top: 0, left: 0, right: 0);
    if (padding.bottom >= 4) {
      return padding;
    }

    return const EdgeInsets.only(bottom: 4);
  }
}
