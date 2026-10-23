import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// A place in the list of floors: a floor, or the empty place a floor dropped from the thread page left
/// ([isDropped]).
final class FloorSlot {
  FloorSlot._(this.key, this.post);

  /// The slot of [post].
  factory FloorSlot.of(String key, Post post) => FloorSlot._(key, post);

  /// Stable key of the floor in the list ([floorKeyOf]); a dropped floor's slot gets a key of its own.
  String key;

  /// The floor, null once it was dropped.
  Post? post;

  /// Whether the floor was dropped from the pages kept ([threadWindowPages]): the slot stays, empty and without
  /// height, so the floors after it keep their places in the list (and on screen).
  bool get isDropped => post == null;
}

/// The floors on screen split around the place the list was opened at, so that pages put above never move what is
/// shown (see `PostList`).
///
/// The list is a scroll view with its zero offset at the first floor it was opened with: [below] grows down from there
/// (the page opened, the pages after it), [above] grows up from there (the pages before it, loaded when scrolled up
/// to). Floors are only ever added at the far ends, and the floors dropped from the kept pages that are not at a far
/// end stay as empty slots (never filled again: a page loaded again goes to a far end), so the items of either list
/// keep their index while the list is shown, and the floors on screen their offsets.
final class FloorLayout {
  /// Floors above the opening place, top to bottom.
  final List<FloorSlot> above = [];

  /// Floors from the opening place down, top to bottom.
  final List<FloorSlot> below = [];

  /// Keys of the floors that begin a page after the first one ("page N" divider above them).
  Set<String> pageStarts = const {};

  /// [ThreadState.generation] of the floors laid out.
  int? generation;

  int _dropped = 0;

  final Map<String, int> _aboveIndex = {};
  final Map<String, int> _belowIndex = {};

  /// Index in the list growing up (0 nearest to the opening place) of the slot with [key].
  int? aboveItemIndexOf(String key) => _aboveIndex[key];

  /// Index in the list growing down of the slot with [key].
  int? belowItemIndexOf(String key) => _belowIndex[key];

  /// The slot of item [index] of the list growing up (0 nearest to the opening place).
  FloorSlot aboveItem(int index) => above[above.length - 1 - index];

  /// Floors on screen, top to bottom.
  Iterable<Post> get posts => [...above, ...below].map((e) => e.post).whereType<Post>();

  /// Whether a floor dropped from the kept pages left an empty slot.
  bool get hasDropped => above.any((e) => e.isDropped) || below.any((e) => e.isDropped);

  /// Lay out [posts] (the floors on screen, top to bottom) of [generation].
  ///
  /// A new generation, or floors without any floor in common with the ones laid out, start over: every floor below the
  /// opening place. Otherwise the floors laid out stay where they are (with the floor of the same key, which may have
  /// changed), the ones no longer there become empty slots (removed at the far ends), and the new ones go above the
  /// first floor (to the top of [above]) or after the last one (to the end of [below]); a new floor between two laid out
  /// ones (a floor the forum did not show before) goes right after the one before it.
  void layOut(List<Post> posts, int generation) {
    final keys = keysOf(posts);
    final byKey = {for (final (i, key) in keys.indexed) key: posts[i]};
    if (generation != this.generation || !keys.any((e) => _aboveIndex.containsKey(e) || _belowIndex.containsKey(e))) {
      this.generation = generation;
      above.clear();
      below
        ..clear()
        ..addAll([for (final (i, key) in keys.indexed) FloorSlot.of(key, posts[i])]);
      _index();
      return;
    }

    for (final slot in [...above, ...below]) {
      if (slot.isDropped) {
        continue;
      }
      final post = byKey[slot.key];
      if (post == null) {
        slot
          ..post = null
          ..key = 'dropped:${_dropped++}';
      } else {
        slot.post = post;
      }
    }
    // Empty slots at the far ends hold no floor's place: nothing comes after them in their list.
    while (above.isNotEmpty && above.first.isDropped) {
      above.removeAt(0);
    }
    if (above.every((e) => e.isDropped)) {
      above.clear();
    }
    while (below.isNotEmpty && below.last.isDropped) {
      below.removeLast();
    }

    final placed = [...above, ...below].where((e) => !e.isDropped).map((e) => e.key).toSet();
    final first = keys.indexWhere(placed.contains);
    if (first < 0) {
      // Nothing in common any more.
      this.generation = null;
      layOut(posts, generation);
      return;
    }
    final last = keys.lastIndexWhere(placed.contains);
    // Between the floors laid out: after the one before it.
    for (var i = first + 1; i < last; i++) {
      if (placed.contains(keys[i])) {
        continue;
      }
      final previous = keys[i - 1];
      final slot = FloorSlot.of(keys[i], posts[i]);
      final inAbove = above.indexWhere((e) => e.key == previous);
      if (inAbove >= 0) {
        above.insert(inAbove + 1, slot);
      } else {
        below.insert(below.indexWhere((e) => e.key == previous) + 1, slot);
      }
    }
    // Before the first floor laid out: on top.
    above.insertAll(0, [for (var i = 0; i < first; i++) FloorSlot.of(keys[i], posts[i])]);
    // After the last one: at the end.
    below.addAll([for (var i = last + 1; i < keys.length; i++) FloorSlot.of(keys[i], posts[i])]);
    _index();
  }

  void _index() {
    _aboveIndex
      ..clear()
      ..addAll({for (var i = 0; i < above.length; i++) aboveItem(i).key: i});
    _belowIndex
      ..clear()
      ..addAll({for (final (i, slot) in below.indexed) slot.key: i});
    final starts = <String>{};
    int? page;
    for (final slot in [...above, ...below]) {
      final post = slot.post;
      if (post == null) {
        continue;
      }
      if (post.page != page && post.page > 1) {
        starts.add(slot.key);
      }
      page = post.page;
    }
    pageStarts = starts;
  }

  /// Keys of [posts] ([floorKeyOf]), a floor without a post id told apart by its place on its page.
  static List<String> keysOf(List<Post> posts) {
    final keys = <String>[];
    final seen = <String>{};
    final unnamed = <int, int>{};
    for (final post in posts) {
      final key = post.postID.isEmpty
          ? 'page${post.page}:${unnamed[post.page] = (unnamed[post.page] ?? -1) + 1}'
          : floorKeyOf(post);
      // The same floor twice on the page (a parser's slip): told apart by how many times it came.
      var copies = 0;
      while (!seen.add(copies == 0 ? key : '$key#$copies')) {
        copies++;
      }
      keys.add(copies == 0 ? key : '$key#$copies');
    }
    return keys;
  }
}
