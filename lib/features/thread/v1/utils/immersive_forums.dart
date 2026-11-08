import 'package:flutter/foundation.dart';

/// The forums whose threads open in immersive reading (the `immersiveForums` setting) and whether every forum does.
///
/// Stored as text, the ids separated by commas, a `+` after an id taking the subforums of that forum along: `12,34+`.
@immutable
final class ImmersiveForums {
  /// Constructor.
  const ImmersiveForums({this.all = false, this.exact = const {}, this.withSubforums = const {}});

  /// Read the stored [raw] text; entries that are not a forum id are dropped.
  factory ImmersiveForums.parse(String raw, {bool all = false}) {
    final exact = <int>{};
    final withSubforums = <int>{};
    for (final part in raw.split(',')) {
      final entry = part.trim();
      final sub = entry.endsWith('+');
      final fid = int.tryParse(sub ? entry.substring(0, entry.length - 1) : entry);
      if (fid == null || fid <= 0) {
        continue;
      }
      if (sub) {
        withSubforums.add(fid);
      } else {
        exact.add(fid);
      }
    }
    return ImmersiveForums(all: all, exact: exact.difference(withSubforums), withSubforums: withSubforums);
  }

  /// Every forum opens in immersive reading.
  final bool all;

  /// Forums picked on their own.
  final Set<int> exact;

  /// Forums picked together with their subforums.
  final Set<int> withSubforums;

  /// The text to store: the forums in id order, a forum picked twice kept with its subforums.
  String get raw {
    final entries = <(int, String)>[
      for (final fid in exact)
        if (!withSubforums.contains(fid)) (fid, '$fid'),
      for (final fid in withSubforums) (fid, '$fid+'),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return entries.map((e) => e.$2).join(',');
  }

  /// Whether [fid] is picked, on its own or with its subforums.
  bool picks(int fid) => exact.contains(fid) || withSubforums.contains(fid);

  /// Whether [fid] is picked together with its subforums.
  bool picksWithSubforums(int fid) => withSubforums.contains(fid);

  /// Whether a thread of forum [fid] opens in immersive reading: every forum is on, the forum is picked, or a forum
  /// above it ([ancestors], the forums of the breadcrumbs) is picked with its subforums.
  bool matches(int? fid, {Iterable<int> ancestors = const []}) {
    if (all) {
      return true;
    }
    if (fid != null && picks(fid)) {
      return true;
    }
    return ancestors.any(withSubforums.contains);
  }

  /// This with [fid] picked ([subforums]: with its subforums too), or no longer picked when [picked] is false.
  ImmersiveForums withForum(int fid, {required bool picked, bool subforums = false}) {
    final nextExact = {...exact}..remove(fid);
    final nextSub = {...withSubforums}..remove(fid);
    if (picked) {
      (subforums ? nextSub : nextExact).add(fid);
    }
    return ImmersiveForums(all: all, exact: nextExact, withSubforums: nextSub);
  }

  @override
  bool operator ==(Object other) =>
      other is ImmersiveForums &&
      other.all == all &&
      setEquals(other.exact, exact) &&
      setEquals(other.withSubforums, withSubforums);

  @override
  int get hashCode => Object.hash(all, Object.hashAllUnordered(exact), Object.hashAllUnordered(withSubforums));
}

/// The ids of the forums the [links] of a thread's breadcrumbs point to (`fid=` in the query), the group links
/// (`gid=`) left out.
List<int> breadcrumbForumIds(Iterable<Uri> links) => [for (final link in links) ?_forumIdOf(link)];

int? _forumIdOf(Uri link) {
  final fid = int.tryParse(link.queryParameters['fid'] ?? '');
  return fid != null && fid > 0 ? fid : null;
}
