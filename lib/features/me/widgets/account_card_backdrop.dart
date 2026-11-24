import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:tsdm_client/features/background_shop/repository/my_content_background.dart';
import 'package:tsdm_client/features/me/utils/account_backdrop.dart';
import 'package:tsdm_client/features/post_background/models/post_background.dart';
import 'package:tsdm_client/features/post_background/widgets/post_background_paint.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/data_saver_mode.dart';
import 'package:tsdm_client/shared/models/post_image_auto_load.dart';
import 'package:tsdm_client/utils/network_usage.dart';

/// The picture of a background at [url]; from the cache only with [cacheOnly].
typedef AccountBackdropImage = ImageProvider<Object> Function(String url, {bool cacheOnly});

/// The pictures of [AccountCardBackdrop]: the floors' backgrounds' ([postBackgroundImage]); replaced in tests.
@visibleForTesting
AccountBackdropImage accountBackdropImage = postBackgroundImage;

/// The opacity of the veil of the card's color [surface] over a background on the side of the texts: the name
/// (`onSurface`) and the uid (`onSurfaceVariant`) keep WCAG AA on it whatever the picture's pixels are, AAA with the
/// platform's high contrast ([postBackgroundVeilOpacity]); 1 when no veil the picture shows through does.
double accountBackdropVeil(ColorScheme scheme, Color surface, {bool highContrast = false}) {
  final contrast = highContrast ? 7.0 : postBackgroundBodyContrast;
  return postBackgroundVeilOpacity(surface, [(scheme.onSurface, contrast), (scheme.onSurfaceVariant, contrast)]);
}

/// The opacity of the veil past the texts over a picture covering the card or tiled on it.
const _baseVeil = 0.15;

/// The share of a [AccountBackdropKind.side] picture's width its left edge fades out over.
const _sideFade = 0.5;

/// The share of the card's width the veil fades out over past the texts.
const _veilFade = 0.3;

/// The kind of each picture sampled in this run, by its url: whether it is on white ([accountBackdropWhiteEdged]).
final _whiteEdged = <String, bool>{};

/// [child] (the content of the account card) on the account's content background [background]
/// ([AccountBackdropKind]), under a veil of the card's color [surface] on the side of the texts: the extent of the texts
/// and of the icon at the end of the row is told by an [AccountBackdropMark] around each.
///
/// Without a background, until (or unless) its picture loads, or when no veil leaves it seen (the platform's high
/// contrast): [fallback] behind [child], as before. The picture is a still of its first frame ([postBackgroundImage]),
/// fetched when the pictures of the posts load by themselves (the cache only otherwise); one that failed is not asked again in
/// this run ([PostBackgroundFailures]).
class AccountCardBackdrop extends StatefulWidget {
  /// Constructor.
  const AccountCardBackdrop({
    required this.background,
    required this.surface,
    required this.fallback,
    required this.child,
    super.key,
  });

  /// The background, null for none.
  final AccountBackground? background;

  /// The color of the card.
  final Color surface;

  /// Drawn behind [child] without a background.
  final Decoration fallback;

  /// The content of the card.
  final Widget child;

  @override
  State<AccountCardBackdrop> createState() => _AccountCardBackdropState();
}

class _AccountCardBackdropState extends State<AccountCardBackdrop> {
  final GlobalKey _paintKey = GlobalKey();
  final _marks = _Marks();

  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// The picture of the url asked last ([_url]), from the cache only or not ([_cacheOnly]).
  String? _url;
  bool? _cacheOnly;

