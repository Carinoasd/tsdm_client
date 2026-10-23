import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/editor/bloc/emoji_bloc.dart';
import 'package:tsdm_client/features/editor/repository/editor_repository.dart';
import 'package:tsdm_client/features/editor/repository/recent_emoji_store.dart';
import 'package:tsdm_client/features/editor/utils/custom_image_input.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
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

/// The emoji panel of the reply box: the emojis inserted lately first (kept on this device, [RecentEmojiStore]), the
/// user's saved images, then the forum's emoji groups. A tap gives [onPicked] the emoji code (`{:12_865:}`) or the
/// image's BBCode (`[img]…[/img]`, [isCustomImageBBCode]); the panel stays open for the next one.
///
/// [groups] replaces the forum's groups (tests), [emojiImage] the emoji cache.
class EmojiPanel extends StatefulWidget {
  /// Constructor.
  const EmojiPanel({required this.onPicked, this.height = 280, this.groups, this.emojiImage, super.key});

  /// Called with what was picked.
  final void Function(String code) onPicked;

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

  TabController _controllerOf(int count, {required bool startWithRecent}) {
    if (_tabs == null || _tabCount != count) {
      _tabs?.dispose();
      _tabCount = count;
      // The recent ones first when there are any, else the first group of the forum.
      _tabs = TabController(length: count, vsync: this, initialIndex: startWithRecent || count < 3 ? 0 : 2);
    }
    return _tabs!;
  }

  Widget _emojiTile(String code, {String? tooltip}) {
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
      message: tooltip ?? code,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: ValueKey('emoji-panel-$code'),
          borderRadius: BorderRadius.circular(appInnerRadius),
          onTap: () => _pick(code),
          child: Padding(padding: const EdgeInsets.all(3), child: child),
        ),
      ),
    );
  }

  Widget _grid(List<String> codes, {double extent = 48}) => GridView.builder(
    padding: edgeInsetsL12T8R12B8,
    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: extent,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      mainAxisExtent: extent,
    ),
    itemCount: codes.length,
    itemBuilder: (context, index) => _emojiTile(codes[index]),
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
      builder: (context, codes, _) =>
          codes.isEmpty ? _hint(context, Icons.history_outlined, context.t.bbcodeEditor.emoji.noRecent) : _grid(codes),
    );
  }

  Widget _buildImages(BuildContext context) {
    if (!getIt.isRegistered<StorageProvider>()) {
      return _hint(context, Icons.collections_outlined, context.t.bbcodeEditor.customImage.empty);
    }
    return StreamBuilder<List<CustomImageEntity>>(
      stream: getIt.get<StorageProvider>().watchCustomImages(),
      builder: (context, snapshot) {
        final images = snapshot.data ?? const <CustomImageEntity>[];
        if (images.isEmpty) {
          return _hint(context, Icons.collections_outlined, context.t.bbcodeEditor.customImage.empty);
        }
        return _grid(images.map((e) => customImageBBCode(e.url)).toList(), extent: 64);
      },
    );
  }

  Widget _buildTabs(BuildContext context, List<EmojiGroup> groups) {
    final tr = context.t.bbcodeEditor;
    final hasRecent = RecentEmojiStore.app?.recent.value.isNotEmpty ?? false;
    final controller = _controllerOf(groups.length + 2, startWithRecent: hasRecent);
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
            ...groups.map((e) => Tab(height: 40, child: Text(e.name))),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: controller,
            children: [
              _buildRecent(context),
              _buildImages(context),
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
      body = _buildTabs(context, groups);
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
            EmojiStatus.success => _buildTabs(context, state.emojiGroupList ?? const []),
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
