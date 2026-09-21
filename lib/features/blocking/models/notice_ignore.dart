import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/blocking/utils/forum_url.dart';

/// The notice type and author a notice's own "屏蔽" link points to.
///
/// Parsed only from the forum's ignore link in the `<dt>` of a notice node:
///
/// ```html
/// <a class="d b" href="home.php?mod=spacecp&amp;ac=common&amp;op=ignore&amp;authorid=1000&amp;type=post&amp;handlekey=noticeignore">屏蔽</a>
/// ```
@immutable
final class NoticeIgnoreTarget {
  /// Constructor.
  const NoticeIgnoreTarget({required this.type, required this.authorId});

  /// Notice type (`post`, `friend`, ...), as sent by the forum.
  final String type;

  /// Author uid, 0 for notices the forum itself sends (system notices).
  ///
  /// A system notice can only be ignored for everybody and never names a user to block.
  final int authorId;

  /// Whether the notice names a user as its author (not a system notice).
  bool get hasUserAuthor => authorId > 0;

  static final _typeRe = RegExp(r'^[0-9a-zA-Z_\-.]{1,32}$');

  /// Whether [type] is a notice type string the forum could have produced.
  static bool isValidType(String type) => _typeRe.hasMatch(type);

  /// Parse from the href of an ignore link, null if it is not exactly the forum's ignore operation.
  ///
  /// Never throws: malformed links give null.
  static NoticeIgnoreTarget? tryParse(String? href) {
    if (href == null) {
      return null;
    }
    final uri = Uri.tryParse(href.replaceAll('&amp;', '&'));
    if (uri == null || !isForumScript(uri, 'home.php')) {
      return null;
    }
    final q = safeQueryParameters(uri);
    if (q == null || q['mod'] != 'spacecp' || q['ac'] != 'common' || q['op'] != 'ignore') {
      return null;
    }
    final type = q['type'];
    final rawAuthor = q['authorid'] ?? '';
    final authorId = RegExp(r'^\d{1,10}$').hasMatch(rawAuthor) ? int.tryParse(rawAuthor) : null;
    if (type == null || !isValidType(type) || authorId == null || authorId < 0) {
      return null;
    }
    return NoticeIgnoreTarget(type: type, authorId: authorId);
  }

  @override
  bool operator ==(Object other) => other is NoticeIgnoreTarget && other.type == type && other.authorId == authorId;

  @override
  int get hashCode => Object.hash(type, authorId);
}

/// One server-side notice ignore rule (`filter_note` in the privacy settings): notices of [type] from [authorId],
/// or from everybody when [authorId] is 0.
@immutable
final class NoticeIgnoreRule {
  /// Constructor.
  const NoticeIgnoreRule({required this.type, required this.authorId, this.label});

  /// Parse the rule key `type|authorid` used by the forum.
  static NoticeIgnoreRule? tryParseKey(String key, {String? label}) {
    final parts = key.split('|');
    if (parts.length != 2 || !NoticeIgnoreTarget.isValidType(parts[0])) {
      return null;
    }
    final authorId = int.tryParse(parts[1]);
    if (authorId == null || authorId < 0) {
      return null;
    }
    return NoticeIgnoreRule(type: parts[0], authorId: authorId, label: label);
  }

  /// Notice type.
  final String type;

  /// Author uid, 0 for everybody.
  final int authorId;

  /// Text the forum shows next to the rule, if any.
  final String? label;

  /// Whether this rule ignores everybody.
  bool get everybody => authorId == 0;

  /// Key used by the forum.
  String get key => '$type|$authorId';

  @override
  bool operator ==(Object other) => other is NoticeIgnoreRule && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// Why a server notice ignore operation did not succeed.
enum NoticeIgnoreFailure {
  /// Request failed before anything was sent to the forum for writing (safe, nothing changed).
  network,

  /// The forum answered the guest page: session expired.
  notLoggedIn,

  /// The page belongs to another account than the one the action was started with.
  accountMismatch,

  /// Cloudflare or another interstitial page instead of the forum page.
  challenge,

  /// The forum answered an error message.
  forumError,

  /// The form is missing, incomplete or not the expected one, nothing was sent.
  unknownForm,

  /// The rule to remove is not in the list any more / the author to ignore is not offered by the form.
  ruleNotFound,

  /// The write request was sent but its result could not be confirmed (network error after sending, or the
  /// verification page did not show the expected state). The rule may or may not be changed on the forum.
  unknownAfterSubmit,
}

/// Result of a server notice ignore operation.
final class NoticeIgnoreResult {
  const NoticeIgnoreResult._(this.failure, this.rules, {this.alreadyApplied = false});

  /// Operation confirmed by reloading the rule list, or nothing to do ([alreadyApplied], nothing was sent).
  const NoticeIgnoreResult.success(List<NoticeIgnoreRule> rules, {bool alreadyApplied = false})
    : this._(null, rules, alreadyApplied: alreadyApplied);

  /// Operation failed.
  const NoticeIgnoreResult.failed(NoticeIgnoreFailure failure, {List<NoticeIgnoreRule>? rules})
    : this._(failure, rules);

  /// The forum already had the requested state; no write was sent.
  final bool alreadyApplied;

  /// Null on success.
  final NoticeIgnoreFailure? failure;

  /// Latest rules known, when available.
  final List<NoticeIgnoreRule>? rules;

  /// Whether succeeded.
  bool get isSuccess => failure == null;
}
