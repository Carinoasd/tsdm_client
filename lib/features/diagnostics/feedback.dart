/// The feedback of the user, two ways, both started by the user and nothing sent by the app itself: the diagnostics
/// bundle with what they wrote in it, shared through the system (`exportDiagnostics`), or a reply to the feedback
/// thread of the forum ([feedbackThreadTid]) the reply bar opens on, sent (or not) by the user.
///
/// The reply carries what the user wrote and one line of the environment ([feedbackEnvironmentLine]): never the
/// account, a cookie or the logs, and never the bundle (the thread is public).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/share_qr/share_qr_dialog.dart' show shareQrThreadUrl;
import 'package:tsdm_client/features/thread/v1/models/thread_reply_prefill.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/log_redaction.dart';
import 'package:tsdm_client/utils/method_channel.dart';
import 'package:tsdm_client/utils/platform.dart';

/// The environment told in a reply to the feedback thread, one line: the version of the app (with its build) and the
/// platform with the version of its system, as the diagnostics bundle reads them.
///
/// On Android the version of the system is its release and API level ([androidRelease], [androidSdk], read by
/// [feedbackEnvironment]: `android 14 (API 34)`), never what Dart gives there, the build's display id
/// (`ro.build.display.id`), a vendor's string that often names the device model, which has no place in a public
/// thread. On Linux it is the kernel's (`uname`: name, release, build): only its name and release are told, not the
/// build part (its time, a vendor's tag).
String feedbackEnvironmentLine({
  String? appVersion,
  String? platform,
  String? osVersion,
  String? androidRelease,
  int? androidSdk,
}) {
  final name = platform ?? Platform.operatingSystem;
  final head = 'tsdm_client ${appVersion ?? appFullVersion} · $name';
  if (name == 'android') {
    // A release is a version number ("14", "8.1.0") or, on a preview, a code name: anything else is left out.
    final release = androidRelease?.trim() ?? '';
    final os = [
      if (RegExp(r'^[\w.-]{1,20}$').hasMatch(release)) release,
      if (androidSdk != null && androidSdk > 0) '(API $androidSdk)',
    ].join(' ');
    return os.isEmpty ? head : '$head $os';
  }
  var os = (osVersion ?? Platform.operatingSystemVersion).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (name == 'linux') {
    os = os.split(' ').take(2).join(' ');
  }
  return os.isEmpty ? head : '$head $os';
}

/// [feedbackEnvironmentLine] of this app, the version of Android asked from the activity ([androidSystemVersion]).
Future<String> feedbackEnvironment() async {
  if (!isAndroid) {
    return feedbackEnvironmentLine();
  }
  final version = await androidSystemVersion();
  return feedbackEnvironmentLine(androidRelease: version?.release, androidSdk: version?.sdk);
}

/// A zero width space put after each `[` of what the user wrote in the reply ([escapeBBCodeBrackets]).
const _bracketBreak = '\u200b';

/// [text] with a zero width space after each `[`, so neither the editor of the reply nor the forum read a tag in it
/// (`[b]`, `[url=…]`, `[/quote]`): the text shows as written, the space takes no room. The forum's own filter of the
/// tags of a user group does the same. Idempotent.
String escapeBBCodeBrackets(String text) => text.replaceAll(RegExp('\\[(?!$_bracketBreak)'), '[$_bracketBreak');

/// The reply to the feedback thread: what the user wrote ([description], may be empty, redacted as in the diagnostics
/// bundle ([redactUserText]: a pasted cookie or password) and its brackets kept from being read as tags
/// ([escapeBBCodeBrackets])) and the [environment] line.
String feedbackReplyText(String description, String environment) {
  final text = escapeBBCodeBrackets(redactUserText(description.trim()));
  return text.isEmpty ? environment : '$text\n\n$environment';
}

/// The route of the feedback thread, built as the thread link the app copies and shares.
RecognizedRoute feedbackThreadRoute() => shareQrThreadUrl('$feedbackThreadTid').parseUrlToRoute()!;

/// Opens the feedback thread with the reply to it written ([feedbackReplyText]), the user sends it themselves.
final class FeedbackThreadOpener {
  /// Constructor.
  const FeedbackThreadOpener({
    required this.isLoggedIn,
    required this.login,
    required this.open,
    this.environment = feedbackEnvironment,
  });

  /// The opener of the app: the account in use of [context], its login page, its router.
  factory FeedbackThreadOpener.of(BuildContext context) {
    final authentication = context.read<AuthenticationRepository>();
    final router = GoRouter.of(context);
    return FeedbackThreadOpener(
      isLoggedIn: () => authentication.effectiveCurrentUid != null,
      login: () async => router.pushNamed<void>(ScreenPaths.login),
      open: (route, prefill) => router.pushNamed<void>(
        route.screenPath,
        pathParameters: route.pathParameters,
        queryParameters: route.queryParameters,
        extra: prefill,
      ),
    );
  }

  /// Whether an account is in use.
  final bool Function() isLoggedIn;

  /// Open the login page; completes when it is left (logged in or given up).
  final Future<void> Function() login;

  /// Open the page of a route with the text of the reply; not waited for (completes when the page is closed).
  final Future<void> Function(RecognizedRoute route, ThreadReplyPrefill prefill) open;

  /// The environment line of the reply ([feedbackEnvironment]).
  final Future<String> Function() environment;

  /// Open the feedback thread with [description] and the environment line in its reply (the [environment] of the
  /// opener when none is given). Without an account the login page comes first, as for a share to a new thread; false
  /// when the user did not log in.
  Future<bool> openWith(String description, {String? environment}) async {
    if (!isLoggedIn()) {
      await login();
      if (!isLoggedIn()) {
        return false;
      }
    }
    final text = feedbackReplyText(description, environment ?? await this.environment());
    // A pushed route completes when its page is left.
    unawaited(open(feedbackThreadRoute(), ThreadReplyPrefill(text)));
    return true;
  }
}
