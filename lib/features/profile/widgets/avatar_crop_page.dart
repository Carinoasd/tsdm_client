import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The square of an image an avatar is cropped from, in the image's pixels.
typedef AvatarCrop = ({int left, int top, int side});

/// Page to pick the square of the image [bytes] the avatar is cropped from: the image is moved and zoomed under a
/// square frame. Pops the [AvatarCrop], or null.
class AvatarCropPage extends StatefulWidget {
  /// Constructor.
  const AvatarCropPage(this.bytes, {super.key});

  /// The image.
  final Uint8List bytes;

  /// Open the page for [bytes].
  static Future<AvatarCrop?> show(BuildContext context, Uint8List bytes) =>
      Navigator.of(context).push<AvatarCrop>(MaterialPageRoute(builder: (_) => AvatarCropPage(bytes)));

  @override
  State<AvatarCropPage> createState() => _AvatarCropPageState();
}

class _AvatarCropPageState extends State<AvatarCropPage> {
  final _transform = TransformationController();

  /// Size of the image in pixels, as shown (its orientation applied); null until read, or when it can not be read.
  Size? _size;

  bool _failed = false;

  /// Side of the square frame the transform was set up for.
  double? _frame;

  Future<void> _readSize() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final frame = await codec.getNextFrame();
      final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();
      codec.dispose();
      if (mounted) {
        setState(() => _size = size);
      }
    } on Exception {
      if (mounted) {
        setState(() => _failed = true);
      }
    }
  }

  /// The image laid out under a frame of side [frame]: its shorter side fills the frame.
  Size _shown(Size size, double frame) {
    final r = frame / math.min(size.width, size.height);
    return Size(size.width * r, size.height * r);
  }

  AvatarCrop? _crop() {
    final size = _size;
    final frame = _frame;
    if (size == null || frame == null) {
      return null;
    }
    final m = _transform.value;
    final scale = m.getMaxScaleOnAxis();
    final offset = m.getTranslation();
    // Pixels of the image per unit of the laid out image.
    final px = math.min(size.width, size.height) / frame;
    final side = (frame / scale * px).round();
    return (
      left: (-offset.x / scale * px).round().clamp(0, math.max(0, size.width.round() - side)),
      top: (-offset.y / scale * px).round().clamp(0, math.max(0, size.height.round() - side)),
      side: math.max(1, side),
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_readSize());
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = _size;
    final colorScheme = Theme.of(context).colorScheme;
    final Widget body;
    if (_failed) {
      body = Center(child: Text(context.t.editAvatarPage.imageUnreadable));
    } else if (size == null) {
      body = const CenteredCircularIndicator();
    } else {
      body = LayoutBuilder(
        builder: (context, constraints) {
          final frame = math.max(1, math.min(constraints.maxWidth, constraints.maxHeight) - 32).toDouble();
          final shown = _shown(size, frame);
          if (_frame != frame) {
            // Centered at first, and again when the frame changes size (a rotated screen).
            _frame = frame;
            _transform.value = Matrix4.translationValues(
              -(shown.width - frame) / 2,
              -(shown.height - frame) / 2,
              0,
            );
          }
          return Center(
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(border: Border.all(color: colorScheme.primary, width: 2)),
              child: SizedBox.square(
                dimension: frame,
                child: ClipRect(
                  child: InteractiveViewer(
                    transformationController: _transform,
                    constrained: false,
                    // Never smaller than the frame: what the frame shows is what is cropped.
                    minScale: 1,
                    maxScale: 8,
                    child: SizedBox.fromSize(
                      size: shown,
                      child: Image.memory(widget.bytes, fit: BoxFit.fill, gaplessPlayback: true),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t.editAvatarPage.cropTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: context.t.editAvatarPage.submit,
            onPressed: size == null ? null : () => Navigator.of(context).pop(_crop()),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(padding: edgeInsetsL16R16, child: body),
      ),
    );
  }
}
