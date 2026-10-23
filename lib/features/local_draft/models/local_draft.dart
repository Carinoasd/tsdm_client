import 'package:flutter/foundation.dart';

/// What a local draft is written for.
enum LocalDraftKind {
  /// A reply to a thread (the quick reply, or the reply box of a notice).
  threadReply('reply'),

  /// A reply to one floor of a thread.
  floorReply('floor'),

  /// A private message to another member.
  message('pm'),

  /// A new thread in a forum.
  newThread('thread'),

  /// An edit of an existing post.
  edit('edit')
  ;

  const LocalDraftKind(this.prefix);

  /// The first part of the keys of this kind.
  final String prefix;
}

final _idRe = RegExp(r'^[1-9]\d*$');

/// The target a local draft belongs to, unique for one account: `reply:<tid>`, `floor:<tid>:<pid>`, `pm:<uid>`,
/// `thread:<fid>`, `edit:<pid>`.
///
/// A draft moved aside (a newer draft was written for the same target while it was still offered) keeps its target and
/// gets a [backup] stamp: `reply:<tid>~<stamp>`. It is listed, never offered again by the editor of the target.
@immutable
final class LocalDraftKey {
  const LocalDraftKey._(this.kind, this.ids, {this.backup});

  /// The reply to thread [tid].
  factory LocalDraftKey.threadReply(String tid) => LocalDraftKey._(LocalDraftKind.threadReply, [tid]);

  /// The reply to floor [pid] of thread [tid].
  factory LocalDraftKey.floorReply(String tid, String pid) => LocalDraftKey._(LocalDraftKind.floorReply, [tid, pid]);

  /// The private message to member [uid].
  factory LocalDraftKey.message(String uid) => LocalDraftKey._(LocalDraftKind.message, [uid]);

  /// The new thread in forum [fid].
  factory LocalDraftKey.newThread(String fid) => LocalDraftKey._(LocalDraftKind.newThread, [fid]);

  /// The edit of post [pid].
  factory LocalDraftKey.edit(String pid) => LocalDraftKey._(LocalDraftKind.edit, [pid]);

  /// The key written as [value], null when it is not one (another app version's, a broken file).
  static LocalDraftKey? parse(String value) {
    final stamped = value.split('~');
    if (stamped.length > 2) {
      return null;
    }
    final backup = stamped.length == 2 ? int.tryParse(stamped[1]) : null;
    if (stamped.length == 2 && (backup == null || backup <= 0)) {
      return null;
    }
    final parts = stamped.first.split(':');
    final kind = LocalDraftKind.values.where((e) => e.prefix == parts.first).firstOrNull;
    if (kind == null) {
      return null;
    }
    final ids = parts.skip(1).toList();
    final count = kind == LocalDraftKind.floorReply ? 2 : 1;
    if (ids.length != count || !ids.every(_idRe.hasMatch)) {
      return null;
    }
    return LocalDraftKey._(kind, List.unmodifiable(ids), backup: backup);
  }

  /// What the draft is for.
  final LocalDraftKind kind;

  /// The ids of the target, in the order of the key.
  final List<String> ids;

  /// When a draft was moved aside (milliseconds since the epoch), null for the draft of the target itself.
  final int? backup;

  /// The thread of a reply, null for other kinds.
  String? get tid => kind == LocalDraftKind.threadReply || kind == LocalDraftKind.floorReply ? ids.first : null;

  /// The floor of a reply to a floor, the post of an edit, null otherwise.
  String? get pid => switch (kind) {
    LocalDraftKind.floorReply => ids[1],
    LocalDraftKind.edit => ids.first,
    _ => null,
  };

  /// The member a private message goes to, null for other kinds.
  String? get peerUid => kind == LocalDraftKind.message ? ids.first : null;

  /// The forum of a new thread, null for other kinds.
  String? get fid => kind == LocalDraftKind.newThread ? ids.first : null;

  /// Whether this is a draft moved aside ([backup]).
  bool get isBackup => backup != null;

  /// The key of the target itself, without the [backup] stamp.
  LocalDraftKey get target => backup == null ? this : LocalDraftKey._(kind, ids);

  /// This target moved aside at [stamp].
  LocalDraftKey backupAt(int stamp) => LocalDraftKey._(kind, ids, backup: stamp);