  /// The picture loaded, owned here.
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    NetworkUsage.unmetered.addListener(_onNetworkChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  @override
  void didUpdateWidget(AccountCardBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  @override
  void dispose() {
    NetworkUsage.unmetered.removeListener(_onNetworkChanged);
    _stop();
    _setImage(null);
    _marks.dispose();
    super.dispose();
  }

  double get _veil => accountBackdropVeil(
    Theme.of(context).colorScheme,
    widget.surface,
    highContrast: MediaQuery.maybeHighContrastOf(context) ?? false,
  );

  /// As the pictures of the posts and the floors' backgrounds: from the cache only while the data saver holds them
  /// back, or they are not loaded by themselves (the auto load setting).
  bool get _cacheOnlyNow {
    final settings = getIt.isRegistered<SettingsRepository>() ? getIt.get<SettingsRepository>().currentSettings : null;
    final mode = settings == null ? DataSaverMode.off : DataSaverMode.fromIndex(settings.dataSaverMode);
    final autoLoad = settings == null
        ? PostImageAutoLoad.always
        : PostImageAutoLoad.fromIndex(settings.postImageAutoLoad);
    final fetches = switch (DataSaver.holdsBack(context, mode)) {
      true || null => false,
      false => switch (autoLoad) {
        PostImageAutoLoad.always => true,
        PostImageAutoLoad.never => false,
        // Asked here: nothing else on the "me" tab may have asked yet; the answer comes by [_onNetworkChanged].
        PostImageAutoLoad.wifiOnly => _unmetered(),
      },
    };
    return !fetches;
  }

  static bool _unmetered() {
    NetworkUsage.refreshIfStale();
    return NetworkUsage.unmetered.value ?? false;
  }

  /// The network changed: whether the picture may be fetched may have too.
  void _onNetworkChanged() {
    if (mounted) {
      setState(_update);
    }
  }

  /// Ask the picture of the background (again) when it, or whether it may be fetched, changed.
  void _update() {
    final url = widget.background?.imageUrl;
    final cacheOnly = url == null ? null : _cacheOnlyNow;
    final wanted = url != null && _veil < 1 && !PostBackgroundFailures.failed(url, cacheOnly: cacheOnly!) ? url : null;
    if (wanted == _url && (wanted == null || cacheOnly == _cacheOnly)) {
      return;
    }
    _stop();
    if (wanted != _url) {
      _setImage(null);
    }
    _url = wanted;
    _cacheOnly = cacheOnly;
    if (wanted == null) {
      return;
    }
    if (!cacheOnly!) {
      PostBackgroundFailures.fetching(wanted);
    }
    final stream = accountBackdropImage(wanted, cacheOnly: cacheOnly).resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted || _url != wanted) {
          info.dispose();
          return;
        }
        _setImage(info.image.clone());
        info.dispose();
        unawaited(_sample(wanted));
      },
      onError: (_, _) {
        PostBackgroundFailures.add(wanted, cacheOnly: cacheOnly);
        if (mounted && _url == wanted) {
          setState(_setImageNull);
        }
      },
    );
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  void _setImageNull() => _setImage(null);

