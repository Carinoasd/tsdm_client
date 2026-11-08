import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
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
class FrequentForumsBar extends StatelessWidget {
  /// Constructor.
  const FrequentForumsBar({super.key});

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
        final forums = FrequentForumsStore.of(data, frequentForumsUid(context));
        if (forums.isEmpty) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          height: frequentForumsBarHeight,
          child: _Bar(forums: forums),
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.forums});

  final FrequentForumsOfAccount forums;

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
      onReorder: (oldIndex, newIndex) async {
        // Only the pinned forums, which come first, can be arranged.
        if (oldIndex >= pinned.length) {
          return;
        }
        await frequentForumsStore().reorder(frequentForumsUid(context), oldIndex, newIndex.clamp(0, pinned.length));
      },
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
  final pinned = frequentForumsStore().current(uid).isPinned(forum.fid);
  final toggle = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListTile(
        leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
        title: Text(pinned ? context.t.forumCard.unpin : context.t.forumCard.pin),
        onTap: () => Navigator.of(context).pop(true),
      ),
    ),
  );
  if (toggle ?? false) {
    await frequentForumsStore().togglePin(uid, forum);
  }
}

/// Notes that the account in use visited [forum].
Future<void> noteForumVisit(BuildContext context, FrequentForum forum) async {
  if (!getIt.isRegistered<SettingsRepository>()) {
    return;
  }
  await frequentForumsStore().visit(frequentForumsUid(context), forum);
}
