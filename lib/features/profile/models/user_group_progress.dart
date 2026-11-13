import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// A credit-based user group of the forum with the credits it starts at.
final class UserGroupTier {
  /// Constructor.
  const UserGroupTier({required this.gid, required this.name, required this.creditsFrom});

  /// Group id.
  final int gid;

  /// Group name.
  final String name;

  /// The credits the group starts at.
  final int creditsFrom;
}

/// What one answer of `home.php?mod=spacecp&ac=usergroup` (with or without `gid`) says.
///
/// The page is the group comparison table of the forum: the main group of the member with the member's credits, and
/// the group asked for (the next one when no `gid` is given and the main group is a credit-based one) with, under
/// its name, either how many credits the member still needs to get there, or the credits it starts at when the
/// member has them already.
final class UserGroupPage {
  const UserGroupPage._({
    required this.uid,
    required this.mainGroupName,
    required this.credits,
    required this.viewedGroupName,
    required this.viewedGid,
    required this.viewedThreshold,
    required this.memberGroups,
    required this.extraGroups,
  });

  /// Read the page of plugin 4.0.0 [json] (`type: usergroup_info`, `schema` 54) as [parse] reads the web page: the main
  /// group (`main`), the group the table is about (`viewed`, null when the page has none) with the credits it starts
  /// at (`threshold`), and the menus of the credit-based groups (`upgrade`, the one viewed marked `active`) and of the
  /// member's own groups (`my`).
  factory UserGroupPage.fromApi(Map<String, dynamic> json) {
    final main = tsdmAppMap(json['main']);
    final viewed = tsdmAppMap(json['viewed']);
    final menus = tsdmAppList(json['menus']);
    List<Map<String, dynamic>> menu(String key) => [
      for (final m in menus)
        if (m['key'] == key) ...tsdmAppList(m['groups']),
    ];
    List<({int gid, String name})> groups(String key) => [
      for (final g in menu(key))
        if (tsdmAppInt(g['gid']) case final gid when gid > 0 && tsdmAppText(g['title']).trim().isNotEmpty)
          (gid: gid, name: tsdmAppText(g['title']).trim()),
    ];
    final viewedName = tsdmAppText(viewed['title']).trim();
    final threshold = viewed['threshold'];
    return UserGroupPage._(
      uid: tsdmAppInt(json['uid']),
      mainGroupName: tsdmAppText(main['title']).trim(),
      credits: tsdmAppInt(main['credits']),
      viewedGroupName: viewedName.isEmpty ? null : viewedName,
      viewedGid: menu('upgrade').where((g) => g['active'] == 1).map((g) => tsdmAppInt(g['gid'])).firstOrNull,
      viewedThreshold: viewed.isEmpty || threshold is! num ? null : threshold.toInt(),
      memberGroups: groups('upgrade'),
      extraGroups: groups('my'),
    );
  }

  /// Uid of the account the forum served the page to (`discuz_uid`), 0 for a guest; null when the page has none.
  final int? uid;

  /// Name of the main group of the member.
  final String mainGroupName;

  /// Credits of the member.
  final int credits;

  /// Name of the group the table is about, null when the page has none (a special or the highest main group).
  final String? viewedGroupName;

  /// Group id of the group the table is about, null when the menu does not mark it.
  final int? viewedGid;

  /// The credits the viewed group starts at, null when the page does not say.
  final int? viewedThreshold;

  /// Every credit-based group of the menu in the forum's order, with the credits not known yet.
  final List<({int gid, String name})> memberGroups;

  /// Groups of the member besides the main one (the menu of the member's groups; they can not be switched here).
  final List<({int gid, String name})> extraGroups;

