import 'package:flutter/foundation.dart' show immutable;
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';

/// What the account a thread page was served to may manage in that thread, as the forum's app API tells it with the
/// page (plugin 3.7.0, `perms` of a thread page answer of `schema` 21 or later).
///
/// Each flag is the forum's own verdict for the page it printed: a management flag is set where the web page's
/// management menu has the item (the user group's permission, the forums the account moderates, what the thread is),
/// so the app offers exactly those. The forum checks again when an operation is sent.
///
/// An answer without `perms` (an older plugin, the web page) has none of this ([fromApi] gives null): the app then
/// offers what it offered before, to an account the forum page says moderates the forum.
@immutable
final class ThreadPerms {
  /// Constructor.
  const ThreadPerms(this._flags);

  /// The permissions in `perms` of a thread page answer; null when the answer has none.
  static ThreadPerms? fromApi(Object? perms) {
    if (perms is! Map<String, dynamic>) {
      return null;
    }
    return ThreadPerms({
      for (final MapEntry(:key, :value) in perms.entries)
        if (value is num) key: value.toInt(),
    });
  }

  final Map<String, int> _flags;

  bool _allows(String key) => (_flags[key] ?? 0) == 1;

  /// The account moderates the thread's forum (`ismoderator`).
  bool get isModerator => _allows('ismoderator');

  /// The highest level the account may stick the thread at (`stick_max`: 1 the forum, 2 its group, 3 everywhere), 0
  /// when it may not stick it.
  int get stickMax => _flags['stick_max'] ?? 0;

  /// The highest level the account may digest the thread at (`digest_max`, 1 to 3), 0 when it may not.
  int get digestMax => _flags['digest_max'] ?? 0;

  /// The account may ban members from posting (`allow_banuser`: the user group's permission, whatever the forum).
  bool get allowBanUser => _allows('allow_banuser');

  /// The account may delete comments of floors (`allow_delcomment`).
  bool get allowDeleteComment => _allows('allow_delcomment');

  /// Whether the web page's management menu of the thread has [operation].
  bool allowsThread(ModerateOperation operation) => _allows(switch (operation) {
    ModerateOperation.stick => 'allow_stick',
    ModerateOperation.digest => 'allow_digest',
    ModerateOperation.highlight => 'allow_highlight',
    ModerateOperation.recommend => 'allow_recommend',
    ModerateOperation.stamp => 'allow_stamp',
    ModerateOperation.stamplist => 'allow_stamplist',
    ModerateOperation.close || ModerateOperation.open => 'allow_close',
    ModerateOperation.move => 'allow_move',
    ModerateOperation.type => 'allow_type',
    ModerateOperation.copy => 'allow_copy',
    ModerateOperation.merge => 'allow_merge',
    ModerateOperation.split => 'allow_split',
    ModerateOperation.repair => 'allow_repair',
    ModerateOperation.delete => 'allow_delthread',
    ModerateOperation.bump || ModerateOperation.down => 'allow_bump',
  });

  /// Whether the web page offers [action] on the floors of the thread: the warning also needs the floor's own
  /// `can.warn` (the author's rank), and sticking a reply is the thread author's too, moderator or not.
  bool allowsFloor(FloorModerateAction action) => _allows(switch (action) {
    FloorModerateAction.warn => 'allow_warn',
    FloorModerateAction.ban => 'allow_banpost',
    FloorModerateAction.delete => 'allow_delpost',
    FloorModerateAction.stick => 'allow_stickreply',
  });

  /// The operations the web page offers on a floor of the thread, of every [FloorModerateAction]: the warning only
  /// where the floor's own `can.warn` allows it too ([canWarn], `Post.canWarn`; null when the floor does not tell).
  List<FloorModerateAction> floorOperations({bool? canWarn}) => [
    for (final action in FloorModerateAction.values)
      if (allowsFloor(action) && (action != FloorModerateAction.warn || (canWarn ?? true))) action,
  ];

  /// The highest level of [operation] the account may set ([stickMax], [digestMax]); null for an operation without
  /// levels.
  int? maxLevelOf(ModerateOperation operation) => switch (operation) {
    ModerateOperation.stick => stickMax,
    ModerateOperation.digest => digestMax,
    _ => null,
  };

  /// [operations] the web page's management menu of the thread has, in their order.
  List<ModerateOperation> threadOperations(List<ModerateOperation> operations) =>
      operations.where(allowsThread).toList(growable: false);

  @override
  bool operator ==(Object other) =>
      other is ThreadPerms &&
      other._flags.length == _flags.length &&
      _flags.entries.every((e) => other._flags[e.key] == e.value);

  @override
  int get hashCode => Object.hashAllUnordered(_flags.entries.map((e) => Object.hash(e.key, e.value)));

  @override
  String toString() => 'ThreadPerms(${_flags.entries.where((e) => e.value != 0).map((e) => e.key).join(', ')})';
}

/// What the accounts of this run may manage in the forums whose threads they opened, by account and forum, as the last
/// thread page of that forum told ([ThreadPerms]): the forum page answer carries no permissions, the management of
/// several threads of a forum page reads them here.
///
/// Only what a thread page told a moderator of its forum about a thread that is not a draft is kept (the forum offers
/// no management of a draft), and only for [keptFor]: a forum no thread was opened of, or not lately, has none, and
/// the forum page offers what it offered before.
abstract final class ForumPermsMemory {
  /// How long what a thread page told is kept.
  static const keptFor = Duration(minutes: 10);

  static final _known = <(int, int), (ThreadPerms, DateTime)>{};

  /// Keep [perms] of a thread page of forum [fid] served to account [uid]. A [draft]'s tell nothing of the forum and
  /// are not kept; a page that does not say the account moderates the forum forgets what was known instead.
  static void note({required int uid, required int fid, required ThreadPerms perms, bool draft = false}) {
    if (uid <= 0 || fid <= 0 || draft) {
      return;
    }
    if (!perms.isModerator) {
      _known.remove((uid, fid));
      return;
    }
    _known[(uid, fid)] = (perms, DateTime.now());
  }

  /// What account [uid] may manage in forum [fid], null when no thread page told it lately.
  static ThreadPerms? of({required int uid, required int fid}) => switch (_known[(uid, fid)]) {
    (final perms, final at) when DateTime.now().difference(at) < keptFor => perms,
    _ => null,
  };

  /// Forget everything (tests).
  static void clear() => _known.clear();
}
