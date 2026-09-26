import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

/// Find only the forum's own checknewpm script, never execute arbitrary page JavaScript.
///
/// Discuz uses this request for both its unread-PM check and the `daylogin` credit rule (#111).
Uri? dailyVisitUri(uh.Document document) {
  final base = Uri.parse(baseUrl);
  for (final script in document.querySelectorAll('script[src]')) {
    final source = Uri.tryParse(script.attributes['src'] ?? '');
    if (source == null) continue;
    final uri = base.resolveUri(source);
    final params = uri.queryParametersAll;
    if (uri.scheme != base.scheme ||
        uri.origin != base.origin ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.path != '/home.php') {
      continue;
    }
    if (params.values.any((v) => v.length != 1) ||
        params.keys.any((k) => !{'mod', 'ac', 'op', 'rand'}.contains(k)) ||
        uri.queryParameters['mod'] != 'spacecp' ||
        uri.queryParameters['ac'] != 'pm' ||
        uri.queryParameters['op'] != 'checknewpm') {
      continue;
    }
    return uri;
  }
  return null;
}

/// Foreground homepage rewards, scoped to the identity that fetched the page.
///
/// The server decides eligibility and amounts. A restart checks its fresh page again; it never invents credits
/// or persists a failed claim as success. Local state only deduplicates concurrent/rapid requests in this session.
final class DailyRewardsRepository with LoggerMixin {
  /// [now] is used for short retry throttles, not to decide the forum's reward day.
  DailyRewardsRepository({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _pending = <int, Future<bool>>{};
  final _visitAttempts = <int, DateTime>{};
  final _packetAttempts = <int, (String, DateTime)>{};
  final _claimedDays = <int, String>{};

  bool _recent(DateTime? previous) =>
      previous != null && _now().difference(previous).abs() < const Duration(minutes: 1);

  /// Return whether the homepage should be fetched once more to update balances/claim availability.
  Future<bool> process({
    required uh.Document document,
    required int? uid,
    required bool Function() isCurrent,
    required bool Function() autoClaimEnabled,
    required Future<bool> Function(Uri) visit,
    required Future<DailyRedPacketResult?> Function(String formHash) claim,
  }) async {
    if (uid == null || uid <= 0 || !isCurrent() || parseLoggedUidFromDocument(document) != uid) return false;
    if (_pending[uid] case final pending?) return pending;
    final pending = _process(
      document: document,
      uid: uid,
      isCurrent: isCurrent,
      autoClaimEnabled: autoClaimEnabled,
      visit: visit,
      claim: claim,
    );
    _pending[uid] = pending;
    try {
      return await pending;
    } finally {
      _pending.removeWhere((key, _) => key == uid);
    }
  }

  Future<bool> _process({
    required uh.Document document,
    required int uid,
    required bool Function() isCurrent,
    required bool Function() autoClaimEnabled,
    required Future<bool> Function(Uri) visit,
    required Future<DailyRedPacketResult?> Function(String formHash) claim,
  }) async {
    var refresh = false;
    final visitUri = dailyVisitUri(document);
    if (visitUri != null && !_recent(_visitAttempts[uid]) && isCurrent()) {
      _visitAttempts[uid] = _now();
      try {
        refresh = await visit(visitUri);
      } on Object {
        warning('daily visit check failed; keep the homepage available');
      }
    }

    final packet = parseDailyRedPacketConfig(document);
    final formHash = parseFormHash(document);
    final previous = _packetAttempts[uid];
    if (packet != null &&
        RegExp(r'^\d{8}$').hasMatch(packet.dateFlag) &&
        formHash != null &&
        _claimedDays[uid] != packet.dateFlag &&
        !(previous?.$1 == packet.dateFlag && _recent(previous?.$2)) &&
        isCurrent() &&
        autoClaimEnabled()) {
      _packetAttempts[uid] = (packet.dateFlag, _now());
      try {
        final result = await claim(formHash);
        if (isCurrent() && result != null && (result.ok || result.already)) {
          _claimedDays[uid] = packet.dateFlag;
          refresh = true;
        }
      } on Object {
        warning('automatic daily red packet failed; manual claim remains available');
      }
    }
    return isCurrent() && refresh;
  }
}
