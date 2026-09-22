import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

/// Tells the user, on whatever page is open, that the block list of the current account could not be read.
///
/// While the list is unknown every item with an identified author is held back ([UserBlockList.hides]). Floors and
/// threads say so in their placeholder, but lists of topics (forum, search, homepage pinned rows) only leave the rows
/// out and would look empty for no visible reason. Shown each time the list turns failed, with a retry; the automatic
/// retries of [UserBlockCubit] keep it failed, so they do not show it again.
///
/// The hint shares the queue of the app wide messenger with every other snack bar, so it never stays on its own (a
/// snack bar with an action would by default) and it is closed once the list is read or the account changes. Failing
/// again while a hint waits in the queue marks that one stale (it closes itself if its turn ever comes) and queues a
/// new one: a queued snack bar may have been dropped by `clearSnackBars`, which never completes it.
class UserBlockFailureListener extends BlocListener<UserBlockCubit, UserBlockList> {
  /// Constructor.
  const UserBlockFailureListener({super.key, super.child}) : super(listenWhen: _changed, listener: _onChanged);

  /// How long the hint stays on screen when nothing closes it earlier.
  static const visibleFor = Duration(seconds: 8);

  /// Hint of each listener, kept on its element so a rebuild of the widget does not lose it.
  static final _hints = Expando<_Hint>();

  static bool _changed(UserBlockList previous, UserBlockList current) =>
      previous.status != current.status || previous.ownerUid != current.ownerUid;

  static void _onChanged(BuildContext context, UserBlockList state) {
    var hint = _hints[context];
    if (hint != null && hint.done) {
      hint = _hints[context] = null;
    }
    // Read again (a retry from another page): the hint stays until the answer.
    if (hint != null && hint.owner == state.ownerUid && state.status == UserBlockListStatus.loading) {
      return;
    }
    // Read, another account, or failed again: the old hint goes (closed if shown, else marked stale) and a new one
    // tells, after it.
    hint?.close();
    _hints[context] = state.status == UserBlockListStatus.failed ? _show(context, state.ownerUid) : null;
  }

  static _Hint? _show(BuildContext context, int? owner) {
    final messenger = snackbarKey.currentState;
    if (messenger == null) {
      return null;
    }
    final cubit = context.read<UserBlockCubit>();
    final hint = _Hint(owner);
    final controller = messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: _HintText(hint: hint, message: context.t.userBlock.loadFailedHint),
        action: SnackBarAction(
          label: context.t.general.retry,
          onPressed: () {
            // The messenger hides it right after this call.
            hint.done = true;
            unawaited(cubit.reload());
          },
        ),
        actionOverflowThreshold: 0.6,
        persist: false,
        duration: visibleFor,
      ),
    );
    hint.controller = controller;
    unawaited(controller.closed.whenComplete(() => hint.done = true));
    return hint;
  }
}

/// A load failure hint in the queue of the messenger.
///
/// Only the first snack bar of the queue can be closed through its controller (closing another one closes the first
/// one instead), so a hint that is no longer true while it waits is only marked and closes itself when its turn comes.
final class _Hint {
  _Hint(this.owner);

  /// Account whose list failed to load.
  final int? owner;

  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? controller;

  /// It is the first snack bar of the queue (the only one the scaffolds build), until it is closed.
  bool current = false;

  /// No longer true, close it as soon as it is [current].
  bool stale = false;

  /// Closed or closing, never close it again.
  bool done = false;

  void becameCurrent() {
    if (done || current) {
      return;
    }
    current = true;
    if (stale) {
      close();
    }
  }

  void close() {
    stale = true;
    if (done || !current) {
      return;
    }
    done = true;
    controller?.close();
  }
}

/// Text of a hint, reports when its hint became the first snack bar of the queue.
class _HintText extends StatefulWidget {
  const _HintText({required this.hint, required this.message});

  final _Hint hint;
  final String message;

  @override
  State<_HintText> createState() => _HintTextState();
}

class _HintTextState extends State<_HintText> {
  @override
  void initState() {
    super.initState();
    // Built for the first time: its snack bar is the first of the queue now. Closing it changes the messenger, so
    // wait for the end of this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.hint.becameCurrent());
  }

  @override
  Widget build(BuildContext context) => Text(widget.message);
}
