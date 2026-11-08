import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart' show AuthStatus;
import 'package:tsdm_client/features/authentication/utils/account_changes.dart';
import 'package:tsdm_client/features/forum/utils/frequent_forums.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// Height of [FrequentForumsBar].
const frequentForumsBarHeight = 48.0;

/// The store of the settings in use.
FrequentForumsStore frequentForumsStore() => FrequentForumsStore(getIt.get<SettingsRepository>());

/// The uid the frequent forums belong to: the account in use, null for a visitor.
int? frequentForumsUid(BuildContext context) => context.read<AuthenticationRepository>().effectiveCurrentUid;

/// A row of the forums the account pinned (drag to arrange) and visited lately; nothing at all when it has none.
class FrequentForumsBar extends StatefulWidget {
  /// Constructor.
  const FrequentForumsBar({super.key});

  @override
  State<FrequentForumsBar> createState() => _FrequentForumsBarState();
}

class _FrequentForumsBarState extends State<FrequentForumsBar> {
  StreamSubscription<AuthStatus>? _accountSub;

  /// The pinned forums in the order just dragged, until the saved settings show it (the drop must not jump back).
  List<FrequentForum>? _dragged;

  @override
  void initState() {
    super.initState();
    // The settings name the account before the repository does (a switch writes them first), so a switch is followed
    // by the account status too.
    _accountSub = listenAccountChanges(
      context.read<AuthenticationRepository>(),
      onLoggingIn: () {},
      onChanged: () {
        if (mounted) {
          setState(() => _dragged = null);
        }
      },
    );
  }

  @override
  void dispose() {
    unawaited(_accountSub?.cancel());
    super.dispose();
  }

  Future<void> _reorder(FrequentForumsOfAccount forums, int oldIndex, int newIndex) async {
    // Only the pinned forums, which come first, can be arranged.
    if (oldIndex >= forums.pinned.length) {
      return;
    }
    final next = frequentForumsReorder(forums, oldIndex, newIndex.clamp(0, forums.pinned.length));
    setState(() => _dragged = next.pinned);
    await frequentForumsStore().reorder(frequentForumsUid(context), oldIndex, newIndex.clamp(0, forums.pinned.length));
    if (mounted) {
      setState(() => _dragged = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = getIt.get<SettingsRepository>();
    return StreamBuilder(
      stream: settings.settings,
      initialData: settings.currentSettings,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return const SizedBox.shrink();
        }
        final saved = FrequentForumsStore.of(data, frequentForumsUid(context));
        if (saved.isEmpty) {
          return const SizedBox.shrink();
        }
        final forums = FrequentForumsOfAccount(pinned: _dragged ?? saved.pinned, recent: saved.recent);
        return SizedBox(
          height: frequentForumsBarHeight,
          child: _Bar(forums: forums, onReorder: (oldIndex, newIndex) => _reorder(forums, oldIndex, newIndex)),
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.forums, required this.onReorder});

  final FrequentForumsOfAccount forums;
  final Future<void> Function(int oldIndex, int newIndex) onReorder;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final pinned = forums.pinned;
    final recent = forums.recent;
    return ReorderableListView(
      scrollDirection: Axis.horizontal,
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      proxyDecorator: (child, _, _) => Material(type: MaterialType.transparency, child: child),
      onReorder: (oldIndex, newIndex) => unawaited(onReorder(oldIndex, newIndex)),
      children: [
        for (final (index, forum) in pinned.indexed)
          ReorderableDelayedDragStartListener(
            key: ValueKey('pinned-${forum.fid}'),
            index: index,
            child: _chip(context, forum, Icons.push_pin_outlined, colorScheme.primary),
          ),
        for (final forum in recent)
          KeyedSubtree(
            key: ValueKey('recent-${forum.fid}'),
            child: _chip(context, forum, Icons.history, colorScheme.outline),
          ),
      ],
    );
  }

  Widget _chip(BuildContext context, FrequentForum forum, IconData icon, Color iconColor) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        avatar: Icon(icon, size: 16, color: iconColor),
        label: Text(forum.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        visualDensity: VisualDensity.compact,
        onPressed: () async => context.pushNamed(
          ScreenPaths.forum,
          pathParameters: <String, String>{'fid': '${forum.fid}'},
          queryParameters: {'appBarTitle': forum.name},
        ),
      ),
    );
  }
}

/// Offers to pin or unpin [forum] (long press on a forum card).
Future<void> showFrequentForumMenu(BuildContext context, FrequentForum forum) async {
  final uid = frequentForumsUid(context);
  final account = frequentForumsStore().current(uid);
  final pinned = account.isPinned(forum.fid);
  final full = !pinned && account.pinned.length >= frequentForumsPinnedMax;
  final toggle = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListTile(
        leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
        title: Text(pinned ? context.t.forumCard.unpin : context.t.forumCard.pin),
        enabled: !full,
        onTap: () => Navigator.of(context).pop(true),
      ),
    ),
  );
  if (toggle ?? false) {
    await frequentForumsStore().togglePin(uid, forum);
  }
}

/// Notes that the account in use visited [forum]. Pages hosted without the settings (a test of one page) note nothing.
Future<void> noteForumVisit(BuildContext context, FrequentForum forum) async {
  if (!getIt.isRegistered<SettingsRepository>()) {
    return;
  }
  await frequentForumsStore().visit(frequentForumsUid(context), forum);
}
