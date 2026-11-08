import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/custom_emoji/models/custom_emoji.dart';
import 'package:tsdm_client/features/custom_emoji/widgets/custom_emoji_image.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Puts a custom emoji into the post being edited: uploads it as an attachment (or reuses the upload) and gives the
/// BBCode that shows it (`[attachimg]aid[/attachimg]`), null when that failed (the editor told why).
typedef CustomEmojiSender = Future<String?> Function(CustomEmoji emoji);

/// The images of a custom emoji pack in the emoji picker; a tap gives [send] the image, its tile showing the progress
/// until [onSent] gets the BBCode (null when it failed). One at a time.
class CustomEmojiGrid extends StatefulWidget {
  /// Constructor.
  const CustomEmojiGrid({required this.pack, required this.send, required this.onSent, super.key});

  /// The pack.
  final CustomEmojiPack pack;

  /// Uploads the image.
  final CustomEmojiSender send;

  /// Gets what [send] gave.
  final void Function(String? bbcode) onSent;

  @override
  State<CustomEmojiGrid> createState() => _CustomEmojiGridState();
}

class _CustomEmojiGridState extends State<CustomEmojiGrid> {
  String? _sending;

  Future<void> _tap(CustomEmoji emoji) async {
    if (_sending != null) return;
    setState(() => _sending = emoji.sha256);
    String? bbcode;
    try {
      bbcode = await widget.send(emoji);
    } finally {
      if (mounted) setState(() => _sending = null);
    }
    widget.onSent(bbcode);
  }

  @override
  Widget build(BuildContext context) {
    final emojis = widget.pack.emojis;
    return GridView.builder(
      padding: edgeInsetsL12R12,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 72,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
      ),
      itemCount: emojis.length,
      itemBuilder: (context, index) {
        final emoji = emojis[index];
        final sending = _sending == emoji.sha256;
        return Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('custom-emoji-pick-${emoji.sha256}'),
            borderRadius: BorderRadius.circular(appInnerRadius),
            onTap: _sending == null ? () async => _tap(emoji) : null,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.all(2),
                  child: Opacity(opacity: sending ? 0.4 : 1, child: CustomEmojiImage(emoji, size: 68)),
                ),
                if (sending) const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 3)),
              ],
            ),
          ),
        );
      },
    );
  }
}

final _attachImgRe = RegExp(r'^\[attachimg\]\d+\[/attachimg\]$');

/// Whether [code] is what a [CustomEmojiSender] gives: an attachment image (`[attachimg]aid[/attachimg]`).
bool isCustomEmojiBBCode(String? code) => code != null && _attachImgRe.hasMatch(code);
