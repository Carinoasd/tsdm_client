part of 'models.dart';

/// All emoji group save in cache.
///
/// Wrapper class to save to/from json with cache.
@MappableClass()
class EmojiGroupList with EmojiGroupListMappable, LoggerMixin {
  /// Constructor.
  const EmojiGroupList(this.emojiGroupList);

  /// All emoji groups
  final List<EmojiGroup> emojiGroupList;

  /// Validate the emoji cache in [rootDir].
  ///
  /// Return true when all emoji cache file exists.
  bool validateCache(String rootDir) {
    for (final emojiGroup in emojiGroupList) {
      for (final emoji in emojiGroup.emojiList) {
        // Ids form file names; never let one escape the cache directory.
        if (!isSafeEmojiId(emojiGroup.id) || !isSafeEmojiId(emoji.id)) {
          error('invalid emoji id in cache info (${emojiGroup.id.length}/${emoji.id.length} chars)');
          return false;
        }
        final cachePath = '$rootDir/${emojiGroup.id}_${emoji.id}.jpg';
        if (!File(cachePath).existsSync()) {
          error('invalid emoji at $cachePath');
          return false;
        }
      }
    }
    return true;
  }
}
