part of '../settings_page.dart';

/// Reading and editing behavior: order, floor interaction, editor parser and the templates.
class _BehaviorSection extends StatelessWidget {
  const _BehaviorSection();

  @override
  Widget build(BuildContext context) => SettingsSelect(
    select: (m) => (
      collapseAppBarWhenScroll: m.collapseAppBarWhenScroll,
      enableEditorBBCodeParser: m.enableEditorBBCodeParser,
      openPosition: m.openPosition,
      postImageAutoLoad: m.postImageAutoLoad,
      threadFloorInteractionMode: m.threadFloorInteractionMode,
      threadReverseOrder: m.threadReverseOrder,
      threadSwipePaging: m.threadSwipePaging,
    ),
    builder: (context, s) {
      final tr = context.t.settingsPage.behaviorSection;
      final threadReverseOrder = s.threadReverseOrder;
      final enableBBCodeParser = s.enableEditorBBCodeParser;
      final threadFloorInteractionMode = s.threadFloorInteractionMode;
      final collapseAppBarWhenScroll = s.collapseAppBarWhenScroll;
      final postImageAutoLoad = PostImageAutoLoad.fromIndex(s.postImageAutoLoad);

      return AppTileGroup(
        title: tr.title,
        icon: Icons.tune_outlined,
        children: [
          SectionSwitchListTile(
            secondary: const Icon(Icons.align_vertical_top_outlined),
            title: Text(tr.threadReverseOrder.title),
            subtitle: Text(tr.threadReverseOrder.detail),
            value: threadReverseOrder,
            onChanged: (v) async =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.threadReverseOrder, v)),
          ),
          SectionListTile(
            key: const ValueKey('settings-thread-open-position'),
            leading: const Icon(Icons.bookmark_outline),
            title: Text(tr.threadOpenPosition.title),
            subtitle: Text(threadOpenPositionLabel(context, s.openPosition)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await showSelectThreadOpenPosition(context, s.openPosition);
              if (result == null || !context.mounted) return;
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.threadOpenPosition, result.index));
            },
          ),
          SectionListTile(
            leading: const Icon(Icons.touch_app_outlined),
            title: Text(tr.threadFloorInteractionMode.title),
            subtitle: Text(tr.threadFloorInteractionMode.detail),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await showSelectThreadFloorInteractionMode(context, threadFloorInteractionMode);
              if (result == null) return;
              if (!context.mounted) return;
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.threadFloorInteractionMode, result));
            },
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.vertical_align_top_outlined),
            title: Text(tr.collapseAppBarWhenScroll.title),
            subtitle: Text(tr.collapseAppBarWhenScroll.detail),
            value: collapseAppBarWhenScroll,
            onChanged: (v) async =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.collapseAppBarWhenScroll, v)),
          ),
          SectionSwitchListTile(
            key: const ValueKey('settings-thread-swipe-paging'),
            secondary: const Icon(Icons.swipe_outlined),
            title: Text(tr.threadSwipePaging.title),
            value: s.threadSwipePaging,
            onChanged: (v) async =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.threadSwipePaging, v)),
          ),
          SectionListTile(
            key: const ValueKey('settings-post-image-auto-load'),
            leading: const Icon(Icons.image_outlined),
            title: Text(tr.postImageAutoLoad.title),
            subtitle: Text(postImageAutoLoadLabel(context, postImageAutoLoad)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await showSelectPostImageAutoLoad(context, postImageAutoLoad);
              if (result == null || !context.mounted) return;
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.postImageAutoLoad, result.index));
            },
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.code_outlined),
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(child: Text(tr.editorBBCodeParser.title)),
                sizedBoxW8H8,
                IconButton(
                  icon: Icon(Icons.help_outline, color: Theme.of(context).colorScheme.secondary),
                  tooltip: tr.editorBBCodeParser.tip.title,
                  onPressed: () async => showMessageSingleButtonDialog(
                    context: context,
                    title: tr.editorBBCodeParser.tip.title,
                    message: tr.editorBBCodeParser.tip.detail,
                  ),
                ),
              ],
            ),
            value: enableBBCodeParser,
            onChanged: (v) async =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.enableEditorBBCodeParser, v)),
          ),
          SectionListTile(
            leading: const Icon(Icons.star_rate_outlined),
            title: Text(context.t.fastRateTemplate.title),
            subtitle: Text(context.t.fastRateTemplate.details),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async => context.pushNamed(ScreenPaths.fastRateTemplate, pathParameters: {'pick': 'false'}),
          ),
          SectionListTile(
            leading: const Icon(Icons.quickreply_outlined),
            title: Text(context.t.fastReplyTemplate.title),
            subtitle: Text(context.t.fastReplyTemplate.details),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async => context.pushNamed(ScreenPaths.fastReplyTemplate, pathParameters: {'pick': 'false'}),
          ),
          // What the editors kept and did not send, for the current account.
          SectionListTile(
            key: const ValueKey('settings-local-drafts'),
            leading: const Icon(Icons.history_edu_outlined),
            title: Text(context.t.localDraft.title),
            subtitle: Text(context.t.localDraft.details),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async => context.pushNamed(ScreenPaths.localDrafts),
          ),
          SectionListTile(
            key: const ValueKey('settings-custom-emoji-packs'),
            leading: const Icon(Icons.emoji_emotions_outlined),
            title: Text(context.t.customEmoji.title),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async => context.pushNamed(ScreenPaths.customEmojiPacks),
          ),
        ],
      );
    },
  );
}
