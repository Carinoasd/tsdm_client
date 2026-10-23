import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// App bar button leaving the notification pages for the homepage in one tap (GitHub #117).
///
/// Closes the pages opened on top of the home shell, then shows the homepage tab. A page holding an unsent reply asks
/// first and, when the user agrees, is closed too: its reply is kept on this device as a local draft (GitHub #235). A
/// page that may hold other unsaved input (a form) is kept open and shown instead, with a hint telling why the homepage
/// did not show ([returnToHome]).
class BackToHomeButton extends StatelessWidget {
  /// Constructor.
  const BackToHomeButton({super.key});

  Future<void> _goHome(BuildContext context) async {
    final tr = context.t.noticePage.appBar;
    final router = GoRouter.of(context);
    var leaveDrafts = false;
    if (hasDraftAboveShell(router)) {
      final leave = await showQuestionDialog(
        context: context,
        title: tr.backToHomeDraftTitle,
        message: tr.backToHomeDraftDetail,
      );
      if (leave != true || !context.mounted) {
        return;
      }
      leaveDrafts = true;
    }
    // Read before leaving: this button's page is closed on the way.
    final stoppedMessage = tr.backToHomeStopped;
    if (!returnToHome(router, leaveDrafts: leaveDrafts)) {
      showSnackBar(context: context, message: stoppedMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.home_outlined),
      tooltip: context.t.noticePage.appBar.backToHome,
      onPressed: () => _goHome(context),
    );
  }
}
