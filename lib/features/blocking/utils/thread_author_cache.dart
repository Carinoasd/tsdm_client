/// Author uid of threads, as far as the app has seen them, keyed by tid.
///
/// Filled from sources that name the thread author reliably: the author link of a thread row in a list (forum,
/// search, latest, homepage) and the first floor of a thread page. A thread opened directly on a later page (a
/// reply notice, a `findpost` link) does not show its first floor; the author recorded here, or the first page when
/// nothing is recorded, tells whether the thread belongs to a blocked user. Never filled from usernames.
///
/// In memory only and bounded: it is a cache of facts of the forum, not user data, and is the same for every account.
final class ThreadAuthorCache {
  ThreadAuthorCache._();

  /// Max number of threads kept.
  static const capacity = 4096;

  static final _authors = <int, int>{};

  /// Record that thread [tid] was started by [authorUid]; ignored when either is not a positive id.
  static void record(String? tid, String? authorUid) {
    final t = int.tryParse(tid ?? '');
    final a = int.tryParse(authorUid ?? '');
    if (t == null || t <= 0 || a == null || a <= 0) {
      return;
    }
    _authors
      ..remove(t)
      ..[t] = a;
    while (_authors.length > capacity) {
      _authors.remove(_authors.keys.first);
    }
  }

  /// Author uid of thread [tid], null when not known.
  static int? authorOf(String? tid) {
    final t = int.tryParse(tid ?? '');
    return t == null ? null : _authors[t];
  }

  /// Forget everything, for tests.
  static void clear() => _authors.clear();
}
