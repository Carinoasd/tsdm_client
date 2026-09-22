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
}
