import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:universal_html/html.dart' as uh;

/// The forum's avatar page (`home.php?mod=spacecp&ac=avatar`) as the app reads it.
///
/// The page may offer two ways to change the avatar, each read only when printed: the external url of the forum's
/// own form (`input[name="headedit"]`), and the upload of the avatar editor of Discuz! X5 (`spacecp_avatar_body`),
/// whose script names the url the cropped images are posted to (`stl_src`: UCenter's `rectavatar`, signed for the
/// account and the user agent that opened the page).
final class AvatarEditPage {
  /// Constructor.
  const AvatarEditPage({
    required this.uid,
    this.externalUrl,
    this.formHash,
    this.uploadUrl,
    this.currentAvatar,
  });

  /// The account the page was served to, null for a guest.
  final int? uid;

  /// The external avatar url as set (empty when none), null when the page has no such form.
  final String? externalUrl;

  /// The form hash of the external avatar form.
  final String? formHash;

  /// The url the avatar editor posts the cropped images to, absolute; null when the page has no avatar editor.
  final String? uploadUrl;

  /// The avatar the forum shows now (the uploaded one, or the default), absolute; null when not found.
  final String? currentAvatar;

  /// Whether the page has the external avatar form.
  bool get hasExternal => externalUrl != null && (formHash?.isNotEmpty ?? false);

  /// Whether the page has the avatar editor.
  bool get hasUpload => uploadUrl != null;

  /// The avatar page [doc].
  // ignore: prefer_constructors_over_static_methods
  static AvatarEditPage parse(uh.Document doc) {
    final external = doc.querySelector('input[name="headedit"]');
    final headForm = external == null ? null : _formOf(external);
    final current = doc.querySelector('form#avatarform img._avt, form#avatarform img.user_avatar, form#avatarform img');
    return AvatarEditPage(
      uid: parseLoggedUidFromDocument(doc),
      externalUrl: external?.attributes['value'],
      formHash: headForm?.querySelector('input[name="formhash"]')?.attributes['value'],
      uploadUrl: _uploadUrl(doc),
      currentAvatar: _absolute(current?.attributes['data-src'] ?? current?.attributes['src']),
    );
  }

  static uh.Element? _formOf(uh.Element element) {
    uh.Element? e = element;
    while (e != null && e.localName != 'form') {
      e = e.parent;
    }
    return e;
  }

  /// The script of the avatar editor: `var data = "width,450,…,stl_src,<url>,…".split(',');`.
  static final _dataRe = RegExp(r'''var\s+data\s*=\s*"([^"]*)"\s*\.split\(\s*['"],['"]\s*\)''');

  static String? _uploadUrl(uh.Document doc) {
    if (doc.querySelector('#avatardesigner') == null) {
      return null;
    }
    for (final script in doc.querySelectorAll('script')) {
      final match = _dataRe.firstMatch(script.text ?? '');
      if (match == null) {
        continue;
      }
      final data = match.group(1)!.split(',');
      final index = data.indexOf('stl_src');
      if (index < 0 || index + 1 >= data.length) {
        return null;
      }
      final url = _absolute(data[index + 1]);
      final uri = url == null ? null : Uri.tryParse(url);
      if (uri == null || uri.queryParameters['a'] != 'rectavatar') {
        return null;
      }
      return url;
    }
    return null;
  }

  static String? _absolute(String? url) {
    if (url == null || url.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return null;
    }
    final resolved = Uri.parse('$baseUrl/').resolveUri(uri);
    return resolved.scheme == 'http' || resolved.scheme == 'https' ? resolved.toString() : null;
  }
}

/// What the forum answered the upload of the avatar editor.
enum AvatarUploadAnswer {
  /// Saved (`postMessage('success')`).
  success,

  /// Refused: an image too large or unreadable; the forum removed the avatar it had.
  failure,

  /// The upload's signature does not match the account or the browser (`<message value="-1">`): log in again.
  denied,

  /// An image was missing (`<message value="-2">`).
  incomplete,

  /// Anything else.
  unknown
  ;

  /// The answer [body].
  static AvatarUploadAnswer parse(String body) {
    if (body.contains("postMessage('success'")) {
      return success;
    }
    if (body.contains("postMessage('failure'")) {
      return failure;
    }
    final value = RegExp(r'''<message\s+type="error"\s+value="(-?\d+)"''').firstMatch(body)?.group(1);
    return switch (value) {
      '-1' => denied,
      '-2' => incomplete,
      _ => unknown,
    };
  }
}

/// The three images the avatar editor posts (`avatar1`, `avatar2`, `avatar3`): JPEG, at most 200×250, 120×120 and
/// 48×48, as UCenter takes them (it refuses larger ones, and then removes the avatar it had).
final class AvatarImages {
  /// Constructor.
  const AvatarImages(this.big, this.middle, this.small);

  /// The big image, at most 200×250.
  final Uint8List big;

  /// The middle image, at most 120×120.
  final Uint8List middle;

  /// The small image, 48×48.
  final Uint8List small;

  /// The largest size of each image (width, height) UCenter takes.
  static const limits = [(200, 250), (120, 120), (48, 48)];

  /// The fields the avatar editor posts: each image in base64.
  Map<String, String> toBody() => {
    'avatar1': _base64(big),
    'avatar2': _base64(middle),
    'avatar3': _base64(small),
  };

  static String _base64(Uint8List bytes) => base64.encode(bytes);

  /// The square [side] × [side] at ([left], [top]) of the image [source] (any format the `image` package reads),
  /// scaled down like the forum's editor: the big image to at most 200, the middle one to at most 120, the small one
  /// to 48; on white, JPEG. Null when [source] is not an image. Runs in another isolate.
  static Future<AvatarImages?> crop(Uint8List source, {required int left, required int top, required int side}) =>
      Isolate.run(() => _crop(source, left, top, side));

  static AvatarImages? _crop(Uint8List source, int left, int top, int side) {
    final img.Image? decoded;
    try {
      decoded = img.decodeImage(source);
    } on Object {
      // The decoders throw on some data that is not an image of theirs.
      return null;
    }
    if (decoded == null) {
      return null;
    }
    final image = img.bakeOrientation(decoded);
    final s = math.max(1, math.min(side, math.min(image.width, image.height)));
    final x = left.clamp(0, image.width - s);
    final y = top.clamp(0, image.height - s);
    final square = img.copyCrop(image, x: x, y: y, width: s, height: s);
    Uint8List encode(int size, {bool exact = false}) {
      final target = exact ? size : math.min(size, s);
      final scaled = img.copyResize(square, width: target, height: target, interpolation: img.Interpolation.average);
      final canvas = img.Image(width: target, height: target)..clear(img.ColorRgb8(255, 255, 255));
      img.compositeImage(canvas, scaled);
      return img.encodeJpg(canvas, quality: 92);
    }

    return AvatarImages(encode(200), encode(120), encode(48, exact: true));
  }
}
