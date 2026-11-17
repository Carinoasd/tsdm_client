import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show immutable;

/// A shortcut handed over by a native side ([ShortcutTarget.requestOf]): `external` when a link from outside the app
/// asked for it.
typedef AppShortcutRequest = ({ShortcutTarget shortcut, bool external});

/// What a shortcut opens: one of the app icon's shortcuts and the widget's taps ([AppShortcut]), or a forum or a
/// thread pinned to the home screen ([PinnedShortcut], Android).
///
/// Both come as `tsdm://shortcut/<id>`, the data of the shortcut's intent: the native `ShortcutsHandler` (Android) hands
/// the id over when the app's own shortcut sent it, the link when another app did.
@immutable
sealed class ShortcutTarget {
  const ShortcutTarget();

  /// The scheme of the shortcut links.
  static const linkScheme = 'tsdm';

  /// The host of the shortcut links.
  static const linkHost = 'shortcut';

  /// The shortcut id, the last segment of its link.
  String get id;

  /// The link opening this shortcut.
  String get link => '$linkScheme://$linkHost/$id';

  /// The shortcut [id] names, null for an id the app does not know.
  static ShortcutTarget? fromId(String? id) => AppShortcut.fromId(id) ?? PinnedShortcut.fromId(id);

  /// The id of [link], `tsdm://shortcut/<id>`; null for another link.
  static String? idOfLink(String? link) {
    final uri = link == null ? null : Uri.tryParse(link);
    if (uri == null || uri.scheme.toLowerCase() != linkScheme || uri.host.toLowerCase() != linkHost) {
      return null;
    }
    final segments = uri.pathSegments.where((e) => e.isNotEmpty).toList();
    return segments.length == 1 ? segments.single : null;
  }

  /// The shortcut a native side handed over, and whether a link opened from outside the app asked for it.
  ///
  /// An id is a shortcut of the app itself: a launcher shortcut, a forum or thread pinned to the home screen or a tap
  /// on the widget, carrying the app's key (Android's `ShortcutsHandler`, `ShortcutKey`), a quick action or a tap on
  /// the widget, its link signed (iOS `HomeWidgetBridge`). A link (`tsdm://shortcut/<id>`) is one another app sent to
  /// the exported activity (Android) or any web page or app opened (iOS registers the scheme): `external`.
  static AppShortcutRequest? requestOf(String? value) {
    if (fromId(value) case final shortcut?) {
      return (shortcut: shortcut, external: false);
    }
    if (fromId(idOfLink(value)) case final shortcut?) {
      return (shortcut: shortcut, external: true);
    }
    return null;
  }
}

/// A shortcut of a long press on the app icon (Android: `android/app/src/main/res/xml/shortcuts.xml`; iOS: the
/// `UIApplicationShortcutItems` of `ios/Runner/Info.plist`), or a tap on the home screen widget.
///
/// The id is the last segment of the `tsdm://shortcut/<id>` data of the shortcut's intent, handed over by the native
/// `ShortcutsHandler` (Android). On iOS the widget opens the same link and a quick action's type is that link, which
/// `HomeWidgetBridge` hands over whole ([fromLink]).
enum AppShortcut implements ShortcutTarget {
  /// Check in for today.
  checkin('checkin'),

  /// The notifications and messages.
  notice('notice'),

  /// The favorites of the account in use.
  favorite('favorite'),

  /// Search the forum.
  search('search')
  ;

  const AppShortcut(this.id);

  /// The shortcut id, as in `shortcuts.xml`.
  @override
  final String id;

  /// The scheme of the shortcut links.
  static const String linkScheme = ShortcutTarget.linkScheme;

  /// The host of the shortcut links.
  static const String linkHost = ShortcutTarget.linkHost;

  /// The shortcut with [id], null for an id the app does not know.
  static AppShortcut? fromId(String? id) => values.firstWhereOrNull((e) => e.id == id);

  /// The shortcut of [link], `tsdm://shortcut/<id>`; null for another link or an id the app does not know.
  static AppShortcut? fromLink(String? link) => fromId(ShortcutTarget.idOfLink(link));

  /// The shortcut a native side handed over: an id (Android) or a link (iOS).
  static AppShortcut? fromIdOrLink(String? value) => fromId(value) ?? fromLink(value);

  /// [ShortcutTarget.requestOf] for the shortcuts of the app icon only.
  static AppShortcutRequest? requestOf(String? value) {
    if (fromId(value) case final shortcut?) {
      return (shortcut: shortcut, external: false);
    }
    if (fromLink(value) case final shortcut?) {
      return (shortcut: shortcut, external: true);
    }
    return null;
  }

  /// The link opening this shortcut.
  @override
  String get link => '$linkScheme://$linkHost/$id';
}

/// A forum or a thread pinned to the home screen (Android's `PinnedShortcuts`, "add to home screen" of the menus of the
/// forum and the thread pages): `forum-<fid>` or `thread-<tid>`, the id the launcher knows it by, so pinning the same
/// one again updates it.
///
/// It only opens its page: from another app's link as well, which any app can do with a link of the forum already.
sealed class PinnedShortcut extends ShortcutTarget {
  const PinnedShortcut();

  /// `forum-<fid>` or `thread-<tid>`, a positive id of at most ten digits without a leading zero: what a route takes.
  static final _idRe = RegExp(r'^(forum|thread)-([1-9][0-9]{0,9})$');

  /// The forum or thread [id] names, null for any other id.
  static PinnedShortcut? fromId(String? id) {
    final match = id == null ? null : _idRe.firstMatch(id);
    if (match == null) {
      return null;
    }
    final value = int.parse(match.group(2)!);
    return match.group(1) == 'forum' ? PinnedForum(value) : PinnedThread(value);
  }
}

/// A forum pinned to the home screen.
final class PinnedForum extends PinnedShortcut {
  /// Constructor.
  const PinnedForum(this.fid);

  /// The forum [fid] names (a route's id), null when it is no forum id.
  static PinnedForum? tryParse(String? fid) => switch (PinnedShortcut.fromId('forum-$fid')) {
    final PinnedForum forum => forum,
    _ => null,
  };

  /// The forum id.
  final int fid;

  @override
  String get id => 'forum-$fid';

  @override
  bool operator ==(Object other) => other is PinnedForum && other.fid == fid;

  @override
  int get hashCode => Object.hash(PinnedForum, fid);

  @override
  String toString() => 'PinnedForum($fid)';
}

/// A thread pinned to the home screen.
final class PinnedThread extends PinnedShortcut {
  /// Constructor.
  const PinnedThread(this.tid);

  /// The thread [tid] names (a route's id), null when it is no thread id.
  static PinnedThread? tryParse(String? tid) => switch (PinnedShortcut.fromId('thread-$tid')) {
    final PinnedThread thread => thread,
    _ => null,
  };

  /// The thread id.
  final int tid;

  @override
  String get id => 'thread-$tid';

  @override
  bool operator ==(Object other) => other is PinnedThread && other.tid == tid;

  @override
  int get hashCode => Object.hash(PinnedThread, tid);

  @override
  String toString() => 'PinnedThread($tid)';
}
