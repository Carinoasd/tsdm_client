import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart';
import 'package:image/image.dart' as img;
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/thread/v1/repository/pdf_font_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/post_export.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_export_action.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_pdf_builder.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_pdf_content.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// The most bytes of images one PDF takes: the images after are drawn as placeholders, the PDF is built in memory.
const int _maxImageBytes = 256 * 1024 * 1024;

/// Widest an image is put in the PDF: a page is about 500 points wide.
const _maxImageWidth = 1600;

/// How long one image may take to load.
const _imageTimeout = Duration(seconds: 30);

/// Write [posts] of the thread [tid] as a PDF: saved where the user picks, or shared ([share]).
///
/// The font is downloaded the first time ([PdfFontRepository]), the images come from the image cache (downloaded
/// when they are not cached). How far it went is told in [progress], opened here when not given; cancelling it stops
/// the export.
Future<void> exportThreadPdf(
  BuildContext context, {
  required String title,
  required String tid,
  required List<Post> posts,
  required bool share,
  ExportProgressDialog? progress,
}) async {
  final tr = context.t.threadExport;
  final dialog = progress ?? (ExportProgressDialog()..open(context));
  final cancelToken = CancelToken();
  dialog.onCancel = cancelToken.cancel;
  final Uint8List bytes;
  try {
    final exportLabels = exportLabelsOf(context);
    final labels = ThreadPdfLabels(exportedAt: tr.exportedAt, attachment: tr.attachment, image: exportLabels.image);
    dialog.update(tr.building);
    final floors = await _floorsOf(posts, exportLabels);

    // The font.
    final File font;
    try {
      font = await PdfFontRepository().obtain(
        cancelToken: cancelToken,
        onProgress: (received, total) => dialog.update(
          tr.fontProgress(received: _megabytes(received), total: _megabytes(total)),
          value: total > 0 ? received / total : null,
        ),
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        return;
      }
      rethrow;
    } on Exception catch (e, st) {
      talker.handle(e, st, 'failed to obtain the font of the PDF export');
      dialog.close();
      if (context.mounted) {
        showSnackBar(context: context, message: tr.fontFailed);
      }
      return;
    }
    if (dialog.cancelled) {
      return;
    }

    // The images.
    final urls = {
      for (final f in floors)
        for (final b in f.blocks)
          if (b is PdfImageBlock) b.url,
    }.toList();
    final images = <String, Uint8List>{};
    var total = 0;
    for (var i = 0; i < urls.length && total < _maxImageBytes; i++) {
      dialog.update(
        tr.imageProgress(done: i + 1, total: urls.length),
        value: i / urls.length,
      );
      final data = await _imageOf(urls[i]);
      if (dialog.cancelled) {
        return;
      }
      if (data != null && total + data.length <= _maxImageBytes) {
        images[urls[i]] = data;
        total += data.length;
      }
    }

    // The document.
    dialog.update(tr.building);
    final job = ThreadPdfJob(
      title: title,
      url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
      exportedAt: DateTime.now(),
      floors: floors,
      labels: labels,
      font: await font.readAsBytes(),
      images: images,
    );
    // A cancellation can not stop the isolate: its result is not used then.
    bytes = await Isolate.run(() => buildThreadPdf(job));
    if (dialog.cancelled) {
      return;
    }
  } on Object catch (e, st) {
    talker.handle(e, st, 'failed to build the PDF of a thread');
    dialog.close();
    if (context.mounted) {
      showSnackBar(context: context, message: tr.failed);
    }
    return;
  } finally {
    dialog.close();
  }
  if (!context.mounted) {
    return;
  }
  await writeExportFile(
    context,
    bytes,
    fileName: threadExportFileName(title: title, tid: tid, format: PostExportFormat.plainText, extension: 'pdf'),
    mimeType: 'application/pdf',
    share: share,
  );
}

/// Floors under which the content is parsed on the UI isolate: starting an isolate costs more than it saves.
const _inlineFloors = 40;

/// [pdfFloorsOf] [posts], off the UI isolate when they are many.
Future<List<PdfFloor>> _floorsOf(List<Post> posts, PostExportLabels labels) async => posts.length < _inlineFloors
    ? pdfFloorsOf(posts, labels: labels)
    : Isolate.run(() => pdfFloorsOf(posts, labels: labels));

String _megabytes(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);

/// The image at [url] as the PDF can hold it, null when it could not be had.
Future<Uint8List?> _imageOf(String url) async {
  try {
    final cached = await getIt
        .get<ImageCacheProvider>()
        .getOrMakeCache(ImageCacheGeneralRequest(url))
        .timeout(_imageTimeout, onTimeout: () => const Option.none());
    final data = cached.toNullable();
    if (data == null || data.isEmpty) {
      return null;
    }
    return await compute(pdfImageBytes, data);
  } on Object catch (e, st) {
    talker.handle(e, st, 'failed to load an image of the PDF export');
    return null;
  }
}

/// [data] of an image as the PDF takes it: a JPEG as it is, any other image the image package reads as a PNG of its
/// first frame, no wider than [_maxImageWidth]; null when it is no image the package reads (AVIF).
@visibleForTesting
Uint8List? pdfImageBytes(Uint8List data) {
  if (img.JpegDecoder().isValidFile(data)) {
    return data;
  }
  final decoder = img.findDecoderForData(data);
  if (decoder == null) {
    return null;
  }
  final image = decoder.decode(data, frame: 0);
  if (image == null || image.width == 0 || image.height == 0) {
    return null;
  }
  final fitted = image.width > _maxImageWidth ? img.copyResize(image, width: _maxImageWidth) : image;
  return img.encodePng(fitted);
}
