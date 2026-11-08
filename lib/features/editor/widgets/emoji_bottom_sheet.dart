import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/cache/repository/image_cache_repository.dart';
import 'package:tsdm_client/features/custom_emoji/models/custom_emoji.dart';
import 'package:tsdm_client/features/custom_emoji/repository/custom_emoji_store.dart';
import 'package:tsdm_client/features/custom_emoji/widgets/custom_emoji_grid.dart';
import 'package:tsdm_client/features/editor/bloc/emoji_bloc.dart';
import 'package:tsdm_client/features/editor/repository/editor_repository.dart';
import 'package:tsdm_client/features/editor/widgets/custom_image_tab.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Show a bottom sheet that provides emojis in editor.
///
/// With [sendCustomEmoji] (an editor that can upload attachments) the custom emoji packs are offered too: a tap sends
/// the image and the sheet closes with the BBCode it gave, or with nothing when that failed.
Future<String?> showEmojiPicker(BuildContext context, {CustomEmojiSender? sendCustomEmoji}) async {
  if (sendCustomEmoji != null) {
    // The packs read before the sheet opens: its tabs stay the same.
    await CustomEmojiStore.app?.load();
    if (!context.mounted) return null;
  }
  return showCustomBottomSheet<String>(
    title: context.t.bbcodeEditor.emoji.title,
    context: context,
    builder: (context) => RootPage(DialogPaths.emojiPicker, _EmojiBottomSheet(context, sendCustomEmoji)),
  );
}

/// Widget to show all available emojis can use in editor.
class _EmojiBottomSheet extends StatefulWidget {
  /// Constructor.
  const _EmojiBottomSheet(this.context, this.sendCustomEmoji);

  final BuildContext context;

  final CustomEmojiSender? sendCustomEmoji;

  @override
  State<_EmojiBottomSheet> createState() => _EmojiBottomSheetState();
}

// A new controller whenever the number of tabs changes (the packs are read before the sheet opens; kept safe anyway).
class _EmojiBottomSheetState extends State<_EmojiBottomSheet> with TickerProviderStateMixin {
  TabController? tabController;
  int _tabCount = 0;

  @override
  void dispose() {
    tabController?.dispose();
    super.dispose();
  }

  /// When calling this function, assume all emoji is available.
  Widget _buildEmojiTab(BuildContext context, EmojiState state, List<CustomEmojiPack> packs) {
    final emojiGroupList = state.emojiGroupList!;
    // The user's own image stickers come first (#5), their emoji packs, then the forum emoji groups.
    final count = emojiGroupList.length + packs.length + 1;
    if (tabController == null || _tabCount != count) {
      tabController?.dispose();
      _tabCount = count;
      tabController = TabController(length: count, vsync: this);
    }

    final tabs = [
      Tab(child: Text(context.t.bbcodeEditor.customImage.tab)),
      ...packs.map((e) => Tab(key: ValueKey('emoji-sheet-pack-${e.id}'), child: Text(e.name))),
      ...emojiGroupList.map((e) => Tab(child: Text(e.name))),
    ];
    final packViews = packs.map(
      (e) => CustomEmojiGrid(
        pack: e,
        send: widget.sendCustomEmoji!,
        onSent: (bbcode) {
          if (mounted) Navigator.of(context).pop(bbcode);
        },
      ),
    );
    final tabViews = emojiGroupList.map(
      (e) => GridView.builder(
        padding: edgeInsetsL12R12,
        shrinkWrap: true,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 50,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          mainAxisExtent: 50,
        ),
        itemBuilder: (context, index) {
          final data = RepositoryProvider.of<ImageCacheRepository>(
            context,
          ).getEmojiCacheSync(e.id, e.emojiList[index].id);
          if (data == null) {
            return Text('${e.id}_${e.emojiList[index].id}');
          }
          // Rounded pressed highlight around each emoji, like the swatches of the color picker.
          return Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(appInnerRadius),
              onTap: () async {
                Navigator.of(context).pop(e.emojiList[index].code);
              },
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: ClipOval(child: Image.memory(data, fit: BoxFit.cover)),
              ),
            ),
          );
        },
        itemCount: e.emojiList.length,
      ),
    );

    return Column(
      children: [
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          controller: tabController,
          tabs: tabs.toList(),
          dividerColor: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
        sizedBoxW12H12,
        Expanded(
          child: TabBarView(controller: tabController, children: [const CustomImageTab(), ...packViews, ...tabViews]),
        ),
      ],
    );
  }

  /// The tabs with the packs that have images, when the editor can send them.
  Widget _buildWithPacks(BuildContext context, EmojiState state) {
    final store = CustomEmojiStore.app;
    if (widget.sendCustomEmoji == null || store == null) {
      return _buildEmojiTab(context, state, const []);
    }
    return ValueListenableBuilder<List<CustomEmojiPack>>(
      valueListenable: store.packs,
      builder: (context, packs, _) => _buildEmojiTab(context, state, packs.where((e) => e.emojis.isNotEmpty).toList()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        RepositoryProvider<EditorRepository>(create: (_) => EditorRepository()),
        BlocProvider(create: (context) => EmojiBloc(editRepository: context.repo())..add(EmojiFetchFromAssetEvent())),
      ],
      child: BlocBuilder<EmojiBloc, EmojiState>(
        builder: (context, state) {
          final body = switch (state.status) {
            EmojiStatus.initial || EmojiStatus.loading => Center(
              child: Padding(
                padding: edgeInsetsL24R24,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularIndicator(),
                    sizedBoxW12H12,
                    Expanded(child: Text(context.t.bbcodeEditor.emoji.loadingAssets)),
                  ],
                ),
              ),
            ),
            EmojiStatus.failure => buildRetryButton(context, () {
              context.read<EmojiBloc>().add(EmojiFetchFromAssetEvent());
            }),
            EmojiStatus.success => _buildWithPacks(context, state),
          };

          return ConstrainedBox(constraints: const BoxConstraints(maxHeight: 400), child: body);
        },
      ),
    );
  }
}
