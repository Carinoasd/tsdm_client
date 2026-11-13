/// Text the reply to the thread starts with when the thread page opens (the route's `extra`): put into the reply bar,
/// which opens on it, once the thread is loaded and can be replied to. Never sent by itself.
final class ThreadReplyPrefill {
  /// Constructor.
  const ThreadReplyPrefill(this.text);

  /// The text, plain (not BBCode).
  final String text;
}
