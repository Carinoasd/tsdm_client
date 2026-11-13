part of 'emoji_bloc.dart';

/// Status of emoji bloc.
enum EmojiStatus {
  /// Initial
  initial,

  /// Loading
  loading,

  /// Succeed
  success,

  /// Failed
  failure,
}

/// How far the images of a group are downloaded.
@MappableClass()
final class EmojiGroupProgress with EmojiGroupProgressMappable {
  /// Constructor.
  const EmojiGroupProgress({required this.status, required this.done, required this.total});

  /// [EmojiStatus.loading] while downloading, [EmojiStatus.failure] when some are still missing after it.
  final EmojiStatus status;

  /// How many images of the group are there.
  final int done;

  /// How many images the group has.
  final int total;
}

/// State of emoji bloc.
@MappableClass()
final class EmojiState with EmojiStateMappable {
  /// Constructor.
  const EmojiState({required this.status, this.emojiGroupList, this.groupProgress = const {}});

  /// Status
  final EmojiStatus status;

  /// All emoji group.
  final List<EmojiGroup>? emojiGroupList;

  /// The downloads of the groups shown, by group id.
  final Map<String, EmojiGroupProgress> groupProgress;
}
