import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';

/// What an editor holds now, as the draft of the account `uid` for `key`: `draft` null when there is nothing to keep
/// (nothing typed, or what was loaded into the editor unchanged).
typedef DraftSnapshot = ({int uid, LocalDraftKey key, LocalDraft? draft});

/// A stored draft offered to the editor ("有未送出的草稿 — 恢復／捨棄"), of the account `uid`.
typedef DraftOffer = ({int uid, LocalDraft draft});

/// Keeps what an editor holds as its local draft ([LocalDraftStore]): written about every [interval] while the text
/// changes ([changed]), at once on [flush] (the editor collapses or closes, the app goes to the background).
///
/// [read] tells what the editor holds and for whom, every time something is to be written: the target can change
/// while the editor is open (another floor replied to, another account).
///
/// A draft is only deleted once this saver wrote it and the editor was emptied (the user cleared it), never because an
/// editor opened empty: the draft stored for the target is offered instead ([offer], [offerStored]) and stays until
/// the user restores or discards it. When something else is written for a target whose stored draft is still
/// offered, that draft is moved aside first ([LocalDraftKey.backupAt]): listed, still offered, never lost.
final class DraftAutosaver implements DraftFlusher {
  /// Constructor.
  ///
  /// It writes while [attach]ed to an editor on screen, until [detach]ed or [dispose]d.
  DraftAutosaver({
    required this.read,
    LocalDraftStore? store,
    this.interval = defaultInterval,
    DateTime Function()? now,
  }) : _store = store ?? LocalDraftStore.app,
       _now = now ?? DateTime.now;

  /// How long changes gather before they are written.
  static const defaultInterval = Duration(seconds: 2);

  /// What the editor holds, null when it has no target yet (nothing loaded, no account).
  final DraftSnapshot? Function() read;

  /// How long changes gather before they are written.
  final Duration interval;

  final LocalDraftStore? _store;
  final DateTime Function() _now;

  /// The stored draft offered to restore, null when none is.
  final offer = ValueNotifier<DraftOffer?>(null);

  Timer? _timer;
  bool _paused = false;
  bool _attached = false;
  bool _disposed = false;

  /// The store is being read for a draft to offer ([offerStored]): nothing is written meanwhile, the offered draft
  /// would be written over before it is known.
  int _checking = 0;
  bool _flushWanted = false;

  /// Start writing: the editor is on screen (also written when the app goes to the background).
  void attach() {
    if (_disposed || _attached) {
      return;
    }
    _attached = true;
    _store?.register(this);
  }

  /// Write what the editor holds and stop until [attach]ed again (the editor left the screen).
  ///
  /// While the content is being sent ([pause]) nothing more is written: it was written when sending began, and what
  /// the bloc does with it once the answer comes (deleted when stored) stands.
  void detach() {
    if (!_attached) {
      return;
    }
    if (!_paused) {
      flush();
    }
    _paused = false;
    _attached = false;
    _timer?.cancel();
    _timer = null;
    _store?.unregister(this);
  }

  /// What was written last for each `uid|key`, as [_signature]: what is unchanged is not written again, and only a
  /// key written here may be deleted when the editor empties.
  final _written = <String, String>{};

  /// What was sent for each `uid|key` ([sent]): not written again while the editor still holds it.
  final _sent = <String, String>{};

  static String _id(int uid, LocalDraftKey key) => '$uid|${key.value}';

  static String _signature(LocalDraft draft) =>
      '${draft.subject ?? ''}\u0000${draft.body}\u0000${draft.delta ?? ''}\u0000${draft.maybeSent}';

  /// The text changed: write it once [interval] passed (the changes of that time together).
  void changed() {
    if (_store == null || _paused || !_attached || _disposed || _timer != null) {
      return;
    }
    _timer = Timer(interval, () {
      _timer = null;
      flush();
    });
  }

  /// Stop writing while the content is being sent ([resume] after the answer).
  ///
  /// What the editor holds is written first: the page may go while the reply is on its way.
  void pause() {
    if (!_paused) {
      flush();
    }
    _timer?.cancel();
    _timer = null;
    _paused = true;
  }

  /// Write again after [pause], what changed meanwhile now.
  void resume() {
    if (!_paused) {
      return;
    }
    _paused = false;
    flush();
  }

