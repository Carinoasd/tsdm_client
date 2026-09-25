import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/repository/daily_rewards_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

const _visit = 'home.php?mod=spacecp&amp;ac=pm&amp;op=checknewpm&amp;rand=123';
String _page({int uid = 1000, String day = '20260925', bool packet = true, String? visit = _visit}) =>
    '''
<script>var discuz_uid = '$uid';</script>
<input name="formhash" value="XXXXXXXX">
${visit == null ? '' : '<script src="$visit"></script>'}
${packet ? '<script>hongbaoDailyInit({"entry":2,"dateflag":"$day"});</script>' : ''}
''';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('recognizes the actual forum fixture checknewpm callback', () {
    final uri = dailyVisitUri(parseHtmlDocument(File('test/data/forum_index_x5.html').readAsStringSync()));
    expect(uri?.origin, Uri.parse(baseUrl).origin);
    expect(uri?.path, '/home.php');
    expect(uri?.queryParameters['op'], 'checknewpm');
  });

  for (final source in [
    'https://example.com/$_visit',
    'javascript:alert(1)',
    'data:text/javascript,alert(1)',
    'home.php?mod=spacecp&amp;ac=pm&amp;op=delete',
    '$_visit&amp;op=delete',
    '$_visit&amp;delete=1',
    '$_visit#extra',
    '${baseUrl.replaceFirst('https://', 'https://user@')}/$_visit',
  ]) {
    test('does not request untrusted or unrelated script: $source', () {
      expect(dailyVisitUri(parseHtmlDocument(_page(visit: source))), isNull);
    });
  }

  late DailyRewardsRepository repo;
  late DateTime now;
  late int visits;
  late int claims;
  late bool current;
  late bool enabled;
  late Future<bool> Function(Uri) visit;
  late Future<DailyRedPacketResult?> Function(String) claim;

  setUp(() {
    now = DateTime(2026, 9, 25);
    repo = DailyRewardsRepository(now: () => now);
    visits = 0;
    claims = 0;
    current = true;
    enabled = true;
    visit = (_) async {
      visits++;
      return true;
    };
    claim = (hash) async {
      expect(hash, 'XXXXXXXX');
      claims++;
      return DailyRedPacketResult.fromJson({'ok': true, 'amount': 5});
    };
  });

  Future<bool> run({int? uid = 1000, String? html}) => repo.process(
    document: parseHtmlDocument(html ?? _page()),
    uid: uid,
    isCurrent: () => current,
    autoClaimEnabled: () => enabled,
    visit: visit,
    claim: claim,
  );

  test('guests, wrong account pages and expired identities do nothing', () async {
    expect(await run(uid: null), isFalse);
    expect(await run(uid: 1001), isFalse);
    expect(await run(html: _page(uid: 0)), isFalse);
    current = false;
    expect(await run(), isFalse);
    expect((visits, claims), (0, 0));
  });

  test('visit credits work independently of the red packet switch', () async {
    enabled = false;
    expect(await run(), isTrue);
    expect((visits, claims), (1, 0));
    enabled = true;
    expect(await run(), isTrue);
    expect((visits, claims), (1, 1));
  });

  test('claim once per account and server day, without relying on local midnight', () async {
    await run();
    now = now.add(const Duration(days: 2));
    await run();
    expect(claims, 1);
    await run(html: _page(day: '20260926'));
    expect(claims, 2);
    await run(uid: 1001, html: _page(uid: 1001));
    expect(claims, 3);
  });

  test('already claimed is terminal for that forum day', () async {
    claim = (_) async {
      claims++;
      return DailyRedPacketResult.fromJson({'ok': false, 'already': 1});
    };
    expect(await run(), isTrue);
    now = now.add(const Duration(minutes: 2));
    await run();
    expect(claims, 1);
  });

  test('failed requests are throttled briefly, then can retry', () async {
    visit = (_) async {
      visits++;
      throw StateError('offline');
    };
    claim = (_) async {
      claims++;
      return null;
    };
    expect(await run(), isFalse);
    expect(await run(), isFalse);
    expect((visits, claims), (1, 1));
    now = now.add(const Duration(minutes: 1));
    await run();
    expect((visits, claims), (2, 2));
  });

  test('concurrent homepage callers do not duplicate requests', () async {
    final pending = Completer<bool>();
    visit = (_) {
      visits++;
      return pending.future;
    };
    final first = run();
    final second = run();
    pending.complete(true);
    expect(await Future.wait([first, second]), [true, true]);
    expect((visits, claims), (1, 1));
  });

  test('account switch or disabling during visit prevents claim', () async {
    visit = (_) async {
      current = false;
      return true;
    };
    expect(await run(), isFalse);
    expect(claims, 0);
    current = true;
    now = now.add(const Duration(minutes: 2));
    visit = (_) async {
      enabled = false;
      return true;
    };
    await run();
    expect(claims, 0);
  });

  test('missing config or formhash keeps manual availability and makes no claim', () async {
    await run(html: _page(packet: false));
    await run(html: _page().replaceAll('<input name="formhash" value="XXXXXXXX">', ''));
    await run(html: _page(day: 'invalid'));
    expect(claims, 0);
  });

  test('claim exception does not discard successful visit or poison next retry', () async {
    claim = (_) async {
      claims++;
      throw StateError('offline');
    };
    expect(await run(), isTrue);
    now = now.add(const Duration(minutes: 2));
    await run();
    expect(claims, 2);
  });
}
