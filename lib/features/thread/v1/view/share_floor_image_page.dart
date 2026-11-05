import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/image/utils/image_actions.dart';
import 'package:tsdm_client/features/image/widgets/post_image.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode_view.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/post_image_auto_load.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/card/post_card/floor_label.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// How wide the floor is rendered, in logical pixels: the same picture on every screen.
const shareFloorImageWidth = 420.0;

/// Pixels per logical pixel of the picture: 840 wide, a little less when the canvas is too tall for it
/// ([shareFloorImagePixelRatioFor]).
const shareFloorImagePixelRatio = 2.0;

/// The picture is never taller than this many pixels: a texture may be 8192 at most on the GPUs of older phones, and a
/// floor of hundreds of pictures would not fit the memory of a phone as one picture. The content is cut at
/// [shareFloorImageMaxHeight] for it; the pixel ratio is lowered as well when the title and the header above the
/// content would still take the whole past it ([shareFloorImagePixelRatioFor]).
const shareFloorImageMaxPixels = 8000.0;

/// The content is cut after this many logical pixels: 7600 pixels at [shareFloorImagePixelRatio], the title, header and
/// footer around it fit [shareFloorImageMaxPixels] at that ratio on the usual text scale.
const shareFloorImageMaxHeight = 3800.0;

/// Pixels per logical pixel for a picture of [canvas]: [shareFloorImagePixelRatio], less when the picture would be
/// taller than [shareFloorImageMaxPixels] at it (a long title at a large text scale).
double shareFloorImagePixelRatioFor(Size canvas) =>
    math.min(shareFloorImagePixelRatio, shareFloorImageMaxPixels / math.max(canvas.height, 1));

/// The buttons are offered after this long even when a picture of the floor still loads (a host that never answers
/// would keep them off for good).
const shareFloorImageLoadTimeout = Duration(seconds: 20);

/// Key of the surface the picture is rendered from, for tests: the [RepaintBoundary] above it is what is captured.
const ValueKey<String> shareFloorImageCanvasKey = ValueKey('share-floor-image-canvas');

/// Key of the mark at the bottom of a floor cut at [shareFloorImageMaxHeight].
const ValueKey<String> shareFloorImageTruncatedKey = ValueKey('share-floor-image-truncated');

/// What the share page renders: the floor, the title of its thread (none on the notice page) and the link printed at
/// the bottom ([shareFloorImageLink]).
final class ShareFloorImageArgs {
  /// Constructor.
  const ShareFloorImageArgs({required this.post, this.threadTitle, this.link});

  /// The floor.
  final Post post;

  /// Title of the thread, null when it is not known where the floor is shown.
  final String? threadTitle;

  /// The link printed under the floor, null when the floor has none.
  final String? link;
}

/// The link printed under the floor: the forum's `findpost` link of the thread [tid] and the floor [pid]. Without
/// [tid], the floor's own share link ([Post.shareLink]) with the `fromuid` of the account that read the page taken
/// out: the picture tells nothing about who made it.
String? shareFloorImageLink({required String pid, String? tid, String? shareLink}) {
  if (tid != null && tid.isNotEmpty) {
    return '$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=$tid&pid=$pid';
  }
  if (shareLink == null) {
    return null;
  }
  final uri = Uri.tryParse(shareLink);
  if (uri == null || !uri.queryParameters.containsKey('fromuid')) {
    return shareLink;
  }
  final query = Map.of(uri.queryParameters)..remove('fromuid');
  return uri.replace(queryParameters: query.isEmpty ? null : query).toString();
}

