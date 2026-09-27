import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/blocking/utils/forum_url.dart';

/// Why an operation on the website blacklist (the forum's `blockuser` plugin) did not succeed.
///
/// This is neither the Discuz friend blacklist nor the notice ignore rules, and not the local block list.
enum WebsiteBlocklistFailure {
  /// Request failed before anything was written.
  network,

  /// The forum answered the guest page: session expired.
  notLoggedIn,

  /// The page belongs to another account than the one the action was started with.
  accountMismatch,

  /// Cloudflare or another interstitial page instead of the forum page.
  challenge,

  /// The forum answered an error message (see [WebsiteBlocklistError.message]), e.g. the list is full.
  forumError,

  /// The page or the form is not one this app understands; nothing was sent.
  unsupported,

  /// The page or the form names another user than the one chosen; nothing was sent.
  targetMismatch,

  /// The lookup found no member for the uid.
  notFound,

  /// The user to remove is not on the list any more.
  notListed,

  /// The write was sent but the reloaded list does not confirm it (or could not be read).
  unknownAfterSubmit,
}

/// A failure with the forum's own message when it gave one.
@immutable
final class WebsiteBlocklistError {
  /// Constructor.
  const WebsiteBlocklistError(this.failure, {this.message});

  /// Kind.
  final WebsiteBlocklistFailure failure;

  /// Text of the forum's error message, for display only (never logged).
  final String? message;

  @override
  String toString() => 'WebsiteBlocklistError($failure)';
}

/// One user on the website blacklist.
@immutable
final class WebsiteBlockedUser {
  /// Constructor.
  const WebsiteBlockedUser({required this.uid, required this.username, required this.removable});

  /// Uid of the blocked user.
  final int uid;

  /// Name shown by the forum, may be empty.
  final String username;

  /// Whether the page offers a remove form for exactly this user that this app understands.
  final bool removable;

  /// Name for display: the forum's name, or the uid when the forum shows none.
  String get displayName => username.isEmpty ? 'UID $uid' : username;
}

/// Quota of the website blacklist as printed on the page; each part is null when the page does not show it.
@immutable
final class WebsiteBlocklistQuota {
  /// Constructor.
  const WebsiteBlocklistQuota({this.used, this.limit});

  /// Number of users on the list according to the page.
  final int? used;

  /// Most users the list may hold.
  final int? limit;
}

/// Website blacklist of one account as read from one page.
@immutable
final class WebsiteBlocklist {
  /// Constructor.
  WebsiteBlocklist({required this.ownerUid, required List<WebsiteBlockedUser> rows, required this.complete, this.quota})
    : rows = List.unmodifiable(rows),
      uids = Set.unmodifiable(rows.map((e) => e.uid));

  /// Account the list belongs to.
  final int ownerUid;

  /// Users in page order.
  final List<WebsiteBlockedUser> rows;

  /// Uids of [rows].
  final Set<int> uids;

  /// Quota printed on the page, null when none was recognised.
  final WebsiteBlocklistQuota? quota;

  /// Whether the page holds the whole list: false when it is split into pages, when it prints no count, or when its
  /// count does not match the rows.
  ///
  /// Only a complete list can be imported from, can be called empty, and proves that a user is not on it.
  final bool complete;

  /// Whether [uid] is on the list.
  bool contains(int uid) => uids.contains(uid);

  /// Row of [uid], null when absent.
  WebsiteBlockedUser? rowOf(int uid) => rows.where((e) => e.uid == uid).firstOrNull;
}

/// Answer of the read-only member lookup (`bu_q`).
@immutable
final class WebsiteBlocklistLookup {
  /// Constructor.
  const WebsiteBlocklistLookup({
    required this.uid,
    required this.username,
    required this.alreadyListed,
    required this.canAdd,
  });

  /// Uid of the member returned by the forum, always the one asked for.
  final int uid;

  /// Name of the member returned by the forum, may be empty.
  final String username;

  /// Whether the member is already on the website blacklist.
  final bool alreadyListed;

  /// Whether the page offers an add form for exactly this member that this app understands.
  final bool canAdd;

  /// Name for display.
  String get displayName => username.isEmpty ? 'UID $uid' : username;
}

/// Result of an add or a remove.
@immutable
final class WebsiteBlocklistWrite {
  /// Confirmed by the reloaded [list], or nothing to do ([alreadyApplied], nothing was sent).
  const WebsiteBlocklistWrite.success({required this.list, this.alreadyApplied = false})
    : error = null,
      sent = !alreadyApplied;

  /// Failed; [list] is the list read last, when there is one. [sent] tells whether the write was sent.
  const WebsiteBlocklistWrite.failed(WebsiteBlocklistError this.error, {this.list, this.sent = false})
    : alreadyApplied = false;

  /// Null on success.
  final WebsiteBlocklistError? error;

  /// Latest list read, null when it could not be read.
  final WebsiteBlocklist? list;

  /// The list already had the requested state: no write was sent.
  final bool alreadyApplied;

  /// Whether the write request was started: it may have reached the forum even when it failed.
  final bool sent;

  /// Whether succeeded.
  bool get isSuccess => error == null;
}

final _decimalUidRe = RegExp(r'^[1-9]\d{0,9}$');
final _spaceUidPathRe = RegExp(r'^space-uid-([1-9]\d{0,9})\.html$');

/// [text] as a uid: plain decimal digits without sign, leading zero, `0x` or spaces, from 1 to 2^31-1. Null otherwise.
int? parseStrictUid(String? text) {
  if (text == null || !_decimalUidRe.hasMatch(text)) {
    return null;
  }
  final uid = int.parse(text);
  return uid <= 0x7fffffff ? uid : null;
}

/// Uid of a forum profile link [href] (`home.php?mod=space&uid=N`, maybe relative, or `space-uid-N.html`), with the
/// same strict uid rules as a typed uid ([parseStrictUid]). Null for another host or path, for a repeated query
/// parameter (`uid=1&uid=2`, `mod=space&mod=x`: the forum and this check could read different values) and for a
/// malformed query.
int? parseStrictProfileUid(String? href) {
  if (href == null || href.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(href.replaceAll('&amp;', '&'));
  if (uri == null || !isForumUri(uri)) {
    return null;
  }
  if (isForumScript(uri, 'home.php')) {
    final Map<String, List<String>> query;
    try {
      query = uri.queryParametersAll;
    } on FormatException {
      return null;
    }
    if (query.values.any((e) => e.length != 1) || query['mod']?.single != 'space') {
      return null;
    }
    return parseStrictUid(query['uid']?.single);
  }
  if (uri.pathSegments.length != 1 || uri.hasQuery) {
    return null;
  }
  return parseStrictUid(_spaceUidPathRe.firstMatch(uri.pathSegments.single)?.group(1));
}

/// The uid the user typed: a positive decimal uid or an absolute forum profile link (`home.php?mod=space&uid=N`,
/// `space-uid-N.html`, on the forum's own hosts only), both read by the same strict rules. Null for anything else.
int? parseWebsiteBlocklistTarget(String input) {
  final text = input.trim();
  if (text.isEmpty) {
    return null;
  }
  if (RegExp(r'^\d+$').hasMatch(text)) {
    return parseStrictUid(text);
  }
  // A link without a scheme would be read as a relative path: only absolute links are accepted.
  if (!text.startsWith('https://') && !text.startsWith('http://')) {
    return null;
  }
  return parseStrictProfileUid(text);
}
