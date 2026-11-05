import 'dart:io';

import 'package:tsdm_client/instance.dart';

/// What another app shared to this one, as the Android side hands it over on the `shareReceive` channel: the subject
/// and the text of a text share (a link, a title with its link, a note), the files of an image share.
///
/// The images are copies in this app's cache (Dart cannot read a `content://` uri): whoever takes them deletes them,
/// see [discardSharedFiles].
final class SharedContent {
  /// Constructor.
  const SharedContent({this.subject, this.text, this.imagePaths = const []});

  /// The content of a channel message: a map with `subject`, `text` (strings or null) and `images` (a list of paths).
  /// Null when it carries nothing to take.
  static SharedContent? fromChannel(Object? arguments) {
    if (arguments is! Map) {
      return null;
    }
    final subject = arguments['subject'];
    final text = arguments['text'];
    final images = arguments['images'];
    final content = SharedContent(
      subject: subject is String && subject.trim().isNotEmpty ? subject.trim() : null,
      text: text is String && text.trim().isNotEmpty ? text.trim() : null,
      imagePaths: images is List ? images.whereType<String>().where((e) => e.isNotEmpty).toList() : const [],
    );
    return content.isEmpty ? null : content;
  }

  /// `Intent.EXTRA_SUBJECT`: the title of the page a browser shares, when it gives one.
  final String? subject;

  /// `Intent.EXTRA_TEXT`, trimmed.
  final String? text;

  /// Paths of the shared images in this app's cache, in the order they were shared.
  final List<String> imagePaths;

  /// Nothing to take: no text and no image.
  bool get isEmpty => text == null && imagePaths.isEmpty;
}

/// Delete the shared image files at [paths] (copies in this app's cache) once nothing will use them any more.
///
/// Synchronous: a few small files of the cache, and the callers run under the widget tree.
void discardSharedFiles(Iterable<String> paths) {
  for (final path in paths) {
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on Object catch (e) {
      talker.warning('shared file not deleted: $e');
    }
  }
}
