import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/features/post/utils/pasted_image.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Takes image files dropped on [child] (desktop), handing their paths to [onImages]; anything else dropped is
/// ignored. While files are dragged over it, [child] is outlined in the primary color.
///
/// Off the desktop, or without [onImages], [child] as it is.
class ImageDropArea extends StatefulWidget {
  /// Constructor.
  const ImageDropArea({required this.child, required this.onImages, super.key});

  /// What files are dropped on (the editor).
  final Widget child;

  /// Called with the dropped image files, in the order dropped; null takes no drop.
  final void Function(List<String> paths)? onImages;

  @override
  State<ImageDropArea> createState() => _ImageDropAreaState();
}

class _ImageDropAreaState extends State<ImageDropArea> {
  bool _dragging = false;

  void _setDragging(bool value) {
    if (mounted && _dragging != value) setState(() => _dragging = value);
  }

  @override
  Widget build(BuildContext context) {
    final onImages = widget.onImages;
    if (!isDesktop || onImages == null) return widget.child;
    final colorScheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => _setDragging(true),
      onDragExited: (_) => _setDragging(false),
      onDragDone: (details) {
        _setDragging(false);
        final paths = details.files.map((e) => e.path).where(isImageFilePath).toList();
        if (paths.isNotEmpty) onImages(paths);
      },
      child: Stack(
        children: [
          widget.child,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(appInnerRadius),
                    border: Border.all(color: colorScheme.primary, width: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