  @override
  void flush() {
    _timer?.cancel();
    _timer = null;
    final store = _store;
    if (store == null || _paused || !_attached || _disposed) {
      return;
    }
    if (_checking > 0) {
      _flushWanted = true;
      return;
    }
    final snap = read();
    if (snap == null) {
      return;
    }
    final id = _id(snap.uid, snap.key);
    final offered = offer.value;
    final offeredHere = offered != null && offered.uid == snap.uid && offered.draft.key == snap.key;
    final draft = snap.draft;
    if (draft == null || draft.isEmpty) {
      // Nothing to keep. The offered draft stays; a draft written here was cleared by the user.
      if (!offeredHere && _written.remove(id) != null) {
        store.delete(snap.uid, snap.key);
      }
      return;
    }
    final saved = LocalDraft(
      key: snap.key,
      body: draft.body,
      updatedAt: _now(),
      delta: draft.delta,
      subject: draft.subject,
      fid: draft.fid,
      tid: draft.tid,
      replyAction: draft.replyAction,
      hint: draft.hint,
      quote: draft.quote,
      title: draft.title,
      typeId: draft.typeId,
      maybeSent: draft.maybeSent,
    );
    final signature = _signature(saved);
    if (_written[id] == signature || _sent[id] == signature) {
      return;
    }
    _sent.remove(id);
    if (offeredHere) {
      if (offered.draft.sameContent(saved)) {
        return;
      }
      // Something else is written for the target while its stored draft is offered: keep that one aside.
      final aside = offered.draft.withKey(snap.key.backupAt(offered.draft.updatedAt.millisecondsSinceEpoch));
      store.save(snap.uid, aside);
      offer.value = (uid: snap.uid, draft: aside);
    }
    store.save(snap.uid, saved);
    _written[id] = signature;
  }

  /// Offer the newest stored draft of [uid] whose key [test] accepts (a draft moved aside is never offered), unless the
  /// editor already holds the same; [onOffered] runs when one is. A draft offered before is withdrawn first.
  Future<void> offerStored(int uid, bool Function(LocalDraftKey key) test, {VoidCallback? onOffered}) async {
    offer.value = null;
    final store = _store;
    if (store == null) {
      return;
    }
    final List<LocalDraft> drafts;
    _checking++;
    try {
      drafts = await store.list(uid);
    } finally {
      _checking--;
    }
    if (_checking == 0 && _flushWanted) {
      _flushWanted = false;
      // Written once the offer below is known.
      scheduleMicrotask(flush);
    }
    // A draft opened from the list comes first, also one kept aside.
    final preferred = store.takePreferred(uid, test);
    final stored = preferred != null
        ? drafts.where((e) => e.key == preferred).firstOrNull
        : drafts.where((e) => !e.key.isBackup && test(e.key)).firstOrNull;
    if (stored == null || _disposed) {
      return;
    }
    final snap = read();
    if (snap == null || snap.uid != uid) {
      return;
    }
    final current = snap.draft;
    if (current != null && current.sameContent(stored)) {
      // The editor holds it already (the page kept it): it is this editor's draft.
      _written[_id(uid, stored.key)] = _signature(stored);
      return;
    }
    offer.value = (uid: uid, draft: stored);
    onOffered?.call();
  }

  /// The user restores the offered draft: what the editor held is moved aside when it is something else (listed, never
  /// lost), a draft offered from aside goes back to its target. The caller puts the returned draft into the editor and
  /// [flush]es; null when nothing is offered.
  LocalDraft? takeOffer() {
    final offered = offer.value;
    offer.value = null;
    final store = _store;
    if (offered == null || store == null) {
      return offered?.draft;
    }
    final snap = read();
    final current = snap?.draft;
    if (snap != null && snap.uid == offered.uid && current != null && !current.isEmpty) {
      if (!current.sameContent(offered.draft)) {
        final now = _now();
        store.save(
          snap.uid,
          LocalDraft(
            key: snap.key.backupAt(now.millisecondsSinceEpoch),
            body: current.body,
            updatedAt: now,
            delta: current.delta,
            subject: current.subject,
            fid: current.fid,
            tid: current.tid,
            replyAction: current.replyAction,
            hint: current.hint,
            quote: current.quote,
            title: current.title,
            typeId: current.typeId,
          ),
        );
      }
      _written.remove(_id(snap.uid, snap.key));
    }
    if (offered.draft.key.isBackup) {
      store.delete(offered.uid, offered.draft.key);
    }
    return offered.draft;
  }

  /// What the editor holds went to another target: the draft of [uid] for [key] written here goes.
  void moved(int uid, LocalDraftKey key) {
    if (_written.remove(_id(uid, key)) != null) {
      _store?.delete(uid, key);
    }
  }

  /// The user discards the offered draft: it is deleted.
  void discardOffer() {
    final offered = offer.value;
    offer.value = null;
    if (offered != null) {
      _store?.delete(offered.uid, offered.draft.key);
    }
  }

  /// The draft of [uid] for [key] was sent: delete it, and write nothing for it until the editor changes again.
  void sent(int uid, LocalDraftKey key) {
    _timer?.cancel();
    _timer = null;
    final id = _id(uid, key);
    _written.remove(id);
    final snap = read();
    final current = snap?.draft;
    if (snap != null && current != null && snap.uid == uid && snap.key == key) {
      _sent[id] = _signature(
        LocalDraft(
          key: key,
          body: current.body,
          updatedAt: current.updatedAt,
          delta: current.delta,
          subject: current.subject,
        ),
      );
    }
    final offered = offer.value;
    if (offered != null && offered.uid == uid && offered.draft.key == key) {
      offer.value = null;
    }
    _store?.delete(uid, key);
  }

  /// Write what the editor holds and stop for good.
  void dispose() {
    if (_disposed) {
      return;
    }
    detach();
    _disposed = true;
    offer.dispose();
  }
}
