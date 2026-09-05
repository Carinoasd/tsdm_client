part of 'models.dart';

int? _jsonInt(Object? value) => switch (value) {
  final int v => v,
  final num v => v.toInt(),
  final String v => int.tryParse(v.trim()),
  _ => null,
};

bool _jsonFlag(Object? value) => switch (value) {
  final bool v => v,
  final num v => v != 0,
  final String v => v == '1' || v == 'true',
  _ => false,
};

/// Amount as the server shows it: integers without a trailing `.0`.
String? _jsonAmount(Object? value) => switch (value) {
  null => null,
  final int v => '$v',
  final num v => v == v.roundToDouble() ? '${v.toInt()}' : '$v',
  final String v => v.trim().isEmpty ? null : v.trim(),
  _ => '$value',
};

String? _jsonText(Object? value) {
  final text = value == null ? null : '$value'.trim();
  return text == null || text.isEmpty ? null : text;
}

/// State of a red packet told by the `open` endpoint.
enum RedPacketState {
  /// Can be claimed.
  open,

  /// Still open, and the current user already claimed a share (the server answers `claimed` instead of `open`).
  claimed,

  /// All shares taken.
  done,

  /// Withdrawn by the sender.
  withdrawn,

  /// Expired.
  expired,

  /// Closed.
  closed,

  /// Anything else.
  unknown;

  /// Parse the server value.
  static RedPacketState parse(String? value) => switch (value) {
    'open' => RedPacketState.open,
    'claimed' => RedPacketState.claimed,
    'done' => RedPacketState.done,
    'withdrawn' => RedPacketState.withdrawn,
    'expired' => RedPacketState.expired,
    'closed' => RedPacketState.closed,
    _ => RedPacketState.unknown,
  };
}

/// A red packet as answered by `plugin.php?id=hongbao:open&tid=TID`.
final class RedPacketInfo {
  /// Constructor.
  const RedPacketInfo({
    required this.tid,
    required this.from,
    required this.bless,
    required this.hasPassword,
    required this.splitMode,
    required this.unit,
    required this.state,
    required this.isSender,
    required this.claimed,
    this.claimedAmount,
    this.claimedBest = false,
  });

  /// Build from the `ok: true` answer.
  factory RedPacketInfo.fromJson(Map<String, dynamic> json) {
    final mine = json['mine'] is Map ? Map<String, dynamic>.from(json['mine'] as Map) : const <String, dynamic>{};
    return RedPacketInfo(
      tid: '${json['tid'] ?? ''}',
      from: _jsonText(json['from']) ?? '',
      bless: _jsonText(json['bless']) ?? '',
      hasPassword: _jsonFlag(json['haspw']),
      splitMode: _jsonInt(json['splitmode']) ?? 1,
      unit: _jsonText(json['unit']) ?? '',
      state: RedPacketState.parse(_jsonText(json['state'])),
      isSender: _jsonFlag(json['is_sender']),
      claimed: _jsonFlag(mine['claimed']),
      claimedAmount: _jsonAmount(mine['amount']),
      claimedBest: _jsonFlag(mine['best']),
    );
  }

  /// Thread id.
  final String tid;

  /// Sender text, e.g. "NAME 的紅包".
  final String from;

  /// Blessing text.
  final String bless;

  /// A password (口令) is required to claim.
  final bool hasPassword;

  /// 1: random amounts (拼手氣), 2: equal shares (均分).
  final int splitMode;

  /// Currency unit.
  final String unit;

  /// State.
  final RedPacketState state;

  /// The current user sent this packet.
  final bool isSender;

  /// The current user already claimed a share.
  final bool claimed;

  /// Amount the current user got, when [claimed].
  final String? claimedAmount;

  /// The current user got the best share, when [claimed].
  final bool claimedBest;

  /// Random amounts (拼手氣).
  bool get isRandom => splitMode == 1;
}

/// Answer of the `open` endpoint: the packet, or why it is not available.
final class RedPacketOpenResult {
  /// Constructor.
  const RedPacketOpenResult({this.info, this.error, this.needLogin = false});

  /// Parse the answer.
  factory RedPacketOpenResult.fromJson(Map<String, dynamic> json) {
    if (_jsonFlag(json['ok'])) {
      return RedPacketOpenResult(info: RedPacketInfo.fromJson(json));
    }
    return RedPacketOpenResult(error: _jsonText(json['error']), needLogin: _jsonFlag(json['need_login']));
  }

  /// The packet, null when not available.
  final RedPacketInfo? info;

