part of 'models.dart';

/// Notice using apis
@MappableClass(ignoreNull: true)
final class NoticeV2 with NoticeV2Mappable {
  /// Constructor.
  const NoticeV2({
    required this.id,
    required this.timestamp,
    required this.data,
    this.alreadyRead = false,
    this.ignoreType,
    this.authorId,
    this.author,
    this.fromId,
    this.fromIdType,
  });

  /// Notice id.
  final int id;

  /// Timestamp in seconds.
  final int timestamp;

  /// Notice data in html format.
  @MappableField(key: 'html')
  final String data;

  /// Messages read or not.
  final bool alreadyRead;

  /// Notice type from the notice's own ignore link, null when unknown (never guessed).
  final String? ignoreType;

  /// Uid of the user who triggered the notice, from the notice's own ignore link, null when unknown (never guessed).
  final int? authorId;

  /// Name of the user who triggered the notice: the `author` of the forum's app API (`notify`), or on the notice page
  /// the name of the link to that user's space in the body ([authorId] of that link). Null when unknown.
  final String? author;

  /// The `from_id` of the forum's app API: what the notice is about, a thread id for most of the post notices (the
  /// post id for a quote). Null on the notice page, which does not print it.
  @MappableField(key: 'from_id')
  final int? fromId;

  /// The `from_idtype` of the forum's app API: the kind of [fromId] and the finer kind of the notice (`post`, `quote`,
  /// `at`, `moderate_*`, `friendrequest`...). Null on the notice page, which does not print it.
  @MappableField(key: 'from_idtype')
  final String? fromIdType;
}
