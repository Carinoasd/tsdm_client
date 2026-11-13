import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_sheet.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/profile/utils/management_group.dart';
import 'package:tsdm_client/features/profile/utils/profile_page_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The app bar of a list while a moderator picks threads in it: how many are picked ([count]), stop picking
/// ([onClose]), pick all of them ([onSelectAll], null when all are picked), manage them ([onModerate], null when none
/// is picked); [actions] go before the management.
class ThreadPickingAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// Constructor.
  const ThreadPickingAppBar({
    required this.count,
    required this.onClose,
    required this.onSelectAll,
    required this.onModerate,
    this.actions = const [],
    this.bottom,
    super.key,
  });

  /// How many threads are picked.
  final int count;

  /// Stop picking.
  final VoidCallback onClose;

  /// Pick every thread that may be picked; null when they all are.
  final VoidCallback? onSelectAll;

  /// Manage the threads picked; null when none is.
  final VoidCallback? onModerate;

  /// More actions on the threads picked, before the management.
  final List<Widget> actions;

  /// Under the bar, as [AppBar.bottom].
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) => AppBar(
    leading: IconButton(
      icon: const Icon(Icons.close),
      tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
      onPressed: onClose,
    ),
    title: Text(context.t.moderate.batch.selected(count: count)),
    actions: [
      IconButton(
        icon: const Icon(Icons.select_all_outlined),
        tooltip: context.t.moderate.batch.selectAll,
        onPressed: onSelectAll,
      ),
      ...actions,
      IconButton(
        key: const ValueKey('thread-picking-moderate'),
        icon: const Icon(Icons.admin_panel_settings_outlined),
        tooltip: context.t.moderate.menu,
        onPressed: count == 0 ? null : onModerate,
      ),
    ],
    bottom: bottom,
  );
}

/// A thread card while picking: its check box before it, [picked] or not; [onToggle] null when it may not be picked.
class PickableThreadRow extends StatelessWidget {
  /// Constructor.
  const PickableThreadRow({required this.picked, required this.onToggle, required this.child, super.key});

  /// The thread is picked.
  final bool picked;

  /// Pick or unpick the thread; null when it may not be picked.
  final VoidCallback? onToggle;

  /// The card.
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Checkbox(value: picked, onChanged: onToggle == null ? null : (_) => onToggle!()),
      Expanded(child: child),
    ],
  );
}

/// A thread of a list of threads from several forums (a search, a member's threads, the latest threads) as a
/// moderator may pick it: its `tid`, `title` and forum (`fid`, null when the row does not tell: not picked), the
/// author (`authorUid`) and whether the list's filters apply to it (`filtered`): a thread its card hides is never
/// picked.
typedef ListPickableThread = ({String tid, String title, int? fid, String? authorUid, bool filtered});

/// Whether account [uid] is of a management group as far as the app knows without asking the forum: the answer kept
/// ([ManagementGroupCache]), else the profile of the account the homepage loaded ([ProfileRepository.getCache],
/// read and kept). False when neither tells: an ordinary member sends nothing more for it.
Future<bool> knownManagementGroup(int uid, {ProfileRepository? profiles}) async {
  if (ManagementGroupCache.cached(uid) case final known?) {
    return known;
  }
  final page = profiles?.getCache();
  if (page == null) {
    return false;
  }
  final profile = (await buildProfilePage(page).run()).toNullable();
  if (profile == null || profile.uid != '$uid') {
    return false;
  }
  final value = (profile.moderatorGroup ?? '').trim().isNotEmpty;
  ManagementGroupCache.remember(uid, value: value);
  return value;
}

