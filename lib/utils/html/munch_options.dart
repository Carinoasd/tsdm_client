import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/foundation.dart';

part 'munch_options.mapper.dart';

/// All available options that controls and changes the behavior when munching
/// html document.
@MappableClass()
final class MunchOptions with MunchOptionsMappable {
  /// Constructor.
  const MunchOptions({this.renderUrl = true, this.onUrlLaunched});

  /// Render <a> tags and bare `http(s)://` urls in text as links when munching html document.
  ///
  /// Disable this flag will not render url highlight or any other url
  /// specified contents, only render as plain text, no url launching when tap,
  /// neither. Use it where the text is not a faithful copy of the page, e.g. the
  /// message summaries in the private message list, whose urls the server has
  /// already mangled (GitHub #46).
  ///
  /// Default is true.
  final bool renderUrl;

  /// Callback on url launched.
  ///
  /// Called when the user taps a url, right before it is dispatched: the page it opens may only pop much later, or
  /// never, and the caller (a notice card marking itself read) must not wait for that.
  final VoidCallback? onUrlLaunched;
}
