import 'package:flutter/material.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

/// Show a snack bar contains message show no more contents.
void showNoMoreSnackBar(BuildContext context, {bool floating = true}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(behavior: floating ? SnackBarBehavior.floating : null, content: Text(context.t.general.noMoreData)),
  );
}

/// Show a snack bar contains message of failed to load event.
void showFailedToLoadSnackBar(BuildContext context, {bool floating = true}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(behavior: floating ? SnackBarBehavior.floating : null, content: Text(context.t.general.failedToLoad)),
  );
}

/// Show a snack bar with given [message].
void showSnackBar({
  required BuildContext context,
  required String message,
  bool floating = true,
  SnackBarAction? action,
  bool clearPrevious = false,
  bool showCloseIcon = false,
}) {
  final messenger = snackbarKey.currentState;
  if (clearPrevious) {
    // Do not let the same hint queue up behind an older one.
    messenger?.clearSnackBars();
  }
  messenger?.showSnackBar(
    SnackBar(
      behavior: floating ? SnackBarBehavior.floating : null,
      content: Text(message),
      action: action,
      showCloseIcon: showCloseIcon,
    ),
  );
}
