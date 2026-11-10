import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/homepage/models/home_block.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Name of [block] on the layout page.
String homeBlockLabel(BuildContext context, HomeBlock block) {
  final tr = context.t.settingsPage.appearanceSection.homeLayout;
  return switch (block) {
    HomeBlock.greeting => tr.greeting,
    HomeBlock.support => tr.support,
    HomeBlock.pinned => tr.pinned,
    HomeBlock.guide => tr.guide,
    HomeBlock.stats => tr.stats,
    HomeBlock.tools => tr.tools,
    HomeBlock.online => tr.online,
  };
}

/// Page to arrange the blocks of the homepage: a switch to show or hide each, a handle to drag it to its place.
class SettingsHomeLayoutPage extends StatelessWidget {
  /// Constructor.
  const SettingsHomeLayoutPage({super.key});

  void _save(BuildContext context, HomeBlockLayout layout) =>
      context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.homeLayout, layout.encode()));

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.homeLayout;
    final layout = HomeBlockLayout.parse(context.select<SettingsBloc, String>((b) => b.state.settingsMap.homeLayout));
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.title),
        actions: [
          IconButton(
            key: const ValueKey('home-layout-reset'),
            icon: const Icon(Icons.restart_alt_outlined),
            tooltip: tr.reset,
            onPressed: layout.isDefault ? null : () => _save(context, HomeBlockLayout.defaults),
          ),
        ],
      ),
      body: SafeArea(
        bottom: false,
        top: false,
        child: AppCenteredList(
          builder: (context, horizontal, width) => ReorderableListView.builder(
            key: const ValueKey('home-layout-list'),
            padding: horizontal + edgeInsetsT12 + context.safePadding() + const EdgeInsets.only(bottom: 24),
            itemCount: layout.order.length,
            buildDefaultDragHandles: false,
            onReorder: (oldIndex, newIndex) => _save(context, layout.moved(oldIndex, newIndex)),
            itemBuilder: (context, index) {
              final block = layout.order[index];
              return Padding(
                key: ValueKey('home-layout-${block.id}'),
                padding: const EdgeInsets.only(bottom: appSurfaceGapCompact),
                child: AppSurface(
                  child: Row(
                    children: [
                      ReorderableDragStartListener(
                        key: ValueKey('home-layout-handle-${block.id}'),
                        index: index,
                        child: Icon(Icons.drag_handle_outlined, color: colorScheme.outline),
                      ),
                      sizedBoxW12H12,
                      Expanded(child: Text(homeBlockLabel(context, block))),
                      Switch(
                        key: ValueKey('home-layout-switch-${block.id}'),
                        value: layout.isVisible(block),
                        onChanged: (v) => _save(context, layout.withVisible(block, visible: v)),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
