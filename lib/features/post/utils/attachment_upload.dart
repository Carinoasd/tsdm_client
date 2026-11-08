import 'dart:convert';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';

/// The answer of the forum's upload script (`misc.php?mod=swfupload`), read as the website's uploaders read it: the
/// `aid` of the attachment, else the error ([AttachmentUploadFailedException] with that code; without a code when
/// [data] is no such answer).
///
/// The url of the form's upload (no `simple`) answers the bare number: the `aid`, or the error negated (`-1` for a
/// type the forum does not take). With `simple=2` (the website's touch uploader) it is
/// `DISCUZUPLOAD|type|error|aid|isimage|path|…`, the `aid` when `error` is 0.
SyncEither<int> parseAttachmentUploadAnswer(Object? data) {
  final text = switch (data) {
    final String s => s,
    final List<int> bytes => utf8.decode(bytes, allowMalformed: true),
    _ => '',
  };
  final number = int.tryParse(text.trim());
  if (number != null) {
    return number > 0
        ? right(number)
        : left(
            number < 0
                ? AttachmentUploadFailedException(AttachmentUploadRefusal.refused, code: -number)
                : AttachmentUploadFailedException(AttachmentUploadRefusal.unavailable),
          );
  }
  final parts = text.trim().split('|');
  if (parts.length < 4 || parts[0] != 'DISCUZUPLOAD') {
    return left(AttachmentUploadFailedException(AttachmentUploadRefusal.unavailable));
  }
  final code = int.tryParse(parts[2]);
  final aid = int.tryParse(parts[3]);
  if (code == null || code != 0) {
    return left(AttachmentUploadFailedException(AttachmentUploadRefusal.refused, code: code));
  }
  if (aid == null || aid <= 0) {
    return left(AttachmentUploadFailedException(AttachmentUploadRefusal.unavailable));
  }
  return right(aid);
}

/// The attachments of [aids] the post [message] still shows ([attachmentImageBBCode]): only these are bound to the
/// post when it is published. One whose code the member deleted from the post (or that a restored draft replaced) is
/// left to the forum as an unused upload, which it lists in the member's attachments and cleans up on its own.
List<int> attachmentsInMessage(String message, Iterable<int> aids) =>
    aids.where((aid) => message.contains(attachmentImageBBCode(aid))).toList();

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
