part of 'reply_bar.dart';

final _positiveIdRe = RegExp(r'^[1-9]\d*$');

/// What the reply bar writes for, the target of its local draft: account [uid], the thread or floor of a reply, the
/// member of a private message ([key]), and what the draft needs to be opened again ([fid], [replyAction], [hint],
/// [quote]).
@immutable
final class _ReplyDraftTarget {
  const _ReplyDraftTarget({
    required this.uid,
    required this.key,
    this.fid,
    this.replyAction,
    this.hint,
    this.quote = true,
  });

  final int uid;
  final LocalDraftKey key;
  final String? fid;
  final String? replyAction;
  final String? hint;
  final bool quote;

  /// The same account and draft key: the same draft, whatever the details.
  bool sameDraft(_ReplyDraftTarget? other) => other != null && other.uid == uid && other.key == key;

  @override
  bool operator ==(Object other) =>
      other is _ReplyDraftTarget &&
      other.uid == uid &&
      other.key == key &&
      other.fid == fid &&
      other.replyAction == replyAction &&
      other.hint == hint &&
      other.quote == quote;

  @override
  int get hashCode => Object.hash(uid, key, fid, replyAction, hint, quote);
}

/// The floor a reply link of the forum (`forum.php?mod=post&action=reply&…&repquote=<pid>` or `&reppost=<pid>`) replies
/// to, null for the reply to the thread.
String? _floorOfReplyAction(String? action) {
  final query = action?.tryParseAsUri()?.queryParameters;
  final pid = query?['repquote'] ?? query?['reppost'];
  return pid != null && _positiveIdRe.hasMatch(pid) ? pid : null;
}

/// The reply link [action] without its quote (`reppost`: the forum stores the reply to the floor and tells its author,
/// as for a reply to the first floor, but quotes nothing), null when it does not quote (`repquote`).
String? _withoutQuote(String? action) =>
    action != null && action.contains('repquote=') ? action.replaceFirst('repquote=', 'reppost=') : null;

/// The local draft of a reply bar ([ReplyBarController]): what the bar holds is kept on this device for the account and
/// the target it goes to ([LocalDraftStore]), every couple of seconds while written, at once when the editor collapses
/// or the page goes away; it is deleted once sent (the reply bloc does that, also for a page closed meanwhile) or when
/// the user empties the box.
///
/// It lives as long as the controller, across the bars a page builds with it (the thread page drops its bar while it
/// reloads), and writes while a bar is on screen ([attach]). It also keeps what the reply window of each reply link
/// told ([prefetch]): the quote of a floor and the forum's size limits.
final class _ReplyDraftSession {
  _ReplyDraftSession(this._controller);

  final ReplyBarController _controller;

  late final saver = DraftAutosaver(read: _snapshot);

  _ReplyDraftTarget? _target;

  /// What the draft is written for, null before the page told it (no account, the thread not loaded yet).
  _ReplyDraftTarget? get target => _target;

  /// The target of the reply being sent.
  _ReplyDraftTarget? _sending;

  /// Text the bar holds that is not this draft's: the text just sent (cleared right after), the text written for
  /// another account before a switch (shown on, never kept for this account). Nothing is kept while the bar holds it.
  String? _ignoredBody;

  /// The editor of the expanded bar, while it is open.
  BBCodeEditorController? _editor;

  /// The text of the collapsed box, null when no box is on screen.
  String Function()? _outerText;

  /// What the box holds after the editor collapsed (its text is set a frame later), and the editor's document then.
  String? _collapsedBody;
  String? _collapsedDelta;

  /// The window info of each reply link: asked, and known.
  final _asked = <String>{};
  final _infos = <String, ReplyFormInfo?>{};
  final _failedAt = <String, DateTime>{};

  /// Bumped when something the editor shows changed: a window info came, the target changed.
  final revision = ValueNotifier<int>(0);

  /// A bar is on screen and keeps its box text in [outerText].
  void attach({required String Function() outerText}) {
    _outerText = outerText;
    saver.attach();
  }

  /// The bar left the screen: what it holds is written now.
  void detach() {
    saver.detach();
    _outerText = null;
    _editor = null;
  }

  /// The expanded editor opened.
  // A method like detachEditor beside it, not a setter.
  // ignore: use_setters_to_change_properties
  void attachEditor(BBCodeEditorController editor) => _editor = editor;

  /// The expanded editor closed holding [body] (BBCode) and [delta] (its document): kept as the box's content, written.
  void detachEditor({required String body, required String delta}) {
    _editor = null;
    _collapsedBody = body;
    _collapsedDelta = delta;
    saver.flush();
  }

  /// The box now holds [body] (cleared after sending, a draft put back), with the editor's [delta] when known.
  void setCollapsed(String body, {String? delta}) {
    _collapsedBody = body;
    _collapsedDelta = delta;
  }

  /// The editor's document for the box text [body], null when the box holds other text than the editor left.
  String? deltaFor(String body) => body == _collapsedBody ? _collapsedDelta : null;

  /// What the bar holds now: the editor's while it is open, else the box's.
  ({String body, String? delta}) get content {
    final editor = _editor;
    if (editor != null) {
      return (body: editor.toForumBBCode(), delta: editor.toQuillDelta());
    }
    final body = _collapsedBody ?? _outerText?.call() ?? '';
    return (body: body, delta: deltaFor(body));
  }

