import 'package:tsdm_client/features/editor/utils/mention.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/utils/discuz_text.dart';

/// The forum's size limits of a post's message, as the post form of its app API tells them (plugin 2.9.0, `message`
/// with `unit: bytes`): UTF-8 bytes of the message as sent (the mentions in the forum's format), the minimum without
/// the quoted parts when [minExcludesQuote] (`checkpost()`); a null bound is not checked.
///
/// A reply is counted without the quote of the floor it replies to: the forum puts that quote (`noticetrimstr`) in
/// front of the message only after checking its size.
final class MessageLimits {
  /// Constructor.
  const MessageLimits({this.min, this.max, this.minExcludesQuote = true});

  /// The limits of [form], null when it checks none.
  static MessageLimits? of(PostForm form) {
    final min = form.messageMin;
    final max = form.messageMax;
    if (min == null && max == null) {
      return null;
    }
    return MessageLimits(min: min, max: max, minExcludesQuote: form.messageMinExcludesQuote);
  }

  /// The smallest size, null when not checked.
  final int? min;

  /// The largest size, null when not checked.
  final int? max;

  /// Whether quotes do not count for [min].
  final bool minExcludesQuote;

  /// The size of [message] as the forum counts it against [max].
  int bytesOf(String message) => discuzMessageBytes(toOfficialMentions(message));

  /// Whether [message] is below [min].
  bool tooShort(String message) {
    final min = this.min;
    if (min == null) {
      return false;
    }
    final sent = toOfficialMentions(message);
    return minExcludesQuote ? discuzMessageTooShort(sent, min) : discuzMessageBytes(sent) < min;
  }

  /// Whether [message] is above [max].
  bool tooLong(String message) {
    final max = this.max;
    return max != null && bytesOf(message) > max;
  }

  @override
  String toString() => 'MessageLimits(min: $min, max: $max, minExcludesQuote: $minExcludesQuote)';
}
