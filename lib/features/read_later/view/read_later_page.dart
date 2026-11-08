import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/read_later/cubit/read_later_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Page of the threads the current account put aside to read later.
class ReadLaterPage extends StatelessWidget {
  /// Constructor.
  const ReadLaterPage({super.key});

  Future<void> _clear(BuildContext context) async {
    final tr = context.t.readLater;
    final cubit = context.read<ReadLaterCubit>();
    final confirmed = await showQuestionDialog(
      context: context,
      title: tr.clear,
      message: tr.clearConfirm,
      dangerous: true,
    );
    if (confirmed ?? false) {
      await cubit.clear();
    }
  }

  Widget _buildItem(BuildContext context, ReadLaterItem item) {
    final colorScheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('read-later-${item.tid}'),
      background: ColoredBox(
        color: colorScheme.errorContainer,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: edgeInsetsL16R16B12,
            child: Icon(Icons.delete_outline, color: colorScheme.onErrorContainer),
          ),
        ),
      ),
      secondaryBackground: ColoredBox(
        color: colorScheme.errorContainer,
        child: Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: edgeInsetsL16R16B12,
            child: Icon(Icons.delete_outline, color: colorScheme.onErrorContainer),
          ),
        ),
      ),
      onDismissed: (_) => unawaited(context.read<ReadLaterCubit>().remove(item.tid)),
      child: AppSurface(
        padding: edgeInsetsL12T12R12B12,
        onTap: () async => context.pushNamed(ScreenPaths.threadV1, queryParameters: {'tid': '${item.tid}'}),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppIconTile(Icons.watch_later_outlined, size: 36),
            sizedBoxW12H12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  sizedBoxW8H8,
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (item.author != null) AppInfoPill(icon: Icons.person_outline, label: item.author!),
                      if (item.forumName != null) AppInfoPill(icon: Icons.forum_outlined, label: item.forumName!),
                      AppInfoPill(icon: Icons.access_time_outlined, label: item.addedAt.yyyyMMDDHHMM()),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.readLater;
    final state = context.watch<ReadLaterCubit>().state;
    final Widget body;
    if (state.uid == null) {
      body = AppStateView(icon: Icons.login_outlined, message: tr.needLogin);
    } else if (!state.loaded) {
      body = const CenteredCircularIndicator();
    } else if (state.items.isEmpty) {
      body = AppStateView(icon: Icons.watch_later_outlined, message: tr.empty);
    } else {
      body = AppCenteredList(
        builder: (context, side, _) => ListView.separated(
          padding: side.copyWith(top: 4, bottom: 16),
          itemCount: state.items.length,
          separatorBuilder: (_, _) => appListSeparator,
          itemBuilder: (context, index) => _buildItem(context, state.items[index]),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.title),
        actions: [
          if (state.items.isNotEmpty)
            IconButton(
              key: const ValueKey('read-later-clear'),
              tooltip: tr.clear,
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () async => _clear(context),
            ),
        ],
      ),
      body: SafeArea(bottom: false, child: body),
    );
  }
}