  void _stop() {
    if (_stream case final stream? when _listener != null) {
      // A picture left loading that fails is no error to report: nothing waits for it.
      stream.completer?.addEphemeralErrorListener((_, _) {});
      stream.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  void _setImage(ui.Image? image) {
    _image?.dispose();
    _image = image;
  }

  /// Tell whether the picture of [url] is on white, from a sample of [accountBackdropSampleSide] pixels at most.
  Future<void> _sample(String url) async {
    final image = _image;
    if (image == null) {
      return;
    }
    if (_whiteEdged.containsKey(url)) {
      setState(() {});
      return;
    }
    final scale = accountBackdropSampleSide / math.max(image.width, image.height);
    final width = math.max(1, (image.width * scale).round());
    final height = math.max(1, (image.height * scale).round());
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final bool white;
    try {
      final small = await picture.toImage(width, height);
      try {
        final data = await small.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        white = data != null && accountBackdropWhiteEdged(data.buffer.asUint8List(), width, height);
      } finally {
        small.dispose();
      }
    } on Object {
      // Not told: the card stays as without a background.
      return;
    } finally {
      picture.dispose();
    }
    if (_whiteEdged.length > 64) {
      _whiteEdged.clear();
    }
    _whiteEdged[url] = white;
    if (mounted && _url == url) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final background = widget.background;
    final image = _image;
    final url = _url;
    final white = url == null ? null : _whiteEdged[url];
    final veil = _veil;
    final painter = background == null || image == null || white == null || veil >= 1 || url != background.imageUrl
        ? null
        : _BackdropPainter(
            image: image,
            background: background,
            kind: accountBackdropKind(width: image.width, whiteEdged: white, repeat: background.repeat),
            whiteEdged: white,
            surface: widget.surface,
            veil: veil,
            marks: _marks,
          );
    return _MarksScope(
      marks: _marks,
      paintKey: _paintKey,
      child: DecoratedBox(
        decoration: painter == null ? widget.fallback : const BoxDecoration(),
        child: CustomPaint(
          key: _paintKey,
          painter: painter,
          // Ink of the controls paints above the background, not on the card's material under it.
          child: Material(type: MaterialType.transparency, child: widget.child),
        ),
      ),
    );
  }
}

/// Where the texts end and where the icon at the end of the row is, in the card.
final class _Marks extends ChangeNotifier {
  double? _textRight;
  Rect? _icon;

  double? get textRight => _textRight;

  Rect? get icon => _icon;

  void tell({required bool icon, required Rect rect}) {
    if (icon ? _icon == rect : _textRight == rect.right) {
      return;
    }
    if (icon) {
      _icon = rect;
    } else {
      _textRight = rect.right;
    }
    notifyListeners();
  }
}

class _MarksScope extends InheritedWidget {
  const _MarksScope({required this.marks, required this.paintKey, required super.child});

  final _Marks marks;

  final GlobalKey paintKey;

  static _MarksScope? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<_MarksScope>();

  @override
  bool updateShouldNotify(_MarksScope oldWidget) => marks != oldWidget.marks || paintKey != oldWidget.paintKey;
}

/// Tells the [AccountCardBackdrop] above where [child] is: the veil keeps the texts readable up to the right of a text
/// mark, and around an icon mark.
class AccountBackdropMark extends SingleChildRenderObjectWidget {
  /// The texts of the card, as wide as they are.
  const AccountBackdropMark.text({super.child, super.key}) : _icon = false;

  /// An icon of the card.
  const AccountBackdropMark.icon({super.child, super.key}) : _icon = true;

  final bool _icon;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMark(icon: _icon, scope: _MarksScope.maybeOf(context));

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) => (renderObject as _RenderMark)
    ..icon = _icon
    ..scope = _MarksScope.maybeOf(context);
}

class _RenderMark extends RenderProxyBox {
  _RenderMark({required this.icon, required this.scope});

  bool icon;

  _MarksScope? scope;