/// Picking threads of a list of threads from several forums to manage them together, for the accounts of a management
/// group ([knownManagementGroup]): a long press (the context menu on desktop) starts picking with a thread, then only
/// the threads of its forum may be picked, as the forum manages the threads of one forum in a request (the others it
/// leaves untouched while it says it is done). The management is the forum page's ([showBatchModerateSheet]), with
/// what the forum page tells the account it may do there ([ModerateRepository.moderationOf], asked once the
/// management is opened).
///
/// The page calls [watchPickingAccount] when it builds, builds its cards with [buildPickableCard], its app bar with
/// [buildPickingAppBar] (null: its own app bar), and wraps its page in [buildPickingPopScope].
mixin ListThreadPicking<T extends StatefulWidget> on State<T> {
  /// Where the forum page and the management go.
  ModerateRepository get pickingRepository;

  /// The account the offer was asked for, null without one.
  int? _pickingUid;

  /// The account [_pickingUid] is of a management group.
  bool _pickingOffered = false;

  /// The threads picked (tids), null when not picking.
  Set<String>? _picked;

  /// The forum of the threads picked.
  int? _pickedFid;

  /// The management is being opened.
  bool _pickingBusy = false;

  /// Builds the page again when the account in use changes ([watchPickingAccount] drops what was picked then).
  StreamSubscription<AuthStatus>? _pickingAuth;

  /// Threads are being picked.
  bool get isPicking => _picked != null;

  /// Picking is offered to the account in use.
  bool get pickingOffered => _pickingOffered;

  int? _currentUid(BuildContext context) => context.readOrNull<AuthenticationRepository>()?.effectiveCurrentUid;

  /// Ask whether the account in use may pick threads, once per account: what is picked is dropped for another account.
  void watchPickingAccount(BuildContext context) {
    _pickingAuth ??= context.readOrNull<AuthenticationRepository>()?.status.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
    final uid = _currentUid(context);
    if (uid == _pickingUid) {
      return;
    }
    _pickingUid = uid;
    _pickingOffered = false;
    _picked = null;
    _pickedFid = null;
    if (uid == null || uid <= 0) {
      return;
    }
    knownManagementGroup(uid, profiles: context.readOrNull<ProfileRepository>()).then((offered) {
      if (offered && mounted && _pickingUid == uid) {
        setState(() => _pickingOffered = true);
      }
    }).ignore();
  }

  @override
  void dispose() {
    unawaited(_pickingAuth?.cancel());
    super.dispose();
  }

  /// Stop picking.
  void stopPicking() {
    if (_picked != null) {
      setState(() {
        _picked = null;
        _pickedFid = null;
      });
    }
  }

  void _toggle(String tid) => setState(() {
    final picked = {...?_picked};
    if (!picked.remove(tid)) {
      picked.add(tid);
    }
    if (picked.isEmpty) {
      _picked = null;
      _pickedFid = null;
    } else {
      _picked = picked;
    }
  });

  /// Whether the card of [thread] hides it (its author blocked, the list's filters).
  static bool _hidden(BuildContext context, ListPickableThread thread, {bool listen = false}) {
    final blockList = currentBlockList(context, listen: listen);
    final author = int.tryParse(thread.authorUid ?? '');
    if (author != null && author > 0 && blockList.hides(author)) {
      return true;
    }
    return thread.filtered && blockList.hidesThread(title: thread.title, fid: thread.fid);
  }

  /// The card of [thread] built by [card], given how a tap and a long press pick threads (null: as usual).
  Widget buildPickableCard(
    BuildContext context,
    ListPickableThread thread,
    Widget Function(VoidCallback? onPick, VoidCallback? onStartPicking) card,
  ) {
    final fid = thread.fid;
    final picked = _picked;
    if (!_pickingOffered || fid == null || _hidden(context, thread, listen: true)) {
      return card(null, null);
    }
    if (picked == null) {
      return card(null, () {
        if (_currentUid(context) != _pickingUid) {
          return;
        }
        setState(() {
          _picked = {thread.tid};
          _pickedFid = fid;
        });
      });
    }
    final pickable = fid == _pickedFid;
    return PickableThreadRow(
      key: ValueKey('thread-picking-${thread.tid}'),
      picked: picked.contains(thread.tid),
      onToggle: pickable ? () => _toggle(thread.tid) : null,
      child: card(pickable ? () => _toggle(thread.tid) : () {}, null),
    );
  }

  /// The threads of [threads] that may be picked now: shown, of the forum of the threads picked.
  List<ListPickableThread> _pickable(BuildContext context, List<ListPickableThread> threads) => [
    for (final t in threads)
      if (t.fid != null && t.fid == _pickedFid && !_hidden(context, t)) t,
  ];

  /// The app bar while picking among [threads] (the list's rows, in its order); [onDone] shows the list as it is now
  /// once the threads were managed. Null when not picking, or when none of the threads picked is in the list any more
  /// (another page of the search, a refresh): picking stops then, and any forum may start it again.
  PreferredSizeWidget? buildPickingAppBar(
    BuildContext context,
    List<ListPickableThread> threads, {
    required VoidCallback onDone,
    PreferredSizeWidget? bottom,
  }) {
    final shown = _pickable(context, threads);
    var picked = _picked;
    if (picked != null) {
      // Only the threads picked the list still shows; built anew, no setState needed.
      final kept = {for (final t in shown) t.tid}.intersection(picked);
      if (kept.isEmpty) {
        _picked = null;
        _pickedFid = null;
      } else if (kept.length != picked.length) {
        _picked = kept;
      }
      picked = _picked;
    }
    if (picked == null) {
      return null;
    }
    final count = picked.length;
    return ThreadPickingAppBar(
      count: count,
      onClose: stopPicking,
      onSelectAll: shown.every((e) => picked!.contains(e.tid))
          ? null
          : () => setState(() => _picked = {...picked!, for (final e in shown) e.tid}),
      onModerate: _pickingBusy ? null : () async => _moderatePicked(context, threads, onDone),
      bottom: bottom,
    );
  }

  Future<void> _moderatePicked(BuildContext context, List<ListPickableThread> threads, VoidCallback onDone) async {
    final picked = _picked;
    final fid = _pickedFid;
    final uid = _pickingUid;
    if (picked == null || fid == null || uid == null) {
      return;
    }
    if (_currentUid(context) != uid) {
      // Another account: what was picked is not its own to manage.
      stopPicking();
      return;
    }
    // One forum only: the forum manages the threads of the forum of a request and leaves the others untouched.
    List<(String, String)> chosenOf(Set<String> picked) => [
      for (final t in _pickable(context, threads))
        if (picked.contains(t.tid)) (t.tid, t.title),
    ];
    if (chosenOf(picked).isEmpty) {
      return;
    }
    setState(() => _pickingBusy = true);
    final ModerateBatchReport? report;
    try {
      final moderation = await pickingRepository.moderationOf(fid);
      if (!mounted || !context.mounted || _pickingUid != uid || _pickedFid != fid) {
        return;
      }
      // What is picked now: picking may have stopped, or threads been unpicked, while the forum answered.
      final now = _picked;
      final chosen = now == null ? const <(String, String)>[] : chosenOf(now);
      if (chosen.isEmpty) {
        return;
      }
      report = await showBatchModerateSheet(
        context,
        threads: chosen,
        fid: fid,
        // What the forum page tells the account it may do there; when it does not moderate the forum (or the page did
        // not tell), every operation is offered and the forum refuses in its own words.
        perms: (moderation?.moderates ?? false) ? moderation?.perms : null,
        repository: pickingRepository,
      );
    } finally {
      if (mounted) {
        setState(() => _pickingBusy = false);
      }
    }
    if (report == null || !mounted) {
      return;
    }
    stopPicking();
    onDone();
  }

  /// [child] whose back stops picking first.
  Widget buildPickingPopScope({required Widget child}) => PopScope(
    canPop: _picked == null,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) {
        stopPicking();
      }
    },
    child: child,
  );
}
