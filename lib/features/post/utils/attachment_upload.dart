import 'dart:convert';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';

/// The answer of the forum's upload script (`misc.php?mod=swfupload`), `DISCUZUPLOAD|uid|error|aid|isimage|path|…`,
/// read as the website's uploader reads it: the `aid` of the attachment when `error` is 0, else the error
/// ([AttachmentUploadFailedException] with that code; without a code when [data] is no such answer).
SyncEither<int> parseAttachmentUploadAnswer(Object? data) {
  final text = switch (data) {
    final String s => s,
    final List<int> bytes => utf8.decode(bytes, allowMalformed: true),
    _ => '',
  };
  final parts = text.trim().split('|');
  if (parts.length < 4 || parts[0] != 'DISCUZUPLOAD') {
    return left(AttachmentUploadFailedException());
  }
  final code = int.tryParse(parts[2]);
  final aid = int.tryParse(parts[3]);
  if (code == null || code != 0) {
    return left(AttachmentUploadFailedException(code: code));
  }
  if (aid == null || aid <= 0) {
    return left(AttachmentUploadFailedException());
  }
  return right(aid);
}

/// The media type of an image file named [filename], by its extension; `application/octet-stream` for an unknown one.
String imageContentTypeOf(String filename) {
  final dot = filename.lastIndexOf('.');
  final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'heic' => 'image/heic',
    'avif' => 'image/avif',
    _ => 'application/octet-stream',
  };
}

/// The BBCode that shows the attachment [aid] in the post, as the website's image list inserts it.
String attachmentImageBBCode(int aid) => '[attachimg]$aid[/attachimg]';
