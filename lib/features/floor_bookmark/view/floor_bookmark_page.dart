import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/floor_bookmark/cubit/floor_bookmark_cubit.dart';
import 'package:tsdm_client/features/floor_bookmark/models/floor_bookmark.dart';
import 'package:tsdm_client/features/floor_bookmark/widgets/floor_bookmark_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The floor bookmarks of [items] by thread: the thread changed last first, its floors in order.
List<({int tid, String title, List<FloorBookmark> items})> groupFloorBookmarks(List<FloorBookmark> items) {
  final byThread = <int, List<FloorBookmark>>{};
  for (final item in [...items]..sort((a, b) => b.updated.compareTo(a.updated))) {
    (byThread[item.tid] ??= []).add(item);
  }
  return [
    for (final MapEntry(key: tid, value: list) in byThread.entries)
      (
        tid: tid,
        // The title the latest bookmark of the thread saw.
        title: list.first.threadTitle,
        items: list..sort((a, b) => (a.floor ?? 0).compareTo(b.floor ?? 0)),
      ),
  ];
}

/// Open floor [bookmark] in its thread: the forum's `findpost` finds the page it is on now.
Future<void> openFloorBookmark(BuildContext context, FloorBookmark bookmark) => context.pushNamed(
  ScreenPaths.threadV1,
  queryParameters: {'pid': '${bookmark.pid}', if (bookmark.threadTitle.isNotEmpty) 'appBarTitle': bookmark.threadTitle},
);

/// The floor bookmarks of the current account, by thread; a tap opens the floor, a long press removes it.
class FloorBookmarkPage extends StatelessWidget {
  /// Constructor.
  const FloorBookmarkPage({super.key});

  Future<void> _remove(BuildContext context, FloorBookmark bookmark) async {
    final tr = context.t.floorBookmark;
    final cubit = context.read<FloorBookmarkCubit>();
    final confirmed = await showQuestionDialog(
      context: context,
      title: tr.remove,
      message: tr.removeConfirm,
      dangerous: true,
    );
    if (confirmed ?? false) {
      await cubit.remove(bookmark.key);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.floorBookmark;
    final state = context.watch<FloorBookmarkCubit>().state;
    final textTheme = Theme.of(context).textTheme;
    final Widget body;
    if (state.uid == null) {
      body = AppStateView(icon: Icons.login_outlined, message: tr.needLogin);
    } else if (!state.loaded) {
      body = const CenteredCircularIndicator();
    } else if (state.items.isEmpty) {
      body = AppStateView(icon: Icons.turned_in_not_outlined, message: tr.empty);
    } else {
      final groups = groupFloorBookmarks(state.items);
      body = AppCenteredList(
        builder: (context, side, _) => ListView.separated(
          padding: side.copyWith(top: 4, bottom: 16),
          itemCount: groups.length,
          separatorBuilder: (_, _) => appListSeparator,
          itemBuilder: (context, index) {
            final group = groups[index];
            return AppSurface(
              key: ValueKey('floor-bookmark-thread-${group.tid}'),
              padding: edgeInsetsT4B4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      group.title.isEmpty ? '${group.tid}' : group.title,
                      style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  for (final bookmark in group.items)
                    FloorBookmarkTile(
                      bookmark,
                      key: ValueKey('floor-bookmark-${bookmark.key}'),
                      onTap: () => unawaited(openFloorBookmark(context, bookmark)),
                      onLongPress: () => unawaited(_remove(context, bookmark)),
                    ),
                ],
              ),
            );
          },
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr.title)),
      body: SafeArea(bottom: false, child: body),
    );
  }
}
