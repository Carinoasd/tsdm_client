import 'dart:async';

import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';

/// Follow the account of [auth] for a page that loaded for the current one: [onLoggingIn] when a login starts (the
/// page clears what it shows), [onChanged] when the account changed or a login ended.
///
/// The status stream replays the current status to a new listener. Pages reloaded on every status, so they loaded
/// twice when opened; the forum's app API answers the second call of an action within a few seconds "too soon" (HTTP
/// 429), and the page waited or fell back to a web page its parser may not know. The replayed status of the account
/// the page loaded for is not a change.
StreamSubscription<AuthStatus> listenAccountChanges(
  AuthenticationRepository auth, {
  required void Function() onLoggingIn,
  required void Function() onChanged,
}) {
  var shownUid = auth.effectiveCurrentUid;
  var loggingIn = false;
  return auth.status.listen((status) {
    if (status is AuthStatusLoading) {
      loggingIn = true;
      onLoggingIn();
      return;
    }
    final uid = auth.effectiveCurrentUid;
    if (!loggingIn && uid == shownUid) return;
    loggingIn = false;
    shownUid = uid;
    onChanged();
  });
}
