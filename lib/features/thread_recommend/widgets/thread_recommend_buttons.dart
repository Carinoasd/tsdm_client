import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/thread_recommend/repository/thread_recommend_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The forum's "支持" and "踩" of a thread under its first floor ([ThreadRecommend]): each button with the forum's
/// text and count, as the web page prints them (the count only when there is one).
///
/// A guest's button opens the login. A member's sends the evaluation once ([ThreadRecommendRepository]): counted, its
/// count goes up and both buttons stay off (the forum takes one evaluation per member and thread); refused, the
/// forum's message is shown.
class ThreadRecommendButtons extends StatefulWidget {
  /// Constructor.
  const ThreadRecommendButtons(this.recommend, {super.key});

  /// The evaluation the page printed.
  final ThreadRecommend recommend;

  @override
  State<ThreadRecommendButtons> createState() => _ThreadRecommendButtonsState();
}

/// The evaluations counted from the app while it runs, by account and thread: the page they were sent from and the
/// side counted. The floors of a thread page are built again when they scroll back into view, and the forum does not
/// tell which side an account took: the buttons read it from here, so a counted evaluation stays counted.
final class ThreadRecommendMemory {
  ThreadRecommendMemory._();

  static final _counted = <(int, int), ({ThreadRecommend from, ThreadRecommendSide side})>{};

  /// What [recommend]'s account counted on its thread, if anything.
  static ({ThreadRecommend from, ThreadRecommendSide side})? of(ThreadRecommend recommend) =>
      recommend.viewerUid == null ? null : _counted[(recommend.viewerUid!, recommend.tid)];

  /// [side] was counted from the page of [from].
  static void remember(ThreadRecommend from, ThreadRecommendSide side) {
    if (from.viewerUid case final uid?) {
      _counted[(uid, from.tid)] = (from: from, side: side);
    }
  }

  /// Forget everything (tests).
  static void clear() => _counted.clear();
}

class _ThreadRecommendButtonsState extends State<ThreadRecommendButtons> {
  /// The side being sent.
  ThreadRecommendSide? _sending;

  /// The forum's answer told nothing: the buttons stay off until the page is read again.
  bool _unconfirmed = false;

  /// The side counted for this account and thread, if any.
  ThreadRecommendSide? get _counted => ThreadRecommendMemory.of(widget.recommend)?.side;

  /// The evaluation shown: the page's, with the side counted from it added while the page is the one it was sent
  /// from (a page read again has it in its counts already).
  ThreadRecommend get _recommend => switch (ThreadRecommendMemory.of(widget.recommend)) {
    (:final from, :final side) when from == widget.recommend => from.pressed(side),
    _ => widget.recommend,
  };

  @override
  void didUpdateWidget(ThreadRecommendButtons oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recommend != widget.recommend) {
      _unconfirmed = false;
    }
  }

  Future<void> _press(ThreadRecommendSide side) async {
    if (_sending != null || _counted != null || _unconfirmed) {
      return;
    }
    final recommend = widget.recommend;
    if (recommend.guest) {
      await context.pushNamed(ScreenPaths.login);
      return;
    }
    final repository =
        context.readOrNull<ThreadRecommendRepository>() ??
        ThreadRecommendRepository.network(getIt.get<NetClientProvider>());
    final auth = context.readOrNull<AuthenticationRepository>();
    if (auth != null && auth.effectiveCurrentUid != recommend.viewerUid) {
      showSnackBar(context: context, message: context.t.general.accountChangedRetry);
      return;
    }
    setState(() => _sending = side);
    final outcome = await repository.submit(recommend, side);
    if (!mounted) {
      return;
    }
    setState(() => _sending = null);
    switch (outcome) {
      case ThreadRecommendDone():
        setState(() => ThreadRecommendMemory.remember(recommend, side));
      case ThreadRecommendRefused(:final message):
        showSnackBar(context: context, message: message);
      case ThreadRecommendNeedLogin():
        await context.pushNamed(ScreenPaths.login);
      case ThreadRecommendAccountChanged():
        showSnackBar(context: context, message: context.t.general.accountChangedRetry);
      case ThreadRecommendUnknown():
        setState(() => _unconfirmed = true);
        showSnackBar(context: context, message: context.t.threadRecommend.unknown);
    }
  }

  Widget _button(BuildContext context, ThreadRecommendSide side, ThreadRecommendButton button) {
    final counted = _counted == side;
    final icon = switch ((side, counted)) {
      (ThreadRecommendSide.add, false) => Icons.thumb_up_outlined,
      (ThreadRecommendSide.add, true) => Icons.thumb_up,
      (ThreadRecommendSide.subtract, false) => Icons.thumb_down_outlined,
      (ThreadRecommendSide.subtract, true) => Icons.thumb_down,
    };
    final colorScheme = Theme.of(context).colorScheme;
    return TextButton.icon(
      onPressed: _sending != null || _counted != null || _unconfirmed ? null : () async => _press(side),
      style: counted ? TextButton.styleFrom(disabledForegroundColor: colorScheme.primary) : null,
      icon: _sending == side ? const SizedBox(width: 16, height: 16, child: CircularIndicator()) : Icon(icon, size: 18),
      label: Text(button.count > 0 ? '${button.label} ${button.count}' : button.label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final add = _recommend.add;
    final subtract = _recommend.subtract;
    return Wrap(
      children: [
        if (add != null) _button(context, ThreadRecommendSide.add, add),
        if (subtract != null) _button(context, ThreadRecommendSide.subtract, subtract),
      ],
    );
  }
}
