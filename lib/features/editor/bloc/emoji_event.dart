part of 'emoji_bloc.dart';

/// Basic emoji related events.
@MappableClass()
sealed class EmojiEvent with EmojiEventMappable {}

/// Load the emoji groups: the list saved on this device, else the forum's.
@MappableClass()
final class EmojiFetchFromCacheEvent extends EmojiEvent with EmojiFetchFromCacheEventMappable {}

/// Download the images of the group [groupId] not downloaded yet: when the group is shown, or again after a failure.
@MappableClass()
final class EmojiFetchGroupEvent extends EmojiEvent with EmojiFetchGroupEventMappable {
  /// Constructor.
  EmojiFetchGroupEvent(this.groupId);

  /// Id of the group.
  final String groupId;
}
