import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/image/utils/image_actions.dart';
import 'package:tsdm_client/features/thread/v1/view/share_floor_image_page.dart' show renderShareFloorImage;
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// The page of the thread [tid] on the forum.
String shareQrThreadUrl(String tid) => '$baseUrl/forum.php?mod=viewthread&tid=$tid';

/// The page of the forum [fid] on the forum.
String shareQrForumUrl(String fid) => '$baseUrl/forum.php?mod=forumdisplay&fid=$fid';

/// The profile page of the user [uid] on the forum.
String shareQrProfileUrl(String uid) => '$uidProfilePage$uid';

/// Side of the code, in logical pixels.
const double shareQrSize = 220;

/// Pixels per logical pixel of the saved picture.
const double shareQrPixelRatio = 3;

/// Show the QR code of [url] under [title], to save or share as a picture.
///
/// [fileName] is the name of the picture without the extension.
Future<void> showShareQrDialog(
  BuildContext context, {
  required String url,
  required String title,
  String fileName = 'tsdm-qr',
}) => showDialog<void>(
  context: context,
  builder: (_) => ShareQrDialog(url: url, title: title, fileName: fileName),
);

/// Dialog with the QR code of a forum page.
class ShareQrDialog extends StatefulWidget {
  /// Constructor.
  const ShareQrDialog({required this.url, required this.title, this.fileName = 'tsdm-qr', super.key});

  /// What the code holds.
  final String url;

  /// Shown under the code, and in the picture.
  final String title;

  /// Name of the saved picture, without the extension.
  final String fileName;

  @override
  State<ShareQrDialog> createState() => _ShareQrDialogState();
}

class _ShareQrDialogState extends State<ShareQrDialog> {
  final GlobalKey _boundary = GlobalKey();
  bool _busy = false;

  String get _fileName => '${widget.fileName}.png';

  Future<Uint8List?> _render() async {
    final boundary = _boundary.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      return null;
    }
    try {
      return await renderShareFloorImage(boundary, pixelRatio: shareQrPixelRatio);
    } on Object catch (e, st) {
      talker.handle(e, st, 'failed to render the qr code');
      return null;
    }
  }

  Future<void> _run(Future<void> Function(Uint8List data) action, {required String failed}) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final data = await _render();
      if (data == null) {
        if (mounted) {
          showSnackBar(context: context, message: failed);
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

  @override
  Widget build(BuildContext context) {
    final tr = context.t.shareQr;
    final share = canShareImageFiles;
    final saveFailed = context.t.imageBottomSheet.failedToSaveImage;
    final shareFailed = context.t.imageBottomSheet.failedToShareImage;
    return AlertDialog(
      content: SingleChildScrollView(
        child: Center(
          // The picture is the same in the light and the dark theme: dark modules on white, which scanners need.
          child: RepaintBoundary(
            key: _boundary,
            child: Container(
              key: const ValueKey('share-qr-card'),
              width: shareQrSize + 32,
              padding: const EdgeInsets.all(16),
              color: Colors.white,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  QrImageView(
                    key: const ValueKey('share-qr-code'),
                    data: widget.url,
                    size: shareQrSize,
                    backgroundColor: Colors.white,
                    // The package's own eye and module styles are square and black. Styles built here with only a color
                    // leave the shape out, which the painter draws round: decoders that look for square patterns (OpenCV)
                    // do not find those.
                  ),
                  sizedBoxW12H12,
                  Text(
                    widget.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.black, fontSize: 14),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('share-qr-save'),
          onPressed: _busy
              ? null
              : () async => _run((data) => saveImageBytes(context, data, fileName: _fileName), failed: saveFailed),
          child: Text(tr.save),
        ),
        if (share)
          Builder(
            builder: (buttonContext) => TextButton(
              key: const ValueKey('share-qr-share'),
              onPressed: _busy
                  ? null
                  : () async {
                      final origin = shareOriginOf(buttonContext);
                      await _run(
                        (data) => shareImageBytes(context, data, fileName: _fileName, origin: origin),
                        failed: shareFailed,
                      );
                    },
              child: Text(tr.share),
            ),
          ),
      ],
    );
  }
}
