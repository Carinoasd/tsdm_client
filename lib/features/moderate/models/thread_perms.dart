import 'package:flutter/foundation.dart' show immutable;
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/models/thread_admin_forms.dart';

/// What the account a thread page was served to may manage in that thread, as the forum's app API tells it with the
/// page (plugin 3.7.0, `perms` of a thread page answer of `schema` 21 or later).
///
/// Each flag is the forum's own verdict for the page it printed: a management flag is set where the web page's
/// management menu has the item (the user group's permission, the forums the account moderates, what the thread is),
/// so the app offers exactly those. The forum checks again when an operation is sent.
///
/// An answer without `perms` (an older plugin, the web page) has none of this ([fromApi] gives null): the app then
/// offers what it offered before, to an account the forum page says moderates the forum.
///
/// The forum page answer carries `perms` of the same shape since plugin 3.8.0, for the management of several threads
/// picked in its list: only the flags the web page's layer of the picked threads has (delete, move, type, stick,
/// digest, highlight, recommend, bump, close, with `stick_max` and `digest_max`), none of them set on an archived
/// page. A flag an answer does not carry reads as not allowed (the two added by plugin 3.8.0 apart, which older
/// thread page answers lack: [allowRemoveRate], [allowDeleteAttachments]).
@immutable
final class ThreadPerms {
  /// Constructor.
  const ThreadPerms(this._flags);

  /// The permissions in `perms` of a thread page answer, or of a forum page answer; null when the answer has none.
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

  /// The account may take rates of the thread's floors back: `allow_removerate` where the answer tells (plugin
  /// 3.8.0: a moderator of the forum whose user group has a rate range, as the forum checks when the window is sent),
  /// a moderator of the forum where it does not (before: as the web page, whose link asks for the moderator only).
  bool get allowRemoveRate => _told('allow_removerate') ?? isModerator;

  /// The account may delete the attachments of floors that are not its own (`allow_delattach`, plugin 3.8.0: the
  /// moderators of the forum, whatever their user group; an author deleting the attachments of the own floor is not
  /// this flag's business); null when the answer does not tell (before plugin 3.8.0: the forum decides when asked).
  bool? get allowDeleteAttachments => _told('allow_delattach');

  /// The account may see the poster's IP of the thread's floors (`allow_viewip`, plugin 3.9.0); each floor tells it
  /// with its own `can.viewip` (the author's rank counts too).
  bool get allowViewIp => _allows('allow_viewip');

  /// The operations beside the management window the web page's menu of the thread has (`allow_removereward`,
  /// `allow_refund`, since plugin 3.7.0), offered only when [formsKnown] (plugin 3.9.0 gives their window's data).
  List<ThreadAdminAction> adminActions({required bool formsKnown}) => [
    if (formsKnown && _allows('allow_removereward')) ThreadAdminAction.removeReward,
    if (formsKnown && _allows('allow_refund')) ThreadAdminAction.refund,
  ];

  /// Flag [key] where the answer carries it, null where it does not.
  bool? _told(String key) => _flags.containsKey(key) ? _allows(key) : null;

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
