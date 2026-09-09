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
  double bottomInset = 0,
  double? actionOverflowThreshold,
}) {
  final messenger = snackbarKey.currentState;
  if (clearPrevious) {
    // Do not let the same hint queue up behind an older one.
    messenger?.clearSnackBars();
  }
  final bar = SnackBar(
    behavior: floating ? SnackBarBehavior.floating : null,
    // Lift a floating snack bar above the keyboard when the page underneath does not resize for it.
    margin: floating && bottomInset > 0 ? EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomInset) : null,
    content: Text(message),
    action: action,
    showCloseIcon: showCloseIcon,
    // Flutter moves the action to a second row once it takes more than 25% of the bar; short bars with a Chinese
    // label and a close icon crossed that on 360dp phones (issue #4), so callers can raise the threshold.
    actionOverflowThreshold: actionOverflowThreshold,
  );
  try {
    messenger?.showSnackBar(bar);
    // Debug builds assert inside the messenger when one of its scaffolds is being torn down in this very frame (seen
    // on the chat pages while the reply sheet closed). Show the bar once the tree settled instead of dropping it
    // together with whatever the caller does next.
    // ignore: avoid_catching_errors
  } on FlutterError {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => messenger?.showSnackBar(bar))
      ..ensureVisualUpdate();
  }
}
