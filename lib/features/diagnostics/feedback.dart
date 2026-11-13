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

/// The environment told in a reply to the feedback thread, one line: the version of the app (with its build) and the
/// platform with the version of its system, as the diagnostics bundle reads them.
///
/// On Android and Linux the version is the kernel's (`uname`: name, release, build): only its name and release are
/// told, the build part (its time, a vendor's tag) has no place in a public thread.
String feedbackEnvironmentLine({String? appVersion, String? platform, String? osVersion}) {
  final name = platform ?? Platform.operatingSystem;
  var os = (osVersion ?? Platform.operatingSystemVersion).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (name == 'android' || name == 'linux') {
    os = os.split(' ').take(2).join(' ');
  }
  return 'tsdm_client ${appVersion ?? appFullVersion} · $name $os';
}

/// The reply to the feedback thread: what the user wrote ([description], may be empty, redacted as in the diagnostics
/// bundle: a pasted cookie or log line) and the [environment] line.
String feedbackReplyText(String description, String environment) {
  final text = redactLogText(description.trim());
  return text.isEmpty ? environment : '$text\n\n$environment';
}

/// The route of the feedback thread, built as the thread link the app copies and shares.
RecognizedRoute feedbackThreadRoute() => shareQrThreadUrl('$feedbackThreadTid').parseUrlToRoute()!;

/// Opens the feedback thread with the reply to it written ([feedbackReplyText]), the user sends it themselves.
final class FeedbackThreadOpener {
  /// Constructor.
  const FeedbackThreadOpener({required this.isLoggedIn, required this.login, required this.open});

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

  /// Open the feedback thread with [description] and [environment] in its reply. Without an account the login page
  /// comes first, as for a share to a new thread; false when the user did not log in.
  Future<bool> openWith(String description, {String? environment}) async {
    if (!isLoggedIn()) {
      await login();
      if (!isLoggedIn()) {
        return false;
      }
    }
    final text = feedbackReplyText(description, environment ?? feedbackEnvironmentLine());
    // A pushed route completes when its page is left.
    unawaited(open(feedbackThreadRoute(), ThreadReplyPrefill(text)));
    return true;
  }
}