  bool _scheduled = false;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (_scheduled || scope == null) {
      return;
    }
    _scheduled = true;
    // Where it is in the card is known once the frame is laid out and painted.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final scope = this.scope;
      final card = scope?.paintKey.currentContext?.findRenderObject();
      if (!attached || scope == null || card is! RenderBox || !card.attached || !hasSize) {
        return;
      }
      scope.marks.tell(
        icon: icon,
        rect: localToGlobal(Offset.zero, ancestor: card) & size,
      );
    });
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.image,
    required this.background,
    required this.kind,
    required this.whiteEdged,
    required this.surface,
    required this.veil,
    required this.marks,
  }) : super(repaint: marks);

  final ui.Image image;
  final AccountBackground background;
  final AccountBackdropKind kind;
  final bool whiteEdged;
  final Color surface;
  final double veil;
  final _Marks marks;

  static double _x(PostBackgroundAlignX x) => switch (x) {
    PostBackgroundAlignX.left => -1,
    PostBackgroundAlignX.center => 0,
    PostBackgroundAlignX.right => 1,
  };

  static double _y(PostBackgroundAlignY y) => switch (y) {
    PostBackgroundAlignY.top => -1,
    PostBackgroundAlignY.center => 0,
    PostBackgroundAlignY.bottom => 1,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final source = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final alignX = background.alignX ?? PostBackgroundAlignX.center;
    final alignY = background.alignY ?? PostBackgroundAlignY.center;
    canvas
      ..save()
      ..clipRect(rect)
      ..drawRect(rect, Paint()..color = surface);
    switch (kind) {
      case AccountBackdropKind.cover:
        paintImage(
          canvas: canvas,
          rect: rect,
          image: image,
          fit: BoxFit.cover,
          alignment: Alignment(_x(alignX), _y(alignY)),
        );
      case AccountBackdropKind.tile:
        paintImage(
          canvas: canvas,
          rect: rect,
          image: image,
          // Its own size, as the web page draws it.
          fit: BoxFit.none,
          repeat: switch (background.repeat) {
            PostBackgroundRepeat.both || PostBackgroundRepeat.none => ImageRepeat.repeat,
            PostBackgroundRepeat.x => ImageRepeat.repeatX,
            PostBackgroundRepeat.y => ImageRepeat.repeatY,
          },
          alignment: Alignment(_x(alignX), _y(alignY)),
          colorFilter: whiteEdged ? postBackgroundBlend(surface) : null,
        );
      case AccountBackdropKind.blend:
        final target = accountBackdropSideRect(
          size,
          source.size,
          // At the right unless the member put it elsewhere.
          alignX: background.alignX ?? PostBackgroundAlignX.right,
          alignY: alignY,
        );
        canvas.drawImageRect(
          image,
          source,
          target,
          Paint()
            ..colorFilter = postBackgroundBlend(surface)
            ..filterQuality = FilterQuality.medium,
        );
      case AccountBackdropKind.side:
        final target = accountBackdropSideRect(size, source.size, alignX: PostBackgroundAlignX.right, alignY: alignY);
        canvas
          ..saveLayer(target, Paint())
          ..drawImageRect(image, source, target, Paint()..filterQuality = FilterQuality.medium)
          ..drawRect(
            target,
            Paint()
              ..blendMode = BlendMode.dstIn
              ..shader = ui.Gradient.linear(
                target.topLeft,
                Offset(target.left + target.width * _sideFade, target.top),
                [
                  const Color(0x00000000),
                  const Color(0xFF000000),
                ],
              ),
          )
          ..restore();
    }

    // The veil: full up to the end of the texts (all the card until told), fading out past them.
    final width = size.width;
    final textEnd = math.min(width, (marks.textRight ?? width) + 12);
    final fadeEnd = math.min(width, textEnd + width * _veilFade);
    final base = switch (kind) {
      AccountBackdropKind.cover || AccountBackdropKind.tile => _baseVeil,
      AccountBackdropKind.blend || AccountBackdropKind.side => 0.0,
    };
    final full = surface.withValues(alpha: veil);
    final end = surface.withValues(alpha: math.min(base, veil));
    canvas.drawRect(
      rect,
      Paint()
        ..shader = textEnd >= width
            ? null
            : ui.Gradient.linear(
                Offset.zero,
                Offset(width, 0),
                [full, full, end],
                [0, textEnd / width, math.min(1, math.max(fadeEnd, textEnd + 0.001) / width)],
              )
        ..color = full,
    );
    // And around the icon at the end of the row, wherever it is.
    if (marks.icon case final icon? when textEnd < width) {
      final inner = icon.longestSide / 2 + 2;
      final outer = inner + 8;
      canvas.drawCircle(
        icon.center,
        outer,
        Paint()
          ..shader = ui.Gradient.radial(
            icon.center,
            outer,
            [full, full, surface.withValues(alpha: 0)],
            [
              0,
              inner / outer,
              1,
            ],
          ),
      );
    }
    canvas.restore();
  }

  @override
  String toString() => '_BackdropPainter(${kind.name})';

  @override
  bool shouldRepaint(_BackdropPainter oldDelegate) =>
      !identical(image, oldDelegate.image) ||
      background != oldDelegate.background ||
      kind != oldDelegate.kind ||
      whiteEdged != oldDelegate.whiteEdged ||
      surface != oldDelegate.surface ||
      veil != oldDelegate.veil ||
      marks != oldDelegate.marks;
}