/// Draw the floor on the surface above [boundary] into a PNG, [pixelRatio] pixels per logical pixel
/// ([shareFloorImagePixelRatio]).
///
/// Throws (an [Exception]) when the picture can not be drawn or encoded.
Future<Uint8List> renderShareFloorImage(
  RenderRepaintBoundary boundary, {
  double pixelRatio = shareFloorImagePixelRatio,
}) async {
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw const FormatException('the floor could not be encoded');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

/// One floor as a picture to save or share: the title of its thread, the author with the floor number and the time,
/// the content as the thread shows it (its tables, pictures and folds as they are, folds closed) and the forum's name
/// with the link to the floor at the bottom, [shareFloorImageWidth] wide on every screen and in the colors of the
/// theme in use.
///
/// The page scrolls the whole picture; saving and sharing wait until every picture of the floor is decoded (or failed,
/// or [shareFloorImageLoadTimeout] passed): a picture captured before would show its placeholder. Content taller than
/// [shareFloorImageMaxHeight] is cut there and fades out with a mark.
class ShareFloorImagePage extends StatefulWidget {
  /// Constructor.
  const ShareFloorImagePage(this.args, {super.key});

  /// What to render.
  final ShareFloorImageArgs args;

  @override
  State<ShareFloorImagePage> createState() => _ShareFloorImagePageState();
}

class _ShareFloorImagePageState extends State<ShareFloorImagePage> with LoggerMixin {
  /// The boundary captured.
  final GlobalKey _canvas = GlobalKey(debugLabel: 'share floor image canvas');

  /// The content with its padding, as the cut applies to it, measured for [_truncated].
  final GlobalKey _content = GlobalKey(debugLabel: 'share floor image content');

  /// The pictures of the floor still loading.
  final _loads = PostImageLoads();

  late final _floorImages = FloorImages(widget.args.post.attachments);

  Timer? _timeout;

  /// Every picture is there, or waiting is over: the buttons act.
  bool _ready = false;

  /// Saving or sharing now.
  bool _busy = false;

  /// The content is taller than [shareFloorImageMaxHeight].
  bool _truncated = false;

  Post get _post => widget.args.post;

  @override
  void initState() {
    super.initState();
    _loads.addListener(_onLoads);
    WidgetsBinding.instance.addPostFrameCallback(_afterFrame);
    _timeout = Timer(shareFloorImageLoadTimeout, () {
      if (mounted && !_ready) {
        debug('share floor image: ${_loads.pending} pictures still loading, offering the buttons');
        setState(() => _ready = true);
      }
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _loads
      ..removeListener(_onLoads)
      ..dispose();
    super.dispose();
  }

  /// A picture settled: it is laid out at its size in the next frame (told before the frame that shows it), measured
  /// after that frame.
  void _onLoads() {
    if (mounted) {
      WidgetsBinding.instance
        ..addPostFrameCallback(_afterFrame)
        ..ensureVisualUpdate();
    }
  }

  /// After a frame: whether the content was cut, and whether every picture built in it is settled.
  void _afterFrame(Duration _) {
    if (!mounted) {
      return;
    }
    final content = _content.currentContext?.findRenderObject();
    final box = content is RenderBox && content.hasSize ? content : null;
    final truncated = box != null && box.size.height > shareFloorImageMaxHeight;
    if (truncated != _truncated) {
      setState(() => _truncated = truncated);
    }
    if (_ready) {
      return;
    }
    if (truncated) {
      _releaseBelowCut(box);
    }
    if (_loads.allSettled) {
      setState(() => _ready = true);
    }
  }

  /// The pictures laid out under the cut are not in the picture: not waited for (they still load, the content is laid
  /// out whole).
  void _releaseBelowCut(RenderBox content) {
    void visit(Element element) {
      if (element.widget case final PostImage image) {
        final box = element.renderObject;
        if (box is RenderBox && box.hasSize && box.attached) {
          final top = box.localToGlobal(Offset.zero, ancestor: content).dy;
          if (top >= shareFloorImageMaxHeight) {
            _loads.settle(image.image.floorUrl);
          }
        }
        return;
      }
      element.visitChildElements(visit);
    }

    _content.currentContext?.visitChildElements(visit);
  }

  Future<Uint8List?> _render() async {
    final boundary = _canvas.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      return null;
    }
    // Anything thrown while drawing or encoding (a texture too large for the GPU still, an encoder error) is told, not
    // left unhandled: tried once more at the logical size before giving up.
    final first = shareFloorImagePixelRatioFor(boundary.size);
    for (final pixelRatio in {first, math.min<double>(1, first)}) {
      try {
        return await renderShareFloorImage(boundary, pixelRatio: pixelRatio);
      } on Object catch (e, st) {
        handleRaw(e, st);
      }
    }
    return null;
  }

  String get _fileName => 'tsdm-floor-${_post.postID}.png';

  /// Render, then [action] on the picture; [failed] is told when it could not be rendered.
  Future<void> _run(Future<void> Function(Uint8List data) action, {required String Function() failed}) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final data = await _render();
      if (data == null) {
        if (mounted) {
          showSnackBar(context: context, message: failed());
        }
        return;
      }
      if (mounted) {
        await action(data);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _save() => _run(
    (data) => saveImageBytes(context, data, fileName: _fileName),
    failed: () => context.t.imageBottomSheet.failedToSaveImage,
  );

  Future<void> _share(BuildContext buttonContext) {
    // Where the sheet points from, taken while the button is surely there.
    final origin = shareOriginOf(buttonContext);
    return _run(
      (data) => shareImageBytes(context, data, fileName: _fileName, origin: origin),
      failed: () => context.t.imageBottomSheet.failedToShareImage,
    );
  }

  Widget _buildAvatar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final url = _post.author.avatarUrl;
    Widget fallback(IconData icon) => DecoratedBox(
      decoration: BoxDecoration(color: colorScheme.surfaceContainerHighest, shape: BoxShape.circle),
      child: Center(child: Icon(icon, color: colorScheme.outline)),
    );
    final Widget avatar;
    if (_post.avatarBlocked || url == null || url.isEmpty) {
      avatar = fallback(_post.avatarBlocked ? Icons.no_accounts_outlined : Icons.person_outline);
    } else {
      // Waited for like the pictures of the content.
      _loads.expect(url);
      avatar = ClipOval(
        child: CachedImage(
          url,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          enableAnimation: false,
          placeholderBuilder: (context, _) => fallback(Icons.person_outline),
          errorBuilder: (context, _, _) {
            _loads.settle(url);
            return fallback(Icons.person_outline);
          },
          onImageSize: (_, {required downscaled}) => _loads.settle(url),
        ),
      );
    }
    return SizedBox(width: 40, height: 40, child: avatar);
  }

  Widget _buildHeader(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final publishTime = _post.publishTime;
    final floor = postFloorLabel(context.t, floor: _post.postFloor, hot: _post.hot, hotFloor: _post.hotFloor);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.args.threadTitle case final title? when title.isNotEmpty) ...[
            Text(title, style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            sizedBoxW12H12,
          ],
          Row(
            children: [
              _buildAvatar(context),
              sizedBoxW12H12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _post.author.name,
                      style: textTheme.titleSmall?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (publishTime != null) ...[
                      sizedBoxW2H2,
                      Text(
                        publishTime.yyyyMMDDHHMMSS(),
                        style: textTheme.labelSmall?.copyWith(color: colorScheme.outline),
                      ),
                    ],
                  ],
                ),
              ),
              sizedBoxW8H8,
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Text(
                    floor,
                    style: textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final appRenderer = context.read<SettingsBloc>().state.settingsMap.enableAppPostRenderer;
    final typography = context.read<SettingsBloc>().state.settingsMap.postTypography.withLineWidth(
      postContentLineWidth(context),
    );
    final content = Padding(
      key: _content,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: PostTypographyScope(
        typography: typography,
        child: PostImageScope(
          images: _floorImages,
          // Every picture, whatever the data saver says: the picture is what is shared.
          autoLoad: PostImageAutoLoad.always,
          loads: _loads,
          child: _post.isSpoofed
              ? Text(context.t.postCard.contentUnavailable, style: TextStyle(color: colorScheme.outline))
              : appRenderer
              ? PostBbcodeBody(_post)
              : MunchedHtml(_post.data),
        ),
      ),
    );
    return Stack(
      children: [
        // Cut at the limit: the content is laid out whole, only its top is shown.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: shareFloorImageMaxHeight),
          child: SingleChildScrollView(physics: const NeverScrollableScrollPhysics(), child: content),
        ),
        if (_truncated)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              key: shareFloorImageTruncatedKey,
              height: 96,
              alignment: Alignment.bottomCenter,
              padding: const EdgeInsets.only(bottom: 4),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [colorScheme.surface.withValues(alpha: 0), colorScheme.surface],
                ),
              ),
              child: Text('……', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: colorScheme.outline)),
            ),
          ),
      ],
    );
  }

  Widget _buildFooter(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(height: 1, color: colorScheme.outlineVariant),
          sizedBoxW12H12,
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: context.t.shareFloorImage.siteName,
                  style: textTheme.labelMedium?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold),
                ),
                if (widget.args.link case final link?) ...[
                  TextSpan(
                    text: ' · ',
                    style: textTheme.labelMedium?.copyWith(color: colorScheme.outline),
                  ),
                  TextSpan(
                    text: link,
                    style: textTheme.labelSmall?.copyWith(color: colorScheme.outline),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    // Everything inside lays out for a screen as wide as the picture (line widths, tables, decoded sizes), on every
    // screen; nothing inside takes a tap.
    return IgnorePointer(
      child: MediaQuery(
        data: media.copyWith(
          size: Size(shareFloorImageWidth, media.size.height),
          padding: EdgeInsets.zero,
          viewPadding: EdgeInsets.zero,
          viewInsets: EdgeInsets.zero,
        ),
        child: RepaintBoundary(
          key: _canvas,
          child: SizedBox(
            key: shareFloorImageCanvasKey,
            width: shareFloorImageWidth,
            child: ColoredBox(
              color: colorScheme.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [_buildHeader(context), _buildBody(context), _buildFooter(context)],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildButtons(BuildContext context) {
    final tr = context.t.shareFloorImage;
    final enabled = _ready && !_busy;
    const waiting = SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));
    Widget icon(IconData data) => _ready ? Icon(data) : waiting;
    final share = canShareImageFiles;
    final save = share
        ? OutlinedButton.icon(
            key: const ValueKey('share-floor-image-save'),
            onPressed: enabled ? _save : null,
            icon: icon(Icons.save_alt_outlined),
            label: Text(tr.save),
          )
        : FilledButton.icon(
            key: const ValueKey('share-floor-image-save'),
            onPressed: enabled ? _save : null,
            icon: icon(Icons.save_alt_outlined),
            label: Text(tr.save),
          );
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          children: [
            Expanded(child: save),
            if (share) ...[
              sizedBoxW12H12,
              Expanded(
                child: Builder(
                  builder: (context) => FilledButton.icon(
                    key: const ValueKey('share-floor-image-share'),
                    onPressed: enabled ? () async => _share(context) : null,
                    icon: icon(Icons.share_outlined),
                    label: Text(tr.share),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.t.shareFloorImage.title)),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Center(
                // Scaled down to fit a screen narrower than the picture; captured at its own size regardless.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topCenter,
                  child: Material(
                    color: Theme.of(context).colorScheme.surface,
                    elevation: 1,
                    borderRadius: BorderRadius.circular(appInnerRadius),
                    clipBehavior: Clip.antiAlias,
                    child: _buildCanvas(context),
                  ),
                ),
              ),
            ),
          ),
          _buildButtons(context),
        ],
      ),
    );
  }
}
