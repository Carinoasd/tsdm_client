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

/// Where an evaluation sent from the app stands ([ThreadRecommendMemory]).
enum ThreadRecommendStatus {
  /// Sent, no answer yet.
  sending,

  /// The forum counted it.
  counted,

  /// The forum's answer told nothing.
  unconfirmed,
}

/// An evaluation sent from the app: the page it was sent `from`, its `side` and where it stands (`status`).
typedef ThreadRecommendEntry = ({ThreadRecommend from, ThreadRecommendSide side, ThreadRecommendStatus status});

/// The evaluations sent from the app while it runs, by account and thread ([ThreadRecommendEntry]).
///
/// The floors of a thread page are built again when they scroll back into view, and the forum does not tell which
/// side an account took: the buttons read it from here, so an evaluation being sent stays sent, a counted one stays
/// counted and one without a verdict stays off until the page is read again, whatever floor was built meanwhile.
final class ThreadRecommendMemory {
  ThreadRecommendMemory._();

  static final _entries = <(int, int), ThreadRecommendEntry>{};

  /// Counts the changes of the entries: told whenever one changes.
  static final changes = ValueNotifier<int>(0);

  /// The entry of [recommend]'s account and thread, if any.
  static ThreadRecommendEntry? of(ThreadRecommend recommend) =>
      recommend.viewerUid == null ? null : _entries[(recommend.viewerUid!, recommend.tid)];

  /// Set the entry of [from]'s account and thread: [side] sent from it, [status] where it stands; none at all
  /// without [status] (refused, nothing sent).
  static void set(ThreadRecommend from, ThreadRecommendSide side, ThreadRecommendStatus? status) {
    final uid = from.viewerUid;
    if (uid == null) {
      return;
    }
    if (status == null) {
      _entries.remove((uid, from.tid));
    } else {
      _entries[(uid, from.tid)] = (from: from, side: side, status: status);
    }
    changes.value++;
  }

  /// Forget everything (tests).
  static void clear() {
    _entries.clear();
    changes.value++;
  }
}

/// The forum's "支持" and "踩" of a thread under its first floor ([ThreadRecommend]): each button with the forum's
/// text and count, as the web page prints them (the count only when there is one).
///
/// A guest's button opens the login. A member's sends the evaluation once ([ThreadRecommendRepository]): counted, its
/// count goes up and both buttons stay off (the forum takes one evaluation per member and thread); refused, the
/// forum's message is shown; without a verdict both stay off until the page is read again. Where the forum says
/// beforehand it would refuse ([ThreadRecommend.canEvaluate] false) both are off from the start.
class ThreadRecommendButtons extends StatelessWidget {
  /// Constructor.
  const ThreadRecommendButtons(this.recommend, {super.key});

  /// The evaluation the page printed.
  final ThreadRecommend recommend;

  Future<void> _press(BuildContext context, ThreadRecommendSide side) async {
    if (ThreadRecommendMemory.of(recommend) case final entry?
        when entry.status != ThreadRecommendStatus.unconfirmed || identical(entry.from, recommend)) {
      return;
    }
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
    ThreadRecommendMemory.set(recommend, side, ThreadRecommendStatus.sending);
    ThreadRecommendOutcome outcome;
    try {
      outcome = await repository.submit(recommend, side);
    } on Object catch (e) {
      // Never left sending: whatever went wrong, the answer told nothing.
      talker.warning('thread recommend: $e');
      outcome = const ThreadRecommendUnknown();
    }
    // Kept whether this floor is still built or not: the one built again reads it.
    ThreadRecommendMemory.set(recommend, side, switch (outcome) {
      ThreadRecommendDone() => ThreadRecommendStatus.counted,
      ThreadRecommendUnknown() => ThreadRecommendStatus.unconfirmed,
      _ => null,
    });
    if (!context.mounted) {
      return;
    }
    switch (outcome) {
      case ThreadRecommendDone():
        break;
      case ThreadRecommendRefused(:final message):
        showSnackBar(context: context, message: message);
      case ThreadRecommendNeedLogin():
        await context.pushNamed(ScreenPaths.login);
      case ThreadRecommendAccountChanged():
        showSnackBar(context: context, message: context.t.general.accountChangedRetry);
      case ThreadRecommendUnknown():
        showSnackBar(context: context, message: context.t.threadRecommend.unknown);
    }
  }

  Widget _button(
    BuildContext context,
    ThreadRecommendSide side,
    ThreadRecommendButton button,
    ThreadRecommendEntry? entry,
  ) {
    final counted = entry?.status == ThreadRecommendStatus.counted && entry?.side == side;
    final sending = entry?.status == ThreadRecommendStatus.sending && entry?.side == side;
    final off = switch (entry) {
      // The forum would refuse whatever is sent: the counts only.
      _ when !recommend.canEvaluate => true,
      null => false,
      // The same page built again stays off; a page read again (another object, even with the same counts: a request
      // that never reached the forum changed nothing) may be evaluated.
      (:final from, side: _, status: ThreadRecommendStatus.unconfirmed) => identical(from, recommend),
      _ => true,
    };
    final icon = switch ((side, counted)) {
      (ThreadRecommendSide.add, false) => Icons.thumb_up_outlined,
      (ThreadRecommendSide.add, true) => Icons.thumb_up,
      (ThreadRecommendSide.subtract, false) => Icons.thumb_down_outlined,
      (ThreadRecommendSide.subtract, true) => Icons.thumb_down,
    };
    final colorScheme = Theme.of(context).colorScheme;
    return TextButton.icon(
      onPressed: off ? null : () async => _press(context, side),
      style: counted ? TextButton.styleFrom(disabledForegroundColor: colorScheme.primary) : null,
      icon: sending ? const SizedBox(width: 16, height: 16, child: CircularIndicator()) : Icon(icon, size: 18),
      label: Text(button.count > 0 ? '${button.label} ${button.count}' : button.label),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ThreadRecommendMemory.changes,
    builder: (context, _) {
      final entry = ThreadRecommendMemory.of(recommend);
      // The page's counts, with the side counted from this very page added (a page read again has it already; one read
      // while the evaluation was out may lack it until read once more).
      final shown = switch (entry) {
        (:final from, :final side, status: ThreadRecommendStatus.counted) when from == recommend => from.pressed(side),
        _ => recommend,
      };
      return Wrap(
        children: [
          if (shown.add case final add?) _button(context, ThreadRecommendSide.add, add, entry),
          if (shown.subtract case final subtract?) _button(context, ThreadRecommendSide.subtract, subtract, entry),
        ],
      );
    },
  );
}