  /// Read the answer [html], null when it is not that page.
  static UserGroupPage? parse(String html) {
    final document = parseHtmlDocument(html);
    final mainTitle = document.querySelector('th.c0 h4')?.text?.trim();
    if (mainTitle == null || mainTitle.isEmpty) {
      return null;
    }
    final uidMatch = RegExp(r"discuz_uid\s*=\s*'(\d+)'").firstMatch(html);
    final credits = _firstInt(document.querySelector('th.alt:not(.h) span.notice')?.text);
    if (credits == null) {
      return null;
    }
    final viewedTitle = document.querySelector('ul#tba li')?.text?.trim();
    final notice = document.querySelector('div.tscr th.alt.h span.notice');

    List<({int gid, String name})> menu(String id) => [
      for (final a in document.querySelectorAll('#$id a'))
        if (_gidOf(a.attributes['href']) case final gid? when (a.text ?? '').trim().isNotEmpty)
          (gid: gid, name: a.text!.trim()),
    ];

    final memberGroups = menu('gupgrade_menu');
    final viewedAnchor = document
        .querySelectorAll('#gupgrade_menu a')
        .where((a) => a.classes.contains('xi1'))
        .firstOrNull;
    return UserGroupPage._(
      uid: uidMatch == null ? null : int.tryParse(uidMatch.group(1)!),
      mainGroupName: _afterDash(mainTitle),
      credits: credits,
      viewedGroupName: viewedTitle == null || viewedTitle.isEmpty ? null : _afterDash(viewedTitle),
      viewedGid: viewedAnchor == null ? null : _gidOf(viewedAnchor.attributes['href']),
      viewedThreshold: _thresholdOf(notice, credits),
      memberGroups: memberGroups,
      extraGroups: menu('gmy_menu'),
    );
  }

  /// The text after the first " - " of a heading such as `会员用户组 - 金牌会员`.
  static String _afterDash(String title) {
    final index = title.indexOf(' - ');
    return (index < 0 ? title : title.substring(index + 3)).trim();
  }

  static int? _gidOf(String? href) {
    final match = href == null ? null : RegExp(r'[?&]gid=(\d+)').firstMatch(href);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static int? _firstInt(String? text) {
    final match = text == null ? null : RegExp(r'-?\d+').firstMatch(text);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  /// The credits the group starts at, from the notice of its table: the number before the unit (an inner `span`) is
  /// what is still missing ("还需 300 积分"), the number after it is the start itself ("积分 1000"). Lets the
  /// text around stay in any language.
  static int? _thresholdOf(uh.Element? notice, int credits) {
    if (notice == null) {
      return null;
    }
    final unitIndex = notice.nodes.indexWhere((n) => n is uh.Element);
    var before = '';
    var after = '';
    for (final (i, node) in notice.nodes.indexed) {
      if (node is uh.Element) {
        continue;
      }
      if (unitIndex < 0 || i < unitIndex) {
        before += node.text ?? '';
      } else {
        after += node.text ?? '';
      }
    }
    if (unitIndex >= 0) {
      if (_firstInt(before) case final missing?) {
        return credits + missing;
      }
      if (_firstInt(after) case final start?) {
        return start;
      }
      return null;
    }
    // No unit element to tell the two apart: not read rather than guessed.
    return null;
  }
}

/// How far the member is from the next credit-based user group.
final class UserGroupProgress {
  /// Constructor.
  const UserGroupProgress({
    required this.mainGroupName,
    required this.credits,
    required this.currentFrom,
    required this.nextName,
    required this.nextFrom,
    this.currentGid,
    this.tiers = const [],
    this.extraGroups = const [],
  });

  /// Name of the main group.
  final String mainGroupName;

  /// Credits of the member.
  final int credits;

  /// The credits the main group starts at, null when not known.
  final int? currentFrom;

  /// Group id of the main group, null when not known.
  final int? currentGid;

  /// Name of the next group.
  final String nextName;

  /// The credits the next group starts at.
  final int nextFrom;

  /// Every credit-based group by the credits it starts at; only filled by the detail page.
  final List<UserGroupTier> tiers;

  /// Names of the other groups of the member.
  final List<String> extraGroups;

  /// Credits still missing, never negative.
  int get creditsLeft => nextFrom > credits ? nextFrom - credits : 0;

  /// How far the member is from the start of the current group to the start of the next, between 0 and 1.
  double get fraction {
    final from = (currentFrom ?? 0) < 0 ? 0 : (currentFrom ?? 0);
    final span = nextFrom - from;
    if (span <= 0) {
      return 1;
    }
    return ((credits - from) / span).clamp(0.0, 1.0);
  }

  /// A copy with the detail fields.
  UserGroupProgress withDetail({required List<UserGroupTier> tiers, required List<String> extraGroups}) =>
      UserGroupProgress(
        mainGroupName: mainGroupName,
        credits: credits,
        currentFrom: currentFrom,
        currentGid: currentGid,
        nextName: nextName,
        nextFrom: nextFrom,
        tiers: tiers,
        extraGroups: extraGroups,
      );
}