  /// Reason told by the server, e.g. "這裡沒有紅包".
  final String? error;

  /// The server asked to login.
  final bool needLogin;
}

/// Answer of the `grab` endpoint.
final class RedPacketGrabResult {
  /// Constructor.
  const RedPacketGrabResult({
    required this.ok,
    this.amount,
    this.unit,
    this.isCat = false,
    this.best = false,
    this.already = false,
    this.state,
    this.error,
  });

  /// Parse the answer.
  factory RedPacketGrabResult.fromJson(Map<String, dynamic> json) => RedPacketGrabResult(
    ok: _jsonFlag(json['ok']),
    amount: _jsonAmount(json['amount']),
    unit: _jsonText(json['unit']),
    isCat: _jsonFlag(json['iscat']),
    best: _jsonFlag(json['best']),
    already: _jsonFlag(json['already']),
    state: _jsonText(json['state']),
    error: _jsonText(json['error']),
  );

  /// Claimed (right now, or [already] before).
  final bool ok;

  /// Amount claimed.
  final String? amount;

  /// Currency unit.
  final String? unit;

  /// The share was claimed earlier; the server repeats the amount with `ok: true`.
  final bool already;

  /// The web page plays a special animation for this share; nothing special in the app.
  final bool isCat;

  /// Best share.
  final bool best;

  /// Failure state: `badpw` (wrong password), `needreply` (reply first), `done` (all taken).
  final String? state;

  /// Reason told by the server.
  final String? error;

  /// Wrong password.
  bool get badPassword => state == 'badpw';

  /// The user must reply in the thread first.
  bool get needReply => state == 'needreply';

  /// All shares are taken.
  bool get allTaken => state == 'done';
}

/// One claimed share in the records (手氣榜).
final class RedPacketRecord {
  /// Constructor.
  const RedPacketRecord({required this.username, required this.time, required this.amount, required this.isBest});

  /// Parse one record.
  factory RedPacketRecord.fromJson(Map<String, dynamic> json) => RedPacketRecord(
    username: _jsonText(json['username']) ?? '',
    time: _jsonText(json['time']) ?? '',
    amount: _jsonAmount(json['amount']) ?? '',
    isBest: _jsonFlag(json['isbest']),
  );

  /// Who claimed.
  final String username;

  /// When, as the server formats it.
  final String time;

  /// How much.
  final String amount;

  /// Best share.
  final bool isBest;
}

/// Answer of the `record` endpoint.
final class RedPacketRecordsResult {
  /// Constructor.
  const RedPacketRecordsResult({this.claimed, this.shares, this.unit, this.records = const [], this.error});

  /// Parse the answer.
  factory RedPacketRecordsResult.fromJson(Map<String, dynamic> json) {
    if (!_jsonFlag(json['ok'])) {
      return RedPacketRecordsResult(error: _jsonText(json['error']) ?? 'unknown');
    }
    final recs = json['recs'];
    return RedPacketRecordsResult(
      claimed: _jsonInt(json['claimed']),
      shares: _jsonInt(json['shares']),
      unit: _jsonText(json['unit']),
      records: recs is List
          ? recs
                .whereType<Map<dynamic, dynamic>>()
                .map((e) => RedPacketRecord.fromJson(Map<String, dynamic>.from(e)))
                .toList()
          : const [],
    );
  }

  /// Shares claimed so far.
  final int? claimed;

  /// Total shares.
  final int? shares;

  /// Currency unit.
  final String? unit;

  /// Claimed shares.
  final List<RedPacketRecord> records;

  /// Reason when the records are not available, e.g. "開包後才能看大家的手氣".
  final String? error;
}

/// Answer of the `daily` endpoint.
final class DailyRedPacketResult {
  /// Constructor.
  const DailyRedPacketResult({required this.ok, this.amount, this.unit, this.already = false, this.error});

  /// Parse the answer.
  factory DailyRedPacketResult.fromJson(Map<String, dynamic> json) => DailyRedPacketResult(
    ok: _jsonFlag(json['ok']),
    amount: _jsonAmount(json['amount']),
    unit: _jsonText(json['unit']),
    already: _jsonFlag(json['already']),
    error: _jsonText(json['error']),
  );

  /// Claimed right now.
  final bool ok;

  /// Amount claimed (today, also when [already]).
  final String? amount;

  /// Currency unit.
  final String? unit;

  /// Already claimed today.
  final bool already;

  /// Reason told by the server.
  final String? error;
}
