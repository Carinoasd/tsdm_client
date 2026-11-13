import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/editor/bloc/emoji_bloc.dart';
import 'package:tsdm_client/features/editor/repository/editor_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/utils/retry_button.dart';

final _emojiCodeRe = RegExp(r'^\{:(\d+)_(\d+):\}$');

/// The group and the id of the emoji [code] (`{:12_865:}`), null when it is not such a code.
({String groupId, String id})? emojiIdsOfCode(String code) {
  final match = _emojiCodeRe.firstMatch(code);
  if (match == null) {
    return null;
  }
  return (groupId: match.group(1)!, id: match.group(2)!);
}

/// The image of the emoji [id] of group [groupId] in the emoji cache, [placeholder] while it is not there.
///
/// Read again when [revision] changes while it is missing (a group downloading, [EmojiGroupView]); with [fetch] it
/// downloads the image itself (an emoji shown alone: a recent one, one in the editor), the emoji list first when this
/// device has none yet ([EmojiListInBackground]), and again when the list comes later (the emoji panel loaded it).
class EmojiCacheImage extends StatefulWidget {
  /// Constructor.
  const EmojiCacheImage({
    required this.groupId,
    required this.id,
    required this.placeholder,
    this.revision = 0,
    this.fetch = false,
    this.width,
    this.height,
    this.fit,
    super.key,
  });

  /// Group of the emoji.
  final String groupId;

  /// Id of the emoji in its group.
  final String id;

  /// Shown while the image is not there.
  final Widget placeholder;

  /// Changes when the image may have come.
  final int revision;

  /// Download the image when it is not in the emoji cache.
  final bool fetch;

  /// Width of the image.
  final double? width;

  /// Height of the image.
  final double? height;

  /// How the image fits its box.
  final BoxFit? fit;

  @override
  State<EmojiCacheImage> createState() => _EmojiCacheImageState();
}

class _EmojiCacheImageState extends State<EmojiCacheImage> {
  Uint8List? _bytes;

  ImageCacheProvider? get _cache => getIt.isRegistered<ImageCacheProvider>() ? getIt.get<ImageCacheProvider>() : null;

  void _load() {
    _bytes = _cache?.getEmojiCacheSync(widget.groupId, widget.id);
    if (_bytes == null && widget.fetch) {
      unawaited(_download());
    }
  }

  Future<void> _download() async {
    final cache = _cache;
    if (cache == null) {
      return;
    }
    final groupId = widget.groupId;
    final id = widget.id;
    var bytes = await cache.getOrMakeEmojiCache(groupId, id);
    if (bytes == null && !await cache.hasEmojiList()) {
      // Not in the list because there is no list yet: fetched once, then the image.
      if (await EmojiListInBackground.ensure(cache)) {
        bytes = await cache.getOrMakeEmojiCache(groupId, id);
      } else {
        _waitForList(cache);
      }
    }
    if (bytes != null && mounted && widget.groupId == groupId && widget.id == id) {
      setState(() => _bytes = bytes);
    }
  }

  /// The list the emoji panel saves later (the fetch here failed): the image is downloaded then.
  ValueListenable<int>? _listRevision;

  void _waitForList(ImageCacheProvider cache) {
    if (!mounted || _listRevision != null) {
      return;
    }
    _listRevision = cache.emojiListRevision..addListener(_onList);
  }

  void _onList() {
    _stopWaitingForList();
    if (mounted && _bytes == null && widget.fetch) {
      unawaited(_download());
    }
  }

  void _stopWaitingForList() {
    _listRevision?.removeListener(_onList);
    _listRevision = null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _stopWaitingForList();
    super.dispose();
  }

  @override
  void didUpdateWidget(EmojiCacheImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId || oldWidget.id != widget.id) {
      _load();
    } else if (_bytes == null && oldWidget.revision != widget.revision) {
      _bytes = _cache?.getEmojiCacheSync(widget.groupId, widget.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return widget.placeholder;
    }
    return Image.memory(bytes, width: widget.width, height: widget.height, fit: widget.fit, gaplessPlayback: true);
  }
}

/// The emoji of [group], downloaded when it is first shown ([EmojiFetchGroupEvent] to the [EmojiBloc] above): a
/// progress bar while it downloads, a retry when some did not.
///
/// [builder] builds the grid; its revision changes as images come ([EmojiCacheImage.revision]). Without an
/// [EmojiBloc] (groups given by a test) the grid only.
class EmojiGroupView extends StatefulWidget {
  /// Constructor.
  const EmojiGroupView({required this.group, required this.builder, super.key});

  /// The group shown.
  final EmojiGroup group;

  /// Builds the grid of the group.
  final Widget Function(BuildContext context, int revision) builder;

  @override
  State<EmojiGroupView> createState() => _EmojiGroupViewState();
}

class _EmojiGroupViewState extends State<EmojiGroupView> {
  EmojiBloc? _bloc;

  @override
  void initState() {
    super.initState();
    _bloc = context.readOrNull<EmojiBloc>()?..add(EmojiFetchGroupEvent(widget.group.id));
  }

  @override
  void didUpdateWidget(EmojiGroupView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.id != widget.group.id) {
      _bloc?.add(EmojiFetchGroupEvent(widget.group.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bloc = _bloc;
    if (bloc == null) {
      return widget.builder(context, 0);
    }
    return BlocSelector<EmojiBloc, EmojiState, EmojiGroupProgress?>(
      bloc: bloc,
      selector: (state) => state.groupProgress[widget.group.id],
      builder: (context, progress) {
        final done = progress?.done ?? 0;
        if (progress?.status == EmojiStatus.failure && done == 0) {
          return buildRetryButton(context, () => bloc.add(EmojiFetchGroupEvent(widget.group.id)));
        }
        final top = switch (progress?.status) {
          EmojiStatus.failure => TextButton.icon(
            key: const ValueKey('emoji-group-retry'),
            onPressed: () => bloc.add(EmojiFetchGroupEvent(widget.group.id)),
            icon: const Icon(Icons.refresh_outlined, size: 18),
            label: Text(context.t.general.retry),
          ),
          EmojiStatus.success => const SizedBox.shrink(),
          _ => LinearProgressIndicator(
            key: const ValueKey('emoji-group-progress'),
            value: progress == null || progress.total == 0 ? null : done / progress.total,
            minHeight: 2,
          ),
        };
        return Column(
          children: [
            top,
            Expanded(child: widget.builder(context, done)),
          ],
        );
      },
    );
  }
}
