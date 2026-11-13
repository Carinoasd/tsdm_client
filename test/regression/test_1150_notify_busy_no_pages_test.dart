/// The first `notify` of a notification fetch refused as too soon (HTTP 429, `retry_after`): waited for, never read
/// from the web pages (GitHub #156, the path left after PR #416).
///
/// Reading the notice page marks every unread notice of the forum read, without `seen` and without the pages after
/// the first: a fetch that fell back to the three pages because the plugin asked for more than two seconds lost the
/// notices #156 is about.
///
/// * Refused with a wait of a few seconds: waited for as the plugin asks, then asked again; no page read.
/// * Refused past [NotificationRepository.notifyBusyBudget] seconds in all, or refused again after the last wait: the
///   fetch gives up this round with HTTP 429 (no page, no `seen`); the caller keeps its bound.
/// * The poll and the refresh the user asked for alike; a forum without the plugin still reads the pages.
///
/// Synthetic answers in the shape of the plugin's.
library;

import 'dart:io' show HttpStatus;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 34;
final int _now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
final int _since = _now - 3600;

/// `notify` of plugin 1.9.0 and later with nothing since [_since].
Map<String, Object?> _nothingNew() => {
  'ok': 1,
  'api': 1,
  'version': '4.0.0',
  'time': _now,
  'uid': _uid,
  'formhash': 'f1f2f3f4',
  'timeoffset': 8,
  'counts': {'notice': 0, 'pm': 0, 'announce': 0},
  'notices': <Object>[],
  'pm_last': 0,
  'pms': <Object>[],
  'announces': <Object>[],
};

/// A forum whose `notify` answers [busy] in turn first (each a 429 with its `retry_after`), then [_nothingNew]; every
/// other request is unexpected.
V4Forum _forum(List<int> busy) {
  final left = [...busy];
  return V4Forum((o) {
    if (o.uri.queryParameters['action'] != 'notify') {
      return null;
    }
    return left.isEmpty ? V4Reply(_nothingNew()) : V4Reply.busy(left.removeAt(0));
  });
}

Future<(Duration, Object)> _fetch(V4Forum forum, {int? timestamp, bool bypassGate = false}) async {
  final started = DateTime.now();
  final result = await NotificationRepository()
      .fetchNotificationWith(v4Client(forum), timestamp: timestamp, bypassGate: bypassGate)
      .run();
  return (DateTime.now().difference(started), result.fold<Object>((e) => e, (v) => v));
}

Matcher get _tooManyRequests =>
    isA<HttpRequestFailedException>().having((e) => e.statusCode, 'statusCode', HttpStatus.tooManyRequests);

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  test('refused for 3 s (more than the 2 s waited before): waited for and asked again, no page', () async {
    final forum = _forum([3]);
    final (took, result) = await _fetch(forum, timestamp: _since);
    expect(forum.names, ['notify', 'notify']);
    expect(forum.unexpected, isEmpty, reason: 'no web page read');
    expect(result, isA<FetchedNotification>());
    expect((result as FetchedNotification).info.noticeList, isEmpty);
    expect(took, greaterThanOrEqualTo(const Duration(seconds: 3)));
  });

  test('refused past the budget: given up at once, no page, no seen, HTTP 429', () async {
    for (final bypassGate in [false, true]) {
      TsdmAppApi.reset();
      final forum = _forum([NotificationRepository.notifyBusyBudget + 1]);
      final (took, result) = await _fetch(forum, timestamp: _since, bypassGate: bypassGate);
      expect(forum.names, ['notify'], reason: 'bypassGate: $bypassGate');
      expect(forum.unexpected, isEmpty, reason: 'bypassGate: $bypassGate');
      expect(result, _tooManyRequests, reason: 'bypassGate: $bypassGate');
      expect(took, lessThan(const Duration(seconds: 2)), reason: 'nothing waited for');
    }
  });

  test('the first fetch (no bound) gives up the same way', () async {
    final forum = _forum([NotificationRepository.notifyBusyBudget + 1]);
    final (_, result) = await _fetch(forum);
    expect(forum.names, ['notify']);
    expect(result, _tooManyRequests);
  });

  test('refused again after every wait: given up after the last one, no page', () async {
    for (final bypassGate in [false, true]) {
      TsdmAppApi.reset();
      final forum = _forum([1, 1, 1, 1]);
      final (_, result) = await _fetch(forum, timestamp: _since, bypassGate: bypassGate);
      expect(forum.names, ['notify', 'notify', 'notify'], reason: 'bypassGate: $bypassGate');
      expect(forum.unexpected, isEmpty, reason: 'bypassGate: $bypassGate');
      expect(result, _tooManyRequests, reason: 'bypassGate: $bypassGate');
    }
  });

  test('the budget counts every wait: a second wait past what is left is not taken', () async {
    final forum = _forum([6, 6]);
    final (took, result) = await _fetch(forum, timestamp: _since);
    expect(forum.names, ['notify', 'notify']);
    expect(result, _tooManyRequests);
    expect(took, lessThan(const Duration(seconds: 10)));
  });

  test('a refresh the user asked for: refused once, waited for, then read from the plugin', () async {
    var refused = false;
    final forum = V4Forum((o) {
      return switch (o.uri.queryParameters['action']) {
        'notify' when !refused => (refused = true) ? const V4Reply.busy(3) : null,
        'notify' => V4Reply(_nothingNew()),
        'pmlist' => V4Reply({..._nothingNew(), 'pms': <Object>[]}),
        _ => null,
      };
    });
    final (_, result) = await _fetch(forum, timestamp: _since, bypassGate: true);
    expect(forum.names.take(2), ['notify', 'notify']);
    expect(forum.names.where((n) => n.contains('do=notice')), isEmpty, reason: 'the notice page is never read');
    expect(result, isNot(_tooManyRequests));
  });

  test('no plugin on the forum: the three pages as before', () async {
    final forum = V4Forum((o) {
      if (o.uri.queryParameters['action'] == 'notify') {
        return const V4Reply('<html><body><div id="messagetext"><p>插件不存在或已关闭</p></div></body></html>');
      }
      return const V4Reply('<html><body><div id="um"></div><div class="nts"></div></body></html>');
    });
    final (_, result) = await _fetch(forum, timestamp: _since);
    expect(forum.names.first, 'notify');
    expect(forum.names.skip(1), hasLength(3));
    expect(result, isA<FetchedNotification>());
  });
}
