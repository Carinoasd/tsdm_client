import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Option, left, right;
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// A forum script link without host, as the forum writes them in its pages: `home.php?mod=space&do=notice`,
/// `/forum.php?mod=viewthread&tid=1#pid2`.
final _forumScriptRe = RegExp(r'^/?[A-Za-z0-9_]+\.php(?:[?#]\S*)?$');

/// The web link a user typed, to be opened in the browser whether or not the app can open it itself (#105).
///
/// * Surrounding whitespace is trimmed; whitespace left inside the link rejects it.
/// * Absolute `http` and `https` links with a host are kept as typed, query and fragment included.
/// * A forum script link without host (see [_forumScriptRe]) is put on the canonical forum host [baseUrl].
/// * Anything else is rejected: empty input, other schemes (`javascript:`, `data:`, `file:`, `mailto:`, app schemes),
///   links without host, and plain usernames or ids.
Uri? parseBrowserLink(String? input) {
  final s = input?.trim() ?? '';
  if (s.isEmpty || s.contains(RegExp(r'\s'))) {
    return null;
  }
  final uri = Uri.tryParse(_forumScriptRe.hasMatch(s) ? '$baseUrl/${s.startsWith('/') ? s.substring(1) : s}' : s);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
    return null;
  }
  return uri;
}

/// Validator of resource format.
///
/// Used when checking resource input.
typedef ResourceValidator = Either<String, RecognizedRoute> Function(BuildContext context, String? v);

/// Represents any forum resource that can be opened in app.
abstract interface class OpenableForumResource<I18n> {
  // WTF dart analyzer, subclass are using it.
  // ignore: unused_element
  I18n _i18n(BuildContext context) => throw UnimplementedError();

  /// Resource name.
  String typename(BuildContext context) => throw UnimplementedError();

  /// Resource detail description.
  String detail(BuildContext context) => throw UnimplementedError();

  /// Get the validator used to validate resource input before commiting.
  ResourceValidator validator() => throw UnimplementedError();
}

/// Supported urls.
final class UrlResource extends OpenableForumResource<TranslationsOpenInAppPageUrlEn> {
  @override
  String typename(BuildContext context) => _i18n(context).title;

  @override
  String detail(BuildContext context) => _i18n(context).detail;

  @override
  ResourceValidator validator() => (context, v) {
    if (v == null) {
      return left(_i18n(context).unsupportedUrl);
    }

    final parsedRoute = v.trim().parseUrlToRoute();
    if (parsedRoute == null) {
      return left(_i18n(context).unsupportedUrl);
    }
    return right(parsedRoute);
  };

  @override
  TranslationsOpenInAppPageUrlEn _i18n(BuildContext context) => context.t.openInAppPage.url;
}

/// Open user space by username.
final class UsernameResource extends OpenableForumResource<TranslationsOpenInAppPageUsernameEn> {
  @override
  String typename(BuildContext context) => _i18n(context).title;

  @override
  String detail(BuildContext context) => _i18n(context).detail;

  @override
  ResourceValidator validator() =>
      (context, v) => Option.fromNullable(v)
          .filter((v) => v.isNotEmpty)
          .toEither(() => _i18n(context).invalidUsername)
          .map((username) => RecognizedRoute(ScreenPaths.profile, queryParameters: {'username': username}));

  @override
  TranslationsOpenInAppPageUsernameEn _i18n(BuildContext context) => context.t.openInAppPage.username;
}

/// Open user space by uid.
final class UidResource extends OpenableForumResource<TranslationsOpenInAppPageUidEn> {
  @override
  String typename(BuildContext context) => _i18n(context).title;

  @override
  String detail(BuildContext context) => _i18n(context).detail;

  @override
  ResourceValidator validator() =>
      (context, v) => Option.fromNullable(v)
          .flatMap((v) => Option.fromNullable(int.tryParse(v)))
          .filter((v) => v > 0)
          .toEither(() => _i18n(context).invalidUid)
          .map((uid) => RecognizedRoute(ScreenPaths.profile, queryParameters: {'uid': '$uid'}));

  @override
  TranslationsOpenInAppPageUidEn _i18n(BuildContext context) => context.t.openInAppPage.uid;
}

/// Open subreddit page by forum id.
final class FidResource extends OpenableForumResource<TranslationsOpenInAppPageFidEn> {
  @override
  String typename(BuildContext context) => _i18n(context).title;

  @override
  String detail(BuildContext context) => _i18n(context).detail;

  @override
  ResourceValidator validator() =>
      (context, v) => Option.fromNullable(v)
          .flatMap((v) => Option.fromNullable(int.tryParse(v)))
          .filter((v) => v > 0)
          .toEither(() => _i18n(context).invalidFid)
          .map((fid) => RecognizedRoute(ScreenPaths.forum, pathParameters: {'fid': '$fid'}));

  @override
  TranslationsOpenInAppPageFidEn _i18n(BuildContext context) => context.t.openInAppPage.fid;
}

/// Open thread page by thread id.
final class TidResource extends OpenableForumResource<TranslationsOpenInAppPageTidEn> {
  @override
  String typename(BuildContext context) => _i18n(context).title;

  @override
  String detail(BuildContext context) => _i18n(context).detail;

  @override
  ResourceValidator validator() =>
      (context, v) => Option.fromNullable(v)
          .flatMap((v) => Option.fromNullable(int.tryParse(v)))
          .filter((v) => v > 0)
          .toEither(() => _i18n(context).invalidTid)
          .map((tid) => RecognizedRoute(ScreenPaths.threadV1, queryParameters: {'tid': '$tid'}));

  @override
  TranslationsOpenInAppPageTidEn _i18n(BuildContext context) => context.t.openInAppPage.tid;
}

/// Find post by post id.
final class PidResource extends OpenableForumResource<TranslationsOpenInAppPagePidEn> {
  @override
  String typename(BuildContext context) => _i18n(context).title;

  @override
  String detail(BuildContext context) => _i18n(context).detail;

  @override
  ResourceValidator validator() =>
      (context, v) => Option.fromNullable(v)
          .flatMap((v) => Option.fromNullable(int.tryParse(v)))
          .filter((v) => v > 0)
          .toEither(() => _i18n(context).invalidPid)
          .map(
            (pid) => RecognizedRoute(
              ScreenPaths.threadV1,
              queryParameters: {'pid': '$pid', 'overrideReverseOrder': 'false'},
            ),
          );

  @override
  TranslationsOpenInAppPagePidEn _i18n(BuildContext context) => context.t.openInAppPage.pid;
}