  DraftSnapshot? _snapshot() {
    final target = _target;
    if (target == null) {
      return null;
    }
    final current = content;
    if (_ignoredBody != null) {
      if (current.body == _ignoredBody) {
        return (uid: target.uid, key: target.key, draft: null);
      }
      _ignoredBody = null;
    }
    if (current.body.trim().isEmpty) {
      return (uid: target.uid, key: target.key, draft: null);
    }
    return (
      uid: target.uid,
      key: target.key,
      draft: LocalDraft(
        key: target.key,
        body: current.body,
        delta: current.delta,
        updatedAt: DateTime.now(),
        fid: target.fid,
        replyAction: target.replyAction,
        hint: target.hint,
        quote: target.quote,
      ),
    );
  }

  /// The text changed.
  void changed() => saver.changed();

  /// Write for [next] from now on.
  ///
  /// Another draft (another account, thread, floor or member): what was written so far is written for the previous
  /// target, then it goes on with the new one (the bar always moved its text along when another floor was picked): the
  /// previous target of the same account keeps nothing of it. The draft stored for the new target is offered
  /// ([DraftAutosaver.offer]): for the reply to a thread the newest draft of the thread, a floor's too (the bar is where
  /// the user comes back to); for a floor or a member its own.
  void retarget(_ReplyDraftTarget? next) {
    final previous = _target;
    if (next == previous) {
      return;
    }
    if (next != null && next.sameDraft(previous)) {
      // The same draft, other details (the floor's hint, the quote taken out).
      _target = next;
      saver.changed();
      return;
    }
    if (next == null) {
      // Nothing to write for (logged out, the thread closed): the box shows a hint now, not the draft, which stays as
      // it was written last.
      _target = null;
      revision.value++;
      saver.offer.value = null;
      return;
    }
    if (previous != null) {
      saver.flush();
    }
    _target = next;
    revision.value++;
    if (previous != null && previous.uid != next.uid) {
      // Another account: the text written for the previous one stays shown, it is not this account's draft.
      _ignoredBody = content.body;
    }
    final moves = previous != null && previous.uid == next.uid && content.body.trim().isNotEmpty;
    final key = next.key;
    unawaited(
      saver
          .offerStored(
            next.uid,
            (k) => key.kind == LocalDraftKind.threadReply ? k.tid == key.tid : k == key,
          )
          .then((_) {
            if (_target != next) {
              return;
            }
            if (moves) {
              // The text went with the editor: the previous target keeps nothing of it.
              saver.moved(previous.uid, previous.key);
            }
            saver.flush();
          }),
    );
  }

  /// Ask the reply window of [url] (the reply link of a floor, the reply page of a thread) once: what it tells is then
  /// [infoOf] it. Asked again later when it could not be read.
  void prefetch(String url, ReplyRepository repository) {
    final failed = _failedAt[url];
    if (failed != null && DateTime.now().difference(failed) > const Duration(seconds: 30)) {
      _failedAt.remove(url);
      _asked.remove(url);
    }
    if (!_asked.add(url)) {
      return;
    }
    unawaited(
      repository.fetchReplyFormInfo(url).then((info) {
        if (info == null) {
          _failedAt[url] = DateTime.now();
          return;
        }
        _infos[url] = info;
        revision.value++;
      }),
    );
  }

  /// What the reply window of [url] told, null when it did not come (yet).
  ReplyFormInfo? infoOf(String url) => _infos[url];

  /// The size limits known for the thread [tid]: any reply window of the forum tells the same.
  MessageLimits? limitsOf(String? tid) {
    if (tid == null) {
      return null;
    }
    for (final MapEntry(:key, :value) in _infos.entries) {
      if (value?.limits != null && key.tryParseAsUri()?.queryParameters['tid'] == tid) {
        return value!.limits;
      }
    }
    return null;
  }

  /// The reply is sent now: its draft is the one of the target now.
  void sending() => _sending = _target;

  /// The reply bloc changed to [status]: nothing is written while the reply is sent; once it was stored, the draft is
  /// gone (the bloc deleted it) and nothing is written for it until the user writes again.
  void onReplyStatus(ReplyStatus status) {
    switch (status) {
      case ReplyStatus.loading:
        saver.pause();
      case ReplyStatus.success:
        final sent = _sending ?? _target;
        _sending = null;
        _ignoredBody = content.body;
        _collapsedBody = '';
        _collapsedDelta = null;
        if (sent != null) {
          saver.sent(sent.uid, sent.key);
        }
        saver.resume();
      case ReplyStatus.failure || ReplyStatus.verification || ReplyStatus.initial:
        if (status != ReplyStatus.verification) {
          _sending = null;
        }
        saver.resume();
    }
  }

  /// Restore the offered draft: a floor's draft takes its floor back (the reply link, the quote taken out or not; the
  /// caller sets its hint), a thread's draft the reply to the thread; the caller puts the text into the bar. Null when
  /// nothing is offered.
  LocalDraft? takeOffer() {
    final draft = saver.takeOffer();
    final target = _target;
    if (draft == null || target == null || draft.key == target.key) {
      return draft;
    }
    if (draft.key.kind == LocalDraftKind.floorReply && draft.replyAction != null) {
      final action = draft.replyAction!;
      _controller
        ..replyAction = action
        .._quotedAction = draft.quote ? null : action.replaceFirst('reppost=', 'repquote=');
      _target = _ReplyDraftTarget(
        uid: target.uid,
        key: draft.key,
        fid: draft.fid ?? target.fid,
        replyAction: action,
        hint: draft.hint,
        quote: draft.quote,
      );
    } else if (draft.key.kind == LocalDraftKind.threadReply) {
      _controller._replyToThread();
      _target = _ReplyDraftTarget(uid: target.uid, key: draft.key, fid: draft.fid ?? target.fid);
    }
    revision.value++;
    return draft;
  }
}
