import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// App bar button leaving the notification pages for the homepage in one tap (GitHub #117).
///
/// Closes the pages opened on top of the home shell, then shows the homepage tab. A page that may hold unsaved input
/// is kept open and shown instead, with a hint telling why the homepage did not show ([returnToHome]).
class BackToHomeButton extends StatelessWidget {
  /// Constructor.
  const BackToHomeButton({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = context.t.noticePage.appBar;
    return IconButton(
      icon: const Icon(Icons.home_outlined),
      tooltip: tr.backToHome,
      onPressed: () {
        // Read before leaving: this button's page is closed on the way.
        final stoppedMessage = tr.backToHomeStopped;
        if (!returnToHome(GoRouter.of(context))) {
          showSnackBar(context: context, message: stoppedMessage);
        }
      },
    );
  }
}
