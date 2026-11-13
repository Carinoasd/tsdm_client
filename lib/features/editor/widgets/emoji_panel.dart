import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/custom_emoji/models/custom_emoji.dart';
import 'package:tsdm_client/features/custom_emoji/repository/custom_emoji_store.dart';
import 'package:tsdm_client/features/custom_emoji/widgets/custom_emoji_grid.dart';
import 'package:tsdm_client/features/editor/bloc/emoji_bloc.dart';
import 'package:tsdm_client/features/editor/repository/editor_repository.dart';
import 'package:tsdm_client/features/editor/repository/recent_emoji_store.dart';
import 'package:tsdm_client/features/editor/utils/custom_image_input.dart';
import 'package:tsdm_client/features/editor/widgets/custom_image_tab.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/indicator.dart';

final _emojiCodeRe = RegExp(r'^\{:(\d+)_(\d+):\}$');

/// The image of the emoji [code] (`{:12_865:}`) in the emoji cache, null when it is not there.
Uint8List? _cachedEmoji(String code) {
  final match = _emojiCodeRe.firstMatch(code);
  if (match == null || !getIt.isRegistered<ImageCacheProvider>()) {
    return null;
  }
  return getIt.get<ImageCacheProvider>().getEmojiCacheSync(match.group(1)!, match.group(2)!);
}

/// How many emojis the panel puts on a row [width] wide: as many as with cells of at most 48 and gaps of 6 between
/// them, the gaps now inside the cells so the whole cell takes the tap; one fewer where that would leave a cell under
/// 48 wide.
int emojiPanelColumns(double width) => max(1, min(((width - 6) / 54).ceil(), (width / 48).floor()));

/// The emoji panel of the reply box: the emojis inserted lately first (kept on this device, [RecentEmojiStore]), the
/// user's saved images (the editor's [CustomImageTab]), the user's custom emoji packs (with [sendCustomEmoji], those
/// with images), then the forum's emoji groups. A tap gives [onPicked] the emoji code (`{:12_865:}`), the image's
/// BBCode (`[img]…[/img]`, [isCustomImageBBCode]) or the attachment of a custom emoji once [sendCustomEmoji] gave it
/// (`[attachimg]aid[/attachimg]`, [isCustomEmojiBBCode]); the panel stays open for the next one.
///
/// [groups] replaces the forum's groups (tests), [emojiImage] the emoji cache.
class EmojiPanel extends StatefulWidget {
  /// Constructor.
  const EmojiPanel({
    required this.onPicked,
    this.height = 280,
    this.groups,
    this.emojiImage,
    this.sendCustomEmoji,
    super.key,
  });

  /// Called with what was picked.
  final void Function(String code) onPicked;

  /// Puts a custom emoji into the reply as an attachment, null where the reply cannot take one: the custom emoji
  /// packs are offered only with it.
  final CustomEmojiSender? sendCustomEmoji;

  /// Height of the panel.
  final double height;

  /// The emoji groups to show instead of the forum's.
  final List<EmojiGroup>? groups;

  /// The image of an emoji code, the emoji cache by default.
  final Uint8List? Function(String code)? emojiImage;

  /// The groups every panel shows when none are given (tests and their screenshots: no emoji cache there).
  @visibleForTesting
  static List<EmojiGroup>? debugGroups;

  /// The images every panel shows when none are given, see [debugGroups].
  @visibleForTesting
  static Uint8List? Function(String code)? debugEmojiImage;

