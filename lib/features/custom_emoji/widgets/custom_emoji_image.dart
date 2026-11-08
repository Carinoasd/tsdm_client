import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tsdm_client/features/custom_emoji/models/custom_emoji.dart';
import 'package:tsdm_client/features/custom_emoji/repository/custom_emoji_store.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The saved image of [emoji], [size] square, rounded like the other thumbnails of the editor.
class CustomEmojiImage extends StatelessWidget {
  /// Constructor.
  const CustomEmojiImage(this.emoji, {required this.size, super.key});

  /// The image.
  final CustomEmoji emoji;

  /// Width and height.
  final double size;

  @override
  Widget build(BuildContext context) {
    final file = CustomEmojiStore.app?.fileOf(emoji);
    final missing = Icon(Icons.broken_image_outlined, color: Theme.of(context).colorScheme.outline);
    if (file == null) {
      return missing;
    }
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(appInnerRadius),
      child: Image.file(
        File(file.path),
        width: size,
        height: size,
        cacheWidth: px,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => missing,
      ),
    );
  }
}
