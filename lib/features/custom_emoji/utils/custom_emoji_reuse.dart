/// How a custom emoji goes into a post as an attachment, [decideCustomEmojiAttachment].
sealed class CustomEmojiAttachment {
  const CustomEmojiAttachment();
}

/// Already an attachment of this post: one uploaded or reused while editing it, or one the edited post has
/// (`attach.used`). Only its code is inserted again.
final class CustomEmojiInPost extends CustomEmojiAttachment {
  /// Constructor.
  const CustomEmojiInPost(this.aid);

  /// The attachment.
  final int aid;
}

/// An upload of this account the forum still keeps unused (`attach.unused` of the form): inserted and bound to the post
/// when it is published, as a new upload is.
final class CustomEmojiUnused extends CustomEmojiAttachment {
  /// Constructor.
  const CustomEmojiUnused(this.aid);

  /// The attachment.
  final int aid;
}

/// Upload it again: never uploaded by this account, or its upload is no longer free to use (bound to another post,
/// deleted by the forum a day after it went unused).
final class CustomEmojiUpload extends CustomEmojiAttachment {
  /// Constructor.
  const CustomEmojiUpload({required this.forget});

  /// Whether the remembered upload is stale and is to be forgotten.
  final bool forget;
}

/// How the image [sha256] goes into the post being edited.
///
/// [inPost] are the images already attachments of this post (by SHA-256: uploaded or reused while editing it),
/// [remembered] the upload this account made of the image before (null when none), [unused] the account's unused
/// uploads the form lists and [used] the attachments of the edited post.
///
/// An attachment bound to another post is never reused: the forum shows an attachment only in its own post, and binding
/// it again (`attachnew`) moves it out of the post it was in.
CustomEmojiAttachment decideCustomEmojiAttachment({
  required String sha256,
  required Map<String, int> inPost,
  required int? remembered,
  required Set<int> unused,
  required Set<int> used,
}) {
  if (inPost[sha256] case final aid?) {
    return CustomEmojiInPost(aid);
  }
  if (remembered == null) {
    return const CustomEmojiUpload(forget: false);
  }
  if (used.contains(remembered)) {
    return CustomEmojiInPost(remembered);
  }
  if (unused.contains(remembered)) {
    return CustomEmojiUnused(remembered);
  }
  return const CustomEmojiUpload(forget: true);
}