  @override
  State<EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<EmojiPanel> with TickerProviderStateMixin {
  TabController? _tabs;
  int _tabCount = 0;
  int _firstGroup = 2;

  @override
  void dispose() {
    _tabs?.dispose();
    super.dispose();
  }

  Uint8List? _image(String code) => (widget.emojiImage ?? EmojiPanel.debugEmojiImage ?? _cachedEmoji)(code);

  void _pick(String code) {
    RecentEmojiStore.app?.use(code);
    widget.onPicked(code);
  }

  /// [count] tabs, the forum's groups from [firstGroup] on.
  ///
  /// Made again when the number of tabs changes (the custom emoji packs come once the reply knows it can take them, a
  /// pack is added or emptied): the tab shown stays, a forum group by its place among the groups.
  TabController _controllerOf(int count, {required int firstGroup, required bool startWithRecent}) {
    final old = _tabs;
    if (old == null || _tabCount != count) {
      final int initial;
      if (old == null) {
        // The recent ones first when there are any, else the first group of the forum.
        initial = startWithRecent || count <= firstGroup ? 0 : firstGroup;
      } else if (old.index < 2) {
        initial = old.index;
      } else if (old.index >= _firstGroup) {
        initial = old.index - _firstGroup + firstGroup;
      } else {
        initial = old.index < firstGroup ? old.index : firstGroup - 1;
      }
      old?.dispose();
      _tabCount = count;
      _firstGroup = firstGroup;
      _tabs = TabController(length: count, vsync: this, initialIndex: count == 0 ? 0 : initial.clamp(0, count - 1));
    }
    return _tabs!;
  }

  /// Offer to remove [code] from the recent ones, in a menu at the tile long pressed ([context]).
  Future<void> _offerRemoveRecent(BuildContext context, String code) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) {
      return;
    }
    final rect = RelativeRect.fromRect(
      box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
      Offset.zero & overlay.size,
    );
    final remove = await showMenu<bool>(
      context: context,
      position: rect,
      items: [
        PopupMenuItem(
          key: const ValueKey('emoji-panel-remove-recent'),
          value: true,
          child: Text(context.t.bbcodeEditor.emoji.removeRecent),
        ),
      ],
    );
    if (remove ?? false) {
      await RecentEmojiStore.app?.remove(code);
    }
  }

  Widget _emojiTile(String code, {bool recent = false}) {
    final Widget child;
    if (isCustomImageBBCode(code)) {
      final url = parseCustomImageInput(code) ?? '';
      child = ClipRRect(
        borderRadius: BorderRadius.circular(appInnerRadius),
        child: CachedImage(url, width: 44, height: 44, fit: BoxFit.cover),
      );
    } else {
      final bytes = _image(code);
      child = bytes == null
          ? FittedBox(child: Text(code))
          : ClipOval(child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true));
    }
    return Tooltip(
      message: code,
      child: Material(
        type: MaterialType.transparency,
        child: Builder(
          builder: (context) => Semantics(
            button: true,
            child: InkWell(
              key: ValueKey('emoji-panel-$code'),
              borderRadius: BorderRadius.circular(appInnerRadius),
              onTap: () => _pick(code),
              onLongPress: recent ? () => unawaited(_offerRemoveRecent(context, code)) : null,
              // The gap between the emojis is inside the cells (see [_grid]): the whole cell takes the tap.
              child: Padding(padding: const EdgeInsets.all(6), child: child),
            ),
          ),
        ),
      ),
    );
  }

  Widget _grid(List<String> codes, {bool recent = false}) => LayoutBuilder(
    builder: (context, constraints) {
      const padding = EdgeInsets.symmetric(horizontal: 9, vertical: 5);
      return GridView.builder(
        padding: padding,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: emojiPanelColumns(constraints.maxWidth - padding.horizontal),
          mainAxisExtent: 54,
        ),
        itemCount: codes.length,
        itemBuilder: (context, index) => _emojiTile(codes[index], recent: recent),
      );
    },
  );

  Widget _hint(BuildContext context, IconData icon, String message) => Center(
    child: Padding(
      padding: edgeInsetsL24R24,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.outline),
          sizedBoxW8H8,
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    ),
  );

  Widget _buildRecent(BuildContext context) {
    final store = RecentEmojiStore.app;
    if (store == null) {
      return _hint(context, Icons.history_outlined, context.t.bbcodeEditor.emoji.noRecent);
    }
    return ValueListenableBuilder<List<String>>(
      valueListenable: store.recent,
      builder: (context, codes, _) => codes.isEmpty
          ? _hint(context, Icons.history_outlined, context.t.bbcodeEditor.emoji.noRecent)
          : _grid(codes, recent: true),
    );
  }

  Widget _buildImages(BuildContext context) {
    if (!getIt.isRegistered<StorageProvider>()) {
      return _hint(context, Icons.collections_outlined, context.t.bbcodeEditor.customImage.empty);
    }
    // The same tab as the editor's sheet: add, long press to delete.
    return CustomImageTab(onPicked: _pick, padding: edgeInsetsL12T8R12B8);
  }

  /// The tabs, with the custom emoji packs that have images when the reply can take them ([EmojiPanel.sendCustomEmoji]).
  Widget _buildWithPacks(BuildContext context, List<EmojiGroup> groups) {
    final store = CustomEmojiStore.app;
    if (widget.sendCustomEmoji == null || store == null) {
      return _buildTabs(context, groups, const []);
    }
    return ValueListenableBuilder<List<CustomEmojiPack>>(
      valueListenable: store.packs,
      builder: (context, packs, _) => _buildTabs(context, groups, packs.where((e) => e.emojis.isNotEmpty).toList()),
    );
  }

  Widget _buildTabs(BuildContext context, List<EmojiGroup> groups, List<CustomEmojiPack> packs) {
    final tr = context.t.bbcodeEditor;
    final hasRecent = RecentEmojiStore.app?.recent.value.isNotEmpty ?? false;
    final controller = _controllerOf(
      groups.length + packs.length + 2,
      firstGroup: packs.length + 2,
      startWithRecent: hasRecent,
    );
    return Column(
      children: [
        TabBar(
          controller: controller,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          dividerColor: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6),
          tabs: [
            Tab(
              key: const ValueKey('emoji-panel-recent-tab'),
              icon: const Icon(Icons.history_outlined, size: 20),
              iconMargin: EdgeInsets.zero,
              height: 40,
              child: Text(tr.emoji.recent),
            ),
            Tab(height: 40, child: Text(tr.customImage.tab)),
            ...packs.map((e) => Tab(key: ValueKey('emoji-panel-pack-${e.id}'), height: 40, child: Text(e.name))),
            ...groups.map((e) => Tab(height: 40, child: Text(e.name))),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: controller,
            children: [
              _buildRecent(context),
              _buildImages(context),
              // A custom emoji is an attachment of this reply only: never one of the recent emojis.
              ...packs.map(
                (e) => CustomEmojiGrid(
                  key: ValueKey('emoji-panel-pack-grid-${e.id}'),
                  pack: e,
                  send: widget.sendCustomEmoji!,
                  onSent: (bbcode) {
                    if (bbcode != null && mounted) widget.onPicked(bbcode);
                  },
                ),
              ),
              ...groups.map((e) => _grid(e.emojiList.map((emoji) => emoji.code).toList())),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups ?? EmojiPanel.debugGroups;
    final Widget body;
    if (groups != null) {
      body = _buildWithPacks(context, groups);
    } else {
      body = MultiBlocProvider(
        providers: [
          RepositoryProvider<EditorRepository>(create: (_) => EditorRepository()),
          BlocProvider(
            create: (context) => EmojiBloc(editRepository: context.repo())..add(EmojiFetchFromAssetEvent()),
          ),
        ],
        child: BlocBuilder<EmojiBloc, EmojiState>(
          builder: (context, state) => switch (state.status) {
            EmojiStatus.initial || EmojiStatus.loading => const CenteredCircularIndicator(),
            EmojiStatus.failure => buildRetryButton(
              context,
              () => context.read<EmojiBloc>().add(EmojiFetchFromAssetEvent()),
            ),
            EmojiStatus.success => _buildWithPacks(context, state.emojiGroupList ?? const []),
          },
        ),
      );
    }
    return SizedBox(
      key: const ValueKey('emoji-panel'),
      height: widget.height,
      child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerLow, child: body),
    );
  }
}
