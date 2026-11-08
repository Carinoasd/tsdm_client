import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/post/utils/image_edits.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The longest side of the picture the editor shows.
const _previewMaxSide = 1600;

/// The aspect ratios offered for the crop (width by height), null for a free one.
const _cropRatios = <(int, int)?>[null, (1, 1), (4, 3), (3, 4), (16, 9), (9, 16)];

enum _Tool { crop, mosaic }

/// [previewImageEdits] in another isolate. Top level: a closure made in a method would take its `this` along.
Future<EditedImage?> _previewInIsolate(Uint8List bytes, ImageEdits edits) =>
    Isolate.run(() => previewImageEdits(bytes, edits, maxSide: _previewMaxSide));

/// Page to edit the image [bytes] before it goes up: cut it (free or to a ratio), pixelate parts of it with a brush,
/// turn it, and choose the longest side and the JPEG quality it is written with.
///
/// Pops the [ImageEdits] to upload with: `const ImageEdits()` for 略過 (the image as it is), null when the page is left
/// (nothing uploaded).
class ImageUploadEditPage extends StatefulWidget {
  /// Constructor.
  const ImageUploadEditPage(this.bytes, {required this.maxSide, required this.quality, super.key});

  /// The image.
  final Uint8List bytes;

  /// The longest side chosen at first ([uploadImageMaxSides]).
  final int maxSide;

  /// The JPEG quality chosen at first.
  final int quality;

  /// Open the page for [bytes].
  static Future<ImageEdits?> show(
    BuildContext context,
    Uint8List bytes, {
    required int maxSide,
    required int quality,
  }) => Navigator.of(context).push<ImageEdits>(
    MaterialPageRoute(
      builder: (_) => ImageUploadEditPage(bytes, maxSide: maxSide, quality: quality),
    ),
  );

  @override
  State<ImageUploadEditPage> createState() => _ImageUploadEditPageState();
}

class _ImageUploadEditPageState extends State<ImageUploadEditPage> {
  _Tool _tool = _Tool.crop;
  int _turns = 0;
  Rect? _crop;
  (int, int)? _ratio;
  final _strokes = <MosaicStroke>[];
  List<Offset>? _drawing;
  double _brush = 0.03;
  late int _maxSide = uploadImageMaxSides.contains(widget.maxSide) ? widget.maxSide : 0;
  late double _quality = widget.quality.clamp(10, 100).toDouble();

  /// The picture shown: turned and pixelated, not cut.
  EditedImage? _preview;

  /// How many of [_strokes] [_preview] shows; the others are drawn over it until it does.
  int _shownStrokes = 0;

