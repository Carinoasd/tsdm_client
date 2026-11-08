import 'package:flutter/foundation.dart';

/// One image of a custom emoji pack, kept in the app's documents as `<sha256>.<ext>` ([fileName]).
@immutable
final class CustomEmoji {
  /// Constructor.
  const CustomEmoji({required this.sha256, required this.ext});

  /// The image as saved in `packs.json`, null when it is not one.
  static CustomEmoji? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final sha = json['sha256'];
    final ext = json['ext'];
    if (sha is! String || !isSha256(sha) || ext is! String || !customEmojiExts.contains(ext)) {
      return null;
    }
    return CustomEmoji(sha256: sha, ext: ext);
  }

  /// SHA-256 of the saved bytes, lower case hex: who the image is (the same image is never kept twice in a pack, and
  /// an account uploads it once while the forum keeps the upload free to use).
  final String sha256;

  /// The extension of the saved file, one of [customEmojiExts].
  final String ext;

  /// The name of the saved file.
  String get fileName => '$sha256.$ext';

  /// As saved.
  Map<String, Object> toJson() => {'sha256': sha256, 'ext': ext};

  @override
  bool operator ==(Object other) => other is CustomEmoji && other.sha256 == sha256 && other.ext == ext;

  @override
  int get hashCode => Object.hash(sha256, ext);
}

/// A named custom emoji pack: its images in their order.
final class CustomEmojiPack {
  /// Constructor.
  const CustomEmojiPack({required this.id, required this.name, this.emojis = const []});

  /// The pack as saved, null when it is not one.
  static CustomEmojiPack? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final id = json['id'];
    final name = json['name'];
    final emojis = json['emojis'];
    if (id is! String || id.isEmpty || name is! String) {
      return null;
    }
    final list = <CustomEmoji>[];
    for (final e in emojis is List ? emojis : const []) {
      final emoji = CustomEmoji.fromJson(e);
      if (emoji != null && !list.any((x) => x.sha256 == emoji.sha256)) {
        list.add(emoji);
      }
    }
    return CustomEmojiPack(id: id, name: name, emojis: list);
  }

  /// Stays the same for the life of the pack.
  final String id;

  /// Shown as its tab.
  final String name;

  /// The images, in the order they are shown.
  final List<CustomEmoji> emojis;

  /// A copy with the given values.
  CustomEmojiPack copyWith({String? name, List<CustomEmoji>? emojis}) =>
      CustomEmojiPack(id: id, name: name ?? this.name, emojis: emojis ?? this.emojis);

  /// As saved.
  Map<String, Object> toJson() => {'id': id, 'name': name, 'emojis': emojis.map((e) => e.toJson()).toList()};
}

/// The extensions an image of a pack is saved with: what the forum's image upload takes (`*.jpg;*.jpeg;*.gif;*.png`).
const customEmojiExts = {'png', 'jpg', 'gif'};

final _sha256Re = RegExp(r'^[0-9a-f]{64}$');

/// Whether [value] is a lower case hex SHA-256.
bool isSha256(String value) => _sha256Re.hasMatch(value);