  /// The key as written in the file.
  String get value => '${kind.prefix}:${ids.join(':')}${backup == null ? '' : '~$backup'}';

  @override
  bool operator ==(Object other) => other is LocalDraftKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'LocalDraftKey($value)';
}

/// What an editor held and did not send, kept on this device for one account (the local draft store).
///
/// [body] is the post as the editor gives it to the forum (BBCode) and [delta] the editor's own document (the rich
/// editor's Quill delta as JSON), which brings back what BBCode does not carry; the body alone is enough to restore.
@immutable
final class LocalDraft {
  /// Constructor.
  const LocalDraft({
    required this.key,
    required this.body,
    required this.updatedAt,
    this.delta,
    this.subject,
    this.fid,
    this.tid,
    this.replyAction,
    this.hint,
    this.quote = true,
    this.title,
    this.typeId,
    this.maybeSent = false,
  });

  /// The draft written as [json] under [key], null when it is not one.
  static LocalDraft? fromJson(LocalDraftKey key, Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final body = json['body'];
    final updated = json['updatedAt'];
    if (body is! String || updated is! int) {
      return null;
    }
    String? text(String name) => json[name] is String ? json[name] as String : null;
    return LocalDraft(
      key: key,
      body: body,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updated),
      delta: text('delta'),
      subject: text('subject'),
      fid: text('fid'),
      tid: text('tid'),
      replyAction: text('replyAction'),
      hint: text('hint'),
      quote: json['quote'] != false,
      title: text('title'),
      typeId: text('typeId'),
      maybeSent: json['maybeSent'] == true,
    );
  }

  /// The target.
  final LocalDraftKey key;

  /// The post, BBCode as sent to the forum.
  final String body;

  /// The editor's document (Quill delta JSON), null when only [body] is known.
  final String? delta;

  /// The title of a new thread or of an edited first post, null for replies and messages.
  final String? subject;

  /// When the draft was last written.
  final DateTime updatedAt;

  /// The forum of the thread replied to or edited, when known.
  final String? fid;

  /// The thread of an edited post (its key names only the post), when known.
  final String? tid;

  /// The reply link of the floor replied to (the forum's `repquote` or `reppost` url), for a reply to a floor.
  final String? replyAction;

  /// What the reply box said about the floor replied to ("回复 Bob #5"), for a reply to a floor.
  final String? hint;

  /// Whether a reply to a floor quotes it (the forum's `repquote`); false when the quote was taken out.
  final bool quote;

  /// A name of the target to show in the list (the thread, the forum, the member), when the editor knew one.
  final String? title;

  /// The thread type chosen for a new thread, when one was.
  final String? typeId;

  /// Sending it failed after the request left (no answer came): the forum may have taken it, the user should look
  /// before sending it again.
  final bool maybeSent;

  /// Whether nothing was written: no title and no post.
  bool get isEmpty => body.trim().isEmpty && (subject?.trim().isEmpty ?? true);

  /// Whether [other] holds the same title and post (whatever its time and target).
  bool sameContent(LocalDraft? other) =>
      other != null && other.body == body && (other.subject ?? '') == (subject ?? '') && other.delta == delta;

  /// This draft under [key].
  LocalDraft withKey(LocalDraftKey key) => copyWith(key: key);

  /// This draft with [key], or marked [maybeSent].
  LocalDraft copyWith({LocalDraftKey? key, bool? maybeSent}) => LocalDraft(
    key: key ?? this.key,
    body: body,
    updatedAt: updatedAt,
    delta: delta,
    subject: subject,
    fid: fid,
    tid: tid,
    replyAction: replyAction,
    hint: hint,
    quote: quote,
    title: title,
    typeId: typeId,
    maybeSent: maybeSent ?? this.maybeSent,
  );

  /// The draft as written in the file (its key is the name it is written under).
  Map<String, Object?> toJson() => {
    'body': body,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'delta': ?delta,
    'subject': ?subject,
    'fid': ?fid,
    'tid': ?tid,
    'replyAction': ?replyAction,
    'hint': ?hint,
    if (!quote) 'quote': false,
    'title': ?title,
    'typeId': ?typeId,
    if (maybeSent) 'maybeSent': true,
  };

  @override
  String toString() => 'LocalDraft(${key.value}, ${body.length} chars, $updatedAt)';
}