  bool _failed = false;
  int _renderToken = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_render());
  }

  ImageEdits get _edits => ImageEdits(
    quarterTurns: _turns,
    crop: _crop,
    strokes: List.of(_strokes),
    maxSide: _maxSide,
    quality: _quality.round(),
  );

  Future<void> _render() async {
    final token = ++_renderToken;
    final bytes = widget.bytes;
    final edits = ImageEdits(quarterTurns: _turns, strokes: List.of(_strokes));
    final strokes = _strokes.length;
    final preview = await _previewInIsolate(bytes, edits);
    if (!mounted || token != _renderToken) return;
    setState(() {
      if (preview == null) {
        _failed = true;
      } else {
        _preview = preview;
        _shownStrokes = strokes;
      }
    });
  }

  void _rotate() {
    setState(() {
      _turns = (_turns + 1) % 4;
      _crop = _crop == null ? null : turnCropRect(_crop!);
      final ratio = _ratio;
      _ratio = ratio == null ? null : (ratio.$2, ratio.$1);
      for (var i = 0; i < _strokes.length; i++) {
        _strokes[i] = _strokes[i].turned();
      }
      _shownStrokes = 0;
    });
    unawaited(_render());
  }

  void _undo() {
    setState(() {
      if (_tool == _Tool.mosaic && _strokes.isNotEmpty) {
        _strokes.removeLast();
        _shownStrokes = math.min(_shownStrokes, _strokes.length);
      } else {
        _crop = null;
        _ratio = null;
      }
    });
    if (_tool == _Tool.mosaic) unawaited(_render());
  }

  bool get _canUndo => _tool == _Tool.mosaic ? _strokes.isNotEmpty : _crop != null;

  /// The largest centered crop of [ratio] on a picture of [size].
  Rect? _ratioCrop((int, int)? ratio, Size size) {
    if (ratio == null) return _crop;
    final r = ratio.$1 / ratio.$2;
    var w = 1.0;
    var h = size.width / r / size.height;
    if (h > 1) {
      h = 1;
      w = size.height * r / size.width;
    }
    return Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.imageUpload.edit;
    final preview = _preview;
    final Widget body;
    if (_failed) {
      body = Center(child: Text(tr.failed));
    } else if (preview == null) {
      body = const CenteredCircularIndicator();
    } else {
      body = LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(preview.width.toDouble(), preview.height.toDouble());
          final fitted = applyBoxFit(BoxFit.contain, size, constraints.biggest).destination;
          final rect = Alignment.center.inscribe(fitted, Offset.zero & constraints.biggest);
          return Stack(
            children: [
              Positioned.fromRect(
                rect: rect,
                child: Image.memory(preview.bytes, fit: BoxFit.fill, gaplessPlayback: true),
              ),
              Positioned.fromRect(
                rect: rect,
                child: switch (_tool) {
                  _Tool.crop => _CropOverlay(
                    crop: _crop ?? const Rect.fromLTWH(0, 0, 1, 1),
                    ratio: _ratio == null ? null : _ratio!.$1 / _ratio!.$2 * size.height / size.width,
                    onChanged: (crop) => setState(() => _crop = crop == const Rect.fromLTWH(0, 0, 1, 1) ? null : crop),
                  ),
                  _Tool.mosaic => _MosaicOverlay(
                    strokes: _strokes.skip(_shownStrokes).toList(),
                    drawing: _drawing,
                    brush: _brush,
                    onStart: (p) => setState(() => _drawing = [p]),
                    onUpdate: (p) => setState(() => _drawing = [...?_drawing, p]),
                    onEnd: () {
                      final points = _drawing;
                      setState(() {
                        _drawing = null;
                        if (points != null && points.isNotEmpty) _strokes.add(MosaicStroke(points, _brush));
                      });
                      unawaited(_render());
                    },
                  ),
                },
              ),
            ],
          );
        },
      );
    }
    final size = preview == null ? null : Size(preview.width.toDouble(), preview.height.toDouble());
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.title),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(const ImageEdits()), child: Text(tr.skip)),
          Padding(
            padding: edgeInsetsR12,
            child: FilledButton(
              onPressed: preview == null ? null : () => Navigator.of(context).pop(_edits),
              child: Text(tr.upload),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(padding: edgeInsetsL16T16R16B16, child: body),
            ),
            Padding(
              padding: edgeInsetsL16R16,
              child: Row(
                children: [
                  SegmentedButton<_Tool>(
                    segments: [
                      ButtonSegment(value: _Tool.crop, icon: const Icon(Icons.crop_outlined), label: Text(tr.crop)),
                      ButtonSegment(
                        value: _Tool.mosaic,
                        icon: const Icon(Icons.blur_on_outlined),
                        label: Text(tr.mosaic),
                      ),
                    ],
                    selected: {_tool},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) => setState(() => _tool = v.first),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.rotate_right_outlined),
                    tooltip: tr.rotate,
                    onPressed: preview == null ? null : _rotate,
                  ),
                  IconButton(
                    icon: const Icon(Icons.undo_outlined),
                    tooltip: tr.undo,
                    onPressed: _canUndo ? _undo : null,
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 56,
              child: switch (_tool) {
                _Tool.crop => ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  children: [
                    for (final ratio in _cropRatios)
                      Padding(
                        padding: edgeInsetsR8,
                        child: ChoiceChip(
                          label: Text(ratio == null ? tr.free : '${ratio.$1}:${ratio.$2}'),
                          selected: _ratio == ratio,
                          onSelected: size == null
                              ? null
                              : (_) => setState(() {
                                  _ratio = ratio;
                                  _crop = _ratioCrop(ratio, size);
                                }),
                        ),
                      ),
                  ],
                ),
                _Tool.mosaic => Padding(
                  padding: edgeInsetsL16R16,
                  child: Row(
                    children: [
                      const Icon(Icons.brush_outlined, size: 20),
                      Expanded(
                        child: Slider(
                          value: _brush,
                          min: 0.01,
                          max: 0.08,
                          onChanged: (v) => setState(() => _brush = v),
                        ),
                      ),
                    ],
                  ),
                ),
              },
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  SegmentedButton<int>(
                    segments: [
                      for (final side in uploadImageMaxSides)
                        ButtonSegment(value: side, label: Text(side == 0 ? tr.original : '$side')),
                    ],
                    selected: {_maxSide},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) => setState(() => _maxSide = v.first),
                  ),
                  sizedBoxW12H12,
                  Tooltip(message: tr.quality, child: const Icon(Icons.high_quality_outlined, size: 20)),
                  Expanded(
                    child: Slider(
                      value: _quality,
                      min: 10,
                      max: 100,
                      divisions: 18,
                      label: '${_quality.round()}',
                      onChanged: (v) => setState(() => _quality = v),
                    ),
                  ),
                  SizedBox(width: 28, child: Text('${_quality.round()}', textAlign: TextAlign.end)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The crop frame over the picture: outside it dimmed, dragged by a corner to resize (keeping [ratio], the width by
/// the height in fractions of the picture, when set) or inside to move. [crop] and what [onChanged] gets are fractions
/// of the picture.
class _CropOverlay extends StatefulWidget {
  const _CropOverlay({required this.crop, required this.ratio, required this.onChanged});

  final Rect crop;
  final double? ratio;
  final ValueChanged<Rect> onChanged;

  @override
  State<_CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<_CropOverlay> {
  /// The corner held (0 top left, then clockwise), -1 for moving, null for nothing.
  int? _hold;
  Rect? _start;
  Offset? _from;

  /// How close to a corner a touch takes it, in logical pixels.
  static const _reach = 28.0;

  /// The smallest frame, in fractions of the picture.
  static const _min = 0.05;

  List<Offset> _corners(Rect r) => [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];

  void _onStart(Offset local, Size size) {
    final px = Rect.fromLTRB(
      widget.crop.left * size.width,
      widget.crop.top * size.height,
      widget.crop.right * size.width,
      widget.crop.bottom * size.height,
    );
    final corners = _corners(px);
    var hold = -2;
    var best = _reach;
    for (var i = 0; i < 4; i++) {
      final d = (corners[i] - local).distance;
      if (d <= best) {
        best = d;
        hold = i;
      }
    }
    if (hold == -2 && px.contains(local)) hold = -1;
    _hold = hold == -2 ? null : hold;
    _start = widget.crop;
    _from = Offset(local.dx / size.width, local.dy / size.height);
  }

  void _onUpdate(Offset local, Size size) {
    final hold = _hold;
    final start = _start;
    final from = _from;
    if (hold == null || start == null || from == null) return;
    final p = Offset((local.dx / size.width).clamp(0.0, 1.0), (local.dy / size.height).clamp(0.0, 1.0));
    if (hold == -1) {
      final dx = (p.dx - from.dx).clamp(-start.left, 1 - start.right);
      final dy = (p.dy - from.dy).clamp(-start.top, 1 - start.bottom);
      widget.onChanged(start.shift(Offset(dx, dy)));
      return;
    }
    // The opposite corner stays.
    final fixed = _corners(start)[(hold + 2) % 4];
    var w = math.max(_min, (p.dx - fixed.dx).abs());
    var h = math.max(_min, (p.dy - fixed.dy).abs());
    final right = hold == 1 || hold == 2;
    final down = hold == 2 || hold == 3;
    final roomW = right ? 1 - fixed.dx : fixed.dx;
    final roomH = down ? 1 - fixed.dy : fixed.dy;
    final ratio = widget.ratio;
    if (ratio != null) {
      // Follow the larger move, then fit the room left.
      if (w / ratio > h) {
        h = w / ratio;
      } else {
        w = h * ratio;
      }
      final fit = math.min(1, math.min(roomW / w, roomH / h));
      w *= fit;
      h *= fit;
    } else {
      w = math.min(w, roomW);
      h = math.min(h, roomH);
    }
    final left = right ? fixed.dx : fixed.dx - w;
    final top = down ? fixed.dy : fixed.dy - h;
    widget.onChanged(Rect.fromLTWH(left, top, w, h));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => _onStart(d.localPosition, size),
          onPanUpdate: (d) => _onUpdate(d.localPosition, size),
          onPanEnd: (_) => _hold = null,
          child: CustomPaint(
            size: size,
            painter: _CropPainter(widget.crop, frame: colorScheme.primary, shade: Colors.black.withValues(alpha: 0.5)),
          ),
        );
      },
    );
  }
}

class _CropPainter extends CustomPainter {
  const _CropPainter(this.crop, {required this.frame, required this.shade});

  final Rect crop;
  final Color frame;
  final Color shade;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(
      crop.left * size.width,
      crop.top * size.height,
      crop.right * size.width,
      crop.bottom * size.height,
    );
    canvas
      ..drawPath(
        Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRect(r)),
        Paint()..color = shade,
      )
      ..drawRect(
        r,
        Paint()
          ..color = frame
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    final handle = Paint()..color = frame;
    for (final c in [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft]) {
      canvas.drawCircle(c, 7, handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.crop != crop || old.frame != frame || old.shade != shade;
}

/// Where the mosaic brush goes: [strokes] not in the picture yet and the one [drawing] are drawn over it. Points are
/// fractions of the picture, the [brush] radius of its shorter side.
class _MosaicOverlay extends StatelessWidget {
  const _MosaicOverlay({
    required this.strokes,
    required this.drawing,
    required this.brush,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  final List<MosaicStroke> strokes;
  final List<Offset>? drawing;
  final double brush;
  final ValueChanged<Offset> onStart;
  final ValueChanged<Offset> onUpdate;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary.withValues(alpha: 0.4);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        Offset fraction(Offset local) =>
            Offset((local.dx / size.width).clamp(0.0, 1.0), (local.dy / size.height).clamp(0.0, 1.0));
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => onStart(fraction(d.localPosition)),
          onPanUpdate: (d) => onUpdate(fraction(d.localPosition)),
          onPanEnd: (_) => onEnd(),
          onPanCancel: onEnd,
          child: CustomPaint(
            size: size,
            painter: _StrokePainter([...strokes, if (drawing != null) MosaicStroke(drawing!, brush)], color),
          ),
        );
      },
    );
  }
}

class _StrokePainter extends CustomPainter {
  const _StrokePainter(this.strokes, this.color);

  final List<MosaicStroke> strokes;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final shorter = math.min(size.width, size.height);
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = stroke.radius * shorter * 2;
      final points = [for (final p in stroke.points) Offset(p.dx * size.width, p.dy * size.height)];
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final p in points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      if (points.length == 1) path.lineTo(points.first.dx + 0.01, points.first.dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_StrokePainter old) => old.strokes != strokes || old.color != color;
}
