import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

final _space = RegExp(r'\s+');

String _line(Object? value) => tsdmAppText(value).replaceAll(_space, ' ').trim();

/// The lists of the account's magic item log (`home.php?mod=magic&action=log&operation=…`), in tab order.
enum MagicLogTab {
  /// Items used (`uselog`).
  use('uselog'),

  /// Items bought (`buylog`).
  buy('buylog'),

  /// Items given to others (`givelog`).
  give('givelog'),

  /// Items received from others (`receivelog`).
  receive('receivelog')
  ;

  const MagicLogTab(this.operation);

  /// The `operation` query value of the list.
  final String operation;

  /// Page [page] of the list.
  String url([int page = 1]) =>
      '$baseUrl/home.php?mod=magic&action=log&operation=$operation${page > 1 ? '&page=$page' : ''}';
}

/// What a used item was used on (`target` of a `uselog` row).
enum MagicLogTargetKind {
  /// A member.
  user,

  /// A thread.
  thread,

  /// A post.
  post,

  /// The item was sold back.
  sold,

  /// The item was dropped.
  dropped,
}

/// What a used item was used on.
final class MagicLogTarget {
  /// Constructor.
  const MagicLogTarget(this.kind, [this.id = 0]);

  /// What it is.
  final MagicLogTargetKind kind;

  /// The member, thread or post.
  final int id;

  /// The forum's page of it, built from [kind] and [id]; null for a sold or dropped item.
  String? get url => switch (kind) {
    MagicLogTargetKind.user => '$baseUrl/home.php?mod=space&uid=$id',
    MagicLogTargetKind.thread => '$baseUrl/forum.php?mod=viewthread&tid=$id',
    MagicLogTargetKind.post => '$baseUrl/forum.php?mod=redirect&pid=$id&goto=findpost',
    MagicLogTargetKind.sold || MagicLogTargetKind.dropped => null,
  };
}

/// One row of the log.
final class MagicLogEntry {
  /// Constructor.
  const MagicLogEntry({
    required this.magicId,
    required this.name,
    this.time,
    this.amount,
    this.price,
    this.creditTitle = '',
    this.creditUnit = '',
    this.target,
    this.userId,
    this.username = '',
  });

  /// The item.
  final int magicId;

  /// Its name.
  final String name;

  /// When (the forum's wall clock), null when the forum could not tell (`dateline` 0).
  final DateTime? time;

  /// How many (bought, given, received).
  final int? amount;

  /// The price of one when bought.
  final int? price;

  /// The credit it was bought with.
  final String creditTitle;

  /// The unit of that credit.
  final String creditUnit;

  /// What it was used on, null when the forum prints nothing.
  final MagicLogTarget? target;

  /// Who it was given to, or who gave it.
  final int? userId;

  /// Their name.
  final String username;
}

/// A page of one list of the log.
final class MagicLogList {
  /// Constructor.
  const MagicLogList({required this.tab, required this.entries, required this.page, required this.pages});

  /// The list.
  final MagicLogTab tab;

  /// Its rows on this page.
  final List<MagicLogEntry> entries;

  /// This page.
  final int page;

  /// How many pages.
  final int pages;
}

MagicLogTarget? _targetOf(Object? value) {
  final map = tsdmAppMap(value);
  final id = tsdmAppInt(map['id']);
  return switch (map['type']) {
    'uid' when id > 0 => MagicLogTarget(MagicLogTargetKind.user, id),
    'tid' when id > 0 => MagicLogTarget(MagicLogTargetKind.thread, id),
    'pid' when id > 0 => MagicLogTarget(MagicLogTargetKind.post, id),
    'sell' => const MagicLogTarget(MagicLogTargetKind.sold),
    'drop' => const MagicLogTarget(MagicLogTargetKind.dropped),
    _ => null,
  };
}

/// A page of the log list [tab] of the forum's app API (plugin 4.0.0: `type: magic_log`, `schema` 71).
MagicLogList magicLogPageFromApi(Map<String, dynamic> json, MagicLogTab tab) {
  final offset = tsdmAppTimeOffset(json);
  final entries = <MagicLogEntry>[];
  for (final row in tsdmAppList(json['list'])) {
    final name = _line(row['name']);
    if (name.isEmpty) continue;
    final credit = tsdmAppMap(row['credit']);
    final user = tsdmAppMap(row['user']);
    final userId = tsdmAppInt(user['uid']);
    entries.add(
      MagicLogEntry(
        magicId: tsdmAppInt(row['magicid']),
        name: name,
        time: tsdmAppWallClockTime(row['dateline'], offset),
        amount: tab == MagicLogTab.use ? null : tsdmAppInt(row['amount']),
        price: tab == MagicLogTab.buy ? tsdmAppInt(row['price']) : null,
        creditTitle: _line(credit['title']),
        creditUnit: _line(credit['unit']),
        target: tab == MagicLogTab.use ? _targetOf(row['target']) : null,
        userId: userId > 0 ? userId : null,
        username: _line(user['username']),
      ),
    );
  }
  final page = tsdmAppInt(json['page']);
  final pages = tsdmAppInt(json['pages']);
  return MagicLogList(
    tab: tab,
    entries: entries,
    page: page > 0 ? page : 1,
    pages: pages > 0 ? pages : 1,
  );
}
