import 'package:flutter/foundation.dart';

/// A block of the homepage of an account that can be hidden and moved.
enum HomeBlock {
  /// Greeting with the day's actions (check-in, red packet, activities, medals and titles).
  greeting,

  /// The support entry.
  support,

  /// The pinned threads of the forum.
  pinned,

  /// The guide index (latest hot, digest, replies and new threads).
  guide,

  /// The statistics of the forum.
  stats,

  /// The tools of the account.
  tools
  ;

  /// The name stored in the setting.
  String get id => name;

  static HomeBlock? _byId(String id) {
    for (final block in values) {
      if (block.id == id) {
        return block;
      }
    }
    return null;
  }
}

/// Order and visibility of the [HomeBlock]s: the value of `SettingsKeys.homeLayout`.
///
/// Stored as the ids of the blocks in order, separated by commas, a hidden one with a `!` before its id. The empty
/// string is the default (every block shown in [HomeBlock.values] order). Reading is tolerant: unknown ids and
/// repeated ones are dropped, blocks the string misses (a newer version added them) follow the others, shown.
@immutable
final class HomeBlockLayout {
  const HomeBlockLayout._(this.order, this._hidden);

  /// The layout [raw] (the setting's value) stands for.
  factory HomeBlockLayout.parse(String raw) {
    final order = <HomeBlock>[];
    final hidden = <HomeBlock>{};
    for (final part in raw.split(',')) {
      final hide = part.trim().startsWith('!');
      final block = HomeBlock._byId(hide ? part.trim().substring(1) : part.trim());
      if (block == null || order.contains(block)) {
        continue;
      }
      order.add(block);
      if (hide) {
        hidden.add(block);
      }
    }
    order.addAll(HomeBlock.values.where((e) => !order.contains(e)));
    return HomeBlockLayout._(List.unmodifiable(order), Set.unmodifiable(hidden));
  }

  /// Every block shown, in the default order.
  static const defaults = HomeBlockLayout._(HomeBlock.values, <HomeBlock>{});

  /// All the blocks, in the order to show them.
  final List<HomeBlock> order;

  final Set<HomeBlock> _hidden;

  /// Whether [block] is shown.
  bool isVisible(HomeBlock block) => !_hidden.contains(block);

  /// The blocks to show, in order.
  List<HomeBlock> get visible => [
    for (final block in order)
      if (isVisible(block)) block,
  ];

  /// Whether this is the default: the arrangement of the homepage as it was before it could be changed.
  bool get isDefault => _hidden.isEmpty && listEquals(order, HomeBlock.values);

  /// The setting's value of this layout.
  String encode() => isDefault ? '' : order.map((e) => isVisible(e) ? e.id : '!${e.id}').join(',');

  /// This layout with the block at [oldIndex] moved to [newIndex] (the index before the move is taken out, as
  /// `ReorderableListView.onReorder` reports it).
  HomeBlockLayout moved(int oldIndex, int newIndex) {
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (oldIndex < 0 || oldIndex >= order.length || target < 0 || target >= order.length || target == oldIndex) {
      return this;
    }
    final next = [...order];
    next.insert(target, next.removeAt(oldIndex));
    return HomeBlockLayout._(List.unmodifiable(next), _hidden);
  }

  /// This layout with [block] shown or hidden.
  HomeBlockLayout withVisible(HomeBlock block, {required bool visible}) {
    final next = {..._hidden};
    if (visible) {
      next.remove(block);
    } else {
      next.add(block);
    }
    return HomeBlockLayout._(order, Set.unmodifiable(next));
  }
}
